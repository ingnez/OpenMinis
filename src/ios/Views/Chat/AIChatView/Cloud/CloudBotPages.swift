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

    static func speak(_ text: String, botId: String) {
        let settings = CloudBotVoiceSettings.load(botId)
        synth.stopSpeaking(at: .immediate)
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

    static func stop() { synth.stopSpeaking(at: .immediate) }
    static var isSpeaking: Bool { synth.isSpeaking }
}

// MARK: - 编辑 Bot

struct CloudBotEditSheet: View {
    let onSaved: @MainActor (CloudBot) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bot: CloudBot
    @State private var spec: CloudBotAvatarSpec
    @State private var voice: CloudBotVoiceSettings
    @State private var showAvatar = false
    @State private var showModel = false
    @State private var modelPick: (option: CloudModelOption?, effort: CloudEffort)?
    @State private var saving = false
    @State private var errorText: String?

    init(bot: CloudBot, onSaved: @escaping @MainActor (CloudBot) async -> Void) {
        self.onSaved = onSaved
        _bot = State(initialValue: bot)
        _spec = State(initialValue: CloudBotAvatarSpec.of(bot))
        _voice = State(initialValue: CloudBotVoiceSettings.load(bot.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showAvatar = true } label: {
                        CloudBotAliveAvatar(spec: spec, size: 110)
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
                        Text(saving ? "保存中" : "完成").font(.subheadline.bold()).foregroundStyle(Color(.systemBackground))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.primary))
                    }
                    .disabled(saving || bot.name.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func save() {
        saving = true
        errorText = nil
        var updated = bot
        updated.name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.emoji = spec.encoded
        if updated.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.instructions = "你是「\(updated.name)」，用户的私人助手。用中文简洁回答。"
        }
        voice.save(bot.id)
        Task {
            do {
                try await CloudBotService.save(updated)
                if let modelPick {
                    try await CloudBotService.setModelChoice(bot.id, option: modelPick.option, effort: modelPick.effort)
                    updated.model = modelPick.option?.model ?? ""
                    updated.reasoningEffort = modelPick.effort.rawValue
                }
                CloudHaptics.success()
                await onSaved(updated)
                dismiss()
            } catch {
                CloudHaptics.warning()
                errorText = error.localizedDescription
            }
            saving = false
        }
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

            Section {
                NavigationLink { CloudBotLibraryView(bot: bot) } label: { Text("资料库") }
                NavigationLink { CloudBotMemoryView(botId: bot.id, botName: bot.name) } label: {
                    LabeledContent("记忆", value: bot.memoryCount > 0 ? "\(bot.memoryCount) 条" : "")
                }
                NavigationLink { CloudSkillsView(bot: bot, onBotChanged: { await refresh() }) } label: {
                    LabeledContent("技能", value: bot.skills.map { "\($0.count) 个" } ?? "全部")
                }
                NavigationLink { CloudDelegationsView(sessionId: bot.latestSessionId) } label: { Text("委托记录") }
                NavigationLink {
                    CloudComputerView(botId: bot.id, sessionId: bot.latestSessionId, reason: nil)
                } label: {
                    LabeledContent("电脑", value: computerStatus)
                }
            }

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
            CloudBotEditSheet(bot: bot, onSaved: { _ in await refresh(); await onChanged() })
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
                    Text(kind == "link" ? (item["title"] as? String ?? "")
                         : (kind == "media" ? "图片" : "页面") + (at > 0 ? " · " + Self.ago(at) : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
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
            let botId = bot.id
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
    }
}

struct CloudComputerView: View {
    let botId: String?
    let sessionId: String?
    let reason: String?
    @ObservedObject private var connection = CloudConnection.shared
    @ObservedObject private var home = CloudBotHomeModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .connecting
    @State private var reloadToken = UUID()
    @State private var viewOnly = false
    @State private var showHelp = false
    @State private var toast: String?
    @State private var keyboardText = CloudComputerView.sentinel
    @FocusState private var keyboardFocused: Bool
    @State private var sendChain: Task<Void, Never>?
    /// websockify token（新版服务器）：main = 主屏，bot-<id> = 该 Bot 的独立屏幕
    @State private var token: String?
    @State private var ownDisplay = false

    enum Phase: Equatable { case connecting, live, failed(String), problem(CloudDesktopProblem) }
    @State private var rechecking = false
    private static let sentinel = "\u{200B}"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .failed = phase {} else if case .problem = phase {} else if let url = streamURL {
                CloudComputerWebView(url: url, reloadToken: reloadToken, onLoaded: { if phase == .connecting { phase = .live } },
                                     onState: { vncStateChanged($0) })
                    .opacity(phase == .live ? 1 : 0.01)
                    .ignoresSafeArea(edges: .bottom)
            }
            switch phase {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("正在连接…").font(.subheadline.weight(.medium)).foregroundStyle(.white)
                }
            case .failed(let text):
                VStack(spacing: 14) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(text).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                    Button("重试") { Task { await start() } }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                }
                .padding(32)
            case .problem(let p):
                CloudDesktopProblemView(problem: p) { Task { await start() } }
                    .padding(.vertical, 60)
            case .live:
                EmptyView()
            }
            // 隐藏输入框：弹出 iOS 键盘，按键转发到云电脑
            TextField("", text: $keyboardText)
                .focused($keyboardFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .opacity(0.01).frame(width: 1, height: 1)
                .onChange(of: keyboardText) { value in forwardKeyboard(value) }
                .onSubmit { send(["action": "key", "key": "Return"]); keyboardFocused = true }
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.footnote).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
                    .padding(.top, 70)
                    .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHelp) { CloudComputerHelpSheet(reason: reason) }
        .task { await start() }
    }

    private var bot: CloudBot? { botId.flatMap { home.bot($0) } }

    private var streamURL: URL? { CloudDesktopCheck.streamURL(token: token, viewOnly: viewOnly) }

    /// noVNC 报告连接失败：先查服务器链路，真坏了就换成诊断卡片；只是网络抖动则交给 noVNC 自动重连
    private func vncStateChanged(_ state: String) {
        if state == "connected" { phase = .live; return }
        guard state.hasPrefix("error"), !rechecking else { return }
        rechecking = true
        Task {
            let r = await CloudDesktopCheck.run(botId: botId, autoRepair: true)
            rechecking = false
            if case .problem(let p) = r { phase = .problem(p) } else { show("画面断开，正在重连…") }
        }
    }

    private var topBar: some View {
        HStack {
            roundButton("chevron.left", label: "返回") { dismiss() }
            Spacer()
            HStack(spacing: 8) {
                if let bot { CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 26) }
                Text(bot?.name ?? "云电脑").font(.headline).foregroundStyle(.white).lineLimit(1)
                if ownDisplay {
                    Text("独立屏幕").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().stroke(Color.white.opacity(0.4)))
                }
            }
            Spacer()
            roundButton("questionmark", label: "帮助") { showHelp = true }
            Menu {
                Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                Button { restartDesktop() } label: { Label("重启桌面", systemImage: "power") }
                Button { if let streamURL { openURL(streamURL) } } label: { Label("在浏览器打开", systemImage: "safari") }
                Toggle(isOn: Binding(get: { viewOnly }, set: { viewOnly = $0; reload() })) { Label("仅查看", systemImage: "eye") }
            } label: {
                roundIcon("ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        .background(Color.black)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            roundButton("doc.on.clipboard", label: "发送剪贴板") { pasteClipboard() }
            Spacer()
            if sessionId != nil {
                Button { finished() } label: {
                    Text("我完成了").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(Capsule().fill(Color(white: 0.17)))
                }
            }
            roundButton("keyboard", label: "键盘") {
                keyboardText = Self.sentinel
                keyboardFocused.toggle()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.black)
    }

    private func roundIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(Circle().fill(Color(white: 0.17)))
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundIcon(symbol) }.accessibilityLabel(label)
    }

    private func start() async {
        phase = .connecting
        // 先体检桌面链路（坏了自动重启一次），拿到这个 Bot 屏幕的 noVNC token
        switch await CloudDesktopCheck.run(botId: botId) {
        case .problem(let p):
            phase = .problem(p)
            return
        case .ready(let t, let own):
            token = t
            ownDisplay = own
        }
        reloadToken = UUID()
        // 网页加载完成后 onLoaded 切换到实时画面；超时兜底
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        if phase == .connecting { phase = .live }
    }

    private func reload() {
        Task { await start() }
    }

    private func restartDesktop() {
        phase = .connecting
        Task {
            do {
                try await connection.restartDesktop()
                show("桌面已重启")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await start()
            } catch {
                phase = .failed("重启桌面失败：\(error.localizedDescription)")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }

    /// 按顺序把输入发到云电脑（与 Agent 共用桌面锁）
    private func send(_ body: [String: Any], done: String? = nil) {
        let previous = sendChain
        sendChain = Task { @MainActor in
            await previous?.value
            do {
                var payload = body
                if ownDisplay, let botId { payload["bot_id"] = botId }
                _ = try await connection.request(method: "POST", path: "/v1/desktop/input", body: payload)
                if let done { show(done) }
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func pasteClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            show("剪贴板没有文字")
            return
        }
        send(["action": "type", "text": String(text.prefix(10000))], done: "已粘贴到云电脑")
    }

    private func forwardKeyboard(_ value: String) {
        guard value != Self.sentinel else { return }
        if value.count < Self.sentinel.count || !value.hasPrefix(Self.sentinel) {
            send(["action": "key", "key": "BackSpace"])
        } else {
            let typed = String(value.dropFirst(Self.sentinel.count))
            if !typed.isEmpty { send(["action": "type", "text": typed]) }
        }
        keyboardText = Self.sentinel
    }

    private func finished() {
        guard let sessionId else { return }
        CloudComputerHandoff.finish(sessionId: sessionId)
        dismiss()
    }
}

struct CloudComputerHelpSheet: View {
    let reason: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let reason, !reason.isEmpty {
                    Section("Bot 需要你做的事") { Text(reason) }
                }
                Section("这是什么") {
                    Text("这是 Bot 在你的 VPS 上使用的云电脑桌面，画面是实时的。Bot 浏览网页、点按钮都在这里进行。")
                }
                Section("怎么接管") {
                    Label("点一下 = 鼠标点击，拖动 = 拖拽，双指缩放查看细节", systemImage: "hand.tap")
                    Label("右下角键盘按钮：弹出键盘，输入会发送到云电脑", systemImage: "keyboard")
                    Label("左下角剪贴板按钮：把手机剪贴板里的文字粘贴过去", systemImage: "doc.on.clipboard")
                    Label("完成登录、验证码等步骤后点「我完成了」，Bot 会继续工作", systemImage: "checkmark.circle")
                }
                Section {
                    Text("密码只在云电脑里输入，不会发给 Bot 或保存在对话里。需要时可在 … 菜单开启「仅查看」，避免误触。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("云电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// noVNC 画面：只允许访问本机桌面隧道端口；加载完成回调；允许双指缩放
struct CloudComputerWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    let onLoaded: () -> Void
    var onState: (String) -> Void = { _ in }

    final class Coordinator: DesktopNavigationCoordinator {
        var onLoaded: (() -> Void)?
        let bridge = CloudNoVNCBridge()
        @objc func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.onLoaded?() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        context.coordinator.bridge.onState = onState
        CloudNoVNCBridge.install(on: config, bridge: context.coordinator.bridge)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 4
        web.scrollView.bouncesZoom = true
        context.coordinator.onLoaded = onLoaded
        context.coordinator.allowedPort = url.port ?? 18766
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.bridge.load(url, in: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onLoaded = onLoaded
        context.coordinator.bridge.onState = onState
        if context.coordinator.lastReloadToken != reloadToken || context.coordinator.bridge.current != url {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.allowedPort = url.port ?? 18766
            context.coordinator.bridge.load(url, in: web)
        }
    }
}
