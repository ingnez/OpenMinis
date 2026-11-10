//
//  CloudResources.swift
//  Minis - 云电脑资源设置：服务器配置检测、按配置推荐、并发 / 排队 / CPU / 内存 / 超时 / 屏幕 / 端口 / 镜像，
//  全部可调（0 = 不限），每行可恢复默认；每个 Bot 可单独覆盖。
//

import SwiftUI

struct CloudBotResourceValues: Codable, Equatable {
    var max_tasks_per_bot: Int?
    var queue_cap: Int?
    var cpu_percent: Int?
    var memory_mb: Int?
    var task_timeout_min: Int?
    var bg_jobs_max: Int?
    var browser_profile: String?
    /// 风险操作：auto = 一律批准（默认），ask = 先问我。旧服务器没有这个字段时为 nil，不显示。
    var approval_mode: String?
}

struct CloudResourceSettings: Codable, Equatable {
    var max_tasks_total: Int
    var max_bots_running: Int
    var system_lock: Bool
    var bot_defaults: CloudBotResourceValues
    var bot_overrides: [String: CloudBotResourceValues]
    var max_displays: Int
    var display_idle_min: Int
    var resolution: String
    var browser_warm: Bool
    var port_base: Int
    var port_range: Int
    var mirror: String
    var mirror_pip: String
    var mirror_npm: String
    // Bot 协作与群聊（旧服务器没有这些字段时为 nil，不显示对应行）
    var delegation_max_hops: Int?
    var delegation_pair_per_10min: Int?
    var group_max_bot_turns: Int?
    var group_tokens_per_min: Int?
    var group_max_concurrent: Int?
    var group_activity: String?

    static func decode(_ object: Any?) -> CloudResourceSettings? {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(CloudResourceSettings.self, from: data)
    }

    /// PUT 请求体（不含 bot_overrides，覆盖项在 Bot 页单独提交）
    var body: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        obj.removeValue(forKey: "bot_overrides")
        return obj
    }
}

/// 一行数字设置：步进 + 输入框 + 单位；0 显示为「不限」；与默认值不同时显示恢复按钮
struct CloudNumberRow: View {
    let title: String
    var unit: String = ""
    @Binding var value: Int
    let defaultValue: Int?
    var step: Int = 1
    var range: ClosedRange<Int> = 0...100000
    var zeroMeansUnlimited = true
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                TextField("", value: $value, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
                    .foregroundStyle(zeroMeansUnlimited && value == 0 ? Color.secondary : Color.primary)
                Text(zeroMeansUnlimited && value == 0 ? "不限" : unit).font(.footnote).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .leading)
                Stepper("", value: $value, in: range, step: step).labelsHidden()
                if let defaultValue, value != defaultValue {
                    Button { value = defaultValue } label: { Image(systemName: "arrow.uturn.backward.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("恢复默认 \(defaultValue)")
                }
            }
            if let footnote { Text(footnote).font(.caption2).foregroundStyle(.secondary) }
        }
        .onChange(of: value) { v in value = min(max(v, range.lowerBound), range.upperBound) }
    }
}

enum CloudResourceService {
    static func load() async throws -> [String: Any] {
        try await CloudBotService.connected().request(method: "GET", path: "/v1/resources", body: nil)
    }

    static func save(_ body: [String: Any]) async throws -> [String: Any] {
        try await CloudBotService.connected().request(method: "PUT", path: "/v1/resources", body: body)
    }

    static func mb(_ v: Int) -> String {
        v >= 1024 ? String(format: "%.1f GB", Double(v) / 1024) : "\(v) MB"
    }
}

struct CloudResourceSettingsView: View {
    @State private var draft: CloudResourceSettings?
    @State private var saved: CloudResourceSettings?
    @State private var defaults: CloudResourceSettings?
    @State private var recommended: [String: Any] = [:]
    @State private var specs: [String: Any] = [:]
    @State private var usage: [String: Any] = [:]
    @State private var perBotDisplay = false
    @State private var errorText: String?
    @State private var info: String?
    @State private var saving = false

