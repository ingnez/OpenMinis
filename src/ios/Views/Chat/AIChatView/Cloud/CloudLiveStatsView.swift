import Charts
import SwiftUI

/// 实时资源面板：打开时每 2 秒取一次，离开页面就停
struct CloudLiveStatsView: View {
    @State private var stats = CloudLiveStats()
    @State private var error: String?

    var body: some View {
        List {
            Section("CPU（\(stats.cores) 核）") {
                CloudLiveGauge(title: "CPU", value: (stats.now?.cpu ?? 0) / 100, text: stats.now?.cpu.map { String(format: "%.0f%%", $0) } ?? "测量中…")
                CloudLiveCPUChart(points: stats.history)
                if !stats.load.isEmpty {
                    Text("负载 " + stats.load.map { String(format: "%.2f", $0) }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("内存 / 磁盘") {
                CloudLiveGauge(title: "内存", value: stats.memoryFraction,
                               text: "\(CloudLiveStats.size(stats.now?.memUsedMB ?? 0)) / \(CloudLiveStats.size(stats.memoryTotalMB))")
                CloudLiveGauge(title: "磁盘", value: stats.diskFraction,
                               text: "\(CloudLiveStats.size(stats.diskUsedMB)) / \(CloudLiveStats.size(stats.diskTotalMB))")
            }
            Section("网络 · 任务") {
                LabeledContent("下载", value: CloudLiveStats.rate(stats.now?.rxBps))
                LabeledContent("上传", value: CloudLiveStats.rate(stats.now?.txBps))
                LabeledContent("运行中 / 排队", value: "\(stats.running) / \(stats.queued)")
            }
            Section("占内存最多的进程") {
                ForEach(stats.top) { p in LabeledContent(p.name, value: String(format: "%.0f MB", p.rssMB)) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle("实时资源")
        .task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                stats = CloudLiveStats(try await CloudConnection.shared.request(method: "GET", path: "/v1/live-stats"))
                error = nil
            } catch {
                self.error = "取不到：\(error.localizedDescription)"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

struct CloudLiveGauge: View {
    let title: String
    let value: Double
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(text).monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value: max(0, min(1, value))).tint(value > 0.85 ? .red : value > 0.6 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CloudLiveCPUChart: View {
    let points: [CloudLivePoint]

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("时间", Date(timeIntervalSince1970: p.t)), y: .value("CPU", p.cpu ?? 0))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .frame(height: 90)
        .overlay { if points.count < 2 { Text("采样中…").font(.caption).foregroundStyle(.secondary) } }
        .accessibilityLabel("CPU 占用曲线")
    }
}
