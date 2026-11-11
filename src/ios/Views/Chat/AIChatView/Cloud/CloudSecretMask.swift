import Foundation

/// 用户把疑似密钥贴进对话时，在发出去之前换成固定遮罩。只认常见公开前缀的格式；测试与界面都只用假值。
/// 纯 Foundation，Linux 上 scripts/CloudSecretMaskTests.swift 跑。
enum CloudSecretMask {
    static let mask = "[疑似密钥已隐藏]"

    /// 常见厂商文档里的密钥前缀。不把匹配到的原文写入日志。
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(sk-ant-[A-Za-z0-9_\-]{20,}|sk-[A-Za-z0-9_\-]{20,}|xai-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_\-]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35})\b"#
    )

    static func maskPasted(_ text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: mask))
    }

    static func didMask(_ text: String) -> Bool { maskPasted(text) != text }
}
