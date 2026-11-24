import Foundation

// Verifies the typed-input feature end to end at the source-contract level,
// plus a REAL JSON round-trip proving an older settings.json (no `input`
// hotkey) is upgraded without resetting the user's other settings.
// Compile with the real model files (see run.sh).

struct Check {
    var pass = 0
    var fail = 0

    mutating func check(_ condition: Bool, _ label: String) {
        if condition {
            pass += 1
            print("PASS: \(label)")
        } else {
            fail += 1
            print("FAIL: \(label)")
        }
    }
}

private func source(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
struct InputTranslateVerification {
    static func main() {
        let root = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath
        let base = root + "/Sources/MacTranslator"
        var r = Check()

        let enums = source("\(base)/Core/Models/Enums.swift")
        let settings = source("\(base)/Core/Models/AppSettings.swift")
        let hotkeys = source("\(base)/Services/HotkeyService.swift")
        let menu = source("\(base)/App/MenuBarController.swift")
        let delegate = source("\(base)/App/AppDelegate.swift")
        let hotkeyPane = source("\(base)/UI/panes/HotkeyPane.swift")
        let settingsVM = source("\(base)/UI/Shared/SettingsViewModel.swift")
        let coordinator = source("\(base)/App/AppCoordinator.swift")
        let panel = source("\(base)/UI/Windows/BasePanel.swift")
        let controller = source("\(base)/UI/Windows/ResultWindowController.swift")
        let viewModel = source("\(base)/UI/Shared/ResultViewModel.swift")
        let view = source("\(base)/UI/Views/ResultView.swift")

        // MARK: A. Model + backwards compatibility
        r.check(enums.contains("case input") && enums.contains("case .input: return \"输入\""),
                "I1 SourceType 新增 .input 与中文显示名")
        r.check(settings.contains("static let inputDefault") && settings.contains("keyCode: 34"),
                "I2 输入快捷键默认 kVK_ANSI_I")
        r.check(settings.contains("modifiers: 2048 | 512"),
                "I3 默认组合为 ⌥⇧I，避开 Bob 的 ⌥D")
        r.check(settings.contains("var input: HotkeyBinding"),
                "I4 HotkeyBindings 持有第三个绑定")
        r.check(settings.contains("decodeIfPresent(HotkeyBinding.self, forKey: .input)"),
                "I5 旧配置缺 input 时按默认填充，而不是抛错")
        r.check(settings.contains("try c.encode(input, forKey: .input)"),
                "I6 新配置完整写回 input")

        // Real JSON round trip: strip `input` from a current payload and set
        // two non-default values. A strict synthesized decoder would throw,
        // SettingsStore would fall back to .default and lose BOTH values.
        do {
            var settingsToEncode = AppSettings.default
            settingsToEncode.targetLanguage = "English"
            settingsToEncode.resultOpacity = 0.62
            let data = try JSONEncoder().encode(settingsToEncode)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var bindings = json["hotkeys"] as? [String: Any] else {
                r.check(false, "I7 构造旧版 JSON 失败")
                throw NSError(domain: "probe", code: 1)
            }
            bindings.removeValue(forKey: "input")
            json["hotkeys"] = bindings
            let legacyData = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
            r.check(decoded.hotkeys.input == HotkeyBinding.inputDefault,
                    "I7 旧配置补出默认 ⌥⇧I")
            r.check(decoded.targetLanguage == "English" && decoded.resultOpacity == 0.62,
                    "I8 旧配置的其他设置与密钥字段未被整体回退清空")
            r.check(decoded.hotkeys.selection == settingsToEncode.hotkeys.selection &&
                    decoded.hotkeys.ocr == settingsToEncode.hotkeys.ocr,
                    "I9 已有划词/OCR 快捷键逐项保留")
        } catch {
            r.check(false, "I7 旧版 settings.json 解码异常：\(error)")
        }

        do {
            var custom = AppSettings.default
            custom.hotkeys.input = HotkeyBinding(keyCode: 17, modifiers: 4096 | 2048)
            let data = try JSONEncoder().encode(custom)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            r.check(decoded.hotkeys.input.keyCode == 17 &&
                    decoded.hotkeys.input.modifiers == (4096 | 2048),
                    "I10 用户自定义输入快捷键可持久化并读回")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let bindings = json?["hotkeys"] as? [String: Any]
            r.check(bindings?["input"] != nil, "I11 编码产物确实包含 input 字段")
        } catch {
            r.check(false, "I10 新版 settings.json 往返失败：\(error)")
        }

        // MARK: B. Entry points
        r.check(hotkeys.contains("case input = 3") &&
                hotkeys.contains("case .input: return \"输入翻译\""),
                "I12 第三个全局热键动作与标签")
        r.check(hotkeys.contains("private var inputRef: EventHotKeyRef?") &&
                hotkeys.contains("unregisterRef(&inputRef)"),
                "I13 独立注册/注销引用，不会覆盖其他热键")
        r.check(hotkeys.contains(".input: [") &&
                hotkeys.contains("let inputOK = registerWithFallback(") &&
                hotkeys.contains("return selectionOK && ocrOK && inputOK"),
                "I14 输入热键参与注册、冲突避让与结果汇总")
        r.check(hotkeys.contains("updated.hotkeys.input = input"),
                "I15 自动避让后的实际组合写回配置")
        r.check(menu.contains("var onInput: (() -> Void)?") &&
                menu.contains("withTitle: \"输入翻译\"") &&
                menu.contains("#selector(inputTranslate(_:))") &&
                menu.contains("onInput?()"),
                "I16 菜单栏新增可用入口")
        r.check(menu.contains("input.tag = 3"), "I17 菜单项标记避免与权限项混淆")
        r.check(delegate.contains("case .input: self.coordinator.handleInput()") &&
                delegate.contains("menuBar.onInput = { [weak self] in"),
                "I18 快捷键与菜单入口都接到 coordinator")
        r.check(hotkeyPane.contains("title: \"输入翻译\"") &&
                hotkeyPane.contains("vm.settings.hotkeys.input") &&
                hotkeyPane.contains("for: .input"),
                "I19 设置页可录制输入快捷键")
        r.check(settingsVM.contains("case .input: settings.hotkeys.input = binding"),
                "I20 设置写入分支完整")

        // MARK: C. Translation pipeline
        r.check(coordinator.contains("case input") &&
                coordinator.contains("func handleInput()") &&
                coordinator.contains("resultWindow.showInput()"),
                "I21 新增 handleInput 入口")
        r.check(coordinator.contains("func submitInput(_ text: String) async") &&
                coordinator.contains("sourceType: .input") &&
                coordinator.contains("action: .input"),
                "I22 输入文本走同一 gateway/缓存/历史链路")
        r.check(coordinator.contains("case .selection, .input:"),
                "I23 重译覆盖输入模式")
        r.check(coordinator.contains("resultWindow.endInputMode()"),
                "I24 划词切换时退出输入模式，避免残留抢焦点")
        r.check(coordinator.contains("resultWindow.onSubmitInput = {"),
                "I25 回车提交回调已接线")

        // MARK: D. Focus switching
        r.check(panel.contains("var allowsKeyboardInput = false") &&
                panel.contains("override var canBecomeKey: Bool { allowsKeyboardInput }"),
                "I26 默认不抢焦点，输入模式按需开启 key window")
        r.check(controller.contains("func showInput(initialText: String = \"\")") &&
                controller.contains("panel.makeKeyAndOrderFront(nil)") &&
                controller.contains("private func focusInputEditor("),
                "I27 showInput 激活窗口并延迟重试聚焦输入框")
        r.check(controller.contains("func endInputMode()") &&
                controller.contains("panel.allowsKeyboardInput = false"),
                "I28 关闭/退出输入模式恢复不抢焦点")
        r.check(viewModel.contains("func showInput(initialText:") &&
                viewModel.contains("func submitInput(_ text: String)") &&
                viewModel.contains("onSubmitInput?(trimmed)"),
                "I29 ViewModel 管理输入态与提交")
        r.check(viewModel.contains("toastMessage = \"请先输入要翻译的文字\""),
                "I30 空输入不发起请求并有提示")
        r.check(viewModel.contains("inputMode = false") &&
                viewModel.contains("func clear()"),
                "I31 关窗后不残留输入态")

        // MARK: E. Editor behaviour + UI reuse
        r.check(view.contains("final class SubmitTextView: NSTextView") &&
                view.contains("struct InputEditor: NSViewRepresentable"),
                "I32 输入区为 AppKit 文本视图包装")
        r.check(view.contains("event.keyCode == 36") &&
                view.contains("onSubmit?(string)"),
                "I33 回车提交")
        r.check(view.contains("event.modifierFlags.contains(.shift)") &&
                view.contains("insertText(\"\\n\", replacementRange: selectedRange())"),
                "I34 Shift+回车插入换行而不提交")
        r.check(view.contains("hasMarkedText()") &&
                view.contains("NSSelectorFromString(\"insertNewline:\")"),
                "I35 中文输入法候选态与命令派发路径均不误提交")
        r.check(!view.contains("didChangeText"),
                "I36 每次按键不回写 SwiftUI，避免全量重绘（历史输入框 bug）")
        r.check(view.contains("private var inputCard: some View") &&
                view.contains("\"keyboard\"") &&
                view.contains("vm.startInputAction()"),
                "I37 结果页新增输入卡片与工具栏入口")
        r.check(view.contains("InputEditorRegistry.shared.textView?.string"),
                "I38 翻译按钮读取实时草稿，鼠标操作同样可用")
        r.check(view.contains("if vm.inputMode {") &&
                view.contains("inputCard") &&
                view.contains("if !vm.inputMode {") &&
                view.contains("sourceCard(result.original)"),
                "I39 输入模式替换原文卡片，普通模式保持不变")
        r.check(view.contains("sourceCard") && view.contains("languageBar") &&
                view.contains("translationCard") && view.contains("toolButton"),
                "I40 译文卡片/语言栏/工具栏完全复用，未另建窗口")
        r.check(controller.contains("firstResponder as? NSTextView") &&
                controller.contains("textView.hasMarkedText()") &&
                controller.contains("IME uses Escape"),
                "I41 输入法候选态按 Esc 取消候选，不误关整个窗口")
        r.check(controller.contains("keyCode == 53") && controller.contains("self?.close()"),
                "I42 普通 Esc 关闭窗口行为保留")

        print("InputTranslateVerification: \(r.pass)/\(r.pass + r.fail) PASS, \(r.fail) FAIL")
        if r.fail > 0 { exit(1) }
    }
}
