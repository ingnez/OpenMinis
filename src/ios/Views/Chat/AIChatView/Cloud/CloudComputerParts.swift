//
//  CloudComputerParts.swift
//  Minis - 「电脑」页的顶栏、底栏、额外按键行、语音输入条、保管库粘贴、帮助
//

import SwiftUI

private func roundIcon(_ symbol: String, on: Bool = false) -> some View {
    Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(on ? .black : .white)
        .frame(width: 44, height: 44).background(Circle().fill(on ? Color.white : Color(white: 0.17)))
}

struct CloudComputerTopBar: View {
    let bot: CloudBot?
    let ownDisplay: Bool
    @ObservedObject var ctl: CloudDesktopController
    let onBack: () -> Void
    let onHelp: () -> Void
    let onReload: () -> Void
    let onRestart: () -> Void
    let onImmersive: () -> Void
    let onBrowser: () -> Void
    var onMini: (() -> Void)? = nil

    var body: some View {
        HStack {
            Button(action: onBack) { roundIcon("chevron.left") }.accessibilityLabel("返回")
            Spacer()
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    if let bot { CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 22) }
                    Text(bot?.name ?? "云电脑").font(.headline).foregroundStyle(.white).lineLimit(1)
                    if ownDisplay {
                        Text("独立屏幕").font(.caption2).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().stroke(Color.white.opacity(0.4)))
                    }
                }
                CloudLatencyChip(ms: ctl.latencyMs, quality: ctl.quality.label, pinned: ctl.pinnedQuality != nil)
            }
            Spacer()
            Button(action: onHelp) { roundIcon("questionmark") }.accessibilityLabel("帮助")
            Menu { menuItems } label: { roundIcon("ellipsis") }.accessibilityLabel("更多")
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        .background(Color.black)
    }

    @ViewBuilder private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder private var menuItems: some View {
        Button(action: onImmersive) { Label("横屏全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
        if let onMini { Button(action: onMini) { Label("小窗继续看（去别处聊天）", systemImage: "pip.enter") } }
        Button { ctl.screenshot() } label: { Label("截图存相册", systemImage: "camera") }
        Button { ctl.toggleRecording() } label: {
            Label(ctl.recording ? "停止录屏" : "录屏", systemImage: ctl.recording ? "stop.circle" : "record.circle")
        }
        Menu {
            Button { ctl.pinnedQuality = nil } label: { checked("自动（按延迟）", ctl.pinnedQuality == nil) }
            ForEach([CloudStreamQuality.high, CloudStreamQuality.balanced, CloudStreamQuality.saver], id: \.label) { level in
                Button { ctl.pinnedQuality = level } label: { checked(level.label, ctl.pinnedQuality == level) }
            }
        } label: { Label("画质", systemImage: "dial.medium") }
        CloudLowDataMenu(ctl: ctl)
        Button { ctl.showFiles = true } label: { Label("文件：发照片过去 / 取回下载", systemImage: "arrow.up.arrow.down.square") }
        Button { ctl.showSnapshots = true } label: { Label("浏览器快照（存 / 恢复登录）", systemImage: "camera.on.rectangle") }
        if ctl.macro == nil {
            Button { ctl.macro = CloudMacro(); ctl.controlling = true } label: { Label("录制宏（存成 Bot 技能）", systemImage: "record.circle.fill") }
        }
        if ctl.zoom.scale > 1.01 {
            Button { ctl.resetZoom() } label: { Label("恢复原始大小", systemImage: "arrow.down.right.and.arrow.up.left") }
        }
        Divider()
        Button(action: onReload) { Label("刷新", systemImage: "arrow.clockwise") }
        Button(action: onRestart) { Label("重启桌面", systemImage: "power") }
        Button(action: onBrowser) { Label("在浏览器打开", systemImage: "safari") }
    }
}

/// 延迟指示：手机经隧道到 VPS 的真实往返（每 5 秒测一次 /health）+ 当前画质
struct CloudLatencyChip: View {
    let ms: Double?
    let quality: String
    let pinned: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ms.map(CloudDesktopLatency.text) ?? "测延迟…").monospacedDigit()
            Text("· \(quality)\(pinned ? "" : "（自动）")")
        }
        .font(.caption2).foregroundStyle(.white.opacity(0.75))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        guard let ms else { return .gray }
        switch CloudDesktopLatency.level(ms) {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }
}

