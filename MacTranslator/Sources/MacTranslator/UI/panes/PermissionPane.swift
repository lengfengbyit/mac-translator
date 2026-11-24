import SwiftUI

struct PermissionPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PaneHeader(title: "权限", detail: "按需申请 · 一键跳转系统设置 · 未授权功能将禁用")

                ForEach(PermissionType.allCases) { type in
                    let status = vm.permissionStates[type] ?? .unknown
                    StatusRow(
                        title: type.displayName,
                        detail: type.purpose,
                        status: status.displayText,
                        statusColor: status.isGranted ? .green : .orange,
                        actionTitle: "前往设置"
                    ) {
                        vm.openPermissionSettings(type)
                    }
                    Divider()
                }

                HStack {
                    Button("重新检测权限") { vm.refreshPermissions() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.top, 4)

                InfoBanner(text: "隐私提示：选中的文本与屏幕截图会发送给你配置的第三方 LLM 服务。请自行评估其隐私政策；可配置本地 Ollama 接口（http://localhost:11434/v1）实现零外发。")
            }
            .padding(20)
        }
    }
}
