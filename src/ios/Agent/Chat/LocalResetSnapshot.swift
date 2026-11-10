//
//  LocalResetSnapshot.swift
//  Minis - 本地 /reset 前先存一份对话快照：完整内容写到 memory/snapshots/，
//  今天的记忆日志里只追加一行指针（标题 + 文件路径），新对话的上下文只多这一行，需要时再读文件。
//  快照先按规则整理（目标、最近的对话、待办、关键路径 / 链接），不等模型，重置不会被网络卡住；
//  随后在后台用副模型写一段「模型总结」补进同一个文件（失败就保留规则版）。新对话顶部出现可点开的快照提示。
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

    // MARK: 模型总结（后台补写）

    static let summaryHeading = "## 模型总结"

    /// 给副模型的提示：只要事实，不编造；中文、要点式
    static func summaryPrompt(_ turns: [Turn]) -> String {
        let body = turns.suffix(30).map { "\($0.role == "user" ? "用户" : "助手")：\(oneLine($0.text, 600))" }.joined(separator: "\n")
        return """
        下面是一段即将被重置的对话。请用中文写 5～10 条要点的交接总结，供之后接着做：目标、已经做完的、关键结论和数据、还没做完的下一步、重要的文件路径或链接。
        只写对话里出现过的事实，不要编造；不要寒暄；直接输出要点列表。

        对话：
        \(body)
        """
    }

    /// 把模型总结放到标题下面（已有就替换），规则整理的部分原样保留
    static func merge(markdown: String, summary: String) -> String {
        let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        if let start = lines.firstIndex(of: summaryHeading) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            lines.removeSubrange(start..<end)
        }
        let insertAt = min(lines.count, (lines.firstIndex { $0.hasPrefix("# ") } ?? -1) + 2)
        lines.insert(contentsOf: [summaryHeading, clean, ""], at: insertAt)
        return lines.joined(separator: "\n")
    }

    // MARK: 新对话里的提示

    struct Recent: Equatable {
        let title: String
        let path: String
        let at: Date
    }

    static let recentKey = "OpenMinisLocalResetSnapshotRecent"

    static func remember(title: String, file: URL, now: Date = Date(), _ d: UserDefaults = .standard) {
        d.set(["title": title, "path": file.path, "at": now.timeIntervalSince1970], forKey: recentKey)
    }

    /// 10 分钟内重置过、文件还在：新对话顶部显示「已保存快照」
    static func recent(now: Date = Date(), window: TimeInterval = 600, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                       _ d: UserDefaults = .standard) -> Recent? {
        guard let v = d.dictionary(forKey: recentKey), let title = v["title"] as? String, let path = v["path"] as? String,
              let at = v["at"] as? Double else { return nil }
        let date = Date(timeIntervalSince1970: at)
        guard now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < window, fileExists(path) else { return nil }
        return Recent(title: title, path: path, at: date)
    }

    static func dismissRecent(_ d: UserDefaults = .standard) { d.removeObject(forKey: recentKey) }

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
