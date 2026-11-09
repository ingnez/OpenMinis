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
        // 从 guest 文件接口读取，不能把 iOS 沙盒路径误作 iSH 根目录。
        let script = """
import pathlib,json,re,sys
root=pathlib.Path('/var/minis')
files=[]
limit=1500000
used=0
include_memory=\(memory ? "True" : "False")
include_skills=\(skills ? "True" : "False")
def clean(text):
    # 仅作常见凭据脱敏，不读取环境变量、配置或凭据文件。
    text=re.sub(r'(?i)(Bearer\\s+)\\S+',r'\\1[已脱敏]',text)
    text=re.sub(r'\\bsk-[A-Za-z0-9_-]{12,}', '[已脱敏]', text)
    text=re.sub(r'(?im)^.*(?:sshpass|SSHPASS|api[_ -]?key|oauth[_ -]?token|登录密码|用户 / 密码|网关密钥|明文密码|密钥：|密码：).*$','[含凭据的行已省略]',text)
    return text
paths=[]
if include_memory:
    directory=root/'memory'
    global_file=directory/'GLOBAL.md'
    if global_file.is_file(): paths.append(global_file)
    paths += sorted((x for x in directory.glob('????-??-??.md') if x.is_file()),reverse=True)[:3]
if include_skills:
    paths += sorted((root/'skills').glob('*/SKILL.md'))
for path in paths:
    if path.is_symlink() or path.stat().st_size>300000:
        raise RuntimeError('上下文文件不适合自动同步：'+path.name)
    content=clean(path.read_text(encoding='utf-8'))
    used += len(content.encode('utf-8'))
    if used>limit: raise RuntimeError('工作配置超过同步上限，请在设置中缩小同步范围')
    files.append({'path':str(path.relative_to(root)),'content':content})
print(json.dumps({'files':files},ensure_ascii=False))
"""
        let result: ISHShellExecutionResult = await withCheckedContinuation { continuation in
            ISHShellExecutor.executeExecutable("/usr/bin/python3", arguments: ["-"], environment: nil,
                stdinData: script.data(using: .utf8), lineCallback: nil) { continuation.resume(returning: $0) }
        }
        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = payload["files"] as? [[String: String]] else {
            throw NSError(domain: "CloudWorkContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "工作配置导出失败。请确认本机已安装 Python3，或在云电脑设置关闭记忆/技能同步后重试。"])
        }
        instructions += "\n工作区中 skills/<技能名>/SKILL.md 是已同步的技能说明，memory/ 是用户工作记忆；需要时通过文件工具读取。只同步了说明文件，引用脚本或其他资产未同步时应明确缺少依赖，不要假定存在。\n"
        return ["instructions": instructions, "files": files]
    }
}
