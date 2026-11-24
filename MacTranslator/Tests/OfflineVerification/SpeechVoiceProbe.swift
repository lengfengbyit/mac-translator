import AppKit
import Foundation

/// Runs the REAL SpeechVoiceService against the voices installed on this Mac.
/// Compile with Sources/MacTranslator/Services/SpeechVoiceService.swift.
@main
struct SpeechVoiceProbe {
    @MainActor
    static func main() {
        let service = SpeechVoiceService.shared
        let english = "This is a sample of the English reading voice."
        let chinese = "这是一段中文朗读示例，用来试听当前音色。"
        let japanese = "これは日本語の朗読テストです。"
        let korean = "이것은 한국어 음성 테스트입니다."

        print("available voices:", NSSpeechSynthesizer.availableVoices.count)
        print("system default:", NSSpeechSynthesizer.defaultVoice.rawValue)
        print("default family:", SpeechVoiceFamily.default.rawValue)
        print("")
        print("family      | en                                             | zh                                             | ja / ko")
        for family in SpeechVoiceFamily.allCases {
            let en = service.resolvedVoiceIdentifier(for: english, family: family) ?? "nil"
            let zh = service.resolvedVoiceIdentifier(for: chinese, family: family) ?? "nil"
            let ja = service.resolvedVoiceIdentifier(for: japanese, family: family) ?? "nil"
            let ko = service.resolvedVoiceIdentifier(for: korean, family: family) ?? "nil"
            print("\(family.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) | "
                  + "\(en.padding(toLength: 46, withPad: " ", startingAt: 0)) | "
                  + "\(zh.padding(toLength: 46, withPad: " ", startingAt: 0)) | \(ja) / \(ko)")
        }

        var pass = 0, fail = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { pass += 1; print("PASS:", label) }
            else { fail += 1; print("FAIL:", label) }
        }

        let novelty = "com.apple.speech.synthesis.voice."
        let cases: [(String, SpeechVoiceFamily)] = [
            (english, .eddy), (chinese, .eddy), (japanese, .eddy), (korean, .eddy),
            (english, .samantha), (chinese, .samantha), (english, .daniel),
            (chinese, .tingting), (english, .tingting),             (english, .flo),
            (chinese, .flo)
        ]
        for (text, family) in cases {
            let id = service.resolvedVoiceIdentifier(for: text, family: family) ?? ""
            check(!id.isEmpty, "V0 \(family.rawValue) resolves a voice")
            check(!id.hasPrefix(novelty), "V1 \(family.rawValue) never picks a novelty voice")
        }

        let eddyEN = service.resolvedVoiceIdentifier(for: english, family: .eddy) ?? ""
        let eddyZH = service.resolvedVoiceIdentifier(for: chinese, family: .eddy) ?? ""
        check(eddyEN == "com.apple.eloquence.en-US.Eddy",
              "V2 default English = Eddy en-US (was Albert novelty)")
        check(eddyZH == "com.apple.eloquence.zh-CN.Eddy",
              "V3 default Chinese unchanged = Eddy zh-CN")
        check(eddyEN.split(separator: ".").last == eddyZH.split(separator: ".").last,
              "V4 English and Chinese use the same speaker family")
        check(service.resolvedVoiceIdentifier(for: english, family: .samantha)
              == "com.apple.voice.compact.en-US.Samantha",
              "V5 Samantha family resolves classic en-US voice")
        check(service.resolvedVoiceIdentifier(for: english, family: .tingting)
              == "com.apple.voice.compact.en-US.Samantha",
              "V6 婷婷 falls back to Samantha when reading English")
        check(service.resolvedVoiceIdentifier(for: chinese, family: .samantha)
              == "com.apple.voice.compact.zh-CN.Tingting",
              "V7 Samantha falls back to 婷婷 when reading Chinese")
        check(service.resolvedVoiceIdentifier(for: japanese, family: .eddy)?.contains("ja") == true,
              "V8 Japanese text resolves a ja voice")
        check(SpeechVoiceFamily.from("not-a-family") == .eddy,
              "V9 unknown stored family falls back to default")
        check(service.resolvedVoiceIdentifier(for: english, family: .system) == nil,
              "V10 system family leaves the synthesizer default untouched")

        print("SpeechVoiceProbe: \(pass)/\(pass + fail) PASS, \(fail) FAIL")
        if fail > 0 { exit(1) }
    }
}
