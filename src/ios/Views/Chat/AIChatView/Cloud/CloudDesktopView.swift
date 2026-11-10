//
//  CloudDesktopView.swift
//  Minis - 云电脑画面网页的导航限制（旧的独立桌面页已合并进「电脑」页 CloudComputer.swift）
//

import SwiftUI
import WebKit

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
