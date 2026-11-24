import AppKit
import Foundation
import SwiftUI

@MainActor
final class ResultViewModel: ObservableObject {
    @Published var result: TranslationResult?
    @Published var errorMessage: String?
    @Published var progressText: String?
    @Published var clipboardWarning = ""
    @Published var isFavorite = false
    @Published var toastMessage = ""
    /// Pin keeps the panel on screen when the user clicks elsewhere.
    @Published var isPinned = false
    /// Collapses just the translated text, like the disclosure arrow in Bob.
    @Published var isCollapsed = false
    /// Shows a "open Screen Recording settings" call-to-action on errors.
    @Published var showsPermissionAction = false
    @Published var sourceLanguageLabel = "自动检测"
    @Published var targetLanguageLabel = AppSettings.defaultTargetLanguage

    /// When true, the top card is an editable text view and the window is
    /// allowed to become key. Progress / error / translation states keep this
    /// flag, so a failed request never throws away what the user typed.
    @Published var inputMode = false
    /// Last submitted text; also used to seed the editor when re-opening.
    @Published var inputText = ""

    /// ID of the history record produced by this result, used by the favorite toggle.
    private(set) var recordID: UUID?

    /// Injected by ResultWindowController. Read on each朗读 so a Settings change
    /// applies immediately, even when this panel is already visible.
    var settingsStore: SettingsStoring?

    var onCopy: (() -> Void)?
    var onCopyOriginal: (() -> Void)?
    var onFavorite: ((UUID) -> Void)?
    var onRetranslate: (() -> Void)?
    var onClose: (() -> Void)?
    var onPinChange: ((Bool) -> Void)?
    var onOpenPermissionSettings: (() -> Void)?
    /// Enter in the editable source card, or the "翻译" button.
    var onSubmitInput: ((String) -> Void)?
    /// Toolbar keyboard icon: switch an existing result into typing mode.
    var onStartInput: (() -> Void)?

    func show(
        _ result: TranslationResult,
        recordID: UUID?,
        isFavorite: Bool,
        clipboardFallback: Bool
    ) {
        self.result = result
        self.recordID = recordID
        self.errorMessage = nil
        self.progressText = nil
        self.isFavorite = isFavorite
        self.isCollapsed = false
        self.showsPermissionAction = false
        self.clipboardWarning = clipboardFallback ? "本次取词使用模拟复制，已恢复原剪贴板" : ""
    }

    func showProgress(_ text: String) {
        progressText = text
        errorMessage = nil
        result = nil
        showsPermissionAction = false
    }

    func showError(_ message: String, needsPermissionSettings: Bool = false) {
        errorMessage = message
        progressText = nil
        result = nil
        showsPermissionAction = needsPermissionSettings
    }

    /// Opens (or re-opens) the editable card. `initialText` lets the toolbar
    /// carry an existing original into the editor for a quick correction.
    func showInput(initialText: String = "") {
        result = nil
        errorMessage = nil
        progressText = nil
        clipboardWarning = ""
        showsPermissionAction = false
        isCollapsed = false
        isFavorite = false
        recordID = nil
        inputMode = true
        inputText = initialText
    }

    /// Leaves typing mode without closing the window, e.g. when a selection
    /// hotkey fires while the input card is open.
    func endInputMode() {
        inputMode = false
        inputText = ""
    }

    func submitInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toastMessage = "请先输入要翻译的文字"
            return
        }
        inputText = trimmed
        onSubmitInput?(trimmed)
    }

    func startInputAction() {
        onStartInput?()
    }

    func clear() {
        result = nil
        errorMessage = nil
        progressText = nil
        clipboardWarning = ""
        isFavorite = false
        isCollapsed = false
        showsPermissionAction = false
        recordID = nil
        inputMode = false
        inputText = ""
        // isPinned deliberately survives: it is a window-level preference,
        // not a property of one translation result.
    }

    func copyAction() {
        guard result != nil else { return }
        onCopy?()
        toastMessage = "已复制译文到剪贴板"
    }

    func copyOriginalAction() {
        guard result != nil else { return }
        onCopyOriginal?()
        toastMessage = "已复制原文到剪贴板"
    }

    func favoriteAction() {
        guard let recordID else { return }
        isFavorite.toggle()
        onFavorite?(recordID)
        toastMessage = isFavorite ? "已加入收藏" : "已取消收藏"
    }

    func retranslateAction() {
        onRetranslate?()
    }

    func closeAction() {
        onClose?()
    }

    func togglePinAction() {
        isPinned.toggle()
        onPinChange?(isPinned)
        toastMessage = isPinned ? "已固定窗口" : "已取消固定"
    }

    func toggleCollapsed() {
        isCollapsed.toggle()
    }

    func openPermissionSettingsAction() {
        onOpenPermissionSettings?()
    }

    /// Speaks the original or translated text with the user-chosen voice family.
    /// The old implementation grabbed the first en/zh voice in `availableVoices`,
    /// which on macOS 15 is a novelty effect voice ("Albert") for English.
    func speakAction(_ text: String) {
        let family = SpeechVoiceFamily.from(settingsStore?.current.speechVoiceFamily)
        SpeechVoiceService.shared.speak(text, family: family)
    }
}
