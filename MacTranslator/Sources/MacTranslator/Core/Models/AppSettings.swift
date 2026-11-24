import Foundation

/// A single global hotkey binding. Modifiers are Carbon modifier masks.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let selectionDefault = HotkeyBinding(
        keyCode: 2,   // kVK_ANSI_D
        modifiers: 2048  // optionKey
    )
    static let ocrDefault = HotkeyBinding(
        keyCode: 1,   // kVK_ANSI_S
        modifiers: 2048 | 512  // optionKey | shiftKey
    )
    static let inputDefault = HotkeyBinding(
        keyCode: 34,  // kVK_ANSI_I
        modifiers: 2048 | 512  // optionKey | shiftKey -> ⌥⇧I
    )

    /// Human readable form, e.g. "⌥⇧S".
    var displayString: String {
        var parts: [String] = []
        if modifiers & 512 != 0 { parts.append("⇧") }
        if modifiers & 2048 != 0 { parts.append("⌥") }
        if modifiers & 4096 != 0 { parts.append("⌘") }
        if modifiers & 256 != 0 { parts.append("⌃") }
        parts.append(Self.keyCodeLabel(keyCode))
        return parts.joined()
    }

    private static func keyCodeLabel(_ code: UInt32) -> String {
        let mapping: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "K", 40: ";", 49: "空格", 123: "←", 124: "→",
            125: "↓", 126: "↑"
        ]
        return mapping[code] ?? "键码\(code)"
    }
}

/// All configurable hotkeys. Decoding is tolerant on purpose: settings.json
/// written by an older build has no `input` key, and a strict synthesized
/// decoder would throw, discard the WHOLE AppSettings (including API keys)
/// and silently reset the user's configuration.
struct HotkeyBindings: Codable, Equatable {
    var selection: HotkeyBinding
    var ocr: HotkeyBinding
    var input: HotkeyBinding

    static let `default` = HotkeyBindings(
        selection: .selectionDefault,
        ocr: .ocrDefault,
        input: .inputDefault
    )

    init(
        selection: HotkeyBinding = .selectionDefault,
        ocr: HotkeyBinding = .ocrDefault,
        input: HotkeyBinding = .inputDefault
    ) {
        self.selection = selection
        self.ocr = ocr
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case selection, ocr, input
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selection = try c.decodeIfPresent(HotkeyBinding.self, forKey: .selection) ?? .selectionDefault
        ocr = try c.decodeIfPresent(HotkeyBinding.self, forKey: .ocr) ?? .ocrDefault
        input = try c.decodeIfPresent(HotkeyBinding.self, forKey: .input) ?? .inputDefault
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selection, forKey: .selection)
        try c.encode(ocr, forKey: .ocr)
        try c.encode(input, forKey: .input)
    }
}

/// Application-wide configuration. Persisted as JSON by SettingsStore.
struct AppSettings: Codable, Equatable {
    var targetLanguage: String
    var sourceLanguage: String
    var sourceAutoDetect: Bool
    var ocrMode: OCRMode
    var cacheEnabled: Bool
    var timeoutSeconds: Int
    var hotkeys: HotkeyBindings
    var interfaces: [LLMInterface]
    var maxCacheEntries: Int
    var historyRetentionLimit: Int
    /// Opacity of the floating result window background (0.35...1.0).
    /// Text is always drawn fully opaque; only the backdrop is affected.
    var resultOpacity: Double
    /// Raw value of SpeechVoiceFamily used for the 朗读 buttons.
    var speechVoiceFamily: String

    static let defaultTargetLanguage = "简体中文"
    static let targetLanguageOptions = ["简体中文", "繁体中文", "English", "日本語"]
    static let sourceLanguageOptions = ["auto", "简体中文", "繁体中文", "English", "日本語"]
    static let defaultResultOpacity: Double = 1.0
    static let resultOpacityRange: ClosedRange<Double> = 0.35...1.0

    static let `default` = AppSettings(
        targetLanguage: defaultTargetLanguage,
        sourceLanguage: "auto",
        sourceAutoDetect: true,
        ocrMode: .localVision,
        cacheEnabled: true,
        timeoutSeconds: 20,
        hotkeys: .default,
        interfaces: [],
        maxCacheEntries: 500,
        historyRetentionLimit: 500,
        resultOpacity: defaultResultOpacity,
        speechVoiceFamily: SpeechVoiceFamily.default.rawValue
    )

    private enum CodingKeys: String, CodingKey {
        case targetLanguage, sourceLanguage, sourceAutoDetect, ocrMode
        case cacheEnabled, timeoutSeconds, hotkeys, interfaces
        case maxCacheEntries, historyRetentionLimit, resultOpacity
        case speechVoiceFamily
    }

    init(
        targetLanguage: String = AppSettings.defaultTargetLanguage,
        sourceLanguage: String = "auto",
        sourceAutoDetect: Bool = true,
        ocrMode: OCRMode = .localVision,
        cacheEnabled: Bool = true,
        timeoutSeconds: Int = 20,
        hotkeys: HotkeyBindings = .default,
        interfaces: [LLMInterface] = [],
        maxCacheEntries: Int = 500,
        historyRetentionLimit: Int = 500,
        resultOpacity: Double = AppSettings.defaultResultOpacity,
        speechVoiceFamily: String = SpeechVoiceFamily.default.rawValue
    ) {
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.sourceAutoDetect = sourceAutoDetect
        self.ocrMode = ocrMode
        self.cacheEnabled = cacheEnabled
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.hotkeys = hotkeys
        self.interfaces = interfaces
        self.maxCacheEntries = max(1, maxCacheEntries)
        self.historyRetentionLimit = max(1, historyRetentionLimit)
        self.resultOpacity = min(max(resultOpacity, AppSettings.resultOpacityRange.lowerBound),
                                 AppSettings.resultOpacityRange.upperBound)
        // Unknown / stale values (e.g. a voice removed by a macOS update) fall
        // back to the recommended family instead of silently selecting nothing.
        self.speechVoiceFamily = SpeechVoiceFamily.from(speechVoiceFamily).rawValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetLanguage: try c.decodeIfPresent(String.self, forKey: .targetLanguage)
                ?? AppSettings.defaultTargetLanguage,
            sourceLanguage: try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? "auto",
            sourceAutoDetect: try c.decodeIfPresent(Bool.self, forKey: .sourceAutoDetect) ?? true,
            ocrMode: try c.decodeIfPresent(OCRMode.self, forKey: .ocrMode) ?? .localVision,
            cacheEnabled: try c.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? true,
            timeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 20,
            hotkeys: try c.decodeIfPresent(HotkeyBindings.self, forKey: .hotkeys) ?? .default,
            interfaces: try c.decodeIfPresent([LLMInterface].self, forKey: .interfaces) ?? [],
            maxCacheEntries: try c.decodeIfPresent(Int.self, forKey: .maxCacheEntries) ?? 500,
            historyRetentionLimit: try c.decodeIfPresent(Int.self, forKey: .historyRetentionLimit) ?? 500,
            resultOpacity: try c.decodeIfPresent(Double.self, forKey: .resultOpacity)
                ?? AppSettings.defaultResultOpacity,
            speechVoiceFamily: try c.decodeIfPresent(String.self, forKey: .speechVoiceFamily)
                ?? SpeechVoiceFamily.default.rawValue
        )
    }

    /// Source language actually sent in the prompt.
    var effectiveSourceLanguage: String {
        sourceAutoDetect ? "auto" : sourceLanguage
    }
}
