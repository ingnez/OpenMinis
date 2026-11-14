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
    var role = "assistant"
}

/// 用户这一条：被引用的话 + 气泡 + Bot 点的表情；长按可复制、回复
struct CloudUserTurnRow: View {
    @ObservedObject var message: ChatMessage
    let accent: Color
    let extras: CloudMessageExtras
    let onReply: (CloudReplyTarget) -> Void
    var onRetry: (() -> Void)? = nil
    var pendingLabel: String? = nil
    var onWithdraw: (() -> Void)? = nil

    private var content: String { message.content }
    private var sendFailed: Bool { message.sendTick == MessageSendTick.failed }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let q = extras.replyExcerpt { CloudReplyQuote(excerpt: q, role: extras.replyRole) }
            CloudProseUser(content: content, accent: accent, textActions: messageActions)
            MessageSendStatusRow(failed: sendFailed, adopted: message.adoptedMark,
                                 pendingLabel: pendingLabel, onRetry: onRetry)
            if let e = extras.botReaction {
                // Bot 用表情回应了这条（代替文字回复）
                CloudReactionPill(emoji: e).padding(.trailing, 14).offset(y: -12).padding(.bottom, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func messageActions() -> [[CloudMessageAction]] {
        let text = CloudMessageText.display(content).text
        var actions = CloudMessageAction.textActions(text)
        if let id = extras.id {
            actions.insert(CloudMessageAction(title: "回复", symbol: "arrowshape.turn.up.left", key: "reply") {
                onReply(CloudReplyTarget(id: id, excerpt: text, role: "user"))
            }, at: 0)
        }
        let withdraw = onWithdraw.map { action in
            CloudMessageAction(title: "撤回待处理消息", symbol: "arrow.uturn.backward", key: "withdraw", role: .destructive, run: action)
        }
        return [actions, [withdraw].compactMap { $0 }]
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

/// 长按 Bot 的回复：底部升起的面板（H4）——背景模糊变暗、消息原地不动；两排表情（再点同一个取消）+ 自定义，
/// 下面分组：回复 / 复制、选择文本、朗读、钉到要点板 / 翻译。以前用系统 contextMenu，抬起的预览把下面的消息挤得重叠
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
            content
                .modifier(MessageActionMenu(
                    selectableText: { CloudMessageText.display(text).text },
                    currentReaction: extras.userReaction,
                    onEmoji: { onReact(id, CloudReactionLogic.next(current: extras.userReaction, picked: $0)) },
                    groups: { groups(id) }
                ))
                .modifier(CloudSystemTranslate(isPresented: $systemTranslate, text: String(CloudMessageText.display(text).text.prefix(4000))))
        } else {
            content
        }
    }

    private func groups(_ id: Int) -> [[CloudMessageAction]] {
        let shown = CloudMessageText.display(text).text
        var first = [CloudMessageAction(title: "回复", symbol: "arrowshape.turn.up.left", key: "reply") { onReply(CloudReplyTarget(id: id, excerpt: text)) }]
        if extras.userReaction != nil {
            first.append(CloudMessageAction(title: "取消表情回应", symbol: "face.dashed", key: "unreact") { onReact(id, nil) })
        }
        var second = CloudMessageAction.textActions(shown, copyText: text)
        if let botId {
            second.append(CloudMessageAction(title: "朗读", symbol: "speaker.wave.2", key: "speak") {
                CloudTips.markUsed("longpress-reply"); CloudBotSpeaker.speak(shown, botId: botId)
            })
            second.append(CloudMessageAction(title: "钉到要点板", symbol: "pin", key: "pin") {
                CloudTips.markUsed("longpress-reply"); if CloudPins.add(botId, text: shown) { CloudHaptics.success() }
            })
        }
        var third: [CloudMessageAction] = []
        if let onAsk {
            let excerpt = String(shown.prefix(1500))
            third.append(CloudMessageAction(title: "翻译成中文", symbol: "character.bubble", key: "zh") { onAsk("把下面这段翻译成中文（只给译文）：\n\(excerpt)") })
            third.append(CloudMessageAction(title: "翻译成英文", symbol: "character.bubble", key: "en") { onAsk("把下面这段翻译成英文（只给译文）：\n\(excerpt)") })
        }
        if CloudSystemTranslateSupport.available {
            third.append(CloudMessageAction(title: "系统翻译（本机，不耗 Bot）", symbol: "translate", key: "systranslate") { systemTranslate = true })
        }
        return [first, second, third].filter { !$0.isEmpty }
    }
}

/// 长按面板的一行动作
struct CloudMessageAction: Identifiable {
    let title: String
    let symbol: String
    let key: String
    let role: ButtonRole?
    let isEnabled: Bool
    let run: () -> Void
    var id: String { key }

