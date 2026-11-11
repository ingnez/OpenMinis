import Foundation

/// 本地对话界面（工具面板、步骤缩略图）被云端任务复用时用的名字与中文说明。
/// 在云电脑里跑的步骤，标题写这台云电脑 / Bot 的名字，资源读数来自云端 /v1/live-stats，不是这台 iPhone。
struct CloudComputerContext: Equatable {
    /// 当前连着的云电脑（多台时是正在用的这台）
    let computerName: String
    /// 谁在干活：Bot 名字；本地会话交给云电脑执行时就是云电脑名字
    let actorName: String

    static func current(actor: String? = nil, _ d: UserDefaults = .standard) -> CloudComputerContext {
        let name = [d.string(forKey: "OpenMinisCloud_name"), d.string(forKey: "OpenMinisCloud_host")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "云电脑"
        let who = actor?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudComputerContext(computerName: name, actorName: (who?.isEmpty == false ? who! : name))
    }

    /// 工具种类（shell / read / write / edit / browser / image / memory / agent / ask）→「小助手 正在用终端…」
    func activity(_ tool: String) -> String {
        let doing: String
        switch tool {
        case "shell": doing = "正在用终端…"
        case "read": doing = "正在读文件…"
        case "write": doing = "正在写文件…"
        case "edit": doing = "正在改文件…"
        case "browser": doing = "正在用浏览器…"
        case "image": doing = "正在看图片…"
        case "memory": doing = "正在翻记忆…"
        case "agent": doing = "正在派子代理…"
        case "ask": doing = "在问你"
        default: return actorName
        }
        return actorName + " " + doing
    }
}