struct CloudComputerBottomBar: View {
    @ObservedObject var ctl: CloudDesktopController
    let botWorking: Bool
    @Binding var keyboardFocused: Bool
    let dictating: Bool
    let onTakeOver: () -> Void
    let onHandBack: () -> Void
    let onPastePhone: () -> Void
    let onSyncClipboard: () -> Void
    let onFetchClipboard: () -> Void
    let onVault: () -> Void
    let onDictate: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if ctl.controlling && botWorking {
                Label("你在操作 · Bot 的电脑操作已暂停", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
            HStack(spacing: 10) {
                if ctl.controlling { controls } else { Label("正在看 Bot 操作", systemImage: "eye").font(.footnote).foregroundStyle(.white.opacity(0.75)) }
                Spacer()
                mainButton
                if ctl.controlling {
                    Button { keyboardFocused.toggle() } label: { roundIcon("keyboard", on: keyboardFocused) }.accessibilityLabel("键盘")
                        .accessibilityIdentifier("desktopIMEButton")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black)
    }

    @ViewBuilder private var controls: some View {
        Menu {
            Button(action: onPastePhone) { Label("把手机剪贴板输入进去", systemImage: "text.insert") }
            Button(action: onSyncClipboard) { Label("同步到云电脑剪贴板", systemImage: "arrow.up.doc.on.clipboard") }
            Button(action: onFetchClipboard) { Label("取回云电脑剪贴板", systemImage: "arrow.down.doc") }
            Divider()
            Button(action: onVault) { Label("从保管库粘贴…", systemImage: "key.fill") }
        } label: { roundIcon("doc.on.clipboard") }
        .accessibilityLabel("剪贴板")
        Button { ctl.mode = ctl.mode == .trackpad ? .direct : .trackpad } label: {
            roundIcon(ctl.mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left")
        }
        .accessibilityLabel(ctl.mode == .trackpad ? "触控板模式（点按切换到直接触控）" : "直接触控（点按切换到触控板）")
        .accessibilityIdentifier("desktopTrackpadMode")
        Button(action: onDictate) { roundIcon(dictating ? "mic.fill" : "mic", on: dictating) }.accessibilityLabel("语音输入到云电脑")
    }

    private var mainButton: some View {
        Button(action: ctl.controlling ? onHandBack : onTakeOver) {
            Label(ctl.controlling ? "交还给 Bot" : "接管", systemImage: ctl.controlling ? "arrow.uturn.backward" : "hand.raised")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ctl.controlling ? .white : .black)
                .padding(.horizontal, 14).frame(height: 44)
                .background(Capsule().fill(ctl.controlling ? Color(white: 0.17) : Color.white))
        }
    }
}

/// 键盘上方的额外按键：Esc、Tab、Ctrl/Alt/Shift/⌘（点一下粘住，长按锁定）、方向键…，再加常用组合
struct CloudDesktopKeyRow: View {
    @ObservedObject var ctl: CloudDesktopController

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(CloudKey.row) { keyButton($0) } }.padding(.horizontal, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CloudCombo.all) { c in
                        Button { ctl.combo(c) } label: { cap(c.label, on: false) }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.08))
    }

    private func keyButton(_ k: CloudKey) -> some View {
        let on = ctl.modifiers.armed.contains(k.id)
        let locked = ctl.modifiers.locked.contains(k.id)
        return cap(k.label + (locked ? " 🔒" : ""), on: on)
            .onTapGesture { ctl.key(k) }
            .onLongPressGesture(minimumDuration: 0.4) { if k.isModifier { ctl.modifiers.lock(k) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(k.label)
    }

    private func cap(_ text: String, on: Bool) -> some View {
        Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? .black : .white)
            .padding(.horizontal, 12).frame(minWidth: 40, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white : Color(white: 0.2)))
    }
}

