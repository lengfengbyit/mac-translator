import SwiftUI

struct OCRPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(title: "OCR 识别", detail: "选择截图后的识别方式，切换即时生效并保存")
                Picker("", selection: modeBinding) {
                    ForEach(OCRMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                modeCard(
                    icon: "🍎",
                    title: "本地 Vision（默认）",
                    detail: "使用系统 VNRecognizeTextRequest 在本地识别文字（zh-Hans / en-US），再将文字交给 LLM 翻译。无需联网、零 OCR 成本，隐私保护更好。",
                    tags: ["离线可用", "零成本", "macOS 11+", "印刷体准确"]
                )
                modeCard(
                    icon: "👁️",
                    title: "多模态 LLM",
                    detail: "将截图直接发送给支持视觉的模型，由其识别并翻译。复杂版式 / 图文混排效果更好，但按图计费且需联网。仅调用已勾选「支持视觉」的接口。",
                    tags: ["高精度", "复杂版式", "按量计费", "需联网"]
                )

                StatusRow(
                    title: "识别语言",
                    detail: "简体中文 / 英文（本地模式固定）",
                    status: "zh-Hans, en-US"
                )
                Divider()
                StatusRow(
                    title: "屏幕录制权限",
                    detail: "区域截图必需。未授权时框选仍会成功，但只能截到桌面壁纸，OCR 会提示识别不到文字",
                    status: vm.permissionStates[.screenRecording]?.displayText ?? "◌ 需确认",
                    statusColor: (vm.permissionStates[.screenRecording]?.isGranted ?? false) ? .green : .orange,
                    actionTitle: "前往设置"
                ) {
                    vm.openPermissionSettings(.screenRecording)
                }
                InfoBanner(text: "在系统设置中打开「划译」的屏幕录制开关后回到本页，状态会自动刷新；如仍显示未授权，请退出并重新打开本应用。")
            }
            .padding(20)
        }
    }

    private var modeBinding: Binding<OCRMode> {
        Binding(
            get: { vm.settings.ocrMode },
            set: { vm.setOCRMode($0) }
        )
    }

    private func modeCard(icon: String, title: String, detail: String, tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(icon)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(9)
    }
}
