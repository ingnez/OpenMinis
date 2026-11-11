import SwiftUI
import WebKit

/// 桌面链路体检：打开 noVNC 之前先问服务器 Xvfb / x11vnc / websockify 是否正常，坏了自动重启一次，仍不行就给出中文诊断。
struct CloudDesktopProblem: Equatable {
    enum Kind: Equatable { case serverOld, desktopDown, vncDown, proxyDown, tunnelDown, sshFailed, other }
    let kind: Kind
    let message: String

    var title: String {
        switch kind {
        case .serverOld: return "服务器 Agent 版本过旧"
        case .desktopDown: return "桌面服务未运行"
        case .vncDown: return "VNC 端口不通"
        case .proxyDown: return "桌面网页代理未运行"
        case .tunnelDown: return "隧道未转发桌面端口"
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
            try await CloudQuiet.retry { try await conn.ensureConnected() }
        } catch {
            return .problem(.init(kind: .sshFailed, message: error.localizedDescription))
        }
        var health: [String: Any]?
        let query = botId.map { "?bot_id=\($0)" } ?? ""
        // 一次超时不能当成「服务器太旧」：静默重试；只有服务器明确回 404 才走旧版兼容
        do {
            health = try await CloudQuiet.retry { try await conn.request(method: "GET", path: "/v1/desktop/health" + query) }
        } catch let e as URLError where CloudConnection.tunnelDropped(e) {
            return .problem(.init(kind: .tunnelDown, message: "到 VPS 的隧道暂时不通，已在自动重连"))
        } catch {
            health = nil
        }
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
            case "vnc_down", "ws_failed", "token_mismatch": kind = .vncDown
            case "proxy_down": kind = .proxyDown
            case "proxy_old": kind = .serverOld
            default: kind = .other
            }
            return .problem(.init(kind: kind, message: msg + "（已自动尝试重启桌面）"))
        }
        if !(await conn.checkDesktopReachable()) {
            // 隧道可能在后台被系统断掉、或重连时没转发桌面端口：自动重建一次隧道（每次重建都同时转发 API 与桌面端口）
            if autoRepair { try? await conn.reconnect() }
            guard await conn.checkDesktopReachable() else {
                return .problem(.init(kind: .tunnelDown, message: "服务器上的桌面正常，但手机到本机 \(conn.desktopPort) 端口的 SSH 隧道没有转发桌面。已自动重建过一次隧道，请点「重新连接」再试。"))
            }
        }
        let proxy = h["token_proxy"] as? Bool ?? false
        let token = proxy ? (h["token"] as? String ?? "main") : nil
        // 端到端：从手机经隧道连 websocket，确认真的能收到 VNC 握手（RFB），否则 noVNC 只会显示「无法连接到服务器」
        if let why = await probeStream(token: token) {
            if autoRepair, (h["own_display"] as? Bool) != true, (try? await conn.restartDesktop()) != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if await probeStream(token: token) == nil {
                    return .ready(token: token, ownDisplay: h["own_display"] as? Bool ?? false)
                }
            }
            return .problem(.init(kind: .vncDown, message: "桌面网页能打开，但画面通道不通：\(why)。已自动重启过一次桌面；仍不行请点「安装 / 更新桌面环境」。"))
        }
        return .ready(token: token, ownDisplay: h["own_display"] as? Bool ?? false)
    }

    /// 经隧道连 ws://127.0.0.1:<桌面端口>/websockify[?token=]，5 秒内收到以 "RFB " 开头的握手即通过；返回 nil 表示正常，否则是中文原因
    static func probeStream(token: String?) async -> String? {
        let port = CloudConnection.shared.desktopPort
        var path = "/websockify"
        if let token, token.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil { path += "?token=" + token }
        guard let url = URL(string: "ws://127.0.0.1:\(port)" + path) else { return "地址无效" }
        let task = URLSession.shared.webSocketTask(with: url, protocols: ["binary"])
        task.resume()
        let timeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); task.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel(); task.cancel(with: .normalClosure, reason: nil) }
        do {
            let msg = try await task.receive()
            let head: String
            switch msg {
            case .data(let d): head = String(decoding: d.prefix(4), as: UTF8.self)
            case .string(let s): head = String(s.prefix(4))
            @unknown default: head = ""
            }
            return head.hasPrefix("RFB") ? nil : "收到的不是 VNC 握手"
        } catch {
            if let code = (task.response as? HTTPURLResponse)?.statusCode, code != 101 {
                return code == 404 ? "websockify 找不到这个屏幕（token 不对）" : "websockify 返回 HTTP \(code)"
            }
            return task.closeCode == .invalid ? "websocket 没有响应（x11vnc 未就绪或 token 目标不对）" : "websocket 被关闭（\(task.closeCode.rawValue)）"
        }
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
            if await probeStream(token: token) == nil { return .ready(token: token, ownDisplay: own) }
            return .problem(.init(kind: .serverOld, message: "服务器上的 Agent 版本过旧：桌面网页能打开，但画面连不上，也无法自动诊断。请点「安装 / 更新桌面环境」一键更新。"))
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
                            wide("重新连接（重建隧道）", prominent: true) { act("正在重建隧道…") { try await connection.reconnect() } }
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

