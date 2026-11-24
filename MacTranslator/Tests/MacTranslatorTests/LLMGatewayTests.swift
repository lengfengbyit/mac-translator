import Foundation
import XCTest
@testable import MacTranslator

final class LLMGatewayTests: XCTestCase {
    // MARK: - Mocks

    private final class MockSettingsStore: SettingsStoring {
        var settings: AppSettings
        var current: AppSettings { settings }
        init(_ settings: AppSettings) { self.settings = settings }
        func load() -> AppSettings { settings }
        func update(_ new: AppSettings) throws { settings = new }
    }

    private final class MemoryCache: CacheStoring {
        var storage: [String: TranslationResult] = [:]
        func get(key: String) -> TranslationResult? { storage[key] }
        func set(key: String, result: TranslationResult) { storage[key] = result }
        func clear() { storage.removeAll() }
        func makeKey(
            request: TranslateRequest,
            modeTag: String,
            input: String?,
            model: String?
        ) -> String {
            "\(request.text)|\(request.sourceLang)|\(request.targetLang)|\(model ?? "")|\(modeTag)|\(input ?? "")"
        }
    }

    private final class MockHTTPSession: LLMHTTPSession {
        enum Outcome {
            case success(String)
            case http(Int)
            case rawJSON(String)
            case failure(GatewayFailure)
        }

        var outcomes: [Outcome]
        private(set) var requests: [URLRequest] = []
        private(set) var didCancel = false

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let index = requests.count - 1
            guard outcomes.indices.contains(index) else {
                throw GatewayFailure(endpointName: "", category: .network, message: "no mock outcome")
            }
            switch outcomes[index] {
            case .success(let text):
                let json = "{\"choices\":[{\"message\":{\"content\":\"\(text)\"}}]}"
                return (Data(json.utf8), response(status: 200))
            case .http(let code):
                return (Data("{}".utf8), response(status: code))
            case .rawJSON(let json):
                return (Data(json.utf8), response(status: 200))
            case .failure(let failure):
                throw failure
            }
        }

        func cancelAll() { didCancel = true }

