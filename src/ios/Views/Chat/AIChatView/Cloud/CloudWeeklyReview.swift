import SwiftUI

/// 每周自我改进：每周日晚上，Bot 看一遍本周数据（任务失败、你给的赞踩和评论、对回答点的负面表情），
/// 写下最多 5 条改进规则存进自己的规则记忆，并用几句话告诉你改了什么。是这个 Bot 的一个例行任务。
enum CloudWeeklyReview {
    static let namePrefix = "每周自我改进"
    static let schedule: [String: Any] = ["kind": "cron", "expr": "0 21 * * 0", "timezone": TimeZone.current.identifier]

    static let prompt = """
    现在是你每周一次的自我复盘。下面是服务器统计的你本周的数据（不含对话全文）：
    {{weekly_stats}}

    请：1）找出最值得改的 1～5 个问题（比如用户点了 👎 的回答有什么共同点、哪类任务老失败、评论里提的要求）；\
    2）每个问题写成一条具体、可执行的规则，用 memory_write（category=rules）存进你自己的记忆，已有相同规则就不要重复写；\
    3）最后用三五句话告诉用户你本周学到了什么、以后会怎么做。数据不足时只回复 [SKIP]。
    """
}

@MainActor
struct CloudWeeklyReviewSection: View {
    let botId: String
    let botName: String
    @State private var routineId: String?
    @State private var enabled = false
    @State private var loaded = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Section {
            Toggle("每周自我改进", isOn: Binding(get: { enabled }, set: { v in enabled = v; apply() }))
                .disabled(!loaded || busy)
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text("每周日 21:00，\(botName.isEmpty ? "Bot" : botName) 会看一遍本周的失败、你的赞踩和评论、你对回答点的负面表情，写下改进规则存进自己的记忆，再告诉你改了什么。")
        }
        .task { await load() }
    }

    private func load() async {
        defer { loaded = true }
        guard let list = try? await CloudQuiet.retry(3, { try await CloudRoutineService.list() }),
              let r = list.first(where: { ($0["persona_id"] as? String) == botId && (($0["name"] as? String) ?? "").hasPrefix(CloudWeeklyReview.namePrefix) }) else { return }
        routineId = r["routine_id"] as? String
        enabled = r["enabled"] as? Bool ?? ((r["enabled"] as? Int) == 1)
    }

    private func apply() {
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                if let rid = routineId {
                    _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/routines/\(rid)", body: ["enabled": enabled])
                } else if enabled {
                    let r = try await CloudRoutineService.create(name: "\(CloudWeeklyReview.namePrefix) · \(botName)", prompt: CloudWeeklyReview.prompt,
                                                                 schedule: CloudWeeklyReview.schedule, personaId: botId)
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
