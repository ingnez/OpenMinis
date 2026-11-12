import Foundation

// 每条回复下面的耗时（首字 / 总 / tokens）只属于产生它的任务（假数据）
var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudLatencyTests {
    static func main() {
        let task: [String: Any] = ["task_id": "t1", "created_at": 1_000.0,
                                   "timings": ["first_text_ms": 22_400.0, "total_ms": 22_900.0, "prompt_tokens": 45_000,
                                               "completion_tokens": 403, "finished_at": 1_022.9]]
        let tasks = [task]
        let reply: [String: Any] = ["role": "assistant", "timestamp": 1_022.5]
        check(CloudLatency.line(for: reply, tasks: tasks) == "首字 22.4 秒 · 总 22.9 秒 · 45403 tokens", "任务自己的回复显示耗时")
        // 真机 09:26：实时语音通话结束后存进来的字幕（没有任务）借用了上一个任务的数字
        for (i, ts) in [1_300.0, 1_310.0, 1_320.0].enumerated() {
            let voice: [String: Any] = ["role": "assistant", "timestamp": ts]
            check(CloudLatency.line(for: voice, tasks: tasks) == nil, "语音字幕第 \(i + 1) 句不显示别的任务的耗时")
        }
        // 旧服务器没给 finished_at：按开始时间 + 总时长判断
        var oldTimings = task["timings"] as! [String: Any]
        oldTimings.removeValue(forKey: "finished_at")
        let oldTasks: [[String: Any]] = [["task_id": "t1", "created_at": 1_000.0, "timings": oldTimings]]
        check(CloudLatency.line(for: reply, tasks: oldTasks) != nil, "旧服务器：任务内的回复照常显示")
        check(CloudLatency.line(for: ["timestamp": 1_300.0], tasks: oldTasks) == nil, "旧服务器：任务结束很久后的消息不显示")
        // 没有数据就不显示
        check(CloudLatency.line(for: ["timestamp": 1_010.0], tasks: [["created_at": 1_000.0]]) == nil, "任务没有耗时数据不显示")
        check(CloudLatency.line(for: ["timestamp": 900.0], tasks: tasks) == nil, "消息早于所有任务不显示")
        check(CloudLatency.line(for: [:], tasks: tasks) == nil, "消息没有时间戳不显示")
        // 两个任务：各自的回复各自的数字
        let t2: [String: Any] = ["task_id": "t2", "created_at": 2_000.0,
                                 "timings": ["first_text_ms": 800.0, "total_ms": 1_500.0, "finished_at": 2_001.5]]
        check(CloudLatency.line(for: ["timestamp": 2_001.4], tasks: tasks + [t2]) == "首字 800 毫秒 · 总 1.5 秒", "第二个任务的回复用自己的数字")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("PASS：回复耗时只挂在产生它的任务上")
    }
}
