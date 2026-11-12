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
    var queuedTasks: Int
    /// 进行中 / 排队的后台任务数（服务器 running_workers）
    var runningWorkers = 0
    var waitingApprovals: Int
    /// 首页状态用（服务器 2.15.0+）：未读条数、待回答的选项卡片、最近一次结束的任务状态、运行中的例行任务
    var unreadCount = 0
    /// 最近的动静是和别的 Bot 说话时（服务器 2.16.0+）：「➤ 已发消息给 X：…」/「← 来自 X：…」
    var threadPreview: String?
    var threadAt: Double = 0
    var threadOutgoing = false
    var threadPriority = false
    var pendingCards = 0
    var lastTaskStatus: String?
    var routineRunning = 0
    /// 有自己的 API 凭据或用过保管库：App 默认给它上 Face ID 锁
    var holdsSecrets = false
    var notify: Bool
    var routinesEnabled: Int
    var reasoningEffort: String
    var fastMode: Bool
    /// 首页长按菜单的设置（服务器保存）：置顶、隐藏、手动标为未读、已读到的时间
    var pinned = false
    var pinnedAt: Double = 0
    var hidden = false
    var markedUnread = false
    var seenAt: Double = 0
    var sectionId: String?
    /// 灵魂设定：style / language / persona / forbidden（服务器每次调用模型都放在系统提示最前面）
    var soul: [String: String] = [:]
    /// 此刻在干什么（服务器 2.33.0+ 的 activity：正在思考 / 用工具 / 回复 / 委派）；没在跑为 nil
    var activity: CloudTypingPhase?

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
        self.queuedTasks = 0
        self.waitingApprovals = 0
        self.notify = true
        self.routinesEnabled = 0
        self.reasoningEffort = ""
        self.fastMode = false
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
        lastPreview = CloudPreviewText.plain(last?["preview"] as? String ?? "")
        lastRole = last?["role"] as? String ?? ""
        lastAt = (last?["at"] as? NSNumber)?.doubleValue ?? 0
        runningTasks = d["running_tasks"] as? Int ?? 0
        queuedTasks = d["queued_tasks"] as? Int ?? 0
        runningWorkers = d["running_workers"] as? Int ?? 0
        waitingApprovals = d["waiting_approvals"] as? Int ?? 0
        activity = CloudTypingPhase(json: d["activity"])
        unreadCount = d["unread_count"] as? Int ?? 0
        if let tp = d["thread_preview"] as? [String: Any] {
            threadPreview = (tp["text"] as? String).map(CloudPreviewText.plain)
            threadAt = (tp["at"] as? NSNumber)?.doubleValue ?? 0
            threadOutgoing = tp["outgoing"] as? Bool ?? false
            threadPriority = (tp["priority"] as? String) == "high"
        }
        pendingCards = d["pending_cards"] as? Int ?? 0
        lastTaskStatus = d["last_task_status"] as? String
        routineRunning = d["routine_running"] as? Int ?? 0
        notify = d["notify"] as? Bool ?? true
        routinesEnabled = d["routines_enabled"] as? Int ?? 0
        reasoningEffort = d["reasoning_effort"] as? String ?? ""
        fastMode = d["fast_mode"] as? Bool ?? false
        let prefs = d["prefs"] as? [String: Any] ?? [:]
        pinned = prefs["pinned"] as? Bool ?? false
        pinnedAt = (prefs["pinned_at"] as? NSNumber)?.doubleValue ?? 0
        hidden = prefs["hidden"] as? Bool ?? false
        markedUnread = prefs["unread"] as? Bool ?? false
        seenAt = (prefs["seen_at"] as? NSNumber)?.doubleValue ?? 0
        sectionId = prefs["section_id"] as? String
        soul = (d["soul"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        holdsSecrets = d["holds_secrets"] as? Bool ?? false
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
        CloudBotTemplate(id: "drug", name: "药物速查", emoji: "💊", summary: "剂量、相互作用、肾肝功能调整、泵速换算",
                         instructions: "你是药物速查助手。回答按「适应证 / 常用剂量 / 肾功能与肝功能调整 / 主要相互作用 / 禁忌与注意」分段，先给一句结论；剂量写明单位与给药途径，泵速换算写出计算式；数据来自药品说明书或指南时注明出处与年份，查不到就直说，不编造；提醒以医院药剂科与说明书为准，不替代临床决策。", primary: false),
        CloudBotTemplate(id: "quiz", name: "刷题", emoji: "📝", summary: "出题、讲解错题、按薄弱点复习",
                         instructions: "你是刷题教练。用户说明科目或考试后，一次出一道题（单选或病例题），等用户作答再公布答案；讲解时说明正确选项的依据和每个错误选项错在哪，给出一句记忆要点；把用户做错的知识点用 memory_write 记下来，之后优先出相关题；用户说「总结」时列出薄弱点和复习建议。", primary: false),
        CloudBotTemplate(id: "paper", name: "文献速读", emoji: "📄", summary: "一篇论文 5 分钟读懂：设计、结果、局限",
                         instructions: "你是文献速读助手。拿到论文（链接、PDF 或标题）后先找到原文，按「一句话结论 / 研究问题 / 设计与人群（样本量）/ 干预与对照 / 主要结局与效应量（含置信区间、P 值）/ 局限与偏倚 / 对临床或研究的意义」输出；数字必须来自原文并注明所在位置，读不到全文时明确说明只基于摘要；不编造引用。", primary: false),
    ]
}

