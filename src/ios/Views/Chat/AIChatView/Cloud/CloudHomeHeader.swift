//
//  CloudHomeHeader.swift
//  Minis - Bot 首页顶栏（11-11 改成 Grok Bot 风格）：中间不再放「Minis Bot ⌄」切换器，
//  左上角仍是齿轮（右上角一个连接状态小点），点一下打开 Bot 设置，长按弹出本地 / 云端快速切换；
//  有 Bot 在后台干活时中间空位飘出一行「SWE 正在构建…」，点一下进对话，干完自动消失；
//  下拉首页露出「今天」卡片。「模式」选择页本地 / 云端两边的设置共用。
//

import SwiftUI

/// 「模式」选择页：两行打勾，选另一种立刻切过去（先关掉所在的设置页再切，避免 sheet 跟着首页一起被拆掉）
struct HomeModePicker: View {
    /// 这个设置页属于哪种模式（打勾的那一行）
    let current: HomeMode
    /// 关掉所在的设置 sheet
    var dismiss: () -> Void = {}
    @AppStorage(CloudBotHome.modeKey) private var homeMode: String = "local"

    var body: some View {
        List {
            Section {
                ForEach(HomeMode.allCases) { mode in
                    Button { pick(mode) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbol).frame(width: 24).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).foregroundStyle(.primary)
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mode == current {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("homeMode.\(mode.rawValue)")
                    .accessibilityAddTraits(mode == current ? .isSelected : [])
                }
            } footer: {
                Text("两种模式的设置、对话各自独立，随时可以切回来。")
            }
        }
        .navigationTitle("模式")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ mode: HomeMode) {
        guard mode != current else { return }
        CloudHaptics.tap()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { homeMode = mode.rawValue }
    }
}

/// 设置里的「模式」一行（本地设置和 Bot 设置都放）
struct HomeModeRow: View {
    let current: HomeMode
    var dismiss: () -> Void = {}

