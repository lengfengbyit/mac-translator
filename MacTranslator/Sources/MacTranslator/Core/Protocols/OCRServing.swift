import Foundation

/// OCR pipeline contract. Capture is owned by the service; a cancellation is reported as
/// OCRServiceError.captureCancelled and produces no LLM request.
protocol OCRServing {
    func recognizeAndTranslate(
        mode: OCRMode,
        req: TranslateRequest,
        progress: ((Int, Int, String) -> Void)?
    ) async throws -> TranslationResult
}
