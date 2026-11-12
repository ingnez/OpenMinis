//
//  CloudSteer.swift
//  Minis - 运行中「插话」（发送免插队）与实时小终端卡片。
//  插话：Bot 正在干活时发的消息立刻交给服务器，模型在下一步之前就能看到（正在生成的那次请求会被打断重来）；
//  任务恰好结束了（409）就改成普通发送。设置在发送键长按菜单里：插话（默认）/ 排队。
//

import SwiftUI
import UIKit

enum CloudSteerMode {
    static let key = "OpenMinisCloud_steerInterrupt"

    /// true = 插话（默认），false = 排队（等这一轮做完再发）
    static var interrupt: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum CloudInjector {
    enum Outcome: Equatable {
        case injected(state: String?)
        /// 任务已经结束 / 不在运行：改走普通发送
        case notRunning
        case retryable
        case failed(String)
    }

    /// 同一条消息重试时带同一个 nonce，服务器只收一次
    static func inject(taskId: String, content: String, nonce: String) async -> Outcome {
        do {
            let response = try await CloudConnection.shared.request(method: "POST", path: "/v1/tasks/\(taskId)/messages",
                                                                    body: ["content": content, "nonce": nonce])
            return .injected(state: response["state"] as? String)
        } catch let error where CloudOutbox.isTransient(error) {
            return .retryable
        } catch {
            let text = error.localizedDescription
            if text.contains("HTTP 409") || text.contains("HTTP 404") || text.contains("版本过旧") { return .notRunning }
            return .failed(text)
        }
    }
}

/// 服务器 live.tool：正在跑的工具名和最后几行输出
struct CloudLiveTool: Equatable {
    let id: String
    let name: String
    let output: String

    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any], let name = d["name"] as? String, !name.isEmpty else { return nil }
        id = d["id"] as? String ?? ""
        self.name = name
        output = d["output"] as? String ?? ""
    }

    var label: String {
        switch name {
        case "shell_execute": return "终端"
        case "file_read": return "读取文件"
        case "file_write": return "写入文件"
        case "file_edit": return "编辑文件"
        case "browser_action": return "浏览器"
        case "desktop_action": return "桌面"
        case "web_search": return "搜索"
        default: return name
        }
    }

    var lines: [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).suffix(6).map(String.init)
    }
}