    init(title: String, symbol: String, key: String, role: ButtonRole? = nil,
         isEnabled: Bool = true, run: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.key = key
        self.role = role
        self.isEnabled = isEnabled
        self.run = run
    }

    @MainActor
    static func textActions(_ text: String, copyText: String? = nil) -> [Self] {
        guard !text.isEmpty else { return [] }
        return [
            Self(title: AppLocalized("Copy"), symbol: "doc.on.doc", key: "copy") {
                UIPasteboard.general.string = copyText ?? text
                CloudHaptics.success()
            },
            Self(title: "选择文本", symbol: "character.cursor.ibeam", key: "select") {}
        ]
    }
}

/// Shared presentation for cloud and local messages. Actions that open another
/// view run after the full-screen cover has dismissed.
struct MessageActionMenu: ViewModifier {
    let selectableText: () -> String
    var currentReaction: String? = nil
    var onEmoji: ((String) -> Void)? = nil
    let groups: () -> [[CloudMessageAction]]
    @State private var isPresented = false
    @State private var pendingAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in present() })
            .accessibilityAction(named: Text("消息操作")) { present() }
            .background {
                CloudMessageOverlay(isPresented: $isPresented, onDismiss: {
                        let action = pendingAction
                        pendingAction = nil
                        action?()
                    }) {
                        CloudMessageActionSheet(emojis: CloudMessageActionSheet.allEmojis, current: currentReaction,
                                                onEmoji: onEmoji, groups: groups().filter { !$0.isEmpty },
                                                selectableText: selectableText(),
                                                onClose: { action in
                                                    pendingAction = action
                                                    CloudMessageMenu.dismiss($isPresented)
                                                })
                    }.frame(width: 0, height: 0)
            }
    }

    private func present() {
        guard !isPresented, onEmoji != nil || groups().contains(where: { !$0.isEmpty }) else { return }
        CloudHaptics.tap()
        CloudMessageMenu.present($isPresented)
    }
}

/// 面板用不带动画的全屏层弹出（背景透明，自己画模糊和升起动画），下面的消息完全不动
enum CloudMessageMenu {
    static func present(_ shown: Binding<Bool>) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { shown.wrappedValue = true }
    }

    static func dismiss(_ shown: Binding<Bool>) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { shown.wrappedValue = false }
    }
}

/// Keep the transcript and its keyboard mounted while the menu is visible.
/// SwiftUI's fullScreenCover removes the presenting page, then reapplies its
/// keyboard avoidance on dismissal, shifting an otherwise unchanged bubble.
private struct CloudMessageOverlay<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> CloudMessageOverlayController {
        let controller = CloudMessageOverlayController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: CloudMessageOverlayController, context: Context) {
        let coordinator = context.coordinator
        let update = { [weak controller, weak coordinator] in
            guard let controller, let coordinator, controller.view.window != nil else { return }
            coordinator.update(controller, shown: isPresented, content: content, onDismiss: onDismiss)
        }
        controller.onAppearance = update
        DispatchQueue.main.async(execute: update)
    }

    static func dismantleUIViewController(_ controller: CloudMessageOverlayController, coordinator: Coordinator) {
        controller.onAppearance = nil
        coordinator.host?.dismiss(animated: false)
    }

    final class Coordinator {
        var host: UIViewController?
        private var dismissing = false

        func update(_ presenter: UIViewController, shown: Bool, content: () -> Content, onDismiss: @escaping () -> Void) {
            if shown {
                guard host == nil, presenter.presentedViewController == nil else { return }
                let next = UIHostingController(rootView: content())
                next.modalPresentationStyle = .overFullScreen
                next.view.backgroundColor = .clear
                host = next
                presenter.present(next, animated: false)
            } else if let host, !dismissing {
                dismissing = true
                host.dismiss(animated: false) {
                    self.host = nil
                    self.dismissing = false
                    onDismiss()
                }
            }
        }
    }
}

