//
//  CloudVoiceBridge.swift
//  Minis - 实时语音通话 → 云电脑 Agent
//  实时语音模型通过函数调用把要真正执行的工作交给云电脑；完成后把结论交回通话由模型朗读。
//

import Foundation

@MainActor
enum CloudVoiceBridge {
    private static var lastTaskId: String?
    private static var sessionByTask: [String: String] = [:]

    /// 已选择云电脑服务商与模型时才向实时模型暴露云电脑工具。
    static var isAvailable: Bool {
        let d = UserDefaults.standard
        return !(d.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? "").isEmpty
            && !(d.string(forKey: "OpenMinisCloud_manualModel") ?? "").isEmpty
    }

    /// 执行一次工具调用；返回给实时模型的 JSON 字符串，以及需要在后台等待完成的任务 ID。
    static func call(name: String, arguments: [String: Any]) async -> (output: String, watchTaskId: String?) {
        do {
            switch name {
            case "cloud_task_start":
                let prompt = (arguments["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { return (encode(["error": "prompt 不能为空"]), nil) }
                let tid = try await startTask(prompt: prompt)
                return (encode(["status": "submitted", "task_id": tid,
                                "note": "已交给云电脑在后台执行，完成后会收到通知；现在先简短告诉用户已经开始。"]), tid)
            case "cloud_task_status":
                var tid = arguments["task_id"] as? String ?? ""
                if tid.isEmpty { tid = lastTaskId ?? "" }
                guard !tid.isEmpty else { return (encode(["error": "本次通话还没有云电脑任务"]), nil) }
                return (encode(try await progress(taskId: tid)), nil)
            case "cloud_routine_run":
                let key = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let routines = try await CloudRoutineService.list()
                let exact = routines.first { ($0["name"] as? String) == key }
                let fuzzy = routines.first { ($0["name"] as? String)?.localizedCaseInsensitiveContains(key) == true }
                guard !key.isEmpty, let match = exact ?? fuzzy, let rid = match["routine_id"] as? String else {
                    let names = routines.compactMap { $0["name"] as? String }
                    return (encode(["error": "没有找到例行任务：\(key)", "routines": names]), nil)
                }
                _ = try await CloudRoutineService.runNow(routineId: rid)
                return (encode(["status": "started", "routine": match["name"] as? String ?? key,
                                "note": "例行任务已开始，结果会通过推送通知送达。"]), nil)
            default:
                return (encode(["error": "未知工具：\(name)"]), nil)
            }
        } catch {
            return (encode(["error": error.localizedDescription]), nil)
        }
    }

    /// 轮询直到任务结束（或需要审批 / 超时），返回给模型朗读的通知文本。取消时返回空串。
    static func waitForResult(taskId: String) async -> String {
        var failures = 0
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return "" }
            do {
                let p = try await progress(taskId: taskId)
                failures = 0
                let status = p["status"] as? String ?? ""
                if status == "waiting_user" {
                    return "云电脑任务 \(taskId) 需要用户批准一项操作，请提醒用户到 Minis 的云端会话或通知里处理。"
                }
                if ["completed", "failed", "cancelled", "limit_reached", "interrupted"].contains(status) {
                    let result = p["result"] as? String ?? ""
                    return "云电脑任务 \(taskId) 结束，状态：\(status)。" + (result.isEmpty ? "" : "结果：\(result)")
                }
            } catch {
                failures += 1
                if failures >= 5 { return "暂时无法获取云电脑任务 \(taskId) 的进度：\(error.localizedDescription)" }
            }
        }
        return "云电脑任务 \(taskId) 已运行 30 分钟仍未结束，可稍后再问进度。"
    }

    private static func startTask(prompt: String) async throws -> String {
        let d = UserDefaults.standard
        let instanceId = d.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? ""
        let model = d.string(forKey: "OpenMinisCloud_manualModel") ?? ""
        guard !instanceId.isEmpty, !model.isEmpty else { throw failure("请先在云电脑设置中选择服务商与模型") }
        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.connect() }
        _ = try await CloudCredentialSync.upload(instanceId: instanceId)
        d.set(true, forKey: CloudCredentialSync.enabledKey)
        let title = "语音：" + String(prompt.prefix(30))
        let created = try await conn.request(method: "POST", path: "/v1/sessions", body: ["title": title])
        guard let sid = created["session_id"] as? String else { throw failure("云电脑没有返回会话 ID") }
        let provider: [String: Any] = ["protocol": "chat", "credential": CloudCredentialSync.credentialName(forInstanceId: instanceId)]
        let body: [String: Any] = [
            "content": prompt,
            "model": model,
            "client_nonce": UUID().uuidString,
            "provider": provider,
            "instructions": "你运行在用户的 Linux 云电脑上，任务来自用户的实时语音通话。调用工具真实完成任务，以工具返回为准；最终回答会被朗读，请简短口语化、先说结论。",
        ]
        let resp = try await conn.request(method: "POST", path: "/v1/sessions/\(sid)/messages", body: body)
        guard let tid = resp["task_id"] as? String else { throw failure("云电脑没有返回任务 ID") }
        lastTaskId = tid
        sessionByTask[tid] = sid
        return tid
    }

    private static func progress(taskId: String) async throws -> [String: Any] {
        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.connect() }
        let task = try await conn.request(method: "GET", path: "/v1/tasks/\(taskId)", body: nil)
        let status = task["status"] as? String ?? "unknown"
        let events = task["events"] as? [[String: Any]] ?? []
        var steps = 0
        var lastTool = ""
        for e in events where e["type"] as? String == "tool_call" {
            steps += 1
            let payload = e["payload"] as? [String: Any] ?? [:]
            lastTool = payload["tool"] as? String ?? payload["name"] as? String ?? lastTool
        }
        var out: [String: Any] = ["task_id": taskId, "status": status, "tool_steps": steps]
        if !lastTool.isEmpty { out["last_tool"] = lastTool }
        if status == "waiting_user" { out["note"] = "等待用户在手机上批准" }
        if status != "running" && status != "waiting_user" {
            let sid = sessionByTask[taskId] ?? task["session_id"] as? String ?? ""
            if !sid.isEmpty {
                let detail = try await conn.request(method: "GET", path: "/v1/sessions/\(sid)", body: nil)
                let messages = detail["messages"] as? [[String: Any]] ?? []
                let last = messages.last { ($0["role"] as? String) == "assistant" && !(($0["content"] as? String) ?? "").isEmpty }
                if let text = last?["content"] as? String { out["result"] = String(text.prefix(1500)) }
            }
        }
        return out
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "CloudVoiceBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
