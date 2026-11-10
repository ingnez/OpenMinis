//
//  CloudTaskPump.swift
//  Minis - 本地「云电脑」对话与多 Bot 对话共用的任务事件管线：
//  同一个事件循环（CloudTaskPump）、同一个事件→消息块转换（CloudEventApplier）、
//  同一个服务器历史→消息块转换（CloudHistoryAdapter），以及客户端实测（CloudClientMetrics）。
//  只依赖 Foundation 和 CloudConnection 的 isConnected / connect / request，便于独立回归测试。
//

import Foundation

/// 客户端实测：首字时间、任务总时长、隧道重连耗时，按模式（local / bot）分开，性能页显示
enum CloudClientMetrics {
    struct Sample: Codable {
        let mode: String
        let kind: String
        let ms: Double
        let at: Double
    }
    private static let key = "OpenMinisCloud_ClientMetrics"
    private static let lock = NSLock()

    static func record(mode: String, kind: String, ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var list = load()
        list.append(Sample(mode: mode, kind: kind, ms: ms, at: Date().timeIntervalSince1970))
        if list.count > 300 { list.removeFirst(list.count - 300) }
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func all() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 中位数与样本数
    static func median(mode: String, kind: String) -> (ms: Double, count: Int)? {
        let v = all().filter { $0.mode == mode && $0.kind == kind }.map(\.ms).sorted()
        guard !v.isEmpty else { return nil }
        let m = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        return (m, v.count)
    }

    private static func load() -> [Sample] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Sample].self, from: d) else { return [] }
        return list
    }
}

/// 任务事件 → ChatMessage 的消息块（文字 / 工具胶囊 / 错误），两种模式完全相同
enum CloudEventApplier {
    static let visibleTypes: Set<String> = ["thought", "text", "content", "tool_call", "tool_result", "final", "error", "approval_required"]

    static func apply(_ message: ChatMessage, type: String, payload: [String: Any]) {
        switch type {
        case "thought", "text", "content":
            if let content = payload["content"] as? String, !content.isEmpty {
                if let last = message.blocks.last, case .text = last.kind {
                    // 不同轮次的整段话之间空一行，免得两句粘在一起
                    if type == "thought", !last.content.isEmpty, !last.content.hasSuffix("\n") { last.content += "\n\n" }
                    last.content += content
                } else {
                    message.blocks.append(AssistantBlock(kind: .text, content: content))
                }
            }
        case "tool_call":
            let callId = payload["id"] as? String ?? UUID().uuidString
            let toolName = payload["tool"] as? String ?? "tool"
            let args = payload["arguments"] as? [String: Any] ?? [:]
            guard !message.blocks.contains(where: { $0.toolUseId == callId }) else { return }
            let block = AssistantBlock(kind: kind(tool: toolName, args: args), content: "", toolStatus: .running, toolUseId: callId)
            if let data = try? JSONSerialization.data(withJSONObject: args), let str = String(data: data, encoding: .utf8) {
                block.toolInputArgs = str
            }
            message.blocks.append(block)
        case "tool_result":
            let callId = payload["id"] as? String ?? ""
            let result = payload["result"]
            let isErr = (payload["is_error"] as? Bool) ?? ((result as? [String: Any])?["error"] != nil)
            let resultStr: String
            if let resDict = result as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: resDict), let str = String(data: data, encoding: .utf8) {
                resultStr = str
            } else if let resStr = result as? String {
                resultStr = resStr
            } else {
                resultStr = "Done"
            }
            if let block = message.blocks.first(where: { $0.toolUseId == callId }) {
                block.content = resultStr
                block.toolStatus = isErr ? .failed(message: resultStr) : .success
            }
        case "error":
            if let err = payload["error"] as? String { message.error = err }
        case "final":
            if let content = payload["content"] as? String, !content.isEmpty {
                if let last = message.blocks.last, case .text = last.kind {
                    if !last.content.contains(content) { last.content += content }
                } else {
                    message.blocks.append(AssistantBlock(kind: .text, content: content))
                }
            }
        default:
            break
        }
    }

    static func kind(tool: String, args: [String: Any]) -> AssistantBlockKind {
        switch tool {
        case "shell_execute": return .shellTool(command: args["command"] as? String ?? "")
        case "file_read": return .fileReadTool(path: args["path"] as? String ?? "")
        case "file_write": return .fileWriteTool(path: args["path"] as? String ?? "")
        case "file_edit": return .fileEditTool(path: args["path"] as? String ?? "")
        case "browser_action", "desktop_action": return .browserTool(action: args["action"] as? String ?? tool)
        default: return .shellTool(command: tool)
        }
    }

    /// 反查工具名（渲染步骤说明用）：shellTool 既可能是命令也可能是其他工具名
    static func toolName(_ block: AssistantBlock) -> String? {
        let args = block.toolInputArgs.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        switch block.kind {
        case .shellTool(let command): return args["command"] != nil ? "shell_execute" : command
        case .fileReadTool: return "file_read"
        case .fileWriteTool: return "file_write"
        case .fileEditTool: return "file_edit"
        case .browserTool: return "browser_action"
        default: return nil
        }
    }
}