struct CloudDesktopDictationBar: View {
    let text: String
    let recording: Bool
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recording ? "waveform" : "text.bubble").foregroundStyle(.green)
            Text(text.isEmpty ? "请说话…" : text).font(.callout).foregroundStyle(.white).lineLimit(3)
            Spacer(minLength: 0)
            Button("取消", action: onCancel).foregroundStyle(.white.opacity(0.7))
            Button("输入", action: onSend).buttonStyle(.borderedProminent).tint(.green).disabled(text.isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.12)))
        .padding(.horizontal, 16)
    }
}

/// 从保管库粘贴：先 Face ID；只列登录项的标题和用户名。选好后服务器解密直接在云电脑焦点处输入，值不经过手机和模型
struct CloudDesktopVaultSheet: View {
    let onPick: (CloudVaultItem, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CloudVaultItem] = []
    @State private var state = "正在验证身份…"
    @State private var picked: CloudVaultItem?

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("先在云电脑上点好要填的输入框。密码由服务器直接输入，不会显示在手机上，也不会进入对话或发给 Bot。")) {
                    if items.isEmpty { Text(state).foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        Button { picked = item } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(.primary)
                                if let u = item.username, !u.isEmpty { Text(u).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("从保管库粘贴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .confirmationDialog(picked?.title ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                                titleVisibility: .visible) {
                if let item = picked {
                    Button("输入密码") { choose(item, "password") }
                    if item.username?.isEmpty == false { Button("输入用户名") { choose(item, "username") } }
                    if item.hasTotp { Button("输入两步验证码") { choose(item, "totp") } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func choose(_ item: CloudVaultItem, _ field: String) {
        onPick(item, field)
        dismiss()
    }

    private func load() async {
        guard await CloudVaultAuth.unlock("在云电脑里输入保管库里的内容") else {
            state = "没有通过验证（设备需要设置密码或 Face ID）"
            return
        }
        do {
            items = try await CloudVaultService.list().items.filter { $0.kind == .login }
            if items.isEmpty { state = "保管库里还没有登录项" }
        } catch {
            state = error.localizedDescription
        }
    }
}

struct CloudComputerHelpSheet: View {
    let reason: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let reason, !reason.isEmpty {
                    Section("Bot 需要你做的事") { Text(reason) }
                }
                Section("看 / 接管 / 交还") {
                    Label("Bot 干活时默认只看；点「接管」后 Bot 的电脑操作会暂停，等你点「交还给 Bot」", systemImage: "hand.raised")
                    Label("App 被关或断网 45 秒后自动交还，Bot 不会一直卡住", systemImage: "clock.arrow.circlepath")
                }
                Section("触控板模式（默认）") {
                    Label("单指拖 = 移动光标，点一下 = 左键，双击 = 双击", systemImage: "hand.point.up.left")
                    Label("双指点 = 右键，双指拖 = 滚动", systemImage: "hand.tap")
                    Label("长按后拖 = 按住左键拖选，捏合 = 放大，三指拖 = 平移；放大后光标靠边会自动跟随", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    Label("底栏手形按钮可切换到直接触控（点哪就点哪）；直接触控时双指捏合会自动切回触控板并放大", systemImage: "hand.point.up")
                }
                Section("打字") {
                    Label("键盘按钮弹出系统键盘，中文输入法选好字才发送，不会把拼音发过去", systemImage: "keyboard")
                    Label("键盘上方有 Esc、Tab、Ctrl、Alt、方向键和复制 / 粘贴 / 全选等组合；点 Ctrl 粘住，长按锁定", systemImage: "command")
                    Label("剪贴板按钮：输入手机剪贴板、同步到云电脑剪贴板、取回云电脑剪贴板、从保管库粘贴密码；接管时在云电脑里复制的文字几秒内自动到手机", systemImage: "doc.on.clipboard")
                    Label("麦克风按钮：说话后把文字输入到云电脑", systemImage: "mic")
                }
                Section("最近连接耗时（本机实测）") {
                    let recent = CloudConnectTimeline.recent()
                    if recent.isEmpty { Text("还没有记录").foregroundStyle(.secondary) }
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.summary).font(.callout)
                            Text(t.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("云电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 省流量：蜂窝 / 低数据模式自动最省画质，可常开 / 关闭；显示本次连接实际收到的流量
struct CloudLowDataMenu: View {
    @ObservedObject var ctl: CloudDesktopController
    @AppStorage(CloudLowBandwidth.key) private var setting = "auto"

    var body: some View {
        Menu {
            Picker("省流量", selection: $setting) {
                Text("用蜂窝时自动").tag("auto")
                Text("常开").tag("on")
                Text("关闭").tag("off")
            }
            Text("本次流量 \(CloudLowBandwidth.bytesText(ctl.bytesReceived))\(ctl.expensiveNetwork ? " · 蜂窝 / 低数据" : "")")
        } label: {
            Label("省流量 · \(CloudLowBandwidth.bytesText(ctl.bytesReceived))", systemImage: "antenna.radiowaves.left.and.right")
        }
        .onChange(of: setting) { _ in
            if ctl.pinnedQuality == nil { ctl.setQuality(ctl.lowBandwidth ? CloudStreamQuality.saver : CloudStreamQuality.balanced) }
        }
    }
}

/// 「指给 Bot 看」：点屏幕一处 → 标记 → 写一句要求 → 发给这个 Bot（带远端坐标）
struct CloudPointOverlay: View {
    @ObservedObject var ctl: CloudDesktopController
    let onSend: (CGPoint, String) -> Void
    let onCancel: () -> Void
    @State private var mark: CGPoint?
    @State private var remote: CGPoint = .zero
    @State private var text = ""
    @State private var asking = false

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        mark = p
                        remote = ctl.remotePoint(fromView: p)
                        asking = true
                    }
                if let mark {
                    Circle().stroke(Color.orange, lineWidth: 3).frame(width: 44, height: 44)
                        .position(mark)
                        .allowsHitTesting(false)
                }
                Text(mark == nil ? "点一下要指给 Bot 看的位置" : "x \(Int(remote.x)) · y \(Int(remote.y))")
                    .font(.footnote.weight(.medium)).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.orange))
                    .padding(12)
            }
        }
        .alert("要 Bot 在这里做什么？", isPresented: $asking) {
            TextField("比如：点这个按钮 / 这里填什么", text: $text)
            Button("发给 Bot") { onSend(remote, text); text = ""; mark = nil }
            Button("重新指", role: .cancel) { mark = nil }
            Button("不指了", role: .destructive) { onCancel() }
        }
    }
}

/// 宏录制中的红色胶囊：显示步数，停止后起名存成技能（Bot 以后可照做）
struct CloudMacroBar: View {
    @ObservedObject var ctl: CloudDesktopController
    let onSaved: (String) -> Void
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        if let m = ctl.macro {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("录制中 · \(m.steps.count) 步").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                Button("停止") { naming = true }.font(.footnote.weight(.bold)).foregroundStyle(.red)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .alert("给这个宏起个名字", isPresented: $naming) {
                TextField("比如：登录医院 OA 后打开排班表", text: $name)
                Button("存成技能") { save(m) }
                Button("丢弃", role: .destructive) { ctl.macro = nil }
                Button("继续录", role: .cancel) {}
            } message: {
                Text("只记点击位置、按键和输入了几个字，不记输入的原文。")
            }
        }
    }

    private func save(_ m: CloudMacro) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillName = "宏：" + (title.isEmpty ? "未命名 \(Int(Date().timeIntervalSince1970))" : String(title.prefix(60)))
        let content = m.skill(name: skillName, screen: ctl.trackpad.screen)
        ctl.macro = nil
        name = ""
        Task {
            do {
                _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/skills/sync", body: [
                    "source": "macro", "prune": false,
                    "skills": [["name": skillName, "content": content, "description": "录制的云电脑操作（\(m.steps.count) 步）"]],
                ])
                onSaved("已存成技能「\(skillName)」，以后可以让 Bot 照做")
            } catch {
                onSaved("没存上：\(error.localizedDescription)")
            }
        }
    }
}
