//
//  CloudProactive.swift
//  Minis - 主动消息：Bot 每天（或工作日）按时自己想一想要不要找你。
//  实现为这个 Bot 的一个例行任务；Bot 回复以 [SKIP] 开头 / 结尾时服务器不推送，不打扰。
//

import SwiftUI

enum CloudProactive {
    static let namePrefix = "主动消息"

    static func prompt(botName: String) -> String {
        """
        现在是你主动联系用户的时间。先用 memory_search 看看用户最近在忙什么、有什么待办、约定或关心的事，\
        需要时查一下今天的日期和相关信息。只有真正有用的才说：提醒即将到来的事、跟进之前没做完的事、\
        给一条与用户相关的有用信息。用一两句话直接说，像朋友发消息，不要寒暄、不要罗列。\
        如果没有值得打扰用户的事，只回复 [SKIP]。
        """
    }

    static func schedule(hour: Int, minute: Int, weekdaysOnly: Bool) -> [String: Any] {
        ["kind": "cron", "expr": "\(minute) \(hour) * * \(weekdaysOnly ? "1-5" : "*")", "timezone": TimeZone.current.identifier]
    }

    /// 从 cron 表达式读回时间与频率
    static func parse(_ s: [String: Any]?) -> (Int, Int, Bool)? {
        guard let expr = s?["expr"] as? String else { return nil }
        let parts = expr.split(separator: " ")
        guard parts.count == 5, let m = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (h, m, parts[4] == "1-5")
    }
}

@MainActor
struct CloudProactiveSection: View {
    let botId: String
    let botName: String
    @State private var routineId: String?
    @State private var enabled = false
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdaysOnly = false
    @State private var loaded = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Section {
            Toggle("主动找我", isOn: Binding(get: { enabled }, set: { v in enabled = v; apply() }))
                .disabled(!loaded || busy)
            if enabled {
                DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                Picker("频率", selection: $weekdaysOnly) {
                    Text("每天").tag(false)
                    Text("工作日").tag(true)
                }
                .pickerStyle(.segmented)
                Button("保存时间") { apply() }.disabled(busy)
            }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("主动消息")
        } footer: {
            Text("到点 \(botName.isEmpty ? "Bot" : botName) 会根据记忆和待办想一想要不要找你；没什么值得说的就不打扰（不推送）。")
        }
        .task { await load() }
    }

    private func load() async {
        defer { loaded = true }
        guard let list = try? await CloudQuiet.retry(3, { try await CloudRoutineService.list() }) else { return }
        guard let r = list.first(where: { ($0["persona_id"] as? String) == botId && (($0["name"] as? String) ?? "").hasPrefix(CloudProactive.namePrefix) }) else { return }
        routineId = r["routine_id"] as? String
        enabled = r["enabled"] as? Bool ?? ((r["enabled"] as? Int) == 1)
        if let p = CloudProactive.parse(r["schedule"] as? [String: Any]) {
            time = Calendar.current.date(bySettingHour: p.0, minute: p.1, second: 0, of: Date()) ?? time
            weekdaysOnly = p.2
        }
    }

    private func apply() {
        busy = true
        errorText = nil
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = CloudProactive.schedule(hour: comps.hour ?? 9, minute: comps.minute ?? 0, weekdaysOnly: weekdaysOnly)
        Task {
            defer { busy = false }
            do {
                if let rid = routineId {
                    _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/routines/\(rid)",
                                                                 body: ["enabled": enabled, "schedule": schedule])
                } else if enabled {
                    let r = try await CloudRoutineService.create(name: "\(CloudProactive.namePrefix) · \(botName)", prompt: CloudProactive.prompt(botName: botName),
                                                                 schedule: schedule, personaId: botId)
                    routineId = r["routine_id"] as? String
                }
                CloudHaptics.success()
            } catch {
                errorText = error.localizedDescription
                if routineId == nil { enabled = false }
            }
        }
    }
}
