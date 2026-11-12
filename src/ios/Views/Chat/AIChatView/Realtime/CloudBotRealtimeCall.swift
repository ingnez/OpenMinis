import SwiftUI

/// 云端 Bot 的实时双向通话：复用本机的 OpenAI Realtime / Gemini Live 通话，
/// 实时模型扮演这个 Bot 说话；需要真正动手的事交给云端的这个 Bot 在同一个对话里执行。
enum CloudBotRealtimeAvailability {
    /// 已在「实时语音」设置里选好可用的服务商和模型
    @MainActor static var isConfigured: Bool {
        let d = UserDefaults.standard
        let providerID = d.string(forKey: "realtimeVoice.provider") ?? ""
        let model = (d.string(forKey: "realtimeVoice.model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !model.isEmpty,
              let provider = ProviderConfigStore.shared.instance(for: providerID), provider.isEnabled else { return false }
        return true
    }

    /// 这个 Bot 能不能开实时语音：有单独设置且服务商可用，或者全局配好了
    @MainActor static func isConfigured(botId: String?) -> Bool {
        if let o = CloudBotRealtimeOverride.load(botId), let p = ProviderConfigStore.shared.instance(for: o.provider), p.isEnabled { return true }
        return isConfigured
    }
}

@MainActor
final class RealtimeCloudBotHost: RealtimeVoiceHost {
    private let botName: String
    private let persona: String
    private let sessionId: String
    private let history: [RealtimeHistoryTurn]
    private let delegate: (String) async -> String?
    private let onSaved: (String?) -> Void
    private var lastTaskId: String?

    /// history：对话里可见的文字，[["role": "user"/"assistant", "text": ...]]，按时间顺序
    init(botName: String, persona: String, sessionId: String, history: [[String: String]],
         delegate: @escaping (String) async -> String?, onSaved: @escaping (String?) -> Void) {
        self.botName = botName
        self.persona = persona
        self.sessionId = sessionId
        self.delegate = delegate
        self.onSaved = onSaved
        self.history = Self.recentTurns(history)
    }

    /// 只带最近 30 条、每条最多 2000 字，避免实时会话一开始就塞满上下文
    nonisolated static func recentTurns(_ rows: [[String: String]]) -> [RealtimeHistoryTurn] {
        let turns: [RealtimeHistoryTurn] = rows.compactMap { row in
            guard let role = row["role"], role == "user" || role == "assistant" else { return nil }
            let text = (row["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : RealtimeHistoryTurn(role: role, text: String(text.prefix(2000)))
        }
        return Array(turns.suffix(30))
    }

    var blockReason: String? { nil }
    var isRetired: Bool { false }
    var toolsAvailable: Bool { true }

    func instructions(toolsEnabled: Bool) -> String {
        var text = "你是「\(botName)」，正在和用户实时语音通话。没有另外要求时用中文，回答简洁口语化，先说结论。"
        let persona = self.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        // 设定里含灵魂设定（风格、人格、禁止事项、语言）和语音设置，优先于上面的默认说法
        if !persona.isEmpty { text += "\n\n你的设定（严格遵守）：\n" + String(persona.prefix(6000)) }
        if toolsEnabled {
            text += "\n\n查资料、操作电脑等需要真实执行的事必须调用 cloud_task_start。云端听不到通话，所以 prompt 要写完整。拿到 task_id 后，只说一次任务已提交。失败时直接说原因。用户问进度时调用 cloud_task_status，收到云电脑任务状态后只转述新信息。只有真实结果才能确认已经查过或完成。"
        } else {
            text += "\n没有可直接调用的工具。只有云电脑派发回执或真实结果能确认已接收或完成。"
        }
        return text
    }

    func historyTurns() -> [RealtimeHistoryTurn] { history }
    func prepareForCall() {}

    func callTool(name: String, arguments: [String: Any]) async -> (output: String, watchTaskId: String?) {
        switch name {
        case "cloud_task_start":
            let prompt = (arguments["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return (Self.encode(["error": "prompt 不能为空"]), nil) }
            guard let taskId = await delegate(prompt) else {
                return (Self.encode(["error": "没有交出去：\(botName) 可能正在做另一件事，或云端暂时连不上。请告诉用户稍后再试。"]), nil)
            }
            lastTaskId = taskId
            return (Self.encode(["status": "submitted", "task_id": taskId,
                                 "note": "云电脑已接收，按后台可用名额执行。请只确认一次。"]), taskId)
        case "cloud_task_status":
            var args = arguments
            if (args["task_id"] as? String ?? "").isEmpty, let lastTaskId { args["task_id"] = lastTaskId }
            return await CloudVoiceBridge.call(name: name, arguments: args)
        default:
            return await CloudVoiceBridge.call(name: name, arguments: arguments)
        }
    }

    func waitForResult(taskId: String) async -> String {
        await CloudVoiceBridge.waitForResult(taskId: taskId)
    }

    func save(transcript: [RealtimeTranscriptLine]) async {
        // 「已调用云电脑」这种工具提示行不存进对话：交出去的任务本身已经在对话里
        let lines: [[String: Any]] = transcript.filter { !$0.text.hasPrefix("[已调用云电脑") }.map { ["role": $0.role, "text": $0.text, "interrupted": $0.interrupted] }
        let problem = await CloudVoiceBridge.saveTranscript(sessionId: sessionId, lines: lines)
        onSaved(problem)
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// 给云端对话页用的入口；连不上或没配置实时服务时可以退回轮流通话
struct CloudBotRealtimeCallView: View {
    private let host: RealtimeCloudBotHost
    private let botName: String
    private let onFallback: () -> Void

    @MainActor init(botName: String, persona: String, sessionId: String, history: [[String: String]], delegate: @escaping (String) async -> String?, onSaved: @escaping (String?) -> Void, onFallback: @escaping () -> Void) {
        self.botName = botName
        self.onFallback = onFallback
        host = RealtimeCloudBotHost(botName: botName, persona: persona, sessionId: sessionId, history: history,
                                    delegate: delegate, onSaved: onSaved)
    }

    var body: some View {
        RealtimeVoiceView(host: host, title: "和 \(botName) 实时通话", fallbackTitle: "改用轮流通话", onFallback: onFallback)
    }
}
