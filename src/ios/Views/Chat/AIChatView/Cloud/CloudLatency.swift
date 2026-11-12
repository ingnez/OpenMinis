import Foundation

/// 每条回复的耗时：服务器在会话详情的 tasks[].timings 里返回（首字、总时长、token）
enum CloudLatency {
    /// 任务结束后多久之内的回复还算这个任务产生的（服务端写消息和记耗时有先后）
    static let finishSlack: Double = 5

    static func ms(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    static func format(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.1f 秒", ms / 1000) : "\(Int(ms)) 毫秒"
    }

    /// 找到产生这条回复的任务：任务开始不晚于消息、且消息写在任务结束（加一点余量）之前。
    /// 不是任何任务产生的消息（实时语音通话存进来的字幕、别处追加的文字）没有耗时，返回 nil，
    /// 以前会借用前一个任务的数字，真机 09:26 每句语音字幕都挂着同一个「首字 22.4 秒 · 45403 tokens」。
    static func timings(for message: [String: Any], tasks: [[String: Any]]) -> [String: Any]? {
        guard let ts = ms(message["timestamp"]) else { return nil }
        let candidates = tasks.filter { (ms($0["created_at"]) ?? .infinity) <= ts + 0.001 }
        guard let best = candidates.max(by: { (ms($0["created_at"]) ?? 0) < (ms($1["created_at"]) ?? 0) }),
              let t = best["timings"] as? [String: Any] else { return nil }
        let end: Double?
        if let finished = ms(t["finished_at"]) {
            end = finished
        } else if let created = ms(best["created_at"]), let total = ms(t["total_ms"]) {
            end = created + total / 1000   // 旧服务器没给 finished_at：开始时间 + 总时长
        } else {
            end = nil
        }
        if let end, ts > end + finishSlack { return nil }
        return t
    }

    static func line(for message: [String: Any], tasks: [[String: Any]]) -> String? {
        guard let t = timings(for: message, tasks: tasks) else { return nil }
        var parts: [String] = []
        if let f = ms(t["first_text_ms"]) { parts.append("首字 \(format(f))") }
        if let total = ms(t["total_ms"]) { parts.append("总 \(format(total))") }
        let tokens = Int(ms(t["prompt_tokens"]) ?? 0) + Int(ms(t["completion_tokens"]) ?? 0)
        if tokens > 0 { parts.append("\(tokens) tokens") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
