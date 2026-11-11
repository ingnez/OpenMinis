//
//  CloudGroups.swift
//  Minis - 群聊：用户和多个 Bot 在一个房间聊天。Bot 由服务器编排：被 @ 的一定回复，其余按话题和活跃度接话、
//  点表情；回复错开并显示「正在输入」；@ 后需要动手的事在该 Bot 自己的工作区执行，结果贴回群里。
//

import SwiftUI
import UIKit

struct CloudGroup: Identifiable, Equatable {
    let id: String
    var name: String
    var members: [String]
    var activity: String?
    var lastSender: String?
    var lastContent: String?
    var lastAt: Double
    var typing: [String]
    var lastReadId: Int
    var notifyMode: String
    var missedCount: Int

    init(_ d: [String: Any]) {
        id = d["group_id"] as? String ?? ""
        name = d["name"] as? String ?? "群聊"
        members = d["members"] as? [String] ?? []
        activity = d["activity"] as? String
        typing = d["typing"] as? [String] ?? []
        let last = d["last_message"] as? [String: Any]
        lastSender = last?["sender"] as? String
        lastContent = last?["content"] as? String
        lastAt = (last?["timestamp"] as? Double) ?? (d["updated_at"] as? Double) ?? 0
        lastReadId = d["last_read_id"] as? Int ?? 0
        notifyMode = d["notify_mode"] as? String ?? "relevant"
        missedCount = d["missed_count"] as? Int ?? (d["missed"] as? [String: Any]).flatMap { $0["count"] as? Int } ?? 0
    }
}

struct CloudGroupMessage: Identifiable, Equatable {
    let id: Int
    let sender: String
    let kind: String
    let content: String
    let replyTo: Int?
    let timestamp: Double
    let taskStatus: String?
    let sessionId: String?

    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0
        sender = d["sender"] as? String ?? ""
        kind = d["kind"] as? String ?? "text"
        content = d["content"] as? String ?? ""
        replyTo = d["reply_to"] as? Int
        timestamp = d["timestamp"] as? Double ?? 0
        let meta = d["meta"] as? [String: Any]
        taskStatus = meta?["status"] as? String
        sessionId = meta?["session_id"] as? String
        reason = meta?["reason"] as? String
        wrapSummary = meta?["summary"] as? String
        disagreements = meta?["disagreements"] as? [String] ?? []
        quotaKind = meta?["quota"] as? String
    }
    let reason: String?
    let wrapSummary: String?
    let disagreements: [String]
    let quotaKind: String?

    var asLine: CloudGroupRules.Line {
        .init(id: id, sender: sender, kind: kind, content: content, replyTo: replyTo, reason: reason, quotaKind: quotaKind)
    }
}

enum CloudGroupPayload {
    static func missed(_ d: [String: Any], fallbackRead: Int = 0) -> CloudGroupRules.Missed {
        let m = d["missed"] as? [String: Any] ?? [:]
        return CloudGroupRules.Missed(
            count: m["count"] as? Int ?? 0,
            senders: m["senders"] as? [String] ?? [],
            preview: m["preview"] as? String ?? "",
            fromId: m["from_id"] as? Int ?? fallbackRead)
    }

    static func quota(_ d: [String: Any]) -> CloudGroupRules.Quota {
        let q = d["quota"] as? [String: Any] ?? [:]
        var out = CloudGroupRules.Quota(
            turns: q["turns"] as? Int ?? 0,
            turnsMax: q["turns_max"] as? Int ?? 0,
            tokens: q["tokens"] as? Int ?? 0,
            tokensMax: q["tokens_max"] as? Int ?? 0,
            hit: q["hit"] as? Bool ?? false,
            hint: q["hint"] as? String)
        if out.hint == nil { out.hint = CloudGroupRules.quotaHint(out) }
        return out
    }
}

@MainActor
enum CloudGroupService {
    static func conn() async throws -> CloudConnection {
        let c = CloudConnection.shared
        if !c.isConnected { try await c.ensureConnected() }
        return c
    }

    static func list() async throws -> [CloudGroup] {
        let r = try await conn().request(method: "GET", path: "/v1/groups")
        return (r["groups"] as? [[String: Any]] ?? []).map(CloudGroup.init)
    }

    static func get(_ id: String) async throws -> (CloudGroup, [CloudGroupMessage], CloudGroupRules.Missed, CloudGroupRules.Quota) {
        let r = try await conn().request(method: "GET", path: "/v1/groups/\(id)")
        return (CloudGroup(r), (r["messages"] as? [[String: Any]] ?? []).map(CloudGroupMessage.init),
                CloudGroupPayload.missed(r), CloudGroupPayload.quota(r))
    }

