import SwiftUI

struct CloudExam: Identifiable, Equatable {
    let id: String
    var name: String
    var day: String
    var notes: String
    var daysLeft: Int

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String, let day = d["day"] as? String else { return nil }
        self.id = id
        self.name = name
        self.day = day
        notes = d["notes"] as? String ?? ""
        daysLeft = d["days_left"] as? Int ?? 0
    }
}

@MainActor
enum CloudExamService {
    /// nil = 取不到（旧服务器没有这个接口），保持原样
    static func list() async -> [CloudExam]? {
        guard let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/exams"),
              let items = r["exams"] as? [[String: Any]] else { return nil }
        return items.compactMap(CloudExam.init)
    }

    static func save(id: String?, name: String, day: String, notes: String) async throws {
        let body: [String: Any] = ["name": name, "day": day, "notes": notes]
        if let id {
            _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/exams/\(id)", body: body)
        } else {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/exams", body: body)
        }
        CloudBotHomeModel.shared.exams = await list() ?? CloudBotHomeModel.shared.exams
    }

    static func delete(_ id: String) async {
        _ = try? await CloudConnection.shared.request(method: "DELETE", path: "/v1/exams/\(id)")
        CloudBotHomeModel.shared.exams = await list() ?? CloudBotHomeModel.shared.exams
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// 首页考试看板：横向一排，越近越醒目；Bot 每一轮也会看到 30 天内的考试
struct CloudExamBoard: View {
    let exams: [CloudExam]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(exams) { e in
                    NavigationLink { CloudExamListView() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(e.daysLeft < 0 ? "已结束" : e.daysLeft == 0 ? "今天" : "\(e.daysLeft) 天")
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(e.daysLeft <= 7 && e.daysLeft >= 0 ? Color.red : Color.primary)
                            Text(e.day).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(minWidth: 96, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(e.name)，\(e.daysLeft < 0 ? "已结束" : "还有 \(e.daysLeft) 天")")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }
}

struct CloudExamListView: View {
    @ObservedObject private var model = CloudBotHomeModel.shared
    @State private var editing: CloudExam?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.exams) { e in
                    Button { editing = e } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name)
                                Text(e.day + (e.notes.isEmpty ? "" : " · " + e.notes)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(e.daysLeft < 0 ? "已结束" : "\(e.daysLeft) 天").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in
                    let ids = idx.map { model.exams[$0].id }
                    Task { for id in ids { await CloudExamService.delete(id) } }
                }
            } footer: { Text("Bot 每一轮都会看到 30 天内的考试，排复习计划、出题、排班时会考虑。结束 3 天后自动从看板消失。") }
            CloudDrillSection()
        }
        .navigationTitle("考试倒计时")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $adding) { CloudExamEditor(exam: nil) }
        .sheet(item: $editing) { CloudExamEditor(exam: $0) }
        .task { model.exams = await CloudExamService.list() ?? model.exams }
    }
}

struct CloudExamEditor: View {
    let exam: CloudExam?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var day = Date().addingTimeInterval(30 * 86400)
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("考试名称（如 主治医师）", text: $name)
                DatePicker("日期", selection: $day, displayedComponents: .date)
                TextField("科目 / 备注", text: $notes)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(exam == nil ? "添加考试" : "编辑考试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                try await CloudExamService.save(id: exam?.id, name: name.trimmingCharacters(in: .whitespaces),
                                                                day: CloudExamService.dayString(day), notes: notes)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let exam else { return }
                name = exam.name
                notes = exam.notes
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd"
                day = f.date(from: exam.day) ?? day
            }
        }
    }
}

/// 碎片复习：一键建一个例行任务，每天 10:00 / 15:00 / 22:00 推一道和考试科目、最近病例相关的选择题（通知点开就答）
struct CloudDrillSection: View {
    @State private var state: String? = nil
    @State private var busy = false

    static let prompt = "碎片复习：出 1 道单选题（4 个选项），优先结合我登记的考试科目和最近对话里复盘过的病例；题干不超过 3 行。"
        + "用 ask_choice 给选项卡片，不要先给答案。我选完后说对错、给一句话解析和出处；答错的题用一句话记进记忆的「错题本」。"
        + "不要使用任何真实病人身份信息。"

    var body: some View {
        Section {
            Button {
                busy = true
                Task {
                    do {
                        try await CloudRoutineService.create(name: "碎片复习", prompt: Self.prompt,
                                                             schedule: ["kind": "cron", "expr": "0 10,15,22 * * *", "timezone": TimeZone.current.identifier])
                        state = "已建好：每天 10:00、15:00、22:00 推一道题（在「例行任务」里可暂停或改时间）"
                        CloudHaptics.success()
                    } catch {
                        state = "没建成：\(error.localizedDescription)"
                    }
                    busy = false
                }
            } label: {
                Label(busy ? "正在创建…" : "每天推 3 道碎片复习题", systemImage: "brain.head.profile")
            }
            .disabled(busy)
            if let state { Text(state).font(.caption).foregroundStyle(.secondary) }
        } footer: { Text("值班空闲时答一道：选项卡片作答，答错的自动进错题本。") }
    }
}
