import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

struct Boom: Error {}
final class Counter: @unchecked Sendable { var n = 0 }

@main
struct CloudBotEditPatchTests {
    static func main() async {
        let old = CloudBotEditFields(name: "总管", emoji: "av:s0c0", summary: "分派", instructions: "很长的指令" + String(repeating: "x", count: 5000), fastMode: false)
        var renamed = old
        renamed.name = "大总管"
        let p = renamed.patch(from: old)
        check(p.keys.sorted() == ["name"], "只改名字时只发 name：\(p.keys.sorted())")
        check(p["name"] as? String == "大总管", "新名字")
        check(old.patch(from: old).isEmpty, "没改就不发")
        var many = old
        many.emoji = ""; many.summary = "新简介"; many.fastMode = true
        let q = many.patch(from: old)
        check(q.keys.sorted() == ["description", "emoji", "fast_mode"], "字段名对应服务器：\(q.keys.sorted())")
        check(q["emoji"] is NSNull, "清空头像发 null")

        // 超时：慢请求 0.3 秒内放弃
        let t0 = Date()
        do {
            _ = try await CloudRetry.withTimeout(0.3) { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
            check(false, "应该超时")
        } catch {
            check(error is CloudTimeoutError && Date().timeIntervalSince(t0) < 1.5, "限时生效")
        }
        // 重试：前两次失败第三次成功
        let c = Counter()
        let v = try? await CloudRetry.run(attempts: 3, timeout: 1, backoff: [0.01]) { () async throws -> Int in
            c.n += 1
            if c.n < 3 { throw Boom() }
            return 7
        }
        check(v == 7 && c.n == 3, "失败后重试")
        // 全部失败：抛出，次数不超过上限
        let d = Counter()
        do {
            _ = try await CloudRetry.run(attempts: 2, timeout: 1, backoff: [0.01]) { () async throws -> Int in d.n += 1; throw Boom() }
            check(false, "应该失败")
        } catch { check(error is Boom && d.n == 2, "重试有上限") }
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("编辑 Bot 保存测试全部通过")
    }
}
