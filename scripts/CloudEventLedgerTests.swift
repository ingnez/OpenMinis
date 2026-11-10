import Foundation

@main struct CloudEventLedgerTests {
    static func main() {
        var l = CloudEventLedger()
        let a: [[String: Any]] = [["id": 1, "type": "thought"], ["id": 2, "type": "tool_call"]]
        precondition(l.fresh(a).count == 2)
        // 全量重拉 + 长轮询重叠：已用过的 1、2 不再出现，只剩 3
        let b: [[String: Any]] = [["id": 1], ["id": 2], ["monotonic_id": 3, "id": 3]]
        let f = l.fresh(b)
        precondition(f.count == 1 && CloudEventLedger.eventId(f[0]) == 3)
        precondition(l.fresh(b).isEmpty)
        precondition(l.fresh([["type": "x"]]).count == 1)   // 没 id 的照常放行
        l.reset(); precondition(l.fresh(a).count == 2)

        precondition(CloudEventLedger.toolCallId("call_1", eventId: 9) == "call_1")
        precondition(CloudEventLedger.toolCallId(nil, eventId: 9) == "ev-9")
        precondition(CloudEventLedger.toolCallId("", eventId: 9) == "ev-9")
        precondition(CloudEventLedger.toolCallId(NSNull(), eventId: 9) == "ev-9")

        // 历史：旧问答 + 这次的问题 + 这次任务已写进历史的两轮
        let roles = ["user", "assistant", "user", "assistant", "tool", "assistant"]
        let ts: [Double?] = [1, 2, 100, 101, 102, 103]
        precondition(CloudEventLedger.visibleHistoryCount(roles: roles, timestamps: ts, liveShown: false, taskStartedAt: 100) == 6)
        precondition(CloudEventLedger.visibleHistoryCount(roles: roles, timestamps: ts, liveShown: true, taskStartedAt: 100) == 3)
        precondition(CloudEventLedger.visibleHistoryCount(roles: roles, timestamps: ts, liveShown: true, taskStartedAt: nil) == 3)
        // 任务不是最后那条用户消息触发的（例行任务）：只隐藏任务开始之后的
        let ts2: [Double?] = [1, 2, 3, 4, 200, 201]
        precondition(CloudEventLedger.visibleHistoryCount(roles: roles, timestamps: ts2, liveShown: true, taskStartedAt: 200) == 4)
        precondition(CloudEventLedger.visibleHistoryCount(roles: ["assistant", "assistant"], timestamps: [1, 50], liveShown: true, taskStartedAt: 50) == 1)
        print("PASS：事件按 id 去重、稳定的工具 id、进行中的任务不从历史重复画")
    }
}
