import Foundation

/// 多个圆拼成的头像（四叶草、蓬松云、花）算成一条外轮廓：只填一次、不描每个圆的边，里面就不会有接缝细线。
/// 纯几何（单位方框 0...1），不依赖 UI，Linux 上单测。
enum CloudShapeOutline {
    struct Disc: Equatable {
        var x: Double, y: Double, r: Double
    }

    static let clover: [Disc] = [Disc(x: 0.32, y: 0.36, r: 0.24), Disc(x: 0.68, y: 0.36, r: 0.24),
                                 Disc(x: 0.36, y: 0.66, r: 0.24), Disc(x: 0.66, y: 0.66, r: 0.24),
                                 Disc(x: 0.5, y: 0.5, r: 0.2)]
    static let cloud: [Disc] = [Disc(x: 0.5, y: 0.3, r: 0.22), Disc(x: 0.28, y: 0.45, r: 0.22),
                                Disc(x: 0.72, y: 0.45, r: 0.22), Disc(x: 0.38, y: 0.7, r: 0.22),
                                Disc(x: 0.64, y: 0.7, r: 0.22), Disc(x: 0.5, y: 0.5, r: 0.22)]
    static let flower: [Disc] = [Disc(x: 0.5, y: 0.5, r: 0.26)] + (0..<6).map { i in
        let a = Double(i) * .pi / 3
        return Disc(x: 0.5 + 0.24 * cos(a), y: 0.5 + 0.24 * sin(a), r: 0.17)
    }

    /// 圆的并集外轮廓：从中心向每个角度打一条射线，取它离开各个圆时最远的那一点。
    /// 这些形状都包含中心、且对中心是星形，所以这一点就是并集的边界。点按角度顺序排列，首尾不重复。
    static func union(_ discs: [Disc], cx: Double = 0.5, cy: Double = 0.5, samples: Int = 720) -> [(x: Double, y: Double)] {
        (0..<samples).compactMap { i in
            let a = Double(i) / Double(samples) * 2 * .pi
            let dx = cos(a), dy = sin(a)
            guard let t = exit(discs, cx: cx, cy: cy, dx: dx, dy: dy) else { return nil }
            return (cx + t * dx, cy + t * dy)
        }
    }

    /// 射线 (cx,cy)+t(dx,dy) 离开各个圆的最远 t（单位方向）
    static func exit(_ discs: [Disc], cx: Double, cy: Double, dx: Double, dy: Double) -> Double? {
        var best: Double?
        for d in discs {
            let ox = cx - d.x, oy = cy - d.y
            let b = dx * ox + dy * oy
            let c = ox * ox + oy * oy - d.r * d.r
            let disc = b * b - c
            guard disc >= 0 else { continue }
            let t = -b + disc.squareRoot()
            if t > 0, t > (best ?? -1) { best = t }
        }
        return best
    }

    /// 点在不在并集里（单测用）
    static func contains(_ discs: [Disc], x: Double, y: Double, slack: Double = 0) -> Bool {
        discs.contains { d in
            let dx = x - d.x, dy = y - d.y
            return (dx * dx + dy * dy).squareRoot() <= d.r + slack
        }
    }
}
