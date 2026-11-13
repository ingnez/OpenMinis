import QuickLook
import SwiftUI
import WebKit

/// 聊天里的交付卡片：类型图标、文件名、大小/页数、缩略图；点开预览，按钮：打开 / 存到文件 / 分享 / 用 WPS 打开。
struct CloudFileCardView: View {
    let item: CloudDeliverable
    let sessionId: String
    let accent: Color
    @StateObject private var dl: CloudFileDownload
    @State private var previewURL: URL?
    @State private var linkURL: URL?
    @State private var remoteThumbnail: UIImage?
    @State private var shareURL: URL?
    @State private var exportURL: URL?
    @State private var showHTML = false
    @State private var zipExpanded = false
    @State private var htmlURL: URL?
    @State private var errorText: String?
    @State private var savedFileName: String?

    init(item: CloudDeliverable, sessionId: String, accent: Color) {
        self.item = item
        self.sessionId = sessionId
        self.accent = accent
        _dl = StateObject(wrappedValue: CloudFileDownload(item: item, sessionId: sessionId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) { header }
                .buttonStyle(.plain)
            if item.kind == .zip, !item.entries.isEmpty {
                zipList
            }
            actions
            if let savedFileName {
                Label("已存到文件：\(savedFileName)", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("deliverableSavedLocation")
            }
            if case .running(let f) = dl.state {
                ProgressView(value: f).tint(accent)
                    .accessibilityLabel("下载进度")
                    .accessibilityValue("\(Int(f * 100))%")
            }
            if case .failed(let msg) = dl.state {
                Button { Task { await dl.retry() } } label: {
                    Label("下载失败，点此重试", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                }
                .accessibilityIdentifier("deliverableRetry")
                Text(msg).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deliverableCard-\(item.name)")
        .task(id: item.id) {
            if let path = item.thumbURL,
               let file = try? await CloudConnection.shared.downloadDeliverable(
                   path: path, id: item.id + "-thumb", name: "thumb.jpg", expectedBytes: 0, onProgress: { _ in }) {
                remoteThumbnail = UIImage(contentsOfFile: file.path)
            } else if item.kind == .image, item.source == "local" {
                await dl.start()
            }
        }
        .sheet(item: Binding(get: { previewURL.map(IdentifiedURL.init) }, set: { previewURL = $0?.url })) { wrapped in
            NavigationView {
                DeliveryQuickLook(url: wrapped.url)
                    .navigationTitle(item.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { previewURL = nil }
                                .accessibilityIdentifier("closeDeliverablePreview")
                        }
                    }
            }
        }
        .sheet(item: Binding(get: { shareURL.map(IdentifiedURL.init) }, set: { shareURL = $0?.url })) { wrapped in
            MinisShareSheet(url: wrapped.url, onCompletion: { shareURL = nil })
        }
        .sheet(item: Binding(get: { linkURL.map(IdentifiedURL.init) }, set: { linkURL = $0?.url })) { wrapped in
            MinisSafariView(url: wrapped.url, localFile: false)
        }
        .sheet(isPresented: $showHTML) {
            if let htmlURL {
                NavigationView {
                    CloudDeliverableHTMLView(url: htmlURL, title: item.displayTitle)
                }
            }
        }
        .sheet(item: Binding(get: { exportURL.map(IdentifiedURL.init) }, set: { exportURL = $0?.url })) { wrapped in
            CloudFileExport(url: wrapped.url) { destination in
                if let destination { savedFileName = destination.lastPathComponent }
                exportURL = nil
            }
        }
        .alert("打不开这个文件", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.subtitle.isEmpty ? item.kindLabel : "\(item.kindLabel) · \(item.subtitle)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let sha = item.sha256, item.kind == .ipa {
                    Text("SHA \(sha.prefix(12))…").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.14))
            if let img = remoteThumbnail ?? thumbLocal.flatMap({ UIImage(contentsOfFile: $0.path) }) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 48, height: 48).clipped().cornerRadius(8)
            } else {
                Image(systemName: item.symbolName).font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
            }
        }
        .frame(width: 48, height: 48)
    }

    private var thumbLocal: URL? {
        if case .ready(let u) = dl.state, item.kind == .image { return u }
        return nil
    }

    @ViewBuilder
    private var zipList: some View {
        Button { withAnimation { zipExpanded.toggle() } } label: {
            Label(zipExpanded ? "收起清单" : "展开清单（\(item.entryCount ?? item.entries.count)）",
                  systemImage: zipExpanded ? "chevron.up" : "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("deliverableZipToggle")
        if zipExpanded {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(item.entries, id: \.self) { name in
                    Text(name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.kind == .link {
                Button(action: open) { label("打开", "safari") }
                    .accessibilityIdentifier("deliverableOpen")
            } else {
                HStack(spacing: 8) {
                    Button(action: open) { label("打开", "eye") }
                        .accessibilityIdentifier("deliverableOpen")
                    Button(action: saveToFiles) { label("存到文件", "folder.badge.plus") }
                        .accessibilityIdentifier("deliverableSave")
                }
                HStack(spacing: 8) {
                    Button(action: share) { label("分享", "square.and.arrow.up") }
                        .accessibilityIdentifier("deliverableShare")
                    if item.kind == .office {
                        Button(action: openWithWPS) { label("用 WPS 打开", "arrow.up.forward.app") }
                            .accessibilityIdentifier("deliverableWPS")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
    }

    private func label(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func open() {
        CloudHaptics.tap()
        if item.kind == .link {
            guard let href = item.href, let url = URL(string: href),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
            linkURL = url
            return
        }
        Task { await presentFile(action: .preview) }
    }

    private func saveToFiles() { Task { await presentFile(action: .export) } }
    private func share() { Task { await presentFile(action: .share) } }
    private func openWithWPS() { Task { await presentFile(action: .wps) } }

    private enum Action { case preview, export, share, wps }

    private func presentFile(action: Action) async {
        await dl.start()
        guard case .ready(let url) = dl.state else {
            if case .failed(let msg) = dl.state { errorText = msg }
            return
        }
        if item.kind == .html || (item.name as NSString).pathExtension.lowercased() == "html" {
            if action == .preview {
                htmlURL = url
                showHTML = true
                return
            }
        }
        switch action {
        case .preview:
            previewURL = url
        case .export:
            exportURL = url
        case .share:
            shareURL = url
        case .wps:
            if !CloudDeliverableOpen.openInWPS(url) {
                shareURL = url   // WPS 没装：走系统分享，用户可在分享面板里选
            }
        }
    }
}

private struct DeliveryQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

/// 在 App 内打开 HTML 交付物
struct CloudDeliverableHTMLView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CloudLocalWebView(url: url)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .accessibilityIdentifier("deliverablePreview")
    }
}

struct CloudLocalWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 把文件交到「文件」App（UIDocumentPicker 导出）
struct CloudFileExport: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onDismiss: onDismiss) }
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onDismiss: (URL?) -> Void
        init(onDismiss: @escaping (URL?) -> Void) { self.onDismiss = onDismiss }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onDismiss(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onDismiss(urls.first) }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// 打开链接（App 内浏览器）或尝试调起 WPS。由当前对话页监听。
enum CloudDeliverableOpen {
    /// 常见 WPS / 金山文档 URL scheme；没装就返回 false，由调用方改走分享面板。不带任何第三方商标资源。
    static func openInWPS(_ file: URL) -> Bool {
        let schemes = ["kingsoftoffice", "wpsoffice", "kwps"]
        for scheme in schemes {
            if var c = URLComponents(url: file, resolvingAgainstBaseURL: false) {
                c.scheme = scheme
                if let url = c.url, UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                    return true
                }
            }
        }
        return false
    }
}

private struct LocalDeliverySessionKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var localDeliverySessionId: String {
        get { self[LocalDeliverySessionKey.self] }
        set { self[LocalDeliverySessionKey.self] = newValue }
    }
}
