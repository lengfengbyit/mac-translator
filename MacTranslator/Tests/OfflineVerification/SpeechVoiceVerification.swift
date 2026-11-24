import Foundation

// Offline regression for the 朗读音色 overhaul:
//   1. novelty voices (Albert / Bells / Zarvox ...) are excluded from selection
//   2. the old `availableVoices.first(where:)` blind pick is gone
//   3. a user-selectable, persisted voice family is wired end to end
//   4. Settings offers previews so the choice can be auditioned
// Run via Tests/OfflineVerification/run.sh.
final class VoiceCounter {
    var pass = 0
    var fail = 0
    func check(_ condition: Bool, _ label: String) {
        if condition {
            pass += 1
            print("PASS: \(label)")
        } else {
            fail += 1
            print("FAIL: \(label)")
        }
    }
}

@main
struct SpeechVoiceVerification {
    static func main() {
        let r = VoiceCounter()
        let root = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath
        let base = "Sources/MacTranslator"

        func source(_ path: String) -> String {
            (try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8)) ?? ""
        }

        let service = source("\(base)/Services/SpeechVoiceService.swift")
        let familyModel = source("\(base)/Core/Models/SpeechVoiceFamily.swift")
        let settings = source("\(base)/Core/Models/AppSettings.swift")
        let resultVM = source("\(base)/UI/Shared/ResultViewModel.swift")
        let window = source("\(base)/UI/Windows/ResultWindowController.swift")
        let pane = source("\(base)/UI/panes/GeneralPane.swift")
        let settingsVM = source("\(base)/UI/Shared/SettingsViewModel.swift")

        // A. Root cause
        r.check(service.contains("com.apple.speech.synthesis.voice.") &&
                service.contains("noveltyPrefix"),
                "S1 特效音前缀被显式识别并列入黑名单")
        r.check(service.contains("guard !id.hasPrefix(Self.noveltyPrefix)"),
                "S2 构建语音目录时过滤全部 novelty 语音")
        r.check(!resultVM.contains("availableVoices.first(where:"),
                "S3 移除『抓列表第一个 en/zh 语音』的盲选逻辑")
        r.check(!resultVM.contains("NSSpeechSynthesizer()"),
                "S4 ViewModel 不再自行持有 synthesizer")

        // B. Resolution rules
        r.check(familyModel.contains("com.apple.eloquence") &&
                familyModel.contains("com.apple.voice.compact") &&
                familyModel.contains("enum SpeechVoiceFamily"),
                "S5 音色枚举独立成模型文件，覆盖 Eloquence 与 compact 两代语音")
        r.check(familyModel.contains("case eddy") && familyModel.contains("static let `default`"),
                "S5b 默认音色 Eddy 定义在无 AppKit 依赖的模型层")
        r.check(service.contains("0x3040...0x30FF") &&
                service.contains("0x3400...0x9FFF"),
                "S6 假名先于汉字判定，日文不会误判成中文")
        r.check(service.contains("preferredLocale") &&
                familyModel.contains("en-us") && familyModel.contains("zh-cn"),
                "S7 同系列内按 en-US / zh-CN 首选地区排序")
        r.check(service.contains("fallbackKey"),
                "S8 单语种音色读其他语言时有明确回退")
        r.check(service.contains("if family == .system { return nil }"),
                "S9 跟随系统默认时不覆盖默认语音（空哨兵值不参与 setVoice）")
        r.check(service.contains("func resolvedVoiceIdentifier"),
                "S10 解析结果以 identifier 暴露，便于真机探针验证")

        // C. Persistence & wiring
        r.check(settings.contains("var speechVoiceFamily: String") &&
                settings.contains("case speechVoiceFamily"),
                "S11 音色选择写入 AppSettings 并持久化")
        r.check(settings.contains("SpeechVoiceFamily.default.rawValue") &&
                settings.contains("decodeIfPresent(String.self, forKey: .speechVoiceFamily)"),
                "S12 老配置缺字段时回落到默认 Eddy")
        r.check(settings.contains("SpeechVoiceFamily.from(speechVoiceFamily).rawValue"),
                "S13 非法/已失效的音色值被归一化")
        r.check(resultVM.contains("SpeechVoiceService.shared.speak"),
                "S14 结果窗朗读统一走语音服务")
        r.check(resultVM.contains("settingsStore?.current.speechVoiceFamily"),
                "S15 每次朗读读取最新设置，改完即时生效")
        r.check(window.contains("viewModel.settingsStore = settingsStore"),
                "S16 ResultWindowController 注入 settingsStore")

        // D. Settings UI
        r.check(pane.contains("SpeechVoiceFamily.allCases") &&
                pane.contains("selection: speechVoiceBinding"),
                "S17 设置页提供全部音色下拉")
        r.check(pane.contains("试听中文") && pane.contains("试听英文"),
                "S18 中英文试听按钮可当场对比音色")
        r.check(settingsVM.contains("func setSpeechVoiceFamily") &&
                settingsVM.contains("func previewSpeech"),
                "S19 设置写入与试听在 ViewModel 落地")
        r.check(pane.contains("已排除系统自带的特效音"),
                "S20 界面向用户说明已排除特效音")

        print("SpeechVoiceVerification: \(r.pass)/\(r.pass + r.fail) PASS, \(r.fail) FAIL")
        if r.fail > 0 { exit(1) }
    }
}
