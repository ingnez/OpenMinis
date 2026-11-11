import SwiftUI

/// 听写时输入栏展开成的圆角卡片（本地和 Bot 模式共用，样子照 Grok）：
/// 上面一行是边说边出的文字（识别中是占位灰）；下面一行左边圆形停止键（黑底白方块）、中间滚动波形（新的在右边）、右边强调色发送箭头。
/// 停止 = 结束听写、文字留在输入框里可以改；发送 = 马上发。这个停止键只在听写时出现。
struct DictationCard: View {
    let transcript: String
    /// 还在识别（文字是临时的，显示占位灰）
    let partial: Bool
    let levels: [Float]
    let accent: Color
    var placeholder = "正在听…"
    let onStop: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(transcript.isEmpty ? placeholder : transcript)
                .font(.body)
                .foregroundStyle(transcript.isEmpty || partial ? Color(uiColor: .placeholderText) : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1...6)
                .accessibilityIdentifier("dictationTranscript")
            HStack(spacing: 12) {
                Button(action: onStop) {
                    ZStack {
                        Circle().fill(Color(.label))
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.systemBackground))
                            .frame(width: 12, height: 12)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止听写")
                .accessibilityIdentifier("dictationStopButton")
                DictationWaveform(levels: levels, tint: Color(.label))
                    .frame(height: 28)
                    .accessibilityElement()
                    .accessibilityLabel("听写波形")
                    .accessibilityValue(DictationLevels.isActive(levels) ? "有声音" : "安静")
                    .accessibilityIdentifier("dictationWaveform")
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("dictationSendButton")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.systemGray6)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
    }
}

/// 细竖条滚动波形：数组最后一个是最新的，画在最右边；放不下时只画最近的
struct DictationWaveform: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let bar: CGFloat = 2.5, gap: CGFloat = 2.5
            let fit = max(1, Int(size.width / (bar + gap)))
            let shown = Array(levels.suffix(fit))
            var x = size.width - bar
            for level in shown.reversed() {
                let h = max(3, CGFloat(min(1, max(0, level))) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(tint.opacity(0.85)))
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
