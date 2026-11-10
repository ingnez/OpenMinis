//
//  CloudDesktopView.swift
//  Minis - VPS Cloud Desktop Takeover View
//

import SwiftUI
import WebKit

struct CloudDesktopView: View {
    @ObservedObject private var connection = CloudConnection.shared
    @State private var isReachable = false
    @State private var isChecking = true
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在校验云电脑桌面连接 (本机端口 \(CloudConnection.shared.desktopPort))...")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding()
                Spacer()
            } else if !isReachable {
                VStack(spacing: 16) {
                    Image(systemName: "desktopcomputer.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("云电脑桌面端口不可达或服务未启动")
                        .font(.headline)
                    Text("请确保已通过“安装 / 更新云电脑桌面环境”成功部署，且 SSH 已成功建立桌面端口隧道。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("重新检测桌面可达性") {
                        checkReachability()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CloudDesktopWebView(url: CloudConnection.shared.desktopURL ?? URL(string: "http://127.0.0.1:18766/vnc.html")!, reloadToken: reloadToken)
                    .edgesIgnoringSafeArea(.bottom)
            }
        }
        .navigationTitle("云电脑桌面接管")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reloadToken = UUID()
                    checkReachability()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            checkReachability()
        }
    }

    private func checkReachability() {
        isChecking = true
        Task {
            let reachable = await connection.checkDesktopReachable()
            await MainActor.run {
                self.isReachable = reachable
                self.isChecking = false
            }
        }
    }
}

final class DesktopNavigationCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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

    func makeCoordinator() -> DesktopNavigationCoordinator {
        DesktopNavigationCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        // 严格 cookies 隔离与无持久化
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear

        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        context.coordinator.allowedPort = url.port ?? 18766
        context.coordinator.lastReloadToken = reloadToken
        webView.load(req)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 当 reloadToken 变化或 URL 变化时重新加载
        if uiView.url != url || context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.allowedPort = url.port ?? 18766
            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            uiView.load(req)
        }
    }
}
