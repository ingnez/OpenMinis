import Foundation

@main
struct CloudClipboardWatchTests {
    static func main() {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { if ok { print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
        var w = CloudClipboardWatch()
        check("第一次只记基线不拷", w.observe("那边原有的") == nil)
        check("没变不拷", w.observe("那边原有的") == nil)
        check("云电脑里复制了新文字 → 拷到手机", w.observe("云电脑里复制的中文") == "云电脑里复制的中文")
        check("同一段不重复拷", w.observe("云电脑里复制的中文") == nil)
        check("清空不拷", w.observe("") == nil)
        w.noteKnown("手机推过去的")
        check("手机推过去的不回声", w.observe("手机推过去的") == nil)
        check("之后再复制照样拷", w.observe("再复制一段") == "再复制一段")
        if failed > 0 { exit(1) }
        print("全部通过")
    }
}
