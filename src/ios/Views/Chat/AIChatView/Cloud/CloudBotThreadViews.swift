import SwiftUI

// MARK: - 接口

/// 当前在哪个 Bot 的对话里（委托卡片据此打开两人之间的线程）
private struct CloudChatBotIdKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var cloudChatBotId: String {
        get { self[CloudChatBotIdKey.self] }
        set { self[CloudChatBotIdKey.self] = newValue }
    }
}

@MainActor
enum CloudBotThreadService {
    static func list(botId: String) async throws -> [CloudBotThreadSummary] {
        let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/bot-threads?bot_id=\(botId)")
        return (r["threads"] as? [[String: Any]] ?? []).compactMap(CloudBotThreadSummary.init)
    }

    static func thread(_ a: String, _ b: String, after: Int, wait: Int = 0, working: [String]? = nil) async throws
        -> (messages: [CloudBotThreadMessage], working: [String], names: [String: String], lastId: Int) {
        var path = "/v1/bot-threads/\(a)/\(b)?after=\(after)"
        if wait > 0 { path += "&wait=\(min(wait, 25))" }
        if let working { path += "&working=" + working.joined(separator: ",") }
        let r = try await CloudConnection.shared.request(method: "GET", path: path)
        return ((r["messages"] as? [[String: Any]] ?? []).compactMap(CloudBotThreadMessage.init),
                r["working"] as? [String] ?? [], r["names"] as? [String: String] ?? [:], (r["last_id"] as? NSNumber)?.intValue ?? after)
    }

    static func collapsed(sessionId: String) async throws -> [CloudBotThreadCollapsed] {
        let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(sessionId)/bot-threads")
        return (r["threads"] as? [[String: Any]] ?? []).compactMap(CloudBotThreadCollapsed.init)
    }
}

/// 线程里每个参与者的头像（主助手没有 Bot 资料时用系统图标）
struct CloudThreadAvatar: View {
    let botId: String
    var size: CGFloat = 28
    @ObservedObject private var home = CloudBotHomeModel.shared

