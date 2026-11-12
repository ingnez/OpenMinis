import SwiftUI
import UIKit

extension Color {
    /// 头像色上的图标颜色：亮底用深色、暗底用白色
    var cloudGlyph: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        return CloudTintContrast.prefersDarkGlyph(r: Double(r), g: Double(g), b: Double(b)) ? Color.black.opacity(0.85) : .white
    }
}

/// 输入框最右边的变形圆按钮：声波（实时语音，长按按住说话）↔ 上箭头（发送）↔ 插话 / 排队；底色是 Bot 头像色
struct CloudMorphButton: View {
    let action: CloudBotComposerAction
    let tint: Color
    var inCall = false
    let onTap: () -> Void
    /// 按住说话：true 按下、false 松开
    var onPushToTalk: ((Bool) -> Void)?
    @State private var holding = false
    /// 刚结束一次按住说话的时间：只吞掉紧跟着（0.4 秒内）的那次点按。
    /// 以前是一个永久的 didHold 标记：按住没触发点按时它一直留着，下一次真正的点按就被吞掉——真机「点声波没反应」
    @State private var holdEndedAt: Date?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let enabled = action.enabled(inCall: inCall)
        let fill = enabled ? tint : Color(.systemGray3)
        ZStack {
            Circle().fill(fill)
                .overlay(Circle().stroke(Color.primary.opacity(scheme == .dark ? 0.25 : 0.08), lineWidth: 1))
            if action == .busy {
                ProgressView().tint(fill.cloudGlyph)
            } else {
                Image(systemName: action.symbol)
                    .font(.system(size: action == .call ? 17 : 16, weight: .bold))
                    .foregroundStyle(fill.cloudGlyph)
                    .id(action.morphKey)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 38, height: 38)
        .scaleEffect(holding ? 1.18 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: action.morphKey)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: holding)
        .contentShape(Circle())
        .onTapGesture {
            if CloudMorphTap.swallow(holdEndedAt: holdEndedAt) { holdEndedAt = nil; return }
            holdEndedAt = nil
            if enabled && !holding { onTap() }
        }
        .simultaneousGesture(pushToTalk)
        .accessibilityElement()
        .accessibilityLabel(action.accessibilityLabel())
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { onTap() } }
    }

    private var pushToTalk: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { v in
                guard action.supportsPushToTalk, let onPushToTalk else { return }
                if case .second(true, _) = v, !holding {
                    holding = true
                    onPushToTalk(true)
                }
            }
            .onEnded { _ in
                guard holding else { return }
                holding = false
                holdEndedAt = Date()
                onPushToTalk?(false)
            }
    }
}

/// 单排通话控制条。下方的拖柄可以把它再收紧，聊天始终有自己的布局空间。
struct CloudCallCapsule<Avatar: View>: View {
    @ObservedObject var call: CloudBotCallController
    let name: String
    let avatar: Avatar
    @State private var showSettings = false
    @State private var compacted = false

    private let hangUpRed = Color(red: 0.94, green: 0.27, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            controls
            if let notice = call.notice {
                Text(notice).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    .padding(.horizontal, 15)
                    .accessibilityIdentifier("callCapsuleStatus")
            }
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callStrip")
        .transition(.opacity)
        .sheet(isPresented: $showSettings) { CloudBotCallSettingsSheet(call: call) }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            avatar
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("与 \(name) 的通话，\(headerStatus)")
                .accessibilityIdentifier("callCapsule")
                .accessibilityValue(CloudCallCapsuleText.value(connected: call.connected, receivedKB: call.receivedAudioKB, lines: call.lines.count))
            RealtimeCallSignal(connected: call.connected, micLevel: call.muted || call.isEnding ? 0 : call.micLevel,
                               speakLevel: call.isEnding ? 0 : call.speakLevel, compact: true)
                .frame(height: 19)
                .frame(maxWidth: .infinity)
            control("gearshape", label: "通话设置") { showSettings = true }
                .disabled(call.isEnding)
            control(call.muted ? "mic.slash" : "mic", label: call.muted ? "取消静音" : "静音") {
                call.toggleMute()
            }
            .disabled(!call.connected || call.isEnding)
            control("phone.down", label: "挂断", tint: hangUpRed) { call.hangUp() }
                .disabled(call.isEnding)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: compacted ? 54 : 74)
        .background {
            Capsule().fill(.regularMaterial)
                .overlay { Capsule().fill(.black.opacity(0.32)) }
        }
        .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.75) }
        .overlay(alignment: .bottom) {
            if !compacted {
                Capsule().fill(.white.opacity(0.30)).frame(width: 48, height: 3)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { drag in
                let y = drag.translation.height
                guard abs(y) > 22, abs(y) > abs(drag.translation.width) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { compacted = y < 0 }
            }
        )
    }

    private var headerStatus: String {
        if call.isEnding { return "正在挂断" }
        if !call.connected { return "正在连接" }
        return CloudBotCallText.clock(call.elapsed)
    }

    private func control(_ icon: String, label: String, tint: Color = .white.opacity(0.11),
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .background(tint, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.75) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 挂断后插在对话里的分隔线
struct CloudCallDividerRow: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text(CloudBotCallText.divider(seconds: seconds)).font(.caption).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 通话中的实时字幕：直接显示在对话里（挂断后由服务器 / 本机存成正式消息）
struct CloudCallLiveLines: View {
    let lines: [CloudBotCallLine]
    let tint: Color

    var body: some View {
        ForEach(lines) { line in
            HStack {
                if line.role == "user" { Spacer(minLength: 40) }
                Text(line.text.isEmpty ? "正在转写…" : line.text)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(line.role == "user" ? tint.opacity(0.18) : Color(.secondarySystemBackground)))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "waveform").font(.system(size: 8)).foregroundStyle(tint).offset(x: -4, y: -4)
                    }
                if line.role != "user" { Spacer(minLength: 40) }
            }
        }
    }
}

/// 最后一条消息下面的状态行：头像 + 「正在输入…」「编写代码中」，右边停止键（停止只在这里和任务卡片上）
struct CloudTypingStatusRow<Avatar: View>: View {
    let text: String
    let tint: Color
    let avatar: Avatar
    var onStop: (() -> Void)?
    @State private var phase = false

    var body: some View {
        HStack(spacing: 8) {
            avatar.frame(width: 22, height: 22)
                .scaleEffect(phase && !CloudE2E.pauseIdleAnimations ? 1.08 : 0.94)
                .animation(CloudE2E.pauseIdleAnimations ? .default : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: phase)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(tint)
            Spacer()
            if let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止")
            }
        }
        .onAppear { if !CloudE2E.pauseIdleAnimations { phase = true } }
        .accessibilityElement(children: .combine)
    }
}


enum CloudCallCapsuleText {
    static func value(connected: Bool, receivedKB: Int, lines: Int) -> String {
        connected ? "已接通 · 收到声音 \(receivedKB) KB · 字幕 \(lines) 条" : "未接通"
    }
}