/// 服务器会话历史（OpenAI 风格 messages）→ 与本地模式同样的 ChatMessage 列表。
/// 同一轮里助手的多条消息（正文、tool_calls、tool 结果）合并成一条助手消息，工具结果挂到对应工具块上。
enum CloudHistoryAdapter {
    struct Turn {
        let message: ChatMessage
        /// 这一轮最后一条原始消息（取时间戳算耗时）
        let raw: [String: Any]
    }

    static func turns(from messages: [[String: Any]]) -> [Turn] {
        var out: [Turn] = []
        var current: ChatMessage?
        var currentRaw: [String: Any] = [:]
        func flush() {
            if let c = current, !c.blocks.isEmpty || c.error != nil { out.append(Turn(message: c, raw: currentRaw)) }
            current = nil
        }
        for m in messages {
            let role = m["role"] as? String ?? ""
            let content = m["content"] as? String ?? ""
            switch role {
            case "user":
                flush()
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                out.append(Turn(message: ChatMessage(role: .user, content: content), raw: m))
            case "assistant":
                let msg = current ?? ChatMessage(role: .assistant, content: "")
                current = msg
                currentRaw = m
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CloudEventApplier.apply(msg, type: "thought", payload: ["content": content])
                    msg.content += (msg.content.isEmpty ? "" : "\n\n") + content
                }
                for call in toolCalls(m) {
                    let fn = call["function"] as? [String: Any] ?? [:]
                    let argText = fn["arguments"] as? String ?? ""
                    let args = argText.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    CloudEventApplier.apply(msg, type: "tool_call", payload: [
                        "id": call["id"] as? String ?? UUID().uuidString,
                        "tool": fn["name"] as? String ?? "tool",
                        "arguments": args,
                    ])
                }
            case "tool":
                guard let msg = current else { continue }
                let parsed: Any = content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? content
                CloudEventApplier.apply(msg, type: "tool_result", payload: ["id": m["tool_call_id"] as? String ?? "", "result": parsed])
            default:
                continue
            }
        }
        flush()
        // 历史里的工具都已结束：没拿到结果的（服务器中断）显示为完成，不能一直转圈
        for t in out {
            for b in t.message.blocks where b.toolStatus == .running { b.toolStatus = .success }
        }
        return out
    }

    static func toolCalls(_ m: [String: Any]) -> [[String: Any]] {
        if let a = m["tool_calls"] as? [[String: Any]] { return a }
        if let s = m["tool_calls"] as? String, let d = s.data(using: .utf8),
           let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { return a }
        return []
    }
}

/// 两种模式共用的任务事件循环（从本地模式 CloudChatBridge.pollAndStream 抽出）：
/// - 出错不退出、不断开别人在用的隧道，按 1/2/4/8 秒退避静默重试；连续失败 3 次才给一行温和提示，恢复后自动清掉
/// - 任务状态只看 events 接口返回的 status；到终态才结束
/// - wait > 0 时用长轮询（多 Bot 模式，事件一到马上返回）；live 为真时顺带取正在生成的文字
@MainActor
enum CloudTaskPump {
    struct Batch {
        let events: [[String: Any]]
        let rawStatus: String?
        let status: CloudTaskStatus?
        let live: [String: Any]?
    }

