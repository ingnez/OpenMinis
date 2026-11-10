import SwiftUI

/// iPad / Mac 上的三栏：左边 Bot 和群聊列表，中间对话，右边这个 Bot 的详情（记忆、插件、设置）。
/// iPhone（紧凑宽度）仍用原来的单栏首页，标题栏不变。
struct CloudBotSplitHome: View {
    @ObservedObject var model: CloudBotHomeModel
    let openHub: () -> Void
    let newBot: () -> Void
    @Binding var selection: String?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            CloudBotSplitSidebar(model: model, selection: $selection)
                .navigationTitle("Minis Bot")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: openHub) { Image(systemName: "gearshape") }.accessibilityLabel("设置")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: newBot) { Image(systemName: "plus") }.accessibilityLabel("新 Bot")
                    }
                }
        } content: {
            CloudBotSplitContent(selection: selection)
        } detail: {
            CloudBotSplitDetail(model: model, selection: selection)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { id in
            if let id, !id.hasPrefix("group:") { model.markSeen(id) }
        }
    }
}

struct CloudBotSplitSidebar: View {
    @ObservedObject var model: CloudBotHomeModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if !model.groups.isEmpty {
                Section("群聊") {
                    ForEach(model.groups) { g in
                        CloudGroupHomeRow(group: g, bots: model.bots).tag("group:" + g.id)
                    }
                }
            }
            Section("Bot") {
                ForEach(model.bots.filter { !$0.hidden }) { bot in
                    CloudBotHomeRow(bot: bot, unread: model.isUnread(bot)).tag(bot.id)
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { await model.refresh() }
        .overlay { if model.bots.isEmpty && model.loaded { Text("还没有 Bot").foregroundStyle(.secondary) } }
    }
}

struct CloudBotSplitContent: View {
    let selection: String?

    var body: some View {
        if let id = selection {
            NavigationStack {
                if id.hasPrefix("group:") {
                    CloudGroupChatView(groupId: String(id.dropFirst(6)))
                } else {
                    CloudBotChatView(botId: id)
                }
            }
            .id(id)          // 换对话时重建，不串状态
        } else {
            Text("从左边选一个 Bot 或群聊").foregroundStyle(.secondary)
        }
    }
}

struct CloudBotSplitDetail: View {
    @ObservedObject var model: CloudBotHomeModel
    let selection: String?

    var body: some View {
        if let id = selection, !id.hasPrefix("group:"), let bot = model.bot(id) {
            NavigationStack {
                CloudBotDetailView(bot: bot, onChanged: { await model.refresh() })
            }
            .id(id)
        } else {
            Text(selection?.hasPrefix("group:") == true ? "群聊没有单独的详情页，成员和设置在对话右上角" : "这里会显示 Bot 的记忆、插件和设置")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        }
    }
}
