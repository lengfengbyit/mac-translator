import Foundation
import SwiftUI

/// Composition of selection/OCR/typed input -> gateway -> floating result -> history.
@MainActor
final class AppCoordinator {
    private enum LastAction {
        case selection
        case ocr
        case input
    }

    private let gateway: LLMProviding
    private let selector: TextSelecting
    private let ocrService: OCRServing
    private let historyStore: HistoryStoring
    private let settingsStore: SettingsStoring
    private let permissions: PermissionService
    private let resultWindow: ResultWindowController

    private var currentToken: CancellationTokenSource?
    private var lastRequest: TranslateRequest?
    private var lastAction: LastAction?

    init(
        gateway: LLMProviding,
        selector: TextSelecting,
        ocrService: OCRServing,
        historyStore: HistoryStoring,
        settingsStore: SettingsStoring,
        permissions: PermissionService,
        resultWindow: ResultWindowController
    ) {
        self.gateway = gateway
        self.selector = selector
        self.ocrService = ocrService
        self.historyStore = historyStore
        self.settingsStore = settingsStore
        self.permissions = permissions
        self.resultWindow = resultWindow

        resultWindow.onToggleFavorite = { [weak self] recordID in
            try? self?.historyStore.toggleFavorite(id: recordID)
        }
        resultWindow.onRetranslate = { [weak self] in
            Task { await self?.retranslate() }
        }
        resultWindow.onSubmitInput = { [weak self] text in
            Task { await self?.submitInput(text) }
        }
    }

    // MARK: Entry points

    func handleSelection() async {
        await handleSelection(forceFresh: false)
    }

    func handleOCR() async {
        await handleOCR(forceFresh: false)
    }

    /// Opens the result window in typing mode. No permission or selection is
    /// needed: the panel becomes key so the editable source card can receive
    /// keystrokes, then Enter submits through the normal translation pipeline.
    func handleInput() {
        resultWindow.showInput()
    }

    func submitInput(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let request = makeRequest(text: trimmed, sourceType: .input, forceFresh: false)
        await execute(request, clipboardFallback: false, action: .input)
    }

    func retranslate() async {
        guard let lastRequest, let lastAction else { return }
        switch lastAction {
        case .selection, .input:
            var request = lastRequest
            request.forceFresh = true
            await execute(request, clipboardFallback: false, action: lastAction)
        case .ocr:
            await handleOCR(forceFresh: true)
        }
    }

    func cancel() {
        currentToken?.cancel()
        gateway.cancelActiveTask()
        resultWindow.showError("已取消本次翻译")
    }

    func toggleFavorite(id: UUID) {
        try? historyStore.toggleFavorite(id: id)
    }

    // MARK: Internals

    private func handleOCR(forceFresh: Bool) async {
        let status = permissions.status(type: .screenRecording)
        guard status.isGranted else {
            permissions.requestIfNeeded(type: .screenRecording)
            resultWindow.showError(
                OCRServiceError.screenRecordingDenied.errorDescription ?? "需授予屏幕录制权限后才能使用 OCR",
                needsPermissionSettings: true
            )
            return
        }

        // Keep the floating result out of the way while the dimming overlay is
        // up: showing it first used to put a 440x470 panel behind a
        // screenSaver-level overlay and its global click monitor could clear
        // the in-flight progress state mid-selection.
        resultWindow.close()
        let request = makeRequest(text: "", sourceType: .ocr, forceFresh: forceFresh)
        do {
            resultWindow.showProgress("正在识别文字…", present: false)
            let result = try await ocrService.recognizeAndTranslate(
                mode: settingsStore.current.ocrMode,
                req: request,
                progress: { [weak self] index, total, name in
                    Task { @MainActor in
                        self?.resultWindow.showProgress("正在尝试第 \(index)/\(total) 个接口：\(name)")
                    }
                }
            )
            finish(result, clipboardFallback: false, action: .ocr)
        } catch {
            handleError(error)
        }
    }

    private func handleSelection(forceFresh: Bool) async {
        // A selection hotkey pressed while the input card is open switches the
        // panel back to a non-focus-stealing, read-only result window.
        resultWindow.endInputMode()
        resultWindow.showProgress("正在获取选中文本…")
        let selection = await selector.selectText()
        guard !selection.isEmpty else {
            resultWindow.showError("无法获取选中文本，请尝试 OCR 翻译或输入翻译")
            return
        }
        let request = makeRequest(
            text: selection.text,
            sourceType: .selection,
            forceFresh: forceFresh
        )
        await execute(request, clipboardFallback: selection.usedClipboardFallback, action: .selection)
    }

    private func makeRequest(
        text: String,
        sourceType: SourceType,
        forceFresh: Bool
    ) -> TranslateRequest {
        let settings = settingsStore.current
        return TranslateRequest(
            text: text,
            sourceLang: settings.effectiveSourceLanguage,
            targetLang: settings.targetLanguage,
            sourceType: sourceType,
            forceFresh: forceFresh
        )
    }

    private func execute(
        _ request: TranslateRequest,
        clipboardFallback: Bool,
        action: LastAction
    ) async {
        let token = CancellationTokenSource()
        currentToken = token
        do {
            let result = try await gateway.translate(
                request,
                progress: { [weak self] index, total, name in
                    Task { @MainActor in
                        self?.resultWindow.showProgress("正在尝试第 \(index)/\(total) 个接口：\(name)")
                    }
                },
                cancel: token
            )
            finish(result, clipboardFallback: clipboardFallback, action: action)
        } catch {
            handleError(error)
        }
    }

    private func finish(
        _ result: TranslationResult,
        clipboardFallback: Bool,
        action: LastAction
    ) {
        let record = HistoryRecord(
            original: result.original,
            translated: result.translated,
            sourceType: result.sourceType,
            interfaceName: result.llmLabel,
            degradedFrom: result.degradedFromName,
            isFavorite: false,
            ocrMode: action == .ocr ? settingsStore.current.ocrMode : nil
        )
        try? historyStore.save(record)
        lastRequest = TranslateRequest(
            requestId: UUID(),
            text: result.original,
            sourceLang: settingsStore.current.effectiveSourceLanguage,
            targetLang: settingsStore.current.targetLanguage,
            sourceType: result.sourceType,
            forceFresh: false
        )
        lastAction = action
        resultWindow.show(
            result,
            recordID: record.id,
            isFavorite: false,
            clipboardFallback: clipboardFallback
        )
    }

    private func handleError(_ error: Error) {
        let needsSettings = (error as? OCRServiceError)?.isPermissionIssue ?? false
        let message: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = "翻译失败：\(error.localizedDescription)"
        }
        resultWindow.showError(message, needsPermissionSettings: needsSettings)
    }
}
