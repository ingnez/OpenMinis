//
//  CloudBotHome.swift
//  Minis - 多 Bot 模式首页（参考 Grok Bot）
//  主屏模式开关：本地模式保持原样；多 Bot 模式下首页是 Bot 列表——主 Bot 大头像置顶，
//  其他 Bot 按最近活动排序，每个 Bot 一条连续对话；进入时后台自动连接云电脑。
//

import Foundation
import SwiftUI
import UIKit
import WidgetKit

enum CloudBotHome {
    /// 主屏模式（"local" / "bots"），跨启动保存
    static let modeKey = "OpenMinis_homeMode"

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
    /// 首页分组（服务器保存）
    @Published var sections: [CloudBotSection] = []
    /// 外部入口（小组件、Siri、分享、委托卡片）要打开的 Bot id 或 "group:<id>"；首页收到后进入对话
    @Published var pendingOpen: String?
    /// 最近打开的 Bot（手表抬腕说话、控制中心没选 Bot 时用这个；不是分组 / 隐藏页）
    @Published var currentBotId: String? = UserDefaults.standard.string(forKey: "OpenMinisCloud_currentBot")

    func rememberCurrent(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        if id.hasPrefix("group:") || id.hasPrefix("nav:") || id.hasPrefix("page:") || id.hasPrefix("detail:") || id == "hidden" { return }
        if CloudBotThreadRules.parseRoute(id) != nil { return }
        currentBotId = id
        UserDefaults.standard.set(id, forKey: "OpenMinisCloud_currentBot")
    }

    func currentForWatch() -> String? {
        if let currentBotId, bots.contains(where: { $0.id == currentBotId }) { return currentBotId }
        return primary?.id ?? bots.first?.id
    }
    /// 外部入口带来的文字 / 附件：对应 Bot 的对话打开时取走
    var pendingPrompt: CloudBotPendingPrompt?
    /// 分享进来的内容还没选 Bot：首页弹出选择表
    @Published var showSharePicker = false
    /// 值班模式到什么时候（服务器 resources.duty_until）；nil = 没在值班
    @Published private(set) var dutyUntil: Date?
    /// 下班后的「错过了什么」（服务器 /v1/duty/digest）；看过点掉就不再显示
    @Published private(set) var dutyDigest: (id: Int, text: String)?

    func dismissDutyDigest() {
        if let d = dutyDigest { UserDefaults.standard.set(d.id, forKey: "OpenMinisCloud_dutyDigestSeen") }
        dutyDigest = nil
    }

    /// 考试倒计时（服务器 /v1/exams）
    @Published var exams: [CloudExam] = []
    /// 「今日」：最近 24 小时例行任务和主动消息的结果（服务器 /v1/feed）
    @Published private(set) var feed: [CloudFeedItem] = []

    func setDuty(hours: Double?) async {
        defer { if hours == nil { Task { await refresh() } } }   // 结束值班：马上拉「错过了什么」
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

    /// 「今日」小组件：只写没上锁的 Bot 的条目
    func publishFeedToWidget() {
        guard let shared = UserDefaults(suiteName: "group.com.openminis.app") else { return }
        let list: [[String: Any]] = feed.filter { !CloudBotLock.isLockedStored($0.botId) }.prefix(5).map { f in
            let name = bot(f.botId)?.name ?? "Bot"
            return ["title": f.proactive ? name + " 找你" : f.title, "text": CloudPreviewText.plain(CloudMessageText.display(f.text).text),
                    "at": f.at.timeIntervalSince1970, "bot_id": f.botId]
        }
        if (shared.array(forKey: "OpenMinisCloud_widgetFeed") as NSArray?) != (list as NSArray) {
            shared.set(list, forKey: "OpenMinisCloud_widgetFeed")
            WidgetCenter.shared.reloadTimelines(ofKind: "CloudTodayWidget")
        }
    }

    func others(matching query: String) -> [CloudBot] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let focus = CloudFocusFilter.active
        return bots.filter { !$0.isPrimary && (!$0.hidden || !q.isEmpty) }
            .filter { CloudFocusFilter.allows(name: $0.name, summary: $0.summary, instructions: $0.instructions,
                                              pinned: $0.pinned, searching: !q.isEmpty, on: focus,
                                              alwaysShow: CloudFocusFilter.isAlwaysShown($0.id)) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.lastPreview.lowercased().contains(q) || $0.id.contains(q) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                if $0.pinned && $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
                // 正在回复的排到最上面（当作「现在」）
                let l = CloudTypingRules.sortTime(lastAt: $0.lastAt, working: $0.activity != nil)
                let r = CloudTypingRules.sortTime(lastAt: $1.lastAt, working: $1.activity != nil)
                return l != r ? l > r : $0.name < $1.name
            }
    }

    var hiddenBots: [CloudBot] { bots.filter { $0.hidden } }

    /// 正在回复的 Bot（首页加快刷新、做完时轻震）
    var typingIds: Set<String> { Set(bots.filter { $0.activity != nil }.map(\.id)) }

    /// 有 Bot 在回复时的轻量刷新：只拉 Bot 列表（阶段、预览、计数），不动群聊、分组和资源
    func refreshBots() async {
        guard CloudConnection.shared.isConnected, let list = try? await CloudBotService.list() else { return }
        bots = list
        CloudWatchBridge.shared.publish(list, currentId: currentForWatch())
        CloudSpotlight.index(list)
    }

