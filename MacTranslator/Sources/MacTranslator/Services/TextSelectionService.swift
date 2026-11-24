import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Three-tier text acquisition: AXUIElement -> browser AppleScript -> simulated Cmd+C.
final class TextSelectionService: TextSelecting {
    private let permission: PermissionService?
    private let axReader: () -> String?
    private let scriptReader: () async -> String?
    private let clipboardReader: () -> String?
    private let now: () -> Date
    private let dedupWindow: TimeInterval

    private var lastSelectionHash: String?
    private var lastSelectionAt: Date = .distantPast

    init(
        permission: PermissionService? = nil,
        axReader: (() -> String?)? = nil,
        scriptReader: (() async -> String?)? = nil,
        clipboardReader: (() -> String?)? = nil,
        currentTime: @escaping () -> Date = Date.init,
        dedupWindow: TimeInterval = 1.0
    ) {
        self.permission = permission
        self.axReader = axReader ?? Self.defaultAXSelection
        self.scriptReader = scriptReader ?? Self.defaultBrowserSelection
        self.clipboardReader = clipboardReader ?? Self.defaultClipboardRead
        self.now = currentTime
        self.dedupWindow = dedupWindow
    }

    func selectText() async -> SelectionResult {
        // L1: AXUIElement must run on the main thread and never touches the clipboard.
        if let text = await readAX() {
            return finish(text, level: .ax, usedClipboard: false)
        }

        // L2: AppleScript may block, so it runs off the main thread when possible.
        if let text = await readAppleScript() {
            return finish(text, level: .appleScript, usedClipboard: false)
        }

        // L3: Cmd+C overwrites the clipboard; always restore it afterwards.
        if let text = await simulateCmdC() {
            return finish(text, level: .cmdC, usedClipboard: true)
        }

        return SelectionResult(text: "", usedClipboardFallback: false, usedLevel: .ax)
    }

    // MARK: Tiers

    private func readAX() async -> String? {
        let value = await MainActor.run { () -> String? in
            if let permission, permission.status(type: .accessibility) != .granted {
                return nil
            }
            return axReader()
        }
        return Self.nonempty(value)
    }

    private func readAppleScript() async -> String? {
        Self.nonempty(await scriptReader())
    }

    private func simulateCmdC() async -> String? {
        await MainActor.run { () -> String? in
            if let permission, permission.status(type: .accessibility) != .granted {
                return nil
            }
            let snapshot = ClipboardSnapshot.capture()
            defer { snapshot.restore() }
            Self.postCommandC()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            return Self.nonempty(clipboardReader())
        }
    }

    private func finish(
        _ text: String,
        level: SelectionLevel,
        usedClipboard: Bool
    ) -> SelectionResult {
        guard !shouldSkipDuplicate(text) else {
            return SelectionResult(text: "", usedClipboardFallback: false, usedLevel: level)
        }
        return SelectionResult(
            text: text,
            usedClipboardFallback: usedClipboard,
            usedLevel: level
        )
    }

    /// 1s window de-duplication protects against double-firing from a single keystroke.
    private func shouldSkipDuplicate(_ text: String) -> Bool {
        let hash = text.sha256Hex
        let current = now()
        defer {
            lastSelectionHash = hash
            lastSelectionAt = current
        }
        guard let previous = lastSelectionHash else { return false }
        return previous == hash && current.timeIntervalSince(lastSelectionAt) < dedupWindow
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    // MARK: Default implementations

    private static func defaultAXSelection() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusStatus == .success, let focusedValue else { return nil }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        let selectionStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectionStatus == .success else { return nil }
        return selectedValue as? String
    }

    private static func defaultBrowserSelection() async -> String? {
        let bundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        guard let bundleID else { return nil }
        return await Task.detached {
            browserSelection(bundleID: bundleID)
        }.value
    }

    private static func browserSelection(bundleID: String) -> String? {
        let scriptSource: String?
        switch bundleID {
        case "com.google.chrome":
            scriptSource = "tell application \"Google Chrome\" to execute javascript \"window.getSelection().toString()\""
        case "com.apple.Safari":
            scriptSource = "tell application \"Safari\" to do JavaScript \"window.getSelection().toString()\" in front document"
        case "com.microsoft.edgemac":
            scriptSource = "tell application \"Microsoft Edge\" to execute javascript \"window.getSelection().toString()\""
        default:
            return nil
        }
        guard let scriptSource, let script = NSAppleScript(source: scriptSource) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let stringValue = result.stringValue else { return nil }
        return stringValue
    }

    private static func defaultClipboardRead() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Clipboard protection

private struct ClipboardSnapshot {
    let changeCount: Int
    let items: [[String: Data]]

    static func capture() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.map { item -> [String: Data] in
            var payload: [String: Data] = [:]
            for type in item.types {
                payload[type.rawValue] = item.data(forType: type)
            }
            return payload
        } ?? []
        return ClipboardSnapshot(changeCount: pasteboard.changeCount, items: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rebuilt = items.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !rebuilt.isEmpty {
            pasteboard.writeObjects(rebuilt)
        }
        _ = changeCount
    }
}
