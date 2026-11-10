//
//  CloudBotPages.swift
//  Minis - Grok Bot 风格的 Bot 资料页、编辑页、资料库与「电脑」接管页
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import QuickLook

// MARK: - 语音设置（每个 Bot 单独保存在本机）

struct CloudBotVoiceSettings: Codable, Equatable {
    var voice: String = ""      // AVSpeechSynthesisVoice.identifier，空 = 系统默认
    var speed: Double = 1.0     // 0.75 / 1 / 1.25 / 1.5
    var language: String = ""   // 空 = 自动
    /// 朗读引擎：空 = 系统语音（上面的语音）；"phone" = 手机「语音」设置里配的语音服务（豆包 / Azure / OpenAI 等，失败自动回落系统语音）
    var engine: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
    }

    @MainActor static var phoneEngineLabel: String? {
        VoiceProviderResolver.resolvedOutputCandidates().first.map { $0.model.displayName }
    }

    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5]
    static let languages: [(String, String)] = [("", "自动"), ("zh-CN", "中文"), ("en-US", "English"), ("ja-JP", "日本語"),
                                                ("ko-KR", "한국어"), ("zh-HK", "粤语")]

    private static func key(_ botId: String) -> String { "OpenMinisBotVoice." + botId }

    static func load(_ botId: String) -> CloudBotVoiceSettings {
        guard let data = UserDefaults.standard.data(forKey: key(botId)),
              let v = try? JSONDecoder().decode(CloudBotVoiceSettings.self, from: data) else { return CloudBotVoiceSettings() }
        return v
    }

    func save(_ botId: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(botId)) }
    }

    static func speedLabel(_ s: Double) -> String { s == 1 ? "1x" : String(format: "%gx", s) }

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") || $0.language.hasPrefix("ja") || $0.language.hasPrefix("ko") }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
}

@MainActor
enum CloudBotSpeaker {
    private static let synth = AVSpeechSynthesizer()
    private static var player: AVAudioPlayer?
    private static var cloudTask: Task<Void, Never>?

    static func speak(_ text: String, botId: String) {
        let settings = CloudBotVoiceSettings.load(botId)
        stop()
        guard settings.engine == "phone", !VoiceProviderResolver.resolvedOutputCandidates().isEmpty else {
            speakSystem(text, settings: settings)
            return
        }
        let clean = String(VoiceTextSanitizer.sanitize(text).prefix(1500))
        cloudTask = Task { @MainActor in
            for entry in VoiceProviderResolver.resolvedOutputCandidates() {
                guard let p = VoiceProviderResolver.outputProvider(for: entry) else { continue }
                do {
                    let data = try await p.synthesize(VoiceOutputRequest(input: clean, model: entry.model.id, voice: entry.model.id,
                                                                         speed: Float(settings.speed), resolvedModel: entry.model))
                    if Task.isCancelled { return }
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    let pl = try AVAudioPlayer(data: data)
                    player = pl
                    pl.play()
                    cloudTask = nil
                    return
                } catch {
                    if Task.isCancelled { return }
                    continue   // 换下一个服务，全部失败再用系统语音
                }
            }
            cloudTask = nil
            speakSystem(text, settings: settings)
        }
    }

    private static func speakSystem(_ text: String, settings: CloudBotVoiceSettings) {
        let u = AVSpeechUtterance(string: String(text.prefix(4000)))
        if !settings.voice.isEmpty, let v = AVSpeechSynthesisVoice(identifier: settings.voice) {
            u.voice = v
        } else {
            let lang = settings.language.isEmpty ? (text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ? "zh-CN" : "en-US") : settings.language
            u.voice = AVSpeechSynthesisVoice(language: lang)
        }
        u.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * settings.speed)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        synth.speak(u)
    }

    static func stop() {
        cloudTask?.cancel()
        cloudTask = nil
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
    }
    static var isSpeaking: Bool { synth.isSpeaking || cloudTask != nil || (player?.isPlaying ?? false) }
}

// MARK: - 编辑 Bot

