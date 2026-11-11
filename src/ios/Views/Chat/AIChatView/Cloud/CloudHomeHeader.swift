//
//  CloudHomeHeader.swift
//  Minis - Bot 首页顶栏（11-11 改成 Grok Bot 风格）：中间不再放「Minis Bot ⌄」切换器，
//  左上角是用户首字母圆头像（右下角连接状态点），点一下打开 Bot 设置，长按弹出本地 / 云端快速切换；
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

/// 左上角的用户圆头像：首字母（没填名字时是人像），右下角是云端连接状态点（替代以前标题旁的绿点）
struct CloudUserAvatarButton: View {
    var onTap: () -> Void
    var onAppSettings: () -> Void
    var onSwitch: (HomeMode) -> Void
    @ObservedObject private var link = CloudLinkSupervisor.shared
    @AppStorage(CloudHomeHeaderRules.userNameKey) private var userName: String = ""

    var body: some View {
        Menu {
            Section("切换模式") {
                Button { onSwitch(.local) } label: { Label(HomeMode.local.title, systemImage: HomeMode.local.symbol) }
                Button {} label: { Label(HomeMode.bots.title + " ✓", systemImage: HomeMode.bots.symbol) }
            }
            Button { onTap() } label: { Label("Bot 设置（模式、云电脑、保管库）", systemImage: "gear") }
            Button { onAppSettings() } label: { Label("App 通用设置", systemImage: "slider.horizontal.3") }
        } label: {
            avatar.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        } primaryAction: {
            onTap()
        }
        .accessibilityIdentifier("userAvatar")
        .accessibilityLabel("设置")
        .accessibilityValue([CloudHomeHeaderRules.initials(userName), CloudHomeHeaderRules.dotText(dot)].compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint("长按切换本地 / 云端模式")
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color.indigo, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let text = CloudHomeHeaderRules.initials(userName) {
                Text(text).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .minimumScaleFactor(0.6).lineLimit(1).padding(3)
            } else {
                Image(systemName: "person.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 32, height: 32)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                .offset(x: 2, y: 2)
                .animation(.easeInOut(duration: 0.3), value: dot)
        }
    }

    private var dot: CloudHomeHeaderRules.Dot {
        switch link.state {
        case .online: return CloudHomeHeaderRules.dot(.online(needsAttention: link.serverOutdated || link.desktopProblem != nil))
        case .connecting: return CloudHomeHeaderRules.dot(.connecting)
        case .retrying: return CloudHomeHeaderRules.dot(.retrying)
        case .offline: return CloudHomeHeaderRules.dot(.offline)
        case .idle: return CloudHomeHeaderRules.dot(.idle)
        }
    }

    private var dotColor: Color {
        switch dot { case .green: return .green; case .yellow: return .yellow; case .gray: return Color(.systemGray3) }
    }
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
        .animation(.easeInOut(duration: 0.3), value: working.map(\.id))
    }
}

/// 下拉首页露出的「今天」卡片：在跑的 Bot、今天有消息的对话、云电脑在线 / 离线
struct CloudTodayCard: View {
    @ObservedObject var model: CloudBotHomeModel
    @ObservedObject private var link = CloudLinkSupervisor.shared

    var body: some View {
        let counts = CloudHomeHeaderRules.todayCounts(lastAts: model.bots.map(\.lastAt), workingCount: model.typingIds.count)
        let online = link.state == .online
        HStack(spacing: 0) {
            cell("\(counts.running)", "在跑的 Bot", "bolt.fill", .orange)
            Divider().frame(height: 34)
            cell("\(counts.chatsToday)", "今天有消息", "bubble.left.and.bubble.right.fill", .blue)
            Divider().frame(height: 34)
            cell(online ? "在线" : "离线", "云电脑", "desktopcomputer", online ? .green : .gray)
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
        .overlay(alignment: .topLeading) {
            Text("今天").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, -16)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("todayCard")
    }

    private func cell(_ value: String, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption).foregroundStyle(tint)
                Text(value).font(.headline.monospacedDigit())
            }
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 读滚动位置：首页内容顶部相对滚动视图的 y（下拉为正）
struct CloudHomeScrollTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct CloudHomeScrollProbe: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: CloudHomeScrollTopKey.self, value: g.frame(in: .named("cloudHomeScroll")).minY)
        }
        .frame(height: 0)
    }
}