    /// 顶部一排大头像：主 Bot + 置顶的 Bot（隐藏的不算）
    var topRow: [CloudBot] {
        let pinned = bots.filter { $0.pinned && !$0.isPrimary && !$0.hidden }.sorted { $0.pinnedAt > $1.pinnedAt }
        return bots.filter { $0.isPrimary && !$0.hidden } + pinned
    }

    /// 列表：搜索时全部匹配；平时去掉主 Bot、置顶（已在顶部）和隐藏的
    func listed(matching query: String) -> [CloudBot] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return others(matching: query).filter { !q.isEmpty || !$0.pinned }
    }

    func sectionAction(_ op: String, _ section: CloudBotSection? = nil, name: String? = nil, botId: String? = nil) {
        Task {
            do {
                let conn = CloudConnection.shared
                switch op {
                case "create":
                    var body: [String: Any] = ["name": name ?? "新分组"]
                    if let botId { body["bot_id"] = botId }
                    _ = try await CloudQuiet.retry { try await conn.request(method: "POST", path: "/v1/bot_sections", body: body) }
                case "rename":
                    guard let section, let name else { return }
                    _ = try await CloudQuiet.retry { try await conn.request(method: "PUT", path: "/v1/bot_sections/\(section.id)", body: ["name": name]) }
                case "toggle":
                    guard let section else { return }
                    if let i = sections.firstIndex(where: { $0.id == section.id }) { sections[i].collapsed.toggle() }
                    _ = try await CloudQuiet.retry {
                        try await conn.request(method: "PUT", path: "/v1/bot_sections/\(section.id)", body: ["collapsed": !section.collapsed])
                    }
                case "delete":
                    guard let section else { return }
                    _ = try await CloudQuiet.retry { try await conn.request(method: "DELETE", path: "/v1/bot_sections/\(section.id)", body: nil) }
                case "move":
                    guard let botId else { return }
                    _ = try await CloudQuiet.retry {
                        try await CloudBotService.setPrefs(botId, ["section_id": section.map { $0.id as Any } ?? NSNull()])
                    }
                default: return
                }
            } catch {
                bannerText = "分组没保存成功：\(error.localizedDescription)"
            }
            await refresh()
        }
    }

    /// 首页状态：服务器真实状态 + 手机这边的已读 + 连接状态（见 CloudBotPresence）
    func presence(_ bot: CloudBot) -> CloudBotPresence {
        var connected = true
        if case .offline = CloudLinkSupervisor.shared.state { connected = false }
        return CloudBotPresence.derive(.init(connected: connected, waitingApprovals: bot.waitingApprovals, pendingCards: bot.pendingCards,
                                             lastTaskStatus: bot.lastTaskStatus, runningTasks: bot.runningTasks, queuedTasks: bot.queuedTasks,
                                             runningWorkers: bot.runningWorkers, unreadCount: bot.unreadCount, locallyUnread: isUnread(bot),
                                             routinesEnabled: bot.routinesEnabled, routineRunning: bot.routineRunning, notify: bot.notify))
    }

    func isUnread(_ bot: CloudBot) -> Bool {
        bot.markedUnread || (bot.lastRole == "assistant" && bot.lastAt > max(seen[bot.id] ?? 0, bot.seenAt) + 0.5)
    }

    /// 长按菜单改设置：先改本机显示，再交给服务器；失败静默重试，最后才提示
    func setPrefs(_ botId: String, _ body: [String: Any]) {
        if let i = bots.firstIndex(where: { $0.id == botId }) {
            if let v = body["pinned"] as? Bool { bots[i].pinned = v; if v { bots[i].pinnedAt = Date().timeIntervalSince1970 } }
            if let v = body["hidden"] as? Bool { bots[i].hidden = v }
            if let v = body["unread"] as? Bool { bots[i].markedUnread = v }
            if let v = body["seen_at"] as? Double { bots[i].seenAt = max(bots[i].seenAt, v) }
        }
        if body["unread"] as? Bool == true { seen[botId] = 0; UserDefaults.standard.set(seen, forKey: "OpenMinisCloud_botSeen") }
        Task {
            do {
                _ = try await CloudQuiet.retry { try await CloudBotService.setPrefs(botId, body) }
            } catch {
                bannerText = "没能保存到云端：\(error.localizedDescription)"
            }
        }
    }

    func markUnread(_ botId: String, _ unread: Bool) {
        if unread {
            setPrefs(botId, ["unread": true])
        } else {
            markSeen(botId)
        }
    }

    /// 换主 Bot：服务器一次事务里转移主 Bot（管理权限跟着走），并记进操作记录
    func makePrimary(_ botId: String) async {
        do {
            try await CloudQuiet.retry { try await CloudBotService.update(botId, ["is_primary": true]) }
            CloudHaptics.success()
        } catch {
            bannerText = "替换主 Bot 失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func rename(_ botId: String, to name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let i = bots.firstIndex(where: { $0.id == botId }) { bots[i].name = n }
        do {
            try await CloudQuiet.retry { try await CloudBotService.update(botId, ["name": n]) }
        } catch {
            bannerText = "重命名失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func softDelete(_ botId: String) async {
        do {
            try await CloudQuiet.retry { try await CloudBotService.softDelete(botId) }
            bots.removeAll { $0.id == botId }
            CloudHaptics.success()
        } catch {
            bannerText = "删除失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    /// 长按菜单的 /reset：给这个 Bot 最近的对话存快照并清上下文（用 Bot 自己的模型，没有就按规则整理）
    func resetContext(_ botId: String) async {
        guard let sid = bot(botId)?.latestSessionId else { return }
        do {
            _ = try await CloudQuiet.retry {
                try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/\(sid)/reset", body: [:])
            }
            CloudHaptics.success()
        } catch {
            bannerText = "重置失败：\(error.localizedDescription)"
        }
    }

    func markSeen(_ botId: String) {
        let at = bots.first(where: { $0.id == botId })?.lastAt ?? 0
        seen[botId] = max(Date().timeIntervalSince1970, at)
        if let b = bots.first(where: { $0.id == botId }), b.markedUnread || b.seenAt < at {
            setPrefs(botId, ["unread": false, "seen_at": seen[botId] ?? at])
        }
        UserDefaults.standard.set(seen, forKey: "OpenMinisCloud_botSeen")
        objectWillChange.send()
    }

    func bot(_ id: String) -> CloudBot? { bots.first(where: { $0.id == id }) }
    func botId(forSession sid: String) -> String? { bots.first(where: { $0.latestSessionId == sid })?.id }

    /// 后台自动连接（复用已保存的连接信息）后刷新 Bot 列表。连接问题交给 CloudLinkSupervisor 静默重连，
    /// 首页先显示上次的列表；只有非连接类错误才显示横幅。forceReconnect：用户点了重试，拆掉旧隧道重建。
    /// 预取前几个 Bot 最近的对话存进手机缓存，点开时直接显示（缓存 1 分钟内的不重取）
    private var prefetching = false
    func prefetchChats(limit: Int = 6) {
        guard !prefetching else { return }
        let targets = bots.filter { !CloudBotLock.isLockedStored($0.id) }.compactMap(\.latestSessionId)
            .filter { (CloudChatCache.age($0) ?? .infinity) > 60 }.prefix(limit)
        guard !targets.isEmpty else { return }
        prefetching = true
        Task { @MainActor in
            defer { prefetching = false }
            for sid in targets {
                guard let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(sid)"),
                      (r["incognito"] as? Bool) != true else { continue }
                CloudChatCache.save(sid, messages: r["messages"] as? [[String: Any]] ?? [], tasks: r["tasks"] as? [[String: Any]] ?? [])
            }
        }
    }

    func refresh(forceReconnect: Bool = false) async {
        let conn = CloudConnection.shared
        let link = CloudLinkSupervisor.shared
        guard conn.canAutoConnect || conn.isConnected else {
            bannerText = "还没有连接云电脑：点左上角齿轮 › 云电脑设置，填写 VPS 并点「安装 / 更新服务器 Agent 服务」"
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
            CloudWatchBridge.shared.publish(bots, currentId: currentForWatch())
            CloudSpotlight.index(bots)
            CloudBotLock.shared.lockSecretHoldersByDefault(bots)
            bannerText = nil
            publishToWidget()
            prefetchChats()
            // 旧版服务器没有群聊接口：忽略错误
            groups = (try? await CloudGroupService.list()) ?? groups
            if let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/bot_sections"),
               let items = r["sections"] as? [[String: Any]] {
                sections = items.compactMap(CloudBotSection.init)
            }
            if let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/resources") {
                let settings = r["settings"] as? [String: Any] ?? [:]
                if let until = settings["duty_until"] as? Double {
                    dutyUntil = until > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: until) : nil
                }
                if dutyUntil == nil, let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/duty/digest"),
                   let d = r["digest"] as? [String: Any], let id = d["id"] as? Int, let text = d["text"] as? String,
                   id != UserDefaults.standard.integer(forKey: "OpenMinisCloud_dutyDigestSeen"),
                   Date().timeIntervalSince1970 - ((d["ended"] as? Double) ?? 0) < 18 * 3600 {
                    dutyDigest = (id, text)
                } else if dutyUntil != nil {
                    dutyDigest = nil
                }
                // 云端记录的上锁 Bot 和本机不一致（比如重装了云端）就再同步一次
                let lock = CloudBotLock.shared
                if let serverLocked = settings["private_bots"] as? [String], Set(serverLocked) != lock.locked {
                    Task { await lock.syncToServer() }
                }
            }
            exams = await CloudExamService.list() ?? exams
            // 旧服务器没有 /v1/feed：保持空
            if let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/feed"),
               let items = r["items"] as? [[String: Any]] {
                feed = items.compactMap(CloudFeedItem.init)
                publishFeedToWidget()
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
    var presence = CloudBotPresence(state: .idle, unread: 0, routine: .none, muted: false)
    /// 头像跟着系统字号一起变大，但不超过 60pt（首页一行一个 Bot，太大挤掉名字）
    @ScaledMetric(relativeTo: .headline) private var scaledAvatar: CGFloat = 46
    private var avatar: CGFloat { min(max(scaledAvatar, 40), 60) }

    var body: some View {
        let status = CloudBotStatus.of(bot)
        let spec = CloudBotAvatarSpec.of(bot)
        HStack(spacing: 14) {
            Group {
                if bot.activity != nil, !CloudBotLock.shared.isLocked(bot.id) {
                    // 正在回复：头像换成 Bot 颜色的三个点
                    CloudTypingAvatarDots(color: spec.fill, size: avatar)
                        .transition(.cloudTypingMorph(reduceMotion: reduceMotion))
                } else if status == .working {
                    CloudBotLivelyAvatar(spec: CloudBotAvatarSpec.of(bot), size: avatar)
                } else {
                    // 列表里的头像也跟着手指看，并按状态换表情
                    CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: avatar, mood: CloudBotMood.of(status, unread: unread, lastTaskStatus: bot.lastTaskStatus, lastAt: bot.lastAt))
                }
            }
            .frame(width: avatar, height: avatar + 4)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.75), value: bot.activity?.kind)
            .overlay(alignment: .bottomTrailing) { CloudPresenceBadge(presence: presence, size: 13) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(bot.name)，\(presence.accessibilityText)")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // 系统字体样式，跟着「更大字体」缩放（以前写死 17pt）
                    Text(bot.name).font(.headline).lineLimit(1)
                        .accessibilityIdentifier("homeRowTitle")
                    CloudPresenceFlags(presence: presence)
                    Spacer(minLength: 8)
                    Text(CloudBotHome.timeText(CloudTypingRules.sortTime(lastAt: max(bot.lastAt, showsThread ? bot.threadAt : 0), working: bot.activity != nil)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if status.busy && typing == nil { CloudBotStatusChip(status: status) }
                    if bot.runningWorkers > 0 {
                        Label("\(bot.runningWorkers)", systemImage: "gearshape.2.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                            .accessibilityLabel("\(bot.runningWorkers) 个后台任务进行中")
                    }
                    if showsThread {
                        // 和别的 Bot 说话：纸飞机 = 它发出的，箭头 = 收到的
                        Image(systemName: bot.threadOutgoing ? "paperplane.fill" : "arrow.down.left")
                            .font(.caption).foregroundStyle(bot.threadPriority ? Color.red : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    if let typing {
                        Text(typing.subtitle).font(.subheadline).foregroundStyle(.green).lineLimit(1)
                            .transition(.opacity)
                    } else {
                        Text(previewText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    CloudUnreadMark(presence: presence)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // 密集的列表行：字号最多放大到辅助功能 2 档，再大就一行放不下名字
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 上锁的 Bot 不显示在干什么（预览可能带内容）
    private var typing: CloudTypingPhase? { CloudBotLock.shared.isLocked(bot.id) ? nil : bot.activity }

    private var threadChoice: (text: String, isThread: Bool) {
        CloudBotThreadRules.homePreview(chat: bot.lastPreview, chatAt: bot.lastAt > 0 ? Date(timeIntervalSince1970: bot.lastAt) : nil,
                                        thread: bot.threadPreview, threadAt: bot.threadAt > 0 ? Date(timeIntervalSince1970: bot.threadAt) : nil)
    }

    private var showsThread: Bool { !CloudBotLock.shared.isLocked(bot.id) && threadChoice.isThread }

    var previewText: String {
        if CloudBotLock.shared.isLocked(bot.id) { return "已上锁" }
        if showsThread {
            // 去掉文字里的「➤」「←」，用前面的图标表示方向
            let t = threadChoice.text
            return t.hasPrefix("➤ ") || t.hasPrefix("← ") ? String(t.dropFirst(2)) : t
        }
        if bot.waitingApprovals > 0 && bot.lastPreview.isEmpty { return "等你处理" }
        if bot.runningTasks > 0 && bot.lastPreview.isEmpty { return "正在处理…" }
        if bot.runningWorkers > 0 && bot.lastPreview.isEmpty { return "后台任务进行中…" }
        if !bot.lastPreview.isEmpty { return bot.lastPreview }
        return bot.summary.isEmpty ? "开始对话" : bot.summary
    }
}

struct CloudBotHomeScreen: View {
    let onOpenSettings: () -> Void
    let onSwitchToLocal: () -> Void
    @ObservedObject private var model = CloudBotHomeModel.shared
    @State private var path: [String] = []
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad / Mac 三栏里选中的对话
    @State private var splitSelection: String?
    @State private var search = ""
    @StateObject private var searchModel = CloudSearchModel()
    @State private var showCreate = false
    @State private var showCreateGroup = false
    @State private var showHub = false
    /// 下拉首页露出的「今天」卡片
    @State private var showToday = false
    @State private var restScrollTop: CGFloat?
    @State private var showShiftCard = false
    @State private var showWorkbench = false
    /// 打开 Bot 设置时直接进「云电脑设置」（连接出问题的修复按钮用）
    @State private var hubOpensCloud = false
    @State private var showConnectApps = false
    @State private var showPrimaryPicker = false
    @State private var sectionFor: CloudBot?
    @State private var sectionName = ""
    @State private var renaming: CloudBot?
    @State private var renameText = ""
    @State private var deleting: CloudBot?
    @State private var shareURL: URL?

    private var menuActions: CloudBotMenuActions {
        CloudBotMenuActions(
            pickPrimary: { showPrimaryPicker = true },
            share: { bot in
                Task { @MainActor in
                    do {
                        shareURL = try await CloudQuiet.retry { try await CloudBotService.exportFile(bot.id) }
                    } catch {
                        model.bannerText = "导出失败：\(error.localizedDescription)"
                    }
                }
            },
            delete: { bot in deleting = bot },
            newSection: { bot in sectionName = ""; sectionFor = bot },
            edit: { bot in path = ["detail:" + bot.id] })
    }

    private var compactStack: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        CloudHomeScrollProbe()
                        if showToday && search.isEmpty {
                            CloudTodayCard(model: model, open: open).transition(.move(edge: .top).combined(with: .opacity))
                        }
                        CloudLinkBanner(onOpenSettings: openCloudSettings)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                        if let until = model.dutyUntil, until > Date() {
                            HStack(spacing: 8) {
                                Image(systemName: "cross.case.fill").foregroundStyle(.red)
                                Text("值班中 · 到 \(until.formatted(date: .omitted, time: .shortened))：回答极简，主动消息攒到下班汇总")
                                    .font(.footnote)
                                Spacer()
                                Button("结束") { Task { await model.setDuty(hours: nil) } }.font(.footnote)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 16)
                        }
                        if let digest = model.dutyDigest {
                            CloudDutyDigestCard(text: digest.text, onDismiss: model.dismissDutyDigest)
                                .padding(.horizontal, 16).padding(.bottom, 8)
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
                        if search.isEmpty {
                            CloudBotTopRow(model: model, actions: menuActions, open: open)
                        }
                        if search.isEmpty && !model.exams.isEmpty {
                            CloudExamBoard(exams: model.exams)
                        }
                        // H1：大「今日」卡片去掉，主动消息 / 例行结果收进顶部「今天」统计栏的「今天有消息」小窗口
                        LazyVStack(spacing: 0) {
                            ForEach(groupsMatching) { g in
                                Button { path = ["group:" + g.id] } label: {
                                    CloudGroupHomeRow(group: g, bots: model.bots)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
                            }
                        }
                        CloudBotSectionedList(model: model, search: search, actions: menuActions, open: open)
                        if search.isEmpty {
                            CloudHiddenFooter(count: model.hiddenBots.count) { path = ["hidden"] }
                            if CloudFocusFilter.active {
                                Label("专注模式过滤中：只显示医疗 Bot 和置顶的 Bot（想留着的 Bot 置顶即可；在系统专注模式里关掉）", systemImage: "moon.circle")
                                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                            }
                        }
                        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                            CloudSearchResultsSection(model: searchModel, query: search) { target in
                                if ["group:", "nav:", "page:"].contains(where: target.hasPrefix) { path = [target] } else { open(target) }
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
                .coordinateSpace(name: "cloudHomeScroll")
                .onPreferenceChange(CloudHomeScrollTopKey.self) { value in
                    guard let top = value else { return }
                    // 静止时内容顶部在导航栏下面（iOS 26 约 116pt），以第一次读到的位置为 0，下拉为正
                    if restScrollTop == nil { restScrollTop = top }
                    let next = CloudHomeHeaderRules.todayVisible(was: showToday, scrollTop: Double(top - (restScrollTop ?? top)))
                    if next != showToday { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showToday = next } }
                }
                .refreshable { await model.refresh() }
                .scrollDismissesKeyboard(.interactively)
                bottomBar
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 11-11：左上角齿轮（带连接状态小点），中间平时空着、有 Bot 干活时飘出一行状态
                ToolbarItem(placement: .topBarLeading) {
                    CloudSettingsGearButton(onTap: openBotSettings, onAppSettings: onOpenSettings, onSwitch: { if $0 == .local { onSwitchToLocal() } })
                }
                ToolbarItem(placement: .principal) {
                    CloudHomeCenterStatus(model: model, open: open)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCreate = true } label: { Label("新 Bot", systemImage: "person.crop.circle.badge.plus") }
                        Button { showCreateGroup = true } label: { Label("新群聊", systemImage: "person.3") }
                            .disabled(model.bots.isEmpty)
                        if !model.hiddenBots.isEmpty {
                            Button { path = ["hidden"] } label: { Label("已隐藏对话（\(model.hiddenBots.count)）", systemImage: "eye.slash") }
                        }
                        Menu {
                            Button("8 小时") { Task { await model.setDuty(hours: 8) } }
                            Button("12 小时") { Task { await model.setDuty(hours: 12) } }
                            Button("到明早 8 点") { Task { await model.setDuty(hours: CloudBotHomeModel.hoursUntilMorning()) } }
                            if model.dutyUntil != nil {
                                Button("结束值班", role: .destructive) { Task { await model.setDuty(hours: nil) } }
                            }
                            Divider()
                            CloudNightModeMenu()
                            CloudWardVoiceMenu()
                        } label: { Label(model.dutyUntil == nil ? "值班模式" : "值班中…", systemImage: "cross.case") }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建")
                }
            }
            .navigationDestination(for: String.self) { id in
                if id.hasPrefix("group:") {
                    CloudGroupChatView(groupId: String(id.dropFirst(6)))
                } else if let pair = CloudBotThreadRules.parseRoute(id) {
                    CloudBotThreadView(a: pair.0, b: pair.1)
                } else if id == "nav:routines" {
                    CloudRoutinesView()
                } else if id == "nav:vault" {
                    CloudVaultView()
                } else if id.hasPrefix("page:") {
                    let rest = id.dropFirst(5).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    CloudPageDetailView(pageId: String(rest.first ?? ""), title: rest.count > 1 ? String(rest[1]) : "页面")
                } else if id == "hidden" {
                    CloudHiddenBotsPage(model: model)
                } else if id.hasPrefix("detail:"), let bot = model.bot(String(id.dropFirst(7))) {
                    CloudBotDetailView(bot: bot, onChanged: { await model.refresh() })
                } else {
                    CloudBotChatView(botId: id)
                }
            }
        }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                CloudBotSplitHome(model: model, openHub: { hubOpensCloud = false; showHub = true }, newBot: { showCreate = true }, selection: $splitSelection)
            } else {
                compactStack
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
        .overlay { CloudMiniDesktopOverlay() }
        .modifier(CloudNightModeModifier(dutyUntil: model.dutyUntil))
        .onReceive(NotificationCenter.default.publisher(for: .cloudFocusFilterChanged)) { _ in model.objectWillChange.send() }
        .onAppear { CloudColdStart.markHomeVisible(hasContent: !model.bots.isEmpty) }
        .sheet(isPresented: $showShiftCard) { CloudShiftCardSheet() }
        .sheet(isPresented: $showWorkbench) { CloudWorkbenchSheet() }
        .sheet(isPresented: $showHub) {
            NavigationStack {
                CloudBotHubView(onDone: { showHub = false }, openCloudFirst: hubOpensCloud,
                                onOpenAppSettings: { showHub = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenSettings() } })
            }
        }
        .cloudBotSaveToast()
        .modifier(CloudBotHomeMenuSheets(model: model, showPrimaryPicker: $showPrimaryPicker,
                                         renaming: $renaming, renameText: $renameText, deleting: $deleting, shareURL: $shareURL,
                                         sectionFor: $sectionFor, sectionName: $sectionName))
        .sheet(isPresented: $showConnectApps) {
            CloudConnectAppsSheet(onClose: { showConnectApps = false })
                .presentationDetents([.large])
        }
        .onChange(of: path) { p in if let id = p.last { model.rememberCurrent(id) } }
        .onChange(of: splitSelection) { id in model.rememberCurrent(id) }
        .onChange(of: model.pendingOpen) { target in
            guard let target else { return }
            model.pendingOpen = nil
            if sizeClass == .regular { splitSelection = target; return }
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
            if let target = model.pendingOpen { model.pendingOpen = nil; path = [target]; splitSelection = target }
            // 进入多 Bot 模式即后台连接并定期刷新（列表的运行 / 待审批 / 未读状态）
            // 有 Bot 在回复时 3 秒拉一次 Bot 列表（阶段跟得上），每 15 秒完整刷新一次
            var sinceFull: UInt64 = 0
            while !Task.isCancelled {
                let before = model.typingIds
                if sinceFull == 0 { await model.refresh() } else { await model.refreshBots() }
                // 首页看着的时候，有 Bot 刚回复完：轻震一下
                if path.isEmpty, UIApplication.shared.applicationState == .active,
                   !CloudTypingRules.justFinished(before: before, after: model.typingIds).isEmpty {
                    CloudHaptics.success()
                }
                let step = CloudTypingRules.pollSeconds(anyWorking: !model.typingIds.isEmpty)
                try? await Task.sleep(nanoseconds: step * 1_000_000_000)
                sinceFull = sinceFull + step >= 15 ? 0 : sinceFull + step
            }
        }
    }

    private var groupsMatching: [CloudGroup] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.groups.filter { q.isEmpty || $0.name.lowercased().contains(q) || (!CloudBotLock.isLockedStored($0.lastSender ?? "") && ($0.lastContent ?? "").lowercased().contains(q)) }
    }

    private func open(_ id: String) {
        CloudHaptics.tap()
        model.markSeen(id)
        model.rememberCurrent(id)
        path = [id]
    }

    private func openBotSettings() {
        hubOpensCloud = false
        showHub = true
    }

    /// 连接诊断、离线横幅里的「检查连接设置」「去设置」：直接到云电脑设置
    private func openCloudSettings() {
        hubOpensCloud = true
        // 可能是从连接诊断的弹窗里点的：等那个弹窗收起再打开，否则两个 sheet 冲突、什么都不出现
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showHub = true }
    }

    /// H5：底部浮在列表上的一条：左边白色圆按钮（深色四宫格线框图标），右边白色胶囊搜索框，都带柔和阴影；
    /// 后面的列表在底部淡出（不是一整块挡板）
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button { showConnectApps = true } label: { Label("连接应用", systemImage: "square.grid.2x2") }
                Button { showWorkbench = true } label: { Label("工作台（在跑的任务）", systemImage: "rectangle.stack.badge.play") }
                Button { showShiftCard = true } label: { Label("交班卡", systemImage: "list.clipboard") }
                Button { path = ["hidden"] } label: {
                    Label(model.hiddenBots.isEmpty ? "已隐藏对话" : "已隐藏对话（\(model.hiddenBots.count)）", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color(.label))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Color(.systemBackground)))
                    .overlay(Circle().stroke(Color.black.opacity(0.05), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
            }
            .tint(Color(.label))
            .accessibilityLabel("连接应用")
            .accessibilityIdentifier("homeAppsButton")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(.label))
                TextField("搜索", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: search) { q in searchModel.update(q) }
                    .accessibilityIdentifier("homeSearchField")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Capsule().fill(Color(.systemBackground)))
            .overlay(Capsule().stroke(Color.black.opacity(0.05), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            // 列表在底部淡出
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground).opacity(0.92), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}

/// 外观：跟随系统（默认）/ 浅色 / 深色；和 App 设置里的「Theme」是同一个开关
struct CloudAppearancePicker: View {
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage(CloudHomeLayout.key) private var layout: String = CloudHomeLayout.list.rawValue
    @AppStorage(ChatFontDesign.key) private var font: String = ChatFontDesign.system.rawValue

    var body: some View {
        Picker(selection: $layout) {
            ForEach(CloudHomeLayout.allCases) { Label($0.label, systemImage: $0.icon).tag($0.rawValue) }
        } label: { Label("首页布局", systemImage: "square.grid.2x2") }
        Picker(selection: $font) {
            ForEach(ChatFontDesign.allCases) { Text($0.label).font(.system(.body, design: $0.swiftUI)).tag($0.rawValue) }
        } label: { Label("聊天字体", systemImage: "textformat") }
        Picker(selection: $appearanceMode) {
            Text("跟随系统").tag(0)
            Text("浅色").tag(1)
            Text("深色").tag(2)
        } label: {
            Label("外观", systemImage: "circle.lefthalf.filled")
        }
        .onChange(of: appearanceMode) { mode in
            let style: UIUserInterfaceStyle = mode == 1 ? .light : mode == 2 ? .dark : .unspecified
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}

/// 左下角入口：Bot 管理、插件、例行任务、记忆、页面、云电脑设置
struct CloudBotHubView: View {
    let onDone: () -> Void
    var openCloudFirst = false
    var onOpenAppSettings: (() -> Void)? = nil
    @State private var showCloud = false

    var body: some View {
        List {
            Section {
                HomeModeRow(current: .bots, dismiss: onDone)
            } footer: {
                Text("切换本地 / 云端；两种模式的设置和对话各自独立。")
            }
            Section {
                NavigationLink(destination: CloudLinkDiagnosticsView(onOpenSettings: { showCloud = true })) {
                    Label("连接诊断（齿轮上的状态点）", systemImage: "stethoscope")
                }
                NavigationLink(destination: CloudAgentSettingsView()) {
                    Label("云电脑设置", systemImage: "server.rack")
                }
                NavigationLink(destination: CloudAgentSettingsView()) {
                    Label("安装 / 更新服务器 Agent 服务", systemImage: "arrow.down.circle")
                }
                CloudVaultSettingsRow()
            } footer: {
                Text("连接 VPS、安装或更新服务器上的 Agent 服务、代理和桌面环境都在「云电脑设置」里。")
            }
            Section {
                CloudAppearancePicker()
            } footer: {
                Text("换聊天字体后，新消息马上用新字体；已经显示的消息重新打开对话后才换。")
            }
            Section {
                NavigationLink(destination: CloudControlsAndWatchView(onPreview: { id in
                    onDone()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { CloudBotEntry.openVoice(bot: id) }
                })) { Label("控制中心与手表", systemImage: "applewatch") }
                NavigationLink(destination: CloudBotsView()) { Label("我的 Bot（模板、导入导出）", systemImage: "person.3") }
                NavigationLink(destination: CloudPluginsView()) { Label("插件市场", systemImage: "puzzlepiece.extension") }
                    .accessibilityIdentifier("pluginMarketRow")
                NavigationLink(destination: CloudRoutinesView()) { Label("例行任务", systemImage: "clock.arrow.circlepath") }
                NavigationLink(destination: CloudEventTriggersView()) { Label("事件触发（GitHub、邮件、Telegram）", systemImage: "bolt.badge.clock") }
                NavigationLink(destination: CloudMemoryTimelineView()) { Label("云端记忆", systemImage: "brain") }
                NavigationLink(destination: CloudSkillsView()) { Label("技能", systemImage: "wand.and.stars") }
                NavigationLink(destination: CloudDelegationsView()) { Label("委托记录", systemImage: "arrow.triangle.branch") }
                NavigationLink(destination: CloudPagesView()) { Label("页面", systemImage: "doc.richtext") }
                NavigationLink(destination: CloudComputerView(botId: nil, sessionId: nil, reason: nil)) { Label("云电脑桌面", systemImage: "display") }
                    .accessibilityIdentifier("ccDesktopSettingsRow")
            }
            Section {
                NavigationLink(destination: CloudUsageView()) { Label("用量与每日上限", systemImage: "chart.bar") }
                NavigationLink(destination: CloudBackupView()) { Label("备份与恢复", systemImage: "externaldrive") }
                NavigationLink(destination: FaceIDProtectionSettingsView()) { Label("Face ID 锁（打开 App 先验证）", systemImage: "faceid") }
                NavigationLink(destination: CloudExamListView()) { Label("考试倒计时", systemImage: "calendar.badge.clock") }
                NavigationLink(destination: CloudErrorLogView()) { Label("导出错误日志", systemImage: "ladybug") }
                NavigationLink(destination: CloudReplayListView()) { Label("录屏回放（Bot 用浏览器 / 桌面的截图）", systemImage: "play.rectangle") }
                NavigationLink(destination: CloudLiveStatsView()) { Label("实时资源（CPU / 内存 / 网速）", systemImage: "gauge.with.dots.needle.33percent") }
                NavigationLink(destination: CloudSystemSnapshotsView()) { Label("系统快照（装软件前自动拍）", systemImage: "camera.metering.matrix") }
            }
            if let onOpenAppSettings {
                Section {
                    Button { onOpenAppSettings() } label: { Label("App 通用设置（模型、外观、语言）", systemImage: "slider.horizontal.3") }
                }
            }
        }
        .navigationDestination(isPresented: $showCloud) { CloudAgentSettingsView() }
        .onAppear { if openCloudFirst && !showCloud { showCloud = true } }
        .navigationTitle("Bot 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { onDone() } } }
    }
}

/// 某个 Bot 的唯一对话（像 Grok Bot 一样每个 Bot 一条连续对话）；菜单里可开新对话或切换历史。
struct CloudBotChatView: View {
    let botId: String
    @ObservedObject private var model = CloudBotHomeModel.shared
    @State private var sessionId: String?
    @State private var replyPlan: CloudReplyPlan?
    @State private var history: [[String: Any]] = []
    @State private var errorText: String?
    @State private var showDetail = false
    @State private var showComputer = false

    @ObservedObject private var lock = CloudBotLock.shared
    /// 当前是无痕对话时记下它和之前的对话，结束后删掉并回到原来的对话
    @State private var incognito: (id: String, previous: String?)?
    /// 页面真正关闭（被弹出）时删掉无痕对话；推到委托 / 电脑 / 资料页时不会触发
    @StateObject private var incognitoGuard = CloudIncognitoGuard()
    @State private var incognitoError: String?
    @AppStorage private var backdropRaw: String
    @Environment(\.colorScheme) private var systemScheme

    init(botId: String) {
        self.botId = botId
        _backdropRaw = AppStorage(wrappedValue: "", CloudChatBackdrop.key(botId))
    }

    @AppStorage(ChatFontDesign.key) private var chatFontRaw: String = ChatFontDesign.system.rawValue

    var body: some View {
        chatBody
            // 聊天字体：Bot 对话里没写死字体的文字都跟着换（消息正文由 Markdown 渲染器单独处理）
            .font(.system(.body, design: (ChatFontDesign(rawValue: chatFontRaw) ?? .system).swiftUI))
    }

    private var chatBody: some View {
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
                    .id(sid + "|" + backdropRaw)
                    .environment(\.cloudChatBotId, botId)
                    .environment(\.colorScheme, CloudChatBackdrop(rawValue: backdropRaw)?.colorScheme ?? systemScheme)
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
                // 还没拿到对话编号（新 Bot 第一次打开）：骨架气泡，不整页转圈
                CloudChatSkeleton()
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
                            if incognito == nil {
                                CloudReplyChatMenu(sessionId: sid, plan: $replyPlan)
                            }
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
        .task(id: sessionId) {
            // 这个对话的回复方式（老服务器没有这个接口：菜单里就不出现）
            if let sid = sessionId { replyPlan = try? await CloudReplyService.session(sid) }
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudReplyService.changed)) { note in
            guard let sid = sessionId, note.userInfo?["session_id"] as? String == sid else { return }
            Task { replyPlan = try? await CloudReplyService.session(sid) }
        }
        .alert("没能开无痕对话", isPresented: Binding(get: { incognitoError != nil }, set: { if !$0 { incognitoError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(incognitoError ?? "") }
        .onDisappear { model.markSeen(botId); CloudBotSpeaker.stop() }
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
        // 先用本地已知的对话编号直接打开（首页缓存的 Bot 列表 / 上次打开的），不等连接
        if sessionId == nil {
            sessionId = model.bot(botId)?.latestSessionId ?? UserDefaults.standard.string(forKey: Self.lastSessionKey(botId))
        }
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
            if let sid = sessionId, incognito?.id != sid { UserDefaults.standard.set(sid, forKey: Self.lastSessionKey(botId)) }
        } catch {
            // 已经在显示缓存的对话时不盖住它；对话页自己会提示在重连
            if sessionId == nil { errorText = error.localizedDescription }
        }
    }

    static func lastSessionKey(_ botId: String) -> String { "OpenMinisCloud_lastSession_" + botId }

    private func startIncognito() async {
        guard let bot = model.bot(botId) else { return }
        do {
            let sid = try await CloudQuiet.retry(2) { try await CloudBotService.newIncognitoSession(bot) }
            guard !sid.isEmpty else { return }
            incognito = (sid, sessionId)
            incognitoGuard.sessionId = sid
            sessionId = sid
        } catch {
            incognitoError = error.localizedDescription
        }
    }

    private func endIncognito(restore: Bool) {
        guard let current = incognito else { return }
        incognito = nil
        incognitoGuard.sessionId = nil
        if restore, sessionId == current.id { sessionId = current.previous }
        CloudChatCache.remove(current.id)
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
    var liked = 0          // 1 赞 / -1 踩 / 0 没反馈
    var comment = ""

    init?(_ d: [String: Any]) {
        guard let id = d["run_id"] as? String, let text = d["text"] as? String, !text.isEmpty else { return nil }
        liked = (d["liked"] as? Int) ?? 0
        comment = d["comment"] as? String ?? ""
        self.id = id
        sessionId = d["session_id"] as? String ?? ""
        title = d["title"] as? String ?? ""
        botId = d["bot_id"] as? String ?? ""
        proactive = d["proactive"] as? Bool ?? false
        self.text = text
        at = Date(timeIntervalSince1970: d["at"] as? Double ?? 0)
    }
}


/// 跟着 CloudBotChatView 的生命周期：视图真正离开（不是被别的页面盖住）时释放，顺手删掉还开着的无痕对话
@MainActor
final class CloudIncognitoGuard: ObservableObject {
    nonisolated(unsafe) var sessionId: String?

    deinit {
        if let sid = sessionId {
            Task { @MainActor in await CloudBotService.deleteIncognito(sid) }
        }
    }
}
