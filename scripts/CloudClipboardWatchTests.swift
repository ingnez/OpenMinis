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
        // 手机自己送过去的中文（输入法走剪贴板粘贴）不回声
        var o = CloudClipboardWatch()
        _ = o.observe("那边原有的")
        o.expect("手机输入的中文")
        check("手机输入的中文改了远端剪贴板，不当成远端复制", o.observe("手机输入的中文") == nil)
        check("远端真的复制了新的照样拷", o.observe("远端复制的中文✓") == "远端复制的中文✓")
        for i in 0..<40 { o.expect("第\(i)段") }
        check("只记最近 16 段", o.own.count == CloudClipboardWatch.ownLimit && o.isOwn("第39段") && !o.isOwn("第0段"))
        // noVNC 剪贴板事件是 Latin-1：中文以服务器 UTF-8 为准
        check("服务器读到的 UTF-8 优先", CloudClipboardWatch.pick(server: "中文✓", rfb: "ä¸\u{AD}æ") == "中文✓")
        check("服务器读不到时 ASCII 事件可信", CloudClipboardWatch.pick(server: nil, rfb: "abc 123") == "abc 123")
        check("服务器读不到时非 ASCII 事件不可信（可能是乱码）", CloudClipboardWatch.pick(server: nil, rfb: "ä¸\u{AD}") == nil)
        check("服务器空、事件空", CloudClipboardWatch.pick(server: "", rfb: "") == nil)
        if failed > 0 { exit(1) }
        print("全部通过")
    }
}
