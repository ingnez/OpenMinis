import Foundation

/// 任务进度时间轴：开始时间、每一步、失败步骤可单独重试。只依赖 Foundation，Linux 上可测。
enum CloudTaskTimeline {
    struct Step: Equatable, Identifiable {
        let id: Int
        let title: String
        let status: String          // pending, running, done, failed
        var retryable: Bool { status == "failed" || status == "interrupted" }
    }

    static func startLabel(createdAt: Double, now: Double = Date().timeIntervalSince1970) -> String {
        guard createdAt > 0 else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let clock = f.string(from: Date(timeIntervalSince1970: createdAt))
        let ago = max(0, Int(now - createdAt))
        if ago < 60 { return "开始于 \(clock)（\(ago) 秒前）" }
        if ago < 3600 { return "开始于 \(clock)（\(ago / 60) 分钟前）" }
        return "开始于 \(clock)"
    }

    /// 从任务字段和过程回合标题拼出步骤。最后一步若任务失败则标 failed，可重试。
    static func steps(createdAt: Double, status: String, lastStep: String, turnTitles: [String]) -> [Step] {
        var titles = turnTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if titles.isEmpty, !lastStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titles = [lastStep]
        }
        if titles.isEmpty { return [] }
        let failed = ["failed", "interrupted", "cancelled", "limit_reached"].contains(status)
        let running = status == "running" || status == "queued"
        return titles.enumerated().map { i, title in
            let last = i == titles.count - 1
            let st: String
            if last, failed { st = status == "interrupted" ? "interrupted" : "failed" }
            else if last, running { st = "running" }
            else { st = "done" }
            return Step(id: i + 1, title: title, status: st)
        }
    }

    static func retryPrompt(step: Step) -> String {
        "请从步骤「\(step.title)」重试，不要从头开始。"
    }
}
