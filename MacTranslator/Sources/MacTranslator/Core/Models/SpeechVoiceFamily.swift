import Foundation

/// Voice families offered in Settings → General → 朗读音色.
///
/// Kept in a dependency-free model file: AppSettings only needs the raw value,
/// and the offline verification suites compile AppSettings without AppKit.
///
/// Apple ships two generations of "real" voices on modern macOS:
///   - `com.apple.eloquence.<locale>.<Name>`  (Eddy / Flo / Reed / ...)
///   - `com.apple.voice.compact.<locale>.<Name>` (Samantha / Daniel / Tingting / ...)
/// and a bag of legacy novelty voices under `com.apple.speech.synthesis.voice.*`
/// (Albert, Bells, Boing, Zarvox, ...). `availableVoices` puts the novelty ones
/// first, so an innocent `first(where: { locale.hasPrefix("en") })` used to pick
/// "Albert" — a joke robot voice — for every English reading.
enum SpeechVoiceFamily: String, Codable, CaseIterable, Identifiable {
    case eddy
    case flo
    case reed
    case rocko
    case sandy
    case shelley
    case samantha
    case daniel
    case tingting
    case system

    var id: String { rawValue }

    /// Eddy is the default: the Chinese Eddy voice is the one users already
    /// liked, and the en-US Eddy is the same speaker in another language.
    static let `default`: SpeechVoiceFamily = .eddy

    static func from(_ rawValue: String?) -> SpeechVoiceFamily {
        SpeechVoiceFamily(rawValue: rawValue ?? "") ?? .default
    }

    var displayName: String {
        switch self {
        case .eddy: return "Eddy（推荐 · 中英同款）"
        case .flo: return "Flo"
        case .reed: return "Reed"
        case .rocko: return "Rocko"
        case .sandy: return "Sandy"
        case .shelley: return "Shelley"
        case .samantha: return "Samantha（经典美式）"
        case .daniel: return "Daniel（英式）"
        case .tingting: return "婷婷（经典中文）"
        case .system: return "跟随系统默认"
        }
    }

    var detail: String {
        switch self {
        case .eddy:
            return "英文与中文使用同一把嗓子：英文 Eddy (en-US)，中文 Eddy (zh-CN)。"
        case .samantha:
            return "macOS 经典美式女声；读中文时回退到婷婷。"
        case .daniel:
            return "英式男声；读中文时回退到婷婷。"
        case .tingting:
            return "经典中文女声；读英文时回退到 Samantha。"
        case .system:
            return "直接使用系统设置里的默认语音，不做语言匹配。"
        default:
            return "Apple Eloquence 音色，按文本语言自动选择同系列的对应语种。"
        }
    }

    /// Last component of the voice identifier, lowercased.
    var voiceKey: String? {
        self == .system ? nil : rawValue
    }

    /// When the chosen family has no voice for a language, prefer this one.
    func fallbackKey(for language: SpeechLanguage) -> String? {
        switch (self, language) {
        case (.samantha, .zh), (.daniel, .zh): return "tingting"
        case (.tingting, .en): return "samantha"
        default: return nil
        }
    }
}

enum SpeechLanguage: String {
    case zh, en, ja, ko

    var localePrefix: String { rawValue }
    var preferredLocale: String {
        switch self {
        case .zh: return "zh-cn"
        case .en: return "en-us"
        case .ja: return "ja-jp"
        case .ko: return "ko-kr"
        }
    }
}
