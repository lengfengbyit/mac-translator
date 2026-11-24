import Foundation
import CoreData

// MARK: - 持久化验证专用断言（独立于 OfflineVerification）

final class PersistenceReport {
    static let shared = PersistenceReport()
    var passed = 0
    var failed = 0
    var failures: [String] = []

    func check(_ condition: Bool, _ name: String, detail: String = "") {
        if condition { passed += 1; print("  [PASS] \(name)") }
        else {
            failed += 1
            let line = detail.isEmpty ? name : "\(name) — \(detail)"
            failures.append(line)
            print("  [FAIL] \(line)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        check(actual == expected, name, detail: "expected=\(expected), actual=\(actual)")
    }
}

private func tempStoreURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("qa-persist-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("MacTranslator.sqlite")
}

private func record(id: UUID = UUID(),
                    timestamp: Date = Date(),
                    text: String,
                    favorite: Bool = false) -> HistoryRecord {
    HistoryRecord(id: id, timestamp: timestamp, original: text,
                  translated: "译文-\(text)", sourceType: .selection,
                  interfaceName: "主力 · gpt-4o", isFavorite: favorite)
}

@main
struct PersistenceVerification {
    static func main() {
        let r = PersistenceReport.shared
        print("\n===== D. 历史/收藏持久化（真实 Core Data） =====")

        let storeURL = tempStoreURL()
        let stack = CoreDataStack(modelName: "Model", storeURL: storeURL, inMemory: false)
        r.check(stack.loadError == nil, "D0 Core Data 存储加载成功",
                detail: stack.loadError.map { "\($0)" } ?? "")

        let store = HistoryStore(stack: stack, retentionLimit: 500)
        let now = Date()
        let idOld = UUID(), idNew = UUID()
        let oldRecord = record(id: idOld, timestamp: now.addingTimeInterval(-100), text: "旧记录")
        let newRecord = record(id: idNew, timestamp: now, text: "新记录")

        // D1 保存 + 时间倒序
        try? store.save(oldRecord)
        try? store.save(newRecord)
        let all = (try? store.fetchAll()) ?? []
        r.equal(all.count, 2, "D1 保存 2 条记录")
        r.check(all.first?.original == "新记录" && all.last?.original == "旧记录",
                "D1 fetchAll 按 timestamp 倒序", detail: "\(all.map { $0.original })")

        // D2 收藏切换不删历史
        try? store.toggleFavorite(id: idNew)
        let afterFav = (try? store.fetchAll()) ?? []
        r.equal(afterFav.count, 2, "D2 收藏切换后历史条数不变")
        r.check(afterFav.first(where: { $0.id == idNew })?.isFavorite == true,
                "D2 收藏态置 true")
        r.check(store.isFavorite(id: idNew), "D2 isFavorite(id) 返回 true")

        // D3 取消收藏不删历史
        try? store.toggleFavorite(id: idNew)
        let afterUnfav = (try? store.fetchAll()) ?? []
        r.equal(afterUnfav.count, 2, "D3 取消收藏后历史条数不变")
        r.check(afterUnfav.first(where: { $0.id == idNew })?.isFavorite == false,
                "D3 收藏态置 false")

        // D4 重启保留：同一 sqlite 新建 stack
        try? store.toggleFavorite(id: idNew) // 留一个收藏态验证持久化
        let restartedStack = CoreDataStack(modelName: "Model", storeURL: storeURL, inMemory: false)
        let restartedStore = HistoryStore(stack: restartedStack, retentionLimit: 500)
        let afterRestart = (try? restartedStore.fetchAll()) ?? []
        r.equal(afterRestart.count, 2, "D4 重启后记录保留")
        r.check(afterRestart.first(where: { $0.id == idNew })?.isFavorite == true,
                "D4 收藏态重启后保留")
        r.check(afterRestart.first(where: { $0.id == idOld })?.original == "旧记录",
                "D4 原文字段重启后保留")
        r.check(afterRestart.first(where: { $0.id == idNew })?.interfaceName == "主力 · gpt-4o",
                "D4 使用接口字段重启后保留")

        // D5 删除单条
        try? restartedStore.delete(id: idOld)
        let afterDelete = (try? restartedStore.fetchAll()) ?? []
        r.equal(afterDelete.count, 1, "D5 删除单条后剩 1 条")
        r.check(afterDelete.first?.id == idNew, "D5 删除的是指定 id")

        // D6 清空
        try? restartedStore.clearAll()
        let afterClear = (try? restartedStore.fetchAll()) ?? []
        r.equal(afterClear.count, 0, "D6 clearAll 清空历史")

        // D7 时间倒序在重启后仍成立（重新写入两条）
        let s3 = HistoryStore(stack: restartedStack, retentionLimit: 500)
        try? s3.save(record(timestamp: now.addingTimeInterval(-500), text: "更早"))
        try? s3.save(record(timestamp: now.addingTimeInterval(-100), text: "较晚"))
        let ordered = (try? s3.fetchAll()) ?? []
        r.check(ordered.map { $0.original } == ["较晚", "更早"],
                "D7 重启后仍按时间倒序", detail: "\(ordered.map { $0.original })")

        print("")
        print("========== 持久化汇总 ==========")
        print("PASS: \(r.passed) | FAIL: \(r.failed) | TOTAL: \(r.passed + r.failed)")
        for f in r.failures { print("  - \(f)") }
        if r.failed > 0 { exit(1) }
    }
}
