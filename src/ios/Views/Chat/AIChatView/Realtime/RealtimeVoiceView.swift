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
    /// 当前服务商的协议（设置页里按服务商保存）
    private var protocolMode: String {
        ((try? JSONDecoder().decode([String: String].self, from: Data(protocolsByProvider.utf8))) ?? [:])[providerID] ?? "automatic"
    }
    @State private var showSettings = false
    private var title = "实时语音"
    private var fallbackTitle: String?
    private var onFallback: (() -> Void)?
    init(chat: AIChatViewModel) { _session = StateObject(wrappedValue: RealtimeVoiceSession(chat: chat)) }
    /// 接到其它对话（如云端 Bot）；连不上时可以退回到对方提供的轮流模式
    init(host: RealtimeVoiceHost, title: String, fallbackTitle: String? = nil, onFallback: (() -> Void)? = nil) {
        _session = StateObject(wrappedValue: RealtimeVoiceSession(host: host))
        self.title = title
        self.fallbackTitle = fallbackTitle
        self.onFallback = onFallback
    }
    private var supportedProviders: [ProviderInstance] { RealtimeVoiceSettingsForm.supportedProviders(providers) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 6)
                Image(systemName: session.connected ? "waveform.circle.fill" : "phone.circle.fill")
                    .font(.system(size: 92)).foregroundStyle(session.connected ? Color.cyan : Color.secondary)
                    .accessibilityHidden(true)
                Text(session.status).font(.headline).multilineTextAlignment(.center)
                if let notice = session.notice {
                    Text(notice).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
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
                    if let onFallback {
                        Button { session.finish(); onFallback() } label: {
                            Label(fallbackTitle ?? "改用轮流通话", systemImage: "arrow.triangle.2.circlepath")
                        }.font(.callout)
                    }
                }
                Text("语音由所选实时模型处理，按服务商计费。文字记录在挂断后保存；退出或切到后台会挂断。")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            .padding(.bottom, 16)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { session.finish(); dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("实时语音设置").disabled(session.active)
                }
            }
            .sheet(isPresented: $showSettings) { RealtimeVoiceSettingsSheet() }
            .onAppear { chooseInitialProvider() }
            .onDisappear { session.finish() }
        }.interactiveDismissDisabled(session.active)
    }
    private func chooseInitialProvider() {
        guard !supportedProviders.contains(where: { $0.id == providerID }) else { return }
        if let entry = providers.modelEntries.first(where: { entry in
            RealtimeVoiceProtocol.isConversationModel(entry.model.id) && supportedProviders.contains(where: { $0.id == entry.providerInstanceId })
        }) {
            providerID = entry.providerInstanceId; model = entry.model.id; preview = model.contains("preview")
        } else { providerID = supportedProviders.first?.id ?? ""; showSettings = true }
    }
}
