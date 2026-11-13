//
//  CloudBotHomeSections.swift
//  Minis - Minis Bot 首页的几块：顶部一排大头像（主 Bot + 置顶），按分组显示的 Bot 列表（分组可折叠），
//  行左滑露出「置顶 / 隐藏」两个圆按钮，以及「已隐藏对话」页。都拆成小视图，免得首页 body 类型检查超时。
//

import SwiftUI
import UIKit

struct CloudBotSection: Identifiable, Equatable {
    let id: String
    var name: String
    var collapsed: Bool

    init?(_ d: [String: Any]) {
        guard let sid = d["section_id"] as? String, let name = d["name"] as? String else { return nil }
        id = sid
        self.name = name
        collapsed = d["collapsed"] as? Bool ?? false
    }
}

/// 顶部一排：主 Bot（状态星标）和置顶的 Bot，大头像，横向滚动
struct CloudBotTopRow: View {
    @ObservedObject var model: CloudBotHomeModel
    let actions: CloudBotMenuActions
    let open: (String) -> Void

    var body: some View {
        let items = model.topRow
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: items.count == 1 ? 0 : 18) {
                    ForEach(items) { bot in
                        CloudBotTopAvatar(bot: bot, unread: model.isUnread(bot), presence: model.presence(bot), size: items.count == 1 ? 96 : 72) { open(bot.id) }
                            .cloudBotMenu(bot, model: model, actions: actions)
                    }
                }
                .padding(.horizontal, 20)
                .frame(minWidth: UIScreen.main.bounds.width)
            }
            .padding(.top, 8).padding(.bottom, 14)
        }
    }
}

