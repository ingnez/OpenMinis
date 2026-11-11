import SwiftUI

/// 点表盘小组件或列表里的 Bot 后打开：看还差几步，可以暂停或批准。
struct WatchStatusView: View {
    let row: WatchBotRow
    var onControl: (WatchControlRequest.Action) -> Void
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name).font(.headline)
            Text(row.working ?? row.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            Text(WatchComplicationText.stepsLine(stepsLeft: row.stepsLeft, working: row.working != nil))
                .font(.caption)
            if row.waitingApprovals > 0 {
                Text("待审批 \(row.waitingApprovals) 项").font(.caption).foregroundStyle(.orange)
            }
            if let notice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
            Button("暂停") {
                onControl(.pause)
                notice = "已发给手机：暂停"
            }
            if row.waitingApprovals > 0 || row.approvalId != nil {
                Button("批准") {
                    onControl(.approve)
                    notice = "已发给手机：批准"
                }
                Button("拒绝") {
                    onControl(.deny)
                    notice = "已发给手机：拒绝"
                }
            }
        }
        .navigationTitle("Bot 状态")
    }
}
