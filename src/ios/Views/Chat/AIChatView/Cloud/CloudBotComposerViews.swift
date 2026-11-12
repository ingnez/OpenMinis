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

/// 浮动通话面板：上滑收起，点小胶囊或下拉恢复。
struct CloudCallCapsule<Avatar: View>: View {
    @ObservedObject var call: CloudBotCallController
    let name: String
    let tint: Color
    let avatar: Avatar
    @State private var minimized = false
    @State private var drag: CGFloat = 0
    @State private var showSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelColor = Color(white: 0.10)
    private let controlFill = Color.white.opacity(0.13)

    var body: some View {
        Group {
            if minimized { pill } else { full }
        }
        .offset(y: drag / (1 + abs(drag) / 54))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    withAnimation(panelAnimation) {
                        if v.translation.height < -24 { minimized = true }
                        if v.translation.height > 24 { minimized = false }
                        drag = 0
                    }
                }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .sheet(isPresented: $showSettings) { CloudBotCallSettingsSheet(call: call) }
    }

    private var panelAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82)
    }

    private var headerStatus: String {
        if call.isEnding { return "正在挂断" }
        if !call.connected { return "正在连接" }
        return call.muted ? "麦克风已静音" : "已接通"
    }

    private var full: some View {
        VStack(spacing: 9) {
            Capsule().fill(.white.opacity(0.24)).frame(width: 30, height: 3)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                avatar
                    .frame(width: 36, height: 36)
                    .shadow(color: tint.opacity(Double(call.speakLevel) * 0.55), radius: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(headerStatus).font(.caption).foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 4)
                if call.connected {
                    Text(CloudBotCallText.clock(call.elapsed))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("callCapsule")
            .accessibilityValue(CloudCallCapsuleText.value(connected: call.connected, receivedKB: call.receivedAudioKB, lines: call.lines.count))
            RealtimeCallSignal(connected: call.connected, micLevel: call.muted || call.isEnding ? 0 : call.micLevel,
                               speakLevel: call.isEnding ? 0 : call.speakLevel)
                .frame(height: 37)
            if let line = CloudCallCapsuleText.line(connected: call.connected, notice: call.notice, status: call.status) {
                Text(line).font(.caption2)
                    .foregroundStyle(call.notice == nil ? Color.white.opacity(0.68) : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("callCapsuleStatus")
            }
            HStack(spacing: 13) {
                capsuleButton("gearshape", label: "通话设置", fill: controlFill) { showSettings = true }
                    .disabled(call.isEnding)
                capsuleButton(call.muted ? "mic.slash.fill" : "mic.fill", label: call.muted ? "取消静音" : "静音",
                              fill: call.muted ? .white : controlFill, glyph: call.muted ? .black : .white) {
                    call.toggleMute()
                }
                .disabled(!call.connected || call.isEnding)
                Spacer(minLength: 4)
                capsuleButton("chevron.up", label: "收起通话", fill: controlFill) {
                    withAnimation(panelAnimation) { minimized = true }
                }
                capsuleButton("phone.down.fill", label: "挂断", fill: .red) { call.hangUp() }
                    .disabled(call.isEnding)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15).padding(.vertical, 11)
        .background(panelColor, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
        .padding(.horizontal, 12)
    }

    private var pill: some View {
        Button {
            withAnimation(panelAnimation) { minimized = false }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: call.notice == nil ? (call.muted ? "mic.slash.fill" : "waveform") : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(call.notice == nil ? Color.white : Color.orange)
                Text(call.connected && !call.isEnding ? CloudBotCallText.clock(call.elapsed) : headerStatus)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(panelColor, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开与 \(name) 的通话")
        .accessibilityIdentifier("callCapsuleCollapsed")
    }

    private func capsuleButton(_ icon: String, label: String, fill: Color, glyph: Color = .white,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(glyph)
                .frame(width: 44, height: 44).background(Circle().fill(fill))
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
