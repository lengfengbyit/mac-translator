import AppKit
import CoreGraphics
import SwiftUI
import Foundation

// Renders the REAL ResultView in three states and captures each window so the
// card layout / content-driven height can be inspected visually.
// Compile together with Sources/MacTranslator/UI/Views/ResultView.swift.

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
}
struct Badge: View {
    let text: String
    let tint: Color
    var body: some View { Text(text).font(.system(size: 10)).foregroundColor(tint) }
}
struct LLMTag: View {
    let label: String
    let degradedFrom: String?
    var body: some View { Text(label).font(.system(size: 10)) }
}
final class ProbeHostingView: NSHostingView<ResultView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private func savePNG(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

@main
struct ResultVisualProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Command line tools have no bundle/appearance of their own; force the
        // light appearance the user actually runs in.
        app.appearance = NSAppearance(named: .aqua)

        let initial = NSSize(width: ResultLayout.width, height: ResultLayout.initialWindowHeight)
        let panel = NSPanel(
            contentRect: NSRect(x: 900, y: 360, width: initial.width, height: initial.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let vm = ResultViewModel()
        let hosting = ProbeHostingView(rootView: ResultView(vm: vm, appearance: ResultAppearance.shared))
        hosting.frame = NSRect(origin: .zero, size: initial)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // Mirrors ResultWindowController.applyMeasuredHeight.
        ResultAppearance.shared.onContentHeightChange = { [weak panel] height in
            guard let panel else { return }
            let body = min(max(height, ResultLayout.minBodyHeight), ResultLayout.maxBodyHeight)
            let total = body + ResultLayout.titleBarHeight
            guard abs(total - panel.frame.height) > 0.5 else { return }
            let frame = panel.frame
            ResultAppearance.shared.bodyHeight = body
            ResultAppearance.shared.windowHeight = total
            panel.setFrame(
                NSRect(x: frame.minX, y: frame.maxY - total, width: ResultLayout.width, height: total),
                display: true
            )
        }

        panel.orderFrontRegardless()
        panel.display()
        hosting.layoutSubtreeIfNeeded()

        let states: [(String, () -> Void)] = [
            ("result", {
                vm.result = TranslationResult(original: "Mac Translator", translated: "Mac 翻译器")
            }),
            ("long", {
                vm.result = TranslationResult(
                    original: "The quick brown fox jumps over the lazy dog, and then keeps running across the field until the sun goes down.",
                    translated: "敏捷的棕色狐狸跳过了那只懒狗，然后继续穿过田野奔跑，直到太阳落下山去。这是一段用来验证长文本时窗口是否仍保持紧凑、且译文区可内部滚动的示例文字。"
                )
            }),
            ("permission_error", {
                vm.result = nil
                vm.progressText = nil
                vm.errorMessage = "屏幕录制权限未开启。请在「系统设置 › 隐私与安全性 › 屏幕录制」中打开「划译」，然后重试 OCR。"
                vm.showsPermissionAction = true
            }),
            ("progress", {
                vm.result = nil
                vm.errorMessage = nil
                vm.showsPermissionAction = false
                vm.progressText = "正在尝试第 1/2 个接口：GLM"
            })
        ]

        for (index, state) in states.enumerated() {
            state.1()
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.7, false)
            panel.display()
            hosting.layoutSubtreeIfNeeded()
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.4, false)

            let height = panel.frame.height
            print("V\(index) state=\(state.0) windowHeight=\(Int(height)) bodyHeight=\(Int(ResultAppearance.shared.bodyHeight))")

            let mainTop = NSScreen.main?.frame.maxY ?? 1080
            let frame = panel.frame
            let pad: CGFloat = 22
            let cgRect = CGRect(
                x: frame.minX - pad,
                y: mainTop - frame.maxY - pad,
                width: frame.width + pad * 2,
                height: frame.height + pad * 2
            )
            if let image = CGWindowListCreateImage(
                cgRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
            ) {
                savePNG(image, "/tmp/mt_result_\(state.0).png")
                print("   saved /tmp/mt_result_\(state.0).png")
            }
        }
        panel.close()
    }
}
