import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 锁屏 / 灵动岛审批用的语音口令：只存规范化文本的摘要，不存原文、不打日志。Linux 可单测规范化与比对。
enum CloudLockPassphrase {
    static let digestKey = "OpenMinisLockApprovalPassphraseDigest"
    static let enabledKey = "OpenMinisLockApprovalPassphraseOn"

    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
        let spaced = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return spaced
    }

    static func digest(_ raw: String, hash: ((String) -> String)? = nil) -> String? {
        let n = normalize(raw)
        guard n.count >= 4 else { return nil }
        if let hash { return hash(n) }
        return sha256Hex(n)
    }

    static func matches(spoken: String, storedDigest: String, hash: ((String) -> String)? = nil) -> Bool {
        guard !storedDigest.isEmpty, let got = digest(spoken, hash: hash) else { return false }
        return got == storedDigest
    }

    static func sha256Hex(_ s: String) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        // Linux 单测应传入 hash 闭包；这里只保证能编译，不用作生产口令。
        return "sha256-unavailable:" + s
        #endif
    }
}

/// 当前待审批（给锁屏预览 / 灵动岛预览 / 手表用）。不含命令原文里可能出现的敏感路径以外的测试假数据。
struct CloudLockApprovalSnapshot: Equatable, Codable {
    var approvalId: String
    var taskId: String
    var botId: String
    var botName: String
    var tool: String
    var summary: String
    var createdAt: Double

    static let key = "OpenMinisLockApprovalSnapshot"

    static func summary(tool: String, reason: String) -> String {
        let t = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = t.isEmpty ? "待审批" : "待审批：\(t)"
        if r.isEmpty { return String(head.prefix(80)) }
        return String((head + "（" + r + "）").prefix(80))
    }

    static func save(_ item: CloudLockApprovalSnapshot?, defaults: UserDefaults) {
        if let item, let data = try? JSONEncoder().encode(item) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func load(defaults: UserDefaults) -> CloudLockApprovalSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CloudLockApprovalSnapshot.self, from: data)
    }

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_LOCK_APPROVAL"] == "1" }

    static func e2eItem() -> CloudLockApprovalSnapshot {
        CloudLockApprovalSnapshot(approvalId: "ap-e2e", taskId: "task-e2e", botId: "e2ebot",
                                  botName: "E2E小助手", tool: "shell_execute",
                                  summary: "待审批：shell_execute（假数据）", createdAt: 1)
    }
}
