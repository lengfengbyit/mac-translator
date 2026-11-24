import AppKit
import CoreGraphics
import Foundation

/// Dual-mode OCR pipeline. Capture is shared by both modes; cancellation produces no LLM request.
final class OCRService: OCRServing {
    private let capture: ScreenCaptureService
    private let vision: VisionOCRService
    private let gateway: LLMProviding
    private let settingsStore: SettingsStoring
    private let permission: PermissionService?

    init(
        capture: ScreenCaptureService,
        vision: VisionOCRService,
        gateway: LLMProviding,
        settingsStore: SettingsStoring,
        permission: PermissionService? = nil
    ) {
        self.capture = capture
        self.vision = vision
        self.gateway = gateway
        self.settingsStore = settingsStore
        self.permission = permission
    }

    /// Current mode from persisted settings; useful for callers that need to display it.
    var preferredMode: OCRMode { settingsStore.current.ocrMode }

    func recognizeAndTranslate(
        mode: OCRMode,
        req: TranslateRequest,
        progress: ((Int, Int, String) -> Void)?
    ) async throws -> TranslationResult {
        try await recognizeAndTranslate(mode: mode, req: req, image: nil, progress: progress)
    }

    /// Variant for a pre-captured image (used by tests and UI reuse).
    func recognizeAndTranslate(
        mode: OCRMode,
        req: TranslateRequest,
        image: CGImage?,
        progress: ((Int, Int, String) -> Void)?
    ) async throws -> TranslationResult {
        let sourceImage: CGImage
        if let image {
            sourceImage = image
        } else {
            // Ask TCC directly. The old black-pixel heuristic in
            // PermissionService could report "granted" for a denied app and
            // let an empty-wallpaper screenshot through to the LLM.
            guard CGPreflightScreenCaptureAccess() else {
                throw OCRServiceError.screenRecordingDenied
            }
            guard let captured = try await capture.captureArea() else {
                throw OCRServiceError.captureCancelled
            }
            sourceImage = captured
        }

        let token = CancellationTokenSource()
        var request = req
        request.sourceType = .ocr

        switch mode {
        case .localVision:
            let text = try await vision.recognize(image: sourceImage)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OCRServiceError.emptyRecognition
            }
            request.text = text
            return try await gateway.translate(request, progress: progress, cancel: token)

        case .multimodalLLM:
            guard let jpeg = sourceImage.multimodalJPEGData() else {
                throw OCRServiceError.imageConversionFailed
            }
            // A local pass gives the result card real source text at zero
            // network cost. The image (not this text) is what the model reads,
            // and the image hash - not the text - remains the cache key.
            let preview = (try? await vision.recognize(image: sourceImage)) ?? ""
            request.text = preview.isEmpty ? "[图片]" : preview
            return try await gateway.translate(image: jpeg, req: request, progress: progress, cancel: token)
        }
    }
}
