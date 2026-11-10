//
//  CloudEventLedger.swift
//  Minis - 多 Bot 对话「每一步只出现一次」的规则（只依赖 Foundation，便于在 Linux / 快速检查里单测）：
//  - 任务事件按事件 id 只用一次：全量重拉、长轮询、断线恢复互相重叠时不再重复追加文字和工具步骤
//  - 任务进行中，这次任务已经写进服务器历史的那几轮回复不再从历史里画一遍（由实时事件那一份负责）
//

import Foundation

struct CloudEventLedger {
    private(set) var seen = Set<Int>()

    static func eventId(_ ev: [String: Any]) -> Int? {
        (ev["monotonic_id"] as? Int) ?? (ev["id"] as? Int)
    }

    /// 返回还没用过的事件（保持顺序）；没有 id 的事件照常放行
    mutating func fresh(_ events: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for ev in events {
            if let id = Self.eventId(ev) {
                guard seen.insert(id).inserted else { continue }
            }
            out.append(ev)
        }
        return out
    }

    mutating func reset() { seen.removeAll() }

    /// 工具调用 id：有的中转站不给 id，用事件 id 生成稳定的，重放时不会变成新的一步
    static func toolCallId(_ raw: Any?, eventId: Int?) -> String {
        if let s = raw as? String, !s.isEmpty { return s }
        if let eventId { return "ev-\(eventId)" }
        return UUID().uuidString
    }

    /// 历史消息里有多少条要画出来。任务进行中且实时那一份在显示时，
    /// 最后一条用户消息之后、并且不早于任务开始的助手 / 工具消息属于这次任务，交给实时那一份。
    /// roles / timestamps 与服务器 messages 一一对应。
    static func visibleHistoryCount(roles: [String], timestamps: [Double?], liveShown: Bool, taskStartedAt: Double?) -> Int {
        guard liveShown else { return roles.count }
        guard let lastUser = roles.lastIndex(of: "user") else {
            // 没有用户消息（例行任务等）：只按时间切
            guard let start = taskStartedAt else { return roles.count }
            return roles.indices.first(where: { (timestamps[$0] ?? 0) >= start - 1 }) ?? roles.count
        }
        var cut = lastUser + 1
        if let start = taskStartedAt, let ts = timestamps[lastUser], ts < start - 1 {
            // 最后一条用户消息比这个任务还早（任务不是它触发的）：只隐藏任务开始之后的
            cut = (lastUser + 1..<roles.count).first(where: { (timestamps[$0] ?? 0) >= start - 1 }) ?? roles.count
        }
        return cut
    }
}
