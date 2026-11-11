//
//  CloudComputer.swift
//  Minis - 「电脑」接管页：看 Bot 干活 → 接管（Bot 暂停）→ 交还给 Bot
//

import SwiftUI
import UIKit

struct CloudComputerView: View {
    let botId: String?
    let sessionId: String?
    let reason: String?
    @ObservedObject private var connection = CloudConnection.shared
    @ObservedObject private var home = CloudBotHomeModel.shared
    @StateObject private var ctl = CloudDesktopController()
    @StateObject private var dictation = CloudDictation()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .connecting
    @State private var reloadToken = UUID()
    @State private var started = false
    @State private var showHelp = false
    @State private var showVault = false
    @State private var clipWatch = CloudClipboardWatch()
    @State private var toast: String?
    @State private var keyboardFocused = false
    @State private var immersive = false
    @State private var sendChain: Task<Void, Never>?
    @State private var lease: Task<Void, Never>?
    @State private var timeline = CloudConnectTimeline(start: Date())
    @State private var timed = false
    /// websockify token（新版服务器）：main = 主屏，bot-<id> = 该 Bot 的独立屏幕
    @State private var token: String?
    @State private var ownDisplay = false
    @State private var rechecking = false
    @State private var pointing = false
    /// 最近一次拷到手机剪贴板的云电脑文字（端到端探针用）
    @State private var lastToPhone = ""

