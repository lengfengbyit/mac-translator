import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published var interfaces: [LLMInterface]
    @Published var permissionStates: [PermissionType: PermissionStatus] = [:]
    @Published var hotkeyConflict: String?
    @Published var testingEndpointID: UUID?

    let toast = ToastCenter()

    private let store: SettingsStoring
    private let gateway: LLMProviding
    private let cache: CacheStoring
    private let history: HistoryStoring
    private let permissions: PermissionService
    private let hotkeyService: HotkeyService?

    init(
        store: SettingsStoring,
        gateway: LLMProviding,
        cache: CacheStoring,
        history: HistoryStoring,
        permissions: PermissionService,
        hotkeyService: HotkeyService? = nil
    ) {
        self.store = store
        self.gateway = gateway
        self.cache = cache
        self.history = history
        self.permissions = permissions
        self.hotkeyService = hotkeyService
        let initialSettings = store.current
        self.settings = initialSettings
        self.interfaces = initialSettings.interfaces
        self.permissionStates = permissions.states
    }

    // MARK: Permissions

    func refreshPermissions() {
        permissions.refresh()
        permissionStates = permissions.states
    }

    func startPermissionPolling() {
        permissions.startPolling()
    }

    func stopPermissionPolling() {
        permissions.stopPolling()
    }

    func requestPermission(_ type: PermissionType) {
        permissions.requestIfNeeded(type: type)
        refreshPermissions()
    }

    func openPermissionSettings(_ type: PermissionType) {
        permissions.openSettings(type: type)
    }

    // MARK: General settings

    func setTargetLanguage(_ language: String) {
        updateSettings { $0.targetLanguage = language }
    }

    func setSourceAutoDetect(_ enabled: Bool) {
        updateSettings { $0.sourceAutoDetect = enabled }
    }

    func updateSourceLanguage(_ language: String) {
        updateSettings { $0.sourceLanguage = language }
    }

    func setCacheEnabled(_ enabled: Bool) {
        updateSettings { $0.cacheEnabled = enabled }
    }

    func setResultOpacity(_ value: Double) {
        updateSettings { $0.resultOpacity = value }
    }

    func setSpeechVoiceFamily(_ family: String) {
        updateSettings { $0.speechVoiceFamily = family }
    }

    /// Plays a short sample so a voice family can be compared before translating.
    func previewSpeech(language: String) {
        let sample = language == "zh"
            ? "这是一段中文朗读示例，用来试听当前音色。"
            : "This is a sample of the English reading voice for Mac Translator."
        SpeechVoiceService.shared.speak(
            sample,
            family: SpeechVoiceFamily.from(settings.speechVoiceFamily)
        )
    }

    func setOCRMode(_ mode: OCRMode) {
        updateSettings { $0.ocrMode = mode }
        toast.show("已切换为：\(mode.displayName)")
    }

    func clearAllData() {
        cache.clear()
        do {
            try history.clearAll()
            toast.show("历史与缓存已清除")
        } catch {
            toast.show("清除失败：\(error.localizedDescription)")
        }
    }

    // MARK: Interfaces

    func addInterface() {
        let nextPriority = (interfaces.map(\.priority).max() ?? 0) + 1
        let endpoint = LLMInterface(priority: nextPriority)
        interfaces.append(endpoint)
        persistInterfaces()
        toast.show("已添加接口，请填写配置")
    }

    func removeInterface(id: UUID) {
        // The key lives on the endpoint itself, so deleting the endpoint also
        // removes its key from settings.json. No Keychain cleanup is needed.
        interfaces.removeAll { $0.id == id }
        persistInterfaces()
        toast.show("接口已删除")
    }

    func updateInterface(_ endpoint: LLMInterface) {
        guard let index = interfaces.firstIndex(where: { $0.id == endpoint.id }) else { return }
        interfaces[index] = endpoint
        persistInterfaces()
    }

    /// Moves the dragged endpoint to the current position of the target endpoint.
    /// Stable UUIDs keep drag/drop correct after earlier reorders or deletions.
    func moveInterface(id draggedID: UUID, before targetID: UUID) {
        guard let from = interfaces.firstIndex(where: { $0.id == draggedID }),
              let to = interfaces.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        moveInterface(from: IndexSet(integer: from), to: to)
    }

    /// Reorders all interfaces and renumbers priority from 1.
    func moveInterface(from source: IndexSet, to destination: Int) {
        interfaces.move(fromOffsets: source, toOffset: destination)
        renumberAndPersist()
        toast.show("优先级已更新")
    }

    func nudgeInterface(id: UUID, direction: Int) {
        guard let from = interfaces.firstIndex(where: { $0.id == id }) else { return }
        let to = from + direction
        guard interfaces.indices.contains(to) else { return }
        interfaces.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        renumberAndPersist()
        toast.show("优先级已更新")
    }

    /// Never returns the full key, only a masked placeholder.
    func maskedKey(for id: UUID) -> String {
        guard let endpoint = interfaces.first(where: { $0.id == id }),
              let key = endpoint.apiKey, !key.isEmpty else { return "未设置" }
        return "sk-****"
    }

    /// API keys are stored plaintext in the local settings.json (no Keychain,
    /// no system authorization prompt). The UI only ever shows a masked value,
    /// and no key is ever written to a log or a toast.
    func saveAPIKey(_ key: String, for id: UUID) {
        guard let index = interfaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : trimmed
        guard interfaces[index].apiKey != next else { return }
        interfaces[index].apiKey = next
        persistInterfaces()
        toast.show(trimmed.isEmpty ? "apiKey 已清除" : "apiKey 已保存到本地配置")
    }

    func testInterface(_ endpoint: LLMInterface) async {
        testingEndpointID = endpoint.id
        defer { testingEndpointID = nil }
        do {
            let outcome = try await gateway.test(endpoint)
            toast.show(outcome.success ? "「\(endpoint.name)」测试成功" : "「\(endpoint.name)」\(outcome.message)")
        } catch {
            toast.show("「\(endpoint.name)」测试失败：\(error.localizedDescription)")
        }
    }

    // MARK: Hotkeys

    func updateHotkey(_ binding: HotkeyBinding, for action: HotkeyAction) {
        updateSettings { settings in
            switch action {
            case .selection: settings.hotkeys.selection = binding
            case .ocr: settings.hotkeys.ocr = binding
            }
        }
        hotkeyService?.reregister()
        hotkeyConflict = hotkeyService?.conflictMessage
        if hotkeyConflict == nil {
            toast.show("快捷键已更新")
        }
    }

    // MARK: Internals

    private func renumberAndPersist() {
        for index in interfaces.indices {
            interfaces[index].priority = index + 1
        }
        persistInterfaces()
    }

    private func persistInterfaces() {
        updateSettings { $0.interfaces = self.interfaces }
    }

    private func updateSettings(_ block: (inout AppSettings) -> Void) {
        var next = settings
        block(&next)
        do {
            try store.update(next)
            settings = next
            interfaces = next.interfaces
        } catch {
            toast.show("保存失败：\(error.localizedDescription)")
        }
    }
}
