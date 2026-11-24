import AppKit
import SwiftUI
import Foundation

// Standalone structural probe for the floating result window. Compile this
// file together with the real Sources/MacTranslator/UI/Views/ResultView.swift;
// the types below are lightweight stubs for everything else the view touches.

struct AppSettings { static let defaultResultOpacity: Double = 1.0 }
enum SourceType { case selection, ocr }
struct TranslationResult {
    var original: String = ""
    var translated: String = ""
    var sourceType: SourceType = .selection
    var usedEndpointName: String = "智谱翻译"
    var usedModel: String = "glm-4"
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
func collect(_ v: NSView, _ depth: Int, _ out: inout [NSView]) {
    if depth > 16 { return }
    out.append(v)
    for s in v.subviews { collect(s, depth + 1, &out) }
}
func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ num: Int, _ win: Int) -> NSEvent? {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: win, context: nil,
                       eventNumber: num, clickCount: 1, pressure: 1.0)
}

@main
struct Probe {
    @MainActor static func main() {
        let size = NSSize(width: ResultLayout.width, height: ResultLayout.initialWindowHeight)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let vm = ResultViewModel()
        var closed = false
        vm.onClose = { closed = true }
        vm.result = TranslationResult(original: "Mac Translator", translated: "Mac 翻译器")
        let hosting = ProbeHostingView(rootView: ResultView(vm: vm, appearance: ResultAppearance.shared))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        panel.display()
        hosting.layoutSubtreeIfNeeded()

        print("P1 nonactivatingPanel mask accepted = \(panel.styleMask.contains(.nonactivatingPanel))")
        print("P2 borderless mask accepted = \(panel.styleMask.contains(.borderless))")
        print("P3 hosting acceptsFirstMouse = \(hosting.acceptsFirstMouse(for: nil))")

        var nodes: [NSView] = []
        if let cv = panel.contentView { collect(cv, 0, &nodes) }
        let bars = nodes.compactMap { $0 as? ResultTitleBarView }
        print("P4 ResultTitleBarView count = \(bars.count)")
        guard let bar = bars.first else { print("FATAL: no native title bar"); exit(1) }
        print("P5 titleBar acceptsFirstMouse = \(bar.acceptsFirstMouse(for: nil))  isFlipped = \(bar.isFlipped)")

        let barY = size.height - 17
        for x: CGFloat in [20, 120, 300] {
            let hit = hosting.hitTest(NSPoint(x: x, y: barY))
            print("P6 hitTest(\(Int(x)), top-17) => \(hit.map { String(describing: type(of: $0)) } ?? "nil")  isTitleBar=\(hit is ResultTitleBarView)  acceptsFirstMouse=\(hit?.acceptsFirstMouse(for: nil) ?? false)")
        }

        // Close hit area -> real mouse-down must fire onClose.
        let closeWindowPoint = bar.convert(NSPoint(x: 20, y: 17), to: nil)
        if let ev = mouse(.leftMouseDown, closeWindowPoint, 1, panel.windowNumber) {
            bar.mouseDown(with: ev)
        }
        print("P7 mouseDown in close area -> onClose fired = \(closed)")

        // Drag area -> mouseDown / mouseDragged / mouseUp must move the window
        // and post the persistence notification exactly once.
        let dragWindowPoint = bar.convert(NSPoint(x: 200, y: 17), to: nil)
        if let down = mouse(.leftMouseDown, dragWindowPoint, 2, panel.windowNumber),
           let moved = mouse(.leftMouseDragged,
                             NSPoint(x: dragWindowPoint.x - 120, y: dragWindowPoint.y - 80),
                             3, panel.windowNumber),
           let up = mouse(.leftMouseUp,
                          NSPoint(x: dragWindowPoint.x - 120, y: dragWindowPoint.y - 80),
                          4, panel.windowNumber) {
            let before = panel.frame.origin
            var notified = 0
            let observer = NotificationCenter.default.addObserver(
                forName: .resultPanelDidMove, object: nil, queue: nil
            ) { _ in notified += 1 }
            bar.mouseDown(with: down)
            bar.mouseDragged(with: moved)
            let after = panel.frame.origin
            print("P8 drag -> dx=\(Int(after.x - before.x)) dy=\(Int(after.y - before.y)) (expect -120 / -80)")
            bar.mouseUp(with: up)
            NotificationCenter.default.removeObserver(observer)
            print("P9 mouseUp -> resultPanelDidMove posted = \(notified > 0)")
        }

        print("P10 default opacity = \(ResultAppearance.shared.opacity)")
        ResultAppearance.shared.opacity = 0.62
        print("P11 opacity mutable at runtime = \(ResultAppearance.shared.opacity)")
        print("P12 initial window height = \(ResultAppearance.shared.windowHeight), body height = \(ResultAppearance.shared.bodyHeight)")
        panel.close()
    }
}
