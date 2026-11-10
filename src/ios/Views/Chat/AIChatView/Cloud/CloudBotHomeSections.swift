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

/// 顶部一排：主 Bot（橙色星标）和置顶的 Bot，大头像，横向滚动
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
                        CloudBotTopAvatar(bot: bot, unread: model.isUnread(bot), size: items.count == 1 ? 96 : 72) { open(bot.id) }
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
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                CloudBotAliveAvatar(spec: CloudBotAvatarSpec.of(bot), size: size, interactive: false)
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottomTrailing) { badge }
                    .overlay(alignment: .topTrailing) {
                        if unread { Circle().fill(Color.blue).frame(width: 12, height: 12) }
                    }
                Text(bot.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    .frame(maxWidth: size + 20)
                let status = CloudBotStatus.of(bot)
                if status.busy { CloudBotStatusChip(status: status) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 \(bot.name)")
    }

    @ViewBuilder
    private var badge: some View {
        if bot.isPrimary {
            ZStack {
                Circle().fill(Color(.systemBackground)).frame(width: 28, height: 28)
                Circle().fill(Color.orange).frame(width: 22, height: 22)
                Image(systemName: "star.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
            .offset(x: 4, y: 4)
        } else if CloudBotStatus.of(bot).busy {
            Circle().fill(Color.green).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
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

    var body: some View {
        let bots = model.listed(matching: search)
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let known = Set(model.sections.map(\.id))
        let loose = searching ? bots : bots.filter { $0.sectionId == nil || !known.contains($0.sectionId ?? "") }
        LazyVStack(spacing: 0) {
            ForEach(loose) { bot in row(bot) }
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

    private func row(_ bot: CloudBot) -> some View {
        CloudSwipeRow(pinned: bot.pinned,
                      onPin: { model.setPrefs(bot.id, ["pinned": !bot.pinned]) },
                      onHide: { model.setPrefs(bot.id, ["hidden": true]) }) {
            Button { open(bot.id) } label: {
                CloudBotHomeRow(bot: bot, unread: model.isUnread(bot))
            }
            .buttonStyle(.plain)
            .cloudBotMenu(bot, model: model, actions: actions)
        }
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
            ForEach(bots) { bot in row(bot) }
        }
    }
}

/// 行左滑：露出「置顶」（灰）和「隐藏」（红）两个圆按钮。横向拖动才算，竖向滚动和点按不受影响。
struct CloudSwipeRow<Content: View>: View {
    let pinned: Bool
    let onPin: () -> Void
    let onHide: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var open = false
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
                .offset(x: offset)
                .allowsHitTesting(!open)
                .overlay {
                    if open {
                        // 打开时点一下行收起
                        Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                            .padding(.trailing, reveal)
                    }
                }
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    let base: CGFloat = open ? -reveal : 0
                    offset = min(0, max(-reveal - 30, base + v.translation.width))
                }
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
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
