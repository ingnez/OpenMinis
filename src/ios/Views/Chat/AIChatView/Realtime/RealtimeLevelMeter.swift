import Foundation

/// 通话里的音量：从 16 位 PCM 算出 0…1 的响度（给胶囊里的电平条、头像随说话跳动用）。
/// 用 RMS 再开方压一下，安静时接近 0、正常说话约 0.3～0.7；带平滑，避免条子乱跳。
struct RealtimeLevelMeter {
    private(set) var value: Float = 0
    /// 上升快、下降慢
    var attack: Float = 0.6
    var release: Float = 0.15

    static func level(pcm16 data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        data.withUnsafeBytes { raw in
            let step = max(1, count / 600)          // 最多采 600 个点，够用且省电
            var n = 0
            var i = 0
            while i < count {
                let bits = UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8
                let s = Double(Int16(bitPattern: bits)) / 32768
                sum += s * s
                n += 1
                i += step
            }
            sum /= Double(max(1, n))
        }
        return Float(min(1, sqrt(sqrt(sum)) * 1.4))
    }

    /// 喂一段新音频，返回平滑后的值
    mutating func feed(_ target: Float) -> Float {
        let k = target > value ? attack : release
        value += (target - value) * k
        if value < 0.005 { value = 0 }
        return value
    }

    mutating func decay() -> Float { feed(0) }
}
