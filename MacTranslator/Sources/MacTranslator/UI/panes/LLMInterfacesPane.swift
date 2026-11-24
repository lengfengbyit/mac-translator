import SwiftUI

struct LLMInterfacesPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var draggingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader(
                title: "LLM 接口",
                detail: "OpenAI 兼容格式 · 按优先级从上到下依次调用，切换即时保存"
            )
            InfoBanner(text: "调用规则：每次仅调用一个接口，取启用接口中优先级最高的；仅当失败（网络错误 / 超时 / HTTP 非 2xx / 响应不合法）才降级到下一个。可用 ↑↓ 或拖拽卡片调整顺序，文本在回车或移开焦点时保存。")
            Text("密钥以明文保存在本地配置文件 settings.json，不再使用系统钥匙串，也不会弹授权框。请勿把该配置文件放到共享或云同步目录。")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            // A plain ScrollView + VStack, NOT List. On macOS List is
            // NSTableView-backed: the first click selects the row and never
            // makes an embedded TextField first responder, so fields appear
            // unselectable and Cmd+V / Delete do nothing. Plain views keep the
            // native field editor fully interactive.
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    // Identity is the endpoint UUID, never the array index.
                    ForEach(vm.interfaces, id: \.id) { endpoint in
                        InterfaceCard(vm: vm, endpoint: endpoint, draggingID: $draggingID)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                            // Drop destination only. The drag source lives on
                            // the numbered handle inside the card so no drag
                            // recognizer covers any text field.
                            .onDrop(of: [.text], isTargeted: nil) { _ in
                                guard let from = draggingID, from != endpoint.id else { return false }
                                vm.moveInterface(id: from, before: endpoint.id)
                                draggingID = nil
                                return true
                            }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 350)

            HStack {
                Button("＋ 添加接口") { vm.addInterface() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Text("共 \(vm.interfaces.count) 个接口 · 已启用 \(vm.interfaces.filter { $0.enabled }.count) 个")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

private struct InterfaceCard: View {
    @ObservedObject var vm: SettingsViewModel
    let endpoint: LLMInterface
    @Binding var draggingID: UUID?

    private enum Field: Hashable { case name, model, baseURL, apiKey }

    // Local buffers. Binding each keystroke straight into the view model used
    // to republish `interfaces` (plus a JSON disk write) on every character,
    // which rebuilt every row and dropped the field editor mid-typing.
    // We now publish only on submit / focus loss / disappearance.
    @State private var nameText: String
    @State private var modelText: String
    @State private var baseURLText: String
    @State private var keyText = ""
    @State private var keyEdited = false
    @FocusState private var focused: Field?

    init(vm: SettingsViewModel, endpoint: LLMInterface, draggingID: Binding<UUID?>) {
        self.vm = vm
        self.endpoint = endpoint
        self._draggingID = draggingID
        self._nameText = State(initialValue: endpoint.name)
        self._modelText = State(initialValue: endpoint.model)
        self._baseURLText = State(initialValue: endpoint.baseURL)
    }

    /// Position derived from the current array, never stored in view identity.
    private var index: Int {
        vm.interfaces.firstIndex(where: { $0.id == endpoint.id }) ?? 0
    }

    var body: some View {
        let position = index
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(endpoint.enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                Text("\(position + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 25, height: 25)
            .onDrag {
                draggingID = endpoint.id
                return NSItemProvider(object: endpoint.id.uuidString as NSString)
            }
            .help("拖拽调整顺序")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    TextField("名称", text: $nameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .focused($focused, equals: .name)
                        .onSubmit { commitTextFields() }

                    TextField("model", text: $modelText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .focused($focused, equals: .model)
                        .onSubmit { commitTextFields() }

                    Toggle("启用", isOn: binding(\.enabled))
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Spacer(minLength: 4)

                    Button(action: {
                        Task { await vm.testInterface(endpoint) }
                    }) {
                        Image(systemName: vm.testingEndpointID == endpoint.id ? "hourglass" : "paperplane")
                    }
                    .buttonStyle(.borderless)
                    .help("测试接口")
                    .disabled(vm.testingEndpointID == endpoint.id)

                    Button(role: .destructive, action: { vm.removeInterface(id: endpoint.id) }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除接口")
                }

                HStack(spacing: 8) {
                    TextField("baseURL（如 https://api.xxx.com/v1）", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .baseURL)
                        .onSubmit { commitTextFields() }

                    // Never seed SecureField with a fake masked value: typing
                    // would append to "sk-****" and persist a corrupt key.
                    // Status is shown separately, read from the local config.
                    SecureField("apiKey（输入后回车或移开焦点保存）", text: Binding(
                        get: { keyText },
                        set: { keyText = $0; keyEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .focused($focused, equals: .apiKey)
                    .onSubmit {
                        commitAPIKey()
                        focused = nil
                    }
                }

                HStack(spacing: 12) {
                    Toggle("支持视觉（多模态 OCR）", isOn: binding(\.supportsVision))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Text(vm.maskedKey(for: endpoint.id))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 3) {
                Button("↑") { vm.nudgeInterface(id: endpoint.id, direction: -1) }
                    .buttonStyle(.borderless)
                    .disabled(position == 0)
                Button("↓") { vm.nudgeInterface(id: endpoint.id, direction: 1) }
                    .buttonStyle(.borderless)
                    .disabled(position == vm.interfaces.count - 1)
            }
        }
        .onChange(of: focused) { newValue in
            // Any focus transition is a natural commit point; both commits are
            // idempotent (guarded by change detection / keyEdited).
            commitTextFields()
            if newValue != .apiKey { commitAPIKey() }
        }
        .onDisappear {
            commitTextFields()
            commitAPIKey()
        }
    }

    /// Publishes buffered text only when it actually changed.
    private func commitTextFields() {
        guard var current = vm.interfaces.first(where: { $0.id == endpoint.id }) else { return }
        guard current.name != nameText
                || current.model != modelText
                || current.baseURL != baseURLText else { return }
        current.name = nameText
        current.model = modelText
        current.baseURL = baseURLText
        vm.updateInterface(current)
    }

    /// Saves only after an actual edit; clearing the field deletes the stored key.
    private func commitAPIKey() {
        guard keyEdited, vm.interfaces.contains(where: { $0.id == endpoint.id }) else { return }
        vm.saveAPIKey(keyText, for: endpoint.id)
        keyText = ""
        keyEdited = false
    }

    /// Reads/writes the freshest model value, avoiding stale copies that could
    /// overwrite another field when two controls change in sequence.
    private func binding<T>(_ keyPath: WritableKeyPath<LLMInterface, T>) -> Binding<T> {
        Binding(
            get: {
                (vm.interfaces.first(where: { $0.id == endpoint.id }) ?? endpoint)[keyPath: keyPath]
            },
            set: { value in
                guard var current = vm.interfaces.first(where: { $0.id == endpoint.id }) else { return }
                current[keyPath: keyPath] = value
                vm.updateInterface(current)
            }
        )
    }
}
