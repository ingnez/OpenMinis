import Foundation
import SwiftUI
import UIKit
import Network
import UserNotifications
import BackgroundTasks

/// 云电脑连接守护：启动 / 回到前台 / 切换网络时静默检查并重连，失败按退避重试；
/// 只有静默重试都失败才显示一行原因和一个修复按钮。连接在线时长轮询服务器通知流，用系统本地通知提醒。
@MainActor
final class CloudLinkSupervisor: ObservableObject {
    static let shared = CloudLinkSupervisor()
    /// App 内置的服务器 Agent 版本（与 cloud_agent_server.AGENT_VERSION 一致，测试会核对）
    static let bundledAgentVersion = "2.49.0"
    nonisolated static let refreshTaskId = "com.openminis.app.cloud-refresh"
    nonisolated static let barkFallbackKey = "OpenMinisCloud_barkFallback"   // "auto" / "on" / "off"

    typealias State = CloudLinkState

    /// 界面显示的状态：连上过之后，静默重连期间仍显示在线（规则见 CloudLinkDisplay）
    @Published private(set) var state: State = .idle
    /// 守护内部的真实状态
    private(set) var actualState: State = .idle
    private var display = CloudLinkDisplay()
    private var resurfaceTask: Task<Void, Never>?
    private var probing = false
    private var backgroundAt: Date?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    @Published private(set) var networkAvailable = true
    @Published private(set) var serverOutdated = false
    @Published private(set) var desktopProblem: String?
    @Published private(set) var desktopMissing = false

    /// 用户正在看的会话：这个会话的通知不再弹
    var visibleSessionId: String?

    private var policy = CloudReconnectPolicy()
    private var started = false
    private var inBackground = false
    private var monitor: NWPathMonitor?
    private var lastPathSignature = ""
    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let conn = CloudConnection.shared
    private static let feedCursorKey = "OpenMinisCloud_feedCursor"

    var configured: Bool { conn.canAutoConnect }

