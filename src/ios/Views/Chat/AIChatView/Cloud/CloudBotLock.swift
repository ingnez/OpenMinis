import LocalAuthentication
import SwiftUI
import UIKit

/// 给单个 Bot 加 Face ID 锁：打开对话前要验证；首页不显示它的最新消息；App 退到后台后重新上锁。
/// 只存在本机（哪些 Bot 上锁），不影响服务器上的数据。
@MainActor
final class CloudBotLock: ObservableObject {
    static let shared = CloudBotLock()
    nonisolated private static let key = "OpenMinisCloud_lockedBots"

    @Published private(set) var locked: Set<String>
    @Published private(set) var unlocked: Set<String> = []
    private var observer: NSObjectProtocol?

    private init() {
        locked = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.unlocked.removeAll() }
        }
    }

    func isLocked(_ botId: String) -> Bool { locked.contains(botId) }

    /// 给通知、实时活动这类不在主线程视图里的地方用：直接读本机记录
    nonisolated static func isLockedStored(_ botId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(botId)
    }

    /// 告诉云端哪些 Bot 上了锁，让 Bark 等推送也不带内容；失败下次刷新再同步
    func syncToServer() async {
        _ = try? await CloudQuiet.retry(3, {
            try await CloudConnection.shared.request(method: "PUT", path: "/v1/resources", body: ["private_bots": Array(locked).sorted()])
        })
    }
    func needsUnlock(_ botId: String) -> Bool { locked.contains(botId) && !unlocked.contains(botId) }

    func set(_ botId: String, locked on: Bool) async -> Bool {
        // 关掉锁也要先验证，避免别人拿到手机直接解除
        if on == isLocked(botId) { return true }
        guard await Self.authenticate(reason: on ? "给这个 Bot 加锁" : "解除这个 Bot 的锁") else { return false }
        if on { locked.insert(botId) } else { locked.remove(botId) }
        unlocked.insert(botId)
        UserDefaults.standard.set(Array(locked), forKey: Self.key)
        Task { await syncToServer() }
        return true
    }

    func unlock(_ botId: String) async {
        if await Self.authenticate(reason: "打开已上锁的 Bot") { unlocked.insert(botId) }
    }

    /// 生物识别失败时系统会自动退回到锁屏密码
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

struct CloudBotLockedView: View {
    let bot: CloudBot
    @ObservedObject private var lock = CloudBotLock.shared

    var body: some View {
        VStack(spacing: 16) {
            CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 64, eyeOpen: 0.12)
            Text("\(bot.name) 已上锁").font(.headline)
            Button {
                Task { await lock.unlock(bot.id) }
            } label: {
                Label("解锁", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await lock.unlock(bot.id) }
    }
}

struct CloudBotLockSection: View {
    let botId: String
    @ObservedObject private var lock = CloudBotLock.shared

    var body: some View {
        Section {
            Toggle("用 Face ID 锁定", isOn: Binding(get: { lock.isLocked(botId) }, set: { on in
                Task { _ = await lock.set(botId, locked: on) }
            }))
        } footer: {
            Text("打开这个 Bot 前要验证，首页不显示它的最新消息；App 退到后台后自动重新上锁。只在本机生效。")
        }
    }
}
