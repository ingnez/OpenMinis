import Combine
import SwiftUI
import UIKit

/// 浮动通话胶囊用的一行实时字幕
struct CloudBotCallLine: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
}

/// 对话页顶部浮动胶囊背后的实时通话：Bot 模式和本地模式共用。
/// 通话期间对话页照常显示，字幕实时出现在对话里；切到后台不挂断，灵动岛 / 锁屏显示通话；挂断后回调通话时长（插分隔线）。
@MainActor
final class CloudBotCallController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var connected = false
    @Published private(set) var muted = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var speakLevel: Float = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var lines: [CloudBotCallLine] = []
    @Published private(set) var pushToTalk = false
    @Published private(set) var startedAt: Date?
    /// 通话中的问题（中文，胶囊上显示）
    @Published private(set) var notice: String?
    @Published private(set) var receivedAudioKB = 0
    /// 挂断后调用：(开始时间, 时长秒)
    var onEnded: ((Date, Int) -> Void)?
    private var session: RealtimeVoiceSession?
    private var bag: Set<AnyCancellable> = []
    private var settleTask: Task<Void, Never>?
    private var callName = ""

    init() {}

    /// 实时语音服务是否已配好（没配好时调用方退回轮流通话或打开设置）
    static var isConfigured: Bool {
        let d = UserDefaults.standard
        return !(d.string(forKey: "realtimeVoice.provider") ?? "").isEmpty
            && !(d.string(forKey: "realtimeVoice.model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Bot 模式：实时模型扮演这个 Bot（灵魂设定 + 语音设置在 persona 里），要动手的事交给云端的这个 Bot
    func startCloudBot(botName: String, persona: String, sessionId: String, history: [[String: String]],
                       delegate: @escaping (String) async -> String?, onSaved: @escaping (String?) -> Void, pushToTalk: Bool = false, botId: String? = nil) async {
        let host = RealtimeCloudBotHost(botName: botName, persona: persona, sessionId: sessionId, history: history,
                                        delegate: delegate, onSaved: onSaved)
        await start(host: host, name: botName, pushToTalk: pushToTalk, botId: botId)
    }

    /// 实际要用的服务商 / 模型 / 声音 / 协议：这个 Bot 有单独设置就用它，否则用全局「实时语音」
    static func effectiveConfig(botId: String?) -> (provider: String, model: String, voice: String, protocolMode: String) {
        let d = UserDefaults.standard
        let protocols = (try? JSONDecoder().decode([String: String].self, from: Data((d.string(forKey: "realtimeVoice.protocolsByProvider") ?? "{}").utf8))) ?? [:]
        let globalVoice = d.string(forKey: "realtimeVoice.voice") ?? "alloy"
        if let o = CloudBotRealtimeOverride.load(botId) {
            return (o.provider, o.model.trimmingCharacters(in: .whitespacesAndNewlines), o.voice.isEmpty ? globalVoice : o.voice, o.protocolMode)
        }
        let provider = d.string(forKey: "realtimeVoice.provider") ?? ""
        return (provider, (d.string(forKey: "realtimeVoice.model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                globalVoice, protocols[provider] ?? "automatic")
    }

    func start(host: RealtimeVoiceHost, name: String, pushToTalk: Bool = false, botId: String? = nil) async {
        guard !active else { return }
        let cfg = Self.effectiveConfig(botId: botId)
        let providerID = cfg.provider, model = cfg.model, voice = cfg.voice
        let preview = model.contains("preview")
        guard !providerID.isEmpty, !model.isEmpty else { error = "先在「实时语音」设置里选好服务商和模型"; return }
        let s = RealtimeVoiceSession(host: host)
        s.continuesInBackground = true
        session = s
        callName = name
        error = nil; lines = []; elapsed = 0; notice = nil; receivedAudioKB = 0
        self.pushToTalk = pushToTalk
        bind(s)
        startedAt = Date()
        await s.start(providerID: providerID, model: model, voice: voice, preview: preview, protocolMode: cfg.protocolMode)
        if s.active, pushToTalk { s.setTalking(false) }
    }

    private func bind(_ s: RealtimeVoiceSession) {
        bag = []
        s.$active.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            let was = self.active
            self.active = on
            if on && !was { self.didConnect() }
            if !on && was { self.didEnd() }
        }.store(in: &bag)
        s.$connected.removeDuplicates().sink { [weak self] c in
            self?.connected = c
            if c { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }.store(in: &bag)
        s.$muted.sink { [weak self] in self?.muted = $0 }.store(in: &bag)
        s.$micLevel.sink { [weak self] in self?.micLevel = $0 }.store(in: &bag)
        s.$speakLevel.sink { [weak self] in self?.speakLevel = $0 }.store(in: &bag)
        s.$elapsed.sink { [weak self] in self?.elapsed = $0 }.store(in: &bag)
        s.$status.sink { [weak self] in self?.status = $0 }.store(in: &bag)
        s.$notice.sink { [weak self] in self?.notice = $0 }.store(in: &bag)
        s.$receivedAudioKB.sink { [weak self] in self?.receivedAudioKB = $0 }.store(in: &bag)
        s.$error.sink { [weak self] e in if let e { self?.error = e } }.store(in: &bag)
        s.$lines.sink { [weak self] ls in
            self?.lines = ls.map { CloudBotCallLine(id: $0.id, role: $0.role, text: $0.text) }
        }.store(in: &bag)
    }

    private func didConnect() {
        AgentLiveActivityManager.shared.botCallChanged(name: callName)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                self?.session?.settleLevels()
            }
        }
    }

    private func didEnd() {
        settleTask?.cancel(); settleTask = nil
        AgentLiveActivityManager.shared.botCallChanged(name: nil)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        if let startedAt, elapsed > 0 { onEnded?(startedAt, elapsed) }
        startedAt = nil
        micLevel = 0; speakLevel = 0
    }

    func toggleMute() { session?.toggleMute() }

    /// 按住说话：按下开麦、松开静音
    func setTalking(_ on: Bool) {
        guard let session, session.active else { return }
        if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        session.setTalking(on)
    }

    func setPushToTalk(_ on: Bool) {
        pushToTalk = on
        session?.setTalking(!on)
    }

    func interrupt() { session?.interrupt() }

    /// 通话中从输入框打来的问题：走实时语音回答，不另开一条文字聊天
    func speakUserText(_ text: String) { session?.insertUserText(text) }

    func hangUp() { session?.finish() }
}

/// 胶囊上的齿轮：声音和按住说话（声音下次通话生效）
struct CloudBotCallSettingsSheet: View {
    @ObservedObject var call: CloudBotCallController
    @AppStorage("realtimeVoice.voice") private var voice = "alloy"
    @AppStorage("realtimeVoice.model") private var model = ""
    @Environment(\.dismiss) private var dismiss

    private var voices: [String] {
        (try? RealtimeConnectionProtocol.resolve("automatic", model: model))?.voices(model: model) ?? RealtimeConnectionProtocol.openAIVoices
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("按住说话（松开就静音）", isOn: Binding(get: { call.pushToTalk }, set: { call.setPushToTalk($0) }))
                    Toggle("静音", isOn: Binding(get: { call.muted }, set: { _ in call.toggleMute() }))
                }
                Section {
                    Picker("声音（下次通话生效）", selection: $voice) { ForEach(voices, id: \.self) { Text($0).tag($0) } }
                } footer: {
                    Text("这一通还用原来的声音，挂断后下次通话换成新声音。语速、语言和说话风格跟随这个 Bot 的灵魂设定与语音设置。")
                }
            }
            .navigationTitle("通话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