    // MARK: 启动

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handle(.foreground) }
        })
        // 解锁 / 切回 App 时 willEnterForeground 比 didBecomeActive 早几百毫秒：提前开始探测
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handle(.foreground) }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handle(.background) }
        })
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let sig = "\(ok)-" + path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
            Task { @MainActor in self?.pathChanged(available: ok, signature: sig) }
        }
        m.start(queue: DispatchQueue(label: "cloud.link.path"))
        monitor = m
        handle(.launch)
    }

    /// 打开任何云端页面时调用（已在线就只是一次轻量探测）
    func pageOpened() { handle(.pageOpened) }

    /// 用户点了修复 / 重试：立即完整重连
    func userRetry() {
        policy.recordSuccess()
        runLoop(force: true)
    }

    private func pathChanged(available: Bool, signature: String) {
        let changed = signature != lastPathSignature && !lastPathSignature.isEmpty
        lastPathSignature = signature
        networkAvailable = available
        if changed || !available { handle(.networkChanged(available: available)) }
    }

    func handle(_ event: CloudLinkEvent) {
        if event == .background {
            // 不断开隧道：向系统要一段后台时间，让 SSH 隧道和通知长轮询多活一会儿（通常约 30 秒）
            inBackground = true
            backgroundAt = Date()
            beginBackgroundTime()
            heartbeatTask?.cancel()
            postPresence(foreground: false)
            startBackgroundPresence()
            Self.scheduleRefresh()
            return
        }
        if event == .foreground {
            inBackground = false
            endBackgroundTime()
            // 离开超过 25 秒多半被挂起过：下一次请求先探测；时间短就直接用原来的隧道
            if let at = backgroundAt, Date().timeIntervalSince(at) > 25 { conn.markStale() }
            backgroundAt = nil
        }
        guard configured else { set(.idle); return }
        switch CloudLinkDecider.action(for: event, configured: configured, connected: conn.isConnected,
                                       networkAvailable: networkAvailable, inBackground: inBackground) {
        case .none: break
        case .pause:
            if !networkAvailable { set(.offline(.noNetwork)) }
        case .probe:
            // 界面保持上次的在线状态和缓存内容，后台 1.5 秒探测；死了才静默重连
            guard !probing else { return }
            probing = true
            let t0 = Date()
            Task {
                let alive = await conn.probeAlive(timeout: 1.5)
                self.probing = false
                if event == .foreground {
                    CloudClientMetrics.record(mode: "link", kind: "foreground_probe", ms: Date().timeIntervalSince(t0) * 1000)
                }
                if alive { self.markOnline() } else { self.runLoop(force: true) }
            }
        case .reconnect:
            runLoop(force: event != .launch && event != .pageOpened)
        }
    }

    // MARK: 重连循环

    private func runLoop(force: Bool) {
        if loopTask != nil { return }
        loopTask = Task { [weak self] in
            await self?.reconnectLoop(force: force)
            self?.loopTask = nil
        }
    }

    private func reconnectLoop(force: Bool) async {
        var forceNext = force
        while !Task.isCancelled {
            guard configured else { set(.idle); return }
            guard networkAvailable else { set(.offline(.noNetwork)); return }
            set(policy.failures == 0 ? .connecting : (policy.shouldSurface ? actualState : .retrying(policy.failures)))
            do {
                if forceNext { try await conn.reconnect() } else { try await conn.ensureConnected() }
                markOnline()
                // 重连好了：首页悄悄刷新一次（列表、未读、运行状态）
                Task { await CloudBotHomeModel.shared.refresh() }
                return
            } catch {
                let cause = CloudLinkCause.classify(error.localizedDescription)
                policy.recordFailure()
                display.failed(at: Date())
                if !cause.retriable {
                    set(.offline(cause))
                    return
                }
                if policy.shouldSurface { set(.offline(cause)) } else { set(.retrying(policy.failures)) }
                if inBackground { return }
                forceNext = true
                let delay = policy.nextDelay(jitter: Double.random(in: 0...1))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// 记下真实状态，按 CloudLinkDisplay 算出界面显示的状态；静默期到点后再算一次
    private func set(_ s: State) {
        actualState = s
        switch s {
        case .online: display.online()
        case .idle: display.unconfigured()
        default: break
        }
        let shown = display.shown(s, now: Date())
        if state != shown { state = shown }
        resurfaceTask?.cancel()
        if shown != s, let left = display.silentRemaining(now: Date()) {
            resurfaceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((left + 0.1) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let again = self.display.shown(self.actualState, now: Date())
                if self.state != again { self.state = again }
            }
        }
    }

    private func beginBackgroundTime() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "cloud-link") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    private func markOnline() {
        policy.recordSuccess()
        set(.online)
        evaluateHealth()
        postPresence(foreground: !inBackground)
        startHeartbeat()
        startFeed()
    }

    private func evaluateHealth() {
        let h = conn.lastHealth
        if let v = h["agent_version"] as? String {
            serverOutdated = CloudVersion.isOlder(v, than: Self.bundledAgentVersion)
        } else {
            serverOutdated = !h.isEmpty     // 旧版服务器没有 agent_version
        }
        if let d = h["desktop"] as? [String: Any] {
            desktopMissing = (d["installed"] as? Bool) == false
            desktopProblem = (d["ok"] as? Bool) == false && !desktopMissing ? d["message"] as? String : nil
        }
    }

    /// 进程还活着（后台没被挂起）时每 25 秒报到一次：服务器据此只走 App 自己的本地通知，不发外部推送。
    /// 被系统挂起或杀掉后报到自然停下，约 90 秒后服务器改用设置里的推送渠道兜底。
    private func startBackgroundPresence() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled, self.inBackground else { return }
                self.postPresence(foreground: false)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled, !self.inBackground else { return }
                // 最近有请求成功（长轮询一直在回）就不必探测
                if Date().timeIntervalSince(self.conn.lastOK) < 20 { continue }
                if await self.conn.probeAlive(timeout: 3) {
                    misses = 0
                    self.evaluateHealth()
                } else {
                    // 连续两次（约 50 秒）都探测失败才判定断线，单次失败不打扰
                    misses += 1
                    if misses >= 2 {
                        self.handle(.heartbeatFailed)
                        return
                    }
                }
            }
        }
    }

    // MARK: 修复动作

    /// 状态点 / 横幅上的修复按钮
    func performFix(_ fix: CloudLinkFix, openSettings: () -> Void) {
        switch fix {
        case .retry, .waitNetwork: userRetry()
        case .openSettings, .confirmHostKey: openSettings()
        case .installAgent:
            Task {
                set(.connecting)
                do { try await conn.installAgent(withDesktop: true); userRetry() }
                catch { set(.offline(CloudLinkCause.classify(error.localizedDescription))) }
            }
        }
    }

    // MARK: 通知

    private var askedNotificationPermission = false

    private func postPresence(foreground: Bool) {
        guard conn.isConnected else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if !askedNotificationPermission, await center.notificationSettings().authorizationStatus == .notDetermined {
                askedNotificationPermission = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let settings = await center.notificationSettings()
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            let pref = UserDefaults.standard.string(forKey: Self.barkFallbackKey)
            _ = try? await conn.request(method: "POST", path: "/v1/presence", body: ["foreground": foreground, "local_notifications": allowed])
            if let pref {
                _ = try? await conn.request(method: "PUT", path: "/v1/resources", body: ["bark_fallback": pref])
            }
        }
    }

    private func startFeed() {
        guard feedTask == nil else { return }
        feedTask = Task { [weak self] in
            defer { self?.feedTask = nil }
            var cursor = UserDefaults.standard.integer(forKey: Self.feedCursorKey)
            var first = cursor == 0
            while !Task.isCancelled {
                guard let self, self.conn.isConnected else { return }
                do {
                    let res = try await self.conn.request(method: "GET", path: "/v1/notifications?after=\(cursor)&wait=\(first ? 0 : 15)")
                    let items = res["items"] as? [[String: Any]] ?? []
                    let last = res["last_id"] as? Int ?? cursor
                    // 第一次连接只记下位置，不把历史通知全弹出来
                    if !first { await self.deliver(items) }
                    first = false
                    cursor = max(cursor, items.compactMap { $0["id"] as? Int }.max() ?? last)
                    if items.isEmpty { cursor = max(cursor, last) }
                    UserDefaults.standard.set(cursor, forKey: Self.feedCursorKey)
                } catch {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self.inBackground { return }
                }
            }
        }
    }

    private func deliver(_ items: [[String: Any]]) async {
        let center = UNUserNotificationCenter.current()
        for item in items {
            let sid = item["session_id"] as? String
            if item["kind"] as? String == "bots_changed" {
                // 主 Bot 新建 / 删除 / 恢复了 Bot：首页马上刷新，不弹通知
                Task { await CloudBotHomeModel.shared.refresh() }
                continue
            }
            if !inBackground, let sid, sid == visibleSessionId { continue }
            // 服务器已经用 Bark / ntfy / Telegram 推过（那时 App 不在）：不再弹第二次
            if item["external"] as? Bool == true { continue }
            let content = UNMutableNotificationContent()
            content.title = item["title"] as? String ?? "云电脑"
            content.body = item["body"] as? String ?? ""
            if let bid = item["bot_id"] as? String, CloudBotLock.isLockedStored(bid) {
                // 旧服务器不会替我们隐藏：本机再兜一层
                content.title = "OpenMinis"
                content.body = "有一条新消息（已上锁的 Bot）"
            }
            content.sound = .default
            content.threadIdentifier = "cloud-" + (item["bot_id"] as? String ?? sid ?? "main")
            var info: [String: Any] = ["cloud_kind": item["kind"] as? String ?? ""]
            if let sid { info["cloud_session_id"] = sid }
            if let bid = item["bot_id"] as? String { info["cloud_bot_id"] = bid }
            content.userInfo = info
            let id = "cloud-feed-\(item["id"] as? Int ?? Int.random(in: 0...Int.max))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: 后台刷新：系统给的短暂时间里重连一次、取走未读通知

    nonisolated static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                let ok = await CloudLinkSupervisor.shared.backgroundFetch()
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
            scheduleRefresh()
        }
    }

    nonisolated static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    func backgroundFetch() async -> Bool {
        guard configured else { return false }
        do {
            try await conn.ensureConnected()
            let cursor = UserDefaults.standard.integer(forKey: Self.feedCursorKey)
            let res = try await conn.request(method: "GET", path: "/v1/notifications?after=\(cursor)&wait=0")
            let items = res["items"] as? [[String: Any]] ?? []
            if cursor > 0 { await deliver(items) }
            let last = max(cursor, items.compactMap { $0["id"] as? Int }.max() ?? (res["last_id"] as? Int ?? cursor))
            UserDefaults.standard.set(last, forKey: Self.feedCursorKey)
            return true
        } catch {
            return false
        }
    }
}

