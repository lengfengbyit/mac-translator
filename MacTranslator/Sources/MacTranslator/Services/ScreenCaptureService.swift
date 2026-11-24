import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Presents one borderless dimming overlay per screen and captures the dragged
/// area with ScreenCaptureKit (macOS 15.2+), falling back to the legacy window
/// list API on older systems.
///
/// Coordinate systems involved:
///   * AppKit global space: bottom-left origin, main screen at (0, 0), points.
///   * CG/SC display space: top-left origin, main screen at (0, 0), points,
///     multi-display aware. SCScreenshotManager.captureImage(in:) takes this.
@MainActor
final class ScreenCaptureService {
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var escapeMonitor: Any?

    /// Returns nil when the user cancels (Esc, right click or a zero-sized drag).
    /// Throws OCRServiceError.captureFailed when the system cannot produce an image.
    func captureArea() async throws -> CGImage? {
        let rect = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            presentOverlays { selected in
                continuation.resume(returning: selected)
            }
        }
        guard let rect else { return nil }

        // The WindowServer composites asynchronously. Capturing in the same run
        // loop turn as orderOut bakes the 42% black overlay into the image,
        // which Vision then reports as "no text". One frame is enough.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return try await Self.capture(rect: rect)
    }

    // MARK: Overlay

    private func presentOverlays(_ completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        let screens = NSScreen.screens.isEmpty ? [] : NSScreen.screens
        let targets: [NSScreen] = screens.isEmpty ? [] : screens

        for screen in targets {
            let window = CaptureOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenOrigin = screen.frame.origin
            view.onFinish = { [weak self] selected in
                self?.finish(selected)
            }
            window.contentView = view
            overlayWindows.append(window)
            window.makeKeyAndOrderFront(nil)
        }

        if targets.isEmpty {
            completion(nil)
            self.completion = nil
            return
        }

        NSCursor.crosshair.push()

        // A local monitor makes Esc work no matter which display owns the key
        // window (a borderless NSWindow does not reliably become key).
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.finish(nil) }
            return nil
        }
    }

    private func finish(_ rect: CGRect?) {
        guard completion != nil else { return }
        let callback = completion
        completion = nil

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        for window in overlayWindows { window.orderOut(nil) }
        overlayWindows.removeAll()
        NSCursor.pop()

        callback?(rect)
    }

    // MARK: Capture

    private static func capture(rect: CGRect) async throws -> CGImage {
        let cgRect = Self.displaySpaceRect(from: rect)

        if #available(macOS 15.2, *) {
            do {
                // Rect is in screen-space points, top-left origin, and is
                // display agnostic, so selections on a secondary monitor work
                // without any per-display maths. Retina scaling is automatic.
                return try await SCScreenshotManager.captureImage(in: cgRect)
            } catch {
                // Fall through to the legacy path; a transient SCK failure
                // should not make OCR unusable.
            }
        }

        if let legacy = Self.legacyCapture(cgRect) { return legacy }
        throw OCRServiceError.captureFailed(
            "系统未返回图像，请确认已开启「屏幕录制」权限后重试"
        )
    }

    /// AppKit global rect -> CG/SC screen-space rect (top-left origin, points).
    /// Uses the MAIN screen's maxY, not the height of whichever display the
    /// drag started on: with a display above/below the main one, using the
    /// local height silently shifts the captured region.
    static func displaySpaceRect(from rect: CGRect) -> CGRect {
        let mainTop = NSScreen.screens
            .first { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }?
            .frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? rect.maxY
        return CGRect(
            x: rect.minX,
            y: mainTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// CGWindowListCreateImage is marked obsolete in the macOS 15 SDK but still
    /// works for binaries with a macOS 13 deployment target. Kept as a fallback
    /// for macOS 13/14 and for rare ScreenCaptureKit failures.
    private static func legacyCapture(_ rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
    }
}

// MARK: - Overlay window

/// Borderless windows do not reliably become key; overriding this lets the
/// selection view receive keyDown even when the app is an accessory (LSUIElement).
private final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Selection overlay view

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    /// Origin of the owning screen in AppKit global coordinates. Window-local
    /// points are offset by this before being handed to the capture layer.
    var screenOrigin: CGPoint = .zero

    private var startPoint: NSPoint?
    private var endPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Stays unflipped on purpose: convert(event.locationInWindow, from: nil)
    // then yields AppKit global coordinates directly, which is what the
    // capture layer expects. Flipping would invert every vertical coordinate.

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.0, alpha: 0.42).setFill()
        bounds.fill()

        if let rect = selectionRect, rect.width > 0, rect.height > 0 {
            rect.fill(using: .clear)
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            outline.stroke()

            drawBadge(for: rect)
        }

        drawHint()
    }

    private func drawHint() {
        let text = "拖动框选要翻译的文字    ·    Esc 或右键取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(
            x: (bounds.width - size.width - 28) / 2,
            y: bounds.maxY - size.height - 42,
            width: size.width + 28,
            height: size.height + 14
        )
        NSColor(calibratedWhite: 0.12, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + 14, y: box.minY + 7),
            withAttributes: attributes
        )
    }

    private func drawBadge(for rect: NSRect) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let box = NSRect(
            x: rect.minX,
            y: min(bounds.maxY - size.height - 12, rect.maxY + 6),
            width: size.width + 14,
            height: size.height + 8
        )
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(
            at: NSPoint(x: box.minX + 7, y: box.minY + 4),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        endPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        endPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        endPoint = convert(event.locationInWindow, from: nil)
        commit()
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }
    }

    private func commit() {
        guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else {
            onFinish?(nil)
            return
        }
        // Window-local -> AppKit global. On the main screen the origin is zero;
        // on a secondary display it is not, and skipping this used to capture
        // the wrong part of the desktop entirely.
        let global = CGRect(
            x: rect.minX + screenOrigin.x,
            y: rect.minY + screenOrigin.y,
            width: rect.width,
            height: rect.height
        )
        onFinish?(global)
    }

    private var selectionRect: NSRect? {
        guard let start = startPoint, let end = endPoint else { return nil }
        return NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}