/// 桌面画面：不用 noVNC 自带的 vnc.html（它的落地页有「连接」按钮和英文/中文错误条），
/// 而是在 App 自己的页面里直接加载服务器上 noVNC 的 core/rfb.js 连 websocket，状态全部回传给 App 显示中文诊断。
/// 服务器 noVNC 太旧（没有 ES 模块）时回退到 vnc.html，并注入样式隐藏它的控制栏、连接按钮和状态条。
final class CloudNoVNCBridge: NSObject, WKScriptMessageHandler {
    var onState: ((String) -> Void)?
    /// window.om 发回来的事件（fb 尺寸、剪贴板、截图、录屏、nopointer）
    var onEvent: (([String: Any]) -> Void)?
    /// 最近一次连接状态（复用保活的画面时直接知道它是不是还连着）
    private(set) var lastState = ""
    weak var webView: WKWebView?
    private(set) var current: URL?
    private var fellBack = false

    static let hideScript = """
    (function(){
      if(!document.getElementById('noVNC_control_bar_anchor')&&!document.getElementById('noVNC_status')){return;}
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

    /// 从 streamURL 的参数生成 App 自己的画面页
    static func page(for url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let path = items.first(where: { $0.name == "path" })?.value ?? "websockify"
        let safePath = path.range(of: #"^websockify(\?token=[A-Za-z0-9_-]{1,64})?$"#, options: .regularExpression) != nil ? path : "websockify"
        let viewOnly = items.contains(where: { $0.name == "view_only" && $0.value == "1" })
        let port = url.port ?? 18766
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#screen{position:absolute;inset:0}</style>
        </head><body><div id="screen"></div>
        <script type="module">
        const post = s => { try { window.webkit.messageHandlers.vncState.postMessage(s); } catch (e) {} };
        let RFB = null;
        try { RFB = (await import('./core/rfb.js')).default; } catch (e) { post('nomodule'); }
        \(omScript)
        if (RFB) {
          const url = 'ws://127.0.0.1:\(port)/\(safePath)';
          let rfb = null, tries = 0, timer = null;
          const connect = () => {
            timer = null;
            post('connecting');
            try { rfb = new RFB(document.getElementById('screen'), url, { wsProtocols: ['binary'] }); }
            catch (e) { post('error:' + e); retry(); return; }
            rfb.scaleViewport = true;
            rfb.resizeSession = false;
            rfb.viewOnly = \(viewOnly ? "true" : "false");
            rfb.background = '#000';
            // 先低清快速出第一帧（实测首帧字节 -33%），连上后 App 按延迟升级画质
            try { rfb.qualityLevel = 2; rfb.compressionLevel = 9; } catch (e) {}
            window.__omRFB = rfb;
            rfb.addEventListener('clipboard', e => om.send({ type: 'clipboard', text: (e.detail && e.detail.text) || '' }));
            rfb.addEventListener('connect', () => {
              tries = 0; post('connected'); setTimeout(om.fb, 50);
              // 真实流量计数：统计 WebSocket 收到的字节，每 2 秒报一次
              try { const ws = rfb._sock && rfb._sock._websocket; if (ws && !ws.__omBytes) { ws.__omBytes = 1; ws.addEventListener('message', e => { om.bytes = (om.bytes || 0) + ((e.data && e.data.byteLength) || 0); }); } } catch (e) {}
            });
            rfb.addEventListener('securityfailure', e => post('error:security ' + ((e.detail && e.detail.reason) || '')));
            rfb.addEventListener('disconnect', e => {
              post((e.detail && e.detail.clean) ? 'disconnected' : 'error:画面连接断开');
              retry();
            });
          };
          const retry = () => {
            if (timer) return;
            tries += 1;
            // 与 CloudReconnect.delay 一致：0.3 s 起翻倍，上限 8 s（网络切换时 App 直接调 __omReconnect 立刻重连）
            timer = setTimeout(connect, Math.min(8000, 300 * Math.pow(2, tries - 1)));
          };
          window.__omReconnect = () => { tries = 0; try { rfb && rfb.disconnect(); } catch (e) {} if (!timer) connect(); };
          connect();
        }
        </script></body></html>
        """
    }

    /// App 控制画面用的 window.om：触控板指针、滚轮、按键、剪贴板、画质、缩放、截图、录屏。
    /// 指针走 RFB 协议的 PointerEvent（远端像素坐标），noVNC 没有这个接口时报 nopointer，App 退回直接触控。
    static let omScript = """
    const om = window.om = {};
    om.send = o => { try { window.webkit.messageHandlers.om.postMessage(JSON.stringify(o)); } catch (e) {} };
    om.bytes = 0;
    setInterval(() => { if (om.bytes) { om.send({ type: 'bytes', n: om.bytes }); om.bytes = 0; } }, 2000);
    const scr = document.getElementById('screen');
    const cvs = () => scr.querySelector('canvas');
    const cur = document.createElement('div');
    cur.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:9;display:none';
    cur.innerHTML = '<svg width="18" height="26" viewBox="0 0 18 26" style="position:absolute;left:-1px;top:-1px"><path d="M1 1 L1 20 L6 15 L10 24 L13 23 L9 14 L16 14 Z" fill="#fff" stroke="#000" stroke-width="1.4"/></svg>';
    scr.appendChild(cur);
    let view = { s: 1 }, last = { x: 0, y: 0 };
    const rect = () => {
      const c = cvs(); if (!c) return null;
      const a = c.getBoundingClientRect(), b = scr.getBoundingClientRect();
      return { x: (a.left - b.left) / view.s, y: (a.top - b.top) / view.s, w: a.width / view.s, h: a.height / view.s, fw: c.width, fh: c.height };
    };
    const place = () => { const r = rect(); if (!r || !r.fw) return; cur.style.left = (r.x + last.x * r.w / r.fw) + 'px'; cur.style.top = (r.y + last.y * r.h / r.fh) + 'px'; };
    om.fb = () => { const r = rect(); if (r) om.send({ type: 'fb', w: r.fw, h: r.fh, x: r.x, y: r.y, cw: r.w, ch: r.h }); };
    window.addEventListener('resize', () => setTimeout(() => { om.fb(); place(); }, 120));
    const R = () => window.__omRFB;
    om.ptr = (x, y, mask) => {
      last = { x, y }; place();
      const rfb = R(); if (!rfb) return;
      try {
        if (typeof RFB !== 'undefined' && RFB && RFB.messages && RFB.messages.pointerEvent && rfb._sock) RFB.messages.pointerEvent(rfb._sock, x, y, mask);
        else if (rfb._sendMouse) rfb._sendMouse(x, y, mask);
        else om.send({ type: 'nopointer' });
      } catch (e) { om.send({ type: 'nopointer' }); }
    };
    om.wheel = (x, y, v, h, mask) => {
      const tap = (b, n) => { for (let i = 0; i < n; i++) { om.ptr(x, y, mask | b); om.ptr(x, y, mask); } };
      if (v) tap(v > 0 ? 16 : 8, Math.min(20, Math.abs(v)));
      if (h) tap(h > 0 ? 64 : 32, Math.min(20, Math.abs(h)));
    };
    om.keys = list => { const rfb = R(); if (!rfb) return; for (const k of list) { try { rfb.sendKey(k[0], null, !!k[1]); } catch (e) {} } };
    om.clip = t => { const rfb = R(); try { rfb && rfb.clipboardPasteFrom(t); } catch (e) {} };
    om.quality = (q, c) => { const rfb = R(); try { if (rfb) { rfb.qualityLevel = q; rfb.compressionLevel = c; } } catch (e) {} };
    om.viewOnly = v => { const rfb = R(); try { if (rfb) rfb.viewOnly = !!v; } catch (e) {} };
    om.cursor = v => { cur.style.display = v ? 'block' : 'none'; place(); };
    // 缩放平移只改 transform（合成层上做，不重排、不重画画布），捏合时 120Hz 跟手；同一帧里多次调用只落最后一次
    let viewReq = null;
    scr.style.transformOrigin = '0 0'; scr.style.willChange = 'transform';
    om.view = (s, tx, ty) => {
      view.s = s;
      const apply = () => { viewReq = null; scr.style.transform = 'translate3d(' + tx + 'px,' + ty + 'px,0) scale(' + s + ')'; };
      if (viewReq) cancelAnimationFrame(viewReq);
      viewReq = requestAnimationFrame(apply);
    };
    om.shot = () => { const c = cvs(); if (!c) { om.send({ type: 'shot', error: 'nocanvas' }); return; } try { om.send({ type: 'shot', data: c.toDataURL('image/png') }); } catch (e) { om.send({ type: 'shot', error: String(e) }); } };
    let rec = null, chunks = [], recTimer = null, recCanvas = null;
    const recBlit = () => {
      const src = cvs(), rc = recCanvas; if (!src || !rc) return;
      if (rc.width !== src.width) rc.width = src.width;
      if (rc.height !== src.height) rc.height = src.height;
      try { rc.getContext('2d').drawImage(src, 0, 0); } catch (e) {}
    };
    const recCleanup = () => {
      if (recTimer) { clearInterval(recTimer); recTimer = null; }
      if (recCanvas && recCanvas.parentNode) recCanvas.parentNode.removeChild(recCanvas);
      recCanvas = null;
    };
    om.rec = on => {
      const c = cvs();
      if (on) {
        if (rec) return;
        if (!c || !c.captureStream || !window.MediaRecorder) { om.send({ type: 'rec', error: 'unsupported' }); return; }
        const mime = ['video/mp4', 'video/webm'].find(m => MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(m)) || '';
        // 远端画面停住之后，直接 captureStream 画布不会再出帧，录完是空文件。另开一块画布定时把当前画面画过去，不改 noVNC 正在用的那块。
        recCanvas = document.createElement('canvas');
        recCanvas.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none';
        (scr || document.body).appendChild(recCanvas);
        recBlit();
        let r;
        try { r = new MediaRecorder(recCanvas.captureStream(10), mime ? { mimeType: mime } : {}); } catch (e) { recCleanup(); om.send({ type: 'rec', error: String(e) }); return; }
        chunks = [];
        rec = r;
        recTimer = setInterval(recBlit, 100);
        r.onerror = e => om.send({ type: 'rec', error: String((e.error && (e.error.name || e.error.message)) || e.type || e) });
        r.ondataavailable = e => { if (e.data && e.data.size) chunks.push(e.data); };
        r.onstop = () => {
          recBlit();
          recCleanup();
          rec = null;
          const typ = r.mimeType || mime || 'video/mp4';
          const b = new Blob(chunks, { type: typ });
          const fr = new FileReader();
          fr.onload = () => om.send({ type: 'rec', data: fr.result, mime: b.type || typ });
          fr.onerror = () => om.send({ type: 'rec', error: 'read' });
          fr.readAsDataURL(b);
        };
        try { r.start(1000); } catch (e) { recCleanup(); rec = null; om.send({ type: 'rec', error: String(e) }); return; }
        om.send({ type: 'rec', started: true });
      } else if (rec) {
        try { rec.stop(); } catch (e) { recCleanup(); rec = null; om.send({ type: 'rec', error: String(e) }); }
      }
    };

    """

    static func install(on config: WKWebViewConfiguration, bridge: CloudNoVNCBridge) {
        let ctl = config.userContentController
        ctl.addUserScript(WKUserScript(source: hideScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ctl.add(CloudWeakScriptHandler(bridge), name: "vncState")
        ctl.add(CloudWeakScriptHandler(bridge), name: "om")
    }

    /// 加载画面：优先 App 自己的页面
    func load(_ url: URL, in web: WKWebView) {
        webView = web
        current = url
        fellBack = false
        guard let base = URL(string: "http://127.0.0.1:\(url.port ?? 18766)/") else { return }
        let html = Self.page(for: url)
        web.loadHTMLString(CloudE2E.fakeDesktop ? CloudDesktopFakePage.patch(html) : html, baseURL: base)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        if message.name == "om" {
            guard let data = s.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            DispatchQueue.main.async { self.onEvent?(obj) }
            return
        }
        if s == "connected" || s.hasPrefix("error") || s == "disconnected" { lastState = s }
        DispatchQueue.main.async {
            if s == "nomodule" {
                // 服务器 noVNC 没有 core/rfb.js（很旧的版本）：退回 vnc.html + 隐藏控件
                if !self.fellBack, let url = self.current, let web = self.webView {
                    self.fellBack = true
                    web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
                }
                return
            }
            self.onState?(s)
        }
    }
}

/// WKUserContentController 会强引用 handler，用弱引用包一层避免 WebView 与 bridge 循环引用
final class CloudWeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
