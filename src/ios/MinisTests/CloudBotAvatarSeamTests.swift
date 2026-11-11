import XCTest
import SwiftUI
@testable import Minis

/// Bot 头像身体里面不能有接缝细线（真机：花、云这类多个圆拼的形状里能看到一条条细弧）。
/// 在 2x / 3x 下渲染只有身体的头像，形状里面离边超过 1.5pt 的每个像素都必须是同一个颜色。
@MainActor
final class CloudBotAvatarSeamTests: XCTestCase {
    private let size: CGFloat = 64

    func testNoInteriorSeamsAtEveryScale() throws {
        for scale in [2.0, 3.0] {
            for scheme in [ColorScheme.light, .dark] {
                for color in [0, 3, 6] where color < CloudBotAvatarSpec.colors.count {
                    for shape in 0..<CloudBotAvatarSpec.shapeCount {
                        try checkShape(shape, color: color, scale: scale, scheme: scheme)
                    }
                }
            }
        }
    }

    private func checkShape(_ shape: Int, color: Int, scale: CGFloat, scheme: ColorScheme) throws {
        let spec = CloudBotAvatarSpec(shape: shape, color: color)
        let view = CloudBotAvatarView(spec: spec, size: size, showsFace: false)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let cg = try XCTUnwrap(renderer.cgImage, "形状 \(shape) 渲染失败")
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn, "读不出像素")
        let path = CloudBotShape(kind: shape).path(in: CGRect(x: 0, y: 0, width: size, height: size))
        let inset: CGFloat = 1.5
        let probes = [CGPoint(x: -inset, y: 0), CGPoint(x: inset, y: 0), CGPoint(x: 0, y: -inset), CGPoint(x: 0, y: inset),
                      CGPoint(x: -inset, y: -inset), CGPoint(x: inset, y: inset), CGPoint(x: -inset, y: inset), CGPoint(x: inset, y: -inset)]
        var reference: [Int]?
        var interior = 0, bad = 0
        var worst = 0
        for y in 0..<h {
            for x in 0..<w {
                // 位图内存第 0 行就是图的最上面一行，和 SwiftUI 坐标同向
                let p = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                guard path.contains(p), probes.allSatisfy({ path.contains(CGPoint(x: p.x + $0.x, y: p.y + $0.y)) }) else { continue }
                interior += 1
                let i = (y * w + x) * 4
                let c = [Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3])]
                guard let ref = reference else { reference = c; continue }
                let d = zip(c, ref).map { abs($0 - $1) }.max() ?? 0
                worst = max(worst, d)
                if d > 3 { bad += 1 }
            }
        }
        XCTAssertGreaterThan(interior, 100, "形状 \(shape) 里面几乎没有像素，检查不了")
        XCTAssertEqual(bad, 0, "形状 \(shape) 颜色 \(color) \(scheme) @\(Int(scale))x：身体里有 \(bad) 个像素颜色不一样（最大差 \(worst)/255），是接缝")
    }
}
