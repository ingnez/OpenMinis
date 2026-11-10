import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudReplayTests {
    static func main() {
        let d: [String: Any] = ["frames": [["i": 1, "t": 20.0, "steps": ["点击 (1, 2)"]], ["i": 0, "t": 10.0, "steps": []], ["bad": true]]]
        let f = CloudReplayFrame.list(d)
        check(f.map(\.index) == [0, 1], "按帧号排序、跳过坏帧")
        check(f[1].steps == ["点击 (1, 2)"], "动作说明")
        let a = CloudReplayFrame(index: 0, time: 0, steps: []), b = CloudReplayFrame(index: 1, time: 4, steps: []),
            c = CloudReplayFrame(index: 2, time: 100, steps: [])
        check(CloudReplayClock.delay(from: a, to: b) == 1.0, "真实 4 秒压成 1 秒")
        check(CloudReplayClock.delay(from: a, to: a) == 0.6 && CloudReplayClock.delay(from: b, to: c) == 2.5, "最短 0.6 秒、最长 2.5 秒")
        check(CloudReplayClock.next(0, count: 2) == 1 && CloudReplayClock.next(1, count: 2) == nil, "播完停下")
        check(CloudReplayClock.durationText(42) == "42 秒" && CloudReplayClock.durationText(125) == "2 分 5 秒", "时长文字")
        let s = CloudReplaySummary.list(["replays": [["task_id": "task_x", "frames": 3, "started_at": 1.0, "ended_at": 5.0]]])
        check(s.first?.taskId == "task_x" && s.first?.frames == 3, "回放列表")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("录屏回放测试全部通过")
    }
}
