import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudApprovalActionsTests {
    static func main() {
        let q = CloudApprovalActions.question(for: [
            "tool": "shell_execute",
            "arguments": ["command": "rm -rf /tmp/openminis-fake"],
            "reason": "destructive",
        ])
        check((q["type"] as? String) == "options", "类型是选项卡")
        let opts = q["options"] as? [[String: Any]]
        let labels = (opts ?? []).compactMap { $0["label"] as? String }
        check(labels.count == 3, "三个选项")
        check(labels == [CloudApprovalActions.onceLabel, CloudApprovalActions.taskLabel, CloudApprovalActions.denyLabel], "选项文案：\(labels)")
        check((q["question"] as? String)?.contains("rm -rf /tmp/openminis-fake") == true, "问题里有命令")

        func result(_ answer: String) -> String {
            "{\"results\":[{\"index\":0,\"status\":\"answered\",\"answer\":\"\(answer)\"}]}"
        }
        check(CloudApprovalActions.decision(fromResult: result(CloudApprovalActions.onceLabel)) == "approve_once", "一次")
        check(CloudApprovalActions.decision(fromResult: result(CloudApprovalActions.taskLabel)) == "approve_task", "本任务")
        check(CloudApprovalActions.decision(fromResult: result(CloudApprovalActions.denyLabel)) == "deny", "拒绝")
        check(CloudApprovalActions.decision(fromResult: "{}") == "deny", "解不出就拒绝")
        check(CloudApprovalActions.decision(fromResult: "{\"results\":[{\"status\":\"answered\",\"answer\":\"同意\"}]}") == "deny", "聊天用词不算")
        print("PASS：审批卡三个选项，回传 approve_once / approve_task / deny，「同意」不会批准")
    }
}