/// 只有需要用户动手时才出现的一行横幅：断线原因 / 服务器需要更新 / 桌面未安装
struct CloudLinkBanner: View {
    @ObservedObject private var link = CloudLinkSupervisor.shared
    @ObservedObject private var conn = CloudConnection.shared
    var onOpenSettings: () -> Void = {}
    @State private var updating = false
    @State private var updateError: String?

    var body: some View {
        Group {
            if let updateError, !updating {
                row("更新没有完成：\(updateError)", button: "重试", tint: .red) { update() }
            } else if case .offline(let cause) = link.state {
                row(cause.message, button: cause.fix.title, tint: .red) { link.performFix(cause.fix, openSettings: onOpenSettings) }
            } else if link.state == .online && link.serverOutdated {
                row(updating ? "正在更新服务器…" : "服务器上的 Agent 版本较旧，部分功能不可用", button: updating ? nil : "更新服务器", tint: .orange) { update() }
            } else if link.state == .online && link.desktopMissing {
                row("服务器还没有安装云电脑桌面", button: updating ? nil : "一键安装", tint: .orange) { update() }
            }
        }
    }

    private func row(_ text: String, button: String?, tint: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.footnote).foregroundStyle(tint).lineLimit(2)
            Spacer(minLength: 4)
            if let button {
                Button(button, action: action).font(.footnote.weight(.semibold)).buttonStyle(.bordered).tint(tint).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.1)))
    }

    private func update() {
        updating = true
        updateError = nil
        Task {
            defer { updating = false }
            do {
                try await conn.installAgent(withDesktop: true)
                link.userRetry()
            } catch {
                // 之前失败时什么都不显示，横幅停在「版本较旧」看不出发生了什么
                updateError = String(error.localizedDescription.prefix(160))
            }
        }
    }
}
