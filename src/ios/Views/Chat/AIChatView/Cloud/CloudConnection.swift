//
//  CloudConnection.swift
//  Minis - VPS Cloud Connection & Tunnel Extension for Desktop & Agent
//

import Foundation
import Security
import Combine
import Darwin

public enum CloudConnectionStatus: Equatable, Sendable {
    case disconnected, connecting, connected
    case error(String)
}

private final class CloudShellWait {
    var finished = false
    var pid: Int32 = -1
}

@MainActor
public final class CloudConnection: ObservableObject {
    public static let shared = CloudConnection()
    @Published public private(set) var status: CloudConnectionStatus = .disconnected
    @Published public private(set) var isConnected = false
    @Published public private(set) var currentFingerprint: String?
    @Published public private(set) var pendingHostKeyMessage: String?
    /// 本机隧道端口：默认 18765 / 18766；被残留进程占用时自动换成空闲端口
    @Published public private(set) var apiPort: Int = 18765
    @Published public private(set) var desktopPort: Int = 18766
    /// 安装过程中实时拉回的服务器安装日志（末尾一段）
    @Published public private(set) var installLog: String = ""
    public var desktopURL: URL? { URL(string: "http://127.0.0.1:\(desktopPort)/vnc.html?autoconnect=1&reconnect=1&resize=scale") }
    @Published public var name: String { didSet { persist() } }
    @Published public var host: String { didSet { if oldValue != host { changed() } } }
    @Published public var sshPort: Int { didSet { if oldValue != sshPort { changed() } } }
    @Published public var username: String { didSet { if oldValue != username { changed() } } }
    private let knownHosts = "/root/.ssh/openminis_cloud_known_hosts"
    private var pendingKeys: String?
    private var pendingIdentity: String?
    private var controlPath: String?
    private var generation = UUID()
    private let redirectDelegate = CloudRedirectDelegate()
    private lazy var http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 40
        c.connectionProxyDictionary = [:]
        // 默认每个主机只有 4 条连接：多 Bot 模式同时挂着通知、任务事件、群聊长轮询时，普通请求和探活会排队超时，
        // 被误判为「隧道断了」而拆隧道重连，进而所有请求一起失败——这是多 Bot 模式频繁「连接失败」的主因
        c.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: c, delegate: redirectDelegate, delegateQueue: nil)
    }()
    /// 长轮询（?wait=）专用：单独的连接池，不占普通请求的连接；超时放宽
    private lazy var longHTTP: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 60
        c.connectionProxyDictionary = [:]
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c, delegate: redirectDelegate, delegateQueue: nil)
    }()
    /// 探活专用：永远不会排在别的请求后面
    private lazy var probeHTTP: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        c.connectionProxyDictionary = [:]
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: redirectDelegate, delegateQueue: nil)
    }()
    private static func isLongPoll(_ path: String) -> Bool {
        if path.hasPrefix("/v1/relays/check") { return true }     // 中转站体检要发好几次真实请求
        guard let r = path.range(of: "wait=") else { return false }
        return !path[r.upperBound...].hasPrefix("0")
    }
    private init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "OpenMinisCloud_name") ?? "我的 VPS"
        host = d.string(forKey: "OpenMinisCloud_host") ?? ""
        sshPort = d.object(forKey: "OpenMinisCloud_sshPort") as? Int ?? 22
        username = d.string(forKey: "OpenMinisCloud_username") ?? "root"
    }
    private var identity: String { "\(host.lowercased()):\(sshPort):\(username)" }
    private func persist() {
        let d = UserDefaults.standard
        d.set(name, forKey: "OpenMinisCloud_name"); d.set(host, forKey: "OpenMinisCloud_host")
        d.set(sshPort, forKey: "OpenMinisCloud_sshPort"); d.set(username, forKey: "OpenMinisCloud_username")
    }
    private func changed() { disconnect(); persist() }
    private var connectTask: Task<Void, Error>?
    /// 已保存连接信息时可后台自动连接（无需再点「保存并测试连接」）
    public var canAutoConnect: Bool {
        #if DEBUG
        if CloudE2E.token != nil { return true }
        #endif
        return !host.isEmpty && !(getPassword() ?? "").isEmpty && !(getToken() ?? "").isEmpty
    }
    /// 最近一次 API 成功应答的时间：超过 20 秒没有成功请求时，先用 2 秒的 /health 探测隧道是否还活着
    public private(set) var lastOK = Date.distantPast
    /// 已连接且隧道活着直接返回；隧道已死（App 被挂起后常见）就拆掉重建；正在连接则等待同一次连接。
    public func ensureConnected() async throws {
        if isConnected {
            if Date().timeIntervalSince(lastOK) < 20 { return }
            if await probeAlive() { return }
            try await reconnect()
            return
        }
        try await connect()
    }
    /// 隧道是否还通：2 秒内 /health 应答才算活着
    public func probeAlive(timeout: TimeInterval = 2) async -> Bool {
        guard isConnected, let url = URL(string: "http://127.0.0.1:\(apiPort)/health") else { return false }
        // 两次机会：第一次超时（服务器忙、手机网络抖动）再给一次更长的；本机端口直接拒绝连接才是真断
        for t in [timeout, timeout * 2] {
            var req = URLRequest(url: url)
            req.timeoutInterval = t
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, resp) = try await probeHTTP.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["service"] as? String == "openminis-cloud-agent" {
                    lastHealth = obj
                    lastOK = Date()
                    return true
                }
                return false
            } catch let e as URLError where e.code == .cannotConnectToHost {
                return false            // 本机转发端口已不在：隧道确实断了
            } catch {
                continue
            }
        }
        return false
    }
    /// 最近一次 /health 的内容（Agent 版本、桌面状态），连接状态点和「更新服务器」横幅用
    @Published public private(set) var lastHealth: [String: Any] = [:]
    /// App 回到前台 / 进入后台时调用：之后的第一次请求必须先探测隧道
    public func markStale() { lastOK = .distantPast }
    /// 强制拆掉旧隧道重新建立；并发调用共享同一次
    public func reconnect() async throws {
        let t0 = Date()
        // SSH 主连接（ControlMaster）还在：转发多半只是暂时没应答（刚从后台回来），再给一次 3 秒探测，通了就直接复用
        if isConnected, connectTask == nil, await masterAlive(), await probeAlive(timeout: 3) {
            CloudClientMetrics.record(mode: "link", kind: "reuse", ms: Date().timeIntervalSince(t0) * 1000)
            return
        }
        isConnected = false
        try await connect()
        // 性能页实测：拆掉旧隧道到新隧道可用的耗时（两种模式共用同一条隧道）
        CloudClientMetrics.record(mode: "link", kind: "reconnect", ms: Date().timeIntervalSince(t0) * 1000)
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "OpenMinisCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func validate() throws {
        guard (1...65535).contains(sshPort) else { throw failure("SSH 端口必须在 1–65535 之间") }
        guard username.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil else {
            throw failure("用户名格式不正确")
        }
        var address = in6_addr()
        let ipv6 = host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        let dns = host.count <= 253 && host.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil && !host.contains("..")
        guard ipv6 || dns else { throw failure("请输入有效 IP 或域名，不含协议、路径或空格") }
    }
    private func account(_ key: String) -> String { identity + ":" + key }
    private func saveSecret(_ value: String, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.openminis.cloud.agent", kSecAttrAccount as String: account(key)]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            var add = query; attrs.forEach { add[$0.key] = $0.value }
            result = SecItemAdd(add as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw failure("凭据保存失败（Keychain \(result)），请解锁设备后重试") }
    }
    private func secret(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.openminis.cloud.agent", kSecAttrAccount as String: account(key),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func saveCredentials(password: String, token: String) throws {
        try validate()
        guard !password.contains("\n"), !password.contains("\r") else { throw failure("SSH 密码不能包含换行") }
        try saveSecret(password, key: "password"); try saveSecret(token, key: "token")
    }
    public func getPassword() -> String? { secret("password") }
    public func getToken() -> String? {
        #if DEBUG
        if let t = CloudE2E.token { return t }
        #endif
        return secret("token")
    }

    private func shell(_ command: String, input: Data? = nil, timeout: TimeInterval = 45) async throws -> ISHShellExecutionResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ISHShellExecutionResult, Error>) in
            let wait = CloudShellWait()
            wait.pid = ISHShellExecutor.executeExecutable("/bin/sh", arguments: ["-c", command], environment: nil,
                stdinData: input, lineCallback: nil) { result in
                guard !wait.finished else { return }
                wait.finished = true; continuation.resume(returning: result)
            }
            if wait.pid <= 0 && !wait.finished {
                wait.finished = true; continuation.resume(throwing: self.failure("无法创建本地 SSH 进程"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !wait.finished else { return }
                wait.finished = true
                ISHShellExecutor.killProcessGroup(wait.pid)
                ISHShellExecutor.finalizeTimedOutPid(wait.pid)
                continuation.resume(throwing: self.failure("SSH 操作超时，请检查网络和服务器"))
            }
        }
    }
    private func checked(_ command: String, input: Data? = nil, timeout: TimeInterval = 45) async throws -> String {
        let r = try await shell(command, input: input, timeout: timeout)
        guard r.exitCode == 0 else {
            // 同时保留 stderr 与 stdout 末尾，避免只看到半截输出
            let parts = [r.errorOutput, r.output].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let message = String(parts.joined(separator: "\n").suffix(3000))
            if r.exitCode == 255 {
                throw failure("SSH 连接失败或中途断开（255）：\(message)")
            }
            throw failure("SSH 操作失败（\(r.exitCode)）：\(message)")
        }
        return r.output
    }
    private func prepare() async throws {
        if !ISHKernel.shared.isBooted {
            try RootfsManager.shared.installIfNeeded()
            let rc = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
            guard rc >= 0 else { throw failure("本地连接环境启动失败（\(rc)）") }
            installSessionFileChangeTracker(kernel: ISHKernel.shared)
            MinisFsRouter.shared.installHook()
            RootfsManager.shared.applyDefaultMountOverlay()
        }
        _ = try await checked("command -v ssh >/dev/null && command -v sshpass >/dev/null && command -v ssh-keyscan >/dev/null && command -v ssh-keygen >/dev/null || apk add --no-cache openssh-client sshpass", timeout: 240)
        _ = try await checked("umask 077; mkdir -p /root/.ssh; touch \(quote(knownHosts)); chmod 600 \(quote(knownHosts))")
    }
    private var knownName: String { sshPort == 22 ? host : "[\(host)]:\(sshPort)" }
    private func verifyHost() async throws {
        let known = try await shell("ssh-keygen -F \(quote(knownName)) -f \(quote(knownHosts))")
        if known.exitCode == 0 && !known.output.isEmpty { return }
        let raw = try await checked("ssh-keyscan -T 8 -p \(sshPort) -t ed25519,ecdsa,rsa -- \(quote(host)) 2>/dev/null", timeout: 30)
        let lines = raw.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(String(fields[1])), Data(base64Encoded: String(fields[2])) != nil else { return nil }
            return "\(knownName) \(fields[1]) \(fields[2])"
        }
        guard !lines.isEmpty else { throw failure("无法取得 SSH 主机公钥") }
        let keys = lines.joined(separator: "\n") + "\n"
        let temp = "/tmp/cloud-host-\(UUID().uuidString)"
        _ = try await checked("umask 077; cat > \(quote(temp))", input: Data(keys.utf8))
        let fp = try await shell("ssh-keygen -lf \(quote(temp)); rc=$?; rm -f \(quote(temp)); exit $rc")
        guard fp.exitCode == 0 else { throw failure("主机指纹计算失败") }
        currentFingerprint = fp.output.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingKeys = keys; pendingIdentity = identity
        pendingHostKeyMessage = "首次连接 \(host):\(sshPort)\n\(currentFingerprint ?? "")\n请与服务器控制台的 SSH 主机指纹核对后确认。"
        throw failure("请先核对并确认下方 SSH 主机指纹")
    }
    private func options() -> String {
        "-p \(sshPort) -o ConnectTimeout=15 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o TCPKeepAlive=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=\(quote(knownHosts)) -o GlobalKnownHostsFile=/dev/null -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=password,keyboard-interactive -o LogLevel=ERROR"
    }
    private var destination: String { quote(username + "@" + host) }
    private func passwordFile() async throws -> String {
        guard let password = getPassword(), !password.isEmpty else { throw failure("请先输入并保存 SSH 密码") }
        let file = "/tmp/.cloud-password-\(UUID().uuidString)"
        _ = try await checked("umask 077; cat > \(quote(file)); chmod 600 \(quote(file))", input: Data(password.utf8))
        return file
    }
    private func cleanup(_ path: String) async { _ = try? await shell("rm -f \(quote(path))", timeout: 10) }
    /// 建立连接；已有连接过程在进行时等待同一次，避免多处同时调用互相断开（之前「连接已取消」的来源）
    public func connect() async throws {
        if let task = connectTask { return try await task.value }
        let task = Task { @MainActor in try await self.connectNow() }
        connectTask = task
        defer { if connectTask == task { connectTask = nil } }
        try await task.value
    }
    private func connectNow() async throws {
        disconnect()
        #if DEBUG
        if CloudE2E.token != nil {
            // 模拟器端到端测试：直连同一台 Mac 上的本地云端 Agent，不走 SSH
            apiPort = CloudE2E.port; desktopPort = CloudE2E.port + 1
            isConnected = true; status = .connected; lastOK = Date()
            return
        }
        #endif
        let expected = generation
        status = .connecting
        do {
            try validate(); try await prepare(); try await verifyHost()
            guard generation == expected else { throw failure("服务器配置已改变，请重新连接") }
            try await openTunnel(expected: expected)
        } catch {
            isConnected = false; status = .error(error.localizedDescription); throw error
        }
    }
    public func acceptHostKeyAndConnect() async throws {
        guard let keys = pendingKeys, pendingIdentity == identity else { throw failure("待确认的主机已改变，请重新测试连接") }
        try validate()
        _ = try await checked("umask 077; cat >> \(quote(knownHosts))", input: Data(keys.utf8))
        pendingKeys = nil; pendingIdentity = nil; pendingHostKeyMessage = nil
        let expected = generation
        do { try await openTunnel(expected: expected) }
        catch { status = .error(error.localizedDescription); throw error }
    }
    /// 本机 127.0.0.1 上该端口能否绑定（被残留 ssh 转发占用时返回 false）。
    private static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }
    private static func findFreePortPair() -> (Int, Int)? {
        for base in stride(from: 28765, to: 29765, by: 2) where portIsFree(base) && portIsFree(base + 1) {
            return (base, base + 1)
        }
        return nil
    }
    /// 关闭本 App 以前留下的所有隧道（控制套接字与残留 ssh 进程）。
    /// 模式写成 [c]loud-ctl- 以免 pkill 匹配到执行本命令的 shell 自身。
    private func closeStrayTunnels() async {
        let command = "for s in /tmp/[c]loud-ctl-*; do if [ -S \"$s\" ]; then ssh -S \"$s\" -O exit placeholder >/dev/null 2>&1; fi; rm -f \"$s\"; done; pkill -f '[c]loud-ctl-' >/dev/null 2>&1; true"
        _ = try? await shell(command, timeout: 15)
    }
    /// 选定本次隧道使用的本机端口：优先 18765/18766，等待残留转发释放；仍被占用时若是可用的同一服务则复用，否则换空闲端口。
    /// 返回 true 表示直接复用了现有隧道。
    private func chooseLocalPorts() async throws -> Bool {
        await closeStrayTunnels()
        for _ in 0..<12 {
            if Self.portIsFree(18765) && Self.portIsFree(18766) {
                apiPort = 18765; desktopPort = 18766
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        apiPort = 18765; desktopPort = 18766
        if !Self.portIsFree(18765),
           let health = try? await requestRaw(method: "GET", path: "/health", body: nil),
           health["service"] as? String == "openminis-cloud-agent",
           (try? await requestRaw(method: "GET", path: "/v1/sessions", body: nil)) != nil {
            return true
        }
        guard let pair = Self.findFreePortPair() else {
            throw failure("本机端口 18765 / 18766 被占用，且找不到其他空闲端口。请从后台划掉 App 后重新打开再连接。")
        }
        apiPort = pair.0; desktopPort = pair.1
        return false
    }
    private func openTunnel(expected: UUID) async throws {
        if try await chooseLocalPorts() {
            guard generation == expected else { throw failure("连接已取消，请重新连接") }
            isConnected = true; status = .connected
            _ = try? await requestRaw(method: "PUT", path: "/v1/settings", body: ["timezone": TimeZone.current.identifier])
            return
        }
        let password = try await passwordFile()
        let control = "/tmp/cloud-ctl-\(UUID().uuidString)"
        controlPath = control
        do {
            let log = control + ".log"
            // 同时转发 API（远端 18765）与 noVNC 桌面（远端 18766）到本机选定端口
            let forwards = "-L 127.0.0.1:\(apiPort):127.0.0.1:18765 -L 127.0.0.1:\(desktopPort):127.0.0.1:18766"
            _ = try await checked("umask 077; sshpass -f \(quote(password)) ssh \(options()) -n -f -N -M -S \(quote(control)) -o ExitOnForwardFailure=yes \(forwards) \(destination) >\(quote(log)) 2>&1; rc=$?; if [ $rc -ne 0 ]; then cat \(quote(log)) >&2; fi; rm -f \(quote(log)); exit $rc", timeout: 50)
            await cleanup(password)
            guard generation == expected else { throw failure("连接已取消，请重新连接") }
            let health = try await requestRaw(method: "GET", path: "/health", body: nil)
            guard health["service"] as? String == "openminis-cloud-agent" else { throw failure("远端服务类型不匹配") }
            _ = try await requestRaw(method: "GET", path: "/v1/sessions", body: nil)
            guard generation == expected else { throw failure("连接已取消") }
            isConnected = true; status = .connected
            // 上报手机时区，云端记忆时间与手机日志一致；旧版服务没有该接口，忽略失败
            _ = try? await requestRaw(method: "PUT", path: "/v1/settings", body: ["timezone": TimeZone.current.identifier])
        } catch {
            await cleanup(password)
            _ = try? await shell("ssh -S \(quote(control)) -O exit \(destination) >/dev/null 2>&1", timeout: 10)
            controlPath = nil; isConnected = false
            let text = error.localizedDescription
            if text.contains("Address in use") || text.contains("cannot listen") || text.contains("Could not request local forwarding") {
                throw failure("\(text)\n本机隧道端口仍被上一次连接占用。已自动清理残留隧道，请等几秒再点「重连」；仍失败请从后台划掉 App 后重开。")
            }
            throw failure("\(text)\n若尚未安装，请点「安装 / 更新服务器 Agent 服务」或「安装 / 更新云电脑桌面环境 (Xvfb/noVNC)」；已安装的请核对 Token。")
        }
    }
    /// ssh -O check：本机的 SSH 主连接进程是否还在（不发网络请求）
    private func masterAlive() async -> Bool {
        guard let control = controlPath else { return false }
        return (try? await shell("ssh -S \(quote(control)) -O check placeholder >/dev/null 2>&1", timeout: 5))?.exitCode == 0
    }
    public func disconnect() {
        generation = UUID(); isConnected = false; status = .disconnected
        pendingKeys = nil; pendingIdentity = nil; pendingHostKeyMessage = nil; currentFingerprint = nil
        if let control = controlPath {
            let command = "ssh -S \(quote(control)) -O exit placeholder >/dev/null 2>&1; rm -f \(quote(control))"
            _ = ISHShellExecutor.executeCommand(command, lineCallback: nil, completion: nil)
        }
        controlPath = nil
    }
    public func installComputer() async throws {
        try await installAgent(withDesktop: true)
    }

    public func installAgent(withDesktop: Bool = true) async throws {
        try validate(); try await prepare(); try await verifyHost()
        guard let url = Bundle.main.url(forResource: "cloud-agent-bundle", withExtension: "tar.gz") else { throw failure("客户端未包含服务器安装包") }
        let data = try Data(contentsOf: url)
        let expectedIdentity = identity
        let password = try await passwordFile()
        installLog = ""
        do {
            try await runDetachedInstall(scriptName: withDesktop ? "install-desktop.sh" : "install.sh", bundle: data,
                                         password: password, maxSeconds: withDesktop ? 3600 : 1200)
            let read = "if [ \"$(id -u)\" = 0 ]; then cat /etc/openminis/token; else sudo -n cat /etc/openminis/token; fi"
            let result = try await shell("sshpass -f \(quote(password)) ssh \(options()) -n \(destination) \(quote(read))", timeout: 45)
            let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, token.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
                throw failure("服务安装完成，但无法取得认证 Token；请检查登录账号的 root 或免密 sudo 权限")
            }
            guard identity == expectedIdentity else { throw failure("安装期间服务器配置已改变，请恢复原配置后重连") }
            try saveSecret(token, key: "token")
            await cleanup(password)
            try await connect()
        } catch { await cleanup(password); throw error }
    }
    /// 上传安装包后在服务器上用 nohup + setsid 后台运行安装脚本，日志写入文件，手机端用短连接轮询。
    /// 国内网络下长时间 SSH 会话容易被中断（255），这样连接断开也不会打断安装，重连后继续看进度。
    private func runDetachedInstall(scriptName: String, bundle: Data, password: String, maxSeconds: TimeInterval) async throws {
        let dir = "/tmp/openminis-install-" + UUID().uuidString.prefix(8).lowercased()
        let sudo = "if [ \"$(id -u)\" = 0 ]; then S=''; else S='sudo -n'; fi"
        func ssh(_ remote: String, stdin: Bool = false) -> String {
            "sshpass -f \(quote(password)) ssh \(options())\(stdin ? "" : " -n") \(destination) \(quote(remote))"
        }
        let upload = "set -e; umask 022; rm -rf \(dir); mkdir -p \(dir); tar -xzf - -C \(dir); \(sudo); $S true || { echo '安装需要 root 或免密 sudo 权限' >&2; exit 3; }; echo uploaded"
        _ = try await checked(ssh(upload, stdin: true), input: bundle, timeout: 300)
        let start = "\(sudo); cd \(dir) && $S nohup setsid bash -c 'bash ./\(scriptName) > ./install.log 2>&1; echo $? > ./install.rc' >/dev/null 2>&1 </dev/null & sleep 1; echo started"
        _ = try await checked(ssh(start), timeout: 60)
        installLog = "安装已在服务器后台运行（日志 \(dir)/install.log）…"
        let poll = "\(sudo); if [ -f \(dir)/install.rc ]; then echo \"__RC__=$($S cat \(dir)/install.rc)\"; fi; $S tail -c 4000 \(dir)/install.log 2>/dev/null; true"
        let deadline = Date().addingTimeInterval(maxSeconds)
        var dropped = 0
        var exitCode: Int?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            guard let r = try? await shell(ssh(poll), timeout: 40), r.exitCode == 0 else {
                dropped += 1
                if dropped >= 20 {
                    throw failure("SSH 连接多次中断，安装可能仍在服务器上进行。可稍后重连查看；服务器日志：\(dir)/install.log\n最近输出：\n\(installLog.suffix(1500))")
                }
                continue
            }
            dropped = 0
            var text = r.output
            if text.hasPrefix("__RC__=") {
                let firstLine = text.prefix(while: { $0 != "\n" })
                exitCode = Int(firstLine.dropFirst("__RC__=".count).trimmingCharacters(in: .whitespaces)) ?? -1
                text = String(text.dropFirst(firstLine.count)).trimmingCharacters(in: .newlines)
            }
            if !text.isEmpty { installLog = text }
            if exitCode != nil { break }
        }
        guard let code = exitCode else {
            throw failure("安装超时（\(Int(maxSeconds / 60)) 分钟）仍未结束，可能卡在下载。服务器日志：\(dir)/install.log\n最近输出：\n\(installLog.suffix(1500))")
        }
        guard code == 0 else {
            let journal = (try? await shell(ssh("\(sudo); $S journalctl -u openminis-cloud-agent --no-pager -n 30 2>&1; true"), timeout: 40))?.output ?? ""
            throw failure("安装脚本失败（退出码 \(code)）。服务器日志：\(dir)/install.log\n最近输出：\n\(installLog.suffix(2500))" + (journal.isEmpty ? "" : "\n----- 服务日志 -----\n\(journal.suffix(1500))"))
        }
        _ = try? await shell(ssh("\(sudo); $S rm -rf \(dir)"), timeout: 30)
    }
    /// 「电脑」页 … 菜单：通过 SSH 重启云电脑桌面（显示器、VNC、noVNC 三个服务）
    /// 重启桌面服务：先请服务器自己重启（新版安装带 root path 单元），不行再经 SSH systemctl
    public func restartDesktop() async throws {
        if isConnected, let r = try? await requestRaw(method: "POST", path: "/v1/desktop/restart", body: [:]), r["restarted"] as? Bool == true {
            return
        }
        let password = try await passwordFile()
        let remote = "if [ \"$(id -u)\" = 0 ]; then S=''; else S='sudo -n'; fi; $S systemctl restart openminis-display openminis-vnc openminis-novnc && echo restarted"
        do {
            _ = try await checked("sshpass -f \(quote(password)) ssh \(options()) -n \(destination) \(quote(remote))", timeout: 60)
            await cleanup(password)
        } catch {
            await cleanup(password)
            throw error
        }
    }
    public func checkDesktopReachable() async -> Bool {
        guard isConnected else { return false }
        guard let url = URL(string: "http://127.0.0.1:\(desktopPort)/vnc.html") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        do {
            let (data, resp) = try await probeHTTP.data(for: req)
            if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                let html = String(data: data, encoding: .utf8) ?? ""
                if html.contains("noVNC") || html.contains("RFB") {
                    return true
                }
            }
        } catch {}
        return false
    }
    public func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        if !isConnected || Date().timeIntervalSince(lastOK) > 20 {
            guard isConnected || canAutoConnect else { throw failure("云端连接已断开，请返回设置重新连接；VPS 上已接受的任务仍会继续") }
            try await ensureConnected()
        }
        do {
            return try await requestRaw(method: method, path: path, body: body)
        } catch let error as URLError where Self.tunnelDropped(error) && canAutoConnect {
            // SSH 隧道断了（切网络、后台被挂起）：自动重连再重试，用户不用回设置页
            if error.code == .timedOut && Self.isLongPoll(path) { throw error }   // 长轮询超时很正常，不能因此拆隧道
            if error.code == .timedOut, await probeAlive() { throw error }   // 隧道是好的，只是这次请求慢
            try await reconnect()
            // 请求肯定没发出去（连不上本机端口）或是只读请求时才自动重发，避免重复发送消息
            guard method == "GET" || error.code == .cannotConnectToHost else { throw error }
            return try await requestRaw(method: method, path: path, body: body)
        }
    }

    static func tunnelDropped(_ e: URLError) -> Bool {
        [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut, .notConnectedToInternet].contains(e.code)
    }
    /// 云电脑画面推流：WebSocket 走同一条 SSH 隧道（ws://127.0.0.1:<端口>），服务器画面变了才推一帧 JPEG
    public func desktopStream(botId: String, fps: Int = 3) -> URLSessionWebSocketTask? {
        guard isConnected, botId.isEmpty || botId.range(of: #"^[a-z0-9][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil,
              let token = getToken(), !token.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "ws"
        c.host = "127.0.0.1"
        c.port = apiPort
        c.path = "/v1/desktop/stream"
        c.queryItems = [URLQueryItem(name: "fps", value: String(min(5, max(1, fps))))] + (botId.isEmpty ? [] : [URLQueryItem(name: "bot_id", value: botId)])
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let task = longHTTP.webSocketTask(with: req)
        task.maximumMessageSize = 4 * 1024 * 1024
        return task
    }

    /// 下载会话工作区里的附件（资料库预览、分享）；只允许 /v1/sessions/<id>/attachments/<文件名>
    public func downloadAttachment(path: String) async throws -> Data {
        guard isConnected else { throw failure("云端连接已断开") }
        guard path.range(of: #"^/v1/sessions/[A-Za-z0-9_-]{1,64}/attachments/[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              !path.contains(".."), let url = URL(string: "http://127.0.0.1:\(apiPort)" + path) else { throw failure("附件路径无效") }
        guard let token = getToken(), !token.isEmpty else { throw failure("缺少服务 Token") }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw failure("附件下载失败") }
        return data
    }

    /// 下载交付文件（支持 Range 续传、写入缓存）。只允许 /v1/sessions/<id>/deliveries/dl_<16 hex>/(file|thumb)
    public func downloadDeliverable(path: String, id: String, name: String, expectedBytes: Int,
                                    onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard isConnected else { throw failure("云端连接已断开") }
        let ok = path.range(of: #"^/v1/sessions/[A-Za-z0-9_-]{1,64}/deliveries/dl_[a-f0-9]{16}/(file|thumb)$"#, options: .regularExpression) != nil
        guard ok, !path.contains(".."), let url = URL(string: "http://127.0.0.1:\(apiPort)" + path) else { throw failure("交付路径无效") }
        if let cached = CloudFileCache.cached(id: id, name: name, bytes: expectedBytes) { return cached }
        guard let token = getToken(), !token.isEmpty else { throw failure("缺少服务 Token") }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let existing = CloudFileCache.partialBytes(id: id, name: name)
        if let h = CloudFileCache.rangeHeader(existingBytes: existing) {
            req.setValue(h.1, forHTTPHeaderField: h.0)
        }
        let (asyncBytes, response) = try await http.bytes(for: req)
        guard let httpResp = response as? HTTPURLResponse, (200...206).contains(httpResp.statusCode) else { throw failure("交付文件下载失败") }
        let part = CloudFileCache.partURL(id: id, name: name)
        if httpResp.statusCode != 206 {
            CloudFileCache.removePartial(id: id, name: name)
        }
        var got = httpResp.statusCode == 206 ? existing : 0
        let total = expectedBytes > 0 ? expectedBytes : (Int(httpResp.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0) + got
        var buffer = Data()
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try CloudFileCache.append(buffer, to: part)
                got += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { onProgress(min(1, Double(got) / Double(total))) }
            }
        }
        if !buffer.isEmpty {
            try CloudFileCache.append(buffer, to: part)
            got += buffer.count
        }
        if total > 0 { onProgress(1) }
        return try CloudFileCache.finalize(id: id, name: name)
    }

    private func requestRaw(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let components = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(components[0])
        let queryAllowed = components.count == 1 || CloudPathPolicy.queryAllowed(route: route, query: String(components[1]))
        guard (route == "/health" || route.hasPrefix("/v1/")), queryAllowed, !path.contains(".."), !path.contains("#"), !path.contains("\\"), !path.contains("//"), let url = URL(string: "http://127.0.0.1:\(apiPort)" + path), url.host == "127.0.0.1", url.port == apiPort else {
            throw failure("云端 API 路径无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if path != "/health" {
            guard let token = getToken(), !token.isEmpty else { throw failure("缺少服务 Token，请先安装云端 Agent 或填入已有 Token") }
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body = body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await (Self.isLongPoll(path) ? longHTTP : http).data(for: req)
        guard let response = response as? HTTPURLResponse else { throw failure("云端响应无效") }
        guard (200...299).contains(response.statusCode) else {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = parsed?["error"] as? String ?? "请检查服务和连接状态"
            // 旧版服务没有新接口：PUT/DELETE 由 http.server 返回 501，未知 GET/POST 路由返回 404 "Not found"。
            if response.statusCode == 501 || (response.statusCode == 404 && reason == "Not found") {
                throw failure("云电脑上的服务版本过旧，请点「安装 / 更新服务器 Agent 服务」后重试")
            }
            throw failure("云端 HTTP \(response.statusCode)：\(reason)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("云端没有返回 JSON 对象") }
        lastOK = Date()
        return object
    }
}

private final class CloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - 连接诊断：逐段检查，每一步给出中文结论；日志不含密码 / Token

public struct CloudDiagStep: Identifiable, Equatable {
    public enum Result: Equatable { case pass, fail, skip }
    public let id: String
    public let title: String
    public let result: Result
    public let detail: String
}

extension CloudConnection {
    public func runDiagnostics(networkAvailable: Bool) async -> [CloudDiagStep] {
        var steps: [CloudDiagStep] = []
        func add(_ id: String, _ title: String, _ r: CloudDiagStep.Result, _ detail: String) {
            steps.append(CloudDiagStep(id: id, title: title, result: r, detail: CloudLogRedactor.redact(detail)))
        }
        add("network", "手机网络", networkAvailable ? .pass : .fail, networkAvailable ? "网络可用" : "手机当前没有网络")
        let configured = !host.isEmpty && !(getPassword() ?? "").isEmpty
        add("config", "连接信息", configured ? .pass : .fail,
            configured ? "\(username)@\(host):\(sshPort)" : "还没有填写服务器地址或 SSH 密码")
        guard configured, networkAvailable else { return steps }

        // SSH 端口是否可达
        let tcp = await Self.tcpReachable(host: host, port: sshPort, timeout: 6)
        add("ssh_port", "SSH 端口 \(sshPort)", tcp == nil ? .pass : .fail,
            tcp == nil ? "服务器端口可以连通" : "连不上：\(tcp!)。请检查服务器是否开机、IP 是否变化、防火墙 / 安全组是否放行 \(sshPort)")
        guard tcp == nil else { return steps }

        // SSH 登录 + 服务器上的服务状态（一次 SSH 完成）
        var remoteOK = false
        do {
            try validate(); try await prepare()
            let password = try await passwordFile()
            defer { Task { await self.cleanup(password) } }
            let remote = "echo __LOGIN_OK__; for u in openminis-cloud-agent openminis-display openminis-vnc openminis-novnc; do echo \"$u=$(systemctl is-active $u 2>/dev/null)\"; done; "
                + "python3 -c \"import urllib.request,json;print('__API__=' + json.load(urllib.request.urlopen('http://127.0.0.1:18765/health', timeout=3)).get('agent_version', 'old'))\" 2>/dev/null || echo __API__=down"
            let r = try await shell("sshpass -f \(quote(password)) ssh \(options()) -n \(destination) \(quote(remote))", timeout: 40)
            let out = r.output + "\n" + r.errorOutput
            if out.contains("__LOGIN_OK__") {
                remoteOK = true
                add("ssh_auth", "SSH 登录", .pass, "用户名和密码正确，主机指纹已确认")
                var units: [String: String] = [:]
                for line in out.split(separator: "\n") where line.contains("=") && line.hasPrefix("openminis-") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    units[parts[0]] = parts.count > 1 ? parts[1] : ""
                }
                let agent = units["openminis-cloud-agent"] ?? ""
                let api = out.components(separatedBy: "__API__=").last?.split(separator: "\n").first.map(String.init) ?? "down"
                add("agent", "服务器 Agent", agent == "active" && api != "down" ? .pass : .fail,
                    agent == "active" && api != "down" ? "运行中，版本 \(api)" : "服务状态 \(agent.isEmpty ? "未安装" : agent)，本机 API \(api == "down" ? "无应答" : api)。请点「安装 / 更新服务器」")
                let desk = ["openminis-display", "openminis-vnc", "openminis-novnc"].map { "\($0.replacingOccurrences(of: "openminis-", with: ""))=\(units[$0].map { $0.isEmpty ? "未安装" : $0 } ?? "未安装")" }
                let deskOK = ["openminis-display", "openminis-vnc", "openminis-novnc"].allSatisfy { units[$0] == "active" }
                add("desktop_services", "桌面服务", deskOK ? .pass : .fail, desk.joined(separator: "  ") + (deskOK ? "" : "。可点「重启桌面」或「安装 / 更新桌面环境」"))
            } else {
                let cause = CloudLinkCause.classify(out)
                add("ssh_auth", "SSH 登录", .fail, cause.message + "：" + String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
            }
        } catch {
            add("ssh_auth", "SSH 登录", .fail, CloudLinkCause.classify(error.localizedDescription).message + "：" + error.localizedDescription)
        }
        guard remoteOK else { return steps }

        // 本机隧道与 API
        if !isConnected { try? await ensureConnected() }
        let apiAlive = await probeAlive(timeout: 3)
        add("tunnel_api", "隧道 · API 端口 \(apiPort)", apiAlive ? .pass : .fail, apiAlive ? "本机端口可以访问服务器 API" : "隧道没有建立或已断开（\(status)）")
        let deskAlive = await checkDesktopReachable()
        add("tunnel_desktop", "隧道 · 桌面端口 \(desktopPort)", deskAlive ? .pass : .fail, deskAlive ? "noVNC 页面可以打开" : "桌面网页打不开：桌面服务未运行或未安装")
        if apiAlive {
            do {
                _ = try await requestRaw(method: "GET", path: "/v1/sessions", body: nil)
                add("token", "服务 Token", .pass, "Token 有效")
            } catch {
                add("token", "服务 Token", .fail, error.localizedDescription.contains("401") ? "Token 不对：请在云电脑设置里重新填写，或重新安装服务器后自动获取" : error.localizedDescription)
            }
            if let d = lastHealth["desktop"] as? [String: Any] {
                let ok = d["ok"] as? Bool ?? false
                add("desktop", "云电脑桌面", ok ? .pass : .fail, d["message"] as? String ?? "")
            }
        }
        return steps
    }

    static func tcpReachable(host: String, port: Int, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
                    cont.resume(returning: "域名解析失败")
                    return
                }
                defer { freeaddrinfo(res) }
                let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
                guard fd >= 0 else { cont.resume(returning: "无法创建网络连接"); return }
                defer { close(fd) }
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
                if rc == 0 { cont.resume(returning: nil); return }
                guard errno == EINPROGRESS else { cont.resume(returning: String(cString: strerror(errno))); return }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let n = poll(&pfd, 1, Int32(timeout * 1000))
                if n <= 0 { cont.resume(returning: "连接超时"); return }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                cont.resume(returning: err == 0 ? nil : String(cString: strerror(err)))
            }
        }
    }
}
