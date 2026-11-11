import Foundation
#if canImport(Network)
import Network

/// 网络从断到通时通知对话页按原 nonce 冲发件箱。iOS 16+ Network 框架。
enum CloudOutboxNetwork {
    private static var monitor: NWPathMonitor?
    private static var ready = false

    static func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            if ok, ready {
                NotificationCenter.default.post(name: CloudE2EOffline.flushNotification, object: nil)
            }
            ready = true
            if !ok { ready = true } // 记住已经见过一次状态，下次变好再冲
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        monitor = m
    }
}
#endif
