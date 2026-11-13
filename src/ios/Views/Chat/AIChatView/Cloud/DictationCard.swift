import SwiftUI

/// 点按与手势都经过同一组录音动作。
enum DictationSwipe {
    enum Action: Equatable { case cancel, send }

    static func action(width: CGFloat, height: CGFloat) -> Action? {
        if width <= -44, -width > abs(height) { return .cancel }
        if height <= -48, -height > abs(width) { return .send }
        return nil
    }
}

struct DictationCard: View {
    let transcript: String
    let partial: Bool
    let levels: [Float]
    let onStop: () -> Void
    let onCancel: () -> Void
    let onSend: () -> Void
    var hasUntranscribedAudio = false

    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var swipe: DictationSwipe.Action? = nil
    private var canSend: Bool { hasUntranscribedAudio || !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Label("向上滑动以发送", systemImage: "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(swipe == .send && canSend ? Color.primary : Color.secondary)
                .padding(.trailing, 16)
                .accessibilityIdentifier("dictationSwipeSendHint")
            card
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .updating($swipe) { event, state, _ in
                    state = DictationSwipe.action(width: event.translation.width, height: event.translation.height)
                }
                .onEnded { event in
                    switch DictationSwipe.action(width: event.translation.width, height: event.translation.height) {
                    case .cancel: onCancel()
                    case .send where canSend: onSend()
                    default: break
                    }
                }
        )
        .accessibilityAction(named: "取消听写") { onCancel() }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 27, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text(transcript.isEmpty ? " " : transcript)
                .font(.body)
                .foregroundStyle(partial ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .lineLimit(1...6)
                .padding(.horizontal, 6)
                .accessibilityIdentifier("dictationTranscript")
            HStack(spacing: 9) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止听写")
                .accessibilityIdentifier("dictationStopButton")
                Label("向左滑动以取消", systemImage: "chevron.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(swipe == .cancel ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("dictationSwipeCancelHint")
                DictationWaveform(levels: levels, tint: Color.primary)
                    .frame(height: 22)
                    .accessibilityElement()
                    .accessibilityLabel("听写波形")
                    .accessibilityValue(DictationLevels.isActive(levels) ? "有声音" : "安静")
                    .accessibilityIdentifier("dictationWaveform")
                Button(action: onSend) {
                    Image(systemName: "arrow.up").font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 36, height: 36)
                        .background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("dictationSendButton")
            }
        }
        .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 9)
        .background { shape.fill(.regularMaterial).overlay { shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04)) } }
        .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictationCard")
    }
}

/// 细竖条滚动波形：数组最后一个是最新的，画在最右边；放不下时只画最近的
struct DictationWaveform: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let bar: CGFloat = 2, gap: CGFloat = 2
            let fit = max(1, Int(size.width / (bar + gap)))
            let recent = Array(levels.suffix(fit))
            let shown = Array(repeating: Float(0), count: max(0, fit - recent.count)) + recent
            var x = size.width - bar
            for level in shown.reversed() {
                let h = max(3, CGFloat(min(1, max(0, level))) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(tint.opacity(0.58)))
                x -= bar + gap
                if x < 0 { break }
            }
        }
    }
}

/// 波形的历史音量：定长、新的追加在后面
struct DictationLevels {
    static let capacity = 90
    private(set) var values: [Float] = []
    mutating func push(_ v: Float) {
        values.append(min(1, max(0, v)))
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }
    mutating func reset() { values = [] }
    /// 最近一段有没有明显的声音
    static func isActive(_ levels: [Float]) -> Bool { levels.suffix(15).contains { $0 > 0.08 } }
    /// 一段 Float PCM 的音量（均方根开方，和实时通话的电平条同一口径）
    static func level(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var i = 0
        let step = max(1, count / 400)
        var n = 0
        while i < count { sum += samples[i] * samples[i]; i += step; n += 1 }
        return min(1, (sum / Float(max(1, n))).squareRoot().squareRoot() * 1.4)
    }
}
