import SwiftUI

/// 手机上的表盘小组件预览：模拟器里测文案和「暂停 / 批准」按钮。真正装到表盘上要配对手表。
struct CloudWatchComplicationPage: View {
    var body: some View {
        List {
            Section {
                Text("把「Bot 状态」加到手表表盘后，会显示当前 Bot 在干什么、还差几步。点一下打开手表上的状态页，可以暂停任务或批准。")
                Text("表盘小组件本身只能在配了对的手表上添加和点按，模拟器里测不了抬腕和表盘。下面是同样的文案和按钮预览。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Text("表盘小组件") }

            Section {
                CloudWatchComplicationPreviewCard(
                    name: "E2E小助手",
                    working: "正在写代码",
                    stepsLeft: 3,
                    approvals: 1
                )
                .accessibilityIdentifier("watchComplicationPreview")
            } header: { Text("预览") }

            Section {
                CloudWatchStatusPreview(
                    name: "E2E小助手",
                    working: "正在写代码",
                    stepsLeft: 3,
                    approvals: 1
                )
            } header: { Text("点小组件后的状态页") } footer: {
                Text("预览里的暂停和批准不会真的发给云端，只确认按钮能点。配对手表后，点下去才会发到手机执行。")
            }
        }
        .navigationTitle("手表表盘小组件")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CloudWatchComplicationPreviewCard: View {
    let name: String
    let working: String?
    let stepsLeft: Int
    let approvals: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.accentColor, lineWidth: 4)
                    .frame(width: 44, height: 44)
                Text("\(stepsLeft)")
                    .font(.headline.monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(WatchComplicationText.statusLine(name: name, working: working, stepsLeft: stepsLeft, approvals: approvals))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(WatchComplicationText.stepsLine(stepsLeft: stepsLeft, working: working != nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WatchComplicationText.statusLine(name: name, working: working, stepsLeft: stepsLeft, approvals: approvals)
                            + "，" + WatchComplicationText.stepsLine(stepsLeft: stepsLeft, working: working != nil))
    }
}

struct CloudWatchStatusPreview: View {
    let name: String
    let working: String?
    let stepsLeft: Int
    let approvals: Int
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            Text(working ?? "空闲").font(.subheadline).foregroundStyle(.secondary)
            Text(WatchComplicationText.stepsLine(stepsLeft: stepsLeft, working: working != nil))
                .font(.caption)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watchPreviewNotice")
            }
            HStack {
                Button("暂停") {
                    notice = "已发给手机（预览）：暂停"
                    CloudHaptics.tap()
                }
                .accessibilityIdentifier("watchPreviewPause")
                if approvals > 0 {
                    Button("批准") {
                        notice = "已发给手机（预览）：批准"
                        CloudHaptics.tap()
                    }
                    .accessibilityIdentifier("watchPreviewApprove")
                    Button("拒绝", role: .destructive) {
                        notice = "已发给手机（预览）：拒绝"
                        CloudHaptics.tap()
                    }
                    .accessibilityIdentifier("watchPreviewDeny")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
