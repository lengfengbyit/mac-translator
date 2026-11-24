import Foundation
import XCTest
@testable import MacTranslator

final class CacheServiceTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func request(text: String = "hello", target: String = "简体中文") -> TranslateRequest {
        TranslateRequest(text: text, sourceLang: "auto", targetLang: target)
    }

    private func result(_ text: String) -> TranslationResult {
        TranslationResult(
            original: "hello",
            translated: text,
            usedEndpointName: "主力",
            usedModel: "gpt-4o"
        )
    }

    func testKeyIncludesTextLanguageModelAndMode() {
        let cache = CacheService(fileURL: fileURL)
        let base = cache.makeKey(request: request(), modeTag: "txt", input: nil, model: "m1")

        XCTAssertEqual(base, cache.makeKey(request: request(), modeTag: "txt", input: nil, model: "m1"))
        XCTAssertNotEqual(base, cache.makeKey(request: request(text: "world"), modeTag: "txt", input: nil, model: "m1"))
        XCTAssertNotEqual(base, cache.makeKey(request: request(target: "English"), modeTag: "txt", input: nil, model: "m1"))
        XCTAssertNotEqual(base, cache.makeKey(request: request(), modeTag: "img", input: nil, model: "m1"))
        XCTAssertNotEqual(base, cache.makeKey(request: request(), modeTag: "txt", input: nil, model: "m2"))
        XCTAssertNotEqual(base, cache.makeKey(request: request(), modeTag: "txt", input: "imageHash", model: "m1"))
        XCTAssertEqual(base.count, 64) // sha256 hex
    }

    func testSetGetAndClear() {
        let cache = CacheService(fileURL: fileURL)
        let key = cache.makeKey(request: request(), modeTag: "txt", input: nil, model: "m1")
        cache.set(key: key, result: result("你好"))

        XCTAssertEqual(cache.get(key: key)?.translated, "你好")
        cache.clear()
        XCTAssertNil(cache.get(key: key))
    }

    func testLRUEvictsOldestEntry() {
        let cache = CacheService(fileURL: fileURL, maxEntries: 2)
        let a = "a", b = "b", c = "c"
        cache.set(key: a, result: result("A"))
        cache.set(key: b, result: result("B"))
        _ = cache.get(key: a) // a becomes most recently used
        cache.set(key: c, result: result("C"))

        XCTAssertNil(cache.get(key: b))
        XCTAssertNotNil(cache.get(key: a))
        XCTAssertNotNil(cache.get(key: c))
    }

    func testPersistenceAcrossInstances() {
        let first = CacheService(fileURL: fileURL)
        let key = first.makeKey(request: request(), modeTag: "txt", input: nil, model: "m1")
        first.set(key: key, result: result("持久化"))

        let second = CacheService(fileURL: fileURL)
        XCTAssertEqual(second.get(key: key)?.translated, "持久化")
    }

    func testRequestIdNeverAffectsKey() {
        let cache = CacheService(fileURL: fileURL)
        var one = request()
        one.requestId = UUID()
        var two = request()
        two.requestId = UUID()
        XCTAssertEqual(
            cache.makeKey(request: one, modeTag: "txt", input: nil, model: "m"),
            cache.makeKey(request: two, modeTag: "txt", input: nil, model: "m")
        )
    }
}
