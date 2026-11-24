import Foundation

/// History and favorites store contract.
protocol HistoryStoring {
    func save(_ record: HistoryRecord) throws
    func fetchAll() throws -> [HistoryRecord]
    func toggleFavorite(id: UUID) throws
    func delete(id: UUID) throws
    func clearAll() throws
}

/// JSON-backed settings contract.
protocol SettingsStoring {
    var current: AppSettings { get }
    func load() -> AppSettings
    func update(_ settings: AppSettings) throws
}

/// Cache contract with LRU eviction and disk persistence.
protocol CacheStoring {
    func get(key: String) -> TranslationResult?
    func set(key: String, result: TranslationResult)
    /// key = sha256("v1|<input>|<source>|<target>|<model>|<modeTag>")
    func makeKey(request: TranslateRequest, modeTag: String) -> String
    func makeKey(
        request: TranslateRequest,
        modeTag: String,
        input: String?,
        model: String?
    ) -> String
    func clear()
}

extension CacheStoring {
    func makeKey(request: TranslateRequest, modeTag: String) -> String {
        makeKey(request: request, modeTag: modeTag, input: nil, model: nil)
    }
}