        private func response(status: Int) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/chat/completions")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
        }
    }

    // MARK: - Helpers

    private func endpoint(_ name: String, priority: Int, vision: Bool = false) -> LLMInterface {
        LLMInterface(
            name: name,
            baseURL: "https://api.example.com/v1/",
            model: "model-\(name)",
            priority: priority,
            supportsVision: vision
        )
    }

    private func makeGateway(
        interfaces: [LLMInterface],
        session: MockHTTPSession,
        cache: CacheStoring? = nil
    ) -> LLMGateway {
        let settings = MockSettingsStore({
            var s = AppSettings.default
            s.interfaces = interfaces
            return s
        }())
        return LLMGateway(
            settingsStore: settings,
            cache: cache ?? MemoryCache(),
            session: session
        )
    }

    private func request() -> TranslateRequest {
        TranslateRequest(text: "hello", sourceLang: "auto", targetLang: "简体中文")
    }

    // MARK: - Tests

    func testFirstEndpointSuccessStopsChain() async throws {
        let session = MockHTTPSession([.success("你好")])
        let gateway = makeGateway(
            interfaces: [endpoint("A", priority: 1), endpoint("B", priority: 2)],
            session: session
        )

        let result = try await gateway.translate(request(), progress: nil, cancel: CancellationTokenSource())

        XCTAssertEqual(result.translated, "你好")
        XCTAssertEqual(result.usedEndpointName, "A")
        XCTAssertNil(result.degradedFromName)
        XCTAssertEqual(result.attemptedCount, 1)
        XCTAssertEqual(session.requests.count, 1)
        XCTAssertTrue(session.requests[0].url!.absoluteString.hasSuffix("/v1/chat/completions"))
    }

    func testFailoverOnHTTPErrorMarksDegradedFromFirst() async throws {
        let session = MockHTTPSession([.http(401), .success("降级译文")])
        let gateway = makeGateway(
            interfaces: [endpoint("主力", priority: 1), endpoint("备用", priority: 2)],
            session: session
        )
        var progress: [(Int, Int, String)] = []

        let result = try await gateway.translate(
            request(),
            progress: { progress.append(($0, $1, $2)) },
            cancel: CancellationTokenSource()
        )

        XCTAssertEqual(result.usedEndpointName, "备用")
        XCTAssertEqual(result.degradedFromName, "主力")
        XCTAssertEqual(result.attemptedCount, 2)
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(session.requests.count, 2)
    }

    func testTimeoutAndInvalidResponseBothFailOver() async throws {
        let timeout = GatewayFailure(endpointName: "A", category: .timeout, message: "超时")
        let session = MockHTTPSession([.failure(timeout), .rawJSON("{\"unexpected\":true}")])
        let gateway = makeGateway(
            interfaces: [endpoint("A", priority: 1), endpoint("B", priority: 2)],
            session: session
        )

        do {
            _ = try await gateway.translate(request(), progress: nil, cancel: CancellationTokenSource())
            XCTFail("expected allFailed")
        } catch GatewayError.allFailed(let attempted, let last, let failures) {
            XCTAssertEqual(attempted, 2)
            XCTAssertEqual(failures.count, 2)
            XCTAssertEqual(failures[0].category, .timeout)
            XCTAssertEqual(failures[1].category, .invalidResponse)
            XCTAssertEqual(last?.endpointName, "B")
        }
    }

    func testEmptyContentIsInvalidResponse() async throws {
        let session = MockHTTPSession([.rawJSON("{\"choices\":[{\"message\":{\"content\":\"   \"}}]}")])
        let gateway = makeGateway(interfaces: [endpoint("A", priority: 1)], session: session)

        do {
            _ = try await gateway.translate(request(), progress: nil, cancel: CancellationTokenSource())
            XCTFail("expected allFailed")
        } catch GatewayError.allFailed(_, let last, _) {
            XCTAssertEqual(last?.category, .invalidResponse)
        }
    }

    func testCacheHitSkipsNetwork() async throws {
        let cache = MemoryCache()
        let firstSession = MockHTTPSession([.success("首次")])
        let firstGateway = makeGateway(
            interfaces: [endpoint("A", priority: 1)],
            session: firstSession,
            cache: cache
        )
        _ = try await firstGateway.translate(request(), progress: nil, cancel: CancellationTokenSource())

        let secondSession = MockHTTPSession([])
        let secondGateway = makeGateway(
            interfaces: [endpoint("A", priority: 1)],
            session: secondSession,
            cache: cache
        )
        let cached = try await secondGateway.translate(request(), progress: nil, cancel: CancellationTokenSource())

        XCTAssertTrue(cached.cached)
        XCTAssertEqual(cached.translated, "首次")
        XCTAssertEqual(secondSession.requests.count, 0)
    }

    func testPreCancelledTokenDoesNotCallNetwork() async throws {
        let session = MockHTTPSession([.success("不应调用")])
        let gateway = makeGateway(interfaces: [endpoint("A", priority: 1)], session: session)
        let token = CancellationTokenSource()
        token.cancel()

        do {
            _ = try await gateway.translate(request(), progress: nil, cancel: token)
            XCTFail("expected cancelled")
        } catch GatewayError.cancelled {
            XCTAssertEqual(session.requests.count, 0)
        }
    }

    func testCancelActiveTaskMarksSessionCancelled() {
        let session = MockHTTPSession([])
        let gateway = makeGateway(interfaces: [endpoint("A", priority: 1)], session: session)
        gateway.cancelActiveTask()
        XCTAssertTrue(session.didCancel)
    }

    func testImageChainOnlyUsesVisionEndpoint() async throws {
        let session = MockHTTPSession([.success("图片译文")])
        let gateway = makeGateway(
            interfaces: [
                endpoint("普通", priority: 1, vision: false),
                endpoint("视觉", priority: 2, vision: true)
            ],
            session: session
        )

        let result = try await gateway.translate(
            image: Data("fake-jpeg".utf8),
            req: request(),
            progress: nil,
            cancel: CancellationTokenSource()
        )

        XCTAssertEqual(result.usedEndpointName, "视觉")
        XCTAssertEqual(session.requests.count, 1)
        let body = String(data: session.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("image_url"))
        XCTAssertTrue(body.contains("data:image/jpeg;base64,"))
    }

    func testNoEnabledEndpointThrows() async throws {
        let gateway = makeGateway(interfaces: [], session: MockHTTPSession([]))
        do {
            _ = try await gateway.translate(request(), progress: nil, cancel: CancellationTokenSource())
            XCTFail("expected noEnabledEndpoint")
        } catch GatewayError.noEnabledEndpoint {
            XCTAssertTrue(true)
        }
    }

    func testTestEndpointReturnsSuccess() async throws {
        let session = MockHTTPSession([.success("hi")])
        let gateway = makeGateway(interfaces: [], session: session)
        let outcome = try await gateway.test(endpoint("测试接口", priority: 1))

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.endpointName, "测试接口")
    }
}
