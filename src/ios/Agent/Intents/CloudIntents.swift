import AppIntents
import Foundation

/// 快捷指令 / Siri：立即运行一个云端例行任务（按名称匹配）。可在“快捷指令”中给它起名字，用语音触发。
struct RunCloudRoutineIntent: AppIntent {
    static var title: LocalizedStringResource = "运行云端例行任务"
    static var description = IntentDescription("立即在云电脑上运行一个已保存的例行任务（按名称匹配，先精确后模糊）。")
    static var openAppWhenRun = true

    @Parameter(title: "任务名称")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let routines = try await CloudRoutineService.list()
        let exact = routines.first { ($0["name"] as? String) == key }
        let fuzzy = routines.first { ($0["name"] as? String)?.localizedCaseInsensitiveContains(key) == true }
        guard !key.isEmpty, let match = exact ?? fuzzy, let rid = match["routine_id"] as? String else {
            let names = routines.compactMap { $0["name"] as? String }.joined(separator: "、")
            return .result(value: "没有找到例行任务“\(key)”。现有：\(names)")
        }
        _ = try await CloudRoutineService.runNow(routineId: rid)
        let title = match["name"] as? String ?? key
        return .result(value: "已开始运行“\(title)”，完成后会推送通知。")
    }
}

/// 快捷指令 / Siri：把一句话写入云端长期记忆（所有人格共享）。
struct SaveCloudMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "记到云端记忆"
    static var description = IntentDescription("把一条事实写入云电脑的长期记忆，云端 Agent 之后可检索到。")
    static var openAppWhenRun = true

    @Parameter(title: "内容")
    var content: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(value: "内容为空，未保存。") }
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        let resp = try await CloudConnection.shared.request(method: "POST", path: "/v1/memory", body: ["content": text, "category": "note"])
        let created = resp["created"] as? Bool ?? true
        return .result(value: created ? "已记到云端记忆。" : "这条已经记过了。")
    }
}

/// 快捷指令 / Siri：问某个云端 Bot 一句话（打开 App，进入这个 Bot 的对话并直接发送）。
struct AskCloudBotIntent: AppIntent {
    static var title: LocalizedStringResource = "问云端 Bot"
    static var description = IntentDescription("打开多 Bot 模式里指定 Bot 的对话并发送这句话；不填 Bot 就发给主 Bot。")
    static var openAppWhenRun = true

    @Parameter(title: "问题", requestValueDialog: "想问什么？")
    var question: String

    @Parameter(title: "Bot 名称", optionsProvider: CloudBotNameOptions())
    var bot: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        CloudBotEntry.open(bot: bot, text: question, send: true)
        return .result()
    }
}

/// 快捷指令：打开某个云端 Bot 的对话（可放到主屏幕或锁屏）。
struct OpenCloudBotIntent: AppIntent {
    static var title: LocalizedStringResource = "打开云端 Bot"
    static var description = IntentDescription("切到多 Bot 模式并打开指定 Bot 的对话；不填就是主 Bot。")
    static var openAppWhenRun = true

    @Parameter(title: "Bot 名称", optionsProvider: CloudBotNameOptions())
    var bot: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        CloudBotEntry.open(bot: bot, text: nil, send: false)
        return .result()
    }
}

/// 「快捷指令」里 Bot 名称的候选：App 上次刷新时缓存的 Bot 列表（不联网）
struct CloudBotNameOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run { CloudBotService.cachedList().map(\.name) }
    }
}