struct CloudBotEditSheet: View {
    /// 点完成后立刻调用（本地先显示新名字 / 头像）；不要在这里等网络
    let onSaved: @MainActor (CloudBot) async -> Void
    /// 改动真的同步到云电脑之后调用（这时再刷新列表）
    var onSynced: (@MainActor () async -> Void)? = nil
    private let original: CloudBot
    @Environment(\.dismiss) private var dismiss
    @State private var bot: CloudBot
    @State private var spec: CloudBotAvatarSpec
    @State private var voice: CloudBotVoiceSettings
    @State private var showAvatar = false
    @State private var showModel = false
    @State private var modelPick: (option: CloudModelOption?, effort: CloudEffort)?
    @State private var saving = false
    @State private var errorText: String?

    init(bot: CloudBot, onSaved: @escaping @MainActor (CloudBot) async -> Void, onSynced: (@MainActor () async -> Void)? = nil) {
        self.onSaved = onSaved
        self.onSynced = onSynced
        // 头像用首页最新的那份资料（传进来的可能是打开资料页时的旧快照）
        let fresh = CloudBotService.cachedList().first { $0.id == bot.id }
        var start = bot
        if let fresh, start.emoji.isEmpty { start.emoji = fresh.emoji }
        self.original = start
        _bot = State(initialValue: start)
        _spec = State(initialValue: CloudBotAvatarSpec.of(start))
        _voice = State(initialValue: CloudBotVoiceSettings.load(bot.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showAvatar = true } label: {
                        CloudBotAliveAvatar(spec: spec, size: 110, interactive: false)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Color(.systemBackground)).shadow(color: .black.opacity(0.15), radius: 4, y: 1))
                                    .offset(x: 6, y: 4)
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityLabel("更换头像")
                }
                Section("名称") {
                    TextField("为 Bot 取个名字", text: $bot.name)
                }
                Section {
                    CloudModelEffortRows(modelText: modelText, effort: currentEffort) { showModel = true }
                } header: { Text("模型") } footer: {
                    Text("这个 Bot 的对话、定时任务和 Telegram 都用这里的模型；对话里输入框上方的小标签也能随时切换。")
                }
                Section("外观") {
                    NavigationLink {
                        ScrollView {
                            VStack(spacing: 24) {
                                CloudBotAliveAvatar(spec: spec, size: 130).padding(.top, 16)
                                CloudBotAvatarPicker(spec: $spec)
                            }
                        }
                        .background(Color(.systemGroupedBackground))
                        .navigationTitle("头像")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Text("头像")
                    }
                }
                Section {
                    Picker("朗读引擎", selection: $voice.engine) {
                        Text("系统语音").tag("")
                        Text(CloudBotVoiceSettings.phoneEngineLabel.map { "语音服务 · \($0)" } ?? "语音服务（未配置）").tag("phone")
                    }
                    .pickerStyle(.menu)
                    Picker("语音", selection: $voice.voice) {
                        Text("系统默认").tag("")
                        ForEach(CloudBotVoiceSettings.voices, id: \.identifier) { v in
                            Text("\(v.name) · \(v.language)").tag(v.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("速度", selection: $voice.speed) {
                        ForEach(CloudBotVoiceSettings.speeds, id: \.self) { s in Text(CloudBotVoiceSettings.speedLabel(s)).tag(s) }
                    }
                    .pickerStyle(.menu)
                    Picker("语言", selection: $voice.language) {
                        ForEach(CloudBotVoiceSettings.languages, id: \.0) { l in Text(l.1).tag(l.0) }
                    }
                    .pickerStyle(.menu)
                    Button("试听") {
                        voice.save(bot.id)
                        CloudBotSpeaker.speak("你好，我是\(bot.name.isEmpty ? "你的 Bot" : bot.name)。", botId: bot.id)
                    }
                } header: {
                    Text("语音通话")
                } footer: {
                    Text("用于在 Bot 对话里朗读回复；保存在本机。")
                }
                CloudProactiveSection(botId: bot.id, botName: bot.name)
                CloudWeeklyReviewSection(botId: bot.id, botName: bot.name)
                CloudBotLockSection(botId: bot.id)
                CloudChatBackdropSection(botId: bot.id, accent: CloudBotAvatarSpec.of(bot).fill)
                Section {
                    Toggle("快速模式", isOn: $bot.fastMode)
                } footer: {
                    Text("开启后这个 Bot 用较低的思考强度、更短的回答，适合查询、翻译这类要快的事。")
                }
                Section("简介") {
                    TextField("一句话介绍（可选）", text: $bot.summary)
                }
                Section {
                    TextEditor(text: $bot.instructions).frame(minHeight: 140)
                } header: {
                    Text("指令")
                } footer: {
                    Text("Bot 每次回答前都会读这段话：它是谁、负责什么、怎么说话。")
                }
                if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("编辑 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save() } label: {
                        Text("完成").font(.subheadline.bold()).foregroundStyle(Color(.systemBackground))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.primary))
                    }
                    .disabled(bot.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showModel) {
                CloudModelEffortSheet(title: "模型与思考深度",
                                      current: (modelPick?.option?.instanceId ?? CloudBotService.instanceId(forCredential: bot.credential),
                                                modelPick?.option?.model ?? bot.model, currentEffort)) { option, e in
                    modelPick = (option, e)
                }
            }
            .sheet(isPresented: $showAvatar) {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 24) {
                            CloudBotAliveAvatar(spec: spec, size: 130).padding(.top, 16)
                            CloudBotAvatarPicker(spec: $spec)
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                    .navigationTitle("头像")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showAvatar = false } } }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var currentEffort: CloudEffort {
        modelPick?.effort ?? CloudEffort(rawValue: bot.reasoningEffort) ?? CloudEffort.globalDefault
    }

    private var modelText: String {
        if let modelPick { return modelPick.option?.model ?? "跟随手机默认" }
        return bot.model.isEmpty ? "跟随手机默认" : bot.model
    }

    /// 乐观保存：本地立刻生效、马上关掉表单；只把变了的字段放到后台发（见 CloudBotSaveQueue）。
    /// 以前这里依次等「重连 → 整个 Bot PUT → 头像上传 → 模型凭据上传 → 重新拉全部 Bot 和云电脑状态」都完成才关，
    /// 隧道慢或云电脑忙时就一直停在「保存中」。
    private func save() {
        var updated = bot
        updated.name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.emoji = spec.encoded
        if updated.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.instructions = "你是「\(updated.name)」，用户的私人助手。用中文简洁回答。"
        }
        if let modelPick {
            updated.model = modelPick.option?.model ?? ""
            updated.reasoningEffort = modelPick.effort.rawValue
        }
        voice.save(bot.id)
        let patch = Self.fields(updated).patch(from: Self.fields(original))
        if spec.pendingPhoto != nil { CloudAvatarImages.shared.store(spec.pendingPhoto!) }
        CloudBotSaveQueue.shared.enqueue(.init(botId: bot.id, botName: updated.name, patch: patch,
                                               avatar: spec.pendingPhoto != nil ? spec : nil, model: modelPick, onDone: onSynced))
        CloudHaptics.success()
        let saved = updated
        Task { await onSaved(saved) }
        dismiss()
    }

    static func fields(_ b: CloudBot) -> CloudBotEditFields {
        CloudBotEditFields(name: b.name, emoji: b.emoji, summary: b.summary, instructions: b.instructions, fastMode: b.fastMode)
    }
}