    enum Phase: Equatable { case connecting, live, failed(String), problem(CloudDesktopProblem) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            screen
            statusOverlay
            CloudIMEField(focused: $keyboardFocused, onEvents: { ctl.type($0, viaServer: typeViaServer) },
                          onReturn: { ctl.key(.enter) })
                .frame(width: 1, height: 1)
        }
        .safeAreaInset(edge: .top) { if !immersive { topBar } }
        .safeAreaInset(edge: .bottom) { if !immersive { bottomArea } }
        .overlay(alignment: .topTrailing) { if immersive { exitImmersive } }
        .overlay(alignment: .bottomTrailing) { if !immersive, !ctl.controlling, sessionId != nil, phase == .live { pointButton } }
        .overlay(alignment: .top) { toastView }
        .overlay(alignment: .topLeading) { CloudMacroBar(ctl: ctl, onSaved: { show($0) }).padding(.top, immersive ? 12 : 64).padding(.leading, 12) }
        .background(CloudComputerAux(ctl: ctl, sessionId: sessionId, live: phase == .live, keyboardFocused: $keyboardFocused,
                                     onPassword: { show("这是密码框：从保管库选一项填进去（值不经过手机和 Bot）"); showVault = true }))
        .overlay(alignment: .bottom) { if dictation.isRecording || !dictation.transcript.isEmpty { dictationBar } }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHelp) { CloudComputerHelpSheet(reason: reason) }
        .sheet(isPresented: $showVault) { CloudDesktopVaultSheet { item, field in pasteFromVault(item, field) } }
        .task { await start() }
        .task { await watchRemoteClipboard() }
        .onAppear(perform: setUp)
        .onDisappear(perform: tearDown)
        .onChange(of: ctl.controlling) { on in holdControl(on) }
    }

    private var bot: CloudBot? { botId.flatMap { home.bot($0) } }

    private var streamURL: URL? { CloudDesktopCheck.streamURL(token: token) }

    @ViewBuilder private var screen: some View {
        if case .failed = phase {} else if case .problem = phase {} else if let url = streamURL {
            ZStack {
                CloudComputerWebView(url: url, reloadToken: reloadToken, controller: ctl,
                                     onLoaded: { reused in pageLoaded(reused) }, onState: { vncStateChanged($0) })
                if ctl.controlling && ctl.mode == .trackpad {
                    CloudTrackpadSurface(controller: ctl)
                } else if !ctl.controlling && !pointing {
                    CloudZoomSurface(controller: ctl)
                }
                if pointing && !ctl.controlling {
                    CloudPointOverlay(ctl: ctl, onSend: { p, t in sendPoint(p, t) }, onCancel: { pointing = false })
                }
            }
            .overlay(alignment: .topTrailing) { if phase == .live, ctl.zoom.isZoomed { zoomBadge } }
            .overlay(alignment: .topLeading) { e2eProbe }
            .opacity(phase == .live ? 1 : 0.01)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 放大时右上角的倍数，点一下恢复原始大小（双击 / 双指双击也行）
    private var zoomBadge: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { ctl.resetZoom() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .bold))
                Text(String(format: "%.1f×", ctl.zoom.scale)).monospacedDigit()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .accessibilityIdentifier("ccZoomBadge")
        .accessibilityLabel("恢复原始大小")
        .accessibilityValue(String(format: "%.2f", ctl.zoom.scale))
        .padding(.top, 10).padding(.trailing, 12)
    }

    /// 模拟器端到端探针：缩放倍数、光标（远端像素和在屏幕上的位置）、假画面收到的点击、拷到手机的文字
    @ViewBuilder private var e2eProbe: some View {
        if CloudE2E.fakeDesktop {
            let c = ctl.trackpad.cursor, v = ctl.cursorOnScreen, k = ctl.lastRemoteClick
            // 画面左上角一个几乎看不见的小字（Color.clear 会被无障碍树忽略）
            Text("e2e").font(.system(size: 4)).foregroundStyle(Color.white.opacity(0.05))
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("ccDesktopProbe")
                .accessibilityLabel("ccDesktopProbe")
                .accessibilityValue(String(format: "scale=%.2f;cursor=%ld,%ld;onscreen=%ld,%ld;viewport=%ld,%ld;click=%ld,%ld;toPhone=",
                                           ctl.zoom.scale, Int(c.x), Int(c.y), Int(v.x), Int(v.y),
                                           Int(ctl.viewport.width), Int(ctl.viewport.height), k.x, k.y) + lastToPhone)
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("正在连接…").font(.subheadline.weight(.medium)).foregroundStyle(.white)
            }
        case .failed(let text):
            VStack(spacing: 14) {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: 40)).foregroundStyle(.orange)
                Text(text).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                Button("重试") { reload() }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            }
            .padding(32)
        case .problem(let p):
            CloudDesktopProblemView(problem: p) { reload() }.padding(.vertical, 60)
        case .live:
            EmptyView()
        }
    }

    private var topBar: some View {
        CloudComputerTopBar(bot: bot, ownDisplay: ownDisplay, ctl: ctl, onBack: { dismiss() }, onHelp: { showHelp = true },
                            onReload: reload, onRestart: restartDesktop, onImmersive: { setImmersive(true) },
                            onBrowser: { if let streamURL { openURL(streamURL) } },
                            onMini: botId.map { id in { CloudMiniDesktop.shared.show(botId: id); dismiss() } })
    }

    private var bottomArea: some View {
        VStack(spacing: 0) {
            if ctl.controlling && keyboardFocused { CloudDesktopKeyRow(ctl: ctl) }
            CloudComputerBottomBar(ctl: ctl, botWorking: bot?.activity != nil, keyboardFocused: $keyboardFocused,
                                   dictating: dictation.isRecording,
                                   onTakeOver: { ctl.controlling = true }, onHandBack: handBack,
                                   onPastePhone: pastePhoneClipboard, onSyncClipboard: syncClipboardToRemote,
                                   onFetchClipboard: fetchRemoteClipboard, onVault: { showVault = true },
                                   onDictate: toggleDictation)
        }
    }

    private var pointButton: some View {
        Button { pointing.toggle() } label: {
            Label(pointing ? "取消指点" : "指给 Bot 看", systemImage: "hand.point.up.left")
                .font(.footnote.weight(.semibold)).foregroundStyle(pointing ? .black : .white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(pointing ? Color.orange : Color.black.opacity(0.6)))
        }
        .padding(.trailing, 14).padding(.bottom, 120)
    }

    /// 把坐标 + 要求作为一条消息发给这个 Bot（Bot 自己截图确认再操作）
    private func sendPoint(_ p: CGPoint, _ text: String) {
        pointing = false
        guard let sid = sessionId else { return }
        let msg = CloudPointAndTell.message(point: p, screen: ctl.trackpad.screen, instruction: text)
        Task {
            do {
                _ = try await connection.request(method: "POST", path: "/v1/sessions/\(sid)/messages",
                                                 body: ["content": msg, "model": "bot", "provider": [String: Any](), "client_nonce": UUID().uuidString])
                show("已发给 Bot：x \(Int(p.x)), y \(Int(p.y))")
            } catch {
                show("没发出去：\(error.localizedDescription)")
            }
        }
    }

    private var exitImmersive: some View {
        Button { setImmersive(false) } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(Color.black.opacity(0.55)))
        }
        .accessibilityLabel("退出全屏")
        .padding(10)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.footnote).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.white))
                .padding(.top, immersive ? 12 : 70)
                .transition(.opacity)
        }
    }

    private var dictationBar: some View {
        CloudDesktopDictationBar(text: dictation.transcript, recording: dictation.isRecording,
                                 onSend: {
                                     let t = dictation.transcript
                                     dictation.stop(); dictation.transcript = ""
                                     if !t.isEmpty { ctl.type([.text(t)], viaServer: typeViaServer) }
                                 },
                                 onCancel: { dictation.stop(); dictation.transcript = "" })
            .padding(.bottom, 90)
    }

    // MARK: 生命周期

    private func setUp() {
        ctl.onNotice = { show($0) }
        ctl.onClipboard = { rfbText in
            // noVNC 的剪贴板事件只有 Latin-1（中文是乱码）：只当信号，文字以服务器 xclip 读到的 UTF-8 为准
            guard ctl.controlling else { return }
            Task { @MainActor in
                var payload: [String: Any] = ["action": "clipboard_get"]
                if ownDisplay, let botId { payload["bot_id"] = botId }
                let server = (try? await connection.request(method: "POST", path: "/v1/desktop/input", body: payload))?["text"] as? String
                guard let text = CloudClipboardWatch.pick(server: server, rfb: rfbText), !clipWatch.isOwn(text),
                      text != clipWatch.baseline else { return }
                clipWatch.noteKnown(text)
                copyToPhone(text, toast: "云电脑剪贴板已同步到手机（\(text.count) 字）")
            }
        }
        ctl.onNetworkChange = {
            guard phase == .live else { return }
            ctl.js("window.__omReconnect&&__omReconnect()")
            show("网络已切换，正在重连画面…")
        }
        ctl.startMonitoring { await probeLatency() }
        // 默认：Bot 正在干活 → 先看着；Bot 请求你帮忙或空闲 → 直接操作
        ctl.controlling = reason != nil || bot?.activity == nil
    }

    private func tearDown() {
        ctl.stopMonitoring()
        if ctl.controlling { holdControl(false) }
        lease?.cancel()
        dictation.stop()
        if immersive { setImmersive(false) }
    }

    private func start() async {
        phase = .connecting
        timeline = CloudConnectTimeline(start: Date())
        timed = false
        let r: CloudDesktopCheckResult
        if CloudE2E.fakeDesktop { r = .ready(token: "main", ownDisplay: false) }
        else if let warm = CloudDesktopWarmup.take(botId: botId) { r = warm } else { r = await CloudDesktopCheck.run(botId: botId) }
        switch r {
        case .problem(let p):
            phase = .problem(p)
            return
        case .ready(let t, let own):
            token = t
            ownDisplay = own
        }
        timeline.checked = Date()
        if started { reloadToken = UUID() }
        started = true
        // 超时兜底：网页 15 秒还没报告连上也先显示出来
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        if phase == .connecting { phase = .live }
    }

    private func reload() { Task { await start() } }

    private func pageLoaded(_ reused: Bool) {
        timeline.loaded = Date()
        timeline.reused = reused
    }

    /// noVNC 报告连接失败：先查服务器链路，真坏了就换成诊断卡片；只是网络抖动则交给页面自动重连
    private func vncStateChanged(_ state: String) {
        if state == "connected" {
            phase = .live
            ctl.connected()
            if !timed {
                timed = true
                timeline.connected = Date()
                CloudConnectTimeline.record(timeline)
                show(timeline.summary)
            }
            return
        }
        guard state.hasPrefix("error"), !rechecking else { return }
        rechecking = true
        Task {
            let r = await CloudDesktopCheck.run(botId: botId, autoRepair: true)
            rechecking = false
            if case .problem(let p) = r { phase = .problem(p) } else { show("画面断开，正在重连…") }
        }
    }

    private func probeLatency() async -> Double? {
        let t0 = Date()
        guard (try? await connection.request(method: "GET", path: "/health")) != nil else { return nil }
        return Date().timeIntervalSince(t0) * 1000
    }

    // MARK: 接管 / 交还

    private func holdControl(_ on: Bool) {
        lease?.cancel()
        lease = nil
        // 带上 bot_id：这个 Bot 有独立屏幕时只暂停那一块，没有时服务器回落到主屏
        let body: [String: Any] = botId.map { ["hold": on, "bot_id": $0] } ?? ["hold": on]
        if on {
            lease = Task { @MainActor in
                while !Task.isCancelled {
                    _ = try? await connection.request(method: "POST", path: "/v1/desktop/control", body: body)
                    try? await Task.sleep(nanoseconds: UInt64(CloudControlLease.heartbeat * 1_000_000_000))
                }
            }
        } else {
            Task { _ = try? await connection.request(method: "POST", path: "/v1/desktop/control", body: body) }
        }
    }

    private func handBack() {
        keyboardFocused = false
        ctl.controlling = false
        CloudHaptics.success()
        // Bot 还在干活：松开后它自己继续；Bot 已经停下来等你（请求接管）：告诉它你完成了
        if bot?.activity == nil, let sessionId {
            CloudComputerHandoff.finish(sessionId: sessionId)
            dismiss()
        } else {
            show("已交还给 Bot，它会接着做")
        }
    }

    // MARK: 输入

    private func setImmersive(_ on: Bool) {
        withAnimation { immersive = on }
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait)) { _ in }
    }

    private func restartDesktop() {
        phase = .connecting
        Task {
            do {
                try await connection.restartDesktop()
                show("桌面已重启")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await start()
            } catch {
                phase = .failed("重启桌面失败：\(error.localizedDescription)")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }

    /// 按顺序把请求发到云电脑（与 Agent 共用桌面锁）
    private func send(_ body: [String: Any], done: String? = nil, always: (() -> Void)? = nil,
                      onResult: (([String: Any]) -> Void)? = nil) {
        let previous = sendChain
        sendChain = Task { @MainActor in
            await previous?.value
            defer { always?() }
            do {
                var payload = body
                if ownDisplay, let botId { payload["bot_id"] = botId }
                let r = try await connection.request(method: "POST", path: "/v1/desktop/input", body: payload)
                onResult?(r)
                if let done { show(done) }
                if let note = r["fallback"] as? String { show(note) }
            } catch {
                show(CloudDesktopInputError.message(error.localizedDescription))
            }
        }
    }

    /// 走服务器的输入（中文等，或排在中文后面的字 / 退格）。中文在服务器上是「放进剪贴板 + Ctrl+V」，
    /// 先记成手机自己送的，剪贴板轮询读到它不会当成「云电脑里复制了」再拷回手机
    private func typeViaServer(_ e: CloudIMECommit.Event, done: @escaping () -> Void) {
        if case .text(let t) = e, CloudIMECommit.viaServer(t) { clipWatch.expect(String(t.prefix(10000))) }
        send(CloudTypeOrder.serverPayload(e), always: done)
    }

    private func pastePhoneClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { show("剪贴板没有文字"); return }
        let t = String(text.prefix(10000))
        if CloudIMECommit.viaServer(t) { clipWatch.expect(t) }
        send(["action": "type", "text": t], done: "已输入到云电脑")
    }

    private func copyToPhone(_ text: String, toast: String) {
        UIPasteboard.general.string = text
        lastToPhone = text
        show(toast)
    }

    /// 接管时每隔几秒看一眼云电脑剪贴板，那边复制了新文字就拷到手机（见 CloudClipboardWatch）
    private func watchRemoteClipboard() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: CloudClipboardWatch.interval)
            guard ctl.controlling, phase == .live else { continue }
            var payload: [String: Any] = ["action": "clipboard_get"]
            if ownDisplay, let botId { payload["bot_id"] = botId }
            guard let r = try? await connection.request(method: "POST", path: "/v1/desktop/input", body: payload),
                  let text = r["text"] as? String else { continue }
            if let fresh = clipWatch.observe(text) {
                copyToPhone(fresh, toast: "云电脑里复制的文字已到手机（\(fresh.count) 字）")
            }
        }
    }

    private func syncClipboardToRemote() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { show("剪贴板没有文字"); return }
        let t = String(text.prefix(10000))
        clipWatch.noteKnown(t)
        clipWatch.expect(t)
        send(["action": "clipboard_set", "text": t], done: "已放进云电脑剪贴板，可在那边 Ctrl+V")
    }

    private func fetchRemoteClipboard() {
        send(["action": "clipboard_get"]) { r in
            let text = r["text"] as? String ?? ""
            if text.isEmpty { show("云电脑剪贴板是空的"); return }
            clipWatch.noteKnown(text)
            copyToPhone(text, toast: "已复制云电脑剪贴板（\(text.count) 字）")
        }
    }

    private func pasteFromVault(_ item: CloudVaultItem, _ field: String) {
        send(["action": "vault", "item_id": item.id, "field": field], done: "已在云电脑输入（值没有经过手机和 Bot）")
    }

    private func toggleDictation() {
        if dictation.isRecording { dictation.stop() } else { dictation.start() }
    }
}
