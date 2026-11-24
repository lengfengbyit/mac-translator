import Foundation

/// LLM gateway contract (see technical design §2.3.7).
protocol LLMProviding {
    /// Text translation with failover and cache.
    func translate(
        _ req: TranslateRequest,
        progress: ((Int, Int, String) -> Void)?,
        cancel: CancellationToken
    ) async throws -> TranslationResult

    /// Multimodal OCR translation, restricted to endpoints with supportsVision == true.
    func translate(
        image: Data,
        req: TranslateRequest,
        progress: ((Int, Int, String) -> Void)?,
        cancel: CancellationToken
    ) async throws -> TranslationResult

    /// Settings pane connectivity check for one explicit endpoint.
    func test(_ endpoint: LLMInterface) async throws -> TestResult

    func cancelActiveTask()
}

/// Minimal network abstraction so the gateway can be unit tested without real HTTP.
protocol LLMHTTPSession: AnyObject {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse)
    func cancelAll()
}
