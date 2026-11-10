import SwiftUI
import UIKit

/// 导出错误日志：给反馈问题用，可复制或分享成文件
struct CloudErrorLogView: View {
    @State private var text = ""
    @State private var fileURL: URL?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                if text.isEmpty && error == nil { ProgressView() }
                if !text.isEmpty {
                    Text(text).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(40)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: { Text("包括 App 和服务器版本、最近 7 天任务出错和服务器后台异常。不含对话内容，密钥、Token、密码和 IP 后两段都已打码。") }
            if !text.isEmpty {
                Section {
                    Button(copied ? "已复制" : "复制") { UIPasteboard.general.string = text; copied = true }
                    if let fileURL { ShareLink(item: fileURL) { Label("分享为文件", systemImage: "square.and.arrow.up") } }
                }
            }
        }
        .navigationTitle("导出错误日志")
        .task { await load() }
    }

    private func load() async {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let system = "iOS \(UIDevice.current.systemVersion)"
        var errors: [[String: Any]] = []
        var server = ""
        do {
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/logs/errors")
            errors = r["errors"] as? [[String: Any]] ?? []
            server = r["version"] as? String ?? ""
        } catch {
            self.error = "服务器的错误记录没取到：\(CloudLogRedactor.redact(error.localizedDescription).prefix(100))"
        }
        text = CloudErrorLogFormat.text(appVersion: app, system: system, serverVersion: server, errors: errors)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenMinis-错误日志.txt")
        if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { fileURL = url }
    }
}
