//
//  CloudPersonas.swift
//  Minis - 云端多人格（/v1/personas）
//  每个人格有自己的指令与私有记忆范围（共享记忆对所有人格可见）；会话、例行任务、子代理继承所属人格。
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

struct CloudPersonasView: View {
    @State private var personas: [CloudPersona] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                if personas.isEmpty && !loading {
                    Text("还没有人格。新建一个，例如“ICU 助手”“代码助手”，它们各有指令与私有记忆。")
                        .foregroundStyle(.secondary)
                }
                ForEach(personas) { p in
                    NavigationLink(destination: CloudPersonaEditor(existing: p, onSaved: { await reload() })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.label).font(.headline)
                            Text(p.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { remove(p, purge: false) }
                        Button("删除并清记忆") { remove(p, purge: true) }.tint(.orange)
                    }
                    .contextMenu {
                        Button("用此人格新建云端会话") { newSession(p) }
                    }
                }
            } footer: {
                Text("长按人格可用它新建云端会话；例行任务可在编辑器中选择人格。共享记忆（未指定人格）对所有人格可见，人格写入的记忆只有自己能检索。")
            }
            if let infoText { Section { Text(infoText).font(.footnote).foregroundStyle(.secondary) } }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("云端人格")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { CloudPersonaEditor(existing: nil, onSaved: { await reload() }) }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        loading = true
        do {
            personas = try await CloudPersonaService.list()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func remove(_ p: CloudPersona, purge: Bool) {
        Task {
            do {
                try await CloudPersonaService.delete(p.id, purgeMemory: purge)
                await reload()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func newSession(_ p: CloudPersona) {
        Task {
            do {
                try await CloudPersonaService.createSession(persona: p)
                infoText = "已新建会话“\(p.label)”，在云端会话列表中打开。"
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

struct CloudPersonaEditor: View {
    let existing: CloudPersona?
    let onSaved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pid = ""
    @State private var name = ""
    @State private var emoji = ""
    @State private var instructions = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                if existing == nil {
                    TextField("ID（小写字母/数字/-/_，如 icu）", text: $pid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    LabeledContent("ID", value: pid)
                }
                TextField("名称", text: $name)
                TextField("图标 Emoji（可选）", text: $emoji)
            }
            Section("指令") {
                TextField("这个人格是谁、怎么做事", text: $instructions, axis: .vertical)
                    .lineLimit(4...14)
            }
            if let errorText { Section { Text(errorText).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle(existing == nil ? "新建人格" : "编辑人格")
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save() }
                    .disabled(saving || !CloudPersonaService.isValidId(pid)
                              || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if let existing, pid.isEmpty {
                pid = existing.id
                name = existing.name
                emoji = existing.emoji
                instructions = existing.instructions
            }
        }
    }

    private func save() {
        saving = true
        let p = CloudPersona(id: pid, name: name.trimmingCharacters(in: .whitespaces),
                             instructions: instructions, emoji: String(emoji.prefix(4)))
        Task {
            do {
                try await CloudPersonaService.save(p)
                await onSaved()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}
