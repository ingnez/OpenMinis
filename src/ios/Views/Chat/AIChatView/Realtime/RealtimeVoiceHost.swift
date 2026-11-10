import Foundation

/// 实时语音通话的「对面」：本机对话（AIChatViewModel）或某个云端 Bot。
/// RealtimeVoiceSession 只通过这个协议读历史、调工具、存记录，
/// 这样同一套双向流式通话可以接到不同的对话上。
@MainActor
protocol RealtimeVoiceHost: AnyObject {
    /// 现在不能开始通话的原因；nil 表示可以开始
    var blockReason: String? { get }
    /// 对话已被重置 / 关闭：不再写入通话记录
    var isRetired: Bool { get }
    /// 是否向实时模型暴露工具（交给云电脑 / Bot 执行）
    var toolsAvailable: Bool { get }
    func instructions(toolsEnabled: Bool) -> String
    /// 只含可见文字的历史，按时间顺序
    func historyTurns() -> [RealtimeHistoryTurn]
    /// 通话开始前停掉本对话正在朗读的语音等
    func prepareForCall()
    func callTool(name: String, arguments: [String: Any]) async -> (output: String, watchTaskId: String?)
    func waitForResult(taskId: String) async -> String
    /// 挂断后按顺序保存文字记录
    func save(transcript: [RealtimeTranscriptLine]) async
}

struct RealtimeHistoryTurn {
    let role: String   // "user" / "assistant"
    let text: String
}

struct RealtimeTranscriptLine {
    let role: String
    let text: String
    let interrupted: Bool
}

/// 本机对话：行为与原来直接持有 AIChatViewModel 时完全一致
@MainActor
final class RealtimeLocalChatHost: RealtimeVoiceHost {
    private weak var chat: AIChatViewModel?
    init(chat: AIChatViewModel) { self.chat = chat }

    var blockReason: String? {
        guard let chat, !chat.isRetiredByReset, !chat.isProcessing, !chat.isCompacting else {
            return "请先停止当前生成，再开始实时通话。"
        }
        return nil
    }
    var isRetired: Bool { chat == nil || chat?.isRetiredByReset == true }
    var toolsAvailable: Bool { CloudVoiceBridge.isAvailable }

    func instructions(toolsEnabled: Bool) -> String {
        if toolsEnabled {
            return SystemPromptBuilder.identitySection() + "\n你正在实时语音通话。默认中文，回答简洁自然。需要真实执行的工作（查资料、上网、跑代码、处理文件）用 cloud_task_start 交给用户的云电脑在后台完成，先口头说明已交给云电脑；收到“云电脑任务完成通知”后用一两句话转述结果。用户问进度时调用 cloud_task_status；cloud_routine_run 可运行已保存的例行任务。没有工具结果之前不得声称已完成。"
        }
        return SystemPromptBuilder.identitySection() + "\n你正在实时语音通话。默认中文，回答简洁自然。没有可执行工具，不得声称已执行外部操作。"
    }

    func historyTurns() -> [RealtimeHistoryTurn] {
        guard let chat else { return [] }
        // 仅传递可见文本；已压缩会话携带摘要，不发送工具内部数据或附件。
        return chat.effectiveAgentHistory().compactMap { message in
            let text = message.parts.compactMap { part -> String? in
                if case .text(let s) = part { return s }; return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : RealtimeHistoryTurn(role: message.role.rawValue, text: text)
        }
    }

    func prepareForCall() { chat?.stopSpeechForThisSession() }

    func callTool(name: String, arguments: [String: Any]) async -> (output: String, watchTaskId: String?) {
        await CloudVoiceBridge.call(name: name, arguments: arguments)
    }

    func waitForResult(taskId: String) async -> String {
        await CloudVoiceBridge.waitForResult(taskId: taskId)
    }

    func save(transcript: [RealtimeTranscriptLine]) async {
        guard let chat, !chat.isRetiredByReset else { return }
        // 按服务端会话顺序写入，而不是按异步转写返回顺序。
        await chat.ensureSession()
        for line in transcript {
            guard !chat.isRetiredByReset else { return }
            var message = AgentMessage(role: line.role == "user" ? .user : .assistant,
                                       parts: [.text(line.text)], isInterrupted: line.interrupted)
            message.dbMessageId = await chat.persistAgentMessage(message)
            guard !chat.isRetiredByReset else { return }
            chat.agentHistory.append(message)
        }
        guard !chat.isRetiredByReset else { return }
        await chat.reloadMessagesFromDB(reason: "实时语音通话结束")
    }
}
