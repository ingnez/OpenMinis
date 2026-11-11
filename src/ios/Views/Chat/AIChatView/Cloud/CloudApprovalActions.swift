import Foundation

/// 云端风险操作审批卡的四个选项：批准一次 / 本任务内都批准 / 本班次都批准 / 拒绝。
/// 绑定到任务+工具+参数哈希；聊天原文「同意」不会走到这里。纯 Foundation，Linux 可单测。
enum CloudApprovalActions {
    static let onceLabel = "批准一次"
    static let taskLabel = "本任务内都批准"
    static let shiftLabel = "本班次都批准"
    static let denyLabel = "拒绝"

    static let onceDecision = "approve_once"
    static let taskDecision = "approve_task"
    static let shiftDecision = "approve_shift"
    static let denyDecision = "deny"

    static func question(for payload: [String: Any]) -> [String: Any] {
        let tool = payload["tool"] as? String ?? "tool"
        let args = payload["arguments"] as? [String: Any] ?? [:]
        let detail: String
        if let command = args["command"] as? String {
            detail = command
        } else if let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) {
            detail = text
        } else {
            detail = tool
        }
        return [
            "type": "options",
            "header": "云电脑审批",
            "question": "允许云电脑执行 \(tool)：\(String(detail.prefix(600)))",
            "impact": "「\(onceLabel)」只放行这一次完全相同的调用；「\(taskLabel)」在本任务内同样参数的后续调用可直接执行（30 分钟内）；「\(shiftLabel)」在本班次（值班结束或 12 小时内）同样参数可直接执行。拒绝后该步骤不会执行。在聊天里说「同意」不会批准。用口令批准视为批准一次。",
            "risk": "high",
            "options": [
                ["label": onceLabel],
                ["label": taskLabel],
                ["label": shiftLabel],
                ["label": denyLabel],
            ],
        ]
    }

    /// 从 UserAsk 结果 JSON 读出要回传给服务器的 decision。解不出选项时按拒绝处理（避免误放行）。
    static func decision(fromResult json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let first = results.first else { return denyDecision }
        let answer: String
        if let s = first["answer"] as? String {
            answer = s
        } else if let arr = first["answer"] as? [String], let s = arr.first {
            answer = s
        } else {
            return denyDecision
        }
        switch answer {
        case onceLabel: return onceDecision
        case taskLabel: return taskDecision
        case shiftLabel: return shiftDecision
        default: return denyDecision
        }
    }
}
