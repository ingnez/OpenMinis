import SwiftUI

struct CloudShortcutDraftCard: View {
    let card: CloudCards.Card
    @State private var file: URL?
    @State private var isDownloading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.payload["title"] as? String ?? "快捷指令草稿")
                .font(.subheadline.weight(.medium))
            Text("XML 草稿，签名后可导入快捷指令")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let file {
                ShareLink(item: file) { Label("分享草稿", systemImage: "square.and.arrow.up") }
            } else {
                Button {
                    Task { await download() }
                } label: {
                    Label(isDownloading ? "正在下载" : "下载草稿", systemImage: "arrow.down.circle")
                }
                .disabled(isDownloading)
            }
            if failed { Text("下载失败，可再试一次。").font(.caption).foregroundStyle(.red) }
        }
        .buttonStyle(.bordered)
    }

    @MainActor
    private func download() async {
        guard !isDownloading, let path = card.payload["attachment_url"] as? String,
              path.range(of: #"^/v1/sessions/[A-Za-z0-9_-]+/attachments/up_[a-f0-9]{8}_OpenMinis-shortcut\.xml$"#,
                         options: .regularExpression) != nil else { return }
        isDownloading = true
        failed = false
        defer { isDownloading = false }
        do {
            let data = try await CloudBotService.connected().downloadAttachment(path: path)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenMinisShortcuts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try data.write(to: url, options: .atomic)
            file = url
        } catch {
            failed = true
        }
    }
}
