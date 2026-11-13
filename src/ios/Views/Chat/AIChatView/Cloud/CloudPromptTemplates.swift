import Foundation

/// 一键模板：把常用提示词存成按钮，长按输入框弹出。增删改、排序都支持。
/// 只依赖 Foundation，Linux 上单测。不含真实个人信息。
struct CloudPromptTemplate: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var prompt: String
}

enum CloudPromptTemplates {
    static let key = "OpenMinisPromptTemplates"
    static let maxCount = 30
    static let titleLimit = 40
    static let promptLimit = 4000

    static let seeds: [CloudPromptTemplate] = [
        CloudPromptTemplate(id: "seed-summary", title: "总结成三句话", prompt: "把下面内容总结成三句话："),
        CloudPromptTemplate(id: "seed-todos", title: "待办排个序", prompt: "把今天的待办按轻重缓急排个序："),
        CloudPromptTemplate(id: "seed-outline", title: "列个提纲", prompt: "根据下面的主题列一个简明提纲："),
    ]

    static func sanitize(_ t: CloudPromptTemplate) -> CloudPromptTemplate? {
        let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = t.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !prompt.isEmpty else { return nil }
        var id = t.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { id = "t-\(Int(Date().timeIntervalSince1970 * 1000))" }
        return CloudPromptTemplate(
            id: String(id.prefix(64)),
            title: String(title.prefix(titleLimit)),
            prompt: String(prompt.prefix(promptLimit))
        )
    }

    /// 还没写过钥匙时给三条例子；用户清空后会留下空数组，不再把例子塞回去。
    static func load(from defaults: UserDefaults) -> [CloudPromptTemplate] {
        guard let data = defaults.data(forKey: key) else { return seeds }
        let list = (try? JSONDecoder().decode([CloudPromptTemplate].self, from: data)) ?? []
        return list.compactMap(sanitize)
    }

    static func save(_ list: [CloudPromptTemplate], to defaults: UserDefaults) {
        let cleaned = Array(list.compactMap(sanitize).prefix(maxCount))
        defaults.set(try? JSONEncoder().encode(cleaned), forKey: key)
    }

    static func add(_ t: CloudPromptTemplate, to list: [CloudPromptTemplate]) -> [CloudPromptTemplate] {
        guard list.count < maxCount, let s = sanitize(t) else { return list }
        var out = list.filter { $0.id != s.id }
        out.append(s)
        return Array(out.prefix(maxCount))
    }

    static func update(_ t: CloudPromptTemplate, in list: [CloudPromptTemplate]) -> [CloudPromptTemplate] {
        guard let s = sanitize(t), let i = list.firstIndex(where: { $0.id == s.id }) else { return list }
        var out = list
        out[i] = s
        return out
    }

    static func delete(id: String, from list: [CloudPromptTemplate]) -> [CloudPromptTemplate] {
        list.filter { $0.id != id }
    }

    static func move(from: Int, to: Int, in list: [CloudPromptTemplate]) -> [CloudPromptTemplate] {
        guard list.indices.contains(from) else { return list }
        var out = list
        let item = out.remove(at: from)
        let dest = min(max(0, to > from ? to - 1 : to), out.count)
        out.insert(item, at: dest)
        return out
    }

    /// 点模板：输入框是空的就填上模板；已有草稿时接在模板后面（模板以顿号/冒号结尾则直接接上）。
    static func apply(_ t: CloudPromptTemplate, to draft: String) -> String {
        guard let s = sanitize(t) else { return draft }
        let cur = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if cur.isEmpty { return s.prompt }
        if s.prompt.hasSuffix("：") || s.prompt.hasSuffix(":") { return s.prompt + cur }
        return s.prompt + "\n" + cur
    }
}
