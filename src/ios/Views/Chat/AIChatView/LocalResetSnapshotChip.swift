import SwiftUI

/// 本地 /reset 后的新对话顶部：「已保存快照『…』」，点开看快照内容（含后台补上的模型总结），可关掉
struct LocalResetSnapshotChip: View {
    let recent: LocalResetSnapshot.Recent
    let onDismiss: () -> Void
    @State private var showing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("已保存上一段对话的快照").font(.subheadline.weight(.semibold))
                Text("「\(recent.title)」· 需要接着做时我会读它").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("查看") { showing = true }.font(.subheadline.weight(.semibold))
            Button { onDismiss() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                .accessibilityLabel("关闭快照提示")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .sheet(isPresented: $showing) { LocalResetSnapshotSheet(path: recent.path, title: recent.title) }
    }
}

struct LocalResetSnapshotSheet: View {
    let path: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "读取中…" : text)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle("对话快照").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("复制快照")
                }
            }
            // 模型总结在后台补写：打开时读一次，停留时每 3 秒再读，补上了就能看到
            .task {
                while !Task.isCancelled {
                    text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "快照文件已不在了"
                    if text.contains(LocalResetSnapshot.summaryHeading) { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }
}
