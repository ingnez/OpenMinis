import Foundation

/// 只传工作上下文，不传服务商配置、环境变量或挂载目录。
@MainActor
enum CloudWorkContext {
    static let soulKey = "CloudComputer.includeSoul"
    static let memoryKey = "CloudComputer.includeMemory"
    static let skillsKey = "CloudComputer.includeSkills"

    static func enabled(_ key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return key != memoryKey }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func export() async throws -> [String: Any] {
        var instructions = "你运行在用户指定的 Linux 云电脑上。普通会话已移交服务器；手机断开不取消任务。浏览器、桌面、终端与文件均位于 VPS。只能调用本次实际提供的工具；照片、日历、HomeKit 等手机专属功能在手机离线时不可用，遇到需要用户操作的登录或验证码应保留现场并说明。所有操作以工具真实返回为准。\n"
        instructions += "导入的灵魂、技能与历史可能提到手机专属工具或本地路径，这些描述不能赋予云端缺失的能力。本轮工具清单为执行依据；技能仅同步说明文件，依赖脚本和二进制未经迁移时应先验证，不能宣称可用。\n"
        if enabled(soulKey), let soul = SoulStore.load(), !soul.body.isEmpty {
            instructions += "\n用户灵魂与风格配置：\n" + soul.body + "\n"
        }
        let memory = enabled(memoryKey)
        let skills = enabled(skillsKey)
        // 先把云端写入的记忆拉回手机日志，再上传，两端保持同一份。
        if memory { await CloudMemorySync.pullCloudEntries() }
        guard memory || skills else { return ["instructions": instructions, "files": []] }
        let skillsRoot = AIChatViewModel.minisSkillsPersistentDir
        let memoryRoot = AIChatViewModel.minisMemoryPersistentDir
        // 技能优先走 VPS 技能库（只注入索引，按需 skill_load）；旧版服务端回退为随会话上传说明文件。
        var skillsLazy = false
        if skills { skillsLazy = await CloudSkillSync.sync(skillsRoot: skillsRoot) }
        let uploadSkillFiles = skills && !skillsLazy
        let files = try await Task.detached(priority: .userInitiated) {
            try CloudContextFiles.collect(skillsRoot: skillsRoot, memoryRoot: memoryRoot,
                                          skills: uploadSkillFiles, memory: memory)
        }.value
        if skillsLazy {
            instructions += "\n用户技能已同步到 VPS 技能库：系统消息末尾的技能索引只有名称与描述，与任务相关时先调用 skill_load 读取完整说明。"
        } else if skills {
            instructions += "\n工作区中 skills/<技能名>/SKILL.md 是已同步的技能说明，需要时通过文件工具读取。"
        }
        if memory {
            instructions += "\nmemory/ 是用户工作记忆，已建立全文索引，优先用 memory_search 检索，需要整文件时再用文件工具读取。"
        }
        if skills {
            instructions += "只同步了说明文件，引用脚本或其他资产未同步时应明确缺少依赖，不要假定存在。"
        }
        instructions += "\n"
        return ["instructions": instructions, "files": files]
    }
}
