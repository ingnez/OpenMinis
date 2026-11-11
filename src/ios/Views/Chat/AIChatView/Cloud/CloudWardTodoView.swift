import SwiftUI

/// 查房待办箱：本班次要核对的事项。只显示标题和床号，不收集真实姓名或住院号。
struct CloudWardTodoPage: View {
    @State private var items: [CloudWardTodo] = CloudWardTodo.e2eForced ? CloudWardTodo.e2eItems() : []
    @State private var title = ""
    @State private var bed = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("待办（例如：复查血气）", text: $title)
                    .accessibilityIdentifier("wardTodoTitleField")
                TextField("床号（可选，不要写姓名）", text: $bed)
                    .accessibilityIdentifier("wardTodoBedField")
                Button("加入待办箱") { Task { await add() } }
                    .accessibilityIdentifier("wardTodoAdd")
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("给本班次要核对的事项用。不要填写患者姓名、住院号或其他身份信息。")
            }
            Section {
                ForEach(displayItems) { item in
                    HStack {
                        Button {
                            Task { await toggle(item) }
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityIdentifier("wardTodoToggle-\(item.todoId)")
                        VStack(alignment: .leading) {
                            Text(item.title)
                            if !item.bed.isEmpty {
                                Text(item.bed).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .accessibilityIdentifier("wardTodo-\(item.todoId)")
                }
            } header: {
                Text(CloudWardTodo.boxTitle(open: CloudWardTodo.totals(displayItems).open))
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("查房待办箱")
        .accessibilityIdentifier("wardTodoPage")
        .task { await load() }
        .refreshable { await load() }
    }

    private var displayItems: [CloudWardTodo] {
        if CloudWardTodo.e2eForced && items.isEmpty { return CloudWardTodo.e2eItems() }
        return items
    }

    @MainActor
    private func load() async {
        if CloudWardTodo.e2eForced { items = CloudWardTodo.e2eItems(); return }
        do {
            try await CloudConnection.shared.ensureConnected()
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/ward-todos?done=1")
            items = CloudWardTodo.list(r)
            error = nil
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func add() async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bed.trimmingCharacters(in: .whitespacesAndNewlines)
        if CloudWardTodo.e2eForced {
            items.insert(CloudWardTodo(todoId: "todo_e2elocal0001", title: t, detail: "", bed: b, done: false,
                                       createdAt: Date().timeIntervalSince1970), at: 0)
            title = ""; bed = ""
            return
        }
        do {
            try await CloudConnection.shared.ensureConnected()
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/ward-todos",
                                                         body: ["title": t, "bed": b])
            title = ""; bed = ""
            await load()
        } catch { self.error = "没加上：\(error.localizedDescription)" }
    }

    @MainActor
    private func toggle(_ item: CloudWardTodo) async {
        if CloudWardTodo.e2eForced {
            if let i = items.firstIndex(where: { $0.todoId == item.todoId }) { items[i].done.toggle() }
            return
        }
        do {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/ward-todos/\(item.todoId)/done",
                                                         body: ["done": !item.done])
            await load()
        } catch { self.error = "更新失败：\(error.localizedDescription)" }
    }
}

/// 首页上的小待办箱。
struct CloudWardTodoHomeBox: View {
    var items: [CloudWardTodo]
    var body: some View {
        let t = CloudWardTodo.totals(items)
        VStack(alignment: .leading, spacing: 6) {
            Text(CloudWardTodo.boxTitle(open: t.open)).font(.headline)
            ForEach(items.filter { !$0.done }.prefix(3)) { item in
                HStack {
                    Text(item.bed.isEmpty ? item.title : "\(item.bed) · \(item.title)")
                        .font(.subheadline)
                    Spacer()
                }
            }
            if t.open == 0 {
                Text("这一班的待办都勾完了").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("wardTodoHomeBox")
        .padding(.vertical, 4)
    }
}
