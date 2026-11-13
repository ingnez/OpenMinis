import Foundation

/// 端到端测试用：启动参数 OPENMINIS_E2E_OFFLINE=1 时，请求一律当作断网，消息进发件箱。
/// 点「模拟网络已恢复」后清掉这个标志，按原 nonce 自动重发。正式使用不会打开。
enum CloudE2EOffline {
    private static var online = false

    static var isTest: Bool {
        ProcessInfo.processInfo.environment["OPENMINIS_E2E_TOKEN"] != nil
            || ProcessInfo.processInfo.environment["OPENMINIS_E2E_OFFLINE"] == "1"
    }

    static var forced: Bool {
        ProcessInfo.processInfo.environment["OPENMINIS_E2E_OFFLINE"] == "1"
            && !online
    }

    static func goOnline() {
        online = true
        NotificationCenter.default.post(name: flushNotification, object: nil)
    }

    static let flushNotification = Notification.Name("OpenMinisOutboxShouldFlush")
}