    var body: some View {
        if let bot = home.bot(botId) {
            CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: size)
        } else {
            Image(systemName: "person.crop.circle.fill").font(.system(size: size * 0.9)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// 两个头像叠在一起（线程标题、折叠行）
struct CloudThreadPairAvatars: View {
    let a: String
    let b: String
    var size: CGFloat = 30

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CloudThreadAvatar(botId: a, size: size).padding(.trailing, size * 0.55).padding(.bottom, size * 0.25)
            CloudThreadAvatar(botId: b, size: size)
                .background(Circle().fill(Color(.systemBackground)).padding(-2))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 只读线程

/// Bot 之间的对话（参照 Grok Bot）：标题是两个叠在一起的头像，按天分隔，每条上方是发送者名字、左下角是小头像，
/// 底部「🔒 只读」。用户不能在这里发言；长按可复制，或引用到自己和某个 Bot 的对话里。
struct CloudBotThreadView: View {
    let a: String
    let b: String
    @ObservedObject private var home = CloudBotHomeModel.shared
    @State private var messages: [CloudBotThreadMessage] = []
    @State private var working: [String] = []
    @State private var names: [String: String] = [:]
    @State private var lastId = 0
    @State private var loaded = false
    @State private var errorText: String?

    private func name(_ id: String) -> String { names[id] ?? home.bot(id)?.name ?? (id == "_main" ? "主助手" : id) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if loaded && messages.isEmpty {
                        Text("这两位还没有互相发过消息。").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(CloudBotThreadRules.daySections(messages)) { section in
                        Text(CloudBotThreadRules.dayLabel(section.day)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color(.secondarySystemBackground)))
                            .frame(maxWidth: .infinity)
                        ForEach(section.messages) { m in
                            CloudThreadBubble(message: m, senderName: name(m.sender), recipientName: name(m.recipient), names: names)
                                .id(m.id)
                        }
                    }
                    if let w = working.first {
                        CloudThreadTyping(botId: w, name: name(w))
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("thread-bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _ in withAnimation { proxy.scrollTo("thread-bottom", anchor: .bottom) } }
            .onChange(of: working) { _ in withAnimation { proxy.scrollTo("thread-bottom", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom) {
            Label("只读", systemImage: "lock.fill").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .padding(.bottom, 8)
                .accessibilityLabel("只读，Bot 之间的对话不能在这里回复")
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    CloudThreadPairAvatars(a: a, b: b, size: 22)
                    Text("\(name(a)) 与 \(name(b))").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(name(a)) 与 \(name(b)) 的对话")
            }
        }
        .task { await follow() }
    }

    /// 先取全部，之后长轮询：有新消息或「正在处理」变化立刻更新
    private func follow() async {
        while !Task.isCancelled {
            do {
                let r = try await CloudBotThreadService.thread(a, b, after: lastId, wait: loaded ? 20 : 0, working: loaded ? working : nil)
                if !r.names.isEmpty { names = r.names }
                let fresh = r.messages.filter { m in !messages.contains(where: { $0.id == m.id }) }
                if !fresh.isEmpty { messages.append(contentsOf: fresh) }
                lastId = max(lastId, r.lastId)
                working = r.working
                loaded = true
                errorText = nil
            } catch {
                if Task.isCancelled { return }
                errorText = loaded ? nil : "没能读取对话：\(error.localizedDescription.prefix(80))"
                loaded = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

/// 线程里的一条：上方名字，左下角小头像（点一下打开那个 Bot），紧急标记，@ 标签
struct CloudThreadBubble: View {
    let message: CloudBotThreadMessage
    let senderName: String
    let recipientName: String
    let names: [String: String]
    @ObservedObject private var home = CloudBotHomeModel.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { open(message.sender) } label: { CloudThreadAvatar(botId: message.sender, size: 26) }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 \(senderName)")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(senderName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if message.isPriority {
                        Text("紧急").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .accessibilityLabel("优先消息")
                    }
                    if message.kind == "task" { Text("委托").font(.caption2).foregroundStyle(.tertiary) }
                    if message.kind == "result" { Text(statusText).font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(message.text).font(.callout).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
                    .contextMenu { menu }
                let mentioned = CloudBotThreadRules.mentions(in: message.text, names: names)
                if !mentioned.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(mentioned, id: \.self) { id in
                            Button { open(id) } label: {
                                HStack(spacing: 4) {
                                    CloudThreadAvatar(botId: id, size: 16)
                                    Text("@" + (names[id] ?? id)).font(.caption.weight(.medium))
                                }
                                .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("打开 \(names[id] ?? id)")
                        }
                    }
                }
                if message.kind == "task", home.bot(message.recipient) != nil {
                    Button { open(message.recipient) } label: {
                        Label("查看 \(recipientName) 处理这个任务", systemImage: "arrow.up.right.circle").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 24)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch message.status {
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return "回复"
        }
    }

    @ViewBuilder private var menu: some View {
        Button { UIPasteboard.general.string = message.text; CloudHaptics.success() } label: { Label("复制", systemImage: "doc.on.doc") }
        ForEach([message.sender, message.recipient].filter { home.bot($0) != nil }, id: \.self) { id in
            Button { quote(into: id) } label: {
                Label("引用到我和 \(names[id] ?? id) 的对话", systemImage: "text.quote")
            }
        }
    }

    private func quote(into botId: String) {
        home.pendingPrompt = CloudBotPendingPrompt(botId: botId, text: CloudBotThreadRules.quote(senderName: senderName, text: message.text), send: false)
        open(botId)
    }

    private func open(_ id: String) {
        guard home.bot(id) != nil else { return }
        CloudHaptics.tap()
        home.pendingOpen = id
    }
}

/// 「X 正在处理…」三个点
struct CloudThreadTyping: View {
    let botId: String
    let name: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 8) {
            CloudThreadAvatar(botId: botId, size: 26)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary).frame(width: 6, height: 6).opacity(phase == i ? 1 : 0.35)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            Text("\(name) 正在处理…").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                phase = (phase + 1) % 3
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) 正在处理")
    }
}

// MARK: - 用户对话里的折叠行

/// 「2 条消息，与 [头像] 制造厂」：点开只读线程
struct CloudBotThreadCollapsedRow: View {
    let item: CloudBotThreadCollapsed

    var body: some View {
        NavigationLink {
            CloudBotThreadView(a: item.me, b: item.peer)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.caption)
                Text("\(item.count) 条消息，与").font(.footnote)
                CloudThreadAvatar(botId: item.peer, size: 18)
                Text(item.peerName).font(.footnote.weight(.semibold))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(item.label + "，点开查看")
    }
}

// MARK: - Bot 资料页里的线程列表

struct CloudBotThreadsSection: View {
    let botId: String
    @State private var threads: [CloudBotThreadSummary] = []

    var body: some View {
        Section {
            if threads.isEmpty {
                Text("还没有和其他 Bot 说过话。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(threads) { t in
                let peer = t.peer ?? t.bots.first { $0 != botId } ?? t.bots[0]
                NavigationLink {
                    CloudBotThreadView(a: t.bots[0], b: t.bots[1])
                } label: {
                    HStack(spacing: 10) {
                        CloudThreadPairAvatars(a: botId, b: peer, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(t.names[peer] ?? peer).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if !t.working.isEmpty { Text("处理中").font(.caption2).foregroundStyle(.green) }
                                if t.highPriority > 0 { Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red) }
                                Spacer()
                                Text("\(t.count) 条").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(t.preview ?? t.lastText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        } header: {
            Text("与其他 Bot 的对话")
        }
        .task {
            threads = (try? await CloudBotThreadService.list(botId: botId)) ?? threads
        }
    }
}