private final class CloudMessageOverlayController: UIViewController {
    var onAppearance: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppearance?()
    }
}

/// 全屏层的系统背景改成透明（iOS 16.0 没有 presentationBackground）
struct CloudClearCoverBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        DispatchQueue.main.async { v.superview?.superview?.backgroundColor = .clear }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct CloudMessageActionSheet: View {
    /// 两排常用表情（最后一格是「自定义」）
    static let allEmojis = ["👍", "👎", "❤️", "😂", "🎉", "😮", "🔥", "👀", "🙏", "😢", "💯"]

    let emojis: [String]
    let current: String?
    let onEmoji: ((String) -> Void)?
    let groups: [[CloudMessageAction]]
    let selectableText: String
    let onClose: ((() -> Void)?) -> Void
    @State private var shown = false
    @State private var closing = false
    @State private var drag: CGFloat = 0
    @State private var selecting = false
    @State private var askingCustom = false
    @State private var customText = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .onTapGesture { close() }
                .accessibilityElement()
                .accessibilityLabel("关闭菜单")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("messageMenuBackdrop")
            panel
                .offset(y: shown ? max(0, drag) : 900)
        }
        .background(CloudClearCoverBackground())
        .onAppear { withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { shown = true } }
        .alert("自定义表情", isPresented: $askingCustom) {
            TextField("输入一个表情", text: $customText)
            Button("取消", role: .cancel) {}
            Button("好") {
                if let e = customText.first.map(String.init), let u = e.unicodeScalars.first, u.properties.isEmoji, u.value > 0xFF {
                    close { onEmoji?(e) }
                }
                customText = ""
            }
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                if value.translation.height > 110 || value.predictedEndTranslation.height > 260 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                }
            }
    }

    private var handle: some View {
        Capsule().fill(Color(.tertiaryLabel)).frame(width: 36, height: 5).padding(.top, 6)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var panel: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 8) {
                handle
                panelContents
            }
            .gesture(dismissGesture)
            VStack(spacing: 8) {
                handle.gesture(dismissGesture)
                ScrollView { panelContents }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.regularMaterial).ignoresSafeArea(edges: .bottom))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageMenuPanel")
    }

    private var panelContents: some View {
        VStack(spacing: 14) {
            if selecting {
                ScrollView {
                    Text(selectableText).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 360)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
                .accessibilityIdentifier("messageMenuSelectText")
                Button("完成") { close() }.font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                if let onEmoji, !emojis.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                        ForEach(emojis, id: \.self) { e in
                            Button { close { onEmoji(e) } } label: {
                                Text(e).font(.system(size: 24))
                                    .frame(width: 46, height: 46)
                                    .background(Circle().fill(current == e ? Color.accentColor.opacity(0.28) : Color(.tertiarySystemFill)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(e + (current == e ? "（已选，再点取消）" : ""))
                            .accessibilityIdentifier("messageMenuEmoji-\(e)")
                        }
                        Button { askingCustom = true } label: {
                            Image(systemName: "face.smiling").font(.system(size: 20))
                                .overlay(alignment: .bottomTrailing) { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).offset(x: 4, y: 3) }
                                .foregroundStyle(.secondary)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("自定义表情")
                        .accessibilityIdentifier("messageMenuEmojiCustom")
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 0) {
                        ForEach(Array(group.enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Divider().padding(.leading, 52) }
                            Button(role: a.role) {
                                if a.key == "select" {
                                    withAnimation(.easeInOut(duration: 0.2)) { selecting = true }
                                } else {
                                    close(then: a.run)
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: a.symbol).font(.system(size: 17)).frame(width: 22)
                                    Text(a.title).font(.body)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(a.role == .destructive ? Color.red : Color.primary)
                                .padding(.horizontal, 16).padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!a.isEnabled)
                            .accessibilityIdentifier("messageMenuAction-\(a.key)")
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground).opacity(0.9)))
                }
            }
        }
    }

    private func close(then action: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: 0.2)) { shown = false; drag = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onClose(action) }
    }
}
