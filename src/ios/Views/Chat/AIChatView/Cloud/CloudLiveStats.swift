import Foundation

/// 实时资源面板的一个采样点（GET /v1/live-stats）
struct CloudLivePoint: Identifiable, Equatable {
    let t: Double
    let cpu: Double?
    let memUsedMB: Int
    let rxBps: Int?
    let txBps: Int?
    var id: Double { t }

    init(t: Double, cpu: Double?, memUsedMB: Int, rxBps: Int?, txBps: Int?) {
        self.t = t; self.cpu = cpu; self.memUsedMB = memUsedMB; self.rxBps = rxBps; self.txBps = txBps
    }

    init?(_ d: [String: Any]) {
        guard let t = (d["t"] as? NSNumber)?.doubleValue else { return nil }
        self.init(t: t, cpu: (d["cpu"] as? NSNumber)?.doubleValue, memUsedMB: (d["mem_used_mb"] as? NSNumber)?.intValue ?? 0,
                  rxBps: (d["rx_bps"] as? NSNumber)?.intValue, txBps: (d["tx_bps"] as? NSNumber)?.intValue)
    }
}

struct CloudLiveProcess: Identifiable, Equatable {
    let pid: Int
    let name: String
    let rssMB: Double
    var id: Int { pid }
}

struct CloudLiveStats: Equatable {
    var now: CloudLivePoint?
    var history: [CloudLivePoint] = []
    var memoryTotalMB = 0
    var diskUsedMB = 0
    var diskTotalMB = 0
    var load: [Double] = []
    var cores = 1
    var running = 0
    var queued = 0
    var top: [CloudLiveProcess] = []

    init() {}

    init(_ d: [String: Any]) {
        now = (d["now"] as? [String: Any]).flatMap(CloudLivePoint.init)
        history = (d["history"] as? [[String: Any]] ?? []).compactMap(CloudLivePoint.init)
        memoryTotalMB = (d["memory_total_mb"] as? NSNumber)?.intValue ?? 0
        let disk = d["disk"] as? [String: Any] ?? [:]
        diskUsedMB = (disk["used_mb"] as? NSNumber)?.intValue ?? 0
        diskTotalMB = (disk["total_mb"] as? NSNumber)?.intValue ?? 0
        load = (d["load"] as? [NSNumber] ?? []).map(\.doubleValue)
        cores = max(1, (d["cores"] as? NSNumber)?.intValue ?? 1)
        running = (d["running_tasks"] as? NSNumber)?.intValue ?? 0
        queued = (d["queued_tasks"] as? NSNumber)?.intValue ?? 0
        top = (d["top"] as? [[String: Any]] ?? []).compactMap { p in
            guard let pid = (p["pid"] as? NSNumber)?.intValue else { return nil }
            return CloudLiveProcess(pid: pid, name: p["name"] as? String ?? "\(pid)", rssMB: (p["rss_mb"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// 内存占用比例 0…1
    var memoryFraction: Double { memoryTotalMB > 0 ? min(1, Double(now?.memUsedMB ?? 0) / Double(memoryTotalMB)) : 0 }
    var diskFraction: Double { diskTotalMB > 0 ? min(1, Double(diskUsedMB) / Double(diskTotalMB)) : 0 }

    /// 网速文字：B/s、KB/s、MB/s
    static func rate(_ bps: Int?) -> String {
        guard let b = bps else { return "—" }
        if b < 1024 { return "\(b) B/s" }
        if b < 1024 * 1024 { return String(format: "%.1f KB/s", Double(b) / 1024) }
        return String(format: "%.1f MB/s", Double(b) / 1024 / 1024)
    }

    static func size(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
