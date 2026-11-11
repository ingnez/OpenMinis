import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudLockPassphraseTests {
    static func main() {
        check(CloudLockPassphrase.normalize("  批准  测试口令  ") == "批准 测试口令", "空白折叠")
        check(CloudLockPassphrase.normalize("批准，测试口令！") == "批准 测试口令" ||
              CloudLockPassphrase.normalize("批准，测试口令！") == "批准测试口令", "去掉标点")
        let hash: (String) -> String = { "h:" + $0 }
        let digest = CloudLockPassphrase.digest("批准测试口令", hash: hash)
        check(digest == "h:批准测试口令", "摘要用规范化文本")
        check(CloudLockPassphrase.matches(spoken: "  批准测试口令  ", storedDigest: digest!, hash: hash), "口令相符")
        check(!CloudLockPassphrase.matches(spoken: "别的句子", storedDigest: digest!, hash: hash), "口令不符")
        check(CloudLockPassphrase.digest("abc", hash: hash) == nil, "太短不要")
        let snap = CloudLockApprovalSnapshot.e2eItem()
        check(snap.summary.contains("待审批"), "摘要")
        check(CloudLockApprovalSnapshot.summary(tool: "shell", reason: "假数据").contains("shell"), "摘要含工具")
        let d = UserDefaults(suiteName: "OpenMinisLockApprovalTest")!
        d.removePersistentDomain(forName: "OpenMinisLockApprovalTest")
        CloudLockApprovalSnapshot.save(snap, defaults: d)
        check(CloudLockApprovalSnapshot.load(defaults: d) == snap, "快照往返")
        CloudLockApprovalSnapshot.save(nil, defaults: d)
        check(CloudLockApprovalSnapshot.load(defaults: d) == nil, "清除")
        print("PASS：锁屏审批口令与快照")
    }
}
