import Charts
import SwiftUI

/// 每日用量柱状图：按 Bot 叠放，没用量的日子也占位；点柱子看当天各 Bot 的数
struct CloudUsageChart: View {
    let points: [CloudUsagePoint]
    @State private var selected: String?

    private var total: Int { points.map(\.tokens).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart(points) { p in
                BarMark(x: .value("日期", String(p.day.suffix(5))), y: .value("tokens", p.tokens))
                    .foregroundStyle(by: .value("Bot", p.series))
                    .opacity(selected == nil || selected == p.day ? 1 : 0.35)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(cloudTokens(n)) } } } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in
                            let x = loc.x - geo[proxy.plotAreaFrame].origin.x
                            if let label: String = proxy.value(atX: x) {
                                let day = points.first { $0.day.hasSuffix(label) }?.day
                                selected = selected == day ? nil : day
                            }
                        }
                }
            }
            .overlay { if total == 0 { Text("这段时间没有用量").font(.caption).foregroundStyle(.secondary) } }
            if let selected {
                let rows = points.filter { $0.day == selected && $0.tokens > 0 }
                Text(selected + "：" + (rows.isEmpty ? "无用量" : rows.map { "\($0.series) \(cloudTokens($0.tokens))" }.joined(separator: " · ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("每日用量图，共 \(cloudTokens(total)) tokens")
    }
}
