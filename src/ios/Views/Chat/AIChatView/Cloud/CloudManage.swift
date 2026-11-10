//
//  CloudManage.swift
//  Minis - 多 Bot 管理页：全局搜索、用量与每日上限、Bot 记忆、技能、备份恢复、委托记录，以及共用的触感与状态。
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 共用

@MainActor
enum CloudHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

enum CloudQuery {
    /// 只放行 ASCII 安全字符，其余（包括中文）一律百分号编码，配合 CloudConnection 的查询白名单
    static let safe: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s
    }()
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: safe) ?? "" }
}

/// 首页卡片的 Bot 状态
enum CloudBotStatus: Equatable {
    case idle, queued, working, waiting

    static func of(_ bot: CloudBot) -> CloudBotStatus {
        if bot.waitingApprovals > 0 { return .waiting }
        if bot.queuedTasks > 0 && bot.runningTasks <= bot.queuedTasks { return .queued }
        if bot.runningTasks > 0 { return .working }
        return .idle
    }

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .queued: return "排队中"
        case .working: return "处理中"
        case .waiting: return "等待审批"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .queued: return .blue
        case .working: return .green
        case .waiting: return .orange
        }
    }

    var busy: Bool { self != .idle }
}

struct CloudBotStatusChip: View {
    let status: CloudBotStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label).font(.caption2.weight(.semibold)).foregroundStyle(status.color)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(status.color.opacity(0.12)))
        .accessibilityLabel("状态：\(status.label)")
    }
}

private func cloudDate(_ ts: Double?) -> String {
    guard let ts, ts > 0 else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts)) ? "HH:mm" : "M月d日 HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

private func cloudTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
    return "\(n)"
}

struct CloudKV: Identifiable {
    let key: String
    let value: Int
    var id: String { key }
}

private func cloudInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int(v as? String ?? "") ?? 0 }

// MARK: - 首页搜索：搜聊天记录

struct CloudSearchHit: Identifiable {
    let id: String
    let kind: String        // bot / group
    let target: String      // botId 或 group:<gid>
    let title: String
    let snippet: String
    let role: String
    let timestamp: Double

    static func parse(_ d: [String: Any], index: Int) -> CloudSearchHit? {
        let kind = d["type"] as? String ?? "bot"
        let ts = (d["timestamp"] as? NSNumber)?.doubleValue ?? 0
        if kind == "group", let gid = d["group_id"] as? String {
            return CloudSearchHit(id: "g\(index)", kind: kind, target: "group:" + gid,
                                  title: (d["group_name"] as? String ?? "群聊") + " · " + (d["bot_name"] as? String ?? ""),
                                  snippet: d["snippet"] as? String ?? "", role: "", timestamp: ts)
        }
        let bot = d["bot_id"] as? String ?? ""
        guard !bot.isEmpty else { return nil }
        return CloudSearchHit(id: "b\(index)", kind: kind, target: bot, title: d["bot_name"] as? String ?? "Bot",
                              snippet: d["snippet"] as? String ?? "", role: d["role"] as? String ?? "", timestamp: ts)
    }
}

@MainActor
final class CloudSearchModel: ObservableObject {
    @Published var hits: [CloudSearchHit] = []
    @Published var searching = false
    @Published var errorText: String?
    private var task: Task<Void, Never>?

    func update(_ raw: String) {
        task?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { hits = []; errorText = nil; searching = false; return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)        // 防抖
            guard !Task.isCancelled, let self else { return }
            self.searching = true
            defer { self.searching = false }
            do {
                let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/search?q=" + CloudQuery.encode(String(q.prefix(100))))
                guard !Task.isCancelled else { return }
                let items = r["results"] as? [[String: Any]] ?? []
                self.hits = items.enumerated().compactMap { CloudSearchHit.parse($0.element, index: $0.offset) }
                self.errorText = nil
            } catch {
                if !Task.isCancelled { self.errorText = error.localizedDescription }
            }
        }
    }
}

