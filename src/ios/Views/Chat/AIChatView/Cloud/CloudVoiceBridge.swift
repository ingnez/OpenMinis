//
//  CloudVoiceBridge.swift
//  Minis - 实时语音通话 → 云电脑 Agent
//  实时语音模型通过函数调用把要真正执行的工作交给云电脑；完成后把结论交回通话由模型朗读。
//

import Foundation

@MainActor
enum CloudVoiceBridge {
    private static var lastTaskId: String?
    private static var voiceSession: (host: String, id: String)?
    private static var frontRequests: [String: (session: String, nonce: String)] = [:]

    /// 已选择云电脑服务商与模型时才向实时模型暴露云电脑工具。
    static var isAvailable: Bool {
        if CloudExperience.enabled {
            return !CloudExperience.reference("front").isEmpty && !CloudExperience.reference("back").isEmpty
        }
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
                                "note": "云电脑已接收，按后台可用名额执行。请只确认一次。"]), tid)
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
                if status == "waiting_user" || p["needs_decision"] as? Bool == true {
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

    /// 通话里的派单直接走云电脑任务接口，只有服务器确认才返回编号。
    static func startBotTask(sessionId: String, prompt: String, model: String, providerID: String?) async throws -> String {
        if CloudPrivacyScan.enabled, !CloudPrivacyScan.hits(prompt).isEmpty {
            throw failure("这条语音任务含疑似身份信息。请隐去后再发给云电脑。")
        }
        var provider: [String: Any] = [:]
        if let providerID, !CloudExperience.enabled {
            guard let inst = ProviderConfigStore.shared.instance(for: providerID), inst.isEnabled,
                  inst.providerType == .openAI, inst.credentialType == .apiKey, !inst.azureMode,
                  let key = ProviderKeychainHelper.loadAPIKey(instanceId: inst.id), !key.isEmpty else {
                throw failure("请先给这个 Bot 选择可用的云端模型和凭据。")
            }
            let base = inst.resolvedBaseURL(default: "https://api.openai.com")
            provider = ["base_url": base.appendV1 ? "\(base.url)/v1" : base.url, "api_key": key]
        }
        return try await submitWorker(sessionId: sessionId, prompt: prompt, model: model, provider: provider)
    }

    private static func submitWorker(sessionId: String, prompt: String, model: String, provider: [String: Any]) async throws -> String {
        if CloudExperience.enabled {
            let nonce = UUID().uuidString
            try await CloudConnection.shared.ensureConnected()
            var body: [String: Any] = ["content": prompt, "model": model, "provider": provider, "client_nonce": nonce]
            try CloudExperience.prepare(&body)
            do {
                let response = try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/\(sessionId)/messages", body: body)
                guard response["task_id"] is String else { throw failure("前台没有确认接收语音消息。") }
            } catch let busy as CloudSessionBusyError {
                switch await CloudInjector.inject(taskId: busy.taskId, content: prompt, nonce: nonce) {
                case .injected: break
                default: throw failure("前台暂时未接收这条语音消息，请重试。")
                }
            }
            let id = "voice_" + nonce
            frontRequests[id] = (sessionId, nonce)
            return id
        }
        let body: [String: Any] = ["goal": prompt, "model": model, "provider": provider, "client_nonce": UUID().uuidString]
        let response = try await CloudQuiet.retry(3) {
            try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/\(sessionId)/voice-tasks", body: body)
        }
        guard let worker = response["worker"] as? [String: Any], let id = worker["worker_id"] as? String else {
            throw failure("云电脑没有确认接收这条任务。")
        }
        return id
    }

    /// 云端 Bot 实时通话挂断后，把文字记录追加进这个 Bot 的会话（不会触发 Bot 运行）。
    /// 失败返回提示文字；旧服务器（2.5.0 以前）没有这个接口时提示更新。
    static func saveTranscript(sessionId: String, lines: [[String: Any]]) async -> String? {
        guard !sessionId.isEmpty, !lines.isEmpty else { return nil }
        do {
            let conn = CloudConnection.shared
            if !conn.isConnected { try await conn.connect() }
            // 同一份记录带同一个 nonce：重试时服务器不会重复写入
            let body: [String: Any] = ["lines": lines, "nonce": UUID().uuidString]
            _ = try await CloudQuiet.retry(3) {
                try await conn.request(method: "POST", path: "/v1/sessions/\(sessionId)/transcript", body: body)
            }
            return nil
        } catch {
            let text = error.localizedDescription
            if text.contains("版本过旧") {
                return "云端服务版本较旧，通话记录没有存进对话。到设置里「更新云端服务」后就能保存。"
            }
            return "通话记录没有存进对话：\(text)"
        }
    }

    private static func startTask(prompt: String) async throws -> String {
        if CloudExperience.enabled {
            let conn = CloudConnection.shared
            if !conn.isConnected { try await conn.connect() }
            let host = conn.host
            let sid: String
            if let prior = voiceSession, prior.host == host { sid = prior.id }
            else {
                let response = try await conn.request(method: "POST", path: "/v1/sessions", body: ["title": "语音对话"])
                guard let id = response["session_id"] as? String else { throw failure("云电脑没有返回语音对话 ID") }
                sid = id; voiceSession = (host, id)
            }
            let tid = try await submitWorker(sessionId: sid, prompt: prompt, model: "", provider: [:])
            lastTaskId = tid
            return tid
        }
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
        let tid = try await submitWorker(sessionId: sid, prompt: prompt, model: model, provider: provider)
        lastTaskId = tid
        return tid
    }

    private static func progress(taskId: String) async throws -> [String: Any] {
        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.connect() }
        if let request = frontRequests[taskId] {
            let ledger = try await conn.request(method: "GET", path: "/v1/sessions/\(request.session)/experience")
            let rows = ledger["requests"] as? [[String: Any]] ?? []
            if let row = rows.first(where: { $0["nonce"] as? String == request.nonce }) {
                if let worker = row["worker_id"] as? String {
                    let result = try await conn.request(method: "GET", path: "/v1/workers/\(worker)")
                    return result["worker"] as? [String: Any] ?? ["status": "running"]
                }
                if row["status"] as? String == "delivered" {
                    return ["status": "completed", "result": row["reply"] as? String ?? ""]
                }
            }
            return ["status": "running", "note": "前台已接收，正在分流"]
        }
        if taskId.hasPrefix("wk_") {
            let response = try await conn.request(method: "GET", path: "/v1/workers/\(taskId)")
            guard let worker = response["worker"] as? [String: Any] else {
                throw failure("云电脑找不到这项后台任务。")
            }
            return worker
        }
        let task = try await conn.request(method: "GET", path: "/v1/tasks/\(taskId)", body: nil)
        let status = task["status"] as? String ?? "unknown"
        let events = task["events"] as? [[String: Any]] ?? []
        if let event = events.last(where: { $0["type"] as? String == "worker_spawned" }),
           let payload = event["payload"] as? [String: Any], let wid = payload["worker_id"] as? String {
            let response = try await conn.request(method: "GET", path: "/v1/workers/\(wid)")
            if let worker = response["worker"] as? [String: Any] { return worker }
        }
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
            let sid = task["session_id"] as? String ?? ""
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