    struct Options {
        var mode: String
        var wait: Int = 0
        var live: Bool = false
        /// 点发送的时刻；nil 表示是恢复 / 重新打开对话，不计入首字统计
        var startedAt: Date? = nil
    }

    static let troubleText = "云端任务继续执行，正在恢复连接…"

    /// 返回终态；被停止（离开页面、换任务）时返回 nil
    static func run(taskId: String,
                    after: Int = 0,
                    options: Options,
                    liveSeq: @escaping () -> Int = { -1 },
                    shouldStop: @escaping () -> Bool,
                    onBatch: @escaping (Batch) -> Void,
                    onTrouble: @escaping (String?) -> Void) async -> CloudTaskStatus? {
        let conn = CloudConnection.shared
        var cursor = after
        var failures = 0
        var troubled = false
        var firstShown = false
        while !Task.isCancelled && !shouldStop() {
            do {
                if !conn.isConnected { try await conn.connect() }
                var path = "/v1/tasks/\(taskId)/events?after=\(cursor)"
                if options.wait > 0 { path += "&wait=\(options.wait)" }
                if options.live { path += "&live_after=\(liveSeq())" }
                let started = Date()
                let resp = try await conn.request(method: "GET", path: path, body: nil)
                if Task.isCancelled || shouldStop() { return nil }
                failures = 0
                if troubled { troubled = false; onTrouble(nil) }
                var fresh: [[String: Any]] = []
                for ev in resp["events"] as? [[String: Any]] ?? [] {
                    guard let id = (ev["monotonic_id"] as? Int) ?? (ev["id"] as? Int), id > cursor else { continue }
                    cursor = id
                    fresh.append(ev)
                }
                if let c = resp["last_cursor"] as? Int { cursor = max(cursor, c) }
                let raw = resp["status"] as? String
                let status = raw.flatMap { CloudTaskStatus(rawValue: $0) }
                let live = resp["live"] as? [String: Any]
                if !firstShown, hasVisibleText(fresh) || !((live?["text"] as? String) ?? "").isEmpty {
                    firstShown = true
                    if let t0 = options.startedAt {
                        CloudClientMetrics.record(mode: options.mode, kind: "first_text", ms: Date().timeIntervalSince(t0) * 1000)
                    }
                }
                onBatch(Batch(events: fresh, rawStatus: raw, status: status, live: live))
                if let status, status.isTerminal {
                    if let t0 = options.startedAt {
                        CloudClientMetrics.record(mode: options.mode, kind: "total", ms: Date().timeIntervalSince(t0) * 1000)
                    }
                    return status
                }
                let quick = Date().timeIntervalSince(started) < 0.5
                if options.wait == 0 || (fresh.isEmpty && live == nil && quick) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                if Task.isCancelled || shouldStop() { return nil }
                failures += 1
                if failures >= 3 && !troubled {
                    troubled = true
                    onTrouble(troubleText)
                }
                let delay = min(8.0, pow(2.0, Double(failures - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return nil
    }

    private static func hasVisibleText(_ events: [[String: Any]]) -> Bool {
        events.contains { ev in
            guard let t = ev["type"] as? String, ["thought", "text", "content", "final"].contains(t) else { return false }
            return !(((ev["payload"] as? [String: Any])?["content"] as? String) ?? "").isEmpty
        }
    }
}

/// 读请求静默重试：瞬时失败（隧道重建、服务器忙）不打扰用户，3 次（约 4.5 秒）都失败才抛给调用方显示
enum CloudQuiet {
    static func retry<T>(_ attempts: Int = 3, _ op: () async throws -> T) async throws -> T {
        var lastError: Error?
        for i in 0..<max(1, attempts) {
            if i > 0 { try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * Double(i))) }
            if Task.isCancelled { break }
            do { return try await op() } catch { lastError = error }
        }
        throw lastError ?? CancellationError()
    }
}
