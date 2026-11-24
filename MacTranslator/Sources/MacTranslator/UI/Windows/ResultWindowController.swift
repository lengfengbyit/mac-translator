import AppKit
import Foundation
import SwiftUI

/// Hosting view that accepts the very first click even though the owning panel
/// never becomes key (so the custom close button always works on first press).
private final class ResultHostingView: NSHostingView<ResultView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ResultWindowController {
    private let panel: BasePanel
    private let settingsStore: SettingsStoring
    private let appearance: ResultAppearance
    let viewModel = ResultViewModel()

    /// Set by the coordinator to persist favorite changes.
    var onToggleFavorite: ((UUID) -> Void)?
    /// Set by the coordinator to re-run the last request.
    var onRetranslate: (() -> Void)?

    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private var settingsObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?
    private var currentSize = NSSize(
        width: ResultLayout.width,
        height: ResultLayout.initialWindowHeight
    )
    private var isPinned = false

    private enum PositionKey {
        static let x = "MacTranslator.ResultPanel.OriginX"
        static let y = "MacTranslator.ResultPanel.OriginY"
    }

    init(settingsStore: SettingsStoring) {
        self.settingsStore = settingsStore
        self.appearance = ResultAppearance.shared
        let initial = NSSize(
            width: ResultLayout.width,
            height: ResultLayout.initialWindowHeight
        )
        let panel = BasePanel(contentRect: NSRect(origin: .zero, size: initial))
        self.panel = panel

        applyAppearance()
        appearance.bodyHeight = ResultLayout.initialBodyHeight
        appearance.windowHeight = ResultLayout.initialWindowHeight

        let hosting = ResultHostingView(rootView: ResultView(vm: viewModel, appearance: appearance))
        hosting.frame = NSRect(origin: .zero, size: initial)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        viewModel.onCopy = { [weak self] in
            guard let text = self?.viewModel.result?.translated else { return }
            Self.copyToPasteboard(text)
        }
        viewModel.onCopyOriginal = { [weak self] in
            guard let text = self?.viewModel.result?.original else { return }
            Self.copyToPasteboard(text)
        }
        viewModel.onFavorite = { [weak self] recordID in
            self?.onToggleFavorite?(recordID)
        }
        viewModel.onRetranslate = { [weak self] in
            self?.onRetranslate?()
        }
        viewModel.onClose = { [weak self] in
            self?.close()
        }
        viewModel.onPinChange = { [weak self] pinned in
            self?.isPinned = pinned
        }
        viewModel.onOpenPermissionSettings = {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) {
                NSWorkspace.shared.open(url)
            }
        }

        // Defer the resize to the next run-loop turn: updating @Published
        // values synchronously from inside a SwiftUI render is not allowed.
        appearance.onContentHeightChange = { [weak self] height in
            Task { @MainActor in
                self?.applyMeasuredHeight(height)
            }
        }

        installMonitors()
        installObservers()
    }

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func show(
        _ result: TranslationResult,
        recordID: UUID?,
        isFavorite: Bool,
        clipboardFallback: Bool
    ) {
        let settings = settingsStore.current
        viewModel.sourceLanguageLabel = settings.sourceAutoDetect ? "自动检测" : settings.sourceLanguage
        viewModel.targetLanguageLabel = settings.targetLanguage
        viewModel.show(
            result,
            recordID: recordID,
            isFavorite: isFavorite,
            clipboardFallback: clipboardFallback
        )
        present()
    }

    func showError(_ message: String, needsPermissionSettings: Bool = false) {
        viewModel.showError(message, needsPermissionSettings: needsPermissionSettings)
        present()
    }

    /// During region selection the progress state is updated but the panel
    /// stays hidden, so it cannot sit behind the full-screen dimming overlay.
    func showProgress(_ message: String, present shouldPresent: Bool = true) {
        viewModel.showProgress(message)
        if shouldPresent { present() }
    }

    func close() {
        panel.orderOut(nil)
        viewModel.clear()
    }

    // MARK: Presentation

    private func applyAppearance() {
        appearance.opacity = settingsStore.current.resultOpacity
    }

    private func present() {
        applyAppearance()
        let size = currentSize
        var origin = Self.defaultOrigin(for: size)
        if let saved = Self.savedOrigin(), Self.isUsable(origin: saved, size: size) {
            origin = saved
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Grows/shrinks the panel to the measured card stack. The top edge stays
    /// put, so a resize never looks like the window jumped. Long results are
    /// capped and scroll inside the content area.
    private func applyMeasuredHeight(_ contentHeight: CGFloat) {
        let body = min(
            max(contentHeight, ResultLayout.minBodyHeight),
            ResultLayout.maxBodyHeight
        )
        let total = body + ResultLayout.titleBarHeight
        guard abs(total - currentSize.height) > 0.5 else { return }

        let size = NSSize(width: ResultLayout.width, height: total)
        let origin = panel.frame.origin
        let top = panel.frame.maxY
        currentSize = size
        appearance.bodyHeight = body
        appearance.windowHeight = total
        panel.setFrame(
            NSRect(x: origin.x, y: top - total, width: size.width, height: size.height),
            display: true
        )
    }

    private static func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: visible.maxX - size.width - 18,
            y: visible.maxY - size.height - 28
        )
    }

    private static func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PositionKey.x) != nil,
              defaults.object(forKey: PositionKey.y) != nil else { return nil }
        return NSPoint(
            x: defaults.double(forKey: PositionKey.x),
            y: defaults.double(forKey: PositionKey.y)
        )
    }

    /// Reject positions left behind by a disconnected external display.
    private static func isUsable(origin: NSPoint, size: NSSize) -> Bool {
        let frame = NSRect(origin: origin, size: size)
        let screens = NSScreen.screens
        if screens.isEmpty { return true }
        return screens.contains { screen in
            let visiblePart = screen.visibleFrame.intersection(frame)
            return !visiblePart.isNull && visiblePart.width >= 80 && visiblePart.height >= 40
        }
    }

    private func persistOrigin() {
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: Self.PositionKey.x)
        UserDefaults.standard.set(Double(origin.y), forKey: Self.PositionKey.y)
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.PositionKey.x)
        UserDefaults.standard.removeObject(forKey: Self.PositionKey.y)
        panel.setFrame(
            NSRect(origin: Self.defaultOrigin(for: currentSize), size: currentSize),
            display: true
        )
    }

    // MARK: Events

    private func installMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            Task { @MainActor in self?.close() }
            return nil
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                if self.panel.isVisible && !self.isPinned && !self.panel.frame.contains(point) {
                    self.close()
                }
            }
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        settingsObserver = center.addObserver(
            forName: .macTranslatorSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }
        moveObserver = center.addObserver(
            forName: .resultPanelDidMove, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistOrigin() }
        }
        resetObserver = center.addObserver(
            forName: .resultPanelResetPosition, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetPosition() }
        }
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        for observer in [settingsObserver, moveObserver, resetObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
