import Foundation

/// Cancellation handle shared between UI and the gateway.
protocol CancellationToken: AnyObject {
    var isCancelled: Bool { get }
    func cancel()
}

/// Thread-safe cancellation token source.
final class CancellationTokenSource: CancellationToken {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    init() {}

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// Input for one translation attempt. requestId is shared by the whole failover chain
/// but never enters the cache key.
struct TranslateRequest {
    var requestId: UUID
    var text: String
    var sourceLang: String
    var targetLang: String
    var sourceType: SourceType
    var forceFresh: Bool

    init(
        requestId: UUID = UUID(),
        text: String,
        sourceLang: String = "auto",
        targetLang: String = AppSettings.defaultTargetLanguage,
        sourceType: SourceType = .selection,
        forceFresh: Bool = false
    ) {
        self.requestId = requestId
        self.text = text
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.sourceType = sourceType
        self.forceFresh = forceFresh
    }
}

/// Output of a successful translation (text or image mode).
struct TranslationResult: Codable, Equatable {
    var original: String
    var translated: String
    var usedEndpointName: String
    var usedModel: String
    var degradedFromName: String?
    var attemptedCount: Int
    var elapsed: TimeInterval
    var cached: Bool
    var sourceType: SourceType

    init(
        original: String,
        translated: String,
        usedEndpointName: String,
        usedModel: String,
        degradedFromName: String? = nil,
        attemptedCount: Int = 1,
        elapsed: TimeInterval = 0,
        cached: Bool = false,
        sourceType: SourceType = .selection
    ) {
        self.original = original
        self.translated = translated
        self.usedEndpointName = usedEndpointName
        self.usedModel = usedModel
        self.degradedFromName = degradedFromName
        self.attemptedCount = attemptedCount
        self.elapsed = elapsed
        self.cached = cached
        self.sourceType = sourceType
    }

    /// "主力接口 · gpt-4o"
    var llmLabel: String { "\(usedEndpointName) · \(usedModel)" }
}

/// Result of the three-tier text acquisition chain.
struct SelectionResult {
    var text: String
    var usedClipboardFallback: Bool
    var usedLevel: SelectionLevel

    init(
        text: String = "",
        usedClipboardFallback: Bool = false,
        usedLevel: SelectionLevel = .ax
    ) {
        self.text = text
        self.usedClipboardFallback = usedClipboardFallback
        self.usedLevel = usedLevel
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Persisted cache value.
struct CacheEntry: Codable, Equatable {
    var key: String
    var result: TranslationResult
    var createdAt: Date

    init(key: String, result: TranslationResult, createdAt: Date = Date()) {
        self.key = key
        self.result = result
        self.createdAt = createdAt
    }
}

/// Value object exposed to UI and Store; Core Data entity is internal.
struct HistoryRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var original: String
    var translated: String
    var sourceTypeRaw: String
    var interfaceName: String
    var degradedFrom: String?
    var isFavorite: Bool
    var ocrModeRaw: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        original: String,
        translated: String,
        sourceType: SourceType = .selection,
        interfaceName: String,
        degradedFrom: String? = nil,
        isFavorite: Bool = false,
        ocrMode: OCRMode? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.original = original
        self.translated = translated
        self.sourceTypeRaw = sourceType.rawValue
        self.interfaceName = interfaceName
        self.degradedFrom = degradedFrom
        self.isFavorite = isFavorite
        self.ocrModeRaw = ocrMode?.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, original, translated, sourceTypeRaw
        case interfaceName, degradedFrom, isFavorite, ocrModeRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            timestamp: try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(),
            original: try c.decodeIfPresent(String.self, forKey: .original) ?? "",
            translated: try c.decodeIfPresent(String.self, forKey: .translated) ?? "",
            sourceType: SourceType(
                rawValue: try c.decodeIfPresent(String.self, forKey: .sourceTypeRaw) ?? ""
            ) ?? .selection,
            interfaceName: try c.decodeIfPresent(String.self, forKey: .interfaceName) ?? "",
            degradedFrom: try c.decodeIfPresent(String.self, forKey: .degradedFrom),
            isFavorite: try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            ocrMode: OCRMode(
                rawValue: try c.decodeIfPresent(String.self, forKey: .ocrModeRaw) ?? ""
            )
        )
    }

    var sourceType: SourceType {
        SourceType(rawValue: sourceTypeRaw) ?? .selection
    }

    var ocrMode: OCRMode? {
        guard let raw = ocrModeRaw else { return nil }
        return OCRMode(rawValue: raw)
    }
}

/// Result of the Settings pane "test endpoint" action.
struct TestResult {
    var endpointName: String
    var success: Bool
    var message: String
    var elapsed: TimeInterval

    init(
        endpointName: String,
        success: Bool,
        message: String,
        elapsed: TimeInterval = 0
    ) {
        self.endpointName = endpointName
        self.success = success
        self.message = message
        self.elapsed = elapsed
    }
}
