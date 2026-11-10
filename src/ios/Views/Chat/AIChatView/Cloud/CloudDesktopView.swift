//
//  CloudDesktopView.swift
//  Minis - VPS Cloud Desktop Takeover View
//

import SwiftUI
import WebKit

struct CloudDesktopView: View {
    @ObservedObject private var connection = CloudConnection.shared
    @State private var state: CloudDesktopCheckResult?
    @State private var reloadToken = UUID()
    @State private var rechecking = false
    @State private var notice: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch state {
            case .none:
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在检查云电脑桌面…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            case .some(.problem(let p)):
                CloudDesktopProblemView(problem: p) { check() }
            case .some(.ready(let token, _)):
                // 与「电脑」页相同：token 模式时连主屏 main，旧版固定目标的服务器不带 token
                if let url = CloudDesktopCheck.streamURL(token: token) {
                    CloudDesktopWebView(url: url, reloadToken: reloadToken, onState: { vncStateChanged($0) })
                        .edgesIgnoringSafeArea(.bottom)
                }
            }
            if let notice {
                VStack {
                    Text(notice).font(.footnote).foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white))
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
        .navigationTitle("云电脑桌面接管")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reloadToken = UUID()
                    check()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新检测并刷新")
            }
        }
        .onAppear { check() }
    }

    private func check() {
        state = nil
        Task {
            let r = await CloudDesktopCheck.run(botId: nil)
            state = r
            reloadToken = UUID()
        }
    }

    private func vncStateChanged(_ s: String) {
        if s == "connected" { notice = nil; return }
        guard s.hasPrefix("error"), !rechecking else { return }
        rechecking = true
        Task {
            let r = await CloudDesktopCheck.run(botId: nil)
            rechecking = false
            if case .problem = r {
                state = r
            } else {
                notice = "画面断开，正在重连…"
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                notice = nil
            }
        }
    }
}

class DesktopNavigationCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var lastReloadToken: UUID?
    /// 允许的本机端口（隧道端口可能不是 18766）
    var allowedPort: Int = 18766
    // 限制仅允许访问 127.0.0.1:<桌面隧道端口>，拦截一切外链和重定向
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "http" && url.host == "127.0.0.1" && url.port == allowedPort && url.user == nil && url.password == nil {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    // 禁止新窗口弹窗
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct CloudDesktopWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    var onState: (String) -> Void = { _ in }

    final class Coordinator: DesktopNavigationCoordinator {
        let bridge = CloudNoVNCBridge()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        // 严格 cookies 隔离与无持久化
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        context.coordinator.bridge.onState = onState
        CloudNoVNCBridge.install(on: config, bridge: context.coordinator.bridge)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear

        context.coordinator.allowedPort = url.port ?? 18766
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.bridge.load(url, in: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.bridge.onState = onState
        // 当 reloadToken 变化或 URL 变化时重新加载
        if context.coordinator.bridge.current != url || context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.allowedPort = url.port ?? 18766
            context.coordinator.bridge.load(url, in: uiView)
        }
    }
}
