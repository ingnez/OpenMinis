import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudTaskTimelineTests {
    static func main() {
        let label = CloudTaskTimeline.startLabel(createdAt: 1_000, now: 1_000 + 125)
        check(label.contains("开始于") && label.contains("2 分钟前"), "开始时间文案：\(label)")
        check(CloudTaskTimeline.startLabel(createdAt: 0).isEmpty, "没有开始时间就空")

        let running = CloudTaskTimeline.steps(createdAt: 1, status: "running", lastStep: "正在检索", turnTitles: ["打开病历", "正在检索"])
        check(running.map(\.status) == ["done", "running"], "进行中：前面完成、最后一步在跑")
        check(running.map(\.title) == ["打开病历", "正在检索"], "步骤标题")
        check(!running[0].retryable && !running[1].retryable, "进行中不能重试")

        let failed = CloudTaskTimeline.steps(createdAt: 1, status: "failed", lastStep: "写入失败", turnTitles: ["打开病历", "写入失败"])
        check(failed.last?.status == "failed" && failed.last?.retryable == true, "失败的最后一步可重试")
        check(!failed[0].retryable, "已完成的步骤不重试")
        check(CloudTaskTimeline.retryPrompt(step: failed[1]) == "请从步骤「写入失败」重试，不要从头开始。", "重试提示")

        let fallback = CloudTaskTimeline.steps(createdAt: 1, status: "running", lastStep: "正在分析", turnTitles: [])
        check(fallback.map(\.title) == ["正在分析"], "没有回合时用 lastStep")
        check(CloudTaskTimeline.steps(createdAt: 1, status: "queued", lastStep: "", turnTitles: []).isEmpty, "还没步骤")

        print("PASS：任务进度时间轴（开始时间、步骤状态、单步重试提示）")
    }
}
