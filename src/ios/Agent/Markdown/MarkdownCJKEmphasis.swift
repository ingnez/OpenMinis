import Foundation

/// cmark 的强调规则对中文不友好：`**结论：**引用` 的结尾 `**` 前面是标点、后面紧跟汉字，
/// 不算「右侧可闭合」，于是星号原样露出来（引用块里同样）。解析前在这类星号和标点之间插一个
/// 零宽空格（不是空白也不是标点），让星号能打开 / 闭合；解析后文字节点里再把零宽空格去掉。
/// 只处理挨着中日韩字符或中文标点的 `*` / `**` / `***`，代码块和行内代码不动。
enum MarkdownCJKEmphasis {
    static let marker: Character = "\u{200B}"

    static func prepare(_ markdown: String) -> String {
        guard markdown.contains("*") else { return markdown }
        var out = ""
        out.reserveCapacity(markdown.count + 8)
        var inFence = false
        var first = true
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out.append("\n") }
            first = false
            let trimmed = line.drop(while: { $0 == " " || $0 == ">" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                out += line
                continue
            }
            if inFence || !line.contains("*") { out += line; continue }
            out += fixLine(Array(line))
        }
        return out
    }

    private static func fixLine(_ chars: [Character]) -> String {
        var out = ""
        var i = 0
        var inCode = false
        var open: [String] = []
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                var j = i
                while j < chars.count && chars[j] == "`" { j += 1 }
                inCode.toggle()
                out += String(chars[i..<j])
                i = j
                continue
            }
            guard c == "*", !inCode else { out.append(c); i += 1; continue }
            var j = i
            while j < chars.count && chars[j] == "*" { j += 1 }
            let run = String(chars[i..<j])
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = j < chars.count ? chars[j] : nil
            var before = false, after = false
            // 同一行里同样长度的星号成对出现：前一个是开头、后一个是结尾
            let closing = open.last == run
            if closing { open.removeLast() } else if j - i <= 3, next.map({ !$0.isWhitespace }) ?? false { open.append(run) }
            if j - i <= 3, let p = prev, let n = next {
                // 结尾：前面标点、后面是字 → 标点和星号之间插零宽空格
                if closing && isPunct(p) && isWord(n) && (isCJK(p) || isCJK(n)) { before = true }
                // 开头：前面是字、后面标点 → 星号和标点之间插零宽空格
                if !closing && isWord(p) && isPunct(n) && (isCJK(p) || isCJK(n)) { after = true }
            }
            if before { out.append(marker) }
            out += run
            if after { out.append(marker) }
            i = j
        }
        return out
    }

    /// 解析后的文字里去掉我们插的零宽空格
    static func clean(_ text: String) -> String {
        text.contains(marker) ? text.replacingOccurrences(of: String(marker), with: "") : text
    }

    private static func isPunct(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return CharacterSet.punctuationCharacters.contains(s) || CharacterSet.symbols.contains(s)
    }

    private static func isWord(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return !isPunct(c) && !CharacterSet.whitespacesAndNewlines.contains(s) && c != "*"
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFFEF).contains(v) || (0x2018...0x201F).contains(v)
            || (0x20000...0x3FFFF).contains(v)
    }
}
