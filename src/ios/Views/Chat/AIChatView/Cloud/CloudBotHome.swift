//
//  CloudBotHome.swift
//  Minis - 多 Bot 模式首页（参考 Grok Bot）
//  主屏模式开关：本地模式保持原样；多 Bot 模式下首页是 Bot 列表——主 Bot 大头像置顶，
//  其他 Bot 按最近活动排序，每个 Bot 一条连续对话；进入时后台自动连接云电脑。
//

import Foundation
import SwiftUI
import WidgetKit

enum CloudBotHome {
    /// 主屏模式（"local" / "bots"），跨启动保存
    static let modeKey = "OpenMinis_homeMode"
    static let initialsKey = "OpenMinis_userInitials"

    static let palette: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.93, green: 0.29, blue: 0.60),
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.30, green: 0.73, blue: 0.64),
        Color(red: 0.97, green: 0.60, blue: 0.17), Color(red: 0.39, green: 0.40, blue: 0.95),
        Color(red: 0.20, green: 0.70, blue: 0.40), Color(red: 0.94, green: 0.36, blue: 0.30),
    ]

    static func color(for id: String) -> Color {
        var h: UInt32 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// 今天 HH:mm，昨天，7 天内星期X，更早 M/d
    static func timeText(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            return "昨天"
        } else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateFormat = "M/d"
        }
        return f.string(from: date)
    }
}

@MainActor
final class CloudBotHomeModel: ObservableObject {
    static let shared = CloudBotHomeModel()
    @Published private(set) var bots: [CloudBot] = []
    @Published private(set) var groups: [CloudGroup] = []
    @Published private(set) var loaded = false
    @Published private(set) var connecting = false
    @Published var bannerText: String?
    /// 外部入口（小组件、Siri、分享、委托卡片）要打开的 Bot id 或 "group:<id>"；首页收到后进入对话
    @Published var pendingOpen: String?
    /// 外部入口带来的文字 / 附件：对应 Bot 的对话打开时取走
    var pendingPrompt: CloudBotPendingPrompt?
    /// 分享进来的内容还没选 Bot：首页弹出选择表
    @Published var showSharePicker = false
    /// 值班模式到什么时候（服务器 resources.duty_until）；nil = 没在值班
    @Published private(set) var dutyUntil: Date?
    /// 「今日」：最近 24 小时例行任务和主动消息的结果（服务器 /v1/feed）
    @Published private(set) var feed: [CloudFeedItem] = []

    func setDuty(hours: Double?) async {
        let until: Double
        if let hours { until = Date().addingTimeInterval(hours * 3600).timeIntervalSince1970 } else { until = 0 }
        do {
            _ = try await CloudQuiet.retry { try await CloudConnection.shared.request(method: "PUT", path: "/v1/resources", body: ["duty_until": until]) }
            dutyUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
            CloudHaptics.success()
        } catch {
            bannerText = "值班模式没设置成功：\(error.localizedDescription.prefix(80))"
        }
    }

    /// 到明早 8 点的小时数（夜班下班）
    static func hoursUntilMorning() -> Double {
        let cal = Calendar.current
        var target = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        if target <= Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return target.timeIntervalSinceNow / 3600
    }

    func deliverShare(to botId: String) {
        pendingPrompt?.botId = botId
        showSharePicker = false
        pendingOpen = botId
    }

    func takePrompt(for botId: String) -> CloudBotPendingPrompt? {
        guard let p = pendingPrompt, p.botId == botId else { return nil }
        pendingPrompt = nil
        return p
    }
    private var seen: [String: Double]

    private init() {
        seen = UserDefaults.standard.dictionary(forKey: "OpenMinisCloud_botSeen") as? [String: Double] ?? [:]
        bots = CloudBotService.cachedList()
        if !bots.isEmpty { loaded = true; publishToWidget() }
    }

    var primary: CloudBot? { bots.first(where: { $0.isPrimary }) }

    /// 主屏幕小组件「云端 Bot」读 App Group 里的列表（主 Bot 在前，最多 4 个）；有变化才刷新小组件
    private func publishToWidget() {
        guard let shared = UserDefaults(suiteName: "group.com.openminis.app") else { return }
        let ordered = bots.filter { $0.isPrimary } + bots.filter { !$0.isPrimary }
        let list: [[String: String]] = ordered.prefix(4).map { b in
            ["id": b.id, "name": b.name, "emoji": CloudBotAvatarSpec.of(b).emoji ?? ""]
        }
        if (shared.array(forKey: "OpenMinisCloud_widgetBots") as? [[String: String]]) != list {
            shared.set(list, forKey: "OpenMinisCloud_widgetBots")
            WidgetCenter.shared.reloadTimelines(ofKind: "CloudBotsWidget")
        }
    }

