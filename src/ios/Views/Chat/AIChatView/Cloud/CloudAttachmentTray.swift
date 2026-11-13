import SwiftUI
import UIKit

/// 发送前的附件托盘：缩略图卡片，可拖动 / 左右移调整顺序、移除、裁剪标注；上传时每张卡上有进度圈，失败可重试
struct CloudAttachmentTray: View {
    @Binding var attachments: [CloudPendingAttachment]
    let states: [UUID: ImageStackSource.Upload]
    let onRetry: () -> Void
    @State private var markup: CloudMarkupTarget?
    @State private var dragging: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { index, a in
                        CloudAttachmentTrayCard(attachment: a, canMoveEarlier: index > 0,
                                                canMoveLater: index + 1 < attachments.count,
                                                attachments: $attachments, markup: $markup)
                            .equatable()
                            .overlay {
                                if let state = states[a.id], state != .done {
                                    ImageUploadBadge(state: state, onRetry: onRetry).scaleEffect(0.8)
                                }
                            }
                            .opacity(dragging == a.id ? 0.4 : 1)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("trayCard")
                            .onDrag { dragging = a.id; return NSItemProvider(object: a.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: CloudTrayDrop(target: a.id, dragging: $dragging, items: $attachments))
                    }
                }
                .padding(.horizontal, 14).padding(.top, 6)
            }
            if attachments.contains(where: \.isImage) {
                ImageKeepOriginalToggle()
            }
        }
        .sheet(item: $markup) { t in
            ImageMarkupSheet(fileURL: t.url) { url in apply(url, to: t.id) }
                .ignoresSafeArea()
        }
    }

    private func apply(_ url: URL, to id: UUID) {
        guard let i = attachments.firstIndex(where: { $0.id == id }), let data = try? Data(contentsOf: url),
              let img = UIImage(data: data), let fresh = CloudAttachmentKit.image(img, name: attachments[i].filename) else { return }
        attachments[i] = fresh
    }
}

/// Keep a presented system menu stable through unrelated composer redraws.
private struct CloudAttachmentTrayCard: View, Equatable {
    let attachment: CloudPendingAttachment
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    @Binding var attachments: [CloudPendingAttachment]
    @Binding var markup: CloudMarkupTarget?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attachment.id == rhs.attachment.id
            && lhs.canMoveEarlier == rhs.canMoveEarlier
            && lhs.canMoveLater == rhs.canMoveLater
    }

    var body: some View {
        AttachmentTrayTile(name: attachment.filename, isPhoto: attachment.isImage, onRemove: remove) {
            ZStack {
                if let thumb = attachment.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc").font(.title3)
                        Text(attachment.filename).appTextFont(size: 9, relativeTo: .caption).lineLimit(1).padding(.horizontal, 4)
                    }.foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            if attachment.isImage {
                Button(action: openMarkup) { Label("裁剪和标注", systemImage: "pencil.tip.crop.circle") }
            }
            if canMoveEarlier {
                Button { move(by: -1) } label: { Label("往前移", systemImage: "arrow.left") }
            }
            if canMoveLater {
                Button { move(by: 1) } label: { Label("往后移", systemImage: "arrow.right") }
            }
            Button(role: .destructive, action: remove) { Label("移除", systemImage: "trash") }
        }
    }

    private func remove() {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func move(by offset: Int) {
        guard let from = attachments.firstIndex(where: { $0.id == attachment.id }),
              attachments.indices.contains(from + offset) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { attachments.swapAt(from, from + offset) }
    }

    private func openMarkup() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(attachment.id.uuidString).jpg")
        guard (try? attachment.data.write(to: url, options: .atomic)) != nil else { return }
        markup = CloudMarkupTarget(id: attachment.id, url: url)
    }
}

/// Shared photo tray surface for cloud and local composers.
struct AttachmentTrayTile<Content: View>: View {
    let name: String
    var isPhoto = true
    let onRemove: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color(.systemGray6)
                content
            }
            .frame(width: isPhoto ? 140 : 64, height: isPhoto ? 140 : 64)
            .clipShape(RoundedRectangle(cornerRadius: isPhoto ? 18 : 12, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6)).font(.system(size: 18))
            }
            .padding(4)
            .accessibilityLabel("移除 \(name)")
        }
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
