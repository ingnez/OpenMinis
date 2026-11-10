import Foundation

/// 只读取技能说明与明确启用的记忆，不遍历挂载文件夹或执行本机命令。
enum CloudContextFiles {
    static func collect(skillsRoot: URL, memoryRoot: URL, skills: Bool, memory: Bool) throws -> [[String: String]] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var files: [[String: String]] = []
        var used = 0
        let deadline = Date().addingTimeInterval(10)
        func failure(_ text: String) -> NSError {
            NSError(domain: "CloudWorkContext", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        func safeDirectory(_ url: URL) throws -> Bool {
            guard fm.fileExists(atPath: url.path) else { return false }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw failure("工作配置目录不可用或为符号链接，请检查共享文件夹设置。")
            }
            return true
        }
        func append(_ url: URL, relative: String) throws {
            try Task.checkCancellation()
            guard Date() < deadline else { throw failure("工作配置读取超时，请暂时关闭技能或记忆同步后重试。") }
            guard fm.fileExists(atPath: url.path) else { return }
            let attrs = try url.resourceValues(forKeys: keys)
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else {
                throw failure("工作配置包含非普通文件：" + relative)
            }
            guard let size = attrs.fileSize, size <= 300_000 else {
                throw failure("工作配置文件超过300KB：" + relative)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 300_000, let text = String(data: data, encoding: .utf8) else {
                throw failure("工作配置不是有效UTF-8文本或超过限制：" + relative)
            }
            let content = redacted(text)
            used += content.utf8.count
            guard used <= 1_500_000 else { throw failure("工作配置超过同步上限，请在设置中缩小同步范围。") }
            files.append(["path": relative, "content": content])
        }
        if memory, try safeDirectory(memoryRoot) {
            try append(memoryRoot.appendingPathComponent("GLOBAL.md"), relative: "memory/GLOBAL.md")
            let days = try fm.contentsOfDirectory(at: memoryRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(3)
            for day in days { try append(day, relative: "memory/" + day.lastPathComponent) }
        }
        if skills, try safeDirectory(skillsRoot) {
            let dirs = try fm.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: nil)
            guard dirs.count <= 1000 else { throw failure("技能目录过多，请缩小同步范围。") }
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let attrs = try fm.attributesOfItem(atPath: dir.path)
                guard attrs[.type] as? FileAttributeType == .typeDirectory else { continue }
                try append(dir.appendingPathComponent("SKILL.md"), relative: "skills/" + dir.lastPathComponent + "/SKILL.md")
            }
        }
        return files
    }

    static func redacted(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"(?i)(Bearer\s+)\S+"#, "$1[已脱敏]"),
            (#"\bsk-[A-Za-z0-9_-]{12,}"#, "[已脱敏]"),
            (#"(?im)^.*(?:sshpass|SSHPASS|api[_ -]?key|oauth[_ -]?token|登录密码|用户 / 密码|网关密钥|明文密码|密钥：|密码：).*$"#, "[含凭据的行已省略]")
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }
}
