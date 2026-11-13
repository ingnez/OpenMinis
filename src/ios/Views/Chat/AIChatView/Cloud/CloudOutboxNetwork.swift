import Foundation
#if canImport(Network)
import Network

/// 网络从断到通时通知对话页按原 nonce 冲发件箱。iOS 16+ Network 框架。
enum CloudOutboxNetwork {
    private static var monitor: NWPathMonitor?
    private static var wasOffline = false

    static func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let isOffline = path.status != .satisfied
            if !isOffline, wasOffline {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: CloudE2EOffline.flushNotification, object: nil)
                }
            }
            wasOffline = isOffline
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        monitor = m
    }
}
#else
enum CloudOutboxNetwork {
    static func start() {}
}
#endif