    static func opt(_ b: Binding<Int?>, _ fallback: Int) -> Binding<Int> {
        Binding(get: { b.wrappedValue ?? fallback }, set: { b.wrappedValue = $0 })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("CPU", value: "\(specs["cpu_cores"] as? Int ?? 0) 核")
                LabeledContent("内存", value: CloudResourceService.mb(specs["memory_mb"] as? Int ?? 0)
                               + "（可用 \(CloudResourceService.mb(specs["memory_available_mb"] as? Int ?? 0))）")
                LabeledContent("磁盘可用", value: CloudResourceService.mb(specs["disk_free_mb"] as? Int ?? 0))
                LabeledContent("负载 (1 分钟)", value: String(format: "%.2f", (specs["load_1m"] as? NSNumber)?.doubleValue ?? 0))
                LabeledContent("资源限制方式", value: (specs["systemd_scope"] as? Bool ?? false) ? "systemd 临时 scope" : "setrlimit（回退）")
                Button { applyRecommended() } label: { Label("按配置推荐", systemImage: "wand.and.stars") }
                    .disabled(draft == nil || recommended.isEmpty)
            } header: {
                Text("服务器配置")
            } footer: {
                Text("推荐值只填进下面的表单，点「保存」后生效。")
            }

            Section {
                NavigationLink { CloudPerfView() } label: { Label("性能", systemImage: "speedometer") }
                NavigationLink { CloudProxyView() } label: { Label("代理", systemImage: "network.badge.shield.half.filled") }
            } footer: {
                Text("首字时间、任务耗时、token 用量，以及流式输出、按需工具等提速开关。代理：国内服务器访问 GitHub 慢时，导入节点让 Bot 的终端和浏览器经代理访问。")
            }

            Section("当前使用") {
                LabeledContent("运行中任务", value: "\(usage["running_tasks"] as? Int ?? 0)")
                LabeledContent("排队中", value: "\(usage["queued_tasks"] as? Int ?? 0)")
                LabeledContent("运行中的 Bot", value: "\(usage["running_bots"] as? Int ?? 0)")
                LabeledContent("打开的独立屏幕", value: "\(usage["displays_open"] as? Int ?? 0)")
                LabeledContent("后台命令", value: "\(usage["background_jobs"] as? Int ?? 0)")
            }

