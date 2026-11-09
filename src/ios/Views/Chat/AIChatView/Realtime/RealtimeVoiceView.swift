import SwiftUI

struct RealtimeVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: RealtimeVoiceSession
    @ObservedObject private var providers = ProviderConfigStore.shared
    @AppStorage("realtimeVoice.provider") private var providerID = ""
    @AppStorage("realtimeVoice.model") private var model = ""
    @AppStorage("realtimeVoice.voice") private var voice = "alloy"
    @AppStorage("realtimeVoice.preview") private var preview = false
    @AppStorage("realtimeVoice.protocolsByProvider") private var protocolsByProvider = "{}"
    @State private var protocolMode = "automatic"
    private var selectedProtocol: RealtimeConnectionProtocol? {
        try? RealtimeConnectionProtocol.resolve(protocolMode, model: model)
    }
    private var availableVoices: [String] {
        selectedProtocol?.isGemini == true ? RealtimeConnectionProtocol.geminiVoices : RealtimeConnectionProtocol.openAIVoices
    }
    @State private var showSettings = false
    @StateObject private var catalog = RealtimeModelCatalog()
    @AppStorage("realtimeVoice.modelsByProvider") private var modelSelections = "{}"
    @State private var selectionProvider = ""
    init(chat: AIChatViewModel) { _session = StateObject(wrappedValue: RealtimeVoiceSession(chat: chat)) }
    private var supportedProviders: [ProviderInstance] {
        providers.instances.filter { $0.isEnabled && ($0.providerType == .openAI || $0.providerType == .openAIResponses || $0.providerType == .gemini) && $0.credentialType == .apiKey }
    }
    private var candidates: [ModelEntry] {
        providers.modelEntries.filter { $0.providerInstanceId == providerID && RealtimeVoiceProtocol.isConversationModel($0.model.id) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 6)
                Image(systemName: session.connected ? "waveform.circle.fill" : "phone.circle.fill")
                    .font(.system(size: 92)).foregroundStyle(session.connected ? Color.cyan : Color.secondary)
                    .accessibilityHidden(true)
                Text(session.status).font(.headline).multilineTextAlignment(.center)
                if session.active {
                    Text(String(format: "%02d:%02d", session.elapsed / 60, session.elapsed % 60))
                        .monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("\(supportedProviders.first(where: { $0.id == providerID })?.label ?? "选择服务商") · \(model)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let error = session.error {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if session.lines.isEmpty {
                                Text("连接后直接说话，停顿后 AI 自动回答。AI 说话时可以直接插话，也可以点「打断」。")
                                    .foregroundStyle(.secondary).padding(.top, 12)
                            }
                            ForEach(session.lines) { line in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(line.role == "user" ? "你" : "AI").font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(line.text.isEmpty ? "正在转写…" : line.text).textSelection(.enabled)
                                }.id(line.id)
                            }
                            Color.clear.frame(height: 1).id("voice-end")
                        }.padding(.horizontal, 24)
                    }
                    .onChange(of: session.lines.last?.text) { _ in proxy.scrollTo("voice-end", anchor: .bottom) }
                }
                if session.active {
                    HStack(spacing: 30) {
                        Button { session.toggleMute() } label: {
                            Label(session.muted ? "取消静音" : "静音", systemImage: session.muted ? "mic.slash.fill" : "mic.fill")
                        }.disabled(!session.connected)
                        Button { session.interrupt() } label: { Label("打断", systemImage: "hand.raised.fill") }
                            .disabled(!session.connected)
                        Button(role: .destructive) { session.finish() } label: { Label("挂断", systemImage: "phone.down.fill") }
                    }.buttonStyle(.bordered).labelStyle(.iconOnly).controlSize(.large)
                } else {
                    Button {
                        Task { await session.start(providerID: providerID, model: model.trimmingCharacters(in: .whitespacesAndNewlines), voice: voice, preview: preview, protocolMode: protocolMode) }
                    } label: { Label("开始实时通话", systemImage: "phone.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 28)
                        .disabled(providerID.isEmpty || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("语音由所选实时模型处理，按服务商计费。文字记录在挂断后保存；退出或切到后台会挂断。")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            .padding(.bottom, 16)
            .navigationTitle("实时语音").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { session.finish(); dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("实时语音设置").disabled(session.active)
                }
            }
            .sheet(isPresented: $showSettings) { settings }
            .onAppear { chooseInitialProvider() }
            .task(id: providerID) {
                prepareCatalog()
                await refreshCatalog()
            }
            .onChange(of: model) { value in
                guard selectionProvider == providerID else { return }
                saveSelection(value, for: providerID)
            }
            .onChange(of: protocolMode) { value in
                guard selectionProvider == providerID else { return }
                var saved = (try? JSONDecoder().decode([String: String].self, from: Data(protocolsByProvider.utf8))) ?? [:]
                saved[providerID] = value
                if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { protocolsByProvider = text }
                voice = selectedProtocol?.normalizedVoice(voice) ?? "alloy"
            }
            .onChange(of: model) { _ in voice = selectedProtocol?.normalizedVoice(voice) ?? "alloy" }
            .onDisappear { session.finish() }
        }.interactiveDismissDisabled(session.active)
    }
    private var settings: some View {
        NavigationStack {
            Form {
                Section("实时音频服务") {
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
                    Button {
                        Task { await session.start(providerID: providerID, model: model.trimmingCharacters(in: .whitespacesAndNewlines), voice: voice, preview: preview, protocolMode: protocolMode, validateOnly: true) }
                    } label: { Label(session.active ? "验证中…" : "验证实时连接（不开麦）", systemImage: "checkmark.shield") }
                    .disabled(session.active || providerID.isEmpty || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let result = session.validationResult { Text(result).font(.footnote).foregroundStyle(.green) }
                    if let error = session.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                    Text("验证只建立所选模型会话，不传录音和聊天历史。服务商可能对会话建立收费。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("需要服务商开放双向 Realtime 音频接口。列出模型名不保证实时通道可用；连接失败时可更换服务商。密钥直接使用服务商设置中的现有凭据。")
                    Text("本模式传送当前聊天文字与灵魂设定。语音通话暂不执行终端、浏览器等工具，挂断后可在普通聊天中继续。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("通话设置").navigationBarTitleDisplayMode(.inline)
                .refreshable { await refreshCatalog() }
                .task { if !catalog.loading { await refreshCatalog() } }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }
    }
    private func chooseInitialProvider() {
        guard !supportedProviders.contains(where: { $0.id == providerID }) else { return }
        if let entry = providers.modelEntries.first(where: { entry in
            RealtimeVoiceProtocol.isConversationModel(entry.model.id) && supportedProviders.contains(where: { $0.id == entry.providerInstanceId })
        }) {
            providerID = entry.providerInstanceId; model = entry.model.id; preview = model.contains("preview")
        } else { providerID = supportedProviders.first?.id ?? ""; showSettings = true }
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
        let local = providers.modelEntries.filter { $0.providerInstanceId == providerID }.map { choice($0.model) }
        catalog.select(providerID, local: local)
    }
    private func choice(_ value: LLMModel) -> RealtimeModelChoice {
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
                return values.map { choice($0) }
            }
            let values = try await OpenAIModelsAPI.fetchModels(apiKey: key, baseURL: provider.effectiveCustomBaseURL,
                appendV1Suffix: provider.appendV1Suffix, forceRefresh: true,
                userAgent: provider.supportsCustomUserAgent ? provider.effectiveCustomUserAgent : nil, includeNonChat: true)
            return values.map { choice($0) }
        }
        // 刷新只更新目录，不替用户选择新模型，也不覆盖正在编辑的名称。
    }
}
