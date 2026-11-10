import Foundation
import WatchConnectivity

/// 把首页的 Bot 列表（谁在干活、在干什么、最后一句）推给配对的 Apple Watch。
/// 只在有配对手表且装了手表 App 时发送；内容和首页一致，上锁的 Bot 不带预览。
@MainActor
final class CloudWatchBridge: NSObject, WCSessionDelegate {
    static let shared = CloudWatchBridge()
    private var lastSent: [WatchBotRow] = []

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ bots: [CloudBot]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        let rows = bots.filter { !$0.hidden }.map { b -> WatchBotRow in
            let locked = CloudBotLock.shared.isLocked(b.id)
            return WatchBotRow(id: b.id, name: b.name, working: locked ? nil : b.activity?.subtitle,
                               preview: locked ? "已上锁" : b.lastPreview, at: b.lastAt)
        }
        guard rows != lastSent else { return }
        lastSent = rows
        try? s.updateApplicationContext(WatchBotRow.encode(rows))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
