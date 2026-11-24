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

    /// ID of the history record produced by this result, used by the favorite toggle.
    private(set) var recordID: UUID?

    var onCopy: (() -> Void)?
    var onCopyOriginal: (() -> Void)?
    var onFavorite: ((UUID) -> Void)?
    var onRetranslate: (() -> Void)?
    var onClose: (() -> Void)?
    var onPinChange: ((Bool) -> Void)?
    var onOpenPermissionSettings: (() -> Void)?

    private let synthesizer = NSSpeechSynthesizer()

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

    func clear() {
        result = nil
        errorMessage = nil
        progressText = nil
        clipboardWarning = ""
        isFavorite = false
        isCollapsed = false
        showsPermissionAction = false
        recordID = nil
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

    /// Speaks the original or translated text with a language-matched system voice.
    func speakAction(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() }
        let wantsChinese = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let prefix = wantsChinese ? "zh" : "en"
        if let voice = NSSpeechSynthesizer.availableVoices.first(where: { name in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: name)
            return (attributes[.localeIdentifier] as? String)?.hasPrefix(prefix) == true
        }) {
            synthesizer.setVoice(voice)
        }
        synthesizer.startSpeaking(trimmed)
    }
}
