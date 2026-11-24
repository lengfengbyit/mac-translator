import Foundation

// MARK: - 轻量断言框架（无需 XCTest）

final class Report {
    static let shared = Report()
    var passed = 0
    var failed = 0
    var failures: [String] = []

    func check(_ condition: Bool, _ name: String, detail: String = "") {
        if condition {
            passed += 1
            print("  [PASS] \(name)")
        } else {
            failed += 1
            let line = detail.isEmpty ? name : "\(name) — \(detail)"
            failures.append(line)
            print("  [FAIL] \(line)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        check(actual == expected, name, detail: "expected=\(expected), actual=\(actual)")
    }

    func summary() {
        print("")
        print("========== 汇总 ==========")
        print("PASS: \(passed) | FAIL: \(failed) | TOTAL: \(passed + failed)")
        if !failures.isEmpty {
            print("失败项:")
            for f in failures { print("  - \(f)") }
        }
    }
}

// MARK: - Mocks（严格独立于工程师的 XCTest mock）

private final class MockSettings: SettingsStoring {
    var settings: AppSettings
    var current: AppSettings { settings }
    init(_ s: AppSettings) { settings = s }
    func load() -> AppSettings { settings }
    func update(_ s: AppSettings) throws { settings = s }
}

private final class MemoryCache: CacheStoring {
    var storage: [String: TranslationResult] = [:]
    func get(key: String) -> TranslationResult? { storage[key] }
    func set(key: String, result: TranslationResult) { storage[key] = result }
    func clear() { storage.removeAll() }
    func makeKey(request: TranslateRequest, modeTag: String, input: String?, model: String?) -> String {
        "\(request.text)|\(request.sourceLang)|\(request.targetLang)|\(model ?? "")|\(modeTag)|\(input ?? "")"
    }
}

private final class MockHTTPSession: LLMHTTPSession {
    enum Script {
        case success(String)
        case http(Int)
        case json(String)
        case gatewayFailure(GatewayFailure)
        case urlError(URLError)
    }

    var scripts: [Script]
    private(set) var requests: [URLRequest] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var cancelCalled = false

    init(_ scripts: [Script]) { self.scripts = scripts }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        timeouts.append(timeout)
        let idx = requests.count - 1
        guard scripts.indices.contains(idx) else {
            throw GatewayFailure(endpointName: "", category: .network, message: "mock 脚本耗尽")
        }
        switch scripts[idx] {
        case .success(let text):
            let obj: [String: Any] = ["choices": [["message": ["content": text]]]]
            let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
            return (data, http(200))
        case .http(let code):
            return (Data("{}".utf8), http(code))
        case .json(let raw):
            return (Data(raw.utf8), http(200))
        case .gatewayFailure(let f):
            throw f
        case .urlError(let e):
            throw e
        }
    }

    func cancelAll() { cancelCalled = true }

    private func http(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/v1/chat/completions")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }
}

// MARK: - 工具

private func ep(_ name: String, _ priority: Int,
                vision: Bool = false,
                baseURL: String = "https://api.example.com/v1/",
                model: String? = nil,
                apiKey: String? = nil,
                enabled: Bool = true,
                id: UUID = UUID()) -> LLMInterface {
    LLMInterface(id: id, name: name, baseURL: baseURL, apiKey: apiKey,
                 model: model ?? "m-\(name)", enabled: enabled,
                 priority: priority, supportsVision: vision)
}

private func gw(_ interfaces: [LLMInterface],
                session: MockHTTPSession,
                cache: CacheStoring? = nil,
                timeout: Int = 20,
                cacheEnabled: Bool = true) -> LLMGateway {
    var s = AppSettings.default
    s.interfaces = interfaces
    s.timeoutSeconds = timeout
    s.cacheEnabled = cacheEnabled
    return LLMGateway(
        settingsStore: MockSettings(s),
        cache: cache ?? MemoryCache(),
        session: session
    )
}

private func req(_ text: String = "hello",
                 requestId: UUID = UUID(),
                 sourceLang: String = "auto",
                 targetLang: String = "简体中文",
                 forceFresh: Bool = false) -> TranslateRequest {
    TranslateRequest(requestId: requestId, text: text, sourceLang: sourceLang,
                     targetLang: targetLang, forceFresh: forceFresh)
}

private func failure(_ category: GatewayFailureCategory, _ message: String = "mock failure") -> GatewayFailure {
    GatewayFailure(endpointName: "", category: category, message: message)
}

private func tempFile(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("qa-offline-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(tag).json")
}

// MARK: - A. Failover 网关（核心）

func verifyFailover() async {
    let r = Report.shared
    print("\n===== A. LLM Failover 网关 =====")

    // A1 首个即成功
    do {
        let session = MockHTTPSession([.success("译文A")])
        let gateway = gw([ep("A", 1), ep("B", 2)], session: session)
        var progress: [(Int, Int, String)] = []
        let result = try await gateway.translate(req(), progress: { progress.append(($0, $1, $2)) },
                                                 cancel: CancellationTokenSource())
        r.equal(result.translated, "译文A", "A1 首个成功：译文")
        r.equal(result.usedEndpointName, "A", "A1 使用接口 A")
        r.check(result.degradedFromName == nil, "A1 链首成功 degradedFromName 为 nil")
        r.equal(result.attemptedCount, 1, "A1 attemptedCount=1")
        r.equal(session.requests.count, 1, "A1 仅调用 1 次网络")
        r.check(progress.count == 1 && progress[0].0 == 1 && progress[0].1 == 2 && progress[0].2 == "A",
                "A1 progress 回调 (1,2,A)", detail: "\(progress)")
        r.equal(session.timeouts.first, 20.0, "A1 超时参数=20s")
    } catch { r.check(false, "A1 首个成功", detail: "抛错 \(error)") }

    // A2 主接口 401 → 备用成功
    do {
        let session = MockHTTPSession([.http(401), .success("降级译文")])
        let gateway = gw([ep("主力", 1), ep("备用", 2)], session: session)
        var progress: [(Int, Int, String)] = []
        let result = try await gateway.translate(req(), progress: { progress.append(($0, $1, $2)) },
                                                 cancel: CancellationTokenSource())
        r.equal(result.usedEndpointName, "备用", "A2 降级到备用接口")
        r.equal(result.degradedFromName, "主力", "A2 degradedFromName=链首名")
        r.equal(result.attemptedCount, 2, "A2 attemptedCount=2")
        r.equal(session.requests.count, 2, "A2 网络调用 2 次")
        r.check(progress.map { $0.2 } == ["主力", "备用"], "A2 progress 顺序", detail: "\(progress.map { $0.2 })")
    } catch { r.check(false, "A2 HTTP 401 降级", detail: "抛错 \(error)") }

    // A3 主接口超时 → 备用成功
    do {
        let session = MockHTTPSession([.gatewayFailure(failure(.timeout, "主接口超时")), .success("超时后译文")])
        let gateway = gw([ep("慢接口", 1), ep("快接口", 2)], session: session)
        let result = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        r.equal(result.usedEndpointName, "快接口", "A3 超时后降级成功")
        r.equal(result.degradedFromName, "慢接口", "A3 降级来源标注")
        r.equal(result.attemptedCount, 2, "A3 attemptedCount=2")
    } catch { r.check(false, "A3 超时降级", detail: "抛错 \(error)") }

    // A4 三接口全失败 → allFailed
    do {
        let session = MockHTTPSession([
            .http(500),
            .gatewayFailure(failure(.network, "DNS 失败")),
            .json("{\"unexpected\":true}")
        ])
        let gateway = gw([ep("X", 1), ep("Y", 2), ep("Z", 3)], session: session)
        do {
            _ = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
            r.check(false, "A4 全失败应抛 allFailed")
        } catch GatewayError.allFailed(let attempted, let last, let failures) {
            r.equal(attempted, 3, "A4 allFailed.attemptedCount=3")
            r.equal(failures.count, 3, "A4 failures 数量=3")
            r.check(failures.map { $0.category } == [.http, .network, .invalidResponse],
                    "A4 四类失败判定(HTTP/网络/响应非法)", detail: "\(failures.map { $0.category })")
            r.equal(last?.endpointName, "Z", "A4 lastError 来自最后接口")
            r.check(GatewayError.allFailed(attemptedCount: attempted, lastError: last, failures: failures)
                .errorDescription?.contains("已尝试 3 个接口") == true, "A4 错误文案含已尝试数")
            r.equal(session.requests.count, 3, "A4 每个接口仅调 1 次")
        } catch {
            r.check(false, "A4 全失败应抛 allFailed", detail: "实际抛错 \(error)")
        }
    }

    // A5 响应非法 JSON（缺 choices）
    do {
        let session = MockHTTPSession([.json("{\"unexpected\":true}")])
        let gateway = gw([ep("A", 1)], session: session)
        do {
            _ = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
            r.check(false, "A5 非法 JSON 应失败")
        } catch GatewayError.allFailed(_, let last, _) {
            r.equal(last?.category, .invalidResponse, "A5 缺 choices → invalidResponse")
            r.check((last?.message.isEmpty == false) &&
                    (last?.message.contains("解析失败") == true || last?.message.contains("缺少") == true),
                    "A5 错误信息有明确说明", detail: last?.message ?? "")
        } catch {
            r.check(false, "A5 非法 JSON 应失败", detail: "实际抛错 \(error)")
        }
    }

    // A6 content 空串
    do {
        let session = MockHTTPSession([.json("{\"choices\":[{\"message\":{\"content\":\"   \"}}]}")])
        let gateway = gw([ep("A", 1)], session: session)
        do {
            _ = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
            r.check(false, "A6 空 content 应失败")
        } catch GatewayError.allFailed(_, let last, _) {
            r.equal(last?.category, .invalidResponse, "A6 空 content → invalidResponse")
        } catch {
            r.check(false, "A6 空 content 应失败", detail: "实际抛错 \(error)")
        }
    }

    // A7 priority 升序稳定排序（乱序注入）
    do {
        let idA = UUID(), idB = UUID(), idC = UUID()
        let session = MockHTTPSession([
            .http(400), .http(400), .success("第三接口成功")
        ])
        let gateway = gw([
            ep("C", 3, id: idC), ep("A", 1, id: idA), ep("B", 2, id: idB)
        ], session: session)
        var progress: [(Int, Int, String)] = []
        let result = try await gateway.translate(req(), progress: { progress.append(($0, $1, $2)) },
                                                 cancel: CancellationTokenSource())
        r.check(progress.map { $0.2 } == ["A", "B", "C"], "A7 调用顺序按 priority 升序",
                detail: "\(progress.map { $0.2 })")
        r.equal(result.usedEndpointName, "C", "A7 最终成功接口")
        r.equal(result.degradedFromName, "A", "A7 非链首成功 degraded 指向链首")
        r.equal(result.attemptedCount, 3, "A7 attemptedCount=3")
    } catch { r.check(false, "A7 priority 排序", detail: "抛错 \(error)") }

    // A8 同 priority 时按 UUID 升序（稳定）
    do {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let session = MockHTTPSession([.success("同优先级")])
        let gateway = gw([ep("高", 5, id: high), ep("低", 5, id: low)], session: session)
        let result = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        r.equal(result.usedEndpointName, "低", "A8 同 priority 按 id 升序取链首")
    } catch { r.check(false, "A8 稳定排序", detail: "抛错 \(error)") }

    // A9 enabled 过滤
    do {
        let session = MockHTTPSession([.success("启用接口结果")])
        let gateway = gw([ep("禁用", 1, enabled: false), ep("启用", 2)], session: session)
        let result = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        r.equal(result.usedEndpointName, "启用", "A9 禁用接口被过滤")
        r.equal(session.requests.count, 1, "A9 仅调用启用接口")
    } catch { r.check(false, "A9 enabled 过滤", detail: "抛错 \(error)") }

    // A10 无启用接口
    do {
        let gateway = gw([ep("禁用", 1, enabled: false)], session: MockHTTPSession([]))
        do {
            _ = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
            r.check(false, "A10 无启用接口应抛 noEnabledEndpoint")
        } catch GatewayError.noEnabledEndpoint {
            r.check(true, "A10 无启用接口 → noEnabledEndpoint")
        } catch {
            r.check(false, "A10 无启用接口应抛 noEnabledEndpoint", detail: "实际抛错 \(error)")
        }
    }

    // A11 网络错误按真实 URLError 进入 network 分类（未映射时兜底）
    do {
        let session = MockHTTPSession([.urlError(URLError(.cannotConnectToHost)), .success("网络失败后成功")])
        let gateway = gw([ep("A", 1), ep("B", 2)], session: session)
        let result = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        r.equal(result.usedEndpointName, "B", "A11 原始 URLError 触发降级")
        r.equal(result.attemptedCount, 2, "A11 attemptedCount=2")
    } catch { r.check(false, "A11 URLError 降级", detail: "抛错 \(error)") }

    // A12 取消：预先取消 token 不发网络
    do {
        let session = MockHTTPSession([.success("不应调用")])
        let gateway = gw([ep("A", 1)], session: session)
        let token = CancellationTokenSource()
        token.cancel()
        do {
            _ = try await gateway.translate(req(), progress: nil, cancel: token)
            r.check(false, "A12 预取消应抛 cancelled")
        } catch GatewayError.cancelled {
            r.equal(session.requests.count, 0, "A12 预取消不触网")
        } catch {
            r.check(false, "A12 预取消应抛 cancelled", detail: "实际抛错 \(error)")
        }
    }

    // A13 cancelActiveTask 透传到 session
    do {
        let session = MockHTTPSession([])
        let gateway = gw([ep("A", 1)], session: session)
        gateway.cancelActiveTask()
        r.check(session.cancelCalled, "A13 cancelActiveTask 调用 session.cancelAll")
    }
}

// MARK: - B. 多模态 / URL 规范化 / Keychain

func verifyVisionURLAndKey() async {
    let r = Report.shared
    print("\n===== B. 多模态筛选 / URL 规范化 / 密钥 =====")

    // B1 supportsVision 筛选
    do {
        let session = MockHTTPSession([.success("图片译文")])
        let gateway = gw([ep("普通", 1, vision: false), ep("视觉", 2, vision: true)], session: session)
        let result = try await gateway.translate(image: Data("fake-jpeg".utf8), req: req(),
                                                 progress: nil, cancel: CancellationTokenSource())
        r.equal(result.usedEndpointName, "视觉", "B1 图片模式仅选 supportsVision 接口")
        r.equal(session.requests.count, 1, "B1 图片模式仅 1 次网络")
        let body = String(data: session.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        r.check(body.contains("image_url"), "B1 请求体含 image_url")
        let imageB64 = Data("fake-jpeg".utf8).base64EncodedString()
        r.check(body.contains(imageB64), "B1 请求体含 base64 图片数据", detail: imageB64)
        r.check(body.contains("data:image") && body.contains("base64"), "B1 data URL 结构正确（JSON 斜杠被转义属正常）")
    } catch { r.check(false, "B1 多模态筛选", detail: "抛错 \(error)") }

    // B2 无视觉接口 → noVisionEndpoint
    do {
        let gateway = gw([ep("普通", 1)], session: MockHTTPSession([]))
        do {
            _ = try await gateway.translate(image: Data("x".utf8), req: req(),
                                            progress: nil, cancel: CancellationTokenSource())
            r.check(false, "B2 无视觉接口应抛 noVisionEndpoint")
        } catch GatewayError.noVisionEndpoint {
            r.check(true, "B2 无视觉接口 → noVisionEndpoint")
        } catch {
            r.check(false, "B2 无视觉接口应抛 noVisionEndpoint", detail: "实际抛错 \(error)")
        }
    }

    // B3 URL 规范化：去尾斜杠 + 空白
    do {
        let session = MockHTTPSession([.success("ok")])
        let gateway = gw([ep("A", 1, baseURL: "  https://api.example.com/v1///  ")], session: session)
        _ = try? await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        let url = session.requests.first?.url?.absoluteString ?? ""
        r.equal(url, "https://api.example.com/v1/chat/completions", "B3 URL 去尾斜杠与空白后拼接")
    }

    // B4 已含完整路径不重复拼接
    do {
        let session = MockHTTPSession([.success("ok")])
        let gateway = gw([ep("A", 1, baseURL: "https://api.example.com/v1/chat/completions")], session: session)
        _ = try? await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        let url = session.requests.first?.url?.absoluteString ?? ""
        r.equal(url, "https://api.example.com/v1/chat/completions", "B4 完整路径不重复拼接")
    }

    // B5 Ollama 兼容 + 空 apiKey 不加 Authorization
    do {
        let session = MockHTTPSession([.success("ollama-ok")])
        let gateway = gw([ep("本地", 1, baseURL: "http://localhost:11434/v1")], session: session)
        let result = try await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        r.equal(session.requests.first?.url?.absoluteString, "http://localhost:11434/v1/chat/completions",
                "B5 Ollama baseURL 正确拼接")
        r.equal(result.translated, "ollama-ok", "B5 Ollama 调用成功")
        r.check(session.requests.first?.value(forHTTPHeaderField: "Authorization") == nil,
                "B5 无 apiKey 时不发送 Authorization")
    } catch { r.check(false, "B5 Ollama 兼容", detail: "抛错 \(error)") }

    // B6 apiKey 从本地配置文件读取并写入 header（不再走 Keychain）
    do {
        let endpoint = ep("云接口", 1, apiKey: "sk-qa-secret-123")
        let session = MockHTTPSession([.success("ok")])
        let gateway = gw([endpoint], session: session)
        _ = try? await gateway.translate(req(), progress: nil, cancel: CancellationTokenSource())
        r.equal(session.requests.first?.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-qa-secret-123", "B6 配置文件 apiKey 进入 Authorization")
    }
}

// MARK: - C. 缓存 key / LRU / Codable

func verifyCacheKeyLRUAndCodable() {
    let r = Report.shared
    print("\n===== C. 缓存 key / LRU / Codable =====")

    let cache = CacheService(fileURL: tempFile("cache"), maxEntries: 500)
    let baseReq = req("hello")
    let k1 = cache.makeKey(request: baseReq, modeTag: "txt")
    let k2 = cache.makeKey(request: baseReq, modeTag: "txt")

    // C1 确定性
    r.equal(k1, k2, "C1 相同输入 key 相同")
    // C2 公式一致
    let expected = "v1|hello|auto|简体中文|default|txt".sha256Hex
    r.equal(k1, expected, "C2 key = sha256(v1|text|source|target|model|mode)")

    // C3 各维度不同 → key 不同
    r.check(cache.makeKey(request: req("world"), modeTag: "txt") != k1, "C3 文本不同 key 不同")
    r.check(cache.makeKey(request: req("hello", sourceLang: "en"), modeTag: "txt") != k1,
            "C3 源语言不同 key 不同")
    r.check(cache.makeKey(request: req("hello", targetLang: "English"), modeTag: "txt") != k1,
            "C3 目标语言不同 key 不同")
    r.check(cache.makeKey(request: baseReq, modeTag: "img", input: "imghash", model: "default") != k1,
            "C3 模式/图片 hash 不同 key 不同")
    r.check(cache.makeKey(request: baseReq, modeTag: "txt", input: nil, model: "m2") != k1,
            "C3 model 不同 key 不同")

    // C4 requestId 不进入 key（用真实 CacheService 计算）
    let differentId = req("hello", requestId: UUID())
    r.equal(cache.makeKey(request: differentId, modeTag: "txt"), k1, "C4 requestId 不入缓存 key")

    // C5 LRU 淘汰（maxEntries=2）
    let lru = CacheService(fileURL: tempFile("lru"), maxEntries: 2)
    let mkResult: (String) -> TranslationResult = {
        TranslationResult(original: $0, translated: $0, usedEndpointName: "A", usedModel: "m")
    }
    lru.set(key: "k1", result: mkResult("1"))
    lru.set(key: "k2", result: mkResult("2"))
    _ = lru.get(key: "k1") // touch k1，使 k2 成为最旧
    lru.set(key: "k3", result: mkResult("3"))
    r.check(lru.get(key: "k1") != nil, "C5 LRU：最近使用的 k1 保留")
    r.check(lru.get(key: "k2") == nil, "C5 LRU：最旧 k2 被淘汰")
    r.check(lru.get(key: "k3") != nil, "C5 LRU：新写入 k3 保留")

    // C6 clear
    lru.clear()
    r.check(lru.get(key: "k1") == nil && lru.get(key: "k3") == nil, "C6 clear 清空全部缓存")

    // C7 apiKey 明文写入本地配置文件且可完整往返（用户要求不用 Keychain）
    let secret = "sk-super-secret-value"
    let iface = ep("带密钥接口", 1, apiKey: secret)
    let jsonData = try! JSONEncoder().encode(iface)
    let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""
    r.check(jsonStr.contains(secret), "C7 JSON 含 apiKey 明文")
    r.check(jsonStr.contains("apiKey"), "C7 JSON 含 apiKey 字段")
    let decoded = try! JSONDecoder().decode(LLMInterface.self, from: jsonData)
    r.check(decoded.apiKey == secret, "C7 解码后 apiKey 完整还原")
    r.equal(decoded.name, "带密钥接口", "C7 其它字段正常往返")
    r.equal(decoded.supportsVision, false, "C7 supportsVision 字段往返")
    // Settings files written by older versions have no apiKey key at all.
    let legacy = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"旧\",\"baseURL\":\"x\",\"model\":\"m\",\"enabled\":true,\"priority\":1,\"supportsVision\":false}"
    let legacyDecoded = try! JSONDecoder().decode(LLMInterface.self, from: Data(legacy.utf8))
    r.check(legacyDecoded.apiKey == nil, "C7 旧配置缺 apiKey 时解码为 nil")

    // C8 AppSettings 默认基线 + Codable 往返
    let settings = AppSettings.default
    r.equal(settings.targetLanguage, "简体中文", "C8 默认目标语言=简体中文")
    r.equal(settings.sourceLanguage, "auto", "C8 默认源语言=auto")
    r.equal(settings.ocrMode, .localVision, "C8 默认 OCR=本地 Vision")
    r.equal(settings.timeoutSeconds, 20, "C8 默认超时=20s")
    r.check(settings.cacheEnabled, "C8 默认缓存开")
    r.equal(settings.hotkeys.selection.keyCode, 2, "C8 划词热键 keyCode=2(⌥D)")
    r.equal(settings.hotkeys.ocr.modifiers, 2048 | 512, "C8 OCR 热键=⌥⇧S")
    let sData = try! JSONEncoder().encode(settings)
    let sDecoded = try! JSONDecoder().decode(AppSettings.self, from: sData)
    r.equal(sDecoded, settings, "C8 AppSettings Codable 往返一致")
    r.check(!(String(data: sData, encoding: .utf8) ?? "").contains("sk-"), "C8 settings.json 无密钥痕迹")

    // C9 HistoryRecord 字段往返
    let record = HistoryRecord(original: "原文", translated: "译文", sourceType: .ocr,
                               interfaceName: "主力 · gpt-4o", degradedFrom: "链首",
                               isFavorite: true, ocrMode: .multimodalLLM)
    let hData = try! JSONEncoder().encode(record)
    let hDecoded = try! JSONDecoder().decode(HistoryRecord.self, from: hData)
    r.equal(hDecoded.sourceTypeRaw, "ocr", "C9 sourceTypeRaw=ocr")
    r.equal(hDecoded.ocrModeRaw, "multimodalLLM", "C9 ocrModeRaw 保留")
    r.equal(hDecoded.degradedFrom, "链首", "C9 degradedFrom 保留")
    r.check(hDecoded.isFavorite, "C9 isFavorite 保留")
    r.equal(hDecoded.interfaceName, "主力 · gpt-4o", "C9 interfaceName 保留")

    // C10 缓存命中不触网 + requestId 不同仍命中（端到端）
    Task {
        let r = Report.shared
        let sharedCache = CacheService(fileURL: tempFile("e2ecache"), maxEntries: 500)
        let epA = ep("A", 1)
        let firstSession = MockHTTPSession([.success("首次译文")])
        let firstGw = gw([epA], session: firstSession, cache: sharedCache)
        _ = try? await firstGw.translate(req("同一文本"), progress: nil, cancel: CancellationTokenSource())

        let secondSession = MockHTTPSession([])
        let secondGw = gw([epA], session: secondSession, cache: sharedCache)
        let cached = try? await secondGw.translate(req("同一文本", requestId: UUID()),
                                                   progress: nil, cancel: CancellationTokenSource())
        r.check(cached?.cached == true, "C10 缓存命中标记 cached=true")
        r.equal(cached?.translated, "首次译文", "C10 缓存命中返回首次译文")
        r.equal(secondSession.requests.count, 0, "C10 缓存命中不触网")
    }
}

// MARK: - 入口

@main
struct OfflineVerification {
    static func main() async {
        await verifyFailover()
        await verifyVisionURLAndKey()
        verifyCacheKeyLRUAndCodable()
        // 等待 C10 的 Task 完成
        try? await Task.sleep(nanoseconds: 200_000_000)
        Report.shared.summary()
        if Report.shared.failed > 0 { exit(1) }
    }
}
