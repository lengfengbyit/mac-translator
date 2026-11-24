import AppKit
import SwiftUI

/// Live appearance of the floating result window. Shared so the Settings pane
/// can change the backdrop while the result window is already on screen, and
/// so the controller can resize the panel to fit the card stack.
@MainActor
final class ResultAppearance: ObservableObject {
    static let shared = ResultAppearance()
    @Published var opacity: Double = AppSettings.defaultResultOpacity
    @Published var bodyHeight: CGFloat = ResultLayout.initialBodyHeight
    @Published var windowHeight: CGFloat = ResultLayout.initialWindowHeight
    /// Wired by ResultWindowController. Receives the natural height of the
    /// content stack (not the ScrollView frame), so resizing cannot feed back
    /// into the measurement and oscillate.
    var onContentHeightChange: ((CGFloat) -> Void)?
    private init() {}
}

/// Geometry contract for the content-driven result window.
enum ResultLayout {
    static let width: CGFloat = 440
    static let titleBarHeight: CGFloat = 38
    static let minBodyHeight: CGFloat = 92
    static let maxBodyHeight: CGFloat = 540
    static let initialBodyHeight: CGFloat = 150
    static let initialWindowHeight: CGFloat = initialBodyHeight + titleBarHeight
}

private struct ResultContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension Notification.Name {
    /// Posted once when a user drag ends; the controller persists the origin.
    static let resultPanelDidMove = Notification.Name("MacTranslatorResultPanelDidMove")
    /// Posted by the Settings pane to forget the saved window position.
    static let resultPanelResetPosition = Notification.Name("MacTranslatorResultPanelResetPosition")
}

// MARK: - Editable source card (typed-input mode)

/// The controller needs to make the AppKit text view first responder after the
/// SwiftUI hierarchy has mounted. A weak registry avoids forcing a hosting
/// controller into the panel just for focus handling.
@MainActor
final class InputEditorRegistry {
    static let shared = InputEditorRegistry()
    weak var textView: NSTextView?
    private init() {}
}

/// NSTextView with a deliberate Enter contract:
///   • Return            -> submit (unless an IME is composing candidates)
///   • Shift + Return    -> insert a real newline
///   • everything else   -> stock AppKit editing (⌘V / ⌘A / Delete all work)
///
/// SwiftUI's TextEditor cannot express "Return submits but marked text does
/// not", which is why this is AppKit-backed.
/// Kept internal (not private) so the offline focus probe can drive real
/// Return / Shift+Return / IME-composition events through it.
final class SubmitTextView: NSTextView {
    var onSubmit: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        // With a Chinese/Japanese IME, Return confirms the candidate word.
        // Submitting here would translate half-finished pinyin every time.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 36 { // kVK_Return
            if event.modifierFlags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onSubmit?(string)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Some input methods route Return through the command dispatcher.
        if selector == NSSelectorFromString("insertNewline:") {
            if hasMarkedText() {
                super.doCommand(by: selector)
            } else {
                onSubmit?(string)
            }
            return
        }
        super.doCommand(by: selector)
    }
}

/// Wraps an NSScrollView + NSTextView. The draft text lives in AppKit and is
/// only pushed into SwiftUI on submit, so typing never re-renders the whole
/// card stack (the original settings-input bug was a per-keystroke redraw).
struct InputEditor: NSViewRepresentable {
    let initialText: String
    let onSubmit: (String) -> Void

    final class Coordinator {
        var lastProgrammaticText: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 72))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // A translator should receive exactly what was typed, not smart
        // quotes, autocorrect or auto-dashes.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = initialText
        textView.onSubmit = onSubmit
        scroll.documentView = textView

        InputEditorRegistry.shared.textView = textView
        context.coordinator.lastProgrammaticText = initialText
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        InputEditorRegistry.shared.textView = textView
        if initialText != context.coordinator.lastProgrammaticText {
            context.coordinator.lastProgrammaticText = initialText
            if textView.string != initialText {
                textView.string = initialText
            }
        }
    }
}

/// Native title bar for the result window: a real close hit area plus a
/// classic drag loop. Everything here is AppKit, so clicks never depend on
/// SwiftUI gesture delivery inside a non-activating panel.
final class ResultTitleBarView: NSView {
    var onClose: (() -> Void)?

