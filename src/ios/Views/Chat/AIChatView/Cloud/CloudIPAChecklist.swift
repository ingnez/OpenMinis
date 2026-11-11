import Foundation

/// 每个 IPA 附带的测试清单：哪些流程已在本机 / Linux 单测和 XCUITest 里覆盖，哪些还必须用真机看一眼。
enum CloudIPAChecklist {
    struct Item: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let note: String
    }

    static let tested: [Item] = [
        Item(name: "零等待首屏", note: "Bot / 对话缓存与同步条，Ideas12UITests.testIdea1"),
        Item(name: "一句话交班", note: "口语解析成定时任务，CloudShiftSpeechTests + testIdea2"),
        Item(name: "任务进度时间轴", note: "开始时间、步骤、单步重试，CloudTaskTimelineTests + testIdea3"),
        Item(name: "离线先写", note: "发件箱与补发时间，CloudOutboxTests + testIdea4"),
        Item(name: "「刚才那个」引用", note: "定位上一张图或文件，CloudLastRefTests + testIdea5"),
        Item(name: "单手模式", note: "输入/发送/语音靠右，CloudOneHandModeTests + testIdea6"),
        Item(name: "值班模式", note: "仅震动、不外推、结论+单位，CloudDutyModeTests + testIdea7"),
        Item(name: "脱敏护栏", note: "姓名/床号/住院号本机打码，CloudPrivacyScanTests + testIdea8"),
        Item(name: "口述转结构化", note: "交班单与病例摘要模板，CloudOralStructTests + testIdea9"),
        Item(name: "云电脑触控板与输入法", note: "中文走 UTF-8 上屏、不走 Latin-1 键码，CloudDesktopInputTests + testIdea10"),
        Item(name: "云电脑断点续跑", note: "中断后保存光标与步骤，CloudDesktopCheckpointTests + testIdea11"),
        Item(name: "IPA 测试清单", note: "已测 / 需真机两节写入 IPA，CloudIPAChecklistTests + testIdea12"),
    ]

    static let needsDevice: [Item] = [
        Item(name: "系统通知声音与值班震动", note: "模拟器听不出铃声音量和真实震动"),
        Item(name: "云电脑中文输入法上屏手感", note: "拼音组字、候选栏、真机键盘与粘贴权限"),
        Item(name: "触控板光标加速与捏合", note: "真机多指手势和延迟"),
        Item(name: "Bark / ntfy 外推", note: "App 被杀掉后的兜底推送"),
        Item(name: "Apple Watch 与控制中心", note: "需成对真机"),
        Item(name: "Face ID 与保管库揭示", note: "需具备生物识别的真机"),
        Item(name: "后台刷新与 120Hz", note: "后台任务和 ProMotion 只能在真机上看"),
    ]

    static func markdown(commit: String? = nil, builtAt: String? = nil) -> String {
        var lines = ["# OpenMinis 测试清单", ""]
        if let builtAt { lines.append("- 生成时间：\(builtAt)") }
        if let commit, !commit.isEmpty { lines.append("- 源码提交：\(commit)") }
        lines.append("")
        lines.append("## 已测流程")
        lines.append("")
        for it in tested { lines.append("- \(it.name)：\(it.note)") }
        lines.append("")
        lines.append("## 需真机验证")
        lines.append("")
        for it in needsDevice { lines.append("- \(it.name)：\(it.note)") }
        lines.append("")
        lines.append("本清单随 IPA 一起分发，不包含密钥或个人信息。")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
