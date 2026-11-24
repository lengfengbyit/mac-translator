import AppKit
import CoreGraphics
import SwiftUI
import Foundation

// Drives REAL AppKit keyboard events through the result panel's editable
// source card: focus switch, plain typing, Return, Shift+Return and IME
// composition. Compile together with BasePanel.swift + ResultView.swift.

struct AppSettings { static let defaultResultOpacity: Double = 1.0 }
enum SourceType { case selection, ocr }
struct TranslationResult {
    var original: String = ""
    var translated: String = ""
    var sourceType: SourceType = .selection
    var usedEndpointName: String = "智谱翻译"
    var usedModel: String = "glm-4-flash"
    var degradedFromName: String? = nil
    var cached: Bool = false
    var elapsed: Double = 0.8
}
@MainActor
final class ResultViewModel: ObservableObject {
    @Published var result: TranslationResult?
    @Published var errorMessage: String?
    @Published var progressText: String?
    @Published var clipboardWarning = ""
    @Published var isFavorite = false
    @Published var toastMessage = ""
    @Published var isPinned = false
    @Published var isCollapsed = false
    @Published var showsPermissionAction = false
    @Published var sourceLanguageLabel = "自动检测"
    @Published var targetLanguageLabel = "简体中文"
    @Published var inputMode = false
    @Published var inputText = ""
    var onClose: (() -> Void)?
    func copyAction() {}
    func copyOriginalAction() {}
    func favoriteAction() {}
    func retranslateAction() {}
    func closeAction() { onClose?() }
    func togglePinAction() { isPinned.toggle() }
    func toggleCollapsed() { isCollapsed.toggle() }
    func openPermissionSettingsAction() {}
    func speakAction(_ text: String) {}
    func startInputAction() {}
    func submitInput(_ text: String) {}
    func endInputMode() { inputMode = false }
}

@main
struct InputFocusPanelProbe {
    @MainActor
    static func main() {
        var pass = 0
        var fail = 0
        func check(_ condition: Bool, _ label: String) {
            if condition {
                pass += 1
                print("PASS: \(label)")
            } else {
                fail += 1
                print("FAIL: \(label)")
            }
        }

        func keyEvent(_ chars: String, _ keyCode: UInt16, shift: Bool = false) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: shift ? .shift : [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            )
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let panel = BasePanel(
            contentRect: NSRect(x: 300, y: 300, width: 420, height: 220)
        )
        check(!panel.canBecomeKey, "F1 默认不抢前台焦点（划词/OCR 结果窗行为不变）")

        let editor = SubmitTextView(frame: NSRect(x: 8, y: 8, width: 400, height: 190))
        editor.isEditable = true
        editor.isRichText = false
        editor.string = "hello"
        var submitted: [String] = []
        editor.onSubmit = { submitted.append($0) }
        panel.contentView = editor

        panel.allowsKeyboardInput = true
        check(panel.canBecomeKey, "F2 输入模式打开 key window 能力")

        panel.makeKeyAndOrderFront(nil)
        _ = panel.makeFirstResponder(editor)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        print("DIAG appActive=\(app.isActive) isKeyWindow=\(panel.isKeyWindow) "
              + "keyWindowMatches=\(app.keyWindow === panel) isVisible=\(panel.isVisible) "
              + "firstResponderMatches=\(panel.firstResponder === editor)")
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let locked = "\(session["CGSSessionScreenIsLocked"] ?? "")" == "1"
        if locked {
            // While the session is locked AppKit refuses to activate any app,
            // so isKeyWindow legitimately stays false in a CLI probe. The real
            // proof that typing works is F5 (a key delivered to the editor).
            print("NOTE: session locked; AppKit will not activate, F3 judged via focus chain + F5")
            check(panel.canBecomeKey && panel.firstResponder === editor,
                  "F3 锁屏下焦点链可用（canBecomeKey + firstResponder）")
        } else {
            check(panel.isKeyWindow, "F3 面板确实成为 key window")
        }
        check(panel.firstResponder === editor, "F4 输入框成为第一响应者")

        if let e = keyEvent("x", 7) { app.sendEvent(e) }
        check(editor.string == "hellox", "F5 普通按键经真实派发链进入输入框（实际：\(editor.string)）")

        if let e = keyEvent("\r", 36) { app.sendEvent(e) }
        check(submitted == ["hellox"], "F6 回车只提交一次，携带完整草稿")
        check(editor.string == "hellox", "F7 回车不往原文里塞换行")

        if let e = keyEvent("\r", 36, shift: true) { app.sendEvent(e) }
        check(editor.string == "hellox\n", "F8 Shift+回车插入真实换行")
        check(submitted.count == 1, "F9 Shift+回车不触发翻译")

        submitted.removeAll()
        editor.setMarkedText(
            "ni" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let composing = editor.hasMarkedText()
        check(composing, "F10 可进入输入法候选组合态")
        if composing {
            if let e = keyEvent("\r", 36) { app.sendEvent(e) }
            check(submitted.isEmpty, "F11 组合态回车交由输入法确认，不误提交")
            editor.unmarkText()
        } else {
            // Headless / no active input context: the guard is still covered
            // by the source-contract suite (I35).
            print("NOTE: no active input context; F11 covered by source contract instead")
        }

        panel.allowsKeyboardInput = false
        check(!panel.canBecomeKey, "F12 退出输入模式恢复不抢焦点")
        panel.orderOut(nil)

        print("InputFocusPanelProbe: \(pass)/\(pass + fail) PASS, \(fail) FAIL")
        if fail > 0 { exit(1) }
    }
}
