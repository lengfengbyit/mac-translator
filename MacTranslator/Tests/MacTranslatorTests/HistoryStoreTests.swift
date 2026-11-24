import Foundation
import XCTest
@testable import MacTranslator

final class HistoryStoreTests: XCTestCase {
    private var stack: CoreDataStack!
    private var store: HistoryStore!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack(inMemory: true)
        XCTAssertNil(stack.loadError)
        store = HistoryStore(stack: stack)
    }

    override func tearDown() {
        store = nil
        stack = nil
        super.tearDown()
    }

    private func record(
        id: UUID = UUID(),
        time: Date = Date(),
        original: String = "hello",
        translated: String = "你好",
        favorite: Bool = false
    ) -> HistoryRecord {
        HistoryRecord(
            id: id,
            timestamp: time,
            original: original,
            translated: translated,
            sourceType: .selection,
            interfaceName: "主力 · gpt-4o",
            isFavorite: favorite
        )
    }

    func testSaveAndFetchInDescendingTimeOrder() throws {
        let now = Date()
        try store.save(record(time: now.addingTimeInterval(-100), original: "old"))
        try store.save(record(time: now, original: "new"))

        let all = try store.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.original, "new")
    }

    func testToggleFavoriteDoesNotDeleteHistory() throws {
        let id = UUID()
        try store.save(record(id: id, favorite: false))

        try store.toggleFavorite(id: id)
        let favoritedRecords = try store.fetchAll()
        let favorited = try XCTUnwrap(favoritedRecords.first)
        XCTAssertEqual(favoritedRecords.count, 1)
        XCTAssertTrue(favorited.isFavorite)

        try store.toggleFavorite(id: id)
        let unfavoritedRecords = try store.fetchAll()
        let unfavorited = try XCTUnwrap(unfavoritedRecords.first)
        XCTAssertEqual(unfavoritedRecords.count, 1)
        XCTAssertFalse(unfavorited.isFavorite)
    }

    func testDeleteSingleRecord() throws {
        let kept = record(original: "kept")
        let removed = record(original: "removed")
        try store.save(kept)
        try store.save(removed)

        try store.delete(id: removed.id)
        let all = try store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, kept.id)
    }

    func testClearAllRemovesEverything() throws {
        try store.save(record())
        try store.save(record(favorite: true))

        try store.clearAll()
        let remaining = try store.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSaveSameIDUpdatesInsteadOfDuplicating() throws {
        let id = UUID()
        try store.save(record(id: id, translated: "旧译文"))
        try store.save(record(id: id, translated: "新译文"))

        let all = try store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.translated, "新译文")
    }
}
