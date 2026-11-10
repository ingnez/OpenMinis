import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 秒开实测：从系统创建 App 进程到 Bot 首页第一次出现在屏幕上的真实耗时，每次冷启动记一条，
/// 存进本机实测（CloudClientMetrics，mode=app kind=cold_start），在「速度」页显示中位数。不编数字：没测到就是「—」。
enum CloudColdStart {
    @MainActor private static var recorded = false

    /// 进程启动时间（sysctl KERN_PROC_PID 的 p_starttime）；取不到返回 nil
    static func processStart() -> Date? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }

    /// 只认合理范围：太长（> 60 秒）多半是后台预启动后很久才打开，不算冷启动
    static func plausible(_ ms: Double) -> Bool { ms > 0 && ms < 60_000 }

    @MainActor
    static func markHomeVisible(hasContent: Bool) {
        guard !recorded, hasContent, let start = processStart() else { return }
        recorded = true
        let ms = Date().timeIntervalSince(start) * 1000
        if plausible(ms) { CloudClientMetrics.record(mode: "app", kind: "cold_start", ms: ms) }
    }
}
