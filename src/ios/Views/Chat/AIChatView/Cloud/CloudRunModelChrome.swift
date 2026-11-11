import SwiftUI

/// 气泡角上的表情回应（Bot 点给用户的 / 用户点给 Bot 的）
struct CloudReactionPill: View {
    let emoji: String
    var mine = false
    @State private var popped = false

    var body: some View {
        Text(emoji).font(.system(size: 14))
            .scaleEffect(popped ? 1 : 0.3)
            .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { popped = true } }
            .onChange(of: emoji) { _ in
                popped = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { popped = true }
            }
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
                Button(e + (current == e ? " ✓" : "")) { onPick(CloudReactionLogic.next(current: current, picked: e)) }
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
            CloudProseUser(content: content, accent: accent, textMenu: {
                AnyView(Group {
                    Button { UIPasteboard.general.string = CloudMessageText.display(content).text } label: { Label("复制", systemImage: "doc.on.doc") }
                    if let id = extras.id {
                        Button { onReply(CloudReplyTarget(id: id, excerpt: CloudMessageText.display(content).text)) } label: {
                            Label("回复", systemImage: "arrowshape.turn.up.left")
                        }
                    }
                })
            })
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

/// 长按 Bot 的回复：快速表情（再点同一个取消）、复制、回复
struct CloudAssistantLongPress: ViewModifier {
    let text: String
    let extras: CloudMessageExtras
    let onReact: (Int, String?) -> Void
    let onReply: (CloudReplyTarget) -> Void
    var botId: String? = nil
    /// 「翻译」等需要让 Bot 处理的：把一句话交给对话页发出去
    var onAsk: ((String) -> Void)? = nil
    @State private var systemTranslate = false

    func body(content: Content) -> some View {
        if let id = extras.id {
            content.contextMenu {
                ForEach(CloudMessageExtras.quickEmojis, id: \.self) { e in
                    Button(e + (extras.userReaction == e ? " ✓" : "")) { onReact(id, CloudReactionLogic.next(current: extras.userReaction, picked: e)) }
                }
                Divider()
                Button { UIPasteboard.general.string = text } label: { Label("复制", systemImage: "doc.on.doc") }
                Button { onReply(CloudReplyTarget(id: id, excerpt: text)) } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                if let botId {
                    Button { CloudTips.markUsed("longpress-reply"); CloudBotSpeaker.speak(CloudMessageText.display(text).text, botId: botId) } label: { Label("朗读", systemImage: "speaker.wave.2") }
                    Button { CloudTips.markUsed("longpress-reply"); if CloudPins.add(botId, text: CloudMessageText.display(text).text) { CloudHaptics.success() } } label: {
                        Label("钉到要点板", systemImage: "pin")
                    }
                }
                if let onAsk {
                    let excerpt = String(CloudMessageText.display(text).text.prefix(1500))
                    Button { onAsk("把下面这段翻译成英文（只给译文）：\n\(excerpt)") } label: { Label("翻译成英文", systemImage: "character.bubble") }
                    Button { onAsk("把下面这段翻译成中文（只给译文）：\n\(excerpt)") } label: { Label("翻译成中文", systemImage: "character.bubble") }
                }
                if CloudSystemTranslateSupport.available {
                    Button { systemTranslate = true } label: { Label("系统翻译（本机，不耗 Bot）", systemImage: "translate") }
                }
            }
            .modifier(CloudSystemTranslate(isPresented: $systemTranslate, text: String(CloudMessageText.display(text).text.prefix(4000))))
        } else {
            content
        }
    }
}
