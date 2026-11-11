import Foundation

/// 本地模式的回复方式：默认「秒回」，可以按对话单独覆盖；前台 / 后台模型分开选（空 = 跟随当前对话的模型）。
/// 只放纯逻辑（Foundation），界面在 LocalReplyViews.swift；Linux 上 scripts/LocalReplyModeTests.swift 跑。
enum LocalReplyStore {
    static let modeKey = "OpenMinis_localReplyMode"
    static let frontKey = "OpenMinis_localReplyFrontModel"
    static let backKey = "OpenMinis_localReplyBackModel"
    static let durationsKey = "OpenMinis_localReplyDurations"
    static let overridePrefix = "OpenMinis_localReplyOverride."
    static var defaults: UserDefaults = .standard

    static func overrideKey(_ sessionId: String) -> String { overridePrefix + sessionId }

    static var defaultMode: CloudReplyMode {
        CloudReplyMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .instant
    }

    static var frontModel: String { defaults.string(forKey: frontKey) ?? "" }
    static var backModel: String { defaults.string(forKey: backKey) ?? "" }

    static func override(for sessionId: String) -> CloudReplyMode? {
        guard !sessionId.isEmpty else { return nil }
        return (defaults.string(forKey: overrideKey(sessionId))).flatMap(CloudReplyMode.init(rawValue:))
    }

    static func plan(sessionId: String) -> CloudReplyPlan {
        let bot = defaultMode
        let over = override(for: sessionId)
        return CloudReplyPlan(mode: over ?? bot, source: over == nil ? "bot" : "chat", botMode: bot,
                              override: over, frontModel: frontModel, backModel: backModel)
    }

    static func setDefault(_ mode: CloudReplyMode, frontModel: String? = nil, backModel: String? = nil) {
        defaults.set(mode.rawValue, forKey: modeKey)
        if let frontModel { defaults.set(frontModel, forKey: frontKey) }
        if let backModel { defaults.set(backModel, forKey: backKey) }
    }

    /// nil = 跟随默认
    static func clearOverrides() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(overridePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static func setOverride(sessionId: String, mode: CloudReplyMode?) {
        guard !sessionId.isEmpty else { return }
        if let mode {
            defaults.set(mode.rawValue, forKey: overrideKey(sessionId))
        } else {
            defaults.removeObject(forKey: overrideKey(sessionId))
        }
    }

    static var settings: CloudReplyBotSettings {
        CloudReplyBotSettings(mode: defaultMode, frontModel: frontModel, backModel: backModel)
    }

    static func setSettings(_ s: CloudReplyBotSettings) {
        setDefault(s.mode, frontModel: s.frontModel, backModel: s.backModel)
    }

    /// 最近完成的后台任务用时（秒），最多 12 个，给预计剩余用
    static func durations() -> [Double] {
        (defaults.array(forKey: durationsKey) as? [Double]) ?? []
    }

    static func recordDuration(_ seconds: Double) {
        guard seconds > 0 else { return }
        var xs = durations()
        xs.insert(seconds, at: 0)
        if xs.count > 12 { xs = Array(xs.prefix(12)) }
        defaults.set(xs, forKey: durationsKey)
    }

    static func eta(elapsed: Double) -> Int? {
        CloudReplyText.etaSeconds(history: durations(), elapsed: elapsed)
    }

    /// 秒回前台附加说明（接到系统提示末尾，覆盖「自己跑命令」的默认口径）
    static let frontNote = """


    [秒回 · 前台] 你是前台：用户发来的每条消息，先在一两句话里马上回应（直接答案、确认、或者追问），语气自然。
    你自己不做多步操作，也没有命令行、浏览器、文件等工具。凡是需要查资料、跑命令、改文件、上网、超过几秒的事，
    先写一句简短回应（比如「好，我让后台去查，做完告诉你」），再在同一条回复里调用 spawn_task 把目标和需要的背景交给后台。
    后台正在做事时用户又发来消息：立刻理解他的意思，用一句自然的话点明他想做什么、你接下来会怎么做（例如「你想把课件改成 10 页，我让后台现在就改」），不要用固定的「收到，已经告诉…」一类套话；然后由你决定：把改写后的具体要求用 task_message 转给正在跑的后台，或 spawn_task 另派一件，或 task_stop 停下/换掉，或这件事不必劳动后台就直接回答；
    问进度就看下面的任务摘要或 task_status，用一句话告诉他。不要复述后台的每一步。
    """

    static let spawnTools: Set<String> = ["spawn_task", "task_status", "task_message", "task_stop", "task_resume"]

    static func isHandoffTool(_ name: String) -> Bool {
        spawnTools.contains(name) || name == "subagent_task" || name == "agent_status"
    }

    static let activeStatuses: Set<String> = ["queued", "running", "waiting_user"]
    static let statusLabels: [String: String] = [
        "queued": "排队中", "running": "进行中", "completed": "已完成",
        "failed": "失败", "cancelled": "已停止", "interrupted": "中断",
        "limit_reached": "达到步数上限"
    ]

    /// 前台每轮现查的任务摘要。不要在一轮开始时只拼一次：同一条前台任务里刚 spawn 再被插话时，旧摘要还是空的。
    static func summaryNote(_ workers: [CloudReplyWorker], limit: Int = 6, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        let rows = Array(workers.filter { w in
            activeStatuses.contains(w.status) || (now - (w.createdAt + w.elapsed)) < 6 * 3600
        }.prefix(limit))
        guard !rows.isEmpty else { return "" }
        var lines: [String] = []
        for w in rows {
            var line = "- \(w.id)「\(w.title)」\(statusLabels[w.status] ?? w.status)"
            if activeStatuses.contains(w.status), !w.phrase.isEmpty {
                line += "，最近一步：\(String(w.phrase.prefix(80)))"
            }
            if !activeStatuses.contains(w.status), !w.result.isEmpty {
                let compact = w.result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                line += "，结果摘要：" + String(compact.prefix(160))
            }
            lines.append(line)
        }
        return ("\n\n[这个对话的后台任务（只是摘要）。用户在补充 / 修改进行中的任务 → task_message；要停 → task_stop；"
            + "中断或失败要继续 → task_resume；无关的闲聊和提问直接回答，不要动后台任务]\n"
            + lines.joined(separator: "\n"))
    }

    /// 工具名 → 状态行短语（本地后台任务；有 tool_title 时优先用 title）
    static func toolPhrase(_ name: String, title: String = "") -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t.count <= 16 ? t : String(t.prefix(15)) + "…" }
        switch name {
        case "shell_execute": return "运行命令"
        case "file_read": return "阅读文件"
        case "file_write": return "写文件"
        case "file_edit": return "修改文件"
        case "browser_use": return "浏览网页"
        case "memory_search", "memory_get": return "翻看记忆"
        case "memory_write": return "记下要点"
        case "read_image": return "查看图片"
        case "subagent_task": return "分派子任务"
        case "": return CloudReplyText.startPhrase
        default: return name.contains("__") || name.contains(".") ? "使用插件" : "处理中"
        }
    }
}
