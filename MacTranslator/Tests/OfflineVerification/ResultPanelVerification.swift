import Foundation

// Offline regression for the result-window fixes:
//   1. configurable backdrop opacity (default fully opaque, backward compatible)
//   2. native drag surface instead of isMovableByWindowBackground
//   3. a real close hit area wired to onClose
//   4. persisted window position with off-screen validation
// Run via Tests/OfflineVerification/run.sh.

final class Counter {
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
}

func source(_ root: String, _ path: String) -> String {
    (try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8)) ?? ""
}

@main
struct ResultPanelVerification {
static func main() {
let r = Counter()
let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let base = "Sources/MacTranslator"

// MARK: A. AppSettings behaviour (real compiled code)

let defaults = AppSettings.default
r.check(defaults.resultOpacity == 1.0, "A1 默认背景不透明度 = 1.0（完全不透明，修复『太透明』）")
r.check(AppSettings.resultOpacityRange.lowerBound == 0.35 &&
        AppSettings.resultOpacityRange.upperBound == 1.0, "A2 可调节范围 0.35...1.0")
r.check(AppSettings(resultOpacity: 9).resultOpacity == 1.0, "A3 超上限值被 clamp 到 1.0")
r.check(AppSettings(resultOpacity: -3).resultOpacity == 0.35, "A4 超下限值被 clamp 到 0.35")

var tuned = AppSettings.default
tuned.resultOpacity = 0.62
let encoded = try! JSONEncoder().encode(tuned)
let decoded = try! JSONDecoder().decode(AppSettings.self, from: encoded)
r.check(decoded == tuned, "A5 resultOpacity Codable 往返一致")
r.check(String(data: encoded, encoding: .utf8)?.contains("resultOpacity") == true,
        "A6 resultOpacity 写入 settings.json")

// Existing users have a settings.json without this key: decodeIfPresent must
// fall back to the new opaque default rather than failing or turning translucent.
let legacy = "{}".data(using: .utf8)!
let fromLegacy = try! JSONDecoder().decode(AppSettings.self, from: legacy)
r.check(fromLegacy.resultOpacity == 1.0, "A7 旧配置文件缺字段时回落为 1.0（向后兼容）")

// MARK: B. Native title bar / close / drag (source contracts)

let panelSrc = source(root, "\(base)/UI/Windows/BasePanel.swift")
r.check(panelSrc.contains("styleMask: [.borderless, .nonactivatingPanel]"),
        "B1 结果窗为 borderless + nonactivatingPanel（去掉失效的系统交通灯）")
r.check(panelSrc.contains("var allowsKeyboardInput = false") &&
        panelSrc.contains("override var canBecomeKey: Bool { allowsKeyboardInput }"),
        "B2 默认不抢前台焦点，仅输入模式按需成为 key window")
r.check(panelSrc.contains("isReleasedWhenClosed = false"),
        "B3 保留窗口生命周期修复（isReleasedWhenClosed=false）")
r.check(panelSrc.contains("isMovableByWindowBackground = false"),
        "B4 关闭 AppKit 背景拖动，交由原生标题栏处理")

let viewSrc = source(root, "\(base)/UI/Views/ResultView.swift")
r.check(viewSrc.contains("final class ResultTitleBarView: NSView"),
        "B5 原生标题栏视图存在")
r.check(viewSrc.contains("override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }"),
        "B6 首次点击即可接收事件（非激活窗口不再吞点击）")
r.check(viewSrc.contains("onClose?()"), "B7 关闭热区直接触发 onClose")
r.check(viewSrc.contains("closeRect.insetBy(dx: -6, dy: -6).contains(local)"),
        "B8 左上角关闭热区有放大容差，易于点中")
r.check(viewSrc.contains("NSBezierPath(ovalIn: closeRect)") && viewSrc.contains("NSColor.systemRed"),
        "B9 自绘红色圆形叉按钮")
r.check(viewSrc.contains("override func mouseDragged(with event: NSEvent)") &&
        viewSrc.contains("override func mouseUp(with event: NSEvent)") &&
        viewSrc.contains("window.setFrameOrigin"),
        "B10 标准 AppKit 拖动分发（mouseDragged/mouseUp），不阻塞 run loop")
r.check(!viewSrc.contains("NSEvent.mouseLocation"),
        "B10b 拖动不依赖会滞后的全局光标位置")
r.check(viewSrc.contains("NotificationCenter.default.post(name: .resultPanelDidMove"),
        "B11 拖动结束发通知（用于保存位置）")
r.check(viewSrc.contains("Color(nsColor: .windowBackgroundColor).opacity(appearance.opacity)"),
        "B12 背景按设置渲染不透明度")
r.check(viewSrc.contains(".allowsHitTesting(false)"), "B13 标题栏文字不拦截鼠标事件")
r.check(viewSrc.components(separatedBy: "appearance.opacity").count - 1 == 1,
        "B14 appearance.opacity 仅作用于背景，译文文字始终不透明")

let controllerSrc = source(root, "\(base)/UI/Windows/ResultWindowController.swift")
r.check(controllerSrc.contains("private static func savedOrigin()"), "B15 读取已保存的窗口位置")
r.check(controllerSrc.contains("private func persistOrigin()"), "B16 拖动后持久化位置")
r.check(controllerSrc.contains("private static func isUsable(origin: NSPoint, size: NSSize)"),
        "B17 多屏幕 / 屏幕外位置校验")
r.check(controllerSrc.contains("if let saved = Self.savedOrigin(), Self.isUsable(origin: saved, size: size)"),
        "B18 present() 优先恢复记忆位置而非强制右上角")
r.check(controllerSrc.contains("viewModel.onClose = { [weak self] in"), "B19 关闭回调接线到 close()")
r.check(controllerSrc.contains(".macTranslatorSettingsDidChange") &&
        controllerSrc.contains("applyAppearance()"), "B20 设置变更即时刷新结果窗外观")
r.check(controllerSrc.contains(".resultPanelResetPosition"), "B21 支持重置窗口位置")
r.check(controllerSrc.contains("acceptsFirstMouse(for event: NSEvent?) -> Bool { true }"),
        "B22 hosting view 同样接受首次点击")

// MARK: C. Settings UI + wiring

let generalSrc = source(root, "\(base)/UI/panes/GeneralPane.swift")
r.check(generalSrc.contains("Slider(value: resultOpacityBinding, in: AppSettings.resultOpacityRange"),
        "C1 通用设置页提供不透明度滑块")
r.check(generalSrc.contains("setResultOpacity"), "C2 滑块/恢复默认写入持久化设置")
r.check(generalSrc.contains("resultPanelResetPosition"), "C3 通用设置页提供重置位置入口")

let storeSrc = source(root, "\(base)/Services/SettingsStore.swift")
r.check(storeSrc.contains("macTranslatorSettingsDidChange") &&
        storeSrc.contains("NotificationCenter.default.post"), "C4 设置写盘后广播变更通知")

let appDelegateSrc = source(root, "\(base)/App/AppDelegate.swift")
r.check(appDelegateSrc.contains("ResultWindowController(settingsStore: settingsStore)"),
        "C5 结果窗注入同一个设置存储实例")

print("ResultPanelVerification: \(r.pass)/\(r.pass + r.fail) PASS, \(r.fail) FAIL")
exit(r.fail == 0 ? 0 : 1)
}
}
