import SwiftUI

struct RealtimeVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: RealtimeVoiceSession
    @ObservedObject private var providers = ProviderConfigStore.shared
    @AppStorage("realtimeVoice.provider") private var providerID = ""
    @AppStorage("realtimeVoice.model") private var model = "gpt-realtime"
    @AppStorage("realtimeVoice.voice") private var voice = "alloy"
    @AppStorage("realtimeVoice.preview") private var preview = false
    @State private var showSettings = false
    init(chat: AIChatViewModel) { _session = StateObject(wrappedValue: RealtimeVoiceSession(chat: chat)) }
    private var supportedProviders: [ProviderInstance] {
        providers.instances.filter { $0.isEnabled && ($0.providerType == .openAI || $0.providerType == .openAIResponses) && $0.credentialType == .apiKey }
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
                        Task { await session.start(providerID: providerID, model: model.trimmingCharacters(in: .whitespacesAndNewlines), voice: voice, preview: preview) }
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
                    }.onChange(of: providerID) { _ in chooseModel() }
                    if !candidates.isEmpty {
                        Picker("已发现的实时模型", selection: $model) {
                            if !candidates.contains(where: { $0.model.id == model }) { Text(model).tag(model) }
                            ForEach(candidates, id: \.id) { entry in Text(entry.model.id).tag(entry.model.id) }
                        }
                    }
                    TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: model) { preview = $0.contains("preview") }
                    Toggle("旧版 Preview 协议", isOn: $preview)
                    Picker("声音", selection: $voice) {
                        ForEach(["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Text("需要服务商开放双向 Realtime 音频接口。列出模型名不保证实时通道可用；连接失败时可更换服务商。密钥直接使用服务商设置中的现有凭据。")
                    Text("本模式传送当前聊天文字与灵魂设定。语音通话暂不执行终端、浏览器等工具，挂断后可在普通聊天中继续。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("通话设置").navigationBarTitleDisplayMode(.inline)
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
    private func chooseModel() {
        if let entry = candidates.first { model = entry.model.id; preview = model.contains("preview") }
    }
}
