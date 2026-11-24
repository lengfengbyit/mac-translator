import Foundation
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(title: "通用", detail: "翻译语言、结果窗外观与数据管理，修改即时保存")

                Divider()

                Text("结果窗外观")
                    .font(.system(size: 13.5, weight: .semibold))
                HStack(spacing: 8) {
                    Text("背景不透明度")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int((vm.settings.resultOpacity * 100).rounded()))%")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(value: resultOpacityBinding, in: AppSettings.resultOpacityRange, step: 0.01)
                    .frame(maxWidth: 440)
                Text("数值越大背景越实、内容越清晰；文字本身始终保持完全不透明，只有背景受影响。调整后即时生效。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                HStack(spacing: 14) {
                    Button("恢复默认不透明度") { vm.setResultOpacity(AppSettings.defaultResultOpacity) }
                        .buttonStyle(.borderless)
                    Button("重置结果窗位置") {
                        NotificationCenter.default.post(name: .resultPanelResetPosition, object: nil)
                    }
                    .buttonStyle(.borderless)
                }
                Text("拖动结果窗顶部的标题栏即可移动窗口，位置会自动记住，下次翻译仍在原处显示。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)

                Divider()

                Text("目标语言")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("翻译结果使用的语言")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Picker("", selection: targetLanguageBinding) {
                    ForEach(AppSettings.targetLanguageOptions, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                Divider()

                Text("源语言自动检测")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("关闭后可手动指定源语言")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Toggle("自动检测源语言", isOn: autoDetectBinding)
                    .toggleStyle(.switch)
                if !vm.settings.sourceAutoDetect {
                    Picker("源语言", selection: sourceLanguageBinding) {
                        ForEach(AppSettings.sourceLanguageOptions.filter { $0 != "auto" }, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    .frame(width: 220)
                }

                Divider()

                Toggle("结果缓存", isOn: cacheBinding)
                    .toggleStyle(.switch)
                Text("相同内容命中缓存，省钱提速并减少数据外发；缓存上限 500 条，LRU 淘汰。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("清除历史与缓存")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("本地数据不会上传，清除后不可恢复")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("清除…") { showClearConfirm = true }
                        .buttonStyle(.borderless)
                }
            }
            .padding(20)
        }
        .alert("清除所有历史与缓存？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { vm.clearAllData() }
        }
    }

    private var targetLanguageBinding: Binding<String> {
        Binding(get: { vm.settings.targetLanguage }, set: { vm.setTargetLanguage($0) })
    }

    private var autoDetectBinding: Binding<Bool> {
        Binding(get: { vm.settings.sourceAutoDetect }, set: { vm.setSourceAutoDetect($0) })
    }

    private var sourceLanguageBinding: Binding<String> {
        Binding(
            get: { vm.settings.sourceLanguage },
            set: { language in
                vm.setSourceAutoDetect(false)
                vm.updateSourceLanguage(language)
            }
        )
    }

    private var cacheBinding: Binding<Bool> {
        Binding(get: { vm.settings.cacheEnabled }, set: { vm.setCacheEnabled($0) })
    }

    private var resultOpacityBinding: Binding<Double> {
        Binding(get: { vm.settings.resultOpacity }, set: { vm.setResultOpacity($0) })
    }
}
