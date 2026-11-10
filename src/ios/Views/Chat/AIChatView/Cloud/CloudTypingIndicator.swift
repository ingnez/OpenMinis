import SwiftUI

/// 头像位置上的「正在输入」：Bot 颜色的三个点依次跳动；减弱动态效果时是静止的三个深浅不同的点
struct CloudTypingDots: View {
    let color: Color
    var size: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: size * 0.08) {
                    ForEach(0..<3, id: \.self) { i in
                        let level = reduceMotion ? [1.0, 0.7, 0.45][i] : CloudTypingRules.dotLevel(index: i, time: t)
                        Circle().fill(color)
                            .frame(width: size * 0.16, height: size * 0.16)
                            .opacity(level)
                            .scaleEffect(reduceMotion ? 1 : 0.8 + 0.3 * level)
                            .offset(y: reduceMotion ? 0 : -size * 0.07 * (level - 0.35) / 0.65)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 顶部大头像外的一圈：正在干活时 Bot 颜色的光环慢慢转；减弱动态效果时静止
struct CloudWorkingRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let angle = reduceMotion ? 0 : (ctx.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360)
            Circle()
                .strokeBorder(AngularGradient(colors: [color, color.opacity(0.15), color], center: .center), lineWidth: 3)
                .rotationEffect(.degrees(angle))
        }
        .accessibilityHidden(true)
    }
}

/// 头像 ↔ 三个点之间的切换：缩放 + 淡入淡出；减弱动态效果时只淡入淡出
extension AnyTransition {
    static func cloudTypingMorph(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }
}
