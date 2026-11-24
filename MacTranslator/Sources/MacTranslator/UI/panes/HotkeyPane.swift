import AppKit
import SwiftUI

struct HotkeyPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PaneHeader(title: "快捷键", detail: "全局快捷键 · 在任何 App 中均可唤起")
                InfoBanner(text: "点击右侧按键显示后直接按下新组合即可录制；若组合被系统或其他 App 占用，会显示冲突提示。")

                HotkeyRecorder(
                    title: "划词翻译",
                    detail: "选中文本后唤起翻译",
                    binding: vm.settings.hotkeys.selection
                ) { binding in
                    vm.updateHotkey(binding, for: .selection)
                }
                .frame(height: 56)

                HotkeyRecorder(
                    title: "OCR 翻译",
                    detail: "框选屏幕区域后识别翻译",
                    binding: vm.settings.hotkeys.ocr
                ) { binding in
                    vm.updateHotkey(binding, for: .ocr)
                }
                .frame(height: 56)

                HotkeyRecorder(
                    title: "输入翻译",
                    detail: "打开输入框，输入文字后按回车翻译",
                    binding: vm.settings.hotkeys.input
                ) { binding in
                    vm.updateHotkey(binding, for: .input)
                }
                .frame(height: 56)

                if let conflict = vm.hotkeyConflict {
                    Text(conflict)
                        .font(.system(size: 11.5))
                        .foregroundColor(.orange)
                }

                Divider()
                StatusRow(
                    title: "关闭结果窗",
                    detail: "也可点击窗外关闭",
                    status: "Esc"
                )
            }
            .padding(20)
        }
    }
}

/// Click-to-record hotkey control backed by a local NSEvent monitor.
private struct HotkeyRecorder: View {
    let title: String
    let detail: String
    let binding: HotkeyBinding
    let onRecord: (HotkeyBinding) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(recording ? "请按键…" : binding.displayString) {
                startRecording()
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 90)
            .foregroundColor(recording ? .orange : .primary)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels recording
                stopRecording()
                return nil
            }
            var modifiers: UInt32 = 0
            let flags = event.modifierFlags
            if flags.contains(.control) { modifiers |= 256 }
            if flags.contains(.shift) { modifiers |= 512 }
            if flags.contains(.option) { modifiers |= 2048 }
            if flags.contains(.command) { modifiers |= 4096 }
            let recorded = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stopRecording()
            onRecord(recorded)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }
}