            if let d = Binding($draft), let def = defaults {
                Section {
                    CloudNumberRow(title: "同时运行任务（总）", unit: "个", value: d.max_tasks_total, defaultValue: def.max_tasks_total, range: 0...256)
                    CloudNumberRow(title: "同时运行的 Bot", unit: "个", value: d.max_bots_running, defaultValue: def.max_bots_running, range: 0...256)
                    Toggle("系统级安装全局锁", isOn: d.system_lock)
                } header: {
                    Text("全局")
                } footer: {
                    Text("全局锁开启时，apt / pip / npm -g / systemctl 等系统级操作同一时间只让一个 Bot 执行。")
                }

                Section {
                    CloudBotResourceRows(values: d.bot_defaults, defaults: def.bot_defaults)
                } header: {
                    Text("每个 Bot 默认")
                } footer: {
                    Text("风险操作默认「一律批准」，想让删除、对外发消息等操作先等你确认就改成「先问我」。每个 Bot 的资料页 … → 资源限制 可以单独覆盖。同一个 Bot 允许多个任务同时运行时，额外的任务用独立子工作区和独立屏幕。")
                }

                Section {
                    CloudNumberRow(title: "最多独立屏幕", unit: "个", value: d.max_displays, defaultValue: def.max_displays, range: 0...64)
                    CloudNumberRow(title: "空闲后关闭", unit: "分钟", value: d.display_idle_min, defaultValue: def.display_idle_min, range: 0...1440)
                    Picker("分辨率", selection: d.resolution) {
                        ForEach(["1024x768", "1280x800", "1440x900", "1600x1000", "1920x1080", "2560x1440"], id: \.self) { Text($0).tag($0) }
                        if !["1024x768", "1280x800", "1440x900", "1600x1000", "1920x1080", "2560x1440"].contains(d.resolution.wrappedValue) {
                            Text(d.resolution.wrappedValue).tag(d.resolution.wrappedValue)
                        }
                    }
                    Toggle("启动后预热浏览器", isOn: d.browser_warm)
                } header: {
                    Text("浏览器与屏幕")
                } footer: {
                    Text(perBotDisplay ? "Bot 选择「独立浏览器」时会得到自己的屏幕；共享模式下所有 Bot 共用登录状态，浏览器在主屏，各自用自己的标签页。"
                         : "服务器没有安装 Xvfb / x11vnc，独立屏幕不可用；请先安装 / 更新云电脑桌面环境。")
                }

                Section {
                    CloudNumberRow(title: "端口起点", value: d.port_base, defaultValue: def.port_base, step: 100, range: 1024...64000, zeroMeansUnlimited: false)
                    CloudNumberRow(title: "每个 Bot 端口数", unit: "个", value: d.port_range, defaultValue: def.port_range, range: 1...1000, zeroMeansUnlimited: false)
                } header: {
                    Text("开发端口")
                } footer: {
                    Text("第 N 个 Bot 使用 起点 + N × 端口数 开始的一段端口，自动跳过 18765 / 18766。")
                }

                Section {
                    Picker("镜像", selection: d.mirror) {
                        Text("官方源").tag("official")
                        Text("国内镜像（阿里云 PyPI / npmmirror）").tag("china")
                        Text("自定义").tag("custom")
                    }
                    if d.mirror.wrappedValue == "custom" {
                        TextField("pip 镜像地址 https://…", text: d.mirror_pip).keyboardType(.URL).textInputAutocapitalization(.never)
                        TextField("npm 镜像地址 https://…", text: d.mirror_npm).keyboardType(.URL).textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("缓存与镜像")
                } footer: {
                    Text("pip / npm / Playwright 缓存在所有 Bot 之间共用。")
                }
            }

            if let d = Binding($draft), let def = defaults, def.group_activity != nil {
                Section {
                    CloudNumberRow(title: "最多委托层数", unit: "层", value: Self.opt(d.delegation_max_hops, 3), defaultValue: def.delegation_max_hops,
                                   range: 0...10, zeroMeansUnlimited: false)
                    CloudNumberRow(title: "同一对 Bot 每 10 分钟", unit: "次", value: Self.opt(d.delegation_pair_per_10min, 10),
                                   defaultValue: def.delegation_pair_per_10min, range: 0...1000)
                } header: {
                    Text("Bot 之间协作")
                } footer: {
                    Text("Bot 可以给其他 Bot 发消息或委托任务；层数为 0 表示不允许 Bot 之间委托。用户取消任务时，它委托出去的任务会一起取消。")
                }

                Section {
                    Picker("活跃度", selection: Binding(get: { d.wrappedValue.group_activity ?? "normal" },
                                                      set: { d.wrappedValue.group_activity = $0 })) {
                        Text("安静").tag("quiet")
                        Text("正常").tag("normal")
                        Text("活跃").tag("lively")
                    }
                    CloudNumberRow(title: "每条消息最多 Bot 发言", unit: "条", value: Self.opt(d.group_max_bot_turns, 6),
                                   defaultValue: def.group_max_bot_turns, range: 0...100)
                    CloudNumberRow(title: "每分钟 token 预算", unit: "tokens", value: Self.opt(d.group_tokens_per_min, 60000),
                                   defaultValue: def.group_tokens_per_min, step: 5000, range: 0...10_000_000)
                    CloudNumberRow(title: "同时回复的 Bot", unit: "个", value: Self.opt(d.group_max_concurrent, 2),
                                   defaultValue: def.group_max_concurrent, range: 0...32)
                } header: {
                    Text("群聊")
                } footer: {
                    Text("被 @ 的 Bot 一定回复，其余按话题相关度和活跃度随机接话、点表情。每个群也可以在群设置里单独选活跃度。")
                }
            }

            if let info { Section { Text(info).font(.footnote).foregroundStyle(.green) } }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("云电脑资源设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "保存中" : "保存") { save() }.disabled(draft == nil || draft == saved || saving)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let resp = try await CloudResourceService.load()
            saved = CloudResourceSettings.decode(resp["settings"])
            draft = saved
            defaults = CloudResourceSettings.decode(resp["defaults"])
            recommended = resp["recommended"] as? [String: Any] ?? [:]
            specs = resp["specs"] as? [String: Any] ?? [:]
            usage = resp["usage"] as? [String: Any] ?? [:]
            perBotDisplay = resp["per_bot_display"] as? Bool ?? false
            errorText = draft == nil ? "服务器版本过旧，请先「安装 / 更新服务器 Agent 服务」" : nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func applyRecommended() {
        guard let current = draft else { return }
        var obj = current.body
        for (k, v) in recommended {
            if k == "bot_defaults", let bd = v as? [String: Any], var cur = obj[k] as? [String: Any] {
                cur.merge(bd) { _, new in new }
                obj[k] = cur
            } else {
                obj[k] = v
            }
        }
        obj["bot_overrides"] = [String: Any]()
        if var next = CloudResourceSettings.decode(obj) {
            next.bot_overrides = current.bot_overrides
            draft = next
            info = "已按 \(specs["cpu_cores"] as? Int ?? 0) 核 / \(CloudResourceService.mb(specs["memory_mb"] as? Int ?? 0)) 填入推荐值，点保存生效。"
        }
    }

    private func save() {
        guard let draft else { return }
        saving = true
        Task {
            do {
                let resp = try await CloudResourceService.save(draft.body)
                saved = CloudResourceSettings.decode(resp["settings"]) ?? draft
                self.draft = saved
                usage = resp["usage"] as? [String: Any] ?? usage
                info = "已保存，立即生效。"
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}

/// 每 Bot 的资源行（默认值编辑用）
struct CloudBotResourceRows: View {
    @Binding var values: CloudBotResourceValues
    let defaults: CloudBotResourceValues

    var body: some View {
        CloudNumberRow(title: "同一 Bot 并发任务", unit: "个", value: int(\.max_tasks_per_bot, 1), defaultValue: defaults.max_tasks_per_bot, range: 1...64, zeroMeansUnlimited: false)
        CloudNumberRow(title: "排队上限", unit: "个", value: int(\.queue_cap, 0), defaultValue: defaults.queue_cap, range: 0...10000)
        CloudNumberRow(title: "CPU 配额", unit: "%", value: int(\.cpu_percent, 0), defaultValue: defaults.cpu_percent, step: 50, range: 0...102400,
                       footnote: "100% = 1 核")
        CloudNumberRow(title: "内存上限", unit: "MB", value: int(\.memory_mb, 0), defaultValue: defaults.memory_mb, step: 256, range: 0...4_194_304)
        CloudNumberRow(title: "任务超时", unit: "分钟", value: int(\.task_timeout_min, 0), defaultValue: defaults.task_timeout_min, step: 5, range: 0...100000)
        CloudNumberRow(title: "后台命令数", unit: "个", value: int(\.bg_jobs_max, 0), defaultValue: defaults.bg_jobs_max, range: 0...1000)
        Picker("浏览器资料", selection: Binding(get: { values.browser_profile ?? "shared" }, set: { values.browser_profile = $0 })) {
            Text("共享登录").tag("shared")
            Text("独立浏览器与屏幕").tag("per_bot")
        }
        if values.approval_mode != nil {
            Picker("风险操作", selection: Binding(get: { values.approval_mode ?? "auto" }, set: { values.approval_mode = $0 })) {
                Text("一律批准").tag("auto")
                Text("先问我").tag("ask")
            }
        }
    }

    private func int(_ key: WritableKeyPath<CloudBotResourceValues, Int?>, _ fallback: Int) -> Binding<Int> {
        Binding(get: { values[keyPath: key] ?? fallback }, set: { values[keyPath: key] = $0 })
    }
}

/// 某个 Bot 的资源覆盖：每项可选「跟随默认」或单独设置
struct CloudBotResourceView: View {
    let botId: String
    let botName: String
    @State private var defaults: CloudBotResourceValues?
    @State private var overrides = CloudBotResourceValues()
    @State private var savedOverrides = CloudBotResourceValues()
    @State private var errorText: String?
    @State private var saving = false

    private struct Item {
        let title: String
        let unit: String
        let key: WritableKeyPath<CloudBotResourceValues, Int?>
        let name: String
        let step: Int
        let range: ClosedRange<Int>
        let zeroUnlimited: Bool
    }

    private let items: [Item] = [
        Item(title: "同一 Bot 并发任务", unit: "个", key: \.max_tasks_per_bot, name: "max_tasks_per_bot", step: 1, range: 1...64, zeroUnlimited: false),
        Item(title: "排队上限", unit: "个", key: \.queue_cap, name: "queue_cap", step: 1, range: 0...10000, zeroUnlimited: true),
        Item(title: "CPU 配额", unit: "%", key: \.cpu_percent, name: "cpu_percent", step: 50, range: 0...102400, zeroUnlimited: true),
        Item(title: "内存上限", unit: "MB", key: \.memory_mb, name: "memory_mb", step: 256, range: 0...4_194_304, zeroUnlimited: true),
        Item(title: "任务超时", unit: "分钟", key: \.task_timeout_min, name: "task_timeout_min", step: 5, range: 0...100000, zeroUnlimited: true),
        Item(title: "后台命令数", unit: "个", key: \.bg_jobs_max, name: "bg_jobs_max", step: 1, range: 0...1000, zeroUnlimited: true),
    ]

    var body: some View {
        Form {
            if let defaults {
                ForEach(items.indices, id: \.self) { i in
                    let item = items[i]
                    Section {
                        Toggle("单独设置", isOn: Binding(get: { overrides[keyPath: item.key] != nil },
                                                      set: { overrides[keyPath: item.key] = $0 ? (defaults[keyPath: item.key] ?? 0) : nil }))
                        if overrides[keyPath: item.key] != nil {
                            CloudNumberRow(title: item.title, unit: item.unit,
                                           value: Binding(get: { overrides[keyPath: item.key] ?? 0 }, set: { overrides[keyPath: item.key] = $0 }),
                                           defaultValue: defaults[keyPath: item.key], step: item.step, range: item.range, zeroMeansUnlimited: item.zeroUnlimited)
                        } else {
                            LabeledContent(item.title, value: label(defaults[keyPath: item.key] ?? 0, item) + "（默认）")
                        }
                    }
                }
                Section {
                    Picker("浏览器资料", selection: Binding(get: { overrides.browser_profile ?? "default" },
                                                         set: { overrides.browser_profile = $0 == "default" ? nil : $0 })) {
                        Text("跟随默认（\(defaults.browser_profile == "per_bot" ? "独立" : "共享")）").tag("default")
                        Text("共享登录").tag("shared")
                        Text("独立浏览器与屏幕").tag("per_bot")
                    }
                } footer: {
                    Text("独立模式下这个 Bot 有自己的浏览器资料（登录状态不与其他 Bot 共享）和自己的屏幕，「电脑」页显示它的屏幕。")
                }
                if defaults.approval_mode != nil {
                    Section {
                        Picker("风险操作", selection: Binding(get: { overrides.approval_mode ?? "default" },
                                                          set: { overrides.approval_mode = $0 == "default" ? nil : $0 })) {
                            Text("跟随默认（\(defaults.approval_mode == "ask" ? "先问我" : "一律批准")）").tag("default")
                            Text("一律批准").tag("auto")
                            Text("先问我").tag("ask")
                        }
                    } footer: {
                        Text("一律批准：删除文件、对外发消息等风险操作不再弹审批卡，直接执行（任务事件里留一条批准记录）。先问我：按审批规则暂停，等你在手机上批准。")
                    }
                }
            } else if errorText == nil {
                ProgressView()
            }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("\(botName) · 资源限制")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "保存中" : "保存") { save() }.disabled(overrides == savedOverrides || saving)
            }
        }
        .task { await load() }
    }

    private func label(_ v: Int, _ item: Item) -> String {
        item.zeroUnlimited && v == 0 ? "不限" : "\(v) \(item.unit)"
    }

    private func load() async {
        do {
            let resp = try await CloudResourceService.load()
            let s = CloudResourceSettings.decode(resp["settings"])
            defaults = s?.bot_defaults
            overrides = s?.bot_overrides[botId] ?? CloudBotResourceValues()
            savedOverrides = overrides
            errorText = s == nil ? "服务器版本过旧，请先更新服务器 Agent 服务" : nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() {
        var body: [String: Any] = [:]
        for item in items {
            if let v = overrides[keyPath: item.key] { body[item.name] = v } else { body[item.name] = NSNull() }
        }
        body["browser_profile"] = overrides.browser_profile ?? NSNull()
        if defaults?.approval_mode != nil { body["approval_mode"] = overrides.approval_mode ?? NSNull() }
        saving = true
        Task {
            do {
                _ = try await CloudResourceService.save(["bot_overrides": [botId: body]])
                savedOverrides = overrides
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}
