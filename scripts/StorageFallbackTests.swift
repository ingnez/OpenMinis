import Foundation

@main
struct StorageFallbackTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let shared = root.appendingPathComponent("Group", isDirectory: true)
        let local = SharedContainerStore.resolveStorageContainer(sharedContainer: nil, applicationSupport: support)
        precondition(local == support.appendingPathComponent("MinisLocalContainer", isDirectory: true))
        precondition(SharedContainerStore.resolveStorageContainer(sharedContainer: shared, applicationSupport: support) == shared)
        // 验证无共享权限时魂设、记忆与配置使用的路径可读写且跨调用稳定。
        for relative in ["MinisFileProvider/shared/soul.json", "MinisFileProvider/memory/test.md", "MinisConfig/config.json"] {
            let file = local.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("本地数据保留验证".utf8)
            try data.write(to: file)
            let again = SharedContainerStore.resolveStorageContainer(sharedContainer: nil, applicationSupport: support)
            let loaded = try Data(contentsOf: again.appendingPathComponent(relative))
            precondition(loaded == data)
        }
        precondition(!fm.fileExists(atPath: shared.path))
        let suite = "MinisRecoveryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("保留", forKey: "test.localData")
        defaults.set(true, forKey: "cloudSync.syncSessions")
        defaults.set("existing-cloud-token", forKey: "cloudSync.testToken")
        for v1 in [false, true] {
            for v2 in [false, true] {
                defaults.set(v1, forKey: "cloudSync.enabled")
                defaults.set(v2, forKey: "cloudSync.v2.enabled")
                SharedContainerStore.recoverCloudSyncPreferences(defaults)
                precondition(!defaults.bool(forKey: "cloudSync.enabled"))
                precondition(!defaults.bool(forKey: "cloudSync.v2.enabled"))
                precondition(defaults.string(forKey: "test.localData") == "保留")
                precondition(defaults.bool(forKey: "cloudSync.syncSessions"))
                precondition(defaults.string(forKey: "cloudSync.testToken") == "existing-cloud-token")
                SharedContainerStore.recoverCloudSyncPreferences(defaults)
            }
        }
        precondition(!SharedContainerStore.cloudSyncAvailable)
        print("通过：同步已启用的四种组合均恢复关闭、重复执行幂等、其他配置及数据保留")
        print("通过：共享目录优先、权限缺失回退、目录稳定、魂设及配置读写、未创建伪共享目录")
    }
}