@MainActor
enum CloudBotService {
    private(set) static var deletedSessions: Set<String> = []

    static func connected() async throws -> CloudConnection {
        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.connect() }
        return conn
    }

    static let cacheKey = "OpenMinisCloud_botListCache"

    static func list() async throws -> [CloudBot] {
        let resp = try await connected().request(method: "GET", path: "/v1/bots", body: nil)
        let items = resp["bots"] as? [[String: Any]] ?? []
        // 记下最近一次的列表：重连期间首页照常显示，不会一片空白
        if let data = try? JSONSerialization.data(withJSONObject: items) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return items.compactMap { CloudBot($0) }
    }

    static func cachedList() -> [CloudBot] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { CloudBot($0) }
    }

    static func save(_ bot: CloudBot) async throws {
        var body: [String: Any] = ["name": bot.name, "instructions": bot.instructions,
                                   "description": bot.summary, "is_primary": bot.isPrimary, "fast_mode": bot.fastMode]
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

    /// 置顶 / 隐藏 / 标为未读 / 已读到（服务器 2.6.0+）
    @discardableResult
    static func setPrefs(_ id: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await connected().request(method: "PUT", path: "/v1/bots/\(id)/prefs", body: body)
    }

    /// 删除进回收站（保留记忆和会话，可恢复）
    static func softDelete(_ id: String) async throws {
        _ = try await connected().request(method: "DELETE", path: "/v1/bots/\(id)?soft=1", body: nil)
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

    /// 无痕对话：不出现在历史和搜索里、不写长期记忆，离开时删除（服务器 24 小时兜底清理）
    static func newSession(_ bot: CloudBot, incognito: Bool = false) async throws -> String {
        let title = bot.label + " · " + (incognito ? "无痕" : Date().formatted(date: .abbreviated, time: .shortened))
        let resp = try await connected().request(method: "POST", path: "/v1/sessions",
                                                 body: ["title": title, "persona_id": bot.id, "incognito": incognito])
        if incognito, resp["incognito"] as? Bool != true {
            throw NSError(domain: "OpenMinisCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "云端版本太旧，不支持无痕对话；请先在设置里更新云端"])
        }
        guard let id = resp["session_id"] as? String, !id.isEmpty else {
            throw NSError(domain: "OpenMinisCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "云端没有返回新对话编号"])
        }
        return id
    }

    static func deleteSessions(_ ids: Set<String>, botId: String) async throws -> Set<String> {
        let response = try await connected().request(method: "POST", path: "/v1/bots/\(botId)/sessions/delete",
                                                      body: ["session_ids": ids.sorted()])
        guard let deleted = response["deleted_session_ids"] as? [String], Set(deleted) == ids else {
            throw NSError(domain: "OpenMinisCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "云端没有确认删除，请刷新历史对话"])
        }
        deletedSessions.formUnion(ids)
        for id in deleted {
            CloudChatCache.remove(id)
        }
        CloudOutbox.shared.removeSessions(ids)
        return Set(deleted)
    }

    static func deleteIncognito(_ sid: String) async {
        // 任务还在停的时候服务器回 409：多等几次；实在删不掉就交给服务器 24 小时后清理
        for attempt in 0..<5 {
            if (try? await connected().request(method: "DELETE", path: "/v1/sessions/\(sid)", body: nil)) != nil { return }
            try? await Task.sleep(nanoseconds: UInt64(1 + attempt) * 1_500_000_000)
        }
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
                            CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 30)
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
    @State private var alwaysShow = false
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
                Toggle("专注模式时始终显示", isOn: $alwaysShow)
            } footer: {
                Text("值班专注打开时，首页默认只显示名字或指令里和医疗相关的 Bot。打开「始终显示」后，即使名称不含这些词也会出现。")
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
                alwaysShow = CloudFocusFilter.isAlwaysShown(existing.id)
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
                CloudFocusFilter.setAlwaysShow(bot.id, alwaysShow)
                NotificationCenter.default.post(name: .cloudFocusFilterChanged, object: nil)
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
                    CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 44)
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
                    NavigationLink(destination: CloudBotChatView(botId: bot.id, sessionId: sid)) {
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
