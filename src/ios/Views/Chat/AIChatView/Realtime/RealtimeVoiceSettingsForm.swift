import SwiftUI

/// 「实时语音」设置（服务商 / 模型 / 协议 / 声音 / 百炼地域）：从 RealtimeVoiceView 拆出来，
/// App 设置、Bot 编辑页、声波按钮长按、接不通时的提示里都用这一份。给了 botId 时顶部多一段「这个 Bot 单独设置」。
struct RealtimeVoiceSettingsScreen: View {
    private let botId: String?
    @MainActor init(botId: String? = nil) { self.botId = botId }

    var body: some View {
        RealtimeVoiceSettingsForm(botId: botId)
            .navigationTitle("实时语音").navigationBarTitleDisplayMode(.inline)
    }
}

/// 弹出来用的版本：自带导航栏和「完成」
struct RealtimeVoiceSettingsSheet: View {
    private let botId: String?
    @Environment(\.dismiss) private var dismiss
    @MainActor init(botId: String? = nil) { self.botId = botId }

    var body: some View {
        NavigationStack {
            RealtimeVoiceSettingsScreen(botId: botId)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// 设置表单本体。验证连接用自己的一个会话（只建会话、不开麦）
struct RealtimeVoiceSettingsForm: View {
    let botId: String?
    @ObservedObject private var providers = ProviderConfigStore.shared
    @StateObject private var session = RealtimeVoiceSession(host: RealtimeCloudBotHost(botName: "验证", persona: "", sessionId: "", history: [],
                                                                                         delegate: { _ in nil }, onSaved: { _ in }))
    @AppStorage("realtimeVoice.provider") private var providerID = ""
    @AppStorage("realtimeVoice.model") private var model = ""
    @AppStorage("realtimeVoice.voice") private var voice = "alloy"
    @AppStorage("realtimeVoice.preview") private var preview = false
    @AppStorage("realtimeVoice.protocolsByProvider") private var protocolsByProvider = "{}"
    @AppStorage("realtimeVoice.dashscopeRegion") private var dashscopeRegion = ""
    @AppStorage("realtimeVoice.dashscopeWorkspace") private var dashscopeWorkspace = ""
    @AppStorage("realtimeVoice.modelsByProvider") private var modelSelections = "{}"
    @State private var protocolMode = "automatic"
    @State private var selectionProvider = ""
    @StateObject private var catalog = RealtimeModelCatalog()

    private var selectedProtocol: RealtimeConnectionProtocol? { try? RealtimeConnectionProtocol.resolve(protocolMode, model: model) }
    private var availableVoices: [String] { selectedProtocol?.voices(model: model) ?? RealtimeConnectionProtocol.openAIVoices }
    private var supportedProviders: [ProviderInstance] { Self.supportedProviders(providers) }

    /// 能接实时语音的服务商（OpenAI / Responses / Gemini 兼容、API 密钥、已启用）
    @MainActor static func supportedProviders(_ store: ProviderConfigStore) -> [ProviderInstance] {
        store.instances.filter { $0.isEnabled && ($0.providerType == .openAI || $0.providerType == .openAIResponses || $0.providerType == .gemini) && $0.credentialType == .apiKey }
    }

    var body: some View {
        Form {
            if let botId { RealtimeBotOverrideSection(botId: botId) }
            Section {
                Picker("服务商", selection: $providerID) {
                    Text("请选择").tag("")
                    ForEach(supportedProviders, id: \.id) { provider in Text(provider.label).tag(provider.id) }
                }
                NavigationLink {
                    RealtimeModelPicker(catalog: catalog, model: $model, refresh: refreshCatalog)
                } label: {
                    LabeledContent("选择语音模型", value: model.isEmpty ? "请选择" : model)
                }.disabled(providerID.isEmpty)
                Button {
                    Task { await refreshCatalog() }
                } label: {
                    HStack {
                        Label("刷新服务商模型", systemImage: "arrow.clockwise")
                        Spacer()
                        if catalog.loading { ProgressView() }
                    }
                }.disabled(providerID.isEmpty || catalog.loading)
                if let error = catalog.error {
                    Text("刷新失败：\(error)\n仍可查看已有列表或手动填写。").font(.footnote).foregroundStyle(.red)
                } else if let updated = catalog.updatedAt {
                    Text("已获取 \(catalog.models.count) 个模型 · \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(catalog.loading ? "正在获取服务商完整模型列表…" : "当前为本地列表，尚未在线验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField("手动填写模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: model) { preview = $0.contains("preview") }
                Picker("实时协议", selection: $protocolMode) {
                    ForEach(RealtimeConnectionProtocol.allCases) { item in Text(item.title).tag(item.rawValue) }
                }
                Text(selectedProtocol.map { "将使用：\($0.title)" } ?? "此名称没有可识别的 Gemini Live 标识。请选择 Live/native-audio 型号；已确认的实时别名可手动选择协议。")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("声音", selection: $voice) {
                    ForEach(availableVoices, id: \.self) { Text($0).tag($0) }
                }
                if selectedProtocol == .dashScope {
                    RealtimeDashScopeFields(region: $dashscopeRegion, workspace: $dashscopeWorkspace, model: model)
                }
                Button {
                    Task { await session.start(providerID: providerID, model: model.trimmingCharacters(in: .whitespacesAndNewlines), voice: voice, preview: preview, protocolMode: protocolMode, validateOnly: true) }
                } label: { Label(session.active ? "验证中…" : "验证实时连接（不开麦）", systemImage: "checkmark.shield") }
                .disabled(session.active || providerID.isEmpty || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let result = session.validationResult { Text(result).font(.footnote).foregroundStyle(.green) }
                if let error = session.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                Text("验证只建立所选模型会话，不传录音和聊天历史。服务商可能对会话建立收费。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text(botId == nil ? "实时音频服务" : "全局默认（没单独设置的 Bot 都用这个）")
            }
            Section {
                Text("需要服务商开放双向 Realtime 音频接口。列出模型名不保证实时通道可用；连接失败时可更换服务商。密钥直接使用服务商设置中的现有凭据。")
                Text("本模式传送当前聊天文字与灵魂设定。语音通话暂不执行终端、浏览器等工具，挂断后可在普通聊天中继续。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .refreshable { await refreshCatalog() }
        .onAppear { chooseInitialProvider() }
        .task(id: providerID) {
            prepareCatalog()
            await refreshCatalog()
        }
        .onChange(of: model) { value in
            guard selectionProvider == providerID else { return }
            saveSelection(value, for: providerID)
            voice = selectedProtocol?.normalizedVoice(voice, model: model) ?? "alloy"
        }
        .onChange(of: protocolMode) { value in
            guard selectionProvider == providerID else { return }
            var saved = (try? JSONDecoder().decode([String: String].self, from: Data(protocolsByProvider.utf8))) ?? [:]
            saved[providerID] = value
            if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { protocolsByProvider = text }
            voice = selectedProtocol?.normalizedVoice(voice, model: model) ?? "alloy"
        }
        .onDisappear { session.finish() }
    }

    private func chooseInitialProvider() {
        guard !supportedProviders.contains(where: { $0.id == providerID }) else { return }
        if let entry = providers.modelEntries.first(where: { entry in
            RealtimeVoiceProtocol.isConversationModel(entry.model.id) && supportedProviders.contains(where: { $0.id == entry.providerInstanceId })
        }) {
            providerID = entry.providerInstanceId; model = entry.model.id; preview = model.contains("preview")
        } else { providerID = supportedProviders.first?.id ?? "" }
    }
    private func saveSelection(_ value: String, for id: String) {
        guard !id.isEmpty else { return }
        var saved = (try? JSONDecoder().decode([String: String].self, from: Data(modelSelections.utf8))) ?? [:]
        saved[id] = value
        if let data = try? JSONEncoder().encode(saved), let json = String(data: data, encoding: .utf8) { modelSelections = json }
    }
    private func prepareCatalog() {
        if !selectionProvider.isEmpty, selectionProvider != providerID { saveSelection(model, for: selectionProvider) }
        let saved = (try? JSONDecoder().decode([String: String].self, from: Data(modelSelections.utf8))) ?? [:]
        let switching = !selectionProvider.isEmpty && selectionProvider != providerID
        selectionProvider = providerID
        let protocolMap = (try? JSONDecoder().decode([String: String].self, from: Data(protocolsByProvider.utf8))) ?? [:]
        protocolMode = protocolMap[providerID] ?? "automatic"
        if let selected = saved[providerID] { model = selected }
        else if switching { model = "" }
        var local = providers.modelEntries.filter { $0.providerInstanceId == providerID }.map { Self.choice($0.model) }
        // 百炼服务商：补上文档列出的实时对话模型（在线刷新后以账号实际返回为准）
        if let provider = supportedProviders.first(where: { $0.id == providerID }),
           RealtimeDashScope.isDashScopeHost(URLComponents(string: provider.resolvedBaseURL(default: "").url)?.host) {
            local += RealtimeDashScope.documentedModels.map { RealtimeModelChoice(id: $0.id, name: $0.note, audioInput: true, audioOutput: true) }
        }
        catalog.select(providerID, local: local)
    }
    static func choice(_ value: LLMModel) -> RealtimeModelChoice {
        let modes = value.modalityOverride ?? value.capabilities.supportedModalities
        return RealtimeModelChoice(id: value.id, name: value.displayName,
                                   audioInput: modes.contains(.audioInput), audioOutput: modes.contains(.audioOutput))
    }
    private func refreshCatalog() async {
        let id = providerID
        guard !session.active, let provider = supportedProviders.first(where: { $0.id == id }) else { return }
        if catalog.providerID != id { prepareCatalog() }
        await catalog.refresh(provider: id) {
            guard let key = ProviderKeychainHelper.loadAPIKey(instanceId: id), !key.isEmpty else {
                throw NSError(domain: "RealtimeModels", code: 401, userInfo: [NSLocalizedDescriptionKey: "服务商未配置 API 密钥"])
            }
            if provider.providerType == .gemini {
                let values = try await GeminiModelsAPI.fetchModels(apiKey: key, customBaseURL: provider.effectiveCustomBaseURL, forceRefresh: true, includeNonChat: true)
                return values.map { Self.choice($0) }
            }
            let values = try await OpenAIModelsAPI.fetchModels(apiKey: key, baseURL: provider.effectiveCustomBaseURL,
                appendV1Suffix: provider.appendV1Suffix, forceRefresh: true,
                userAgent: provider.supportsCustomUserAgent ? provider.effectiveCustomUserAgent : nil, includeNonChat: true)
            return values.map { Self.choice($0) }
        }
    }
}

/// 这个 Bot 单独的实时语音：开关打开后选服务商 + 用户服务商里已有的实时模型（也可手填）
struct RealtimeBotOverrideSection: View {
    let botId: String
    @ObservedObject private var providers = ProviderConfigStore.shared
    @State private var on = false
    @State private var o = CloudBotRealtimeOverride()

    private var models: [String] {
        providers.modelEntries.filter { $0.providerInstanceId == o.provider && CloudVoiceRoute.isRealtimeCapable($0.model.id) }.map { $0.model.id }
    }
    private var voices: [String] {
        (try? RealtimeConnectionProtocol.resolve(o.protocolMode, model: o.model))?.voices(model: o.model) ?? RealtimeConnectionProtocol.openAIVoices
    }

    var body: some View {
        Section {
            Toggle("这个 Bot 单独设置", isOn: $on)
            if on {
                Picker("服务商", selection: $o.provider) {
                    Text("请选择").tag("")
                    ForEach(RealtimeVoiceSettingsForm.supportedProviders(providers), id: \.id) { Text($0.label).tag($0.id) }
                }
                if !models.isEmpty {
                    Picker("模型", selection: $o.model) {
                        Text("请选择").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("或手动填写模型名称", text: $o.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("实时协议", selection: $o.protocolMode) {
                    ForEach(RealtimeConnectionProtocol.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("声音", selection: $o.voice) {
                    Text("跟随全局").tag("")
                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: {
            Text("这个 Bot")
        } footer: {
            Text(on && !o.isUsable ? "选好服务商和模型后才生效；没填完整时用下面的全局默认。" : "单独设置只保存在本机。")
        }
        .onAppear {
            let saved = CloudBotRealtimeOverride.all()[botId]
            on = saved != nil
            o = saved ?? CloudBotRealtimeOverride()
        }
        .onChange(of: on) { v in CloudBotRealtimeOverride.save(v ? o : nil, botId: botId) }
        .onChange(of: o) { v in if on { CloudBotRealtimeOverride.save(v, botId: botId) } }
    }
}