struct CloudBotTopAvatar: View {
    let bot: CloudBot
    let unread: Bool
    var presence = CloudBotPresence(state: .idle, unread: 0, routine: .none, muted: false)
    let size: CGFloat
    let onTap: () -> Void
    @ObservedObject private var link = CloudLinkSupervisor.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            avatarButton
            // 星标状态给 VoiceOver / XCUITest 读：和头像按钮并列的独立元素（放在按钮的 background 里会被并进按钮，43151506030）。
            // 只读、不可点；说明在长按菜单里
            if bot.isPrimary {
                Color.clear.frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier("primaryStarBadge")
                    .accessibilityLabel(star.text)
                    .accessibilityValue(star.tone.rawValue)
            }
        }
    }

    private var avatarButton: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                CloudBotAliveAvatar(spec: CloudBotAvatarSpec.of(bot), size: size, interactive: false,
                                    mood: presence.state == .error ? .frown : .calm, working: typing != nil)
                    .allowsHitTesting(false)
                    // 主 Bot 用星标和下方的状态文字；其他置顶 Bot 正在回复时显示光环。
                    .overlay {
                        if !bot.isPrimary, typing != nil {
                            CloudWorkingRing(color: CloudBotAvatarSpec.of(bot).fill)
                                .padding(-6)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: typing != nil)
                    .overlay(alignment: .bottomTrailing) { badge }
                    // H2：主 Bot 不再在左下角另放状态点，状态体现在星标颜色上；其它 Bot 的状态点照旧在右下
                    .overlay(alignment: .bottomTrailing) {
                        if !bot.isPrimary { CloudPresenceBadge(presence: presence, size: max(12, size * 0.16)) }
                    }
                HStack(spacing: 5) {
                    Text(bot.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    CloudPresenceFlags(presence: presence)
                    CloudUnreadMark(presence: presence)
                }
                .frame(maxWidth: size + 40)
                let status = CloudBotStatus.of(bot)
                if let typing {
                    Text(typing.shortLabel).font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                } else if status.busy { CloudBotStatusChip(status: status) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 \(bot.name)，\(presence.accessibilityText)")
        .accessibilityValue(presence.state == .error ? "皱眉" : (typing != nil ? "思考中眨眼" : "平静"))
    }

    private var typing: CloudTypingPhase? { CloudBotLock.shared.isLocked(bot.id) ? nil : bot.activity }

    /// 主 Bot 星标颜色：绿 = 正常，黄 = 连接中 / 有事要处理，红 = 断开 / 出错（只变色，不可点，免得误点进聊天）
    private var star: (tone: CloudHomeHeaderRules.StarTone, text: String) {
        CloudHomeHeaderRules.star(link.headerLink, botError: presence.state == .error)
    }

    private var starColor: Color {
        switch star.tone { case .green: return .green; case .yellow: return .yellow; case .red: return .red }
    }

    @ViewBuilder
    private var badge: some View {
        if bot.isPrimary {
            ZStack {
                Circle().fill(Color(.systemBackground)).frame(width: 28, height: 28)
                Circle().fill(starColor).frame(width: 22, height: 22)
                Image(systemName: "star.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
            .offset(x: 4, y: 4)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.3), value: star.tone)
        }
    }
}

/// Bot 列表：未分组的在前，后面每个分组一个可折叠的小节
struct CloudBotSectionedList: View {
    @ObservedObject var model: CloudBotHomeModel
    let search: String
    let actions: CloudBotMenuActions
    let open: (String) -> Void
    @State private var renamingSection: CloudBotSection?
    @State private var sectionName = ""
    @AppStorage(CloudHomeLayout.key) private var layoutRaw: String = CloudHomeLayout.list.rawValue

    var body: some View {
        let bots = model.listed(matching: search)
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let known = Set(model.sections.map(\.id))
        let loose = searching ? bots : bots.filter { $0.sectionId == nil || !known.contains($0.sectionId ?? "") }
        LazyVStack(spacing: 0) {
            group(loose)
            if !searching {
                ForEach(model.sections) { sec in
                    sectionView(sec, bots: bots.filter { $0.sectionId == sec.id })
                }
            }
        }
        .alert("重命名分组", isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })) {
            TextField("分组名", text: $sectionName)
            Button("取消", role: .cancel) { renamingSection = nil }
            Button("保存") {
                if let sec = renamingSection { model.sectionAction("rename", sec, name: sectionName) }
                renamingSection = nil
            }
        }
    }

    /// 按首页布局排：列表 = 一行一个（可左滑）；网格 / 卡片 = 方块（长按菜单）
    @ViewBuilder private func group(_ bots: [CloudBot]) -> some View {
        let layout = CloudHomeLayout(rawValue: layoutRaw) ?? .list
        if layout == .list {
            ForEach(bots) { bot in row(bot) }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: layout.columns), spacing: 12) {
                ForEach(bots) { bot in
                    Button { open(bot.id) } label: {
                        CloudBotHomeTile(bot: bot, unread: model.isUnread(bot), presence: model.presence(bot), card: layout == .card)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("homeBotRow-\(bot.id)")
                    .cloudBotMenu(bot, model: model, actions: actions)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func row(_ bot: CloudBot) -> some View {
        // H3：点按交给 CloudSwipeRow 处理（以前行里是 Button，左滑抬手时也算一次点按，直接进了聊天）
        CloudSwipeRow(pinned: bot.pinned,
                      onPin: { model.setPrefs(bot.id, ["pinned": !bot.pinned]) },
                      onHide: { model.setPrefs(bot.id, ["hidden": true]) },
                      onTap: { open(bot.id) }) {
            CloudBotHomeRow(bot: bot, unread: model.isUnread(bot), presence: model.presence(bot))
                .cloudBotMenu(bot, model: model, actions: actions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeBotRow-\(bot.id)")
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func sectionView(_ sec: CloudBotSection, bots: [CloudBot]) -> some View {
        Button {
            CloudHaptics.selection()
            withAnimation(.easeInOut(duration: 0.2)) { model.sectionAction("toggle", sec) }
        } label: {
            HStack(spacing: 6) {
                Text(sec.name).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(bots.count)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: sec.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { sectionName = sec.name; renamingSection = sec } label: { Label("重命名分组", systemImage: "pencil") }
            Button(role: .destructive) { model.sectionAction("delete", sec) } label: { Label("删除分组（Bot 保留）", systemImage: "trash") }
        }
        if !sec.collapsed {
            group(bots)
        }
    }
}

/// 行左滑：露出「置顶」（灰）和「隐藏」（红）两个圆按钮。横向拖动才算，竖向滚动不受影响。
/// 点按也在这里处理：横向拖过门槛就不算点按；行滑开时点一下只收起；两个圆按钮只做自己的事。
struct CloudSwipeRow<Content: View>: View {
    let pinned: Bool
    let onPin: () -> Void
    let onHide: () -> Void
    var onTap: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var open = false
    /// 最近一次横向拖动的时间：抬手后紧跟着到的点按当作拖动的一部分丢掉
    @State private var lastSwipe = Date.distantPast
    private let reveal: CGFloat = 124

    var body: some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                HStack(spacing: 14) {
                    circle(pinned ? "pin.slash.fill" : "pin.fill", color: Color(.systemGray), label: pinned ? "取消置顶" : "置顶") { onPin() }
                    circle("eye.slash.fill", color: .red, label: "隐藏") { onHide() }
                }
                .padding(.trailing, 4)
                .opacity(min(1, Double(-offset / reveal)))
            }
            content()
                .contentShape(Rectangle())
                .onTapGesture { tapped() }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tapped() }
                .offset(x: offset)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    lastSwipe = Date()
                    let base: CGFloat = open ? -reveal : 0
                    offset = min(0, max(-reveal - 30, base + v.translation.width))
                }
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    lastSwipe = Date()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        open = offset < -reveal / 2
                        offset = open ? -reveal : 0
                    }
                }
        )
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open = false; offset = 0 }
    }

    private func tapped() {
        if open || offset != 0 { close(); return }                       // 滑开时点一下只收起
        guard Date().timeIntervalSince(lastSwipe) > 0.35 else { return }  // 刚拖完的抬手不算点按
        onTap?()
    }

    private func circle(_ icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button {
            CloudHaptics.tap()
            action()
            close()
        } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 「已隐藏对话」页：取消隐藏；右上角 ? 说明隐藏的含义
struct CloudHiddenBotsPage: View {
    @ObservedObject var model: CloudBotHomeModel
    @State private var showHelp = false

    var body: some View {
        List {
            if model.hiddenBots.isEmpty {
                Text("没有隐藏的对话").foregroundStyle(.secondary)
            }
            ForEach(model.hiddenBots) { bot in
                HStack(spacing: 12) {
                    CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: 40)
                    Text(bot.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer()
                    Button {
                        CloudHaptics.tap()
                        model.setPrefs(bot.id, ["hidden": false])
                    } label: {
                        Text("取消隐藏").font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color(.systemGray5)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .navigationTitle("已隐藏对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("说明")
            }
        }
        .alert("隐藏是什么意思？", isPresented: $showHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("隐藏只是不在首页列表里显示。这个 Bot 的消息、记忆和例行任务都还在，照常运行，有新消息也会照常通知你。随时可以在这里取消隐藏。")
        }
    }
}

/// 列表底部「已隐藏 N 个」
struct CloudHiddenFooter: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        if count > 0 {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash").font(.caption)
                    Text("已隐藏 \(count) 个").font(.footnote)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }
}
