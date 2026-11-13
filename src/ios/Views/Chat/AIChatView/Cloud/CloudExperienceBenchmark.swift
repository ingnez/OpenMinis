import Foundation
import SwiftUI

struct CloudExperienceBenchmarkResult: Identifiable {
    let id = UUID()
    let role: String
    let number: Int
    let firstTextMS: Int?
    let route: String
    let validContract: Bool
    let error: String?
}

/// Runs only when the user explicitly starts it, directly from the phone.
/// It does not send the examples, credentials or results to CI or analytics.
struct CloudExperienceBenchmarkView: View {
    @State private var examples = "你好\n现在几点\n用一句话解释缓存\n谢谢\n给我三个标题\n把这句话翻译成英文\n计算 12 加 30\n什么是 JSON\n今天的计划怎么安排\n好的\n整理一个项目并测试\n搜索资料并比较三个来源\n处理表格并交回文件\n帮我修复代码错误\n检查服务器部署\n生成并验证演示文稿\n整理图片并打包\n打开网站并截图\n继续上一个任务\n把报告改成十页"
    @State private var results: [CloudExperienceBenchmarkResult] = []
    @State private var running = false
    @State private var error: String?
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                TextEditor(text: $examples).frame(minHeight: 200)
                    .disabled(running)
                Text("每行一条，共 20 条。示例是编造的，可替换成自己的消息。开始后分别测试当前前台和后台配置，会产生服务商费用。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(running ? "停止比较" : "开始比较 20 条消息") {
                    if running { runTask?.cancel() }
                    else { runTask = Task { await run() } }
                }
                .accessibilityIdentifier("experienceBenchmarkRun")
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("本次结果") {
                ForEach(results) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.role == "front" ? "前台" : "后台") · 第 \(row.number) 条")
                        if let error = row.error { Text(error).foregroundStyle(.red) }
                        else {
                            Text("首字 \(row.firstTextMS.map { "\($0) ms" } ?? "未测得") · 分流 \(row.route) · 工单 \(row.validContract ? "有效" : "无效")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("模型实测")
        .onDisappear { runTask?.cancel() }
    }

    @MainActor private func run() async {
        let messages = examples.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard messages.count == 20 else { error = "请填写恰好 20 条消息，每行一条。"; return }
        running = true; results = []; error = nil
        defer { running = false; runTask = nil }
        for role in ["front", "back"] {
            for (index, content) in messages.enumerated() {
                if Task.isCancelled { return }
                do {
                    let profile = try CloudExperience.profile(entryID: CloudExperience.reference(role))
                    results.append(try await measure(role: role, number: index + 1, content: content, profile: profile))
                } catch is CancellationError { return
                } catch {
                    if Task.isCancelled { return }
                    results.append(.init(role: role, number: index + 1, firstTextMS: nil, route: "未知", validContract: false,
                                         error: error.localizedDescription))
                }
            }
        }
    }

    private func measure(role: String, number: Int, content: String, profile: [String: Any]) async throws -> CloudExperienceBenchmarkResult {
        guard let provider = profile["provider"] as? [String: String], let base = provider["base_url"],
              let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 35
        request.setValue("Bearer " + (provider["api_key"] ?? ""), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": profile["model"] ?? "", "stream": true,
            "messages": [["role": "system", "content": "判断用户消息：简单问题 route=answer，操作或多步任务 route=work。只输出 JSON。"
                + "answer 格式 {\"route\":\"answer\",\"reply\":\"简短回答\"}。work 格式 {\"route\":\"work\",\"workorder\":{"
                + "\"workstream\":\"稳定代号\",\"goal\":\"目标\",\"context\":\"背景\",\"success_criteria\":[\"可验证标准\"],\"report_back\":\"结果与证据\"}}。"],
                         ["role": "user", "content": content]]])
        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        var first: Int?, text = "", raw = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if Date().timeIntervalSince(started) > 35 { throw URLError(.timedOut) }
            guard line.hasPrefix("data:") else { raw += line; continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = item["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty else { continue }
            if first == nil { first = Int(Date().timeIntervalSince(started) * 1000) }
            text += piece
        }
        if text.isEmpty, let data = raw.data(using: .utf8), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = item["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] {
            text = message["content"] as? String ?? ""
            // Non-streaming fallback cannot establish first-visible-token latency.
        }
        let json = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let route = json?["route"] as? String ?? "未知"
        let order = json?["workorder"] as? [String: Any]
        let valid = route == "answer" ? !(json?["reply"] as? String ?? "").isEmpty : Self.valid(order)
        return .init(role: role, number: number, firstTextMS: first, route: route, validContract: valid, error: nil)
    }

    static func valid(_ order: [String: Any]?) -> Bool {
        guard let order, let criteria = order["success_criteria"] as? [String], !criteria.isEmpty,
              criteria.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              order["context"] is String else { return false }
        return ["workstream", "goal", "report_back"].allSatisfy { !(order[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