    private let closeRect = NSRect(x: 12, y: 9, width: 16, height: 16)
    private var hoveringClose = false
    private var trackingArea: NSTrackingArea?
    private var dragStartOrigin = NSPoint.zero
    private var dragStartScreen = NSPoint.zero
    private var dragging = false
    private var moved = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: closeRect)
        (hoveringClose ? NSColor.systemRed : NSColor.systemRed.withAlphaComponent(0.85)).setFill()
        circle.fill()

        let cross = NSBezierPath()
        let inset: CGFloat = 4.5
        cross.move(to: NSPoint(x: closeRect.minX + inset, y: closeRect.minY + inset))
        cross.line(to: NSPoint(x: closeRect.maxX - inset, y: closeRect.maxY - inset))
        cross.move(to: NSPoint(x: closeRect.maxX - inset, y: closeRect.minY + inset))
        cross.line(to: NSPoint(x: closeRect.minX + inset, y: closeRect.maxY - inset))
        cross.lineWidth = hoveringClose ? 2.0 : 1.4
        NSColor.white.setStroke()
        cross.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: closeRect.insetBy(dx: -6, dy: -6),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoveringClose = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveringClose = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -6, dy: -6).contains(local) {
            onClose?()
            return
        }

        // Track the drag through normal AppKit event delivery rather than a
        // blocking nextEvent loop: the run loop keeps running, so the window
        // follows the cursor smoothly. Coordinates come from the events
        // themselves (not the global cursor position, which lags on fast drags).
        dragStartOrigin = window.frame.origin
        dragStartScreen = NSPoint(
            x: dragStartOrigin.x + event.locationInWindow.x,
            y: dragStartOrigin.y + event.locationInWindow.y
        )
        dragging = true
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let window else { return }
        let origin = window.frame.origin
        let currentScreen = NSPoint(
            x: origin.x + event.locationInWindow.x,
            y: origin.y + event.locationInWindow.y
        )
        let dx = currentScreen.x - dragStartScreen.x
        let dy = currentScreen.y - dragStartScreen.y
        if abs(dx) > 0.5 || abs(dy) > 0.5 { moved = true }
        window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging && moved {
            NotificationCenter.default.post(name: .resultPanelDidMove, object: nil)
        }
        dragging = false
        moved = false
    }
}

struct ResultTitleBar: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ResultTitleBarView {
        let view = ResultTitleBarView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ResultTitleBarView, context: Context) {
        nsView.onClose = onClose
    }
}

/// Card-based result window, modelled on Bob: a compact toolbar, a source
/// card, a language bar and a translation card. The panel grows and shrinks
/// with the cards, so short results no longer sit on top of 300 px of nothing.
/// In typed-input mode the read-only source card is swapped for an editable
/// one; the translation card, language bar and toolbar are reused as-is.
struct ResultView: View {
    @ObservedObject var vm: ResultViewModel
    @ObservedObject var appearance: ResultAppearance

