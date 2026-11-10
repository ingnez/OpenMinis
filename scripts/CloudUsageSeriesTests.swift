import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudUsageSeriesTests {
    static func main() {
        check(CloudUsageSeries.days(endingAt: "2026-03-01", count: 3) == ["2026-02-27", "2026-02-28", "2026-03-01"], "跨月补齐日期")
        let items: [[String: Any]] = [
            ["day": "2026-11-08", "bot_id": "", "total_tokens": 100],
            ["day": "2026-11-10", "bot_id": "a", "total_tokens": 50],
            ["day": "2026-11-10", "bot_id": "b", "total_tokens": 5],
            ["day": "2026-11-10", "bot_id": "c", "total_tokens": 4],
            ["day": "2026-11-10", "bot_id": "d", "total_tokens": 3],
        ]
        let p = CloudUsageSeries.points(items: items, today: "2026-11-10", count: 7, names: ["a": "制造厂"])
        check(Set(p.map(\.day)).count == 7, "7 天都有，没用量的天记 0")
        check(Set(p.map(\.series)) == ["主助手", "制造厂", "b", "其他"], "超过 4 个 Bot 合并成其他")
        check(p.first { $0.day == "2026-11-10" && $0.series == "其他" }?.tokens == 7, "其他 = c + d")
        check(p.filter { $0.day == "2026-11-09" }.allSatisfy { $0.tokens == 0 }, "空白日为 0")
        check(p.filter { $0.day == "2026-11-08" }.map(\.tokens).reduce(0, +) == 100, "当天合计不变")
        let e = CloudUsageSeries.points(items: [], today: "2026-11-10", count: 7, names: [:])
        check(e.count == 7 && e.allSatisfy { $0.tokens == 0 }, "没有数据也画出 7 天的 0")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("用量图数据测试全部通过")
    }
}
