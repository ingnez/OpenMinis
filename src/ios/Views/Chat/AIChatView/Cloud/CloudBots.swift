//
//  CloudBots.swift
//  Minis - 多 Bot（/v1/bots）
//  每个 Bot 有自己的名称、头像、简介、指令、会话列表、例行任务、私有记忆、插件授权与可选的模型；
//  可设一个主 Bot 负责分派，可从模板新建，可导出 / 导入为 JSON（不含密钥）。
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CloudBot: Identifiable, Hashable {
    let id: String
    var name: String
    var emoji: String
    var summary: String
    var instructions: String
    var model: String
    var credential: String
    var plugins: [String]
    /// nil 表示可用全部技能；否则只允许列表中的技能
    var skills: [String]?
    var hasTelegram: Bool
    var isPrimary: Bool
    var sessionCount: Int
    var routineCount: Int
    var memoryCount: Int
    var latestSessionId: String?
    var lastPreview: String
    var lastRole: String
    var lastAt: Double
    var runningTasks: Int
    var waitingApprovals: Int
    var notify: Bool
    var routinesEnabled: Int
    var reasoningEffort: String

    init(id: String, name: String, emoji: String, summary: String, instructions: String, isPrimary: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.summary = summary
        self.instructions = instructions
        self.model = ""
        self.credential = ""
        self.plugins = []
        self.skills = nil
        self.hasTelegram = false
        self.isPrimary = isPrimary
        self.sessionCount = 0
        self.routineCount = 0
        self.memoryCount = 0
        self.latestSessionId = nil
        self.lastPreview = ""
        self.lastRole = ""
        self.lastAt = 0
        self.runningTasks = 0
        self.waitingApprovals = 0
        self.notify = true
        self.routinesEnabled = 0
        self.reasoningEffort = ""
    }

    init?(_ d: [String: Any]) {
        guard let bid = (d["bot_id"] as? String) ?? (d["persona_id"] as? String) else { return nil }
        id = bid
        name = d["name"] as? String ?? bid
        emoji = d["emoji"] as? String ?? ""
        summary = d["description"] as? String ?? ""
        instructions = d["instructions"] as? String ?? ""
        model = d["model"] as? String ?? ""
        credential = d["credential"] as? String ?? ""
        plugins = d["plugins"] as? [String] ?? []
        skills = d["skills"] as? [String]
        hasTelegram = d["telegram"] as? Bool ?? false
        isPrimary = d["is_primary"] as? Bool ?? false
        sessionCount = d["session_count"] as? Int ?? 0
        routineCount = d["routine_count"] as? Int ?? 0
        memoryCount = d["memory_count"] as? Int ?? 0
        latestSessionId = d["latest_session_id"] as? String
        let last = d["last_message"] as? [String: Any]
        lastPreview = last?["preview"] as? String ?? ""
        lastRole = last?["role"] as? String ?? ""
        lastAt = (last?["at"] as? NSNumber)?.doubleValue ?? 0
        runningTasks = d["running_tasks"] as? Int ?? 0
        waitingApprovals = d["waiting_approvals"] as? Int ?? 0
        notify = d["notify"] as? Bool ?? true
        routinesEnabled = d["routines_enabled"] as? Int ?? 0
        reasoningEffort = d["reasoning_effort"] as? String ?? ""
    }

    /// 这个 Bot 自己固定了模型与凭据：对话不依赖手机当前选择的服务商
    var hasOwnModel: Bool { !model.isEmpty && !credential.isEmpty }

    var avatar: String { (emoji.isEmpty || emoji.hasPrefix("av:")) ? "🤖" : emoji }
    var label: String { "\(avatar) \(name)" }
}

struct CloudBotTemplate: Identifiable {
    let id: String
    let name: String
    let emoji: String
    let summary: String
    let instructions: String
    let primary: Bool

