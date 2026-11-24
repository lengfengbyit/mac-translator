import Foundation

/// In-memory LRU cache mirrored to a JSON file. Keys never include the requestId.
final class CacheService: CacheStoring {
    private let lock = NSLock()
    private var entries: [String: CacheEntry] = [:]
    /// Oldest first, newest last.
    private var recency: [String] = []
    private let fileURL: URL
    private let maxEntries: Int

    init(fileURL: URL? = nil, maxEntries: Int = 500) {
        self.fileURL = fileURL ?? Bundle.applicationSupportDirectory
            .appendingPathComponent("cache.json", isDirectory: false)
        self.maxEntries = max(1, maxEntries)
        loadFromDisk()
    }

    func get(key: String) -> TranslationResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        touchLocked(key)
        return entry.result
    }

    func set(key: String, result: TranslationResult) {
        lock.lock()
        defer { lock.unlock() }
        if entries[key] != nil {
            recency.removeAll { $0 == key }
        }
        entries[key] = CacheEntry(key: key, result: result)
        recency.append(key)

        while recency.count > maxEntries {
            let oldest = recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        persistLocked()
    }

    func makeKey(
        request: TranslateRequest,
        modeTag: String,
        input: String?,
        model: String?
    ) -> String {
        let textHashInput = input ?? request.text
        let modelName = model ?? "default"
        return "v1|\(textHashInput)|\(request.sourceLang)|\(request.targetLang)|\(modelName)|\(modeTag)".sha256Hex
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        recency.removeAll()
        persistLocked()
    }

    // MARK: Internals

    private func touchLocked(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let stored = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        lock.lock()
        entries = stored
        recency = stored.values
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.key }
        while recency.count > maxEntries {
            let oldest = recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    /// Caller must hold `lock`.
    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
