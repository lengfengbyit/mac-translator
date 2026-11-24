import AppKit
import Foundation

// SpeechVoiceFamily / SpeechLanguage live in Core/Models/SpeechVoiceFamily.swift
// so AppSettings and the offline suites do not need to link AppKit.

/// Resolves and plays system voices. All callers are on the main thread.
@MainActor
final class SpeechVoiceService {
    static let shared = SpeechVoiceService()

    private let synthesizer = NSSpeechSynthesizer()

    private struct Candidate {
        let identifier: String
        let locale: String
        let familyKey: String
    }

    /// Novelty voices are deliberately excluded from the entire catalog.
    private static let noveltyPrefix = "com.apple.speech.synthesis.voice."

    private lazy var catalog: [Candidate] = {
        NSSpeechSynthesizer.availableVoices.compactMap { voice in
            let id = voice.rawValue
            guard !id.hasPrefix(Self.noveltyPrefix) else { return nil }
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
            let locale = (attributes[.localeIdentifier] as? String ?? "")
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            let familyKey = id.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            return Candidate(identifier: id, locale: locale, familyKey: familyKey)
        }
    }()

    private init() {}

    /// Returns the identifier of the voice `speak(_:family:)` would use.
    /// Exposed for probes; the Swift name of `NSSpeechSynthesizerVoiceName`
    /// varies with the SDK, so identifiers are the portable currency here.
    func resolvedVoiceIdentifier(for text: String, family: SpeechVoiceFamily) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = Self.detectLanguage(trimmed)
        // `defaultVoice.rawValue` is an empty sentinel on macOS 15, not a real
        // identifier. Return nil so `speak` simply leaves the synthesizer alone.
        if family == .system { return nil }

        let pool = orderedCandidates(for: language)
        if let key = family.voiceKey {
            if let exact = pool.first(where: {
                $0.familyKey == key && $0.locale == language.preferredLocale
            }) {
                return exact.identifier
            }
            if let sameFamily = pool.first(where: { $0.familyKey == key }) {
                return sameFamily.identifier
            }
            if let fallback = family.fallbackKey(for: language),
               let hit = pool.first(where: { $0.familyKey == fallback }) {
                return hit.identifier
            }
        }
        return pool.first?.identifier
    }

    func speak(_ text: String, family: SpeechVoiceFamily) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() }
        if let identifier = resolvedVoiceIdentifier(for: trimmed, family: family),
           let voice = NSSpeechSynthesizer.availableVoices.first(where: { $0.rawValue == identifier }) {
            synthesizer.setVoice(voice)
        }
        synthesizer.startSpeaking(trimmed)
    }

    // MARK: Internals

    private static func detectLanguage(_ text: String) -> SpeechLanguage {
        let scalars = text.unicodeScalars
        // Kana before CJK: Japanese text also contains Han characters.
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .ja }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return .ko }
        if scalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return .zh }
        return .en
    }

    /// Natural voices only, preferred locale first, compact voices before
    /// Eloquence for generic fallbacks (they are the more neutral readers).
    private func orderedCandidates(for language: SpeechLanguage) -> [Candidate] {
        catalog.filter { $0.locale.hasPrefix(language.localePrefix) }
            .sorted { a, b in
                let aPreferred = a.locale == language.preferredLocale
                let bPreferred = b.locale == language.preferredLocale
                if aPreferred != bPreferred { return aPreferred }
                let aCompact = a.identifier.contains(".voice.compact.")
                let bCompact = b.identifier.contains(".voice.compact.")
                if aCompact != bCompact { return aCompact }
                return a.identifier < b.identifier
            }
    }
}
