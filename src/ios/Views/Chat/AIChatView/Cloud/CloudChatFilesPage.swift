import SwiftUI

/// 每个聊天的「文件」页：集中本对话交付物，按时间倒序，可搜索。
struct CloudChatFilesPage: View {
    let sessionId: String
    var botName: String? = nil
    var localItems: [CloudDeliverable]? = nil
    @State private var items: [CloudDeliverable] = []
    @State private var query = ""
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if loading && localItems == nil && items.isEmpty {
                ProgressView("正在加载文件…")
            } else if visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.largeTitle)
                    Text(query.isEmpty ? "还没有文件" : "没有匹配的文件")
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visible) { item in
                        CloudFileCardView(item: item, sessionId: sessionId, accent: .accentColor)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("文件")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chatFilesPage")
        .searchable(text: $query, prompt: "搜索文件名")
        .refreshable { await load() }
        .task { await load() }
        .alert("没能加载文件", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var visible: [CloudDeliverable] {
        let all = localItems ?? items
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q)
            || ($0.path?.lowercased().contains(q) ?? false)
            || ($0.title?.lowercased().contains(q) ?? false)
            || ($0.href?.lowercased().contains(q) ?? false)
            || ($0.site?.lowercased().contains(q) ?? false)
        }
    }

    private func load() async {
        guard localItems == nil else {
            loading = false
            return
        }
        loading = items.isEmpty
        do {
            let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(sessionId)/deliveries")
            let list = CloudDeliverable.parseList(res["deliveries"])
            items = list
            loading = false
        } catch {
            errorText = error.localizedDescription
            loading = false
        }
    }
}
