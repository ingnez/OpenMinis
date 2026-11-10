import SwiftUI

/// 群聊语音的驱动：只在打开时轮询本地状态，真正说话 / 听写用现成的 CloudBotSpeaker（每个 Bot 自己的声音设置）和 CloudDictation
@MainActor
final class CloudGroupVoiceCall: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var speakingBot: String?
    @Published var muted = false
    private var startId = 0
    private var spoken: Set<Int> = []
    private var loop: Task<Void, Never>?
    private var listenRequestedAt = Date.distantPast

    func start(model: CloudGroupChatModel, dictation: CloudDictation) {
        guard !active else { return }
        active = true
        startId = model.messages.last?.id ?? 0
        spoken = []
        CloudBotSpeaker.stop()
        loop = Task { [weak self] in
            while let self, self.active, !Task.isCancelled {
                self.tick(model: model, dictation: dictation)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func stop(dictation: CloudDictation) {
        active = false
        loop?.cancel()
        loop = nil
        speakingBot = nil
        dictation.stop()
        CloudBotSpeaker.stop()
    }

    /// 插话：正在念就停下，马上听你说
    func interrupt(model: CloudGroupChatModel) {
        CloudBotSpeaker.stop()
        spoken.formUnion(CloudGroupVoiceRules.pending(lines(model), after: startId, spoken: spoken).map(\.id))
        speakingBot = nil
    }

    private func lines(_ model: CloudGroupChatModel) -> [CloudGroupVoiceRules.Line] {
        model.messages.map { .init(id: $0.id, sender: $0.sender, kind: $0.kind, content: $0.content) }
    }

    private func tick(model: CloudGroupChatModel, dictation: CloudDictation) {
        let pending = CloudGroupVoiceRules.pending(lines(model), after: startId, spoken: spoken)
        let speaking = CloudBotSpeaker.isSpeaking
        if !speaking { speakingBot = nil }
        let action = CloudGroupVoiceRules.next(
            pending: pending, speaking: speaking, recording: dictation.isRecording,
            heardText: !dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            silence: Date().timeIntervalSince(dictation.lastHeard), typing: model.typing.count, sending: model.sending)
        switch action {
        case .speak(let line):
            spoken.insert(line.id)
            speakingBot = line.sender
            CloudBotSpeaker.speak(CloudGroupVoiceRules.spokenText(line.content), botId: line.sender)
        case .listen:
            // 授权和开麦是异步的：2 秒内不重复开；没权限就停在静音，提示交给听写自己的错误文字
            if dictation.errorText != nil { muted = true; return }
            guard !muted, Date().timeIntervalSince(listenRequestedAt) > 2 else { return }
            listenRequestedAt = Date()
            dictation.start()
        case .send:
            let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            dictation.stop()
            dictation.transcript = ""
            Task { await model.send("🎤 " + text) }
        case .wait:
            break
        }
    }
}

/// 群聊语音进行中的条：谁在说、静音、插话、挂断
struct CloudGroupVoiceBar: View {
    @ObservedObject var call: CloudGroupVoiceCall
    @ObservedObject var dictation: CloudDictation
    let botName: (String) -> String
    let onInterrupt: () -> Void
    let onHangUp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill").foregroundStyle(.green)
            Text(status).font(.subheadline).lineLimit(2)
            Spacer()
            if call.speakingBot != nil {
                Button("插话", action: onInterrupt).font(.subheadline.weight(.semibold))
            }
            Button { call.muted.toggle(); if call.muted { dictation.stop() } } label: {
                Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
            }
            .accessibilityLabel(call.muted ? "取消静音" : "静音")
            Button(action: onHangUp) {
                Image(systemName: "phone.down.fill").foregroundStyle(.white).padding(8).background(Circle().fill(Color.red))
            }
            .accessibilityLabel("挂断群聊语音")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.1)))
        .padding(.horizontal, 12)
    }

    private var status: String {
        if let b = call.speakingBot { return "\(botName(b)) 正在说…" }
        if call.muted { return "已静音" }
        if dictation.isRecording { return dictation.transcript.isEmpty ? "正在听你说…" : dictation.transcript }
        return "等 Bot 回答…"
    }
}
