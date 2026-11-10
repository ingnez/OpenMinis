import SwiftUI

/// 每条回复的耗时：服务器在会话详情的 tasks[].timings 里返回（首字、总时长、token）
enum CloudLatency {
    static func ms(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    static func format(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.1f 秒", ms / 1000) : "\(Int(ms)) 毫秒"
    }

    /// 找到产生这条回复的任务（创建时间不晚于消息时间的最近一个任务）
    static func timings(for message: [String: Any], tasks: [[String: Any]]) -> [String: Any]? {
        guard let ts = ms(message["timestamp"]) else { return nil }
        let candidates = tasks.filter { (ms($0["created_at"]) ?? .infinity) <= ts + 0.001 }
        let best = candidates.max { (ms($0["created_at"]) ?? 0) < (ms($1["created_at"]) ?? 0) }
        return best?["timings"] as? [String: Any]
    }

    static func line(for message: [String: Any], tasks: [[String: Any]]) -> String? {
        guard let t = timings(for: message, tasks: tasks) else { return nil }
        var parts: [String] = []
        if let f = ms(t["first_text_ms"]) { parts.append("首字 \(format(f))") }
        if let total = ms(t["total_ms"]) { parts.append("总 \(format(total))") }
        let tokens = Int(ms(t["prompt_tokens"]) ?? 0) + Int(ms(t["completion_tokens"]) ?? 0)
        if tokens > 0 { parts.append("\(tokens) tokens") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 设置 > 云电脑资源设置 > 性能：最近任务的耗时、连接复用情况和提速开关
struct CloudPerfView: View {
    @State private var data: [String: Any] = [:]
    @State private var error: String?
    @State private var loading = false
    @State private var stream = true
    @State private var lazyTools = true
    @State private var parallelTools = true
    @State private var promptCache = true
    @State private var trimTokens = 48000
    @State private var loaded = false
    @State private var clientTick = 0
    @State private var autoTitle = true
    @State private var autoModel = false
    @State private var quickAck = true
    @State private var fastModel = ""
    @State private var strongModel = ""
    @State private var visionModel = ""
    @State private var failover: [[String: Any]] = []

    private var recent: [[String: Any]] { data["recent"] as? [[String: Any]] ?? [] }
    private var median: [String: Any] { data["median"] as? [String: Any] ?? [:] }
    private var pool: [String: Any] { data["pool"] as? [String: Any] ?? [:] }

    var body: some View {
        List {
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Section {
                row("首字（中位数）", median["first_text_ms"])
                row("模型首个 token", median["ttft_ms"])
                row("整个任务", median["total_ms"])
                row("排队", median["queued_ms"])
                HStack {
                    Text("每次请求输入 token")
                    Spacer()
                    Text(CloudLatency.ms(median["prompt_tokens"]).map { "\(Int($0))" } ?? "—").foregroundStyle(.secondary)
                }
                HStack {
                    Text("缓存命中输入 token")
                    Spacer()
                    Text(CloudLatency.ms(median["cached_tokens"]).map { "\(Int($0))" } ?? "—").foregroundStyle(.secondary)
                }
                HStack {
                    Text("连接复用")
                    Spacer()
                    Text("新建 \(pool["new"] as? Int ?? 0) · 复用 \(pool["reused"] as? Int ?? 0)").foregroundStyle(.secondary)
                }
            } header: { Text("最近 \(recent.count) 个任务") } footer: {
                Text("数据来自云端服务器内存，重启服务后清空。长按聊天里的回复也能看到那一条的耗时。")
            }
            Section {
                clientRow("本地云电脑 · 首字", mode: "local", kind: "first_text")
                clientRow("Minis Bot · 首字", mode: "bot", kind: "first_text")
                clientRow("本地云电脑 · 整个任务", mode: "local", kind: "total")
                clientRow("Minis Bot · 整个任务", mode: "bot", kind: "total")
                clientRow("冷启动到首页出现", mode: "app", kind: "cold_start")
                clientRow("隧道重连耗时", mode: "link", kind: "reconnect")
                clientRow("回到前台 · 探测隧道", mode: "link", kind: "foreground_probe")
                clientRow("复用 SSH 主连接", mode: "link", kind: "reuse")
                Button("清空本机实测", role: .destructive) { CloudClientMetrics.clear(); clientTick += 1 }
            } header: { Text("本机实测（中位数 · 样本数）") } footer: {
                Text("在这台手机上实际测得：从点发送到第一段文字出现、到任务结束，以及隧道断开后重建的耗时。两种模式用同一条事件管线，口径相同。")
            }
            Section("提速开关") {
                Toggle("流式输出（边生成边显示）", isOn: $stream).onChange(of: stream) { v in save(["stream": v]) }
                Toggle("按需发送工具定义", isOn: $lazyTools).onChange(of: lazyTools) { v in save(["lazy_tools": v]) }
                Toggle("只读工具并行执行", isOn: $parallelTools).onChange(of: parallelTools) { v in save(["parallel_tools": v]) }
                Toggle("提示缓存", isOn: $promptCache).onChange(of: promptCache) { v in save(["prompt_cache": v]) }
                Stepper(value: $trimTokens, in: 0...200000, step: 8000) {
                    Text(trimTokens == 0 ? "长对话自动精简：关闭" : "超过约 \(trimTokens / 1000)k token 时精简")
                }
                .onChange(of: trimTokens) { v in save(["context_trim_tokens": v == 0 || v >= 4000 ? v : 8000]) }
            }
            Section {
                Toggle("自动给对话起标题", isOn: $autoTitle).onChange(of: autoTitle) { v in save(["auto_title": v]) }
                HStack {
                    Text("小模型")
                    TextField("留空：只截取首句", text: $fastModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { save(["fast_model": fastModel.trimmingCharacters(in: .whitespaces)]) }
                }
                HStack {
                    Text("难题强模型")
                    TextField("留空：只调高思考深度", text: $strongModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { save(["strong_model": strongModel.trimmingCharacters(in: .whitespaces)]) }
                }
                HStack {
                    Text("看图模型")
                    TextField("留空：自动选能看图的", text: $visionModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { save(["vision_model": visionModel.trimmingCharacters(in: .whitespaces)]) }
                }
                Toggle("自动选模型（简单题小模型，难题强模型）", isOn: $autoModel).onChange(of: autoModel) { v in save(["auto_model": v]) }
                Toggle("先回一句（小模型秒回确认）", isOn: $quickAck).onChange(of: quickAck) { v in save(["quick_ack": v]) }
                    .disabled(fastModel.trimmingCharacters(in: .whitespaces).isEmpty)
                NavigationLink { CloudFailoverView(initial: failover) } label: {
                    HStack { Text("备用服务商"); Spacer(); Text(failover.isEmpty ? "未设置" : "\(failover.count) 个").foregroundStyle(.secondary) }
                }
                NavigationLink { CloudRelayCheckView() } label: { Label("中转站体检", systemImage: "stethoscope") }
            } header: { Text("提效") } footer: {
                Text("小模型用于起标题；打开「自动选模型」后，打招呼、一句话问答这类短问题交给小模型（更快更省）；推导、鉴别诊断、架构设计这类难题换用「难题强模型」并把思考深度调到高（没填强模型就只调高思考深度，值班和快速模式下不调）。小模型或强模型出错时本次自动回到主模型。「先回一句」：主模型 1.5 秒还没开始说话时，小模型先回一句简短确认。小模型与当前对话同一服务商（如 gpt-4.1-mini、qwen-turbo、deepseek-chat）。备用服务商：主模型连续出错（5xx、限流、超时、断连）时自动依次换用。提示缓存对 Claude、Qwen 加缓存标记，GPT 系按 Bot 固定缓存键，DeepSeek / Gemini / GLM 自动命中。")
            }
            Section("最近任务") {
                if recent.isEmpty { Text("还没有记录，发一条消息后再来看").foregroundStyle(.secondary) }
                ForEach(Array(recent.prefix(30).enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r["model"] as? String ?? "") · \(r["status"] as? String ?? "")").font(.subheadline)
                        Text(detail(r)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("性能")
        .refreshable { clientTick += 1; await load() }
        .task { await load() }
    }

    private func clientRow(_ title: String, mode: String, kind: String) -> some View {
        let m = clientTick >= 0 ? CloudClientMetrics.median(mode: mode, kind: kind) : nil
        return HStack {
            Text(title)
            Spacer()
            Text(m.map { "\(CloudLatency.format($0.ms)) · \($0.count) 次" } ?? "—").foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ v: Any?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(CloudLatency.ms(v).map { CloudLatency.format($0) } ?? "—").foregroundStyle(.secondary)
        }
    }

    private func detail(_ r: [String: Any]) -> String {
        var parts: [String] = []
        if let f = CloudLatency.ms(r["first_text_ms"]) { parts.append("首字 \(CloudLatency.format(f))") }
        if let t = CloudLatency.ms(r["total_ms"]) { parts.append("总 \(CloudLatency.format(t))") }
        parts.append("调用 \(r["llm_calls"] as? Int ?? 0) 次")
        parts.append("工具定义 \(r["tool_defs"] as? Int ?? 0) 个")
        let tok = Int(CloudLatency.ms(r["prompt_tokens"]) ?? 0) + Int(CloudLatency.ms(r["completion_tokens"]) ?? 0)
        if tok > 0 { parts.append("\(tok) tokens") }
        if (r["streamed"] as? Bool) == true { parts.append("流式") }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            try await CloudConnection.shared.ensureConnected()
            data = try await CloudConnection.shared.request(method: "GET", path: "/v1/perf")
            let s = data["settings"] as? [String: Any] ?? [:]
            loaded = false
            stream = s["stream"] as? Bool ?? true
            lazyTools = s["lazy_tools"] as? Bool ?? true
            parallelTools = s["parallel_tools"] as? Bool ?? true
            promptCache = s["prompt_cache"] as? Bool ?? true
            trimTokens = s["context_trim_tokens"] as? Int ?? 48000
            autoTitle = s["auto_title"] as? Bool ?? true
            fastModel = s["fast_model"] as? String ?? ""
            visionModel = s["vision_model"] as? String ?? ""
            strongModel = s["strong_model"] as? String ?? ""
            autoModel = s["auto_model"] as? Bool ?? false
            quickAck = s["quick_ack"] as? Bool ?? true
            failover = s["failover"] as? [[String: Any]] ?? []
            error = nil
            DispatchQueue.main.async { loaded = true }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ patch: [String: Any]) {
        guard loaded else { return }
        Task { @MainActor in
            do {
                _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/resources", body: patch)
            } catch {
                self.error = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
