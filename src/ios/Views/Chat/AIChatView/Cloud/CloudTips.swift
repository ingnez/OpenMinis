import Foundation

/// 新手提示：用过一次对应功能（或点 ×）就永远不再出现。只依赖 Foundation，Linux 上单测
enum CloudTips {
    static let key = "OpenMinisTipsDone"

    static func shouldShow(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: key) ?? []).contains(id)
    }

    static func markUsed(_ id: String, defaults: UserDefaults = .standard) {
        var done = defaults.stringArray(forKey: key) ?? []
        guard !done.contains(id) else { return }
        done.append(id)
        defaults.set(done, forKey: key)
    }
}
