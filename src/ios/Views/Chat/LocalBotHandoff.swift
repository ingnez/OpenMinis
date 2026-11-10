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
        let package = handoffPackage(instruction: instruction, target: target)
        inputText = ""
        attachments.removeAll()
        center.sending.insert(key)
        center.errors[key] = nil
        Task { @MainActor in
            defer { center.sending.remove(key) }
            do {
                try await CloudConnection.shared.ensureConnected()
                let receipt = try await CloudLocalHandoff.send(package)
                center.add(receipt, session: key)
            } catch {
                center.errors[key] = "交给 Bot 没成功：\(error.localizedDescription)"
            }
        }
    }

    private func handoffPackage(instruction: String, target: String?) -> CloudLocalHandoff.Package {
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
        var files: [(name: String, data: Data)] = []
        let queued = attachments.filter { $0.loadState == .ready } + visible.flatMap(\.inputAttachments)
        for a in queued where files.count < 10 {
            guard !files.contains(where: { $0.name == a.fileName }),
                  let data = try? Data(contentsOf: a.cacheURL), data.count <= 20_000_000 else { continue }
            files.append((name: a.fileName, data: data))
        }
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
