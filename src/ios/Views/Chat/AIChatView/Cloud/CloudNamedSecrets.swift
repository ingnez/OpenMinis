import Foundation

/// 命名密钥的元数据。接口只回名字和说明，从不回明文。
struct CloudNamedSecretItem: Identifiable, Equatable {
    var name: String
    var description: String
    var updatedAt: Double

    var id: String { name }

    init?(json d: [String: Any]) {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        description = d["description"] as? String ?? ""
        updatedAt = (d["updated_at"] as? NSNumber)?.doubleValue ?? 0
    }
}

enum CloudNamedSecretsService {
    static func list() async throws -> (items: [CloudNamedSecretItem], available: Bool) {
        let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/named-secrets", body: nil)
        let items = (resp["items"] as? [[String: Any]] ?? []).compactMap(CloudNamedSecretItem.init)
        return (items, resp["available"] as? Bool ?? true)
    }

    static func save(name: String, value: String, description: String) async throws {
        _ = try await CloudBotService.connected().request(
            method: "PUT", path: "/v1/named-secrets",
            body: ["name": name, "value": value, "description": description]
        )
    }

    static func delete(_ name: String) async throws {
        _ = try await CloudBotService.connected().request(method: "DELETE", path: "/v1/named-secrets/\(name)", body: nil)
    }
}

