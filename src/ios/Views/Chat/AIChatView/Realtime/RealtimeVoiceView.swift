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
                if session.active {
                    activePanel
                } else {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 58)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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
                        }.disabled(!session.connected || session.isEnding)
                        Button { session.interrupt() } label: { Label("打断", systemImage: "hand.raised.fill") }
                            .disabled(!session.connected || session.isEnding)
                        Button(role: .destructive) { session.hangUp() } label: { Label("挂断", systemImage: "phone.down.fill") }
                            .disabled(session.isEnding)
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

    private var activePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.status).font(.subheadline.weight(.semibold))
                Spacer()
                if session.connected {
                    Text(String(format: "%02d:%02d", session.elapsed / 60, session.elapsed % 60))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                }
            }
            RealtimeCallSignal(connected: session.connected, levels: session.levels,
                               muted: session.muted, ending: session.isEnding)
                .frame(height: 46)
            if let notice = session.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 24)
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

/// 音量变化只重画波形，不刷新聊天列表和通话按钮。
@MainActor
final class RealtimeCallLevels: ObservableObject {
    @Published private(set) var mic: Float = 0
    @Published private(set) var speaker: Float = 0

    func updateMic(_ level: Float) {
        if mic != level { mic = level }
    }

    func updateSpeaker(_ level: Float) {
        if speaker != level { speaker = level }
    }
}

struct RealtimeCallSignal: View {
    let connected: Bool
    @ObservedObject var levels: RealtimeCallLevels
    let muted: Bool
    let ending: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mic = muted || ending ? 0 : Double(levels.mic)
        let speaker = ending ? 0 : Double(levels.speaker)
        let paused = reduceMotion || CloudE2E.pauseIdleAnimations
        let smoothing = paused ? nil : Animation.linear(duration: 0.08)
        RealtimeCallSignalDrawing(connected: connected, micLevel: mic, speakLevel: speaker,
                                  compact: compact, paused: paused)
            .animation(smoothing, value: mic)
            .animation(smoothing, value: speaker)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connected ? "实时通话波形" : "正在连接实时通话")
            .accessibilityIdentifier(connected ? "realtimeCallLiveWaveform" : "realtimeCallPendingTrack")
    }
}

/// 在两次音量采样之间插值。活跃时跟随系统的动画节奏，安静时停止时钟。
private struct RealtimeCallSignalDrawing: View, Animatable {
    let connected: Bool
    var micLevel: Double
    var speakLevel: Double
    let compact: Bool
    let paused: Bool
    private let barsPerSide = 12
    private let spacing: CGFloat = 3

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(micLevel, speakLevel) }
        set { micLevel = newValue.first; speakLevel = newValue.second }
    }

    var body: some View {
        let quiet = connected && max(micLevel, speakLevel) < 0.025
        TimelineView(.animation(paused: paused || quiet)) { context in
            let phase = paused ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                if connected {
                    if compact { compactWaveform(size: proxy.size, phase: phase) }
                    else { waveform(size: proxy.size, phase: phase) }
                } else {
                    pendingTrack(width: proxy.size.width, phase: phase)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func pendingTrack(width: CGFloat, phase: TimeInterval) -> some View {
        let segment = width * 0.32
        let progress = phase.truncatingRemainder(dividingBy: 1.35) / 1.35
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.14))
            Capsule().fill(.white.opacity(0.82))
                .frame(width: segment)
                .offset(x: (width - segment) * CGFloat(progress))
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }

    private func compactWaveform(size: CGSize, phase: TimeInterval) -> some View {
        let count = max(5, Int(size.width / 5.5))
        let pitch = size.width / CGFloat(count)
        return Canvas { context, _ in
            for index in 0..<count {
                let isMic = index < count / 2
                let level = max(0, min(1, isMic ? micLevel : speakLevel))
                let fraction = CGFloat(index) / CGFloat(count - 1)
                let edge = isMic ? 1 - fraction * 1.4 : fraction
                let motion = 0.65 + 0.35 * sin(phase * 10 + Double(index) * 0.9)
                let h = 2.8 + (size.height - 2.8) * CGFloat(level) * (0.25 + edge * 0.75) * CGFloat(motion)
                let rect = CGRect(x: pitch * (CGFloat(index) + 0.5) - 1.4,
                                  y: (size.height - h) / 2, width: 2.8, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.4),
                             with: .color(.white.opacity(Double(0.22 + 0.78 * level))))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func waveform(size: CGSize, phase: TimeInterval) -> some View {
        let count = barsPerSide * 2
        let barWidth = max(1, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        return Canvas { context, _ in
            for index in 0..<count {
                let isMic = index < barsPerSide
                let level = max(0, min(1, isMic ? micLevel : speakLevel))
                let position = Double(index % barsPerSide)
                let center = Double(barsPerSide - 1) / 2
                let envelope = 0.36 + 0.64 * (1 - abs(position - center) / center)
                let movement = 0.72 + 0.28 * sin(phase * 11 + position * 0.89)
                let height = 3 + max(0, size.height - 3) * CGFloat(level * envelope * movement)
                let rect = CGRect(x: CGFloat(index) * (barWidth + spacing), y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                let tint = isMic ? Color.white : Color(red: 0.49, green: 0.80, blue: 1)
                context.fill(Path(roundedRect: rect, cornerRadius: min(barWidth, height) / 2),
                             with: .color(tint.opacity(0.28 + level * 0.72)))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
