import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudSecretMaskTests {
    static func main() {
        let fake = "sk-fake-phase64-not-a-real-key-xxxxxxxx"
        let masked = CloudSecretMask.maskPasted("请保存 " + fake + " 谢谢")
        check(masked.contains(CloudSecretMask.mask), "有遮罩：\(masked)")
        check(!masked.contains(fake), "假密钥不应保留：\(masked)")
        check(CloudSecretMask.didMask("x " + fake), "didMask")
        check(CloudSecretMask.maskPasted("没有密钥，只是一段话") == "没有密钥，只是一段话", "普通句子不动")
        check(!CloudSecretMask.didMask("sk-short"), "太短的假前缀不误伤")
        print("PASS：误贴假密钥会被遮罩，普通句子保持原样")
    }
}
