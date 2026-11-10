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
        guard memory || skills else { return ["instructions": instructions, "files": []] }
        let skillsRoot = AIChatViewModel.minisSkillsPersistentDir
        let memoryRoot = AIChatViewModel.minisMemoryPersistentDir
        let files = try await Task.detached(priority: .userInitiated) {
            try CloudContextFiles.collect(skillsRoot: skillsRoot, memoryRoot: memoryRoot,
                                          skills: skills, memory: memory)
        }.value
        instructions += "\n工作区中 skills/<技能名>/SKILL.md 是已同步的技能说明，memory/ 是用户工作记忆；需要时通过文件工具读取。只同步了说明文件，引用脚本或其他资产未同步时应明确缺少依赖，不要假定存在。\n"
        return ["instructions": instructions, "files": files]
    }
}
