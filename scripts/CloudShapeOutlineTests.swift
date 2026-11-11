// 和 CloudShapeOutline.swift 一起编译：swiftc -parse-as-library CloudShapeOutline.swift CloudShapeOutlineTests.swift
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("✗ \(msg)") } }

@main struct CloudShapeOutlineTests {
    static func main() {

        for (name, discs) in [("四叶草", CloudShapeOutline.clover), ("蓬松云", CloudShapeOutline.cloud), ("花", CloudShapeOutline.flower)] {
            let pts = CloudShapeOutline.union(discs)
            check(pts.count == 720, "\(name)：每个角度都应该有轮廓点，只有 \(pts.count)")
            for p in pts {
                // 轮廓点在并集边上：在某个圆上，外面一点点就不在任何圆里
                check(CloudShapeOutline.contains(discs, x: p.x, y: p.y, slack: 1e-9), "\(name)：轮廓点 \(p) 不在形状里")
                let dx = p.x - 0.5, dy = p.y - 0.5, len = (dx * dx + dy * dy).squareRoot()
                check(!CloudShapeOutline.contains(discs, x: p.x + dx / len * 1e-4, y: p.y + dy / len * 1e-4), "\(name)：轮廓点 \(p) 外面还是形状（不是外边界）")
                // 中心到轮廓点整段都在形状里（星形：没有被漏掉的缺口）
                for k in 1..<40 {
                    let f = Double(k) / 40
                    check(CloudShapeOutline.contains(discs, x: 0.5 + dx * f, y: 0.5 + dy * f, slack: 1e-9), "\(name)：中心到 \(p) 的线段有一段不在形状里")
                }
                check(p.x >= -0.01 && p.x <= 1.01 && p.y >= -0.01 && p.y <= 1.01, "\(name)：轮廓点 \(p) 出了单位方框")
            }
            // 相邻两点距离很小：放大到 3 倍 150pt（450px）也看不出折线
            var maxGap = 0.0
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                maxGap = max(maxGap, ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot())
            }
            check(maxGap * 450 < 3, "\(name)：轮廓相邻点最大间距 \(maxGap * 450) px（450px 下）太大")
        }
        if failures == 0 { print("CloudShapeOutline 单测通过") } else { print("\(failures) 处失败"); exit(1) }
    }
}
