import Foundation

@main struct CloudContextFilesTests {
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? fm.removeItem(at: root) }
  let skills = root.appendingPathComponent("skills"), memory = root.appendingPathComponent("memory")
  let skill = skills.appendingPathComponent("demo")
  try fm.createDirectory(at: skill, withIntermediateDirectories: true)
  try fm.createDirectory(at: memory, withIntermediateDirectories: true)
  try "# 技能\n正常内容\nBearer secret-token\napi_key: secret-value".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  try "不应同步的脚本".write(to: skill.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)
  try "偏好".write(to: memory.appendingPathComponent("GLOBAL.md"), atomically: true, encoding: .utf8)
  for day in 1...4 {
   try "日记".write(to: memory.appendingPathComponent("2026-11-0\(day).md"), atomically: true, encoding: .utf8)
  }
  let basic = try CloudContextFiles.collect(skillsRoot: skills, memoryRoot: memory, skills: true, memory: false)
  precondition(basic.count == 1 && basic[0]["path"] == "skills/demo/SKILL.md")
  precondition(!basic[0]["content"]!.contains("secret-token") && !basic[0]["content"]!.contains("secret-value"))
  let all = try CloudContextFiles.collect(skillsRoot: skills, memoryRoot: memory, skills: true, memory: true)
  precondition(all.count == 5 && !all.contains { $0["path"] == "memory/2026-11-01.md" })
  let off = try CloudContextFiles.collect(skillsRoot: skills, memoryRoot: memory, skills: false, memory: false)
  precondition(off.isEmpty)
  try String(repeating: "x", count: 300001).write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  do {
   _ = try CloudContextFiles.collect(skillsRoot: skills, memoryRoot: memory, skills: true, memory: false)
   preconditionFailure("未阻止超限文件")
  } catch {}
  try fm.removeItem(at: skill.appendingPathComponent("SKILL.md"))
  try fm.createSymbolicLink(at: skill.appendingPathComponent("SKILL.md"), withDestinationURL: memory.appendingPathComponent("GLOBAL.md"))
  do {
   _ = try CloudContextFiles.collect(skillsRoot: skills, memoryRoot: memory, skills: true, memory: false)
   preconditionFailure("未阻止符号链接")
  } catch {}
  print("原生工作配置回归通过：无Python依赖、开关隔离、仅说明文件、最近三日日志、脱敏、超限和符号链接")
 }
}
