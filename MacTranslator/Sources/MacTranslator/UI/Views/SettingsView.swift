import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case llm
    case ocr
    case general
    case permission
    case hotkey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .llm: return "LLM 接口"
        case .ocr: return "OCR 识别"
        case .general: return "通用"
        case .permission: return "权限"
        case .hotkey: return "快捷键"
        }
    }

    var icon: String {
        switch self {
        case .llm: return "cpu"
        case .ocr: return "eye"
        case .general: return "slider.horizontal.3"
        case .permission: return "lock.shield"
        case .hotkey: return "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var selection: SettingsPane = .llm

    var body: some View {
        NavigationView {
            List(SettingsPane.allCases, id: \.self, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, maxWidth: 190)

            Group {
                switch selection {
                case .llm: LLMInterfacesPane(vm: vm)
                case .ocr: OCRPane(vm: vm)
                case .general: GeneralPane(vm: vm)
                case .permission: PermissionPane(vm: vm)
                case .hotkey: HotkeyPane(vm: vm)
                }
            }
            .frame(minWidth: 500, idealWidth: 610, maxHeight: .infinity)
        }
        .frame(width: 780, height: 560)
        .toast(center: vm.toast)
        .onAppear {
            vm.refreshPermissions()
            vm.startPermissionPolling()
        }
        .onDisappear {
            vm.stopPermissionPolling()
        }
    }
}