// MARK: - Bot 资料页（从 Bot 对话顶部进入）

struct CloudBotDetailView: View {
    let onChanged: @MainActor () async -> Void
    @State private var bot: CloudBot
    @State private var desktopAvailable: Bool?
    @State private var exportURL: URL?
    @State private var showEdit = false
    @State private var showAdvanced = false
    @State private var showResources = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var errorText: String?
    @ObservedObject private var connection = CloudConnection.shared
    @Environment(\.dismiss) private var dismiss

    init(bot: CloudBot, onChanged: @escaping @MainActor () async -> Void) {
        self.onChanged = onChanged
        _bot = State(initialValue: bot)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    CloudBotAliveAvatar(spec: CloudBotAvatarSpec.of(bot), size: 112)
                        .overlay(alignment: .bottomTrailing) {
                            if bot.isPrimary {
                                Image(systemName: "star.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30).background(Circle().fill(Color.orange))
                                    .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 3))
                            }
                        }
                    Text(bot.name).font(.title2.bold())
                    if !bot.summary.isEmpty {
                        Text(bot.summary).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("编辑") { showEdit = true }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 22).padding(.vertical, 8)
                        .background(Capsule().fill(Color(.systemGray5)))
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            CloudBotOverviewSection(bot: bot)

            Section {
                NavigationLink { CloudBotSoulView(bot: bot, onSaved: { await refresh(); await onChanged() }) } label: {
                    LabeledContent("灵魂设定", value: bot.soul.isEmpty ? "未设置" : (bot.soul["language"] ?? "已设置"))
                }
                NavigationLink { CloudBotLibraryView(bot: bot) } label: { Text("资料库") }
                NavigationLink { CloudBotMemoryView(botId: bot.id, botName: bot.name) } label: {
                    LabeledContent("记忆", value: bot.memoryCount > 0 ? "\(bot.memoryCount) 条" : "")
                }
                NavigationLink { CloudSkillsView(bot: bot, onBotChanged: { await refresh() }) } label: {
                    LabeledContent("技能", value: bot.skills.map { "\($0.count) 个" } ?? "全部")
                }
                NavigationLink { CloudDelegationsView(sessionId: bot.latestSessionId) } label: { Text("委托记录") }
                NavigationLink { CloudAuditView(botId: bot.id) } label: { Text("操作记录") }
                NavigationLink { CloudBotVersionsView(botId: bot.id, onRestored: { await refresh() }) } label: { Text("设置历史版本") }
                NavigationLink {
                    CloudComputerView(botId: bot.id, sessionId: bot.latestSessionId, reason: nil)
                } label: {
                    LabeledContent("电脑", value: computerStatus)
                }
            }

