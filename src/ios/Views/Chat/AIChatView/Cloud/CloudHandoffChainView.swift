import SwiftUI

/// 委托记录顶部的「接力链」：每条链一张卡，从上到下画出谁交给了谁、每一跳的状态和总用时
struct CloudHandoffChainSection: View {
    let items: [[String: Any]]

    var body: some View {
        let chains = CloudHandoffChain.build(items).prefix(8)
        if !chains.isEmpty {
            Section {
                ForEach(Array(chains)) { chain in CloudHandoffChainCard(chain: chain) }
            } header: { Text("接力链") } footer: { Text("一条链 = 一次请求在 Bot 之间转了几手。缩进表示是谁再转出去的。") }
        }
    }
}

struct CloudHandoffChainCard: View {
    let chain: CloudHandoffChain

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chain.names.joined(separator: " → ")).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(CloudHandoffChain.durationText(chain.duration(now: Date().timeIntervalSince1970)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(chain.hops, id: \.id) { hop in
                HStack(spacing: 6) {
                    Circle().fill(color(hop.status)).frame(width: 7, height: 7)
                    Text("\(hop.fromName) → \(hop.toName)").font(.caption)
                    if hop.status == "running" { ProgressView().scaleEffect(0.5) }
                }
                .padding(.leading, CGFloat(min(hop.depth, 4)) * 14)
                .accessibilityLabel("\(hop.fromName) 交给 \(hop.toName)，\(hop.status)")
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "completed": return .green
        case "failed": return .red
        case "running", "queued": return .blue
        default: return .secondary
        }
    }
}