    var body: some View {
        NavigationLink { HomeModePicker(current: current, dismiss: dismiss) } label: {
            HStack {
                Label("模式", systemImage: "arrow.left.arrow.right.circle")
                Spacer()
                Text(current.title).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("homeModeRow")
    }
}

/// 左上角齿轮（和本地模式一样的系统工具栏样式，iOS 26 上是玻璃按钮）：点一下打开 Bot 设置（里面有「模式」），
/// 长按弹出本地 / 云端快速切换。连接状态改由主 Bot 星标颜色表示（H2）
struct CloudSettingsGearButton: View {
    var onTap: () -> Void
    var onAppSettings: () -> Void
    var onSwitch: (HomeMode) -> Void
    @ObservedObject private var link = CloudLinkSupervisor.shared

    var body: some View {
        Menu {
            Section("切换模式") {
                Button { onSwitch(.local) } label: { Label(HomeMode.local.title, systemImage: HomeMode.local.symbol) }
                Button {} label: { Label(HomeMode.bots.title + " ✓", systemImage: HomeMode.bots.symbol) }
            }
            Button { onTap() } label: { Label("Bot 设置（模式、云电脑、保管库）", systemImage: "gear") }
            Button { onAppSettings() } label: { Label("App 通用设置", systemImage: "slider.horizontal.3") }
        } label: {
            // H2：齿轮上不再有状态小点，连接状态看主 Bot 星标的颜色（VoiceOver 仍读得到）
            Image(systemName: "gear")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        } primaryAction: {
            onTap()
        }
        .accessibilityIdentifier("settingsGear")
        .accessibilityLabel("设置")
        .accessibilityValue(CloudHomeHeaderRules.dotText(dot))
        .accessibilityHint("长按切换本地 / 云端模式")
    }

    private var dot: CloudHomeHeaderRules.Dot { CloudHomeHeaderRules.dot(link.headerLink) }
}

/// 顶栏中间：平时空着；有 Bot 在后台干活时淡入一行小字，点一下进对话
struct CloudHomeCenterStatus: View {
    @ObservedObject var model: CloudBotHomeModel
    let open: (String) -> Void

    var body: some View {
        let working = model.bots.filter { $0.activity != nil && !CloudBotLock.shared.isLocked($0.id) }
        ZStack {
            if let first = working.first,
               let line = CloudHomeHeaderRules.centerLine(working.map { (name: $0.name, label: $0.activity?.shortLabel ?? "") }) {
                Button { open(first.id) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(CloudBotAvatarSpec.of(first).fill).frame(width: 6, height: 6)
                        Text(line).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("homeCenterStatus")
                .accessibilityLabel(line)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 42956011241：首页打开时没人干活，这一格量出来是 0 宽，之后 Bot 开工也不会重新撑开（iOS 26 工具栏只量一次）。
        // 固定一个看不见的框，空着时不挡点按
        .frame(width: 230, height: 30)
        .animation(.easeInOut(duration: 0.3), value: working.map(\.id))
    }
}

/// 下拉首页露出的「今天」统计栏：在跑的 Bot、今天有消息、云电脑在线 / 离线。
/// 点前两格在下面展开小窗口（互斥，再点同一格收回）；「云电脑」格只显示状态。
struct CloudTodayCard: View {
    @ObservedObject var model: CloudBotHomeModel
    let open: (String) -> Void
    @ObservedObject private var link = CloudLinkSupervisor.shared
    @State private var panel: CloudTodayPanel?

    /// 「今天有消息」小窗口的一条
    struct Entry: Identifiable {
        let id: String
        let bot: CloudBot?
        let title: String
        let text: String
        let at: Date
        let feed: CloudFeedItem?
    }

    private var working: [CloudBot] {
        model.bots.filter { $0.activity != nil && !CloudBotLock.shared.isLocked($0.id) }
    }

    /// 今天的主动消息 / 例行结果（全文），加上今天聊过的 Bot（聊天最后一条），新的在前
    private var entries: [Entry] {
        let start = Calendar.current.startOfDay(for: Date())
        var out: [Entry] = []
        for b in model.bots where !CloudBotLock.shared.isLocked(b.id) && b.lastAt >= start.timeIntervalSince1970 {
            out.append(Entry(id: "chat:" + b.id, bot: b, title: b.name, text: b.lastPreview,
                             at: Date(timeIntervalSince1970: b.lastAt), feed: nil))
        }
        for f in model.feed where f.at >= start && !CloudBotLock.shared.isLocked(f.botId) {
            let bot = model.bots.first { $0.id == f.botId }
            out.append(Entry(id: "feed:" + f.id, bot: bot, title: f.proactive ? "\(bot?.name ?? "Bot") 找你" : f.title,
                             text: CloudMessageText.display(f.text).text, at: f.at, feed: f))
        }
        return out.sorted { $0.at > $1.at }
    }

    var body: some View {
        let online = link.state == .online
        let list = entries
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                cell(.running, "\(working.count)", "在跑的 Bot", "bolt.fill", .orange)
                Divider().frame(height: 34)
                cell(.messages, "\(list.count)", "今天有消息", "bubble.left.and.bubble.right.fill", .blue)
                Divider().frame(height: 34)
                info(online ? "在线" : "离线", "云电脑", "desktopcomputer", online ? .green : .gray)
            }
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            .overlay(alignment: .topLeading) {
                Text("今天").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, -16)
            }
            if panel == .running {
                runningPanel.transition(.opacity.combined(with: .move(edge: .top)))
            } else if panel == .messages {
                messagesPanel(list).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("todayCard")
    }

    private func cell(_ kind: CloudTodayPanel, _ value: String, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        Button {
            CloudHaptics.tap()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { panel = CloudTodayPanel.toggle(panel, tapped: kind) }
        } label: {
            info(value, title, symbol, tint)
                .background(RoundedRectangle(cornerRadius: 10).fill(panel == kind ? tint.opacity(0.12) : .clear).padding(.horizontal, 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("todayCell.\(kind.rawValue)")
        .accessibilityValue(panel == kind ? "已展开" : "已收起")
    }

    private func info(_ value: String, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption).foregroundStyle(tint)
                Text(value).font(.headline.monospacedDigit())
            }
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if working.isEmpty {
                Text("现在没有 Bot 在干活").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(working) { b in
                Button { open(b.id) } label: {
                    HStack(spacing: 10) {
                        CloudBotAvatarView(spec: CloudBotAvatarSpec.of(b), size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(b.activity?.subtitle ?? "正在干活").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todayRunning-\(b.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("todayRunningPanel")
    }

    private func messagesPanel(_ list: [Entry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if list.isEmpty {
                    Text("今天还没有消息").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(list) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        messageRow(e)
                        if let f = e.feed { CloudFeedFeedbackBar(item: f).padding(.leading, 36) }   // 赞 / 踩 / 评论，Bot 据此调整主动消息
                    }
                    if e.id != list.last?.id { Divider() }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: list.count <= 2)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .accessibilityIdentifier("todayMessagesPanel")
    }

    @ViewBuilder private func messageRow(_ e: Entry) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            if let bot = e.bot {
                CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 26)
            } else {
                Image(systemName: "clock.arrow.circlepath").frame(width: 26, height: 26).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(e.at, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                Self.richText(e.text).font(.callout).foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        if let f = e.feed, !f.sessionId.isEmpty {
            NavigationLink {
                CloudSessionView(sessionId: f.sessionId, sessionTitle: f.proactive ? (e.bot?.name ?? f.title) : f.title,
                                 model: UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "",
                                 selectedInstanceId: UserDefaults.standard.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "",
                                 botHasOwnModel: e.bot?.hasOwnModel ?? false, theme: e.bot.map { CloudBotChatTheme(bot: $0) })
            } label: { content }
            .buttonStyle(.plain)
            .accessibilityIdentifier("todayMessage-\(e.id)")
        } else if let bot = e.bot {
            Button { open(bot.id) } label: { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todayMessage-\(e.id)")
        } else {
            content.accessibilityIdentifier("todayMessage-\(e.id)")
        }
    }

    /// Markdown 正文：加粗成段，其余记号去掉（星号不露出来）
    static func richText(_ s: String) -> Text {
        CloudPreviewText.rich(s).reduce(Text("")) { acc, seg in
            acc + (seg.bold ? Text(seg.text).bold() : Text(seg.text))
        }
    }
}

/// 读滚动位置：首页内容顶部相对滚动视图的 y（下拉为正）
/// 可选值：VStack 里别的子视图不设这个偏好时贡献的是 defaultValue，以前 reduce 直接用 nextValue()
/// 会被后面兄弟视图的 0 盖掉，下拉永远读到 0（42963481185 test13「今天」卡片不出来）
struct CloudHomeScrollTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

struct CloudHomeScrollProbe: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: CloudHomeScrollTopKey.self, value: g.frame(in: .named("cloudHomeScroll")).minY)
        }
        .frame(height: 0)
    }
}

extension CloudLinkSupervisor {
    /// 齿轮的 VoiceOver 状态、主 Bot 星标颜色共用
    var headerLink: CloudHomeHeaderRules.Link {
        switch state {
        case .online: return .online(needsAttention: serverOutdated || desktopProblem != nil)
        case .connecting: return .connecting
        case .retrying: return .retrying
        case .offline: return .offline
        case .idle: return .idle
        }
    }
}
