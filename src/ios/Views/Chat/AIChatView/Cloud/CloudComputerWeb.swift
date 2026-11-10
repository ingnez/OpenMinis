//
//  CloudComputerWeb.swift
//  Minis - 云电脑画面网页：只允许本机桌面隧道端口；关页后保活 60 秒，再打开直接复用；体检结果预热
//

import SwiftUI
import WebKit

/// 预热：Bot 请求接管、对话里出现实时画面时先把桌面体检做了，打开「电脑」页时跳过这一步
@MainActor
enum CloudDesktopWarmup {
    private static var cache: [String: (result: CloudDesktopCheckResult, at: Date)] = [:]
    private static var running: Set<String> = []

    static func key(_ botId: String?) -> String { botId ?? "main" }

    static func prewarm(botId: String?) {
        let k = key(botId)
        guard !running.contains(k), !CloudDesktopReuse.fresh(cache[k]?.at) else { return }
        running.insert(k)
        Task { @MainActor in
            let r = await CloudDesktopCheck.run(botId: botId)
            running.remove(k)
            if case .ready = r { cache[k] = (r, Date()) }
        }
    }

    /// 60 秒内的体检结果（用过就作废，下次重新体检）
    static func take(botId: String?) -> CloudDesktopCheckResult? {
        let k = key(botId)
        guard let hit = cache[k], CloudDesktopReuse.fresh(hit.at) else { return nil }
        cache[k] = nil
        return hit.result
    }

    static func remember(botId: String?, _ r: CloudDesktopCheckResult) {
        if case .ready = r { cache[key(botId)] = (r, Date()) }
    }
}

/// 关掉「电脑」页后画面不马上断：停 60 秒，期间再打开同一块屏幕直接接上（省掉页面加载和约 140 ms 的 VNC 握手）
@MainActor
enum CloudDesktopWebPool {
    struct Entry {
        let web: WKWebView
        let bridge: CloudNoVNCBridge
        let url: URL
    }

    private static var parked: Entry?
    private static var timer: Task<Void, Never>?

    static func take(_ url: URL) -> Entry? {
        guard let e = parked, e.url == url else { return nil }
        parked = nil
        timer?.cancel()
        return e
    }

    static func park(_ e: Entry) {
        parked = e
        e.bridge.onState = nil
        e.bridge.onEvent = nil
        e.web.evaluateJavaScript("window.om&&(om.view(1,0,0),om.cursor(false),om.viewOnly(true))", completionHandler: nil)
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(CloudDesktopReuse.parkSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            parked?.web.evaluateJavaScript("window.__omRFB&&__omRFB.disconnect()", completionHandler: nil)
            parked = nil
        }
    }
}

struct CloudComputerWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    let controller: CloudDesktopController
    let onLoaded: (_ reused: Bool) -> Void
    var onState: (String) -> Void = { _ in }

    final class Coordinator: DesktopNavigationCoordinator {
        var onLoaded: ((Bool) -> Void)?
        var bridge = CloudNoVNCBridge()
        var url: URL?
        @objc func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onLoaded?(false) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let c = context.coordinator
        c.onLoaded = onLoaded
        c.allowedPort = url.port ?? 18766
        c.lastReloadToken = reloadToken
        c.url = url
        if let reused = CloudDesktopWebPool.take(url) {
            c.bridge = reused.bridge
            wire(c)
            reused.web.navigationDelegate = c
            reused.web.uiDelegate = c
            controller.web = reused.web
            let state = reused.bridge.lastState
            DispatchQueue.main.async {
                onLoaded(true)
                if state == "connected" { onState("connected") }
            }
            return reused.web
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        CloudNoVNCBridge.install(on: config, bridge: c.bridge)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        web.uiDelegate = c
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        wire(c)
        controller.web = web
        c.bridge.load(url, in: web)
        return web
    }

    private func wire(_ c: Coordinator) {
        c.bridge.onState = onState
        let ctl = controller
        c.bridge.onEvent = { [weak ctl] ev in ctl?.handle(ev) }
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onLoaded = onLoaded
        c.bridge.onState = onState
        if c.lastReloadToken != reloadToken || c.bridge.current != url {
            c.lastReloadToken = reloadToken
            c.allowedPort = url.port ?? 18766
            c.url = url
            c.bridge.load(url, in: web)
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        guard let url = coordinator.url else { return }
        let bridge = coordinator.bridge
        Task { @MainActor in CloudDesktopWebPool.park(.init(web: web, bridge: bridge, url: url)) }
    }
}
