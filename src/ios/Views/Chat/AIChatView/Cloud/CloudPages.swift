//
//  CloudPages.swift
//  Minis - 云端页面库（/v1/pages）
//  云端 Agent 用 page_write 保存的报告、看板与交互式 HTML。页面在非持久化、无 baseURL 的
//  WKWebView 中渲染：不能访问 VPS 接口或登录态，点开的外部链接交给系统浏览器。
//

import SwiftUI
import UIKit
import WebKit

struct CloudPagesView: View {
    @State private var pages: [[String: Any]] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if pages.isEmpty && !loading {
                Text("还没有页面。让云端 Agent “把结果做成一个页面”即可保存到这里。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(pages.indices, id: \.self) { i in
                let page = pages[i]
                let pid = page["page_id"] as? String ?? ""
                NavigationLink(destination: CloudPageDetailView(pageId: pid, title: page["title"] as? String ?? pid)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page["title"] as? String ?? pid).font(.headline)
                        if let summary = page["summary"] as? String, !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let updated = (page["updated_at"] as? NSNumber)?.doubleValue {
                            Text("v\((page["version"] as? NSNumber)?.intValue ?? 1) · " + Date(timeIntervalSince1970: updated).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task {
                            do {
                                _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/pages/" + pid, body: nil)
                            } catch {
                                errorText = error.localizedDescription
                            }
                            await reload()
                        }
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("云端页面库")
        .overlay { if loading && pages.isEmpty { ProgressView() } }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
            let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/pages", body: nil)
            pages = resp["pages"] as? [[String: Any]] ?? []
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct CloudPageDetailView: View {
    let pageId: String
    let title: String
    @State private var html: String?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let html {
                CloudPageWebView(html: html)
            } else if let errorText {
                Text(errorText).foregroundStyle(.red).padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let html {
                    ShareLink(item: html, preview: SharePreview(title)) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/pages/" + pageId, body: nil)
            html = resp["html"] as? String ?? ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

final class CloudPageNavigationCoordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 页面自身内容（loadHTMLString、锚点、脚本跳转到 about:）放行；用户点开的外部链接交给系统打开。
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if let scheme = navigationAction.request.url?.scheme?.lowercased(), !["about", "data", "blob"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

struct CloudPageWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> CloudPageNavigationCoordinator { CloudPageNavigationCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
