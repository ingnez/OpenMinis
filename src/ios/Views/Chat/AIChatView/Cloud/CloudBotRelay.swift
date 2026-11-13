import Foundation

/// 多 Bot 接力：把当前结果打包交给另一个 Bot 继续做（POST /v1/relay）。
enum CloudBotRelay {
    struct Package {
        var toBot: String
        var fromBot: String?
        var fromSession: String?
        var result: String
        var context: String
        var goal: String
        var nonce: String

        init(toBot: String, fromBot: String? = nil, fromSession: String? = nil,
             result: String, context: String = "", goal: String = "", nonce: String = "relay-nonce") {
            self.toBot = toBot
            self.fromBot = fromBot
            self.fromSession = fromSession
            self.result = result
            self.context = context
            self.goal = goal
            self.nonce = nonce
        }

        var body: [String: Any] {
            var b: [String: Any] = ["to_bot": toBot, "result": result, "context": context, "goal": goal,
                                    "client_nonce": nonce]
            if let fromBot { b["from_bot"] = fromBot }
            if let fromSession { b["from_session"] = fromSession }
            return b
        }
    }

    struct Receipt: Equatable {
        let sessionId: String
        let taskId: String
        let botId: String
        let botName: String
        let deduped: Bool
        var title: String { "已交给 \(botName) 继续" }

        static func parse(_ res: [String: Any]) -> Receipt? {
            guard let sid = res["session_id"] as? String, let tid = res["task_id"] as? String,
                  let bid = res["bot_id"] as? String else { return nil }
            return Receipt(sessionId: sid, taskId: tid, botId: bid, botName: res["bot_name"] as? String ?? bid,
                           deduped: res["deduped"] as? Bool ?? false)
        }
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
}
