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
        return URLSession(configuration: c, delegate: redirectDelegate, delegateQueue: nil)
    }()
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
    public func getToken() -> String? { secret("token") }

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
            let message = String((r.errorOutput.isEmpty ? r.output : r.errorOutput).suffix(2000))
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
        "-p \(sshPort) -o ConnectTimeout=15 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=\(quote(knownHosts)) -o GlobalKnownHostsFile=/dev/null -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=password,keyboard-interactive -o LogLevel=ERROR"
    }
    private var destination: String { quote(username + "@" + host) }
    private func passwordFile() async throws -> String {
        guard let password = getPassword(), !password.isEmpty else { throw failure("请先输入并保存 SSH 密码") }
        let file = "/tmp/.cloud-password-\(UUID().uuidString)"
        _ = try await checked("umask 077; cat > \(quote(file)); chmod 600 \(quote(file))", input: Data(password.utf8))
        return file
    }
    private func cleanup(_ path: String) async { _ = try? await shell("rm -f \(quote(path))", timeout: 10) }
    public func connect() async throws {
        disconnect()
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
    private func openTunnel(expected: UUID) async throws {
        let password = try await passwordFile()
        let control = "/tmp/cloud-ctl-\(UUID().uuidString)"
        controlPath = control
        do {
            let log = control + ".log"
            // 同时转发 API (18765) 与无VNC桌面 (18766)
            _ = try await checked("umask 077; sshpass -f \(quote(password)) ssh \(options()) -n -f -N -M -S \(quote(control)) -o ExitOnForwardFailure=yes -L 127.0.0.1:18765:127.0.0.1:18765 -L 127.0.0.1:18766:127.0.0.1:18766 \(destination) >\(quote(log)) 2>&1; rc=$?; if [ $rc -ne 0 ]; then cat \(quote(log)) >&2; fi; rm -f \(quote(log)); exit $rc", timeout: 50)
            await cleanup(password)
            guard generation == expected else { throw failure("连接已取消，请重新连接") }
            let health = try await requestRaw(method: "GET", path: "/health", body: nil)
            guard health["service"] as? String == "openminis-cloud-agent" else { throw failure("远端服务类型不匹配") }
            _ = try await requestRaw(method: "GET", path: "/v1/sessions", body: nil)
            guard generation == expected else { throw failure("连接已取消") }
            isConnected = true; status = .connected
        } catch {
            await cleanup(password)
            _ = try? await shell("ssh -S \(quote(control)) -O exit \(destination) >/dev/null 2>&1", timeout: 10)
            controlPath = nil; isConnected = false
            throw failure("\(error.localizedDescription)\n若尚未安装云电脑桌面，请点击“安装 / 更新云电脑桌面与 Agent 服务”；已有服务请核对 Token。")
        }
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
        do {
            let scriptName = withDesktop ? "install-desktop.sh" : "install.sh"
            let remote = "set -e; d=$(mktemp -d /tmp/openminis-cloud.XXXXXXXX); trap 'rm -rf \"$d\"' EXIT; tar -xzf - -C \"$d\"; cd \"$d\"; if [ \"$(id -u)\" = 0 ]; then bash \(scriptName); else sudo -n bash \(scriptName); fi"
            _ = try await checked("sshpass -f \(quote(password)) ssh \(options()) \(destination) \(quote(remote))", input: data, timeout: 720)
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
    public func checkDesktopReachable() async -> Bool {
        guard isConnected else { return false }
        guard let url = URL(string: "http://127.0.0.1:18766/vnc.html") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        do {
            let (data, resp) = try await http.data(for: req)
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
        guard isConnected else { throw failure("云端连接已断开，请返回设置重新连接；VPS 上已接受的任务仍会继续") }
        return try await requestRaw(method: method, path: path, body: body)
    }
    private func requestRaw(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let components = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(components[0])
        let queryAllowed = components.count == 1 || (route.hasPrefix("/v1/tasks/") && route.hasSuffix("/events") && String(components[1]).range(of: #"^after=[0-9]{1,18}$"#, options: .regularExpression) != nil)
        guard (route == "/health" || route.hasPrefix("/v1/")), queryAllowed, !path.contains(".."), !path.contains("#"), !path.contains("\\"), !path.contains("//"), let url = URL(string: "http://127.0.0.1:18765" + path), url.host == "127.0.0.1", url.port == 18765 else {
            throw failure("云端 API 路径无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if path != "/health" {
            guard let token = getToken(), !token.isEmpty else { throw failure("缺少服务 Token，请先安装云端 Agent 或填入已有 Token") }
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body = body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await http.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw failure("云端响应无效") }
        guard (200...299).contains(response.statusCode) else {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = parsed?["error"] as? String ?? "请检查服务和连接状态"
            throw failure("云端 HTTP \(response.statusCode)：\(reason)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("云端没有返回 JSON 对象") }
        return object
    }
}

private final class CloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
