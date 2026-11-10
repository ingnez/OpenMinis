//
//  CloudBotHome.swift
//  Minis - 多 Bot 模式首页（参考 Grok Bot）
//  主屏模式开关：本地模式保持原样；多 Bot 模式下首页是 Bot 列表——主 Bot 大头像置顶，
//  其他 Bot 按最近活动排序，每个 Bot 一条连续对话；进入时后台自动连接云电脑。
//

import Foundation
import SwiftUI

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
    @Published private(set) var loaded = false
    @Published private(set) var connecting = false
    @Published var bannerText: String?
    private var seen: [String: Double]

    private init() {
        seen = UserDefaults.standard.dictionary(forKey: "OpenMinisCloud_botSeen") as? [String: Double] ?? [:]
    }

    var primary: CloudBot? { bots.first(where: { $0.isPrimary }) }

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

    /// 后台自动连接（复用已保存的连接信息）后刷新 Bot 列表；失败只显示横幅。
    func refresh() async {
        let conn = CloudConnection.shared
        if !conn.isConnected {
            guard conn.canAutoConnect else {
                bannerText = "还没有连接云电脑：点左上角头像 › 云电脑设置，填写 VPS 并安装服务"
                loaded = true
                return
            }
            connecting = true
            do {
                try await conn.ensureConnected()
            } catch {
                connecting = false
                bannerText = "云电脑连接失败：\(error.localizedDescription.prefix(160))"
                loaded = true
                return
            }
            connecting = false
        }
        do {
            bots = try await CloudBotService.list()
            bannerText = nil
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
        CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: size)
            .accessibilityLabel(bot.name)
    }
}

struct CloudBotHomeRow: View {
    let bot: CloudBot
    let unread: Bool

    var body: some View {
        HStack(spacing: 14) {
            CloudBotBlobAvatar(bot: bot)
                .overlay(alignment: .bottomTrailing) {
                    if bot.runningTasks > 0 || bot.waitingApprovals > 0 {
                        Circle().fill(bot.waitingApprovals > 0 ? Color.orange : Color.green)
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
        if bot.waitingApprovals > 0 { return "⏳ 等待你审批" }
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
    @State private var showCreate = false
    @State private var showHub = false
    @State private var showConnectApps = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        if let banner = model.bannerText {
                            Button { Task { await model.refresh() } } label: {
                                Text(banner + "（点此重试）")
                                    .font(.footnote).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        if model.connecting {
                            Text("正在连接云电脑…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                        }
                        if let primary = model.primary, search.isEmpty {
                            hero(primary)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(model.others(matching: search)) { bot in
                                Button { open(bot.id) } label: {
                                    CloudBotHomeRow(bot: bot, unread: model.isUnread(bot))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
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
                bottomBar
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { avatarMenu }
                ToolbarItem(placement: .principal) {
                    Menu {
                        modeButtons
                    } label: {
                        HStack(spacing: 3) {
                            Text("多 Bot").font(.caption.weight(.semibold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建 Bot")
                }
            }
            .navigationDestination(for: String.self) { id in
                CloudBotChatView(botId: id)
            }
        }
        .sheet(isPresented: $showCreate) {
            CloudBotCreateSheet(onCreated: { id in
                await model.refresh()
                if !id.isEmpty { open(id) }
            })
        }
        .sheet(isPresented: $showHub) {
            NavigationStack { CloudBotHubView(onDone: { showHub = false }) }
        }
        .sheet(isPresented: $showConnectApps) {
            CloudConnectAppsSheet(onClose: { showConnectApps = false })
                .presentationDetents([.large])
        }
        .task {
            // 进入多 Bot 模式即后台连接并定期刷新（列表的运行 / 待审批 / 未读状态）
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func open(_ id: String) {
        model.markSeen(id)
        path = [id]
    }

    private func hero(_ bot: CloudBot) -> some View {
        Button { open(bot.id) } label: {
            VStack(spacing: 10) {
                CloudBotBlobAvatar(bot: bot, size: 96, dark: true)
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
                if bot.waitingApprovals > 0 {
                    Text("⏳ 等待你审批").font(.caption).foregroundStyle(.orange)
                } else if bot.runningTasks > 0 {
                    Text("正在处理…").font(.caption).foregroundStyle(.green)
                }
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
                TextField("搜索", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                NavigationLink(destination: CloudPagesView()) { Label("页面", systemImage: "doc.richtext") }
                NavigationLink(destination: CloudComputerView(botId: nil, sessionId: nil, reason: nil)) { Label("云电脑桌面", systemImage: "display") }
            }
            Section {
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

    var body: some View {
        Group {
            if let sid = sessionId, let bot = model.bot(botId) {
                CloudSessionView(sessionId: sid, sessionTitle: bot.name,
                                 model: UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "",
                                 selectedInstanceId: UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "",
                                 botHasOwnModel: bot.hasOwnModel,
                                 mentionBots: model.bots.filter { $0.id != botId },
                                 theme: CloudBotChatTheme(botId: bot.id, name: bot.name, spec: CloudBotAvatarSpec.of(bot)))
                    .id(sid)
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
                        if let sid = sessionId {
                            Button { speakLatest(sid) } label: { Label("朗读最新回复", systemImage: "speaker.wave.2") }
                            Button { showComputer = true } label: { Label("电脑", systemImage: "display") }
                        }
                        if history.count > 1 {
                            Section("历史对话") {
                                ForEach(history.indices, id: \.self) { i in
                                    let sid = history[i]["session_id"] as? String ?? ""
                                    Button(history[i]["title"] as? String ?? sid) { sessionId = sid }
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
        do {
            try await CloudConnection.shared.ensureConnected()
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
                    sessionId = try await CloudBotService.newSession(bot)
                }
            }
            model.markSeen(botId)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func startNew() async {
        guard let bot = model.bot(botId) else { return }
        do {
            sessionId = try await CloudBotService.newSession(bot)
            history = (try? await CloudBotService.sessions(botId)) ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }
}
