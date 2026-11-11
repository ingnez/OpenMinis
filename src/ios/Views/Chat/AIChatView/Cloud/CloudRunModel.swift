import SwiftUI

/// Grok Bot 式对话行为在 App 里的数据层：消息卡片（后台任务 / 选项卡 / 页面 / 里程碑）、表情回应、引用回复、分气泡。
/// 卡片挂在助手消息的 .info 块上（toolUseId 以 cardPrefix 开头，content 是卡片 JSON），和重置提示走同一条管线。
enum CloudCards {
    static let cardPrefix = "cloudcard-"

    enum Kind: String { case worker, choice, page, milestone, deliverable }

    struct Card {
        let kind: Kind
        let payload: [String: Any]
        let messageId: Int?
    }

    /// 一条服务器消息带的卡片（服务器在 meta 里给 choice / page / milestone）
    static func cards(in m: [String: Any]) -> [Card] {
        let mid = (m["id"] as? NSNumber)?.intValue
        var out: [Card] = []
        if let c = m["choice"] as? [String: Any] { out.append(Card(kind: .choice, payload: c, messageId: mid)) }
        if let p = m["page"] as? [String: Any] { out.append(Card(kind: .page, payload: p, messageId: mid)) }
        if let w = m["milestone"] as? String {
            out.append(Card(kind: .milestone, payload: ["worker_id": w, "text": m["content"] as? String ?? ""], messageId: mid))
        }
        if let arr = m["deliverables"] as? [[String: Any]] {
            for d in arr {
                out.append(Card(kind: .deliverable, payload: d, messageId: mid))
            }
        }
        return out
    }

    /// spawn_task 的工具结果 → 后台任务卡片
    static func workerCard(fromToolResult parsed: Any) -> Card? {
        guard let d = parsed as? [String: Any], let id = d["id"] as? String, id.hasPrefix("wk_") else { return nil }
        return Card(kind: .worker, payload: d, messageId: nil)
    }

    static func block(_ card: Card) -> AssistantBlock {
        var payload = card.payload
        payload["_kind"] = card.kind.rawValue
        if let mid = card.messageId { payload["_mid"] = mid }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let key = (payload["worker_id"] as? String) ?? (payload["id"] as? String) ?? (payload["page_id"] as? String) ?? "\(card.messageId ?? 0)"
        return AssistantBlock(kind: .info, content: String(data: data, encoding: .utf8) ?? "{}",
                              toolUseId: cardPrefix + card.kind.rawValue + "-" + key)
    }

    static func decode(_ block: AssistantBlock) -> Card? {
        guard (block.toolUseId ?? "").hasPrefix(cardPrefix),
              let d = block.content.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let kind = Kind(rawValue: d["_kind"] as? String ?? "") else { return nil }
        return Card(kind: kind, payload: d, messageId: (d["_mid"] as? NSNumber)?.intValue)
    }

    /// 卡片自带文字（选项卡的问题、里程碑）：正文里不再重复显示
    static func hidesText(_ m: [String: Any]) -> Bool {
        m["choice"] != nil || m["milestone"] != nil
    }
}

/// 一条回复里用单独一行 --- 分开的两三个意思，拆成几个气泡（和服务器 split_beats 同一规则；代码块不拆）
enum CloudBeats {
    static func split(_ text: String, limit: Int = 3) -> [String] {
        guard text.contains("---"), !text.contains("```") else { return [text] }
        var parts: [String] = []
        var cur: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                parts.append(cur.joined(separator: "\n")); cur = []
            } else {
                cur.append(line)
            }
        }
        parts.append(cur.joined(separator: "\n"))
        parts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard parts.count >= 2 else { return [text] }
        if parts.count > limit {
            parts = Array(parts.prefix(limit - 1)) + [parts.dropFirst(limit - 1).joined(separator: "\n\n")]
        }
        return parts
    }
}

