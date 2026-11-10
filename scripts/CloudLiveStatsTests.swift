import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudLiveStatsTests {
    static func main() {
        let json = """
        {"now": {"t": 100.0, "cpu": 50.0, "mem_used_mb": 3000, "rx_bps": 2048, "tx_bps": null},
         "memory_total_mb": 4000, "disk": {"used_mb": 4096, "total_mb": 10240}, "load": [0.5, 0.25, 0.1], "cores": 2,
         "running_tasks": 1, "queued_tasks": 3, "top": [{"pid": 7, "name": "python3", "rss_mb": 80.5}],
         "history": [{"t": 98.0, "cpu": 10.0, "mem_used_mb": 1}, {"bad": 1}, {"t": 100.0, "cpu": 50.0, "mem_used_mb": 3000}]}
        """
        let d = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let s = CloudLiveStats(d)
        check(s.now?.cpu == 50 && s.now?.rxBps == 2048 && s.now?.txBps == nil, "当前点（null 网速保留为空）")
        check(s.history.count == 2, "历史里坏点被跳过")
        check(abs(s.memoryFraction - 0.75) < 1e-9 && abs(s.diskFraction - 0.4) < 1e-9, "内存 / 磁盘比例")
        check(s.running == 1 && s.queued == 3 && s.cores == 2 && s.load.count == 3, "任务与负载")
        check(s.top.first?.name == "python3" && s.top.first?.rssMB == 80.5, "进程")
        check(CloudLiveStats.rate(nil) == "—" && CloudLiveStats.rate(512) == "512 B/s" && CloudLiveStats.rate(2048) == "2.0 KB/s"
              && CloudLiveStats.rate(3 * 1024 * 1024) == "3.0 MB/s", "网速文字")
        check(CloudLiveStats.size(512) == "512 MB" && CloudLiveStats.size(2048) == "2.0 GB", "容量文字")
        let empty = CloudLiveStats([:])
        check(empty.now == nil && empty.memoryFraction == 0 && empty.cores == 1, "空数据不崩")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("实时资源面板测试全部通过")
    }
}