struct CloudSearchResultsSection: View {
    @ObservedObject var model: CloudSearchModel
    let query: String
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("聊天记录").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                if model.searching { ProgressView().scaleEffect(0.7) }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
            if let err = model.errorText {
                Text(err).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            } else if model.hits.isEmpty && !model.searching {
                Text("没有找到包含「\(query)」的消息").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            ForEach(model.hits) { hit in
                Button {
                    CloudHaptics.tap()
                    onOpen(hit.target)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: hit.kind == "group" ? "person.3.fill" : (hit.role == "user" ? "person.fill" : "bubble.left.fill"))
                            .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(hit.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(cloudDate(hit.timestamp)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            highlight(hit.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func highlight(_ text: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let r = text.range(of: q, options: .caseInsensitive) else { return Text(text) }
        return Text(String(text[..<r.lowerBound]))
            + Text(String(text[r])).bold().foregroundColor(.accentColor)
            + Text(String(text[r.upperBound...]))
    }
}

// MARK: - 用量与每日上限

struct CloudUsageView: View {
    @State private var data: [String: Any] = [:]
    @State private var days = 14
    @State private var cap = 0
    @State private var alertPercent = 80
    @State private var capText = ""
    @State private var errorText: String?
    @State private var loading = false
    @State private var saving = false

    private var byDay: [CloudKV] {
        ((data["by_day"] as? [String: Any]) ?? [:]).map { CloudKV(key: $0.key, value: cloudInt($0.value)) }.sorted { $0.key < $1.key }
    }
    private func ranked(_ key: String) -> [CloudKV] {
        ((data[key] as? [String: Any]) ?? [:]).map { CloudKV(key: $0.key, value: cloudInt($0.value)) }.sorted { $0.value > $1.value }
    }
    private var today: Int { cloudInt(data["today_total"]) }
    private var botNames: [String: String] { data["bot_names"] as? [String: String] ?? [:] }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今天").font(.caption).foregroundStyle(.secondary)
                    Text(cloudTokens(today) + " tokens").font(.title2.bold())
                    if cap > 0 {
                        let p = min(1, Double(today) / Double(cap))
                        ProgressView(value: p).tint(p >= 1 ? .red : (p * 100 >= Double(alertPercent) ? .orange : .accentColor))
                        Text(p >= 1 ? "已达今日上限，新任务会被拒绝（明天 0 点重置）" : "上限 \(cloudTokens(cap))，已用 \(Int(p * 100))%")
                            .font(.caption).foregroundStyle(p >= 1 ? .red : .secondary)
                    } else {
                        Text("未设每日上限").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("范围", selection: $days) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                CloudUsageBars(points: byDay).frame(height: 120).padding(.vertical, 6)
            } header: { Text("每日用量") }
            if !ranked("by_bot").isEmpty {
                Section("按 Bot") {
                    ForEach(ranked("by_bot")) { item in
                        LabeledContent(item.key.isEmpty ? "主助手" : (botNames[item.key] ?? item.key), value: cloudTokens(item.value))
                    }
                }
            }
            if !ranked("by_model").isEmpty {
                Section("按模型") {
                    ForEach(ranked("by_model")) { item in
                        LabeledContent(item.key.isEmpty ? "未知" : item.key, value: cloudTokens(item.value))
                    }
                }
            }
            Section {
                HStack {
                    Text("每日上限")
                    Spacer()
                    TextField("0 = 不限", text: $capText).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 140)
                }
                Stepper("接近上限提醒：\(alertPercent)%", value: $alertPercent, in: 50...95, step: 5)
                Button(saving ? "保存中…" : "保存") { Task { await save() } }.disabled(saving)
            } header: { Text("上限") } footer: {
                Text("所有 Bot 合计的 token 数。接近上限时提醒一次；达到后当天的新任务会被拒绝，进行中的任务不受影响。")
            }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("用量")
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: days) { _ in Task { await load() } }
        .overlay { if loading && data.isEmpty { ProgressView() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/usage?days=\(days)")
            data = r
            cap = cloudInt(r["daily_token_cap"])
            alertPercent = max(50, min(95, cloudInt(r["usage_alert_percent"]) == 0 ? 80 : cloudInt(r["usage_alert_percent"])))
            capText = cap > 0 ? "\(cap)" : ""
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let value = Int(capText.trimmingCharacters(in: .whitespaces)) ?? 0
        do {
            _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/resources",
                                                         body: ["daily_token_cap": max(0, value), "usage_alert_percent": alertPercent])
            CloudHaptics.success()
            await load()
        } catch {
            CloudHaptics.warning()
            errorText = error.localizedDescription
        }
    }
}

struct CloudUsageBars: View {
    let points: [CloudKV]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(1, points.map { $0.value }.max() ?? 1)
            let w = points.isEmpty ? 0 : geo.size.width / CGFloat(points.count)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(points) { p in
                    VStack(spacing: 3) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: max(3, w * 0.6), height: max(2, (geo.size.height - 16) * CGFloat(p.value) / CGFloat(maxV)))
                        Text(String(p.key.suffix(2))).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    .frame(width: w)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(p.key)：\(p.value) tokens")
                }
            }
        }
        .overlay { if points.isEmpty { Text("暂无数据").font(.caption).foregroundStyle(.secondary) } }
    }
}

