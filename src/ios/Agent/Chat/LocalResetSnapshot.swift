//
//  LocalResetSnapshot.swift
//  Minis - 本地 /reset 前先存一份对话快照：完整内容写到 memory/snapshots/，
//  今天的记忆日志里只追加一行指针（标题 + 文件路径），新对话的上下文只多这一行，需要时再读文件。
//  快照按规则整理（目标、最近的对话、待办、关键路径 / 链接），不调用模型，重置不会被网络卡住。
//

import Foundation

enum LocalResetSnapshot {
    struct Turn {
        let role: String   // "user" / "assistant"
        let text: String
    }

    struct Snapshot {
        let title: String
        let markdown: String
        let fileName: String
    }

    static func make(_ turns: [Turn], now: Date = Date()) -> Snapshot? {
        let useful = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let firstUser = useful.first(where: { $0.role == "user" }) else { return nil }
        let title = oneLine(firstUser.text, 24)
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            return f.string(from: now)
        }()
        var md = "# 对话快照：\(title)\n\n"
        md += "## 目标\n\(oneLine(firstUser.text, 400))\n\n"
        if let lastUser = useful.last(where: { $0.role == "user" }), lastUser.text != firstUser.text {
            md += "## 最新要求\n\(oneLine(lastUser.text, 400))\n\n"
        }
        md += "## 最近的对话\n"
        for t in useful.suffix(8) {
            md += "- \(t.role == "user" ? "用户" : "助手")：\(oneLine(t.text, 300))\n"
        }
        let todos = useful.filter { $0.role == "assistant" }.flatMap { $0.text.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in ["待办", "下一步", "TODO", "todo", "- [ ]", "还需要", "未完成"].contains { line.contains($0) } }
        if !todos.isEmpty {
            md += "\n## 待办\n" + todos.suffix(10).map { "- " + oneLine($0, 200) }.joined(separator: "\n") + "\n"
        }
        let facts = keyFacts(useful.map(\.text).joined(separator: "\n"))
        if !facts.isEmpty {
            md += "\n## 关键路径 / 链接\n" + facts.map { "- `\($0)`" }.joined(separator: "\n") + "\n"
        }
        return Snapshot(title: title, markdown: md, fileName: "\(stamp).md")
    }

    /// 写快照文件，并在今天的记忆日志里追加一行指针。返回快照文件路径。
    @discardableResult
    static func save(_ snap: Snapshot, memoryDir: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let dir = memoryDir.appendingPathComponent("snapshots", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(snap.fileName)
            try snap.markdown.write(to: file, atomically: true, encoding: .utf8)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            let daily = memoryDir.appendingPathComponent("\(f.string(from: now)).md")
            let line = "- 已保存对话快照「\(snap.title)」并重置上下文：snapshots/\(snap.fileName)（需要接着做时读这个文件）\n"
            if let h = try? FileHandle(forWritingTo: daily) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try line.write(to: daily, atomically: true, encoding: .utf8)
            }
            return file
        } catch {
            return nil
        }
    }

    static func oneLine(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    static func keyFacts(_ text: String) -> [String] {
        let pattern = #"(https?://[^\s)\]>"'`]+|(?:~|/)[A-Za-z0-9._\-]+(?:/[A-Za-z0-9._\-]+)+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let v = String(text[r])
            if !seen.contains(v) { seen.append(v) }
            if seen.count >= 12 { break }
        }
        return seen
    }
}