    func others(matching query: String) -> [CloudBot] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bots.filter { !$0.isPrimary }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.lastPreview.lowercased().contains(q) || $0.id.contains(q) }
            .sorted { $0.lastAt != $1.lastAt ? $0.lastAt > $1.lastAt : $0.name < $1.name }
    }

    func isUnread(_ bot: CloudBot) -> Bool {
        bot.lastRole == "assistant" && bot.lastAt > (seen[bot.id] ?? 0) + 0.5
    }

    func markSeen(_ botId: String) {
        let at = bots.first(where: { $0.id == botId })?.lastAt ?? 0
        seen[botId] = max(Date().timeIntervalSince1970, at)
        UserDefaults.standard.set(seen, forKey: "OpenMinisCloud_botSeen")
        objectWillChange.send()
    }

    func bot(_ id: String) -> CloudBot? { bots.first(where: { $0.id == id }) }
    func botId(forSession sid: String) -> String? { bots.first(where: { $0.latestSessionId == sid })?.id }

    /// 后台自动连接（复用已保存的连接信息）后刷新 Bot 列表。连接问题交给 CloudLinkSupervisor 静默重连，
    /// 首页先显示上次的列表；只有非连接类错误才显示横幅。forceReconnect：用户点了重试，拆掉旧隧道重建。
    func refresh(forceReconnect: Bool = false) async {
        let conn = CloudConnection.shared
        let link = CloudLinkSupervisor.shared
        guard conn.canAutoConnect || conn.isConnected else {
            bannerText = "还没有连接云电脑：点左上角头像 › 云电脑设置，填写 VPS 并安装服务"
            loaded = true
            return
        }
        connecting = !conn.isConnected
        do {
            if forceReconnect { try await conn.reconnect() } else { try await conn.ensureConnected() }
        } catch {
            connecting = false
            bannerText = nil
            link.handle(.requestFailed)      // 横幅由连接守护在静默重试失败后显示
            loaded = true
            return
        }
        connecting = false
        link.handle(.pageOpened)
        do {
            bots = try await CloudQuiet.retry { try await CloudBotService.list() }
            bannerText = nil
            publishToWidget()
            // 旧版服务器没有群聊接口：忽略错误
            groups = (try? await CloudGroupService.list()) ?? groups
            if let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/resources"),
               let until = (r["settings"] as? [String: Any])?["duty_until"] as? Double {
                dutyUntil = until > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: until) : nil
            }
            // 旧服务器没有 /v1/feed：保持空
            if let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/feed"),
               let items = r["items"] as? [[String: Any]] {
                feed = items.compactMap(CloudFeedItem.init)
            }
        } catch let error as URLError where CloudConnection.tunnelDropped(error) {
            bannerText = nil
            link.handle(.requestFailed)
        } catch {
            bannerText = "读取 Bot 失败：\(error.localizedDescription.prefix(160))"
        }
        loaded = true
    }
}

/// Bot 头像：保存的形状与颜色（见 CloudBotAvatar.swift），未设置时按 ID 生成；主 Bot 默认黑色。
struct CloudBotBlobAvatar: View {
    let bot: CloudBot
    var size: CGFloat = 46
    var dark = false

    var body: some View {
        // 首页列表里的头像也会眨眼、跟着手指看
        CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bot.name)
    }
}

struct CloudBotHomeRow: View {
    let bot: CloudBot
    let unread: Bool