// MARK: - 某个 Bot 的记忆（可编辑）

struct CloudBotMemoryView: View {
    let botId: String
    let botName: String
    @State private var entries: [[String: Any]] = []
    @State private var includeShared = true
    @State private var editing: CloudMemoryDraft?
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                Toggle("同时显示共享记忆", isOn: $includeShared)
            } footer: {
                Text("「仅此 Bot」的记忆只有 \(botName) 能用；主 Bot 写的是共享记忆，所有 Bot 都能看到。编辑共享记忆会把它变成这个 Bot 自己的一条。")
            }
            if entries.isEmpty && !loading {
                Text("还没有记忆。对话里说「记住…」，或点右上角 + 手动添加。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(entries.indices, id: \.self) { i in
                let e = entries[i]
                let id = cloudInt(e["id"])
                let shared = (e["persona"] as? String ?? "").isEmpty
                Button {
                    editing = CloudMemoryDraft(id: id, content: e["content"] as? String ?? "", category: e["category"] as? String ?? "note")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(CloudMemoryTimelineView.label(e["category"] as? String)).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            Text(shared ? "共享" : "仅此 Bot").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text(e["content"] as? String ?? "").font(.footnote).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if (e["source"] as? String) != "phone" {
                        Button(role: .destructive) { Task { await delete(id) } } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("记忆")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = CloudMemoryDraft(id: nil, content: "", category: "note") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加记忆")
            }
        }
        .sheet(item: $editing) { draft in
            CloudMemoryEditSheet(draft: draft) { content, category in
                await save(draft, content: content, category: category)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: includeShared) { _ in Task { await load() } }
        .overlay { if loading && entries.isEmpty { ProgressView() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/memory?bot=\(botId)&shared=\(includeShared ? 1 : 0)&limit=200")
            entries = r["entries"] as? [[String: Any]] ?? []
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func save(_ draft: CloudMemoryDraft, content: String, category: String) async -> String? {
        do {
            if let id = draft.id {
                _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/memory/\(id)",
                                                             body: ["content": content, "category": category, "bot_id": botId])
            } else {
                _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/memory",
                                                             body: ["content": content, "category": category, "bot_id": botId])
            }
            CloudHaptics.success()
            await load()
            return nil
        } catch {
            CloudHaptics.warning()
            return error.localizedDescription
        }
    }

    private func delete(_ id: Int) async {
        do {
            _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/memory/\(id)")
            CloudHaptics.tap()
        } catch { errorText = error.localizedDescription }
        await load()
    }
}

struct CloudMemoryDraft: Identifiable {
    let id: Int?
    var content: String
    var category: String
}

struct CloudMemoryEditSheet: View {
    let draft: CloudMemoryDraft
    let onSave: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var category: String
    @State private var saving = false
    @State private var errorText: String?

    init(draft: CloudMemoryDraft, onSave: @escaping (String, String) async -> String?) {
        self.draft = draft
        self.onSave = onSave
        _content = State(initialValue: draft.content)
        _category = State(initialValue: draft.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("分类") {
                    Picker("分类", selection: $category) {
                        Text("关于我").tag("profile")
                        Text("偏好").tag("rules")
                        Text("人物").tag("people")
                        Text("项目").tag("workstreams")
                        Text("笔记").tag("note")
                    }
                    .pickerStyle(.segmented)
                }
                Section("内容") {
                    TextEditor(text: $content).frame(minHeight: 140)
                }
                if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(draft.id == nil ? "添加记忆" : "编辑记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "保存中…" : "保存") {
                        Task {
                            saving = true
                            let err = await onSave(content.trimmingCharacters(in: .whitespacesAndNewlines), category)
                            saving = false
                            if let err { errorText = err } else { dismiss() }
                        }
                    }
                    .disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 技能

struct CloudSkillsView: View {
    /// 传入 Bot 时可勾选这个 Bot 能用哪些技能；nil = 全部技能管理
    var bot: CloudBot?
    var onBotChanged: (@MainActor () async -> Void)?
    @State private var skills: [[String: Any]] = []
    @State private var enabled: Set<String>?
    @State private var errorText: String?
    @State private var loading = false
    @State private var confirmDelete: String?

    var body: some View {
        List {
            if let bot {
                Section {
                    Toggle("可以使用全部技能", isOn: Binding(get: { enabled == nil }, set: { all in
                        Task { await setBotSkills(all ? nil : Set(skills.compactMap { $0["name"] as? String })) }
                    }))
                } footer: {
                    Text("关掉后只勾选的技能对 \(bot.name) 可见。Bot 在对话里用 skill_save 存下的新技能会自动勾上。")
                }
            }
            if skills.isEmpty && !loading {
                Text("还没有技能。让 Bot 把常做的流程「存成技能」，或从手机同步。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(skills.indices, id: \.self) { i in
                let s = skills[i]
                let name = s["name"] as? String ?? ""
                HStack {
                    NavigationLink {
                        CloudSkillDetailView(name: name)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.subheadline.weight(.semibold))
                            if let d = s["description"] as? String, !d.isEmpty {
                                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(((s["source"] as? String) == "phone" ? "手机同步" : "Bot 保存") + " · " + cloudDate((s["updated_at"] as? NSNumber)?.doubleValue))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if bot != nil, let set = enabled {
                        Button {
                            var next = set
                            if next.contains(name) { next.remove(name) } else { next.insert(name) }
                            CloudHaptics.selection()
                            Task { await setBotSkills(next) }
                        } label: {
                            Image(systemName: set.contains(name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(set.contains(name) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(set.contains(name) ? "已启用" : "未启用")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { confirmDelete = name } label: { Label("删除", systemImage: "trash") }
                }
            }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("技能")
        .confirmationDialog("删除技能「\(confirmDelete ?? "")」？所有 Bot 都将不能再用它。", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let n = confirmDelete { Task { await delete(n) } } }
        }
        .refreshable { await load() }
        .task { await load() }
        .overlay { if loading && skills.isEmpty { ProgressView() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/skills")
            skills = r["skills"] as? [[String: Any]] ?? []
            if let bot {
                let d = try await CloudConnection.shared.request(method: "GET", path: "/v1/bots/\(bot.id)")
                enabled = (d["skills"] as? [String]).map(Set.init)
            }
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func setBotSkills(_ set: Set<String>?) async {
        guard let bot else { return }
        do {
            let value: Any = set.map { Array($0).sorted() } ?? NSNull()
            _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/bots/\(bot.id)", body: ["skills": value])
            enabled = set
            await onBotChanged?()
        } catch { errorText = error.localizedDescription }
    }

    private func delete(_ name: String) async {
        do {
            _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/skills/" + CloudQuery.encode(name))
            CloudHaptics.tap()
        } catch { errorText = error.localizedDescription }
        await load()
    }
}

struct CloudSkillDetailView: View {
    let name: String
    @State private var skill: [String: Any] = [:]
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let d = skill["description"] as? String, !d.isEmpty {
                    Text(d).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(skill["content"] as? String ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let c = skill["content"] as? String, !c.isEmpty {
                    Button { UIPasteboard.general.string = c; CloudHaptics.success() } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("复制")
                }
            }
        }
        .task {
            do {
                skill = try await CloudConnection.shared.request(method: "GET", path: "/v1/skills/" + CloudQuery.encode(name))
            } catch { errorText = error.localizedDescription }
        }
    }
}

// MARK: - 备份与恢复

struct CloudBackupView: View {
    @State private var includeMessages = true
    @State private var exportURL: URL?
    @State private var working = false
    @State private var showImporter = false
    @State private var resultText: String?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Toggle("包含聊天记录", isOn: $includeMessages)
                Button(working ? "正在生成…" : "生成备份文件") { Task { await export() } }.disabled(working)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("分享 / 存到文件", systemImage: "square.and.arrow.up") }
                }
            } header: { Text("备份") } footer: {
                Text("包含 Bot、会话、群聊、记忆、技能和资源设置。不含任何密钥、Token 或服务商凭证，恢复后需在新服务器重新填写。")
            }
            Section {
                Button("从文件恢复…") { showImporter = true }.disabled(working)
            } header: { Text("恢复") } footer: {
                Text("只会添加这台服务器上没有的内容，已有的 Bot / 会话 / 记忆不会被覆盖。")
            }
            if let resultText { Section { Text(resultText).font(.footnote).foregroundStyle(.green) } }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("备份与恢复")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await restore(url) }
            case .failure(let e): errorText = e.localizedDescription
            }
        }
    }

    private func export() async {
        working = true
        defer { working = false }
        do {
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/backup?messages=\(includeMessages ? 1 : 0)")
            let data = try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("openminis-backup-\(f.string(from: Date())).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            errorText = nil
            CloudHaptics.success()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func restore(_ url: URL) async {
        working = true
        defer { working = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorText = "文件不是有效的备份"; return
            }
            let s = try await CloudConnection.shared.request(method: "POST", path: "/v1/backup/import", body: ["backup": obj])
            resultText = "已恢复：Bot \(cloudInt(s["bots"]))、会话 \(cloudInt(s["sessions"]))、消息 \(cloudInt(s["messages"]))、群聊 \(cloudInt(s["groups"]))、记忆 \(cloudInt(s["memory"]))、技能 \(cloudInt(s["skills"]))；跳过已有 \(cloudInt(s["skipped"]))"
            errorText = nil
            CloudHaptics.success()
            await CloudBotHomeModel.shared.refresh()
        } catch {
            CloudHaptics.warning()
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 委托记录

struct CloudDelegationsView: View {
    var sessionId: String?
    @State private var items: [[String: Any]] = []
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        List {
            if items.isEmpty && !loading {
                Text("还没有 Bot 之间的委托。对话里说「让 xx 去做…」或用 @ 提到别的 Bot。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(items.indices, id: \.self) { i in
                let d = items[i]
                let target = d["to_bot"] as? String ?? ""
                NavigationLink {
                    CloudBotChatView(botId: target)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(d["from_name"] as? String ?? "").font(.subheadline.weight(.semibold))
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                            Text(d["to_name"] as? String ?? "").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(statusLabel(d["status"] as? String)).font(.caption2.weight(.semibold))
                                .foregroundStyle(statusColor(d["status"] as? String))
                        }
                        Text(clean(d["content"] as? String ?? "")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        if let r = d["result"] as? String, !r.isEmpty {
                            Text("结果：" + r).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(cloudDate((d["created_at"] as? NSNumber)?.doubleValue)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .disabled(target.isEmpty)
            }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("委托记录")
        .refreshable { await load() }
        .task { await load() }
        .overlay { if loading && items.isEmpty { ProgressView() } }
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"^【[^】]*】\s*"#, with: "", options: .regularExpression)
    }

    private func statusLabel(_ s: String?) -> String {
        switch s {
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "running": return "进行中"
        case "queued": return "排队中"
        default: return s ?? ""
        }
    }

    private func statusColor(_ s: String?) -> Color {
        switch s {
        case "completed": return .green
        case "failed": return .red
        case "running", "queued": return .blue
        default: return .secondary
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let path = sessionId.map { "/v1/delegations?session_id=\($0)" } ?? "/v1/delegations"
            let r = try await CloudConnection.shared.request(method: "GET", path: path)
            items = r["delegations"] as? [[String: Any]] ?? []
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }
}
