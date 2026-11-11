import SwiftUI
import UIKit

/// 发送前的附件托盘：缩略图卡片，可拖动 / 左右移调整顺序、移除、裁剪标注；上传时每张卡上有进度圈，失败可重试
struct CloudAttachmentTray: View {
    @Binding var attachments: [CloudPendingAttachment]
    let states: [UUID: ImageStackSource.Upload]
    let onRetry: () -> Void
    @AppStorage(ImageSendPolicy.keepOriginalKey) private var keepOriginal = false
    @State private var markup: CloudMarkupTarget?
    @State private var dragging: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ComposerAttachLayout.thumbSpacing) {
                    ForEach(attachments) { a in
                        card(a)
                            .onDrag { dragging = a.id; return NSItemProvider(object: a.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: CloudTrayDrop(target: a.id, dragging: $dragging, items: $attachments))
                    }
                }
                .padding(.horizontal, 4).padding(.top, ComposerAttachLayout.closeOverhang)
            }
            if attachments.contains(where: \.isImage) {
                Toggle(isOn: $keepOriginal) {
                    Text(keepOriginal ? "保留原图（之后选的图不缩小）" : "自动压缩大图（长边 1600）").font(.caption)
                }
                .toggleStyle(.button).buttonStyle(.borderless).font(.caption)
                .accessibilityIdentifier("keepOriginalToggle")
                .padding(.horizontal, 14)
            }
        }
        .sheet(item: $markup) { t in
            ImageMarkupSheet(fileURL: t.url) { url in apply(url, to: t.id) }
                .ignoresSafeArea()
        }
    }

    private func card(_ a: CloudPendingAttachment) -> some View {
        let state = states[a.id] ?? .done
        return ZStack(alignment: .topTrailing) {
            ZStack {
                Color(.systemGray6)
                if let thumb = a.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc").font(.title3)
                        Text(a.filename).font(.system(size: 9)).lineLimit(1).padding(.horizontal, 4)
                    }.foregroundStyle(.secondary)
                }
                ImageUploadBadge(state: state, onRetry: onRetry).scaleEffect(0.8)
            }
            .frame(width: ComposerAttachLayout.thumbSize.width, height: ComposerAttachLayout.thumbSize.height)
            .clipShape(RoundedRectangle(cornerRadius: ComposerAttachLayout.thumbCorner, style: .continuous))
            .opacity(dragging == a.id ? 0.4 : 1)
            Button { attachments.removeAll { $0.id == a.id } } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6)).font(.system(size: 22))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("移除 \(a.filename)")
        }
        .contextMenu {
            if a.isImage {
                Button { openMarkup(a) } label: { Label("裁剪和标注", systemImage: "pencil.tip.crop.circle") }
            }
            if let i = attachments.firstIndex(where: { $0.id == a.id }) {
                if i > 0 { Button { move(i, to: i - 1) } label: { Label("往前移", systemImage: "arrow.left") } }
                if i < attachments.count - 1 { Button { move(i, to: i + 1) } label: { Label("往后移", systemImage: "arrow.right") } }
            }
            Button(role: .destructive) { attachments.removeAll { $0.id == a.id } } label: { Label("移除", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trayCard")
    }

    private func move(_ from: Int, to: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { attachments.swapAt(from, to) }
    }

    private func openMarkup(_ a: CloudPendingAttachment) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(a.id.uuidString).jpg")
        guard (try? a.data.write(to: url, options: .atomic)) != nil else { return }
        markup = CloudMarkupTarget(id: a.id, url: url)
    }

    private func apply(_ url: URL, to id: UUID) {
        guard let i = attachments.firstIndex(where: { $0.id == id }), let data = try? Data(contentsOf: url),
              let img = UIImage(data: data), let fresh = CloudAttachmentKit.image(img, name: attachments[i].filename) else { return }
        attachments[i] = fresh
    }
}

struct CloudMarkupTarget: Identifiable {
    let id: UUID
    let url: URL
}

private struct CloudTrayDrop: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    @Binding var items: [CloudPendingAttachment]

    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let from = items.firstIndex(where: { $0.id == d }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }
}
