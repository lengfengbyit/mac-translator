import CoreGraphics
import Foundation
import Vision

// Offline regression for the OCR + result-window overhaul:
//   1. screen recording permission is read from TCC, never guessed from pixels
//   2. capture uses ScreenCaptureKit with multi-display aware coordinates
//   3. Vision output is reconstructed in reading order
//   4. the result window is card based and sized by its content
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
struct OCRAndResultLayoutVerification {
    static func main() {
        let r = Counter()
        let root = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath
        let base = "Sources/MacTranslator"

        // MARK: A. Permission detection

        let perm = source(root, "\(base)/Services/PermissionService.swift")
        r.check(perm.contains("CGPreflightScreenCaptureAccess() ? .granted : .denied"),
                "A1 屏幕录制权限直接查询 TCC，不再依赖截图内容")
        r.check(!perm.contains("CGWindowListCreateImage") && !perm.contains("calibratedWhite"),
                "A2 已移除『截图是否全黑』的误判启发式")
        r.check(perm.contains("CGRequestScreenCaptureAccess()"),
                "A3 未授权时主动触发系统授权弹窗")
        r.check(perm.contains("func openScreenRecordingSettings()"),
                "A4 提供一键跳转屏幕录制设置的入口")

        // MARK: B. Capture pipeline

        let cap = source(root, "\(base)/Services/ScreenCaptureService.swift")
        r.check(cap.contains("import ScreenCaptureKit"), "B1 引入 ScreenCaptureKit")
        r.check(cap.contains("SCScreenshotManager.captureImage(in: cgRect)"),
                "B2 主路径使用 SCScreenshotManager（替代已 obsolete 的窗口列表 API）")
        r.check(cap.contains("CGWindowListCreateImage(rect,") && cap.contains("legacyCapture"),
                "B3 旧系统 / SCK 失败时保留回退路径")
        r.check(cap.contains("NSScreen.screens") && cap.contains("for screen in targets"),
                "B4 为每个屏幕创建框选遮罩")
        r.check(cap.contains("screenOrigin"), "B5 窗口内坐标加上屏幕原点得到全局坐标")
        r.check(cap.contains("displaySpaceRect") && cap.contains("mainTop - rect.maxY"),
                "B6 AppKit 左下原点正确转换为 CG/SC 左上原点")
        r.check(cap.contains("Task.sleep(nanoseconds:"),
                "B7 截图前等待遮罩从 WindowServer 合成中消失")
        r.check(cap.contains("override var canBecomeKey: Bool { true }"),
                "B8 无边框遮罩窗口可成为 key（Esc 生效）")
        r.check(cap.contains("addLocalMonitorForEvents(matching: .keyDown)"),
                "B9 本地 Esc 监听覆盖多屏任意焦点窗口")
        r.check(cap.contains("rightMouseDown(with event: NSEvent)"),
                "B10 支持右键取消框选")
        r.check(cap.contains("NSCursor.crosshair"), "B11 框选时显示十字光标")
        r.check(cap.contains("drawBadge"), "B12 框选时显示尺寸提示")
        r.check(!cap.contains("isFlipped: Bool { true }"),
                "B13 遮罩视图保持非翻转，避免纵坐标被反转")

        // MARK: C. Vision recognition (real compiled behaviour)

        let vision = source(root, "\(base)/Services/VisionOCRService.swift")
        r.check(vision.contains("readingOrder(items)"), "C1 结果按阅读顺序重排")
        r.check(vision.contains("confidence >= 0.25"), "C2 过滤低置信度乱码")
        r.check(vision.contains("upscaleForRecognition"), "C3 小图放大后再识别")
        r.check(vision.contains("usesLanguageCorrection = true"), "C4 启用语言校正")

        let shuffled = [
            VisionOCRService.LineItem(text: "World", box: CGRect(x: 0.5, y: 0.88, width: 0.2, height: 0.05)),
            VisionOCRService.LineItem(text: "第二行", box: CGRect(x: 0.1, y: 0.45, width: 0.3, height: 0.05)),
            VisionOCRService.LineItem(text: "Hello", box: CGRect(x: 0.1, y: 0.88, width: 0.2, height: 0.05))
        ]
        let ordered = VisionOCRService.readingOrder(shuffled)
        r.check(ordered == "Hello World\n第二行",
                "C5 乱序 observations 还原为正确阅读顺序（实际：\(ordered.debugDescription)）")
        r.check(VisionOCRService.readingOrder([]) == "", "C6 空识别结果返回空字符串")

        // MARK: D. Result window layout

        let view = source(root, "\(base)/UI/Views/ResultView.swift")
        r.check(!view.contains("height: 470") && !view.contains("minHeight: 180"),
                "D1 移除固定高度与撑高空白的 minHeight")
        r.check(view.contains("sourceCard") && view.contains("languageBar") && view.contains("translationCard"),
                "D2 Bob 风格三段卡片布局：原文 / 语言栏 / 译文")
        r.check(view.contains("ResultContentHeightKey") && view.contains("onContentHeightChange"),
                "D3 内容高度通过 PreferenceKey 回传给窗口控制器")
        r.check(view.contains("ScrollView(.vertical") && view.contains(".frame(height: appearance.bodyHeight)"),
                "D4 超长内容在内容区内滚动，窗口高度由控制器给定")
        r.check(view.contains("toolButton") && view.contains("togglePinAction"),
                "D5 顶部图标工具栏（固定 / 收藏 / 复制 / 重译）")
        r.check(view.contains("chevron.up"), "D6 译文卡片支持折叠")
        r.check(view.contains("showsPermissionAction") && view.contains("打开屏幕录制设置"),
                "D7 权限错误提供跳转按钮")
        r.check(view.contains("speakAction"), "D8 原文 / 译文支持朗读")
        r.check(view.contains("Color(nsColor: .windowBackgroundColor).opacity(appearance.opacity)"),
                "D9 透明度设置仍然生效")

        let ctrl = source(root, "\(base)/UI/Windows/ResultWindowController.swift")
        r.check(ctrl.contains("private func applyMeasuredHeight"),
                "D10 控制器按内容高度调整面板尺寸")
        r.check(ctrl.contains("ResultLayout.maxBodyHeight"),
                "D10b 窗口高度有上限，长文本不会撑满屏幕")
        r.check(ctrl.contains("let top = panel.frame.maxY") && ctrl.contains("y: top - total"),
                "D11 调整高度时保持顶边不动，窗口不跳位")
        r.check(ctrl.contains("present shouldPresent: Bool = true"),
                "D12 框选阶段只更新进度、不弹出结果窗")
        r.check(ctrl.contains("!self.isPinned"), "D13 图钉固定时点击外部不关闭")
        r.check(ctrl.contains("sourceLanguageLabel") && ctrl.contains("targetLanguageLabel"),
                "D14 语言栏显示当前源 / 目标语言")

        let coord = source(root, "\(base)/App/AppCoordinator.swift")
        r.check(coord.contains("needsPermissionSettings: true"),
                "D15 权限被拒时给出明确指引而非笼统报错")
        r.check(coord.contains("present: false"), "D16 框选阶段结果窗保持隐藏")
        r.check(coord.contains("resultWindow.close()"), "D17 框选前收起旧结果窗")

        let ocr = source(root, "\(base)/Services/OCRService.swift")
        r.check(ocr.contains("CGPreflightScreenCaptureAccess()"),
                "D18 截图前二次校验权限，避免空图进入 LLM")
        r.check(ocr.contains("try? await vision.recognize(image: sourceImage)"),
                "D19 多模态模式也用本地识别填充原文卡片")

        // MARK: F. Hotkey collision + always-reachable menu entry

        let hotkey = source(root, "\(base)/Services/HotkeyService.swift")
        r.check(hotkey.contains("private static let fallbacks"),
                "F1 为被占用的默认快捷键准备候选组合（Bob 默认占用 ⌥D）")
        r.check(hotkey.contains("registerWithFallback"),
                "F2 注册失败时自动避让而非留下死快捷键")
        r.check(hotkey.contains("settingsStore.update(updated)"),
                "F3 实际生效的组合写回配置，设置页显示真实值")

        let menu = source(root, "\(base)/App/MenuBarController.swift")
        r.check(menu.contains("menu.item(withTag: 2)?.isEnabled = true"),
                "F4 OCR 菜单项不再因权限缺失变灰")
        r.check(menu.contains("需屏幕录制权限"), "F5 菜单标题直接标出缺失的权限")
        r.check(menu.contains("setHotkeyNotice"), "F6 菜单栏提示快捷键已调整")

        let delegate = source(root, "\(base)/App/AppDelegate.swift")
        r.check(delegate.contains("menuBar.setHotkeyNotice("),
                "F7 启动时同步快捷键调整提示")

        print("OCRAndResultLayoutVerification: \(r.pass)/\(r.pass + r.fail) PASS, \(r.fail) FAIL")
        exit(r.fail == 0 ? 0 : 1)
    }
}