    static let all: [CloudBotTemplate] = [
        CloudBotTemplate(id: "boss", name: "总管", emoji: "🧭", summary: "主 Bot：理解需求并分派给专长 Bot",
                         instructions: "你是用户的总管。先弄清用户真正要什么；能自己完成的直接完成，属于其他 Bot 专长的用 subagent_task 转交并整合答复。回答先给结论。", primary: true),
        CloudBotTemplate(id: "research", name: "研究助理", emoji: "🔎", summary: "联网调研、读文献、做对比",
                         instructions: "你是研究助理。调研时至少交叉核对两个独立来源并附链接；读论文时说明研究设计、样本量、主要结果与局限；不编造数据。", primary: false),
        CloudBotTemplate(id: "coder", name: "代码助手", emoji: "💻", summary: "写代码、排错、维护服务器",
                         instructions: "你是代码助手，在云电脑上真实运行与验证代码。修改前先读相关文件，改完运行测试；破坏性命令先说明再执行。", primary: false),
        CloudBotTemplate(id: "life", name: "生活管家", emoji: "🏠", summary: "日程、购物比价、出行提醒",
                         instructions: "你是生活管家。比价时列出店铺、价格与链接；涉及付款、下单、发消息时先给出草稿请用户确认。", primary: false),
        CloudBotTemplate(id: "writer", name: "写作编辑", emoji: "✍️", summary: "润色、改写、总结",
                         instructions: "你是写作编辑。保留作者原意与语气，删去空话套话；给出修改稿后用要点说明主要改动。", primary: false),
        CloudBotTemplate(id: "coach", name: "健身教练", emoji: "🏃", summary: "训练计划与习惯追踪",
                         instructions: "你是健身教练。根据用户记忆中的身体情况制定循序渐进的计划；涉及伤病或药物时建议就医，不给诊断。", primary: false),
        CloudBotTemplate(id: "icu", name: "ICU 助手", emoji: "🩺", summary: "重症医学病例整理与指南查询",
                         instructions: "你是重症医学助手。整理病例时先脱敏；引用指南写明名称与年份；剂量以说明书为准并提示核对，不替代临床决策。", primary: false),
    ]
}

@MainActor
enum CloudBotService {
    static func connected() async throws -> CloudConnection {
        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.connect() }
        return conn
    }

    static func list() async throws -> [CloudBot] {
        let resp = try await connected().request(method: "GET", path: "/v1/bots", body: nil)
        let items = resp["bots"] as? [[String: Any]] ?? []
        return items.compactMap { CloudBot($0) }
    }

    static func save(_ bot: CloudBot) async throws {
        var body: [String: Any] = ["name": bot.name, "instructions": bot.instructions,
                                   "description": bot.summary, "is_primary": bot.isPrimary]
        if bot.emoji.isEmpty {
            body["emoji"] = NSNull()
        } else {
            body["emoji"] = bot.emoji
        }
        _ = try await connected().request(method: "PUT", path: "/v1/bots/\(bot.id)", body: body)
    }

    static func update(_ id: String, _ body: [String: Any]) async throws {
        _ = try await connected().request(method: "PUT", path: "/v1/bots/\(id)", body: body)
    }

    /// 让 Bot 固定使用手机当前选择的服务商 Key（加密上传）与模型；useCurrent 为 false 时恢复跟随客户端。
    static func setModel(_ id: String, useCurrent: Bool) async throws {
        guard useCurrent else {
            try await update(id, ["model": NSNull(), "credential": NSNull()])
            return
        }
        let d = UserDefaults.standard
        let instanceId = d.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? ""
        let model = d.string(forKey: "OpenMinisCloud_manualModel") ?? ""
        guard !instanceId.isEmpty, !model.isEmpty else {
            throw NSError(domain: "CloudBotService", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先在云电脑设置中选择服务商与模型"])
        }
        _ = try await connected()
        _ = try await CloudCredentialSync.upload(instanceId: instanceId)
        d.set(true, forKey: CloudCredentialSync.enabledKey)
        try await update(id, ["model": model, "credential": CloudCredentialSync.credentialName(forInstanceId: instanceId)])
    }

    static func delete(_ id: String, purgeMemory: Bool) async throws {
        _ = try await connected().request(method: "DELETE", path: "/v1/bots/\(id)" + (purgeMemory ? "?purge_memory=1" : ""), body: nil)
    }

    static func sessions(_ id: String) async throws -> [[String: Any]] {
        let resp = try await connected().request(method: "GET", path: "/v1/sessions?bot=\(id)", body: nil)
        return resp["sessions"] as? [[String: Any]] ?? []
    }

    static func routines(_ id: String) async throws -> [[String: Any]] {
        let resp = try await connected().request(method: "GET", path: "/v1/routines?bot=\(id)", body: nil)
        return resp["routines"] as? [[String: Any]] ?? []
    }

    static func newSession(_ bot: CloudBot) async throws -> String {
        let title = bot.label + " · " + Date().formatted(date: .abbreviated, time: .shortened)
        let resp = try await connected().request(method: "POST", path: "/v1/sessions", body: ["title": title, "persona_id": bot.id])
        return resp["session_id"] as? String ?? ""
    }

    static func exportFile(_ id: String) async throws -> URL {
        let bundle = try await connected().request(method: "GET", path: "/v1/bots/\(id)/export", body: nil)
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).openminis-bot.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func importFile(_ url: URL) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count < 8_000_000,
              let bundle = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CloudBotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "不是有效的 Bot 导出文件"])
        }
        let resp = try await connected().request(method: "POST", path: "/v1/bots/import", body: ["bundle": bundle])
        let bot = resp["bot"] as? [String: Any] ?? [:]
        let name = bot["name"] as? String ?? "Bot"
        let memory = resp["memory_imported"] as? Int ?? 0
        let skipped = (resp["routines_skipped"] as? [Any])?.count ?? 0
        var text = "已导入“\(name)”，私有记忆 \(memory) 条"
        if skipped > 0 { text += "；\(skipped) 个例行任务需要在此设备重新创建（导出文件不含密钥）" }
        return text
    }
}

