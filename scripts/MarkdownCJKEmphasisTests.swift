import Foundation

// 中文加粗星号修复的回归：在 cmark 判不成强调的位置插零宽空格，其它地方一个字都不改
@main
struct MarkdownCJKEmphasisTests {
    static func main() {
        let z = "\u{200B}"
        var failed = 0
        func expect(_ input: String, _ want: String, _ name: String) {
            let got = MarkdownCJKEmphasis.prepare(input)
            if got == want { print("PASS \(name)") } else { failed += 1; print("FAIL \(name): \(got.debugDescription) != \(want.debugDescription)") }
        }
        expect("> 这是**结论：**引用里有中文", "> 这是**结论：\(z)**引用里有中文", "引用里结尾星号前是中文标点")
        expect("中**「重点」**中文", "中**\(z)「重点」\(z)**中文", "开头星号后是中文引号")
        expect("> 这是**加粗的中文**引用，里面有 **重点**。", "> 这是**加粗的中文**引用，里面有 **重点**。", "本来就能解析的不动")
        expect("**English (note)**text", "**English (note)**text", "纯英文不动")
        expect("`中**「x」**中`", "`中**「x」**中`", "行内代码不动")
        expect("```\n中**「x」**中\n```", "```\n中**「x」**中\n```", "代码块不动")
        expect("* 列表项\n***", "* 列表项\n***", "列表符号和分隔线不动")
        expect("> - 第一，**注意：**别忘了", "> - 第一，**注意：\(z)**别忘了", "引用里的列表")
        if MarkdownCJKEmphasis.clean("结论：\(z)") != "结论：" { failed += 1; print("FAIL clean") } else { print("PASS clean") }
        if failed > 0 { print("\(failed) 个失败"); exit(1) }
        print("全部通过")
    }
}
