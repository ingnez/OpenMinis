//
//  CloudBotHomeMenu.swift
//  Minis - Minis Bot 首页长按 Bot（主 Bot 大卡片和列表行）：系统菜单，上面是预览卡片（头像 + 名字 + 最后一条消息），
//  下面是 标为未读 / 置顶 / 替换主 Bot / 分享为模板 / 隐藏 / 更多（重命名、编辑设置、/reset、删除）。
//  菜单挂在按钮上（.contextMenu），点一下照常打开对话。
//

import SwiftUI
import UIKit

/// 菜单要首页做的事（弹窗 / 跳转由首页负责）
struct CloudBotMenuActions {
    var rename: (CloudBot) -> Void
    var edit: (CloudBot) -> Void
    var pickPrimary: () -> Void
    var share: (CloudBot) -> Void
    var delete: (CloudBot) -> Void
}

struct CloudBotContextMenu: ViewModifier {
    let bot: CloudBot
    @ObservedObject var model: CloudBotHomeModel
    let actions: CloudBotMenuActions

    func body(content: Content) -> some View {
        content.contextMenu {
            menuItems
        } preview: {
            CloudBotMenuPreview(bot: bot)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        let unread = model.isUnread(bot)
        Button { model.markUnread(bot.id, !unread) } label: {
            Label(unread ? "标为已读" : "标为未读", systemImage: unread ? "envelope.open" : "envelope.badge")
        }
        Button { model.setPrefs(bot.id, ["pinned": !bot.pinned]) } label: {
            Label(bot.pinned ? "取消置顶" : "置顶", systemImage: bot.pinned ? "pin.slash" : "pin")
        }
        if bot.isPrimary {
            Button { actions.pickPrimary() } label: { Label("替换主 Bot…", systemImage: "arrow.triangle.2.circlepath") }
        } else {
            Button { Task { await model.makePrimary(bot.id) } } label: { Label("设为主 Bot", systemImage: "star") }
        }
        Button { actions.share(bot) } label: { Label("分享为模板…", systemImage: "square.and.arrow.up") }
        if !bot.isPrimary {
            Button(role: .destructive) { model.setPrefs(bot.id, ["hidden": true]) } label: { Label("隐藏", systemImage: "eye.slash") }
        }
        Menu {
            Button { actions.rename(bot) } label: { Label("重命名", systemImage: "pencil") }
            Button { actions.edit(bot) } label: { Label("编辑设置", systemImage: "slider.horizontal.3") }
            if bot.latestSessionId != nil {
                Button { Task { await model.resetContext(bot.id) } } label: {
                    Label("/reset 上下文", systemImage: "arrow.counterclockwise.circle")
                }
            }
            if !bot.isPrimary {
                Button(role: .destructive) { actions.delete(bot) } label: { Label("删除", systemImage: "trash") }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }
}

/// 长按时浮起的预览卡片
struct CloudBotMenuPreview: View {
    let bot: CloudBot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CloudBotAliveAvatar(spec: CloudBotAvatarSpec.of(bot), size: 44, interactive: false)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(bot.name).font(.headline).lineLimit(1)
                        if bot.isPrimary { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                        if bot.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if !bot.summary.isEmpty {
                        Text(bot.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if CloudBotLock.isLockedStored(bot.id) {
                Text("已上锁").font(.subheadline).foregroundStyle(.secondary)
            } else if bot.lastPreview.isEmpty {
                Text("还没有对话").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack {
                    if bot.lastRole == "user" { Spacer(minLength: 30) }
                    Text(CloudMessageText.display(bot.lastPreview).text)
                        .font(.subheadline)
                        .lineLimit(5)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 16)
                            .fill(bot.lastRole == "user" ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground)))
                    if bot.lastRole != "user" { Spacer(minLength: 30) }
                }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Color(.systemBackground))
    }
}

/// 替换主 Bot：选一个别的 Bot 接任（管理权限一起转过去）
struct CloudPrimaryPicker: View {
    @ObservedObject var model: CloudBotHomeModel
    let onDone: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("新的主 Bot 会接管所有管理权限（新建、删除 Bot、改设置等），原来的主 Bot 立刻失去这些权限。操作会记在操作记录里，可撤销。")) {
                    ForEach(model.bots.filter { !$0.isPrimary }) { bot in
                        Button {
                            Task { await model.makePrimary(bot.id); onDone() }
                        } label: {
                            HStack(spacing: 10) {
                                CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: 30)
                                Text(bot.name).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("替换主 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { onDone() } } }
        }
    }
}

/// 已隐藏的 Bot：取消隐藏
struct CloudHiddenBotsSheet: View {
    @ObservedObject var model: CloudBotHomeModel
    let onDone: () -> Void

    var body: some View {
        NavigationView {
            List {
                if model.hiddenBots.isEmpty {
                    Text("没有隐藏的 Bot").foregroundStyle(.secondary)
                }
                ForEach(model.hiddenBots) { bot in
                    HStack(spacing: 10) {
                        CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: 30)
                        Text(bot.name)
                        Spacer()
                        Button("取消隐藏") { model.setPrefs(bot.id, ["hidden": false]) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle("已隐藏的 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { onDone() } } }
        }
    }
}

extension View {
    func cloudBotMenu(_ bot: CloudBot, model: CloudBotHomeModel, actions: CloudBotMenuActions) -> some View {
        modifier(CloudBotContextMenu(bot: bot, model: model, actions: actions))
    }
}

/// 首页长按菜单用到的弹窗（单独拆出来，首页 body 的修饰链太长编译器会超时）
struct CloudBotHomeMenuSheets: ViewModifier {
    @ObservedObject var model: CloudBotHomeModel
    @Binding var showPrimaryPicker: Bool
    @Binding var showHidden: Bool
    @Binding var renaming: CloudBot?
    @Binding var renameText: String
    @Binding var deleting: CloudBot?
    @Binding var shareURL: URL?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showPrimaryPicker) {
                CloudPrimaryPicker(model: model, onDone: { showPrimaryPicker = false })
            }
            .sheet(isPresented: $showHidden) {
                CloudHiddenBotsSheet(model: model, onDone: { showHidden = false })
            }
            .sheet(isPresented: shareShown) {
                if let url = shareURL { CloudActivitySheet(items: [url]) }
            }
            .alert("重命名", isPresented: renameShown) {
                TextField("名字", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { saveRename() }
            }
            .confirmationDialog("删除这个 Bot？", isPresented: deleteShown, titleVisibility: .visible) {
                Button("删除（放进回收站）", role: .destructive) { confirmDelete() }
            } message: {
                Text("记忆和聊天记录会保留，可以在操作记录里撤销恢复。")
            }
    }

    private var shareShown: Binding<Bool> {
        Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func saveRename() {
        if let bot = renaming {
            let name = renameText
            Task { await model.rename(bot.id, to: name) }
        }
        renaming = nil
    }

    private func confirmDelete() {
        if let bot = deleting { Task { await model.softDelete(bot.id) } }
        deleting = nil
    }
}
