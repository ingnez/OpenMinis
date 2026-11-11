import SwiftUI
import UIKit

/// 消息里的一组图片（本地对话和 Bot 对话共用）
struct ImageStackSource: Identifiable {
    enum Upload: Equatable { case done, uploading(Double?), failed }
    let id: String
    let load: () async -> UIImage?
    var state: Upload = .done
}

/// 一张 = 一张圆角卡；多张 = 略微旋转错开的一摞 +「◫ N 张图片」。长按铺开，轻点打开全屏看图。
struct ImageCardStack: View {
    let sources: [ImageStackSource]
    var alignment: HorizontalAlignment = .trailing
    let onOpen: (Int) -> Void
    var onRetry: (() -> Void)? = nil
    @State private var fanned = false
    @State private var images: [String: UIImage] = [:]

    var body: some View {
        let count = sources.count
        VStack(alignment: alignment, spacing: ImageStackLayout.captionSpacing) {
            ZStack {
                ForEach(ImageStackLayout.cards(count: count, fanned: fanned), id: \.index) { card in
                    cardView(card, single: count == 1)
                }
            }
            .frame(width: ImageStackLayout.stackSize(count: count).width, height: ImageStackLayout.stackSize(count: count).height)
            if let caption = ImageStackLayout.caption(count) {
                Label(caption, systemImage: "square.stack")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(height: ImageStackLayout.captionHeight)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35) {
            guard count > 1 else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { fanned.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "图片" : "\(count) 张图片")
        .accessibilityValue(count > 1 ? (fanned ? "已展开" : "叠放") : "")
        .accessibilityIdentifier("imageStack")
        .accessibilityHint("轻点全屏查看")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(0) }
    }

    @ViewBuilder
    private func cardView(_ card: ImageStackLayout.Card, single: Bool) -> some View {
        let size = single ? ImageStackLayout.singleSize : ImageStackLayout.cardSize
        let src = sources[card.index]
        ZStack {
            Color(.secondarySystemFill)
            if let img = images[src.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ProgressView()
            }
            ImageUploadBadge(state: src.state, onRetry: onRetry)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: ImageStackLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ImageStackLayout.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(single ? 0 : 0.12), radius: 6, y: 2)
        .rotationEffect(.degrees(card.rotation))
        .offset(card.offset)
        .zIndex(card.zIndex)
        .onTapGesture { onOpen(fanned ? card.index : 0) }
        .task(id: src.id) {
            if images[src.id] == nil, let img = await src.load() { images[src.id] = img }
        }
    }
}

/// 卡片上的上传进度圈 / 失败重试
struct ImageUploadBadge: View {
    let state: ImageStackSource.Upload
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .done:
            EmptyView()
        case .uploading(let p):
            ZStack {
                Circle().fill(.black.opacity(0.35))
                Circle().stroke(.white.opacity(0.3), lineWidth: 3).padding(6)
                if let p {
                    Circle().trim(from: 0, to: max(0.02, p)).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(6)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("正在上传")
        case .failed:
            Button { onRetry?() } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .disabled(onRetry == nil)
        }
    }
}
