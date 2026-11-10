import SwiftUI
import UIKit

/// 「连接诊断」：手机网络 → SSH 端口 → SSH 登录 → 服务器服务 → 隧道端口 → API Token → 桌面，逐项给出结论，可复制去敏日志
struct CloudLinkDiagnosticsView: View {
    var onOpenSettings: () -> Void = {}
    @ObservedObject private var link = CloudLinkSupervisor.shared
    @ObservedObject private var conn = CloudConnection.shared
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [CloudDiagStep] = []
    @State private var running = false
    @State private var copied = false
    @State private var busy: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(stateText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if case .offline(let cause) = link.state {
                    Button(cause.fix.title) { link.performFix(cause.fix, openSettings: onOpenSettings) }
                }
                Button("立即重连") { link.userRetry() }
            }
            Section {
                if steps.isEmpty && !running {
                    Text("点下面的按钮逐项检查连接链路").foregroundStyle(.secondary)
                }
                ForEach(steps) { s in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: s.result == .pass ? "checkmark.circle.fill" : (s.result == .fail ? "xmark.octagon.fill" : "minus.circle"))
                            .foregroundStyle(s.result == .pass ? Color.green : (s.result == .fail ? Color.red : Color.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.subheadline.weight(.medium))
                            Text(s.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if running {
                    HStack(spacing: 8) { ProgressView(); Text("正在检查…").foregroundStyle(.secondary) }
                }
                Button(running ? "检查中…" : "开始连接诊断") { run() }.disabled(running)
            } header: { Text("连接诊断") }
            if steps.contains(where: { $0.result == .fail }) {
                Section("修复") {
                    if let busy {
                        HStack(spacing: 8) { ProgressView(); Text(busy).foregroundStyle(.secondary) }
                    } else {
                        Button("重启桌面") { act("正在重启桌面…") { try await conn.restartDesktop() } }
                        Button("安装 / 更新服务器") { act("正在安装 / 更新，约需几分钟…") { try await conn.installAgent(withDesktop: true) } }
                        Button("检查连接设置") { onOpenSettings() }
                    }
                }
            }
            if !steps.isEmpty {
                Section {
                    Button(copied ? "已复制" : "复制诊断日志（不含密码和 Token）") {
                        UIPasteboard.general.string = logText
                        copied = true
                    }
                }
            }
        }
        .navigationTitle("云电脑连接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }

    private var stateText: String {
        switch link.state {
        case .online: return link.serverOutdated ? "在线（服务器需要更新）" : "在线"
        case .connecting: return "正在连接…"
        case .retrying(let n): return "正在重连（第 \(n) 次）"
        case .offline(let c): return c.message
        case .idle: return "还没有配置云电脑"
        }
    }

    private var logText: String {
        let head = "OpenMinis 连接诊断 \(ISO8601DateFormatter().string(from: Date()))\n状态：\(stateText)\n"
        let body = steps.map { "[\($0.result == .pass ? "通过" : ($0.result == .fail ? "失败" : "跳过"))] \($0.title)：\($0.detail)" }.joined(separator: "\n")
        return CloudLogRedactor.redact(head + body)
    }

    private func run() {
        running = true
        copied = false
        steps = []
        Task {
            steps = await conn.runDiagnostics(networkAvailable: link.networkAvailable)
            running = false
            if steps.allSatisfy({ $0.result != .fail }) { link.userRetry() }
        }
    }

    private func act(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        busy = label
        Task { @MainActor in
            do { try await work() } catch { steps.append(CloudDiagStep(id: "fix-\(UUID())", title: "修复失败", result: .fail, detail: error.localizedDescription)) }
            busy = nil
            run()
        }
    }
}