    var body: some View {
        VStack(spacing: 0) {
            toolBar
                .frame(height: ResultLayout.titleBarHeight)
                .background(ResultTitleBar(onClose: { vm.closeAction() }))
            ScrollView(.vertical, showsIndicators: false) {
                contentStack
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ResultContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .frame(height: appearance.bodyHeight)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(appearance.opacity))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
        )
        .frame(width: ResultLayout.width, height: appearance.windowHeight)
        .onPreferenceChange(ResultContentHeightKey.self) { height in
            guard height > 0 else { return }
            appearance.onContentHeightChange?(height)
        }
        .overlay(alignment: .bottom) {
            if !vm.toastMessage.isEmpty {
                Text(vm.toastMessage)
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.72))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            vm.toastMessage = ""
                        }
                    }
            }
        }
    }

    // MARK: Toolbar

    /// The native drag/close view sits behind this HStack. Labels and spacers
    /// are hit-testing disabled so a press on empty toolbar space reaches it,
    /// while the icon buttons keep their own hit targets.
    private var toolBar: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 30)
                .allowsHitTesting(false)
            toolButton(
                vm.isPinned ? "pin.fill" : "pin",
                active: vm.isPinned,
                help: "固定窗口（点击其他位置不自动关闭）"
            ) { vm.togglePinAction() }
            toolButton(
                vm.isFavorite ? "star.fill" : "star",
                active: vm.isFavorite,
                enabled: vm.result != nil,
                help: "收藏这条翻译"
            ) { vm.favoriteAction() }
            toolButton(
                "doc.on.doc",
                enabled: vm.result != nil,
                help: "复制译文"
            ) { vm.copyAction() }
            toolButton(
                "arrow.clockwise",
                enabled: vm.result != nil,
                help: "重新翻译"
            ) { vm.retranslateAction() }
            toolButton(
                "keyboard",
                active: vm.inputMode,
                help: "输入翻译（打开输入框）"
            ) { vm.startInputAction() }
            Spacer(minLength: 4)
                .allowsHitTesting(false)
            if vm.inputMode {
                Text("⌨ 输入")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            } else if let result = vm.result {
                Text(result.sourceType == .ocr ? "🔍 OCR" : "✂️ 划词")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
            if !vm.inputMode {
                Text("拖动移动")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
    }

    private func toolButton(
        _ system: String,
        active: Bool = false,
        enabled: Bool = true,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? .accentColor : .secondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: Cards

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The editable card stays on screen during progress / error / result
            // states, so a failed request never discards the typed text.
            if vm.inputMode {
                inputCard
            }
            if let progress = vm.progressText {
                statusCard(text: progress, showsProgress: true)
            } else if let error = vm.errorMessage {
                errorCard(error)
            } else if let result = vm.result {
                if !vm.inputMode {
                    sourceCard(result.original)
                }
                languageBar
                translationCard(result)
                if !vm.clipboardWarning.isEmpty {
                    Text(vm.clipboardWarning)
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                }
            } else if !vm.inputMode {
                statusCard(
                    text: "⌥⇧I 输入翻译 · ⌥D 划词翻译 · ⌥⇧S 截图 OCR",
                    showsProgress: false
                )
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
    }

    /// Reuses the exact source-card shell, but its body is an editor instead
    /// of static text. Enter submits; the "翻译" button is a mouse-friendly
    /// equivalent reading the live AppKit draft.
    private var inputCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text("输入原文")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Button("翻译") {
                        let draft = InputEditorRegistry.shared.textView?.string ?? vm.inputText
                        vm.submitInput(draft)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                InputEditor(initialText: vm.inputText) { text in
                    vm.submitInput(text)
                }
                .frame(height: 72)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
                )
                HStack(spacing: 10) {
                    Text("⏎ 翻译")
                        .font(.system(size: 10.5))
                        .foregroundColor(.accentColor)
                    Text("⇧⏎ 换行")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Text("Esc 关闭")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                }
            }
        }
    }

    private func statusCard(text: String, showsProgress: Bool) -> some View {
        card {
            HStack(spacing: 9) {
                if showsProgress {
                    ProgressView()
                        .scaleEffect(0.75, anchor: .center)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    Text("翻译未完成")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if vm.showsPermissionAction {
                    Button("打开屏幕录制设置") { vm.openPermissionSettingsAction() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    private func sourceCard(_ original: String) -> some View {
        let isImageOnly = original == "[图片]"
        return card {
            VStack(alignment: .leading, spacing: 10) {
                Text(isImageOnly ? "图片内容（多模态识别）" : original)
                    .font(.system(size: 15))
                    .foregroundColor(isImageOnly ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    smallIconButton("speaker.wave.2", "朗读原文") {
                        vm.speakAction(isImageOnly ? "" : original)
                    }
                    smallIconButton("doc.on.doc", "复制原文") { vm.copyOriginalAction() }
                    Spacer(minLength: 4)
                    Text(vm.sourceLanguageLabel == "自动检测"
                         ? "自动检测语言"
                         : "识别为 \(vm.sourceLanguageLabel)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            Text(vm.sourceLanguageLabel)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 6)
            Text(vm.targetLanguageLabel)
                .font(.system(size: 12.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func translationCard(_ result: TranslationResult) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text(result.usedEndpointName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(result.usedModel)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { vm.toggleCollapsed() } label: {
                        Image(systemName: vm.isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(vm.isCollapsed ? "展开译文" : "收起译文")
                }
                if !vm.isCollapsed {
                    Text(result.translated)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        smallIconButton("speaker.wave.2", "朗读译文") {
                            vm.speakAction(result.translated)
                        }
                        smallIconButton("doc.on.doc", "复制译文") { vm.copyAction() }
                        smallIconButton("arrow.clockwise", "重新翻译") { vm.retranslateAction() }
                        Spacer(minLength: 4)
                        if let degraded = result.degradedFromName, !degraded.isEmpty {
                            Text("降级自 \(degraded)")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        }
                        let elapsed = String(format: "%.1f", result.elapsed)
                        Text(result.cached ? "缓存 · \(elapsed)s" : "\(elapsed)s")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func smallIconButton(
        _ system: String,
        _ help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
