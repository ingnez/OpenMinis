import SwiftUI
import WebKit

/// 桌面链路体检：打开 noVNC 之前先问服务器 Xvfb / x11vnc / websockify 是否正常，坏了自动重启一次，仍不行就给出中文诊断。
struct CloudDesktopProblem: Equatable {
    enum Kind: Equatable { case serverOld, desktopDown, vncDown, proxyDown, tunnelDown, sshFailed, other }
    let kind: Kind
    let message: String

    var title: String {
        switch kind {
        case .serverOld: return "服务器未更新"
        case .desktopDown: return "桌面服务未运行"
        case .vncDown: return "VNC 端口不通"
        case .proxyDown: return "桌面网页代理未运行"
        case .tunnelDown: return "桌面端口隧道不通"
        case .sshFailed: return "连接云电脑失败"
        case .other: return "桌面暂时不可用"
        }
    }
}

enum CloudDesktopCheckResult: Equatable {
    case ready(token: String?, ownDisplay: Bool)
    case problem(CloudDesktopProblem)
}

@MainActor
enum CloudDesktopCheck {
    /// noVNC 地址：自动连接、断线自动重连、缩放适配；token 模式时指定屏幕（主屏为 main）
    static func streamURL(token: String?, viewOnly: Bool = false) -> URL? {
        let port = CloudConnection.shared.desktopPort
        var s = "http://127.0.0.1:\(port)/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1500&resize=scale&view_clip=0&show_dot=1"
        if viewOnly { s += "&view_only=1" }
        if let token, token.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil {
            s += "&path=websockify%3Ftoken%3D\(token)"
        }
        return URL(string: s)
    }

    static func run(botId: String?, autoRepair: Bool = true) async -> CloudDesktopCheckResult {
        let conn = CloudConnection.shared
        do {
            try await conn.ensureConnected()
        } catch {
            return .problem(.init(kind: .sshFailed, message: error.localizedDescription))
        }
        var health: [String: Any]?
        let query = botId.map { "?bot_id=\($0)" } ?? ""
        health = try? await conn.request(method: "GET", path: "/v1/desktop/health" + query)
        guard var h = health else {
            return await legacy(botId: botId)
        }
        if (h["ok"] as? Bool) != true, autoRepair, (h["own_display"] as? Bool) != true {
            // 主屏服务挂了：经 SSH 重启 display / vnc / novnc 一次再复查
            if (try? await conn.restartDesktop()) != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let again = try? await conn.request(method: "GET", path: "/v1/desktop/health" + query) { h = again }
            }
        }
        guard (h["ok"] as? Bool) == true else {
            let code = h["diagnosis"] as? String ?? ""
            let msg = h["message"] as? String ?? "桌面链路检查未通过"
            let kind: CloudDesktopProblem.Kind
            switch code {
            case "display_down": kind = .desktopDown
            case "vnc_down": kind = .vncDown
            case "proxy_down": kind = .proxyDown
            case "proxy_old": kind = .serverOld
            default: kind = .other
            }
            return .problem(.init(kind: kind, message: msg + "（已自动尝试重启桌面）"))
        }
        guard await conn.checkDesktopReachable() else {
            return .problem(.init(kind: .tunnelDown, message: "服务器上的桌面正常，但手机到 \(conn.desktopPort) 端口的 SSH 隧道不通。请点「重新连接」。"))
        }
        let proxy = h["token_proxy"] as? Bool ?? false
        return .ready(token: proxy ? (h["token"] as? String ?? "main") : nil, ownDisplay: h["own_display"] as? Bool ?? false)
    }

    /// 旧版服务器没有 /v1/desktop/health：沿用 /v1/desktop/display 的 token 逻辑，再不行就提示更新
    private static func legacy(botId: String?) async -> CloudDesktopCheckResult {
        let conn = CloudConnection.shared
        var token: String?
        var own = false
        var body: [String: Any] = [:]
        if let botId { body["bot_id"] = botId }
        if let resp = try? await conn.request(method: "POST", path: "/v1/desktop/display", body: body) {
            token = (resp["token_proxy"] as? Bool ?? false) ? (resp["token"] as? String ?? "main") : nil
            own = resp["own_display"] as? Bool ?? false
        }
        if await conn.checkDesktopReachable() {
            return .ready(token: token, ownDisplay: own)
        }
        return .problem(.init(kind: .serverOld, message: "服务器上的 Agent 版本较旧，无法检查桌面状态，桌面网页也打不开。请点「安装 / 更新桌面环境」。"))
    }
}

