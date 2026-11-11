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

/// 对话页顶部的浮动通话胶囊（像灵动岛）：头像随 Bot 说话跳动、电平条、齿轮、静音、红色挂断。
/// 往上滑缩成小药丸，点一下展开；对话照常显示在下面。
struct CloudCallCapsule<Avatar: View>: View {
    @ObservedObject var call: CloudBotCallController
    let name: String
    let tint: Color
    let avatar: Avatar
    @State private var minimized = false
    @State private var drag: CGFloat = 0
    @State private var showSettings = false

    var body: some View {
        Group {
            if minimized { pill } else { full }
        }
        .offset(y: min(0, drag))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        if v.translation.height < -24 { minimized = true }
                        if v.translation.height > 24 { minimized = false }
                        drag = 0
                    }
                }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .sheet(isPresented: $showSettings) { CloudBotCallSettingsSheet(call: call) }
    }

    private var pulse: CGFloat { 1 + CGFloat(min(1, call.speakLevel)) * 0.22 }

    private var full: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: 34, height: 34)
                .scaleEffect(pulse)
                .shadow(color: tint.opacity(Double(call.speakLevel) * 0.8), radius: 8)
                .animation(.easeOut(duration: 0.12), value: call.speakLevel)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(call.connected ? CloudBotCallText.clock(call.elapsed) : "连接中…")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("callCapsule")
                .accessibilityValue(CloudCallCapsuleText.value(connected: call.connected, receivedKB: call.receivedAudioKB, lines: call.lines.count))
                if let line = CloudCallCapsuleText.line(connected: call.connected, notice: call.notice, status: call.status) {
                    // 没接通、或接通了但某个方向不通时，直接在胶囊里写原因（以前只有计时在走，两边都没声音也看不出来）
                    Text(line).font(.caption2).foregroundStyle(call.notice != nil ? Color.orange : Color.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("callCapsuleStatus")
                } else {
                    CloudLevelMeter(level: max(call.micLevel, call.speakLevel), tint: tint)
                        .frame(height: 6)
                }
            }
            Spacer(minLength: 4)
            capsuleButton("gearshape.fill", label: "通话设置", fill: Color(.tertiarySystemFill), glyph: .primary) { showSettings = true }
            capsuleButton(call.muted ? "mic.slash.fill" : "mic.fill", label: call.muted ? "取消静音" : "静音",
                          fill: call.muted ? Color.primary : Color(.tertiarySystemFill), glyph: call.muted ? Color(.systemBackground) : .primary) {
                call.toggleMute()
            }
            .disabled(!call.connected)
            capsuleButton("phone.down.fill", label: "挂断", fill: .red, glyph: .white) { call.hangUp() }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            if let err = call.error, !call.active {
                Text(err).font(.caption2).foregroundStyle(.red).offset(y: 18)
            }
        }
    }

    private var pill: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { minimized = false }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8).scaleEffect(pulse)
                Text(call.connected ? CloudBotCallText.clock(call.elapsed) : "连接中").font(.caption.monospacedDigit().weight(.semibold))
                Image(systemName: call.notice != nil ? "exclamationmark.triangle.fill" : (call.muted ? "mic.slash.fill" : "waveform"))
                    .font(.caption2).foregroundStyle(call.notice != nil ? Color.orange : tint)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("和 \(name) 通话中，点一下展开")
    }

    private func capsuleButton(_ icon: String, label: String, fill: Color, glyph: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(glyph)
                .frame(width: 34, height: 34).background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 一排小竖条的电平表
struct CloudLevelMeter: View {
    let level: Float
    let tint: Color
    private let bars = 14

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let on = Float(i) / Float(bars) < level
                    Capsule().fill(on ? tint : Color.secondary.opacity(0.25))
                        .frame(width: max(2, (geo.size.width - CGFloat(bars - 1) * 2) / CGFloat(bars)))
                }
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
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


/// 胶囊上的一行字：有问题写问题；没接通写在做什么；正常接通显示音量条（nil）
enum CloudCallCapsuleText {
    static func line(connected: Bool, notice: String?, status: String) -> String? {
        if let notice, !notice.isEmpty { return notice }
        if !connected { return status.isEmpty ? "正在连接实时语音" : status }
        return nil
    }
    static func value(connected: Bool, receivedKB: Int, lines: Int) -> String {
        connected ? "已接通 · 收到声音 \(receivedKB) KB · 字幕 \(lines) 条" : "未接通"
    }
}
