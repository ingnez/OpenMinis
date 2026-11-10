//
//  CloudSkillSync.swift
//  Minis - 技能按需加载
//  手机 skills/<名称>/SKILL.md 同步到 VPS 技能库（POST /v1/skills/sync），对话只注入名称+描述索引，
//  模型需要时调用 skill_load 读取全文。内容未变化且服务端已有全部技能时跳过上传。
//

import CryptoKit
import Foundation

@MainActor
enum CloudSkillSync {
    static let syncedHashKey = "OpenMinisCloud_skillsSyncedHash"

    /// 同步成功（服务端已是最新）返回 true；服务端不支持或失败返回 false，调用方回退为随会话上传技能文件。
    static func sync(skillsRoot: URL) async -> Bool {
        guard CloudConnection.shared.isConnected else { return false }
        let files: [[String: String]]
        do {
            files = try await Task.detached(priority: .userInitiated) {
                try CloudContextFiles.collect(skillsRoot: skillsRoot, memoryRoot: skillsRoot, skills: true, memory: false)
            }.value
        } catch {
            return false
        }
        var skills: [[String: Any]] = []
        var hasher = SHA256()
        for file in files {
            guard let path = file["path"], let content = file["content"] else { continue }
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "skills" else { continue }
            let name = String(parts[1])
            skills.append(["name": name, "content": content])
            hasher.update(data: Data((name + "\u{0}" + content + "\u{0}").utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let localNames = Set(skills.compactMap { $0["name"] as? String })

        // 服务端技能清单与本地一致且内容哈希未变：跳过上传（服务重装或被清空时会重新上传）。
        guard let index = try? await CloudConnection.shared.request(method: "GET", path: "/v1/skills"),
              let remote = index["skills"] as? [[String: Any]] else { return false }
        let remoteNames = Set(remote.compactMap { item -> String? in
            (item["source"] as? String) == "phone" ? item["name"] as? String : nil
        })
        if digest == UserDefaults.standard.string(forKey: syncedHashKey), remoteNames == localNames {
            return true
        }
        do {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/skills/sync",
                                                        body: ["skills": skills, "prune": true])
            UserDefaults.standard.set(digest, forKey: syncedHashKey)
            return true
        } catch {
            return false
        }
    }
}
