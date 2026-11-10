import SwiftUI

/// 浏览器快照：存下当前登录和打开的网页，重启桌面 / 换资料后一键恢复
struct CloudSnapshotsSheet: View {
    let sessionId: String?
    @ObservedObject private var connection = CloudConnection.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CloudBrowserSnapshot] = []
    @State private var name = ""
    @State private var busy: String?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("名字（可空，比如「医院系统已登录」）", text: $name)
                    Button { Task { await save() } } label: { Label("存下现在的浏览器", systemImage: "camera.on.rectangle") }
                } footer: { Text("保存登录 cookie 和打开的网页（最多 6 个）。cookie 只留在你的 VPS，不发到手机、不给模型看。不保存页面里没提交的表单。") }
                Section("已存的快照") {
                    if items.isEmpty { Text("还没有快照").foregroundStyle(.secondary) }
                    ForEach(items) { s in
                        Button { Task { await restore(s) } } label: {
                            VStack(alignment: .leading) {
                                Text(s.name).foregroundStyle(.primary)
                                Text("\(s.subtitle) · \(s.created.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { Task { await remove(s) } } label: { Label("删除", systemImage: "trash") } }
                    }
                }
            }
            .overlay { if let busy { ProgressView(busy).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("浏览器快照").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await reload() }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好") {} }
        }
    }

    private var scope: [String: Any] { sessionId.map { ["session_id": $0] } ?? [:] }

    private func reload() async {
        if let r = try? await connection.request(method: "GET", path: "/v1/browser/snapshots") { items = CloudBrowserSnapshot.parse(r) }
    }

    private func save() async {
        busy = "正在保存…"
        defer { busy = nil }
        var body = scope
        body["name"] = name
        do {
            _ = try await connection.request(method: "POST", path: "/v1/browser/snapshots", body: body)
            name = ""
            await reload()
        } catch { notice = error.localizedDescription }
    }

    private func restore(_ s: CloudBrowserSnapshot) async {
        busy = "正在恢复…"
        defer { busy = nil }
        do {
            let r = try await connection.request(method: "POST", path: "/v1/browser/snapshots/\(s.id)/restore", body: scope)
            notice = "已恢复登录，重新打开了 \((r["opened"] as? NSNumber)?.intValue ?? 0) 个网页"
        } catch { notice = error.localizedDescription }
    }

    private func remove(_ s: CloudBrowserSnapshot) async {
        _ = try? await connection.request(method: "DELETE", path: "/v1/browser/snapshots/\(s.id)")
        await reload()
    }
}