struct CloudBotsView: View {
    @State private var bots: [CloudBot] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var showEditor = false
    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                if bots.isEmpty && !loading {
                    Text("还没有 Bot。每个 Bot 有自己的指令、对话、例行任务、记忆和插件，可以从模板新建。")
                        .foregroundStyle(.secondary)
                }
                ForEach(bots) { bot in
                    NavigationLink(destination: CloudBotDetailView(bot: bot, onChanged: { await reload() })) {
                        HStack(spacing: 12) {
                            Text(bot.avatar).font(.title2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(bot.name).font(.headline)
                                    if bot.isPrimary {
                                        Text("主 Bot").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    }
                                }
                                Text(bot.summary.isEmpty ? bot.instructions : bot.summary)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("对话 \(bot.sessionCount) · 例行任务 \(bot.routineCount) · 记忆 \(bot.memoryCount) · 插件 \(bot.plugins.count)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } footer: {
                Text("在对话里写“@Bot 名称”可以把任务交给另一个 Bot；主 Bot 会自动分派。Telegram 未指定 Bot 时由主 Bot 接待。")
            }
            if let infoText { Section { Text(infoText).font(.footnote).foregroundStyle(.secondary) } }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("我的 Bot")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showEditor = true } label: { Label("新建 Bot", systemImage: "plus") }
                    Button { showImporter = true } label: { Label("导入 Bot（JSON）", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { CloudBotEditor(existing: nil, onSaved: { await reload() }) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        infoText = try await CloudBotService.importFile(url)
                        await reload()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        loading = true
        do {
            bots = try await CloudBotService.list()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

struct CloudBotEditor: View {
    let existing: CloudBot?
    let onSaved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var botId = ""
    @State private var name = ""
    @State private var emoji = ""
    @State private var summary = ""
    @State private var instructions = ""
    @State private var isPrimary = false
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        Form {
            if existing == nil {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(CloudBotTemplate.all) { t in
                                Button {
                                    botId = t.id
                                    name = t.name
                                    emoji = t.emoji
                                    summary = t.summary
                                    instructions = t.instructions
                                    isPrimary = t.primary
                                } label: {
                                    VStack(spacing: 6) {
                                        Text(t.emoji).font(.title2)
                                        Text(t.name).font(.caption)
                                    }
                                    .frame(width: 84, height: 64)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("从模板开始")
                }
            }
            Section {
                if existing == nil {
                    TextField("ID（小写字母/数字/-/_，如 research）", text: $botId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    LabeledContent("ID", value: botId)
                }
                TextField("名称", text: $name)
                TextField("头像 Emoji", text: $emoji)
                TextField("一句话简介（主 Bot 据此分派）", text: $summary)
                Toggle("设为主 Bot", isOn: $isPrimary)
            }
            Section("指令") {
                TextField("这个 Bot 是谁、怎么做事", text: $instructions, axis: .vertical)
                    .lineLimit(4...14)
            }
            if let errorText { Section { Text(errorText).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle(existing == nil ? "新建 Bot" : "编辑 Bot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save() }
                    .disabled(saving || !CloudPersonaService.isValidId(botId)
                              || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if let existing, botId.isEmpty {
                botId = existing.id
                name = existing.name
                emoji = existing.emoji
                summary = existing.summary
                instructions = existing.instructions
                isPrimary = existing.isPrimary
            }
        }
    }

    private func save() {
        saving = true
        var bot = CloudBot(id: botId, name: name.trimmingCharacters(in: .whitespaces), emoji: String(emoji.prefix(4)),
                           summary: summary, instructions: instructions, isPrimary: isPrimary)
        if let existing { bot.plugins = existing.plugins }
        Task {
            do {
                try await CloudBotService.save(bot)
                await onSaved()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}

/// 高级设置（对话列表、插件、技能、模型、记忆、导出）：从 Bot 资料页的 … 菜单进入
struct CloudBotAdvancedView: View {
    let onChanged: @MainActor () async -> Void
    @State private var bot: CloudBot
    @State private var sessions: [[String: Any]] = []
    @State private var routines: [[String: Any]] = []
    @State private var plugins: [CloudPlugin] = []
    @State private var allSkills: [String] = []
    @State private var exportURL: URL?
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(bot: CloudBot, onChanged: @escaping @MainActor () async -> Void) {
        self.onChanged = onChanged
        _bot = State(initialValue: bot)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Text(bot.avatar).font(.system(size: 44))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bot.name).font(.title3.bold())
                        if !bot.summary.isEmpty { Text(bot.summary).font(.subheadline).foregroundStyle(.secondary) }
                        if bot.isPrimary { Text("主 Bot · 负责分派").font(.caption).foregroundStyle(.tint) }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    newSession()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
                .disabled(busy)
                ForEach(sessions.indices, id: \.self) { i in
                    let s = sessions[i]
                    let sid = s["session_id"] as? String ?? ""
                    let title = s["title"] as? String ?? sid
                    NavigationLink(destination: CloudSessionView(sessionId: sid, sessionTitle: title, model: currentModel(),
                                                                 selectedInstanceId: currentInstance())) {
                        Text(title).lineLimit(1)
                    }
                }
            } header: {
                Text("对话")
            }

            Section {
                if routines.isEmpty {
                    Text("暂无。在“云端例行任务”新建时选择此 Bot。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(routines.indices, id: \.self) { i in
                    let r = routines[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r["name"] as? String ?? "").font(.body)
                        Text(CloudRoutineService.scheduleText(r["schedule"] as? [String: Any]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("例行任务")
            }

            Section {
                if plugins.filter({ $0.kind == "mcp" }).isEmpty {
                    Text("还没有安装 MCP 插件，去“插件市场”安装后可在这里授权给此 Bot。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(plugins.filter { $0.kind == "mcp" }) { p in
                    Toggle(isOn: Binding(get: { bot.plugins.contains(p.id) }, set: { togglePlugin(p.id, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.statusText).font(.caption2).foregroundStyle(p.status == "ready" ? Color.secondary : Color.orange)
                        }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("插件授权")
            }

            Section {
                Toggle("可用全部技能", isOn: Binding(get: { bot.skills == nil }, set: { setAllSkills($0) }))
                    .disabled(busy)
                if let allowed = bot.skills {
                    if allSkills.isEmpty {
                        Text("云电脑上还没有技能。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(allSkills, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { allowed.contains(name) }, set: { toggleSkill(name, $0) }))
                            .disabled(busy)
                    }
                }
            } header: {
                Text("技能")
            } footer: {
                Text("关闭“可用全部技能”后，这个 Bot 只能看到并调用勾选的技能。")
            }

            CloudTelegramSection(selectedInstanceId: currentInstance(), path: "/v1/bots/\(bot.id)/telegram",
                                 title: bot.hasTelegram ? "专属 Telegram Bot（已连接）" : "专属 Telegram Bot")

            Section {
                LabeledContent("模型", value: bot.model.isEmpty ? "跟随手机当前选择" : bot.model)
                Button("固定使用当前服务商与模型") { setModel(true) }.disabled(busy)
                if !bot.model.isEmpty {
                    Button("恢复跟随手机") { setModel(false) }.disabled(busy)
                }
            } header: {
                Text("模型")
            } footer: {
                Text("固定后，这个 Bot 的对话、例行任务和 Telegram 消息都用它自己的模型；服务商 Key 加密保存在云电脑。")
            }

            Section {
                LabeledContent("私有记忆", value: "\(bot.memoryCount) 条")
                if let exportURL {
                    ShareLink(item: exportURL) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
                } else {
                    Button { prepareExport() } label: { Label("导出为 JSON", systemImage: "doc.badge.arrow.up") }
                        .disabled(busy)
                }
                Button("删除 Bot", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("导出包含指令、例行任务与私有记忆，不含任何密钥。")
            }

            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("高级设置")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("编辑") { showEditor = true } }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { CloudBotEditor(existing: bot, onSaved: { await refresh() }) }
        }
        .confirmationDialog("删除“\(bot.name)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除，保留其记忆", role: .destructive) { remove(purge: false) }
            Button("删除并清除其私有记忆", role: .destructive) { remove(purge: true) }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func currentModel() -> String { UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "" }
    private func currentInstance() -> String { UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "" }

    private func refresh() async {
        do {
            if let fresh = try await CloudBotService.list().first(where: { $0.id == bot.id }) { bot = fresh }
            sessions = try await CloudBotService.sessions(bot.id)
            routines = try await CloudBotService.routines(bot.id)
            plugins = (try? await CloudPluginService.list()) ?? []
            if let resp = try? await CloudBotService.connected().request(method: "GET", path: "/v1/skills", body: nil) {
                let items = resp["skills"] as? [[String: Any]] ?? []
                allSkills = items.compactMap { $0["name"] as? String }
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            do {
                try await op()
                await refresh()
                await onChanged()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func newSession() {
        run { _ = try await CloudBotService.newSession(bot) }
    }

    private func togglePlugin(_ id: String, _ on: Bool) {
        var list = bot.plugins.filter { $0 != id }
        if on { list.append(id) }
        let botId = bot.id
        run { try await CloudBotService.update(botId, ["plugins": list]) }
    }

    private func setAllSkills(_ all: Bool) {
        let botId = bot.id
        let body: [String: Any]
        if all {
            body = ["skills": NSNull()]
        } else {
            body = ["skills": [String]()]
        }
        run { try await CloudBotService.update(botId, body) }
    }

    private func toggleSkill(_ name: String, _ on: Bool) {
        var list = (bot.skills ?? []).filter { $0 != name }
        if on { list.append(name) }
        let botId = bot.id
        run { try await CloudBotService.update(botId, ["skills": list]) }
    }

    private func setModel(_ useCurrent: Bool) {
        let botId = bot.id
        run { try await CloudBotService.setModel(botId, useCurrent: useCurrent) }
    }

    private func prepareExport() {
        let botId = bot.id
        busy = true
        Task {
            do { exportURL = try await CloudBotService.exportFile(botId) } catch { errorText = error.localizedDescription }
            busy = false
        }
    }

    private func remove(purge: Bool) {
        let botId = bot.id
        Task {
            do {
                try await CloudBotService.delete(botId, purgeMemory: purge)
                await onChanged()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