    static func create(name: String, members: [String]) async throws -> String {
        let r = try await conn().request(method: "POST", path: "/v1/groups", body: ["name": name, "members": members])
        return r["group_id"] as? String ?? ""
    }

    static func update(_ id: String, _ body: [String: Any]) async throws {
        _ = try await conn().request(method: "PUT", path: "/v1/groups/\(id)", body: body)
    }

    static func delete(_ id: String) async throws {
        _ = try await conn().request(method: "DELETE", path: "/v1/groups/\(id)")
    }

    /// 成员 Bot 没有自己的模型时，用手机上当前选的模型（Key 先加密上传到云电脑，不随消息明文发送）
    static func send(_ id: String, text: String, nonce: String = UUID().uuidString, replyTo: Int? = nil) async throws -> Int {
        var body: [String: Any] = ["content": text, "client_nonce": nonce]
        if let replyTo { body["reply_to"] = replyTo }
        let d = UserDefaults.standard
        let instanceId = d.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? ""
        let model = d.string(forKey: "OpenMinisCloud_manualModel") ?? ""
        if !instanceId.isEmpty, !model.isEmpty, CloudCredentialSync.eligibleInstance(instanceId) != nil {
            _ = try await conn()
            _ = try? await CloudCredentialSync.upload(instanceId: instanceId)
            body["model"] = model
            body["provider"] = ["protocol": "chat", "credential": CloudCredentialSync.credentialName(forInstanceId: instanceId)]
        }
        let r = try await conn().request(method: "POST", path: "/v1/groups/\(id)/messages", body: body)
        return r["message_id"] as? Int ?? 0
    }

    /// 长轮询：有新消息或输入状态变化时返回
    static func poll(_ id: String, after: Int, wait: Int = 20) async throws -> ([CloudGroupMessage], [String], CloudGroupRules.Quota) {
        let r = try await conn().request(method: "GET", path: "/v1/groups/\(id)/messages?after=\(after)&wait=\(wait)")
        return ((r["messages"] as? [[String: Any]] ?? []).map(CloudGroupMessage.init), r["typing"] as? [String] ?? [], CloudGroupPayload.quota(r))
    }

    static func wrap(_ id: String) async throws -> [String: Any] {
        try await conn().request(method: "POST", path: "/v1/groups/\(id)/wrap", body: [:])
    }

    static func markRead(_ id: String, lastId: Int) async throws {
        _ = try await conn().request(method: "POST", path: "/v1/groups/\(id)/read", body: ["last_id": lastId])
    }

    static func spinTask(_ id: String, botId: String, goal: String? = nil) async throws {
        var body: [String: Any] = ["bot_id": botId]
        if let goal, !goal.isEmpty { body["goal"] = goal }
        _ = try await conn().request(method: "POST", path: "/v1/groups/\(id)/spin-task", body: body)
    }
}

// MARK: - 头像与首页行

/// 群头像：最多三个成员头像叠在一起
struct CloudGroupStackAvatar: View {
    let bots: [CloudBot]
    var size: CGFloat = 46

