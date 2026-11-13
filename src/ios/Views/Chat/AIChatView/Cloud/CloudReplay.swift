import Foundation

/// 录屏回放的一帧（GET /v1/tasks/<id>/replay）：截图之前做过的动作说明
struct CloudReplayFrame: Identifiable, Equatable {
    let index: Int
    let time: Double
    let steps: [String]
    var id: Int { index }

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_REPLAY"] == "1" }

    static func e2eFrames() -> [CloudReplayFrame] {
        [
            CloudReplayFrame(index: 0, time: 0, steps: ["打开浏览器"]),
            CloudReplayFrame(index: 1, time: 4, steps: ["点击 (120, 80)"]),
            CloudReplayFrame(index: 2, time: 10, steps: ["截图确认"]),
        ]
    }

    static func list(_ d: [String: Any]) -> [CloudReplayFrame] {
        if e2eForced, (d["frames"] as? [[String: Any]] ?? []).isEmpty { return e2eFrames() }
        return (d["frames"] as? [[String: Any]] ?? []).compactMap { f in
            guard let i = (f["i"] as? NSNumber)?.intValue else { return nil }
            return CloudReplayFrame(index: i, time: (f["t"] as? NSNumber)?.doubleValue ?? 0, steps: f["steps"] as? [String] ?? [])
        }.sorted { $0.index < $1.index }
    }
}

struct CloudReplaySummary: Identifiable, Equatable {
    let taskId: String
    let frames: Int
    let startedAt: Double
    let endedAt: Double
    var id: String { taskId }

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_REPLAY"] == "1" }

    static func e2eItems() -> [CloudReplaySummary] {
        [CloudReplaySummary(taskId: "e2e-replay", frames: 3, startedAt: 1, endedAt: 12)]
    }

    static func list(_ d: [String: Any]) -> [CloudReplaySummary] {
        if e2eForced { return e2eItems() + _parse(d) }
        return _parse(d)
    }

    private static func _parse(_ d: [String: Any]) -> [CloudReplaySummary] {
        (d["replays"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["task_id"] as? String else { return nil }
            return CloudReplaySummary(taskId: id, frames: (r["frames"] as? NSNumber)?.intValue ?? 0,
                                      startedAt: (r["started_at"] as? NSNumber)?.doubleValue ?? 0,
                                      endedAt: (r["ended_at"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
}

/// 播放进度：自动播放按真实间隔压缩（最短 0.6 秒、最长 2.5 秒一帧），播完停在最后一帧
enum CloudReplayClock {
    static func delay(from a: CloudReplayFrame, to b: CloudReplayFrame, speed: Double = 1) -> Double {
        let real = max(0, b.time - a.time) / max(0.25, speed)
        return min(2.5, max(0.6, real / 4))
    }

    static func next(_ i: Int, count: Int) -> Int? { i + 1 < count ? i + 1 : nil }

    static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }
}

/// 回放里「从这一步重做」：告诉 Bot 上次第 N 步做了什么，从这里接着重新执行
enum CloudReplayRedo {
    static func message(step: Int, total: Int, actions: [String]) -> String {
        let did = actions.isEmpty ? "（这一步没有记录动作）" : actions.prefix(5).joined(separator: "；")
        return "[从这一步重做] 上次任务一共 \(total) 帧，请从第 \(step + 1) 帧重新做。那一步做的是：\(did)。"
            + "先截图看看现在屏幕的状态，前面已经完成的步骤不要重复；如果状态和当时不一样，先说明再继续。"
    }
}
