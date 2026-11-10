import SwiftUI

/// 应用内悬浮小窗：离开「电脑」页后继续看 Bot 用云电脑（App 内的浮窗，不是系统画中画——系统画中画要视频流，noVNC 画面不是）。
/// 可拖到四个角，点一下回到这个 Bot 的对话，× 关闭。
@MainActor
final class CloudMiniDesktop: ObservableObject {
    static let shared = CloudMiniDesktop()
    @Published private(set) var botId: String?
    @Published var corner: Int = 3   // 0 左上 1 右上 2 左下 3 右下

    func show(botId: String) { self.botId = botId }
    func hide() { botId = nil }

    /// 拖动结束时落到最近的角
    nonisolated static func corner(for p: CGPoint, in size: CGSize) -> Int {
        (p.x < size.width / 2 ? 0 : 1) + (p.y < size.height / 2 ? 0 : 2)
    }
}

struct CloudMiniDesktopOverlay: View {
    @ObservedObject private var mini = CloudMiniDesktop.shared
    @State private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let id = mini.botId {
                let w: CGFloat = 180
                let left = mini.corner % 2 == 0, top = mini.corner < 2
                ZStack(alignment: .topTrailing) {
                    CloudDesktopPreview(botId: id) { CloudBotEntry.open(bot: id, text: nil, send: false) }
                        .frame(width: w)
                        .allowsHitTesting(true)
                    Button { mini.hide() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 20)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .padding(4)
                    .accessibilityLabel("关闭小窗")
                }
                .shadow(radius: 8)
                .position(x: left ? w / 2 + 12 : geo.size.width - w / 2 - 12,
                          y: top ? 60 + w * 0.32 : geo.size.height - 110 - w * 0.32)
                .offset(drag)
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { v in
                        mini.corner = CloudMiniDesktop.corner(for: v.location, in: geo.size)
                        drag = .zero
                    })
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mini.corner)
            }
        }
    }
}
