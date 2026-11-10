import SwiftUI

/// 气泡角上的表情回应（Bot 点给用户的 / 用户点给 Bot 的）
struct CloudReactionPill: View {
    let emoji: String
    var mine = false

    var body: some View {
        Text(emoji).font(.system(size: 14))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
            .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
            .overlay(Capsule().stroke(mine ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
            .accessibilityLabel(mine ? "你的回应 \(emoji)" : "回应 \(emoji)")
    }
}

/// 引用回复：气泡上方的一小段被引用的话
struct CloudReplyQuote: View {
    let excerpt: String
    let role: String?
    var trailing = true

    var body: some View {
        HStack(spacing: 6) {
            if trailing { Spacer(minLength: 56) }
            RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(role == "assistant" ? "回复 Bot" : "回复自己").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !trailing { Spacer(minLength: 0) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 输入框上方「正在回复：…」，点 × 取消
struct CloudReplyBanner: View {
    let excerpt: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.caption).foregroundStyle(.secondary)
            Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .accessibilityLabel("取消回复")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }
}

/// 长按菜单里的「回应」：一排常用表情 + 取消
struct CloudReactMenu: View {
    let current: String?
    let onPick: (String?) -> Void

    var body: some View {
        Menu {
            ForEach(CloudMessageExtras.quickEmojis, id: \.self) { e in
                Button(e + (current == e ? " ✓" : "")) { onPick(current == e ? nil : e) }
            }
            if current != nil { Button("取消回应", role: .destructive) { onPick(nil) } }
        } label: {
            Label("回应", systemImage: "face.smiling")
        }
    }
}

/// 回复里提到的其他 Bot（@名字）：显示成标签，点一下打开它的对话
struct CloudTeammateChips: View {
    let text: String
    let selfId: String
    @ObservedObject private var home = CloudBotHomeModel.shared

    private var mentioned: [CloudBot] {
        home.bots.filter { $0.id != selfId && !$0.name.isEmpty && (text.contains("@" + $0.name) || text.contains("＠" + $0.name)) }
    }

    var body: some View {
        if !mentioned.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mentioned) { bot in
                        Button { home.pendingOpen = bot.id } label: {
                            HStack(spacing: 5) {
                                CloudBotBlobAvatar(bot: bot, size: 18)
                                Text(bot.name).font(.caption.weight(.medium))
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color(.secondarySystemBackground)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开 \(bot.name) 的对话")
                    }
                }
            }
        }
    }
}

/// 准备引用回复的那条消息
struct CloudReplyTarget: Equatable {
    let id: Int
    let excerpt: String
}

/// 用户这一条：被引用的话 + 气泡 + Bot 点的表情；长按可复制、回复
struct CloudUserTurnRow: View {
    let content: String
    let accent: Color
    let extras: CloudMessageExtras
    let onReply: (CloudReplyTarget) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let q = extras.replyExcerpt { CloudReplyQuote(excerpt: q, role: extras.replyRole) }
            CloudProseUser(content: content, accent: accent)
                .contextMenu {
                    Button { UIPasteboard.general.string = CloudMessageText.display(content).text } label: { Label("复制", systemImage: "doc.on.doc") }
                    if let id = extras.id {
                        Button { onReply(CloudReplyTarget(id: id, excerpt: CloudMessageText.display(content).text)) } label: {
                            Label("回复", systemImage: "arrowshape.turn.up.left")
                        }
                    }
                }
            if let e = extras.botReaction {
                // Bot 用表情回应了这条（代替文字回复）
                CloudReactionPill(emoji: e).padding(.trailing, 14).offset(y: -12).padding(.bottom, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Bot 回复下面那一行：复制、回应、回复、耗时；提到的其他 Bot 显示成标签
struct CloudAssistantFooter: View {
    let text: String
    let latency: String?
    let extras: CloudMessageExtras
    let selfId: String
    let onReact: (Int, String?) -> Void
    let onReply: (CloudReplyTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CloudTeammateChips(text: text, selfId: selfId)
            HStack(spacing: 12) {
                Button { UIPasteboard.general.string = text; CloudHaptics.success() } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .accessibilityLabel("复制回复")
                if let id = extras.id {
                    CloudReactMenu(current: extras.userReaction) { onReact(id, $0) }
                        .labelStyle(.iconOnly).font(.caption2)
                    Button { onReply(CloudReplyTarget(id: id, excerpt: text)) } label: {
                        Image(systemName: "arrowshape.turn.up.left").font(.caption2)
                    }
                    .accessibilityLabel("回复这条")
                }
                if let e = extras.userReaction { CloudReactionPill(emoji: e, mine: true) }
                if let latency { Text(latency).font(.caption2) }
            }
            .foregroundStyle(.tertiary)
            .buttonStyle(.plain)
        }
    }
}
