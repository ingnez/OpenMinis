import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudBotRelayTests {
    static func main() {
        let p = CloudBotRelay.Package(toBot: "scribe", fromBot: "icu", fromSession: "sess_abc",
                                      result: "结论：接力测试通过（假数据）", context: "背景假数据",
                                      goal: "写成三句话", nonce: "relay-nonce-001")
        let b = p.body
        check(b["to_bot"] as? String == "scribe" && b["from_bot"] as? String == "icu", "请求体含双方")
        check(b["client_nonce"] as? String == "relay-nonce-001", "nonce 用于去重")
        check(b["result"] as? String == "结论：接力测试通过（假数据）", "结果原文")
        let r = CloudBotRelay.Receipt.parse(["session_id": "sess_x", "task_id": "task_y", "bot_id": "scribe",
                                             "bot_name": "记录员", "deduped": false])
        check(r?.title == "已交给 记录员 继续" && r?.deduped == false, "回执卡片")
        check(CloudBotRelay.Receipt.parse(["error": "没有这个 Bot"]) == nil, "失败无回执")
        check(CloudBotRelay.clip("abcdef", 3) == "abc…", "截断")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("多 Bot 接力测试全部通过")
    }
}
