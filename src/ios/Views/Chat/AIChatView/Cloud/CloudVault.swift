import Foundation
import LocalAuthentication
import UIKit

// CloudVaultItem 和列表分组、计数、遮挡等纯逻辑在 CloudVaultModel.swift（可在 Linux 上测试）

/// 一条使用记录：哪个 Bot 在什么时候用了哪一项、填到了哪里
struct CloudVaultUse: Identifiable {
    let id: Int
    let itemId: String
    let itemTitle: String
    let actor: String
    let action: String
    let target: String?
    let ok: Bool
    let detail: String?
    let at: Date

    init?(_ d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue, let item = d["item_id"] as? String else { return nil }
        self.id = id
        itemId = item
        itemTitle = d["item_title"] as? String ?? ""
        actor = d["actor"] as? String ?? ""
        action = d["action"] as? String ?? ""
        target = d["target"] as? String
        ok = d["ok"] as? Bool ?? false
        detail = d["detail"] as? String
        at = Date(timeIntervalSince1970: (d["at"] as? NSNumber)?.doubleValue ?? 0)
    }

    var actionLabel: String {
        switch action {
        case "vault_fill": return "填写"
        case "vault_totp": return "填验证码"
        case "app_reveal": return "在 App 查看"
        default: return action
        }
    }
}

@MainActor
enum CloudVaultService {
    static func list() async throws -> (items: [CloudVaultItem], available: Bool) {
        let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/vault", body: nil)
        let items = (resp["items"] as? [[String: Any]] ?? []).compactMap(CloudVaultItem.init)
        return (items, resp["available"] as? Bool ?? true)
    }

    static func save(id: String?, body: [String: Any]) async throws -> CloudVaultItem? {
        let conn = try await CloudBotService.connected()
        let resp = try await conn.request(method: id == nil ? "POST" : "PUT", path: id.map { "/v1/vault/\($0)" } ?? "/v1/vault", body: body)
        return (resp["item"] as? [String: Any]).flatMap(CloudVaultItem.init)
    }

    static func delete(_ id: String) async throws {
        _ = try await CloudBotService.connected().request(method: "DELETE", path: "/v1/vault/\(id)", body: nil)
    }

    /// 机密原值：只在 Face ID 通过后调用，结果只留在内存里
    static func reveal(_ id: String) async throws -> [String: Any] {
        let resp = try await CloudBotService.connected().request(method: "POST", path: "/v1/vault/\(id)/reveal", body: [:])
        return resp["secret"] as? [String: Any] ?? [:]
    }

    static func uses(itemId: String? = nil) async throws -> [CloudVaultUse] {
        let path = itemId.map { "/v1/vault/uses?item_id=\($0)" } ?? "/v1/vault/uses"
        let resp = try await CloudBotService.connected().request(method: "GET", path: path, body: nil)
        return (resp["items"] as? [[String: Any]] ?? []).compactMap(CloudVaultUse.init)
    }

    static func importCSV(_ text: String) async throws -> (imported: Int, skipped: Int) {
        let resp = try await CloudBotService.connected().request(method: "POST", path: "/v1/vault/import", body: ["csv": text])
        return ((resp["imported"] as? NSNumber)?.intValue ?? 0, (resp["skipped"] as? NSNumber)?.intValue ?? 0)
    }
}

/// Face ID / 密码验证。设备没有设密码时直接放行会不安全，所以返回 false 并提示。
enum CloudVaultAuth {
    static func unlock(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in cont.resume(returning: ok) }
        }
    }

    /// 复制机密：只留在本机剪贴板（不同步到其他设备），60 秒后自动清除
    static func copy(_ text: String, secret: Bool) {
        if secret {
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                                          options: [.localOnly: true, .expirationDate: CloudVaultRevealPolicy.clipboardExpiry(from: Date())])
        } else {
            UIPasteboard.general.string = text
        }
    }
}

import CryptoKit

/// 本机算当前两步验证码（RFC 6238，30 秒、6 位），只在 Face ID 后显示
enum CloudVaultTOTP {
    static func code(_ raw: String, at date: Date = Date()) -> (code: String, secondsLeft: Int)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("otpauth://"),
           let v = URLComponents(string: s)?.queryItems?.first(where: { $0.name == "secret" })?.value {
            s = v
        }
        guard let key = base32(s.uppercased().filter { !" -=".contains($0) }), !key.isEmpty else { return nil }
        let t = Int(date.timeIntervalSince1970)
        var counter = UInt64(t / 30).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
        let off = Int(mac[mac.count - 1] & 0x0f)
        let b0 = UInt32(mac[off] & 0x7f) << 24
        let b1 = UInt32(mac[off + 1]) << 16
        let b2 = UInt32(mac[off + 2]) << 8
        let num = (b0 | b1 | b2 | UInt32(mac[off + 3])) % 1_000_000
        return (String(format: "%06u", num), 30 - t % 30)
    }

    static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits: UInt32 = 0
        var count = 0
        var out = Data()
        for ch in s {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            bits = (bits << 5) | UInt32(v)
            count += 5
            if count >= 8 {
                out.append(UInt8((bits >> UInt32(count - 8)) & 0xff))
                count -= 8
            }
        }
        return out
    }
}
