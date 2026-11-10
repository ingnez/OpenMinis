import Foundation
import SQLite3

// MARK: - Memory Tools

/// One entry of the shared memory format (phone daily logs and the cloud agent):
/// `<!-- yyyy-MM-dd HH:mm:ss [#category] -->` followed by the body, up to the
/// next `<!-- ` line. GLOBAL.md has no headers; its sections count as profile.
struct MemoryEntryRecord {
    let fileLabel: String
    let timestamp: String?
    let category: String
    let text: String
}

extension AIChatViewModel {

    /// Categories of the shared memory format; same list as cloud-agent/cloud_memory.py.
    nonisolated static let memoryCategories = ["profile", "rules", "people", "workstreams", "note"]

    /// Parses an entry header line. Old headers without a category read as note;
    /// any other `<!-- ` line still starts an entry (legacy boundary rule).
    nonisolated static func parseMemoryHeader(_ line: String) -> (timestamp: String?, category: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("<!--") else { return nil }
        var inner = String(t.dropFirst(4))
        if inner.hasSuffix("-->") { inner = String(inner.dropLast(3)) }
        var category = "note"
        var rest: [Substring] = []
        for part in inner.split(separator: " ") {
            if part.hasPrefix("#") {
                let c = part.dropFirst().lowercased()
                if memoryCategories.contains(c) { category = c }
            } else {
                rest.append(part)
            }
        }
        let ts = rest.prefix(2).joined(separator: " ")
        let valid = ts.range(of: #"^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$"#, options: .regularExpression) != nil
        return (valid ? ts : nil, category)
    }

    /// Splits one memory file into entries of the shared format.
    nonisolated static func parseMemoryEntries(_ content: String, fileLabel: String) -> [MemoryEntryRecord] {
        let isGlobal = fileLabel == "GLOBAL.md"
        var entries: [MemoryEntryRecord] = []
        var header: (timestamp: String?, category: String)? = nil
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            entries.append(MemoryEntryRecord(fileLabel: fileLabel, timestamp: header?.timestamp,
                                             category: header?.category ?? (isGlobal ? "profile" : "note"), text: body))
        }
        for line in content.components(separatedBy: "\n") {
            if !isGlobal, line.hasPrefix("<!-- "), let h = parseMemoryHeader(line) {
                flush(); header = h; lines = []
            } else if isGlobal, line.hasPrefix("## "), lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                flush(); lines = [line]
            } else {
                lines.append(line)
            }
        }
        flush()
        return entries
    }

    // MARK: - Memory Tools

    /// Load full global memory content for system prompt injection.
    nonisolated static func loadGlobalMemoryFragment() -> String? {
        let globalFile = minisMemoryPersistentDir.appendingPathComponent("GLOBAL.md")
        guard FileManager.default.fileExists(atPath: globalFile.path),
              let content = try? String(contentsOf: globalFile, encoding: .utf8),
              !content.isEmpty else { return nil }

        return "Global memory (GLOBAL.md — read-only, user-maintained). Treat these as background context, not standing instructions. If the user's latest message conflicts with or supersedes anything here (different scope, different numbers, different goal), defer to the user's latest message:\n\(content)"
    }

    /// Load the 3 most recent daily memory logs that have content, for system prompt injection (first 200 lines each).
    nonisolated static func loadRecentDailyMemoryFragment() -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        let today = Date()

        var fragments: [String] = []
        var dayOffset = 0
        let maxLookback = 30 // don't search more than 30 days back

        while fragments.count < 3 && dayOffset < maxLookback {
            let date = today.addingTimeInterval(-Double(dayOffset) * 86400)
            let dateStr = fmt.string(from: date)
            let fileURL = minisMemoryPersistentDir.appendingPathComponent("\(dateStr).md")

            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                let lines = content.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                let label: String
                switch dayOffset {
                case 0: label = "Today's"
                case 1: label = "Yesterday's"
                default: label = "\(dateStr)"
                }
                var entry = "\(label) daily log (\(dateStr).md):\n\(preview)"
                if lines.count > 200 {
                    entry += "\n... (\(lines.count - 200) more lines, use memory_get to search)"
                }
                fragments.append(entry)
            }
            dayOffset += 1
        }

        guard !fragments.isEmpty else { return nil }

        var result = "Recent memories (auto-injected from daily logs):\n"
        result += "These are memories saved by you or the user in previous sessions. Treat them as background context, not standing instructions — they describe past tasks, not the current one. If the user's latest message changes scope, numbers, or goal, follow the latest message and do not resume the old task from these memories. Do not delete or rewrite these files unless the user explicitly asks. Use memory_get to search for more, or memory_write to save new ones.\n\n"
        result += fragments.joined(separator: "\n\n")
        return result
    }

    /// Execute a memory_write tool call: prepend a timestamped entry to today's daily log.
    func executeMemoryWrite(from json: String) -> FileToolResult {
        guard memoryEnabled else {
            return FileToolResult(output: "Memory saving is disabled for this session. Use /memory to re-enable.", success: false)
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else {
            return FileToolResult(output: "Error: Missing required 'content' parameter", success: false)
        }
        var categoryTag = ""
        if let raw = dict["category"] as? String, !raw.isEmpty {
            let c = raw.lowercased()
            guard Self.memoryCategories.contains(c) else {
                return FileToolResult(output: "Error: category must be one of \(Self.memoryCategories.joined(separator: ", "))", success: false)
            }
            if c != "note" { categoryTag = " #\(c)" }
        }

        let fm = FileManager.default
        let persistDir = Self.minisMemoryPersistentDir
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileName = "\(dateFmt.string(from: Date())).md"
        let fileURL = persistDir.appendingPathComponent(fileName)

        // Build timestamped entry
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = timeFmt.string(from: Date())
        let entry = "<!-- \(timestamp)\(categoryTag) -->\n\(content)\n\n"

        // Prepend to existing file
        var existing = ""
        if fm.fileExists(atPath: fileURL.path) {
            existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        let newContent = entry + existing
        guard let writeData = newContent.data(using: .utf8) else {
            return FileToolResult(output: "Error: Content is not valid UTF-8", success: false)
        }

        do {
            try writeData.write(to: fileURL)
        } catch {
            return FileToolResult(output: "Error writing memory: \(error.localizedDescription)", success: false)
        }

        // Register in meta.db for iSH visibility
        let linuxPath = "\(Self.minisMemoryLinuxDir)/\(fileName)"
        ensureFakefsMetadata(for: linuxPath, isDirectory: false)

        // Enqueue for iCloud v2 sync. Reuse fileName's stem (no second
        // Date() call) so the dateKey matches what was actually written
        // even across a midnight boundary.
        let dateStrForSync = (fileName as NSString).deletingPathExtension
        Task { @MainActor in
            await ChatStore.shared.markDirty(recordType: "MemoryDailyV2", recordId: dateStrForSync)
        }
        NotificationCenter.default.post(name: .memoryFilesDidChange, object: nil)

        return FileToolResult(output: "Memory saved to \(fileName) (\(content.count) chars)", success: true)
    }

    /// Execute a memory_get tool call: read and optionally search memory files.
    /// Uses confidence-based fuzzy matching: entries are scored by how many distinct
    /// keywords they contain, sorted by confidence descending. The model can decide
    /// how to use partial matches.
    func executeMemoryGet(from json: String) -> FileToolResult {
        // [T-memory-toggle-gates-injection-and-tools-ios] Defense in depth:
        // when memory is disabled, makeAgentTools() drops memory_get from
        // the registered tools, so the model normally cannot emit this
        // call. If something else routes here (history replay, manual
        // RPC, future caller), refuse with a clear message that mirrors
        // executeMemoryWrite's guard above.
        guard memoryEnabled else {
            return FileToolResult(output: "Memory is disabled for this session. Use /memory to re-enable, or open Settings to change the default.", success: false)
        }
        let dict: [String: Any]
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = [:]
        }

        let scope = (dict["scope"] as? String) ?? "all"
        let categoryFilter = (dict["category"] as? String).map { $0.lowercased() }.flatMap { Self.memoryCategories.contains($0) ? $0 : nil }
        let keywords = ((dict["keywords"] as? String) ?? "")
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        var filesToSearch: [(label: String, url: URL)] = []
        let fm = FileManager.default
        let memDir = Self.minisMemoryPersistentDir

        var globalEmpty = false
        if scope == "all" {
            let globalFile = memDir.appendingPathComponent("GLOBAL.md")
            if fm.fileExists(atPath: globalFile.path) {
                let content = (try? String(contentsOf: globalFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if content.isEmpty {
                    globalEmpty = true
                } else {
                    filesToSearch.append(("GLOBAL.md", globalFile))
                }
            } else {
                globalEmpty = true
            }
        }

        if fm.fileExists(atPath: memDir.path),
           let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let sorted = files
                .filter { $0.pathExtension == "md" && $0.lastPathComponent != "GLOBAL.md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in sorted {
                filesToSearch.append((file.lastPathComponent, file))
            }
        }

        let globalNote = globalEmpty ? "[GLOBAL.md is empty or does not exist. Use file_write to create it when the user asks to save global memory.]\n\n" : ""

        if filesToSearch.isEmpty {
            return FileToolResult(output: globalNote + "No memory files found.", success: true)
        }

        // If no keywords (and no category filter), return full file contents (truncated)
        if keywords.isEmpty && categoryFilter == nil {
            let maxTotalLines = 500
            var results: [String] = []
            var totalLines = 0
            for (label, fileURL) in filesToSearch {
                guard totalLines < maxTotalLines else { break }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
                let lines = content.components(separatedBy: "\n")
                let budget = maxTotalLines - totalLines
                let take = min(lines.count, budget)
                let preview = lines.prefix(take).joined(separator: "\n")
                let truncated = lines.count > take ? " (showing first \(take) of \(lines.count) lines)" : ""
                results.append("[\(label)\(truncated)]\n\(preview)")
                totalLines += take
            }
            return FileToolResult(output: globalNote + results.joined(separator: "\n\n"), success: true)
        }

        // Split file content into memory entries using "<!-- " timestamp markers as boundaries.
        // Falls back to treating the whole file as one entry if no markers found.
        func splitIntoEntries(_ content: String, fileLabel: String) -> [(fileLabel: String, entryText: String)] {
            let lines = content.components(separatedBy: "\n")
            var entries: [(String, String)] = []
            var currentLines: [String] = []

            for line in lines {
                if line.hasPrefix("<!-- ") && !currentLines.isEmpty {
                    let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { entries.append((fileLabel, text)) }
                    currentLines = [line]
                } else {
                    currentLines.append(line)
                }
            }
            if !currentLines.isEmpty {
                let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append((fileLabel, text)) }
            }
            // If no timestamp markers found, treat whole file as one entry
            if entries.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append((fileLabel, content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return entries
        }

        // Score each entry: count distinct keywords + extract timestamp for recency scoring.
        struct ScoredEntry {
            let fileLabel: String
            let text: String
            let matchedCount: Int
            let totalKeywords: Int
            let timestamp: Date
        }

        // Parse timestamp from entry text (<!-- 2026-03-04 17:00:00 -->) or fall back to
        // file label date (2026-03-04.md) or distantPast for GLOBAL.md entries.
        let tsFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        func extractTimestamp(from entryText: String, fileLabel: String) -> Date {
            // Try <!-- 2026-03-04 17:00:00 [#category] --> in first line
            if let firstLine = entryText.components(separatedBy: "\n").first,
               firstLine.hasPrefix("<!-- "),
               let raw = Self.parseMemoryHeader(firstLine)?.timestamp,
               let ts = tsFormatter.date(from: raw) ?? dateFormatter.date(from: String(raw.prefix(10))) {
                return ts
            }
            // Fall back to file label date (e.g. "2026-03-04.md")
            let stem = (fileLabel as NSString).deletingPathExtension
            if let d = dateFormatter.date(from: stem) { return d }
            // GLOBAL.md or unknown — treat as oldest
            return Date.distantPast
        }

        var allEntries: [ScoredEntry] = []
        var totalEntryCount = 0

        for (label, fileURL) in filesToSearch {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
            let entries = splitIntoEntries(content, fileLabel: label)
            totalEntryCount += entries.count
            for (fileLabel, entryText) in entries {
                if let categoryFilter {
                    let firstLine = entryText.components(separatedBy: "\n").first ?? ""
                    let category = fileLabel == "GLOBAL.md" ? "profile" : (Self.parseMemoryHeader(firstLine)?.category ?? "note")
                    if category != categoryFilter { continue }
                }
                let lower = entryText.lowercased()
                let matchedCount = keywords.isEmpty ? 1 : keywords.filter { lower.contains($0) }.count
                if matchedCount > 0 {
                    let ts = extractTimestamp(from: entryText, fileLabel: fileLabel)
                    allEntries.append(ScoredEntry(
                        fileLabel: fileLabel,
                        text: entryText,
                        matchedCount: matchedCount,
                        totalKeywords: keywords.count,
                        timestamp: ts
                    ))
                }
            }
        }

        if allEntries.isEmpty {
            return FileToolResult(
                output: globalNote + "No matches found for keywords: \(keywords.joined(separator: ", ")) (scanned \(totalEntryCount) memory entries)",
                success: true
            )
        }

        // Compute combined score: 50% normalized confidence + 50% normalized recency.
        // Normalize confidence: matchedCount / totalKeywords → [0, 1]
        // Normalize recency: (ts - minTs) / (maxTs - minTs) → [0, 1], newer = higher
        let minTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.min() ?? 0
        let maxTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 1
        let tsRange = maxTs - minTs  // may be 0 if all entries have same timestamp

        let scored: [(entry: ScoredEntry, score: Double)] = allEntries.map { entry in
            let confScore = Double(entry.matchedCount) / Double(max(entry.totalKeywords, 1))
            let recencyScore: Double
            if tsRange > 0 {
                recencyScore = (entry.timestamp.timeIntervalSince1970 - minTs) / tsRange
            } else {
                recencyScore = 1.0  // all same age — treat equally
            }
            let combined = 0.5 * confScore + 0.5 * recencyScore
            return (entry, combined)
        }

        let sortedScored = scored.sorted { $0.score > $1.score }

        // Cap output to avoid flooding context. Two independent limits, whichever
        // is hit FIRST wins:
        //   1. Entry count — max 60 entries (legacy T-memory-get-limit).
        //   2. Byte size — max 30 KB of UTF-8 entry text. From a field
        //      report: a single memory_get returned ~70 KB, making the
        //      tool-result view stutter for seconds. We accumulate per entry
        //      and stop AFTER the entry that pushes the running total past the
        //      ceiling (so the triggering entry is shown whole, never sliced).
        let maxEntries = 60
        let maxBytes = 30 * 1024  // 30,720 bytes

        var rendered: [String] = []
        var shownBytes = 0
        var stoppedByBytes = false
        for item in sortedScored {
            if rendered.count >= maxEntries { break }
            let confidence = "\(item.entry.matchedCount)/\(item.entry.totalKeywords)"
            let scoreStr = String(format: "%.2f", item.score)
            let block = "[score: \(scoreStr) | confidence: \(confidence) | \(item.entry.fileLabel)]\n\(item.entry.text)"
            rendered.append(block)
            shownBytes += block.utf8.count
            // Append-then-break: include this entry in full, then stop.
            if shownBytes >= maxBytes {
                stoppedByBytes = true
                break
            }
        }

        let output = rendered.joined(separator: "\n\n---\n\n")

        let shownCount = rendered.count
        let truncatedNote: String
        if stoppedByBytes {
            let kb = String(format: "%.1f", Double(shownBytes) / 1024.0)
            truncatedNote = "\n\n[Truncated: showing \(shownCount) of \(sortedScored.count) matching entries, total \(kb) KB]"
        } else if sortedScored.count > shownCount {
            // Hit the entry-count cap before the byte cap.
            truncatedNote = "\n\n[Showing top \(shownCount) of \(sortedScored.count) matching entries]"
        } else {
            truncatedNote = ""
        }

        let summary = "Found \(sortedScored.count) matching entries (scanned \(totalEntryCount) total), sorted by combined score (50% confidence + 50% recency):"
        return FileToolResult(output: globalNote + summary + "\n\n" + output + truncatedNote, success: true)
    }

    /// Execute a memory_search tool call: full-text search over all memory
    /// entries with an in-memory SQLite FTS5 trigram index (CJK substrings
    /// work). Terms shorter than 3 characters, or a missing FTS5, fall back to
    /// substring matching. Ranked by distinct terms hit, then bm25, then recency.
    func executeMemorySearch(from json: String) -> FileToolResult {
        guard memoryEnabled else {
            return FileToolResult(output: "Memory is disabled for this session. Use /memory to re-enable, or open Settings to change the default.", success: false)
        }
        let dict = (json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let terms = ((dict["query"] as? String) ?? "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.prefix(12).map { $0 }
        let categoryFilter = (dict["category"] as? String)?.lowercased()
        let limit = max(1, min((dict["limit"] as? Int) ?? 10, 50))

        let memDir = Self.minisMemoryPersistentDir
        let files = ((try? FileManager.default.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var entries: [MemoryEntryRecord] = []
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            entries += Self.parseMemoryEntries(content, fileLabel: file.lastPathComponent)
        }
        if let categoryFilter { entries = entries.filter { $0.category == categoryFilter } }
        if entries.isEmpty { return FileToolResult(output: "No memory entries found.", success: true) }

        func sortKey(_ e: MemoryEntryRecord) -> String {
            e.timestamp ?? ((e.fileLabel as NSString).deletingPathExtension == "GLOBAL" ? "" : (e.fileLabel as NSString).deletingPathExtension)
        }
        var ranked: [(index: Int, hits: Int, rank: Double)] = []
        if terms.isEmpty {
            ranked = entries.indices.map { (index: $0, hits: 0, rank: 0.0) }
        } else {
            let ftsRank = Self.memoryFTSRank(entries.map(\.text), terms: terms.filter { $0.count >= 3 })
            for (i, e) in entries.enumerated() {
                let lower = e.text.lowercased()
                let hits = terms.filter { lower.contains($0.lowercased()) }.count
                if hits > 0 { ranked.append((index: i, hits: hits, rank: ftsRank[i] ?? 0)) }
            }
        }
        ranked.sort {
            if $0.hits != $1.hits { return $0.hits > $1.hits }
            if $0.rank != $1.rank { return $0.rank < $1.rank }  // bm25: lower is better
            return sortKey(entries[$0.index]) > sortKey(entries[$1.index])
        }
        if ranked.isEmpty {
            return FileToolResult(output: "No matches for: \(terms.joined(separator: " ")) (searched \(entries.count) entries)", success: true)
        }
        var blocks: [String] = []
        var bytes = 0
        for r in ranked.prefix(limit) {
            let e = entries[r.index]
            let block = "[\(e.fileLabel) | \(e.timestamp ?? "-") | #\(e.category) | hits \(r.hits)/\(max(terms.count, 1))]\n\(e.text)"
            blocks.append(block)
            bytes += block.utf8.count
            if bytes >= 30 * 1024 { break }
        }
        let header = "Found \(ranked.count) matching entries (searched \(entries.count)), showing \(blocks.count):"
        return FileToolResult(output: header + "\n\n" + blocks.joined(separator: "\n\n---\n\n"), success: true)
    }

    /// bm25 rank per entry index from an in-memory FTS5 trigram table; empty
    /// when there are no 3+ character terms or SQLite lacks FTS5/trigram.
    nonisolated static func memoryFTSRank(_ texts: [String], terms: [String]) -> [Int: Double] {
        guard !terms.isEmpty else { return [:] }
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return [:]
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE VIRTUAL TABLE m USING fts5(body, tokenize='trigram')", nil, nil, nil) == SQLITE_OK else { return [:] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO m(rowid, body) VALUES (?, ?)", -1, &insert, nil) == SQLITE_OK else { return [:] }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (i, text) in texts.enumerated() {
            sqlite3_bind_int64(insert, 1, Int64(i))
            sqlite3_bind_text(insert, 2, text, -1, transient)
            sqlite3_step(insert)
            sqlite3_reset(insert)
        }
        sqlite3_finalize(insert)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, bm25(m) FROM m WHERE m MATCH ?", -1, &query, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, match, -1, transient)
        var out: [Int: Double] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            out[Int(sqlite3_column_int64(query, 0))] = sqlite3_column_double(query, 1)
        }
        return out
    }

    /// Escape single quotes for shell arguments.
    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }


}
