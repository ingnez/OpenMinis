# OpenMinis Cloud Agent Connection Interface (`connection-interface.md`)

本文档定义了 iOS 客户端 `CloudConnection` 的公开 Swift 类型与方法约定，供 UI 团队直接进行视图绑定与交互。

## 1. 核心单例与属性定义 (`CloudConnection`)

```swift
import Foundation
import Combine

public enum CloudConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
public class CloudConnection: ObservableObject {
    public static let shared = CloudConnection()

    // MARK: - Published State
    @Published public private(set) var status: CloudConnectionStatus = .disconnected
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var currentFingerprint: String? = nil
    @Published public private(set) var pendingHostKeyMessage: String? = nil

    // 配置属性
    @Published public var name: String = ""
    @Published public var host: String = ""
    @Published public var sshPort: Int = 22
    @Published public var username: String = "root"

    private init() {}

    // MARK: - Configuration & Security (Keychain)
    /// 保存密码与 Token 到 iOS Keychain (ThisDeviceOnly)。普通配置可存 UserDefaults。
    public func saveCredentials(password: String, token: String) throws {
        // ...
    }

    /// 从 Keychain 读取密码
    public func getPassword() -> String? {
        // ...
    }

    /// 从 Keychain 读取 Token
    public func getToken() -> String? {
        // ...
    }

    // MARK: - Connection Lifecycle
    /// 建立 SSH 端口转发（127.0.0.1:18765 -> VPS:18765），处理主机指纹首次确认与严格校验
    public func connect() async throws {
        // 1. 检查 openssh-client 与 sshpass 是否存在于 iSH 环境，自动准备
        // 2. 检查已知主机指纹；首次连接展示指纹并要求明确确认，拒绝 StrictHostKeyChecking=no 漏洞
        // 3. 异步启动后台 ssh 隧道进程
        // 4. 验证 /health 接口与 Bearer Token 鉴权
    }

    /// 断开 SSH 隧道与清理连接状态
    public func disconnect() {
        // ...
    }

    // MARK: - Remote Agent Installation
    /// 在已授权连接的 VPS 上安装远端 Agent：读取打包在资源中的 cloud-agent-bundle.tar.gz，经 SSH 传输 stdin 到远端解包并运行 install.sh
    public func installAgent() async throws {
        // ...
    }

    // MARK: - HTTP API Client (URLSession over local tunnel)
    /// 通过本地隧道访问 Python 云Agent服务 (http://127.0.0.1:18765/v1/...)
    /// 自动在 Header 中携带 Bearer Token
    public func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        // ...
    }
}
```

## 2. 交互说明与安全合规
- **密码与凭据安全**: 密码与 Token 存储在 Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)。绝不打印到日志或工具输出。
- **SSH 密钥指纹**: 首次连接时通过 `ssh-keyscan` 获取目标主机指纹并在 UI 中展示 (`pendingHostKeyMessage`)，用户确认后方可写入 `known_hosts`。拒绝使用 `StrictHostKeyChecking=no`。
- **后台保持**: 利用 `ISHShellExecutor` 在 iSH 环境后台运行 ssh 隧道，支持重连机制。

## 3. iSH 网络层实现与 iOS 原生 URLSession 直连证据

### 3.1 结论
**可以直连。** 在 iSH 环境中通过 `ssh -L 127.0.0.1:18765:127.0.0.1:18765` 建立的 TCP 监听，iOS 原生 `URLSession`（基于 `http://127.0.0.1:18765`）可以直接发起 TCP 连接并通信。

### 3.2 源码与架构证据
1. **网络栈直通 (Passthrough)**：
   根据 `docs/specs/ios-sandbox-ish-summary.md` 第 1.2 节架构规格：
   - iSH 内核网络实现：`Networking: AF_INET/AF_INET6/AF_LOCAL, TCP/UDP/RAW sockets, DNS resolution, full host network stack passthrough`。
   - iSH 内核不运行虚拟网络交换机或软件 TAP/TUN 网桥；对 guest 内的 `AF_INET` / `AF_INET6` 套接字系统调用（`socket`、`bind`、`listen`、`connect`），iSH 直接桥接并调用 host Darwin/iOS 原生 BSD socket APIs。
2. **同一进程与 Loopback 共享**：
   - iSH 虚拟机是运行在 iOS 主进程（`MinisApp`）内部的一个嵌入式仿真内核（JIT 解释器运行在 background pthread）。
   - 当 guest 进程执行 `ssh -L 127.0.0.1:18765:...` 时，底层通过 host Darwin 系统的 `bind(127.0.0.1, 18765)` 和 `listen()` 绑定在 host 的 loopback 接口上。
   - 同一 App 进程内的原生 iOS Swift 代码使用 `URLSession.shared` 或自定义 `URLSession` 连接 `http://127.0.0.1:18765` 时，直接路由至 host loopback 上的对应监听端口，与原生 socket 完全共享网络命名空间。
3. **AF_UNIX 与 AF_INET 的实现对比**：
   - 如 `src/ios/iSH/ISHKernel.m` 注释中关于 `setUpUnixSocketPrefix` 所示（`[T-ios-ish-af-unix-sandbox GH#175]`）：iSH 并未实现完全隔离的 guest socket 协议栈，AF_UNIX 是直接重写路径到 iOS 沙盒目录绑定真实主机 Unix socket；
   - 而 TCP/IP（AF_INET/AF_INET6）更是直接复用 iOS 主机 TCP 协议栈，因此 127.0.0.1 的 TCP 监听对 iOS 原生网络库完全可见且可直连。
