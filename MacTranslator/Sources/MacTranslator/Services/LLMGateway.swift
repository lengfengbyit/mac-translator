import Foundation

// MARK: - URLSession backed network session

/// Tracks the in-flight data task so `cancelActiveTask()` can abort the current attempt.
final class URLSessionLLMHTTPSession: LLMHTTPSession {
    private let session: URLSession
    private let lock = NSLock()
    private var currentTask: URLSessionDataTask?

    init(session: URLSession = URLSession.shared) {
        self.session = session
    }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = request
        urlRequest.timeoutInterval = timeout

        return try await withCheckedThrowingContinuation { continuation in
            let task = self.session.dataTask(with: urlRequest) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: GatewayFailure(
                        endpointName: "",
                        category: .invalidResponse,
                        message: "响应不是 HTTP 响应"
                    ))
                    return
                }
                continuation.resume(with: Result.success((data ?? Data(), http)))
            }
            self.lock.lock()
            self.currentTask = task
            self.lock.unlock()
            task.resume()
        }
    }

    func cancelAll() {
        lock.lock()
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }

    private static func mapError(_ error: Error) -> GatewayFailure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return GatewayFailure(endpointName: "", category: .cancelled, message: "请求已取消")
            case .timedOut, .cannotConnectToHost, .notConnectedToInternet:
                return GatewayFailure(
                    endpointName: "",
                    category: urlError.code == .timedOut ? .timeout : .network,
                    message: urlError.localizedDescription
                )
            default:
                return GatewayFailure(endpointName: "", category: .network, message: urlError.localizedDescription)
            }
        }
        return GatewayFailure(endpointName: "", category: .network, message: error.localizedDescription)
    }
}

// MARK: - Gateway

/// Serial failover gateway. One request => at most one call per endpoint, no retry on the same endpoint.
final class LLMGateway: LLMProviding {
    private let settingsStore: SettingsStoring
    private let cache: CacheStoring
    private let session: LLMHTTPSession
    private var activeToken = CancellationTokenSource()
    private let decoder = JSONDecoder()

    init(
        settingsStore: SettingsStoring,
        cache: CacheStoring,
        session: LLMHTTPSession? = nil
    ) {
        self.settingsStore = settingsStore
        self.cache = cache
        self.session = session ?? URLSessionLLMHTTPSession()
    }

    // MARK: Public API

    func translate(
        _ req: TranslateRequest,
        progress: ((Int, Int, String) -> Void)?,
        cancel: CancellationToken
    ) async throws -> TranslationResult {
        let startedAt = Date()
        activeToken = CancellationTokenSource()
        if let hit = lookupCache(for: req, modeTag: "txt", input: nil) {
            var cached = hit
            cached.cached = true
            return cached
        }

        let chain = buildChain(mode: nil)
        guard !chain.isEmpty else { throw GatewayError.noEnabledEndpoint }

        var failures: [GatewayFailure] = []
        for (index, endpoint) in chain.enumerated() {
            try assertNotCancelled(cancel)
            progress?(index + 1, chain.count, endpoint.name)

            do {
                let content = try await call(endpoint: endpoint, request: req, imageData: nil)
                let result = TranslationResult(
                    original: req.text,
                    translated: content,
                    usedEndpointName: endpoint.name,
                    usedModel: endpoint.model,
                    degradedFromName: index == 0 ? nil : chain[0].name,
                    attemptedCount: index + 1,
                    elapsed: Date().timeIntervalSince(startedAt),
                    cached: false,
                    sourceType: req.sourceType
                )
                if settingsStore.current.cacheEnabled && !req.forceFresh {
                    cache.set(key: cacheKey(for: req, modeTag: "txt", input: nil), result: result)
                }
                return result
            } catch let failure as GatewayFailure {
                if failure.category == .cancelled {
                    throw GatewayError.cancelled
                }
                failures.append(failure)
            } catch let error as GatewayError {
                throw error
            } catch {
                failures.append(GatewayFailure(
                    endpointName: endpoint.name,
                    category: .network,
                    message: error.localizedDescription
                ))
            }
        }

        throw GatewayError.allFailed(
            attemptedCount: chain.count,
            lastError: failures.last,
            failures: failures
        )
    }

    func translate(
        image: Data,
        req: TranslateRequest,
        progress: ((Int, Int, String) -> Void)?,
        cancel: CancellationToken
    ) async throws -> TranslationResult {
        let startedAt = Date()
        activeToken = CancellationTokenSource()
        let imageHash = image.sha256Hex
        if let hit = lookupCache(for: req, modeTag: "img", input: imageHash) {
            var cached = hit
            cached.cached = true
            return cached
        }

        let chain = buildChain(mode: .multimodalLLM)
        guard !chain.isEmpty else { throw GatewayError.noVisionEndpoint }

        var failures: [GatewayFailure] = []
        for (index, endpoint) in chain.enumerated() {
            try assertNotCancelled(cancel)
            progress?(index + 1, chain.count, endpoint.name)

            do {
                let content = try await call(endpoint: endpoint, request: req, imageData: image)
                let result = TranslationResult(
                    original: req.text,
                    translated: content,
                    usedEndpointName: endpoint.name,
                    usedModel: endpoint.model,
                    degradedFromName: index == 0 ? nil : chain[0].name,
                    attemptedCount: index + 1,
                    elapsed: Date().timeIntervalSince(startedAt),
                    cached: false,
                    sourceType: req.sourceType
                )
                if settingsStore.current.cacheEnabled && !req.forceFresh {
                    cache.set(key: cacheKey(for: req, modeTag: "img", input: imageHash), result: result)
                }
                return result
            } catch let failure as GatewayFailure {
                if failure.category == .cancelled {
                    throw GatewayError.cancelled
                }
                failures.append(failure)
            } catch let error as GatewayError {
                throw error
            } catch {
                failures.append(GatewayFailure(
                    endpointName: endpoint.name,
                    category: .network,
                    message: error.localizedDescription
                ))
            }
        }

        throw GatewayError.allFailed(
            attemptedCount: chain.count,
            lastError: failures.last,
            failures: failures
        )
    }

