import Foundation

/// 录屏回放的一帧（GET /v1/tasks/<id>/replay）：截图之前做过的动作说明
struct CloudReplayFrame: Identifiable, Equatable {
    let index: Int
    let time: Double
    let steps: [String]
    var id: Int { index }

    static func list(_ d: [String: Any]) -> [CloudReplayFrame] {
        (d["frames"] as? [[String: Any]] ?? []).compactMap { f in
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

    static func list(_ d: [String: Any]) -> [CloudReplaySummary] {
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