    var body: some View {
        let status = CloudBotStatus.of(bot)
        HStack(spacing: 14) {
            Group {
                if status == .working {
                    CloudBotLivelyAvatar(spec: CloudBotAvatarSpec.of(bot), size: 46)
                } else {
                    // 列表里的头像也跟着手指看，并按状态换表情
                    CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: 46, mood: CloudBotMood.of(status, unread: unread))
                }
            }
            .frame(width: 46, height: 50)
            .accessibilityLabel(bot.name)
                .overlay(alignment: .bottomTrailing) {
                    if status.busy {
                        Circle().fill(status.color)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bot.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(CloudBotHome.timeText(bot.lastAt)).font(.footnote).foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    if status.busy { CloudBotStatusChip(status: status) }
                    Text(previewText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if unread {
                        Circle().fill(Color.blue).frame(width: 9, height: 9)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var previewText: String {
        if CloudBotLock.shared.isLocked(bot.id) { return "已上锁" }
        if bot.waitingApprovals > 0 && bot.lastPreview.isEmpty { return "等你处理" }
        if bot.runningTasks > 0 && bot.lastPreview.isEmpty { return "正在处理…" }
        if !bot.lastPreview.isEmpty { return bot.lastPreview }
        return bot.summary.isEmpty ? "开始对话" : bot.summary
    }
}

struct CloudBotHomeScreen: View {
    let onOpenSettings: () -> Void
    let onSwitchToLocal: () -> Void
    @ObservedObject private var model = CloudBotHomeModel.shared
    @AppStorage(CloudBotHome.initialsKey) private var initials: String = "我"
    @State private var path: [String] = []
    @State private var search = ""
    @StateObject private var searchModel = CloudSearchModel()
    @State private var showCreate = false
    @State private var showCreateGroup = false
    @State private var showHub = false
    @State private var showConnectApps = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        CloudLinkBanner(onOpenSettings: onOpenSettings)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                        if let until = model.dutyUntil, until > Date() {
                            HStack(spacing: 8) {
                                Image(systemName: "cross.case.fill").foregroundStyle(.red)
                                Text("值班中 · 到 \(until.formatted(date: .omitted, time: .shortened))：回答极简，不推送主动消息")
                                    .font(.footnote)
                                Spacer()
                                Button("结束") { Task { await model.setDuty(hours: nil) } }.font(.footnote)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 16)
                        }
                        if let banner = model.bannerText {
                            Button { Task { await model.refresh(forceReconnect: true) } } label: {
                                Text(banner + "（点此重试）")
                                    .font(.footnote).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        if model.connecting && model.bots.isEmpty {
                            Text("正在连接云电脑…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                        }
                        if let primary = model.primary, search.isEmpty {
                            hero(primary)
                        }
                        if search.isEmpty && model.feed.contains(where: { !CloudBotLock.shared.isLocked($0.botId) }) {
                            CloudTodayFeed(items: model.feed.filter { !CloudBotLock.shared.isLocked($0.botId) }, bots: model.bots)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(groupsMatching) { g in
                                Button { path = ["group:" + g.id] } label: {
                                    CloudGroupHomeRow(group: g, bots: model.bots)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
                            }
                            ForEach(model.others(matching: search)) { bot in
                                Button { open(bot.id) } label: {
                                    CloudBotHomeRow(bot: bot, unread: model.isUnread(bot))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
                            }
                        }
                        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                            CloudSearchResultsSection(model: searchModel, query: search) { target in
                                if target.hasPrefix("group:") { path = [target] } else { open(target) }
                            }
                        }
                        if model.loaded && model.bots.isEmpty && model.bannerText == nil {
                            VStack(spacing: 12) {
                                Text("还没有 Bot").font(.headline)
                                Text("每个 Bot 有自己的指令、记忆、插件和一条连续对话。").font(.subheadline).foregroundStyle(.secondary)
                                Button("从模板创建") { showCreate = true }.buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 60)
                        }
                        Color.clear.frame(height: 90)
                    }
                }
                .refreshable { await model.refresh() }
                .scrollDismissesKeyboard(.interactively)
                bottomBar
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { avatarMenu }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 2) {
                        Menu {
                            modeButtons
                        } label: {
                            HStack(spacing: 3) {
                                Text("多 Bot").font(.caption.weight(.semibold))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        CloudLinkDot(onOpenSettings: onOpenSettings)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCreate = true } label: { Label("新 Bot", systemImage: "person.crop.circle.badge.plus") }
                        Button { showCreateGroup = true } label: { Label("新群聊", systemImage: "person.3") }
                            .disabled(model.bots.isEmpty)
                        Menu {
                            Button("8 小时") { Task { await model.setDuty(hours: 8) } }
                            Button("12 小时") { Task { await model.setDuty(hours: 12) } }
                            Button("到明早 8 点") { Task { await model.setDuty(hours: CloudBotHomeModel.hoursUntilMorning()) } }
                            if model.dutyUntil != nil {
                                Button("结束值班", role: .destructive) { Task { await model.setDuty(hours: nil) } }
                            }
                        } label: { Label(model.dutyUntil == nil ? "值班模式" : "值班中…", systemImage: "cross.case") }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建")
                }
            }
            .navigationDestination(for: String.self) { id in
                if id.hasPrefix("group:") {
                    CloudGroupChatView(groupId: String(id.dropFirst(6)))
                } else {
                    CloudBotChatView(botId: id)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CloudBotCreateSheet(onCreated: { id in
                await model.refresh()
                if !id.isEmpty { open(id) }
            })
        }
        .sheet(isPresented: $showCreateGroup) {
            CloudGroupCreateSheet(onCreated: { id in
                await model.refresh()
                if !id.isEmpty { path = ["group:" + id] }
            })
        }
        .sheet(isPresented: $model.showSharePicker, onDismiss: {
            // 没选就关掉：丢弃这次分享，不要留到下一次打开对话
            if model.pendingPrompt?.botId == nil { model.pendingPrompt = nil }
        }) {
            CloudShareBotPicker(prompt: model.pendingPrompt, bots: model.bots) { model.deliverShare(to: $0) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showHub) {
            NavigationStack { CloudBotHubView(onDone: { showHub = false }) }
        }
        .sheet(isPresented: $showConnectApps) {
            CloudConnectAppsSheet(onClose: { showConnectApps = false })
                .presentationDetents([.large])
        }
        .onChange(of: model.pendingOpen) { target in
            guard let target else { return }
            model.pendingOpen = nil
            if path == [target] {
                // 已经在这个对话里：退出再进，让对话页取走新的文字
                path = []
                Task { @MainActor in try? await Task.sleep(nanoseconds: 350_000_000); path = [target] }
            } else {
                path = [target]
            }
        }
        .task {
            CloudTouchTracker.shared.install()
            if let target = model.pendingOpen { model.pendingOpen = nil; path = [target] }
            // 进入多 Bot 模式即后台连接并定期刷新（列表的运行 / 待审批 / 未读状态）
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private var groupsMatching: [CloudGroup] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.groups.filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.lastContent ?? "").lowercased().contains(q) }
    }

    private func open(_ id: String) {
        CloudHaptics.tap()
        model.markSeen(id)
        path = [id]
    }

    private func hero(_ bot: CloudBot) -> some View {
        Button { open(bot.id) } label: {
            VStack(spacing: 10) {
                CloudBotAliveAvatar(spec: CloudBotAvatarSpec.of(bot), size: 96)
                    .overlay(alignment: .bottomTrailing) {
                        ZStack {
                            Circle().fill(Color(.systemBackground)).frame(width: 30, height: 30)
                            Circle().fill(Color.orange).frame(width: 24, height: 24)
                            Image(systemName: "star.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                        .offset(x: 4, y: 4)
                    }
                    .overlay(alignment: .topTrailing) {
                        if model.isUnread(bot) { Circle().fill(Color.blue).frame(width: 12, height: 12) }
                    }
                Text(bot.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                let status = CloudBotStatus.of(bot)
                if status.busy { CloudBotStatusChip(status: status) }
            }
            .padding(.top, 8).padding(.bottom, 18)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modeButtons: some View {
        Button { onSwitchToLocal() } label: { Label("本地模式", systemImage: "iphone") }
        Button {} label: { Label("多 Bot 模式 ✓", systemImage: "person.3.fill") }
    }

    private var avatarMenu: some View {
        Menu {
            Button { onOpenSettings() } label: { Label("设置", systemImage: "gear") }
            Button { showHub = true } label: { Label("云电脑与 Bot 管理", systemImage: "square.grid.2x2") }
            Divider()
            Button { onSwitchToLocal() } label: { Label("切换到本地模式", systemImage: "iphone") }
        } label: {
            Text(String(initials.prefix(2)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { showConnectApps = true } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(.regularMaterial))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .accessibilityLabel("连接应用")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 Bot 与聊天记录", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: search) { q in searchModel.update(q) }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Capsule().fill(.regularMaterial))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// 左下角入口：Bot 管理、插件、例行任务、记忆、页面、云电脑设置
struct CloudBotHubView: View {
    let onDone: () -> Void

    var body: some View {
        List {
            Section {
                NavigationLink(destination: CloudBotsView()) { Label("我的 Bot（模板、导入导出）", systemImage: "person.3") }
                NavigationLink(destination: CloudPluginsView()) { Label("插件市场", systemImage: "puzzlepiece.extension") }
                NavigationLink(destination: CloudRoutinesView()) { Label("例行任务", systemImage: "clock.arrow.circlepath") }
                NavigationLink(destination: CloudMemoryTimelineView()) { Label("云端记忆", systemImage: "brain") }
                NavigationLink(destination: CloudSkillsView()) { Label("技能", systemImage: "wand.and.stars") }
                NavigationLink(destination: CloudDelegationsView()) { Label("委托记录", systemImage: "arrow.triangle.branch") }
                NavigationLink(destination: CloudPagesView()) { Label("页面", systemImage: "doc.richtext") }
                NavigationLink(destination: CloudComputerView(botId: nil, sessionId: nil, reason: nil)) { Label("云电脑桌面", systemImage: "display") }
            }
            Section {
                NavigationLink(destination: CloudUsageView()) { Label("用量与每日上限", systemImage: "chart.bar") }
                NavigationLink(destination: CloudBackupView()) { Label("备份与恢复", systemImage: "externaldrive") }
                NavigationLink(destination: CloudAgentSettingsView()) { Label("云电脑设置", systemImage: "server.rack") }
            }
        }
        .navigationTitle("云电脑与 Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { onDone() } } }
    }
}

/// 某个 Bot 的唯一对话（像 Grok Bot 一样每个 Bot 一条连续对话）；菜单里可开新对话或切换历史。
struct CloudBotChatView: View {
    let botId: String
    @ObservedObject private var model = CloudBotHomeModel.shared
    @State private var sessionId: String?
    @State private var history: [[String: Any]] = []
    @State private var errorText: String?
    @State private var showDetail = false
    @State private var showComputer = false

    @ObservedObject private var lock = CloudBotLock.shared
    /// 当前是无痕对话时记下它和之前的对话，结束后删掉并回到原来的对话
    @State private var incognito: (id: String, previous: String?)?

    var body: some View {
        Group {
            if let bot = model.bot(botId), lock.needsUnlock(botId) {
                CloudBotLockedView(bot: bot)
            } else if let sid = sessionId, let bot = model.bot(botId) {
                CloudSessionView(sessionId: sid, sessionTitle: bot.name,
                                 model: UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "",
                                 selectedInstanceId: UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "",
                                 botHasOwnModel: bot.hasOwnModel,
                                 mentionBots: model.bots.filter { $0.id != botId },
                                 theme: CloudBotChatTheme(bot: bot))
                    .id(sid)
                    .safeAreaInset(edge: .top) {
                        if incognito?.id == sid {
                            HStack(spacing: 8) {
                                Image(systemName: "eye.slash")
                                Text("无痕对话 · 不写入记忆，离开后删除").font(.caption)
                                Spacer()
                                Button("结束") { endIncognito(restore: true) }.font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.regularMaterial)
                        }
                    }
            } else if let errorText {
                VStack(spacing: 12) {
                    Text(errorText).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("重试") { Task { await prepare() } }.buttonStyle(.bordered)
                }
                .padding()
            } else {
                ProgressView("正在打开对话…")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let bot = model.bot(botId) {
                    Button { showDetail = true } label: {
                        HStack(spacing: 8) {
                            CloudBotBlobAvatar(bot: bot, size: 26, dark: bot.isPrimary)
                                .overlay(alignment: .bottomTrailing) {
                                    if CloudConnection.shared.isConnected {
                                        Circle().fill(Color.green).frame(width: 9, height: 9)
                                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                            .offset(x: 2, y: 2)
                                    }
                                }
                            Text(bot.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                        }
                        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 5)
                        .background(Capsule().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(bot.name) 资料")
                    .contextMenu {
                        Button { Task { await startNew() } } label: { Label("新对话", systemImage: "square.and.pencil") }
                        if incognito == nil {
                            Button { Task { await startIncognito() } } label: { Label("无痕对话", systemImage: "eye.slash") }
                        }
                        if let sid = sessionId {
                            Button { speakLatest(sid) } label: { Label("朗读最新回复", systemImage: "speaker.wave.2") }
                            Button { showComputer = true } label: { Label("电脑", systemImage: "display") }
                        }
                        if history.count > 1 {
                            Section("历史对话") {
                                ForEach(history.indices, id: \.self) { i in
                                    let sid = history[i]["session_id"] as? String ?? ""
                                    Button(history[i]["title"] as? String ?? sid) { endIncognito(restore: false); sessionId = sid }
                                }
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // … 打开 Bot 资料页；新对话 / 历史 / 朗读 / 电脑 在长按标题的菜单里
                Button { showDetail = true } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Bot 资料")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showComputer) {
            CloudComputerView(botId: botId, sessionId: sessionId, reason: nil)
        }
        .navigationDestination(isPresented: $showDetail) {
            if let bot = model.bot(botId) {
                CloudBotDetailView(bot: bot, onChanged: { await model.refresh() })
            }
        }
        .task { await prepare() }
        .onDisappear { model.markSeen(botId); CloudBotSpeaker.stop()
            // 推到电脑 / 资料页时也会触发 onDisappear：这时不结束无痕
            if !showComputer && !showDetail { endIncognito(restore: true) }
        }
    }

    private func speakLatest(_ sid: String) {
        Task {
            guard let detail = try? await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(sid)", body: nil) else { return }
            let messages = detail["messages"] as? [[String: Any]] ?? []
            if let text = messages.last(where: { $0["role"] as? String == "assistant" && !(($0["content"] as? String) ?? "").isEmpty })?["content"] as? String {
                CloudBotSpeaker.speak(text, botId: botId)
            }
        }
    }

    private func prepare() async {
        errorText = nil
        do {
            try await CloudQuiet.retry { try await CloudConnection.shared.ensureConnected() }
            if model.bot(botId) == nil { await model.refresh() }
            guard let bot = model.bot(botId) else {
                errorText = "找不到这个 Bot，可能已被删除"
                return
            }
            history = (try? await CloudBotService.sessions(botId)) ?? []
            if sessionId == nil {
                if let latest = bot.latestSessionId {
                    sessionId = latest
                } else {
                    sessionId = try await CloudQuiet.retry(2) { try await CloudBotService.newSession(bot) }
                }
            }
            model.markSeen(botId)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func startIncognito() async {
        guard let bot = model.bot(botId) else { return }
        do {
            let sid = try await CloudQuiet.retry(2) { try await CloudBotService.newIncognitoSession(bot) }
            guard !sid.isEmpty else { return }
            incognito = (sid, sessionId)
            sessionId = sid
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func endIncognito(restore: Bool) {
        guard let current = incognito else { return }
        incognito = nil
        if restore, sessionId == current.id { sessionId = current.previous }
        Task { await CloudBotService.deleteIncognito(current.id) }
    }

    private func startNew() async {
        endIncognito(restore: false)
        guard let bot = model.bot(botId) else { return }
        do {
            sessionId = try await CloudBotService.newSession(bot)
            history = (try? await CloudBotService.sessions(botId)) ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct CloudFeedItem: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let title: String
    let botId: String
    let proactive: Bool
    let text: String
    let at: Date

    init?(_ d: [String: Any]) {
        guard let id = d["run_id"] as? String, let text = d["text"] as? String, !text.isEmpty else { return nil }
        self.id = id
        sessionId = d["session_id"] as? String ?? ""
        title = d["title"] as? String ?? ""
        botId = d["bot_id"] as? String ?? ""
        proactive = d["proactive"] as? Bool ?? false
        self.text = text
        at = Date(timeIntervalSince1970: d["at"] as? Double ?? 0)
    }
}

/// 首页「今日」卡片：最近 24 小时 Bot 主动找你和例行任务的结果，默认显示 3 条
struct CloudTodayFeed: View {
    let items: [CloudFeedItem]
    let bots: [CloudBot]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日").font(.headline)
                Spacer()
                if items.count > 3 {
                    Button(expanded ? "收起" : "全部 \(items.count) 条") { withAnimation { expanded.toggle() } }.font(.caption)
                }
            }
            ForEach(expanded ? items : Array(items.prefix(3))) { item in
                row(item)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func row(_ item: CloudFeedItem) -> some View {
        let bot = bots.first { $0.id == item.botId }
        let content = HStack(alignment: .top, spacing: 10) {
            if let bot {
                CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 26)
            } else {
                Image(systemName: "clock.arrow.circlepath").frame(width: 26, height: 26).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.proactive ? "\(bot?.name ?? "Bot") 找你" : item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(item.at, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                Text(CloudMessageText.display(item.text).text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        if item.sessionId.isEmpty {
            content
        } else {
            NavigationLink {
                CloudSessionView(sessionId: item.sessionId, sessionTitle: item.proactive ? (bot?.name ?? item.title) : item.title,
                                 model: UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "",
                                 selectedInstanceId: UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "",
                                 botHasOwnModel: bot?.hasOwnModel ?? false, theme: bot.map { CloudBotChatTheme(bot: $0) })
            } label: { content }
            .buttonStyle(.plain)
        }
    }
}
