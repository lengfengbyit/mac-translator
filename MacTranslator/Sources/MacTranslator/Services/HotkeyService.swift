import AppKit
import Carbon
import Foundation

/// Semantic action behind a global hotkey.
enum HotkeyAction: UInt32 {
    case selection = 1
    case ocr = 2

    var label: String {
        switch self {
        case .selection: return "划词翻译"
        case .ocr: return "OCR 翻译"
        }
    }
}

/// C event handlers cannot capture state; a process-wide dispatcher forwards to the service.
private final class HotkeyDispatcher {
    static let shared = HotkeyDispatcher()
    var handler: ((HotkeyAction) -> Void)?
    private init() {}
}

private func hotkeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if status == noErr, let action = HotkeyAction(rawValue: hotKeyID.id) {
        DispatchQueue.main.async {
            HotkeyDispatcher.shared.handler?(action)
        }
    }
    return noErr
}

/// Carbon based global hotkeys. Registration itself requires no accessibility permission.
final class HotkeyService {
    private let settingsStore: SettingsStoring
    private var selectionRef: EventHotKeyRef?
    private var ocrRef: EventHotKeyRef?
    private var handlerInstalled = false

    /// Set by the composition root; receives actions on the main queue.
    var onHotkeyAction: ((HotkeyAction) -> Void)?

    /// Set when a registration fails, or when a fallback combo was chosen.
    private(set) var conflictMessage: String?

    /// Bob ships ⌥D for selection translation and iShot-like tools commonly
    /// claim ⌥⇧S, so the documented defaults collide on real machines. When a
    /// combo is taken we try a short, deterministic list instead of leaving
    /// the user with a dead shortcut and a greyed-out menu.
    private static let fallbacks: [HotkeyAction: [HotkeyBinding]] = [
        .selection: [
            HotkeyBinding(keyCode: 2, modifiers: 2048 | 512),   // ⌥⇧D
            HotkeyBinding(keyCode: 17, modifiers: 2048 | 512),  // ⌥⇧T
            HotkeyBinding(keyCode: 2, modifiers: 4096 | 2048)   // ⌘⌥D
        ],
        .ocr: [
            HotkeyBinding(keyCode: 0, modifiers: 2048 | 512),   // ⌥⇧A
            HotkeyBinding(keyCode: 1, modifiers: 4096 | 2048),  // ⌘⌥S
            HotkeyBinding(keyCode: 3, modifiers: 2048 | 512)    // ⌥⇧F
        ]
    ]

    init(settingsStore: SettingsStoring) {
        self.settingsStore = settingsStore
    }

    /// Called by the Carbon handler; dispatches to the registered application callback.
    func onHotkey(_ action: HotkeyAction) {
        onHotkeyAction?(action)
    }

    @discardableResult
    func register() -> Bool {
        conflictMessage = nil
        HotkeyDispatcher.shared.handler = { [weak self] action in
            self?.onHotkey(action)
        }
        installHandlerIfNeeded()

        let configured = settingsStore.current.hotkeys
        var selection = configured.selection
        var ocr = configured.ocr
        var adjustments: [String] = []

        let selectionOK = registerWithFallback(
            action: .selection, preferred: &selection, ref: &selectionRef, log: &adjustments
        )
        let ocrOK = registerWithFallback(
            action: .ocr, preferred: &ocr, ref: &ocrRef, log: &adjustments
        )

        if !adjustments.isEmpty {
            // Persist what actually works so the Settings pane shows the truth
            // and the next launch does not repeat the whole negotiation.
            var updated = settingsStore.current
            updated.hotkeys.selection = selection
            updated.hotkeys.ocr = ocr
            try? settingsStore.update(updated)
            conflictMessage = "快捷键被其他 App 占用，已自动切换：\(adjustments.joined(separator: "；"))。可在「设置 › 快捷键」中修改。"
        }

        return selectionOK && ocrOK
    }

    func unregister() {
        unregisterRef(&selectionRef)
        unregisterRef(&ocrRef)
        HotkeyDispatcher.shared.handler = nil
    }

    /// Re-registers after a hotkey customization. Returns false when the new combo is occupied.
    @discardableResult
    func reregister() -> Bool {
        unregister()
        return register()
    }

    // MARK: Internals

    private func registerWithFallback(
        action: HotkeyAction,
        preferred: inout HotkeyBinding,
        ref: inout EventHotKeyRef?,
        log: inout [String]
    ) -> Bool {
        if registerOne(binding: preferred, action: action, ref: &ref) { return true }
        let original = preferred
        for candidate in Self.fallbacks[action] ?? [] {
            if registerOne(binding: candidate, action: action, ref: &ref) {
                preferred = candidate
                conflictMessage = nil
                log.append("\(action.label) \(original.displayString) → \(candidate.displayString)")
                return true
            }
        }
        conflictMessage = "\(action.label) 快捷键 \(original.displayString) 及全部备用组合均被占用，请到「设置 › 快捷键」手动指定。"
        return false
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            nil,
            nil
        )
        handlerInstalled = status == noErr
    }

    private func registerOne(
        binding: HotkeyBinding,
        action: HotkeyAction,
        ref: inout EventHotKeyRef?
    ) -> Bool {
        unregisterRef(&ref)
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x54524E53), // 'TRNS'
            id: action.rawValue
        )
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            UInt32(binding.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            let occupied: OSStatus = -9868 // hotKeyAlreadyRegistered
            conflictMessage = status == occupied
                ? "快捷键 \(binding.displayString) 已被占用"
                : "快捷键 \(binding.displayString) 注册失败（\(status)）"
            return false
        }
        return true
    }

    private func unregisterRef(_ ref: inout EventHotKeyRef?) {
        if let existing = ref {
            UnregisterEventHotKey(existing)
            ref = nil
        }
    }
}