            CloudBotThreadsSection(botId: bot.id)

            Section("配置 Bot") {
                NavigationLink {
                    List {
                        CloudTelegramSection(selectedInstanceId: UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "",
                                             path: "/v1/bots/\(bot.id)/telegram",
                                             title: bot.hasTelegram ? "专属 Telegram Bot（已连接）" : "专属 Telegram Bot")
                    }
                    .navigationTitle("添加到 Telegram")
                    .onDisappear { Task { await refresh() } }
                } label: {
                    LabeledContent("添加到 Telegram", value: bot.hasTelegram ? "已连接" : "")
                }
                NavigationLink { CloudBotRoutinesPage(bot: bot) } label: {
                    LabeledContent("定时任务", value: bot.routinesEnabled > 0 ? "\(bot.routinesEnabled) 已开启" : "")
                }
            }

            Section {
                Toggle("通知", isOn: Binding(get: { bot.notify }, set: { setNotify($0) })).disabled(busy)
            } footer: {
                Text("Bot 完成任务或等你处理时，用 Minis 的系统通知提醒你。App 被关掉时，可在「通知」设置里选择用 Bark / ntfy 兜底。")
            }

            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .listStyle(.insetGrouped)
        .cloudBotSaveToast()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                } else {
                    Button { prepareExport() } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("导出分享")
                }
                Menu {
                    if !bot.isPrimary {
                        Button { setPrimary() } label: { Label("设为主 Bot", systemImage: "star") }
                    }
                    Menu {
                        Button("固定使用手机当前服务商与模型") { setModel(true) }
                        if !bot.model.isEmpty { Button("恢复跟随手机") { setModel(false) } }
                    } label: { Label(bot.model.isEmpty ? "切换模型（跟随手机）" : "切换模型（\(bot.model)）", systemImage: "cpu") }
                    Button { showAdvanced = true } label: { Label("技能、插件与对话记录", systemImage: "slider.horizontal.3") }
                    Button { showResources = true } label: { Label("资源限制", systemImage: "gauge.with.dots.needle.67percent") }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除 Bot", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .navigationDestination(isPresented: $showResources) {
            CloudBotResourceView(botId: bot.id, botName: bot.name)
        }
        .navigationDestination(isPresented: $showAdvanced) {
            CloudBotAdvancedView(bot: bot, onChanged: { await refresh(); await onChanged() })
        }
        .sheet(isPresented: $showEdit) {
            CloudBotEditSheet(bot: bot, onSaved: { saved in bot = saved }, onSynced: { await refresh(); await onChanged() })
        }
        .confirmationDialog("删除“\(bot.name)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除，保留其记忆", role: .destructive) { remove(purge: false) }
            Button("删除并清除其私有记忆", role: .destructive) { remove(purge: true) }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var computerStatus: String {
        guard connection.isConnected, desktopAvailable == true else { return "未连接" }
        return bot.runningTasks > 0 ? "工作中" : "空闲"
    }

    private func refresh() async {
        do {
            if let fresh = try await CloudBotService.list().first(where: { $0.id == bot.id }) { bot = fresh }
            let status = try? await CloudBotService.connected().request(method: "GET", path: "/v1/desktop/status", body: nil)
            desktopAvailable = status?["available"] as? Bool
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

    private func setNotify(_ on: Bool) {
        bot.notify = on
        let id = bot.id
        run { _ = try await CloudBotService.connected().request(method: "PUT", path: "/v1/bots/\(id)/notify", body: ["enabled": on]) }
    }

    private func setPrimary() {
        let id = bot.id
        run { try await CloudBotService.update(id, ["is_primary": true]) }
    }

    private func setModel(_ useCurrent: Bool) {
        let id = bot.id
        run { try await CloudBotService.setModel(id, useCurrent: useCurrent) }
    }

    private func prepareExport() {
        let id = bot.id
        busy = true
        Task {
            do { exportURL = try await CloudBotService.exportFile(id) } catch { errorText = error.localizedDescription }
            busy = false
        }
    }

    private func remove(purge: Bool) {
        let id = bot.id
        Task {
            do {
                try await CloudBotService.delete(id, purgeMemory: purge)
                await onChanged()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// 某个 Bot 的定时任务（例行任务）
struct CloudBotRoutinesPage: View {
    let bot: CloudBot
    @State private var routines: [[String: Any]] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if routines.isEmpty {
                Text("这个 Bot 还没有定时任务。").foregroundStyle(.secondary)
            }
            ForEach(routines.indices, id: \.self) { i in
                let r = routines[i]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r["name"] as? String ?? "")
                        Text(CloudRoutineService.scheduleText(r["schedule"] as? [String: Any])).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text((r["enabled"] as? Bool ?? false) ? "已开启" : "已暂停").font(.caption)
                        .foregroundStyle((r["enabled"] as? Bool ?? false) ? Color.green : Color.secondary)
                }
            }
            Section {
                NavigationLink { CloudRoutinesView() } label: { Label("管理全部定时任务", systemImage: "clock.arrow.circlepath") }
            } footer: {
                Text("新建定时任务时选择「\(bot.name)」，它就会用这个 Bot 的指令、模型和记忆运行。")
            }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("定时任务")
        .task {
            do { routines = try await CloudBotService.routines(bot.id) } catch { errorText = error.localizedDescription }
        }
    }
}

// MARK: - 资料库

struct CloudBotLibraryView: View {
    let bot: CloudBot
    @State private var items: [[String: Any]] = []
    @State private var filter = "all"
    @State private var loading = true
    @State private var errorText: String?
    @State private var preview: CloudLibraryPreview?
    @Environment(\.openURL) private var openURL

    private static let filters = [("all", "全部"), ("media", "媒体"), ("link", "链接"), ("file", "文件")]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.filters, id: \.0) { f in
                        Button(f.1) { filter = f.0 }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(filter == f.0 ? Color(.systemBackground) : Color.primary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(filter == f.0 ? Color.primary : Color(.systemGray5)))
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            List {
                if loading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if filtered.isEmpty {
                    Text(errorText ?? "这里会收集对话里出现的图片、链接和生成的页面。").font(.footnote).foregroundStyle(errorText == nil ? Color.secondary : Color.red)
                }
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1.indices, id: \.self) { i in row(group.1[i]) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(get: { pendingPage != nil }, set: { if !$0 { pendingPage = nil } })) {
            if let p = pendingPage { CloudPageDetailView(pageId: p.id, title: p.title) }
        }
        .quickLookPreview($quickLook)
        .sheet(item: $shareFile) { f in CloudActivitySheet(items: [f.url]) }
        .confirmationDialog(pendingDelete.map { "删除「\($0.title)」？" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let t = pendingDelete { delete(t) }; pendingDelete = nil }
        } message: {
            Text("手机上传的文件会从云电脑上删除；对话里的图片和链接只从资料库移除，对话内容不变。")
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $preview) { p in
            NavigationStack {
                Group {
                    if let image = p.image {
                        ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit() }
                    } else {
                        ProgressView()
                    }
                }
                .navigationTitle(p.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if let image = p.image {
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(p.title, image: Image(uiImage: image)))
                        }
                    }
                }
            }
        }
    }

    private var filtered: [[String: Any]] {
        filter == "all" ? items : items.filter { $0["kind"] as? String == filter }
    }

    private var groups: [(String, [[String: Any]])] {
        var order: [String] = []
        var map: [String: [[String: Any]]] = [:]
        for item in filtered {
            let label = Self.dayLabel((item["at"] as? NSNumber)?.doubleValue ?? 0)
            if map[label] == nil { order.append(label) }
            map[label, default: []].append(item)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    static func dayLabel(_ ts: Double) -> String {
        guard ts > 0 else { return "更早" }
        let d = Date(timeIntervalSince1970: ts)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        return d.formatted(.dateTime.month().day())
    }

    static func ago(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let s = max(0, Date().timeIntervalSince1970 - ts)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟" }
        if s < 86400 { return "\(Int(s / 3600)) 小时" }
        return Date(timeIntervalSince1970: ts).formatted(.dateTime.month().day())
    }

    @ViewBuilder private func row(_ item: [String: Any]) -> some View {
        let kind = item["kind"] as? String ?? ""
        let at = (item["at"] as? NSNumber)?.doubleValue ?? 0
        Button {
            open(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind == "media" ? "photo" : kind == "link" ? "globe" : "doc.richtext")
                    .font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind == "link" ? Self.shortURL(item["url"] as? String ?? "") : item["title"] as? String ?? "")
                        .font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    Text((kind == "link" ? (item["title"] as? String ?? "")
                         : (kind == "media" ? "图片" : "页面") + (at > 0 ? " · " + Self.ago(at) : "")) + sharedNote(item))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if kind == "link", let s = item["url"] as? String, let url = URL(string: s) {
                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.url = url; CloudHaptics.success() } label: { Label("复制链接", systemImage: "link") }
            } else if item["attachment_url"] != nil || kind == "media" {
                Button { share(item) } label: { Label("分享", systemImage: "square.and.arrow.up") }
            } else if item["page_id"] != nil {
                Button { open(item) } label: { Label("打开", systemImage: "doc.richtext") }
            }
            if item["shared_from"] == nil {
                let shared = item["shared"] as? Bool ?? false
                Button { setShared(item, !shared) } label: {
                    Label(shared ? "取消共享" : "共享给所有 Bot", systemImage: shared ? "person.2.slash" : "person.2")
                }
            }
            Button(role: .destructive) { pendingDelete = CloudLibraryPage(id: item["id"] as? String ?? "", title: item["title"] as? String ?? "") } label: {
                Label(item["attachment_url"] != nil && item["shared_from"] == nil ? "删除文件" : "从资料库移除", systemImage: "trash")
            }
        }
    }

    private func sharedNote(_ item: [String: Any]) -> String {
        if let from = item["shared_from"] as? String {
            return " · 来自 " + (CloudBotHomeModel.shared.bot(from)?.name ?? from)
        }
        return (item["shared"] as? Bool ?? false) ? " · 已共享" : ""
    }

    /// 共享后其他 Bot 的资料库里也能看到这一项（它们各自移除不影响这里）
    private func setShared(_ item: [String: Any], _ on: Bool) {
        guard let id = item["id"] as? String else { return }
        Task { @MainActor in
            do {
                _ = try await CloudBotService.connected().request(method: "POST", path: "/v1/bots/\(bot.id)/library/\(id)/share", body: ["shared": on])
                CloudHaptics.success()
                await load()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// 下载附件 / 图片到临时文件后弹出系统分享面板
    private func share(_ item: [String: Any]) {
        let title = (item["title"] as? String ?? "附件").replacingOccurrences(of: "/", with: "-")
        Task { @MainActor in
            do {
                var data: Data?
                var name = title
                if let path = item["attachment_url"] as? String {
                    data = try await CloudConnection.shared.downloadAttachment(path: path)
                } else if let mid = item["message_id"] as? Int, let part = item["part"] as? Int {
                    let owner = item["shared_from"] as? String ?? bot.id
                    let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/bots/\(owner)/library/media/\(mid)/\(part)", body: nil)
                    if let url = resp["url"] as? String, let comma = url.firstIndex(of: ","), url.hasPrefix("data:") {
                        data = Data(base64Encoded: String(url[url.index(after: comma)...]))
                        name = "图片-\(mid)-\(part).jpg"
                    }
                }
                guard let data else { errorText = "没有取到文件内容"; return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                shareFile = CloudShareFile(url: url)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func delete(_ target: CloudLibraryPage) {
        let before = items
        items.removeAll { ($0["id"] as? String) == target.id }
        CloudHaptics.tap()
        Task { @MainActor in
            do {
                _ = try await CloudBotService.connected().request(method: "DELETE", path: "/v1/bots/\(bot.id)/library/\(target.id)", body: nil)
            } catch {
                items = before
                errorText = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    static func shortURL(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    private func open(_ item: [String: Any]) {
        if let path = item["attachment_url"] as? String {
            // 手机上传的附件：下载到临时目录后用快速查看打开（可分享、存到文件）
            let title = item["title"] as? String ?? "附件"
            Task {
                do {
                    let data = try await CloudConnection.shared.downloadAttachment(path: path)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(title.replacingOccurrences(of: "/", with: "-"))
                    try data.write(to: url, options: .atomic)
                    quickLook = url
                } catch {
                    errorText = error.localizedDescription
                }
            }
            return
        }
        switch item["kind"] as? String {
        case "link":
            if let s = item["url"] as? String, let url = URL(string: s), url.scheme == "https" || url.scheme == "http" { openURL(url) }
        case "media":
            guard let mid = item["message_id"] as? Int, let part = item["part"] as? Int else { return }
            let placeholder = CloudLibraryPreview(title: "图片")
            preview = placeholder
            let botId = item["shared_from"] as? String ?? bot.id
            Task {
                let resp = try? await CloudBotService.connected().request(method: "GET", path: "/v1/bots/\(botId)/library/media/\(mid)/\(part)", body: nil)
                if let url = resp?["url"] as? String, let comma = url.firstIndex(of: ","), url.hasPrefix("data:"),
                   let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                    var loaded = placeholder
                    loaded.image = UIImage(data: data)
                    preview = loaded
                }
            }
        case "file":
            if let pid = item["page_id"] as? String {
                pendingPage = CloudLibraryPage(id: pid, title: item["title"] as? String ?? "页面")
            }
        default:
            break
        }
    }

    @State private var pendingPage: CloudLibraryPage?
    @State private var quickLook: URL?
    @State private var pendingDelete: CloudLibraryPage?
    @State private var shareFile: CloudShareFile?

    private func load() async {
        loading = true
        do {
            let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/bots/\(bot.id)/library", body: nil)
            items = resp["items"] as? [[String: Any]] ?? []
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

struct CloudLibraryPage: Hashable, Identifiable {
    let id: String
    let title: String
}

struct CloudShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系统分享面板
struct CloudActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct CloudLibraryPreview: Identifiable {
    let id = UUID()
    var title: String
    var image: UIImage?
}

// MARK: - 「电脑」接管页

/// 「我完成了」交回控制：对话页在前台时立即发送，不在前台时下次打开该会话再发送
enum CloudComputerHandoff {
    static let finished = Notification.Name("OpenMinisCloudComputerFinished")
    private static var pending = Set<String>()

    static func finish(sessionId: String) {
        pending.insert(sessionId)
        NotificationCenter.default.post(name: finished, object: nil, userInfo: ["session_id": sessionId])
    }

    static func consume(_ sessionId: String) -> Bool { pending.remove(sessionId) != nil }
}

struct CloudTakeoverCard: View {
    let reason: String
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bot 需要你帮忙", systemImage: "hand.raised.fill").font(.subheadline.bold()).foregroundStyle(.orange)
            if !reason.isEmpty { Text(reason).font(.callout) }
            Button(action: onOpen) {
                Label("打开电脑接管", systemImage: "display").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.primary).foregroundStyle(Color(.systemBackground))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.1)))
        // Bot 请求接管：先预热桌面体检，点「打开电脑接管」时省掉这一步
        .onAppear { CloudDesktopWarmup.prewarm(botId: nil) }
    }
}