    func test(_ endpoint: LLMInterface) async throws -> TestResult {
        let startedAt = Date()
        let request = TranslateRequest(
            text: "hello",
            sourceLang: "auto",
            targetLang: settingsStore.current.targetLanguage,
            sourceType: .selection
        )
        do {
            let content = try await call(endpoint: endpoint, request: request, imageData: nil)
            return TestResult(
                endpointName: endpoint.name,
                success: true,
                message: "连接成功，返回：\(String(content.prefix(24)))",
                elapsed: Date().timeIntervalSince(startedAt)
            )
        } catch let failure as GatewayFailure {
            return TestResult(
                endpointName: endpoint.name,
                success: false,
                message: "\(failure.category.displayName)：\(failure.message)",
                elapsed: Date().timeIntervalSince(startedAt)
            )
        }
    }

    func cancelActiveTask() {
        activeToken.cancel()
        session.cancelAll()
    }

    // MARK: Internals

    private func assertNotCancelled(_ token: CancellationToken) throws {
        if token.isCancelled || activeToken.isCancelled {
            throw GatewayError.cancelled
        }
    }

    /// Stable priority order: priority asc, then UUID string asc.
    private func buildChain(mode: OCRMode?) -> [LLMInterface] {
        let candidates = settingsStore.current.interfaces.filter { endpoint in
            guard endpoint.enabled else { return false }
            guard let mode = mode else { return true }
            return mode == .multimodalLLM ? endpoint.supportsVision : true
        }
        return candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func lookupCache(
        for request: TranslateRequest,
        modeTag: String,
        input: String?
    ) -> TranslationResult? {
        guard settingsStore.current.cacheEnabled, !request.forceFresh else { return nil }
        return cache.get(key: cacheKey(for: request, modeTag: modeTag, input: input))
    }

    private func cacheKey(
        for request: TranslateRequest,
        modeTag: String,
        input: String?
    ) -> String {
        let model = buildChain(mode: nil).first?.model ?? "default"
        return cache.makeKey(
            request: request,
            modeTag: modeTag,
            input: input,
            model: model
        )
    }

    private func call(
        endpoint: LLMInterface,
        request: TranslateRequest,
        imageData: Data?
    ) async throws -> String {
        guard let url = endpoint.resolvedURL() else {
            throw GatewayFailure(
                endpointName: endpoint.name,
                category: .invalidResponse,
                message: "baseURL 无效：\(endpoint.baseURL)"
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // API key comes from the local config (settings.json), never Keychain.
        // It is only placed in the Authorization header, never logged.
        if let apiKey = endpoint.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            if let imageData {
                urlRequest.httpBody = try multimodalBody(endpoint: endpoint, request: request, image: imageData)
            } else {
                let body = ChatRequestBody(
                    model: endpoint.model,
                    messages: [
                        ChatMessage(role: "system", content: systemPrompt(for: request)),
                        ChatMessage(role: "user", content: request.text)
                    ],
                    temperature: 0
                )
                urlRequest.httpBody = try JSONEncoder().encode(body)
            }
        } catch {
            throw GatewayFailure(
                endpointName: endpoint.name,
                category: .invalidResponse,
                message: "请求体构造失败：\(error.localizedDescription)"
            )
        }

        let timeout = TimeInterval(max(1, settingsStore.current.timeoutSeconds))
        let (data, response) = try await session.send(urlRequest, timeout: timeout)
        return try validate(data: data, response: response, endpointName: endpoint.name)
    }

    private func systemPrompt(for request: TranslateRequest) -> String {
        let source = request.sourceLang == "auto" ? "自动检测" : request.sourceLang
        return "你是专业翻译助手。请将用户输入准确翻译为\(request.targetLang)（源语言：\(source)），仅输出译文，不要输出解释或原文。"
    }

    private func multimodalBody(
        endpoint: LLMInterface,
        request: TranslateRequest,
        image: Data
    ) throws -> Data {
        let payload: [String: Any] = [
            "model": endpoint.model,
            "messages": [
                [
                    "role": "system",
                    "content": "你是 OCR 与翻译助手。识别图片中的文字并翻译为\(request.targetLang)，仅输出译文。"
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "请识别并翻译图中文字"],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(image.base64EncodedString())",
                                "detail": "auto"
                            ]
                        ]
                    ]
                ]
            ],
            "temperature": 0
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func validate(
        data: Data,
        response: HTTPURLResponse,
        endpointName: String
    ) throws -> String {
        guard (200..<300).contains(response.statusCode) else {
            throw GatewayFailure(
                endpointName: endpointName,
                category: .http,
                message: "HTTP \(response.statusCode)"
            )
        }
        do {
            let decoded = try decoder.decode(ChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw GatewayFailure(
                    endpointName: endpointName,
                    category: .invalidResponse,
                    message: "缺少 choices[0].message.content"
                )
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GatewayFailure(
                    endpointName: endpointName,
                    category: .invalidResponse,
                    message: "译文内容为空"
                )
            }
            return trimmed
        } catch let failure as GatewayFailure {
            throw failure
        } catch {
            throw GatewayFailure(
                endpointName: endpointName,
                category: .invalidResponse,
                message: "响应 JSON 解析失败"
            )
        }
    }
}

// MARK: - Wire types

private struct ChatRequestBody: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Int
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
