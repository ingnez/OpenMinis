//
//  CloudPersonas.swift
//  Minis - 云端人格（/v1/personas）的轻量模型，供例行任务编辑器选择 Bot。
//  完整的 Bot 管理见 CloudBots.swift（人格即 Bot）。
//

import Foundation
import SwiftUI

struct CloudPersona: Identifiable, Hashable {
    let id: String
    var name: String
    var instructions: String
    var emoji: String

    init(id: String, name: String, instructions: String, emoji: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.emoji = emoji
    }

    init?(_ d: [String: Any]) {
        guard let pid = d["persona_id"] as? String else { return nil }
        id = pid
        name = d["name"] as? String ?? pid
        instructions = d["instructions"] as? String ?? ""
        emoji = d["emoji"] as? String ?? ""
    }

    var label: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
}

@MainActor
enum CloudPersonaService {
    static func list() async throws -> [CloudPersona] {
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/personas", body: nil)
        let items = resp["personas"] as? [[String: Any]] ?? []
        return items.compactMap { CloudPersona($0) }
    }

    static func save(_ p: CloudPersona) async throws {
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        var body: [String: Any] = ["name": p.name, "instructions": p.instructions]
        if !p.emoji.isEmpty { body["emoji"] = p.emoji }
        _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/personas/\(p.id)", body: body)
    }

    static func delete(_ id: String, purgeMemory: Bool) async throws {
        let path = "/v1/personas/\(id)" + (purgeMemory ? "?purge_memory=1" : "")
        _ = try await CloudConnection.shared.request(method: "DELETE", path: path, body: nil)
    }

    static func createSession(persona: CloudPersona) async throws {
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions",
                                                     body: ["title": persona.label, "persona_id": persona.id])
    }

    static func isValidId(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }
}
