import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudIPAChecklistTests {
    static func main() {
        check(CloudIPAChecklist.tested.count >= 12, "已测流程覆盖 12 项")
        let names = CloudIPAChecklist.tested.map(\.name)
        for n in ["零等待首屏", "一句话交班", "离线先写", "刚才那个", "单手模式", "值班模式", "脱敏护栏", "口述转结构化", "触控板", "断点续跑", "测试清单"] {
            check(names.contains(where: { $0.contains(n) }), "已测含 \(n)")
        }
        check(!CloudIPAChecklist.needsDevice.isEmpty, "需真机验证非空")
        let md = CloudIPAChecklist.markdown(commit: "abc123", builtAt: "2026-11-12 02:00")
        check(md.contains("## 已测流程") && md.contains("## 需真机验证"), "两节标题")
        check(md.contains("abc123") && md.contains("2026-11-12"), "写明提交与时间")
        check(!md.contains("sk-") && !md.contains("Bearer "), "清单不含密钥")
        print("PASS：IPA 测试清单（已测流程 / 需真机验证）")
    }
}