/// 失败时替代 noVNC 原始画面的诊断卡片
struct CloudDesktopProblemView: View {
    let problem: CloudDesktopProblem
    let onRetry: () -> Void
    @ObservedObject private var connection = CloudConnection.shared
    @State private var busy: String?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: 44)).foregroundStyle(.orange)
                Text(problem.title).font(.title3.bold()).foregroundStyle(.white)
                Text(problem.message).font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                if let busy {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text(busy).font(.footnote).foregroundStyle(.white) }
                    if busy.hasPrefix("正在安装"), !connection.installLog.isEmpty {
                        Text(String(connection.installLog.suffix(600))).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12)))
                    }
                } else {
                    VStack(spacing: 10) {
                        if problem.kind == .tunnelDown || problem.kind == .sshFailed {
                            wide("重新连接", prominent: true) { act("正在重新连接…") { try await connection.connect() } }
                        }
                        if problem.kind != .serverOld {
                            wide("重启桌面", prominent: problem.kind != .tunnelDown && problem.kind != .sshFailed) {
                                act("正在重启桌面…") {
                                    try await connection.restartDesktop()
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                }
                            }
                        }
                        wide("安装 / 更新桌面环境", prominent: problem.kind == .serverOld) {
                            act("正在安装 / 更新桌面环境，约需几分钟…") { try await connection.installAgent(withDesktop: true) }
                        }
                        Button("重新检测") { onRetry() }.font(.footnote).foregroundStyle(.white.opacity(0.8)).padding(.top, 4)
                    }
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            }
            .padding(28)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
    }

    private func wide(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(Capsule().fill(prominent ? Color.white : Color(white: 0.18)))
        }
        .buttonStyle(.plain)
    }

    private func act(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        busy = label
        errorText = nil
        Task { @MainActor in
            do {
                try await work()
                busy = nil
                onRetry()
            } catch {
                busy = nil
                errorText = error.localizedDescription
            }
        }
    }
}

/// 注入 noVNC 页面：隐藏它自带的控制栏、连接按钮和状态条，把连接状态回传给 App（App 自己显示诊断）
final class CloudNoVNCBridge: NSObject, WKScriptMessageHandler {
    var onState: ((String) -> Void)?

    static let script = """
    (function(){
      var css=document.createElement('style');
      css.textContent='#noVNC_control_bar_anchor,#noVNC_control_bar,#noVNC_connect_dlg,#noVNC_status,#noVNC_transition{display:none !important}';
      (document.head||document.documentElement).appendChild(css);
      var last='';
      function post(s){try{window.webkit.messageHandlers.vncState.postMessage(s);}catch(e){}}
      setInterval(function(){
        var root=document.documentElement, st=document.getElementById('noVNC_status');
        var s='';
        if(root.classList.contains('noVNC_connected')){s='connected';}
        else if(st&&(st.className||'').indexOf('noVNC_status_error')>=0){s='error:'+(st.textContent||'').trim();}
        else if(root.classList.contains('noVNC_disconnected')){s='disconnected';}
        if(s&&s!==last){last=s;post(s);}
      },500);
    })();
    """

    static func install(on config: WKWebViewConfiguration, bridge: CloudNoVNCBridge) {
        let ctl = config.userContentController
        ctl.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ctl.add(bridge, name: "vncState")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        DispatchQueue.main.async { self.onState?(s) }
    }
}