    var body: some View {
        let shown = Array(bots.prefix(3))
        let small = shown.count <= 1 ? size : size * 0.62
        ZStack {
            if shown.isEmpty {
                Circle().fill(Color(.systemGray5)).frame(width: size, height: size)
                Image(systemName: "person.3.fill").foregroundStyle(.secondary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, bot in
                CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: small)
                    .background(Circle().fill(Color(.systemBackground)).padding(-1.5))
                    .offset(offset(i, count: shown.count))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("群聊：" + bots.map(\.name).joined(separator: "、"))
    }

    private func offset(_ i: Int, count: Int) -> CGSize {
        let d = size * 0.2
        switch (count, i) {
        case (2, 0): return CGSize(width: -d, height: -d * 0.6)
        case (2, 1): return CGSize(width: d, height: d * 0.6)
        case (3, 0): return CGSize(width: 0, height: -d)
        case (3, 1): return CGSize(width: -d, height: d * 0.7)
        case (3, 2): return CGSize(width: d, height: d * 0.7)
        default: return .zero
        }
    }
}

struct CloudGroupHomeRow: View {
    let group: CloudGroup
    let bots: [CloudBot]

    var body: some View {
        HStack(spacing: 14) {
            CloudGroupStackAvatar(bots: members)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text("\(group.members.count + 1)").font(.caption).foregroundStyle(.tertiary)
                    if group.missedCount > 0 {
                        Text("\(group.missedCount)")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                            .accessibilityLabel("不在时错过 \(group.missedCount) 条")
                            .accessibilityIdentifier("groupMissedBadge-\(group.id)")
                    }
                    Spacer(minLength: 8)
                    Text(CloudBotHome.timeText(group.lastAt)).font(.caption).foregroundStyle(.secondary)
                }
                Text(preview).font(.subheadline).foregroundStyle(group.typing.isEmpty ? Color.secondary : Color.green).lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var members: [CloudBot] { group.members.compactMap { id in bots.first(where: { $0.id == id }) } }

    private var preview: String {
        if let t = group.typing.first, let b = bots.first(where: { $0.id == t }) { return "\(b.name) 正在输入…" }
        guard let content = group.lastContent, !content.isEmpty else { return "群里有：" + members.map(\.name).joined(separator: "、") }
        if group.lastSender == "user" { return "我：" + content }
        let name = bots.first(where: { $0.id == group.lastSender })?.name ?? ""
        if let sender = group.lastSender, CloudBotLock.isLockedStored(sender) { return (name.isEmpty ? "" : "\(name)：") + "（已上锁）" }
        return name.isEmpty ? content : "\(name)：\(content)"
    }
}

// MARK: - 新建群聊

struct CloudGroupCreateSheet: View {
    let onCreated: @MainActor (String) async -> Void
    @ObservedObject private var home = CloudBotHomeModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: [String] = []
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CloudGroupStackAvatar(bots: selected.compactMap { id in home.bots.first(where: { $0.id == id }) }, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("群名") {
                    TextField(defaultName.isEmpty ? "给群取个名字" : defaultName, text: $name)
                }
                Section {
                    CloudGroupMemberPicker(selected: $selected)
                } header: {
                    Text("成员")
                } footer: {
                    Text("你自己总在群里。被 @ 的 Bot 一定会回复；其他 Bot 会按话题和活跃度接话。")
                }
                if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("新群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "创建中…" : "创建") { create() }
                        .disabled(selected.isEmpty || saving)
                        .accessibilityIdentifier("createGroupConfirm")
                }
            }
        }
    }

    private var defaultName: String {
        selected.prefix(3).compactMap { id in home.bots.first(where: { $0.id == id })?.name }.joined(separator: "、")
    }

    private func create() {
        saving = true
        errorText = nil
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let id = try await CloudGroupService.create(name: String(finalName.prefix(40)), members: selected)
                await onCreated(id)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}

struct CloudGroupMemberPicker: View {
    @Binding var selected: [String]
    @ObservedObject private var home = CloudBotHomeModel.shared

    var body: some View {
        if home.bots.isEmpty {
            Text("还没有 Bot，先在首页创建几个吧").foregroundStyle(.secondary)
        }
        ForEach(home.bots) { bot in
            Button {
                if let i = selected.firstIndex(of: bot.id) { selected.remove(at: i) } else { selected.append(bot.id) }
            } label: {
                HStack(spacing: 12) {
                    CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.name).foregroundStyle(.primary)
                        if !bot.summary.isEmpty { Text(bot.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Image(systemName: selected.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(bot.id) ? Color.accentColor : Color.secondary)
                        .font(.title3)
                }
            }
            .accessibilityAddTraits(selected.contains(bot.id) ? .isSelected : [])
            .accessibilityIdentifier("groupMember-\(bot.id)")
        }
    }
}

// MARK: - 群聊页

@MainActor
final class CloudGroupChatModel: ObservableObject {
    let groupId: String
    @Published var group: CloudGroup?
    @Published var messages: [CloudGroupMessage] = []
    @Published var typing: [String] = []
    @Published var errorText: String?
    @Published var sending = false
    @Published var listenTo: String? = nil
    @Published var replyTo: CloudGroupMessage? = nil
    @Published var quota = CloudGroupRules.Quota(turns: 0, turnsMax: 0, tokens: 0, tokensMax: 0, hit: false, hint: nil)
    @Published var missed = CloudGroupRules.Missed(count: 0, senders: [], preview: "", fromId: 0)
    @Published var showMissed = false
    @Published var expandedFolds: Set<Int> = []
    @Published var threadSeed: Int? = nil
    private var lastId = 0

    init(groupId: String) { self.groupId = groupId }

    func load() async {
        do {
            let (g, msgs, missed, quota) = try await CloudQuiet.retry { try await CloudGroupService.get(self.groupId) }
            group = g
            messages = msgs
            typing = g.typing
            lastId = msgs.last?.id ?? 0
            self.quota = quota
            self.missed = missed
            showMissed = missed.count > 0
            errorText = nil
        } catch {
            if messages.isEmpty { errorText = "暂时读不到群聊，正在自动重试…" }
        }
    }

    func pollLoop() async {
        var misses = 0
        while !Task.isCancelled {
            do {
                let (new, typing, quota) = try await CloudGroupService.poll(groupId, after: lastId)
                if Task.isCancelled { return }
                if !new.isEmpty {
                    let known = Set(messages.map(\.id))
                    messages.append(contentsOf: new.filter { !known.contains($0.id) })
                    lastId = messages.last?.id ?? lastId
                }
                if typing != self.typing { self.typing = typing }
                self.quota = quota
                misses = 0
                if errorText != nil, !sending { errorText = nil; if group == nil { await load() } }
            } catch {
                if Task.isCancelled { return }
                misses += 1
                // 偶尔失败不打扰；连续失败才轻提示（成功一次就自动消失）
                if misses >= 4, errorText == nil { errorText = "网络不太稳，正在自动重连…" }
                try? await Task.sleep(nanoseconds: UInt64(min(8, 1 << min(misses, 3))) * 1_000_000_000)
            }
        }
    }

    func send(_ text: String) async {
        sending = true
        defer { sending = false }
        // 同一个 nonce 静默重试，服务器按 nonce 去重，不会发出两条
        let nonce = UUID().uuidString
        let reply = replyTo?.id
        replyTo = nil
        do {
            _ = try await CloudQuiet.retry { try await CloudGroupService.send(self.groupId, text: text, nonce: nonce, replyTo: reply) }
            errorText = nil
            await markReadNow()
        } catch {
            errorText = "发送失败：\(error.localizedDescription)"
        }
    }

    func wrapUp() async {
        do {
            _ = try await CloudGroupService.wrap(groupId)
            errorText = nil
        } catch {
            errorText = "收尾失败：\(error.localizedDescription)"
        }
    }

    func spinTask(botId: String) async {
        do {
            try await CloudGroupService.spinTask(groupId, botId: botId)
            errorText = nil
        } catch {
            errorText = "转任务失败：\(error.localizedDescription)"
        }
    }

    func markReadNow() async {
        let last = messages.last?.id ?? lastId
        showMissed = false
        missed = CloudGroupRules.Missed(count: 0, senders: [], preview: "", fromId: last)
        try? await CloudGroupService.markRead(groupId, lastId: last)
    }
}

struct CloudGroupChatView: View {
    let groupId: String
    @StateObject private var model: CloudGroupChatModel
    @ObservedObject private var home = CloudBotHomeModel.shared
    @State private var input = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool
    /// 群里的语音消息：说完自动转成文字发出（带 🎤 标记），Bot 的回复可以长按朗读
    @StateObject private var voice = CloudDictation()
    /// 群聊语音：轮流说（你说完发进群，各 Bot 用自己的声音念回复）
    @StateObject private var groupVoice = CloudGroupVoiceCall()
    @ObservedObject private var lock = CloudBotLock.shared

    init(groupId: String) {
        self.groupId = groupId
        _model = StateObject(wrappedValue: CloudGroupChatModel(groupId: groupId))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let err = model.errorText {
                            Text(err).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                        }
                        if model.showMissed, model.missed.count > 0 {
                            missedCard
                        }
                        ForEach(Array(foldedSections.enumerated()), id: \.offset) { _, sec in
                            sectionView(sec)
                        }
                        ForEach(visibleTyping, id: \.self) { bid in
                            typingRow(bid)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.typing) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if !CloudGroupRules.quotaLine(model.quota).isEmpty {
                Text(CloudGroupRules.quotaLine(model.quota))
                    .font(.caption2)
                    .foregroundStyle(model.quota.hit ? Color.orange : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(model.quota.hit ? Color.orange.opacity(0.12) : Color(.secondarySystemBackground))
                    .accessibilityIdentifier("groupQuotaBanner")
                    .accessibilityLabel(CloudGroupRules.quotaLine(model.quota))
            }
            composer
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showSettings = true } label: {
                    HStack(spacing: 8) {
                        CloudGroupStackAvatar(bots: memberBots, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.group?.name ?? "群聊").font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(model.typing.isEmpty ? "\(memberBots.count) 个 Bot 和你" : typingText)
                                .font(.caption2).foregroundStyle(model.typing.isEmpty ? Color.secondary : Color.green).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("群设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Menu {
                        Button("听所有人") { model.listenTo = nil }
                            .accessibilityIdentifier("groupListen-all")
                        ForEach(memberBots) { b in
                            Button {
                                model.listenTo = b.id
                            } label: {
                                Label(b.name, systemImage: model.listenTo == b.id ? "checkmark" : "ear")
                            }
                            .accessibilityIdentifier("groupListen-\(b.id)")
                        }
                    } label: {
                        Image(systemName: model.listenTo == nil ? "ear" : "ear.fill")
                    }
                    .accessibilityLabel(model.listenTo == nil ? "只听某个 Bot" : "正在只听一位 Bot")
                    .accessibilityIdentifier("groupListenButton")
                    Button {
                        if groupVoice.active { groupVoice.stop(dictation: voice) } else { groupVoice.start(model: model, dictation: voice) }
                    } label: { Image(systemName: groupVoice.active ? "phone.down.fill" : "phone") }
                    .accessibilityLabel(groupVoice.active ? "挂断群聊语音" : "群聊语音")
                    .accessibilityIdentifier("groupVoiceButton")
                    Button { showSettings = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("群设置")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            if let g = model.group {
                CloudGroupSettingsView(group: g, onChanged: { Task { await model.load(); await home.refresh() } })
            }
        }
        .sheet(item: threadItem) { seed in
            CloudGroupThreadSheet(messages: threadMessages(seed.id), nameOf: { bot($0)?.name ?? $0 }, onReply: { m in
                model.replyTo = m
                model.threadSeed = nil
            })
        }
        .task {
            await model.load()
            await model.pollLoop()
        }
    }

    private var threadItem: Binding<IdentifiedInt?> {
        Binding(
            get: { model.threadSeed.map(IdentifiedInt.init) },
            set: { model.threadSeed = $0?.id }
        )
    }

    private func threadMessages(_ id: Int) -> [CloudGroupMessage] {
        let ids = Set(CloudGroupRules.thread(around: id, in: model.messages.map(\.asLine)).map(\.id))
        return model.messages.filter { ids.contains($0.id) }
    }

    private var memberBots: [CloudBot] {
        (model.group?.members ?? []).compactMap { id in home.bots.first(where: { $0.id == id }) }
    }

    private var typingText: String {
        let names = visibleTyping.compactMap { id in home.bots.first(where: { $0.id == id })?.name }
        return CloudGroupRules.typingLabel(names)
    }

    private var visibleTyping: [String] {
        guard let listen = model.listenTo, !listen.isEmpty else { return model.typing }
        return model.typing.filter { $0 == listen }
    }

    private var foldedSections: [CloudGroupRules.Section] {
        CloudGroupRules.fold(CloudGroupRules.listening(model.messages.map(\.asLine), to: model.listenTo))
    }

    struct ReactionCount: Identifiable {
        let emoji: String
        let count: Int
        var id: String { emoji }
    }

    private func reactions(for id: Int) -> [ReactionCount] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for m in model.messages where m.kind == "reaction" && m.replyTo == id {
            if counts[m.content] == nil { order.append(m.content) }
            counts[m.content, default: 0] += 1
        }
        return order.map { ReactionCount(emoji: $0, count: counts[$0] ?? 0) }
    }

    private func bot(_ id: String) -> CloudBot? { home.bots.first(where: { $0.id == id }) }

    @ViewBuilder
    private func row(_ m: CloudGroupMessage) -> some View {
        switch m.kind {
        case "system":
            Text(m.content).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.horizontal, 24)
                .accessibilityIdentifier(m.quotaKind == nil ? "groupSystem-\(m.id)" : "groupQuotaHint")
        case "wrap":
            wrapCard(m)
        case "task", "task_result":
            taskCard(m)
        default:
            if m.sender == "user" {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Spacer(minLength: 48)
                        Text(m.content).textSelection(.enabled)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.accentColor))
                            .contextMenu {
                                Button { model.replyTo = m } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                                Button { model.threadSeed = m.id } label: { Label("查看回复串", systemImage: "text.bubble") }
                            }
                    }
                    if let parent = quote(of: m) {
                        Text("回复 \(parent)").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("groupReplyQuote-\(m.id)")
                    }
                    reactionChips(m.id)
                }
                .padding(.horizontal, 12)
            } else {
                botBubble(m)
            }
        }
    }

    private func botBubble(_ m: CloudGroupMessage) -> some View {
        let b = bot(m.sender)
        return HStack(alignment: .top, spacing: 8) {
            if let b {
                CloudBotAvatarView(spec: CloudBotAvatarSpec.of(b), size: 30)
            } else {
                Circle().fill(Color(.systemGray4)).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(b?.name ?? m.sender).font(.caption.weight(.semibold))
                    .foregroundStyle(b.map { CloudBotAvatarSpec.of($0).fill } ?? Color.secondary)
                if lock.needsUnlock(m.sender) {
                    lockedPlaceholder(m.sender)
                } else {
                Text(m.content).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.systemGray6)))
                    .contextMenu {
                        Button { model.replyTo = m } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                        Button { model.threadSeed = m.id } label: { Label("查看回复串", systemImage: "text.bubble") }
                        Button { CloudBotSpeaker.speak(m.content, botId: m.sender) } label: { Label("朗读", systemImage: "speaker.wave.2") }
                        Button { UIPasteboard.general.string = m.content } label: { Label("复制", systemImage: "doc.on.doc") }
                    }
                    .onLongPressGesture(minimumDuration: 0.5) { model.replyTo = m }
                }
                reactionChips(m.id)
            }
            Spacer(minLength: 32)
        }
        .padding(.horizontal, 12)
    }

    /// 已上锁 Bot 在群里的发言：不显示内容，轻点用 Face ID 解锁
    private func lockedPlaceholder(_ botId: String) -> some View {
        Button {
            Task { await lock.unlock(botId) }
        } label: {
            Label("已上锁，轻点解锁查看", systemImage: "lock.fill").font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.systemGray6)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func reactionChips(_ id: Int) -> some View {
        let rs = reactions(for: id)
        if !rs.isEmpty {
            HStack(spacing: 4) {
                ForEach(rs) { r in
                    Text(r.count > 1 ? "\(r.emoji) \(r.count)" : r.emoji).font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
            }
            .accessibilityLabel("表情回应：" + rs.map { "\($0.emoji) \($0.count)" }.joined(separator: "，"))
        }
    }

    private func taskCard(_ m: CloudGroupMessage) -> some View {
        let b = bot(m.sender)
        let done = m.kind == "task_result"
        let finished = done || model.messages.contains { $0.kind == "task_result" && $0.replyTo == m.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let b { CloudBotAvatarView(spec: CloudBotAvatarSpec.of(b), size: 20) }
                Text(done ? "\(b?.name ?? "Bot") 完成了任务" : "\(b?.name ?? "Bot") 开始做：")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if done {
                    Text(m.taskStatus == "completed" ? "已完成" : "已结束（\(m.taskStatus ?? "")）").font(.caption2)
                        .foregroundStyle(m.taskStatus == "completed" ? Color.green : Color.orange)
                } else if !finished {
                    ProgressView().controlSize(.small)
                }
            }
            if lock.needsUnlock(m.sender) {
                lockedPlaceholder(m.sender)
            } else {
            Text(m.content).font(.callout).lineLimit(done ? 12 : 4).textSelection(.enabled)
            }
            if let sid = m.sessionId, let b, !lock.needsUnlock(m.sender) {
                NavigationLink {
                    CloudSessionView(sessionId: sid, sessionTitle: b.name,
                                     model: UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "",
                                     selectedInstanceId: UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "",
                                     botHasOwnModel: b.hasOwnModel, theme: CloudBotChatTheme(bot: b))
                } label: {
                    Text(done ? "查看完整过程" : "查看进度").font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 12)
    }

    private func typingRow(_ bid: String) -> some View {
        HStack(spacing: 8) {
            if let b = bot(bid) {
                CloudBotLivelyAvatar(spec: CloudBotAvatarSpec.of(b), size: 30)
                Text("\(b.name) 正在输入").font(.caption).foregroundStyle(.secondary)
            }
            CloudTypingDots()
            Spacer()
        }
        .padding(.horizontal, 12)
        .transition(.opacity)
        .accessibilityIdentifier("groupTyping-\(bid)")
    }

    private func quote(of m: CloudGroupMessage) -> String? {
        guard let rid = m.replyTo, let p = model.messages.first(where: { $0.id == rid }) else { return nil }
        let who = p.sender == "user" ? "我" : (bot(p.sender)?.name ?? p.sender)
        let line = p.content.replacingOccurrences(of: "\n", with: " ")
        return who + "：" + String(line.prefix(40))
    }

    private var missedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CloudGroupRules.missedLabel(model.missed)).font(.subheadline.weight(.semibold))
            if !model.missed.preview.isEmpty {
                Text(model.missed.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("知道了") { Task { await model.markReadNow() } }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("groupMissedDismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("groupMissedCard")
    }

    @ViewBuilder
    private func sectionView(_ sec: CloudGroupRules.Section) -> some View {
        let shown = sec.hidden.isEmpty || model.expandedFolds.contains(sec.messages.first?.id ?? 0) ? sec.messages + sec.hidden : sec.messages
        ForEach(shown, id: \.id) { line in
            if let m = model.messages.first(where: { $0.id == line.id }) {
                row(m).id(m.id)
            }
        }
        if !sec.hidden.isEmpty {
            let key = sec.messages.first?.id ?? 0
            let open = model.expandedFolds.contains(key)
            Button {
                if open { model.expandedFolds.remove(key) } else { model.expandedFolds.insert(key) }
            } label: {
                Text(open ? "收起" : CloudGroupRules.foldLabel(hidden: sec.hidden))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("groupFoldButton")
            .accessibilityLabel(open ? "收起折叠的回复" : CloudGroupRules.foldLabel(hidden: sec.hidden))
        }
    }

    private func wrapCard(_ m: CloudGroupMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本轮收尾").font(.subheadline.weight(.semibold))
            Text(m.wrapSummary ?? m.content).font(.callout)
            if m.disagreements.isEmpty {
                if m.content.contains("没有明显分歧") {
                    Text("没有明显分歧。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("分歧：" + m.disagreements.joined(separator: "；")).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("groupWrapCard")
    }

    private var mentionCandidates: [CloudBot] {
        guard let at = input.lastIndex(of: "@") else { return [] }
        let q = input[input.index(after: at)...]
        guard !q.contains(" "), q.count <= 12 else { return [] }
        return memberBots.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.id.contains(q.lowercased()) }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let r = model.replyTo {
                HStack {
                    Text("回复 \(r.sender == "user" ? "我" : (bot(r.sender)?.name ?? r.sender))：\(String(r.content.prefix(40)))")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Button("取消") { model.replyTo = nil }.font(.caption)
                }
                .padding(.horizontal, 14)
                .accessibilityIdentifier("groupReplyBanner")
            }
            if !mentionCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionCandidates) { b in
                            Button {
                                if let at = input.lastIndex(of: "@") { input = String(input[..<at]) }
                                input += "@\(b.name) "
                            } label: {
                                HStack(spacing: 4) {
                                    CloudBotAvatarView(spec: CloudBotAvatarSpec.of(b), size: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(b.name).font(.subheadline)
                                        if !b.summary.isEmpty {
                                            Text(b.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("groupMention-\(b.id)")
                            .accessibilityLabel(b.summary.isEmpty ? b.name : "\(b.name)，擅长 \(b.summary)")
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            if groupVoice.active {
                CloudGroupVoiceBar(call: groupVoice, dictation: voice,
                                   botName: { id in home.bots.first { $0.id == id }?.name ?? id },
                                   onInterrupt: { groupVoice.interrupt(model: model) },
                                   onHangUp: { groupVoice.stop(dictation: voice) })
            } else if voice.isRecording {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(.red)
                    Text(voice.transcript.isEmpty ? "正在听…" : voice.transcript).font(.subheadline).lineLimit(2)
                    Spacer()
                    Button("取消") { voice.stop(); voice.transcript = "" }.font(.subheadline)
                    Button("发送") { finishVoice() }.font(.subheadline.weight(.semibold))
                        .disabled(voice.transcript.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.08)))
                .padding(.horizontal, 12)
            }
            if let err = voice.errorText { Text(err).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    if voice.isRecording { finishVoice() } else { CloudBotSpeaker.stop(); voice.start() }
                } label: {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
                        .font(.system(size: 18)).foregroundStyle(voice.isRecording ? Color.red : Color.secondary)
                        .frame(width: 34, height: 38)
                }
                .accessibilityLabel(voice.isRecording ? "说完了，发送" : "语音消息")
                CloudGroupDebateMenu { input = $0; focused = true }
                Menu {
                    Button("收尾总结") { Task { await model.wrapUp() } }
                        .accessibilityIdentifier("groupWrapButton")
                    ForEach(memberBots) { b in
                        Button("把讨论交给\(b.name)") { Task { await model.spinTask(botId: b.id) } }
                            .accessibilityIdentifier("groupSpin-\(b.id)")
                    }
                } label: {
                    Image(systemName: "checkmark.rectangle")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(width: 34, height: 38)
                }
                .accessibilityLabel("收尾或转任务")
                .accessibilityIdentifier("groupWrapMenu")
                TextField("发消息，@ 某个 Bot 让它回答或去做事", text: $input, axis: .vertical)
                    .accessibilityIdentifier("groupComposerField")
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                Button {
                    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    input = ""
                    Task { await model.send(text) }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.accentColor))
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.sending)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("groupSendButton")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.top, 6)
        .background(.bar)
        .onDisappear { groupVoice.stop(dictation: voice); voice.stop() }
    }

    private func finishVoice() {
        let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        voice.stop()
        voice.transcript = ""
        guard !text.isEmpty else { return }
        CloudHaptics.success()
        Task { await model.send("🎤 " + text) }
    }
}

/// 「正在输入」的三个跳动点（尊重“减弱动态效果”）
struct CloudTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .offset(y: reduceMotion ? 0 : -3 * max(0, sin(t * 6 - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Capsule().fill(Color(.systemGray6)))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 群设置

struct CloudGroupSettingsView: View {
    let group: CloudGroup
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var members: [String]
    @State private var activity: String
    @State private var notifyMode: String
    @State private var saving = false
    @State private var errorText: String?
    @State private var confirmDelete = false

    init(group: CloudGroup, onChanged: @escaping () -> Void) {
        self.group = group
        self.onChanged = onChanged
        _name = State(initialValue: group.name)
        _members = State(initialValue: group.members)
        _activity = State(initialValue: group.activity ?? "")
        _notifyMode = State(initialValue: group.notifyMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("群名") { TextField("群名", text: $name) }
                Section {
                    CloudGroupMemberPicker(selected: $members)
                } header: {
                    Text("成员（\(members.count) 个 Bot + 你）")
                }
                Section {
                    Picker("活跃度", selection: $activity) {
                        Text("跟随资源设置").tag("")
                        Text("安静").tag("quiet")
                        Text("正常").tag("normal")
                        Text("活跃").tag("lively")
                    }
                } footer: {
                    Text("安静：主要是被 @ 的 Bot 回复；活跃：Bot 们更爱接话、点表情。发言数、token 预算等上限在 云电脑资源设置 › 群聊。")
                }
                Section {
                    Picker("推送", selection: $notifyMode) {
                        Text("只推与我相关").tag("relevant")
                        Text("全部消息").tag("all")
                    }
                    .accessibilityIdentifier("groupNotifyMode")
                } footer: {
                    Text("只推与我相关：回复你的、被 @ 的、任务、收尾和额度提示。表情和闲聊接话不推。")
                }
                Section {
                    Button("删除群聊", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("只删除群聊记录；Bot 和它们在自己工作区做过的任务都保留。")
                }
                if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("群设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "保存中…" : "保存") { save() }
                        .disabled(saving || members.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("删除「\(group.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    Task {
                        do {
                            try await CloudGroupService.delete(group.id)
                            onChanged()
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func save() {
        saving = true
        errorText = nil
        Task {
            do {
                try await CloudGroupService.update(group.id, ["name": name.trimmingCharacters(in: .whitespaces), "members": members,
                                                              "activity": activity.isEmpty ? NSNull() : activity,
                                                              "notify_mode": notifyMode])
                onChanged()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}


/// 群聊输入框旁的「辩论 / 投票」：填入命令模板，服务器按顺序让各 Bot 发言并计票
struct CloudGroupDebateMenu: View {
    let insert: (String) -> Void

    var body: some View {
        Menu {
            Button { insert("/辩论 ") } label: { Label("发起辩论（亮观点 → 反驳 → 投票）", systemImage: "person.2.wave.2") }
            Button { insert("/投票 问题 | 选项一 | 选项二") } label: { Label("发起投票", systemImage: "checkmark.square") }
        } label: {
            Image(systemName: "hand.raised").font(.system(size: 17)).foregroundStyle(.secondary)
                .frame(width: 30, height: 38)
        }
        .accessibilityLabel("辩论或投票")
    }
}


private struct IdentifiedInt: Identifiable, Hashable {
    let id: Int
}

/// G7：一条消息所在的回复串
struct CloudGroupThreadSheet: View {
    let messages: [CloudGroupMessage]
    let nameOf: (String) -> String
    let onReply: (CloudGroupMessage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.sender == "user" ? "我" : nameOf(m.sender)).font(.caption.weight(.semibold))
                            Text(m.content)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                        .onTapGesture { onReply(m); dismiss() }
                    }
                }
                .padding()
            }
            .navigationTitle("回复串")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .accessibilityIdentifier("groupThreadSheet")
        }
    }
}
