import Foundation

/// 头像心情：排队 / 工作时专注、等你审批时好奇、有新回复时开心、上次任务出错皱眉、闲太久打瞌睡
enum CloudBotMood: Equatable {
    /// shy：长按大头像时害羞（闭眼、脸红、扭头）
    case calm, focused, curious, happy, frown, dozing, shy

    /// 多久没动静算「闲太久」
    static let dozeAfter: Double = 2 * 86400

    /// 空闲时的心情：新回复优先（开心），其次是出错（皱眉），再次是闲太久（打瞌睡）
    static func idle(unread: Bool, failed: Bool, idleSeconds: Double) -> CloudBotMood {
        if unread { return .happy }
        if failed { return .frown }
        if idleSeconds >= dozeAfter { return .dozing }
        return .calm
    }

    /// 3D 倾斜角度（度）：跟着手指转头；害羞时扭向另一边并低头
    static func tilt(gaze: (x: Double, y: Double), shy: Bool) -> (yaw: Double, pitch: Double) {
        let gx = max(-1, min(1, gaze.x)), gy = max(-1, min(1, gaze.y))
        if shy { return (yaw: gx >= 0 ? -32 : 32, pitch: 14) }
        return (yaw: 20 * gx, pitch: -14 * gy)
    }
}