/// 表情回应 / 引用回复的显示数据（来自服务器消息的 id、reactions、reply_to）
struct CloudMessageExtras {
    let id: Int?
    let botReaction: String?
    var userReaction: String?
    let replyExcerpt: String?
    let replyRole: String?

    init(_ m: [String: Any]) {
        id = (m["id"] as? NSNumber)?.intValue
        (botReaction, userReaction) = CloudReactionLogic.split(m["reactions"] as? [[String: Any]] ?? [])
        let r = m["reply_to"] as? [String: Any]
        replyExcerpt = r?["excerpt"] as? String
        replyRole = r?["role"] as? String
    }

    static let quickEmojis = ["👍", "❤️", "😂", "😮", "🙏", "🎉"]
}

/// 后台任务（服务器 /v1/workers）
struct CloudWorkerInfo: Identifiable {
    let id: String
    let title: String
    let status: String
    let lastStep: String
    let result: String
    let elapsed: Double
    let steps: Int
    let workerSession: String
    let botId: String
    let taskId: String?
    let createdAt: Double

    init?(_ d: [String: Any]) {
        guard let id = d["worker_id"] as? String else { return nil }
        self.id = id
        title = d["title"] as? String ?? "后台任务"
        status = d["status"] as? String ?? "queued"
        lastStep = d["last_step"] as? String ?? ""
        result = d["result"] as? String ?? ""
        elapsed = (d["elapsed_s"] as? NSNumber)?.doubleValue ?? 0
        steps = (d["steps"] as? NSNumber)?.intValue ?? 0
        workerSession = d["worker_session"] as? String ?? ""
        botId = d["bot_id"] as? String ?? ""
        taskId = d["task_id"] as? String
        createdAt = (d["created_at"] as? NSNumber)?.doubleValue ?? 0
    }

    var active: Bool { status == "queued" || status == "running" }

    var statusLabel: String {
        switch status {
        case "queued": return "排队中"
        case "running": return "进行中"
        case "completed": return "已完成"
        case "cancelled": return "已停止"
        case "interrupted": return "中断"
        case "limit_reached": return "达到上限"
        default: return "失败"
        }
    }

    var statusColor: Color {
        switch status {
        case "running": return .green
        case "queued": return .orange
        case "completed": return .blue
        default: return .secondary
        }
    }

    static func elapsedText(_ s: Double) -> String {
        let n = Int(s)
        return n < 60 ? "\(n) 秒" : (n < 3600 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n / 3600) 小时 \(n % 3600 / 60) 分")
    }
}

@MainActor
enum CloudRunModelService {
    static func worker(_ id: String) async throws -> CloudWorkerInfo? {
        let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/workers/\(id)")
        return (res["worker"] as? [String: Any]).flatMap(CloudWorkerInfo.init)
    }

    static func workers(botId: String) async throws -> [CloudWorkerInfo] {
        let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/workers?bot=\(botId)")
        return (res["workers"] as? [[String: Any]] ?? []).compactMap(CloudWorkerInfo.init)
    }

    static func stop(_ id: String) async throws {
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/workers/\(id)/stop", body: [:])
    }

    static func message(_ id: String, _ text: String) async throws {
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/workers/\(id)/message", body: ["text": text])
    }

    static func react(sessionId: String, messageId: Int, emoji: String?) async throws {
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/\(sessionId)/messages/\(messageId)/reaction",
                                                     body: ["emoji": emoji ?? ""])
    }
}

/// 对话页给卡片用的动作（选项卡回答、打开别的 Bot）
struct CloudChatActions {
    var answerChoice: (_ messageId: Int, _ selected: [String], _ custom: String?, _ dismissed: Bool, _ text: String) -> Void = { _, _, _, _, _ in }
    var sessionId: String = ""
}

private struct CloudChatActionsKey: EnvironmentKey {
    static let defaultValue = CloudChatActions()
}

extension EnvironmentValues {
    var cloudChatActions: CloudChatActions {
        get { self[CloudChatActionsKey.self] }
        set { self[CloudChatActionsKey.self] = newValue }
    }
}
