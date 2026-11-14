import SwiftUI

/// 本地模式「交给 Bot」：本地做不完的工作打包交给云端（没点名 → 主 Bot 分派；@名字 → 直接给它）。
/// 本地对话里留一张卡片「已交给 主 Bot → X 在云端继续」，点一下切到 Bot 模式打开那个 Bot。
@MainActor
final class LocalBotHandoffCenter: ObservableObject {
    static let shared = LocalBotHandoffCenter()
    private static let key = "LocalBotHandoff_receipts"

    @Published private(set) var receipts: [String: [CloudLocalHandoff.Receipt]] = [:]
    @Published var sending: Set<String> = []
    @Published var errors: [String: String] = [:]
    /// 交接已经发出、但有几个文件没能一起带过去（太大 / 读不出来 / 暂存失败）。
    /// 以前这些文件是被静默丢掉的：用户只看到「已交给 Bot」，东西其实没跟过去。
    @Published var notes: [String: String] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: [CloudLocalHandoff.Receipt]].self, from: data) {
            receipts = saved
        }
    }

    func add(_ r: CloudLocalHandoff.Receipt, session: String) {
        receipts[session, default: []].append(r)
        if let data = try? JSONEncoder().encode(receipts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension AIChatViewModel {
    /// 发送前调用：这句话是明确的「交给 Bot」就打包交接并返回 true（不发给本地模型）
    @MainActor
    func tryHandoffToBot() -> Bool {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bots = CloudBotHomeModel.shared.bots.map { (id: $0.id, name: $0.name) }
        if bots.isEmpty { Task { await CloudBotHomeModel.shared.refresh() } }   // 下次就能认出 @名字
        guard let target = CloudLocalHandoff.intent(text, bots: bots) else { return false }
        handoffToBot(instruction: text, target: target)
        return true
    }

    /// 打包本地上下文（目标、进展、关键输出、文件、剩余步骤）交给 Bot。target nil = 主 Bot 分派。
    @MainActor
    func handoffToBot(instruction: String, target: String?) {
        let key = sessionId ?? "draft"
        let center = LocalBotHandoffCenter.shared
        guard !center.sending.contains(key) else { return }
        let (candidates, overflow) = handoffFileCandidates()
        inputText = ""
        attachments.removeAll()
        center.sending.insert(key)
        center.errors[key] = nil
        center.notes[key] = nil
        Task { @MainActor in
            defer { center.sending.remove(key) }
            do {
                try await CloudConnection.shared.ensureConnected()
                // 小文件内联进 JSON，大文件先暂存（staging_id），全程不把大文件读进内存
                var refs: [CloudLocalHandoff.FileRef] = []
                // 10 个以外的文件也不静默丢：一并写进下面那句提示
                var skipped: [String] = overflow.map { "\($0)（一次最多带 10 个）" }
                var inlineBytes = 0
                for f in candidates {
                    if CloudLocalHandoff.canInline(bytes: f.size, used: inlineBytes) {
                        if let data = try? Data(contentsOf: f.url) {
                            refs.append(.inline(name: f.name, data: data))
                            inlineBytes += data.count
                        } else {
                            skipped.append("\(f.name)（读不出来）")
                        }
                    } else {
                        do {
                            let stagingId = try await CloudHandoffStaging.stage(filename: f.name, fileURL: f.url)
                            refs.append(.staged(name: f.name, stagingId: stagingId))
                        } catch {
                            skipped.append("\(f.name)（\(CloudHandoffStaging.sizeText(f.size))：\(error.localizedDescription)）")
                        }
                    }
                }
                let package = handoffPackage(instruction: instruction, target: target, files: refs)
                let receipt = try await CloudLocalHandoff.send(package)
                center.add(receipt, session: key)
                if !skipped.isEmpty {
                    center.notes[key] = "这几个文件没能一起带过去：" + skipped.joined(separator: "、")
                }
            } catch {
                center.errors[key] = "交给 Bot 没成功：\(error.localizedDescription)"
            }
        }
    }

    /// 这次交接要带上的文件（同名只带一份，最多 10 个 = 服务端 MAX_FILES）。
    /// 返回 (能带的, 因为超过 10 个而没带的文件名)。只看元数据，不读内容。
    private func handoffFileCandidates() -> (files: [(name: String, url: URL, size: Int)], overflow: [String]) {
        let visible = messages.filter { !$0.isCompactedHistory }
        let queued = attachments.filter { $0.loadState == .ready } + visible.flatMap(\.inputAttachments)
        var out: [(name: String, url: URL, size: Int)] = []
        var overflow: [String] = []
        var seen = Set<String>()
        for a in queued {
            guard seen.insert(a.fileName).inserted else { continue }
            let size = (try? a.cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, FileManager.default.fileExists(atPath: a.cacheURL.path) else { continue }
            if out.count < 10 {
                out.append((a.fileName, a.cacheURL, size))
            } else {
                overflow.append(a.fileName)
            }
        }
        return (out, overflow)
    }

    private func handoffPackage(instruction: String, target: String?, files: [CloudLocalHandoff.FileRef]) -> CloudLocalHandoff.Package {
        let visible = messages.filter { !$0.isCompactedHistory }
        let users = visible.filter { $0.role == .user }.map(\.content)
        let goal = CloudLocalHandoff.clip(users.first ?? instruction, 1500)
        let turns = visible.suffix(8).map { m -> String in
            let who = m.role == .user ? "用户" : "助手"
            let text = m.role == .user ? m.content : m.blocks.filter { $0.kind == .text }.map(\.content).joined(separator: "\n")
            return "\(who)：" + CloudLocalHandoff.clip(text.isEmpty ? m.content : text, 400)
        }
        let lastAnswer = visible.last { $0.role == .assistant }
            .map { m in m.blocks.filter { $0.kind == .text }.map(\.content).joined(separator: "\n") } ?? ""
        let tools = visible.flatMap { $0.blocks.filter { $0.toolStatus != nil } }.suffix(4)
        let outputs = tools.map { "· \($0.toolDescription)：" + CloudLocalHandoff.clip($0.content, 600) }.joined(separator: "\n")
        return CloudLocalHandoff.Package(goal: goal, summary: turns.joined(separator: "\n"),
                                         progress: CloudLocalHandoff.clip(lastAnswer, 2000), outputs: outputs,
                                         remaining: instruction, files: files, targetBot: target)
    }
}

/// 本地对话输入框上方的交接卡片：发送中 / 已交给谁（点开对应 Bot）/ 失败原因
struct LocalBotHandoffCards: View {
    let sessionKey: String
    @ObservedObject private var center = LocalBotHandoffCenter.shared

    var body: some View {
        VStack(spacing: 6) {
            if center.sending.contains(sessionKey) {
                card(icon: "arrow.up.forward.circle", text: "正在交给 Bot…", tint: .secondary)
            }
            if let err = center.errors[sessionKey] {
                card(icon: "exclamationmark.circle", text: err, tint: .red)
                    .onTapGesture { center.errors[sessionKey] = nil }
            }
            if let note = center.notes[sessionKey] {
                card(icon: "info.circle", text: note, tint: .orange)
                    .onTapGesture { center.notes[sessionKey] = nil }
            }
            if let last = center.receipts[sessionKey]?.last {
                Button {
                    CloudBotEntry.open(bot: last.botId, text: nil, send: false)
                } label: {
                    card(icon: "cloud", text: last.title, tint: .accentColor, chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开这个 Bot 的对话")
            }
        }
    }

    private func card(icon: String, text: String, tint: Color, chevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.footnote).foregroundStyle(.primary).lineLimit(2)
            Spacer(minLength: 4)
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}
