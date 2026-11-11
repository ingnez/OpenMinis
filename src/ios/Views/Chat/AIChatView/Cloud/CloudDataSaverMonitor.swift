import Foundation
import Network

/// 监听 Wi-Fi / 蜂窝，把结果写到 CloudDataSaver.expensiveNetwork。逻辑文件本身保持只依赖 Foundation。
enum CloudDataSaverMonitor {
    private static var monitor: NWPathMonitor?
    private static let lock = NSLock()

    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.isConstrained
            DispatchQueue.main.async { CloudDataSaver.expensiveNetwork = expensive }
        }
        m.start(queue: DispatchQueue(label: "openminis.datasaver.path"))
        monitor = m
    }
}
