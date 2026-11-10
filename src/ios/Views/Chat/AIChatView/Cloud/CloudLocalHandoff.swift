import Foundation

/// 本地 → 云端交接：本地模式做不完的工作打包交给 Bot（POST /v1/handoff）。
/// 没点名 Bot 时交给主 Bot，由它决定自己做还是转给最合适的 Bot。
enum CloudLocalHandoff {
    struct Package {
        var goal: String
        var summary: String
        var progress: String
        var outputs: String
        var remaining: String
        var files: [(name: String, data: Data)]
        var targetBot: String?

        var body: [String: Any] {
            var b: [String: Any] = ["goal": goal, "summary": summary, "progress": progress, "outputs": outputs, "remaining": remaining,
                                    "files": files.map { ["filename": $0.name, "data_base64": $0.data.base64EncodedString()] }]
            if let targetBot { b["target_bot"] = targetBot }
            return b
        }
    }

    struct Receipt: Codable, Equatable {
        let sessionId: String
        let taskId: String
        let botId: String
        let botName: String
        let routed: Bool
        var files: [String]

        /// 本地对话里那张卡片上的字
        var title: String { routed ? "已交给 主 Bot → \(botName) 在云端继续" : "已交给 \(botName) 在云端继续" }
    }

    /// 用户这句话是不是要交给 Bot：返回 nil = 不是；.some(nil) = 交给主 Bot；.some(id) = 点名的 Bot。
    /// bots 是 (id, 名字)。只认明确的说法（「交给 Bot」「转给 @码农」「让云端继续」），不把普通的「交给你」当成交接。
    static func intent(_ text: String, bots: [(id: String, name: String)]) -> String?? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        // @名字：点名的 Bot
        let named = bots.sorted { $0.name.count > $1.name.count }.first { b in
            !b.name.isEmpty && (t.contains("@" + b.name) || t.contains("＠" + b.name))
        }
        let verbs = ["交给", "转给", "交接给", "移交给", "让", "hand off to", "handoff to", "send to"]
        let objects = ["bot", "云端", "云上", "主 bot", "主bot"]
        let hasVerbObject = verbs.contains { v in
            guard let r = lower.range(of: v) else { return false }
            let after = lower[r.upperBound...].prefix(8)
            return objects.contains { after.contains($0) } || after.contains("@") || after.contains("＠")
        }
        if let named, hasVerbObject || t.hasPrefix("@" + named.name) || t.hasPrefix("＠" + named.name) { return .some(named.id) }
        return hasVerbObject ? .some(nil) : nil
    }

    static func send(_ package: Package) async throws -> Receipt {
        let res = try await CloudConnection.shared.request(method: "POST", path: "/v1/handoff", body: package.body)
        guard let sid = res["session_id"] as? String, let tid = res["task_id"] as? String, let bid = res["bot_id"] as? String else {
            throw NSError(domain: "CloudLocalHandoff", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: res["error"] as? String ?? "交接失败"])
        }
        return Receipt(sessionId: sid, taskId: tid, botId: bid, botName: res["bot_name"] as? String ?? bid,
                       routed: res["routed"] as? Bool ?? false, files: res["files"] as? [String] ?? [])
    }

    /// 截断成给模型看的长度
    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
}
