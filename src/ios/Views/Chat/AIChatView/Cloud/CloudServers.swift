import SwiftUI

/// 多台云电脑：保存几台、逐台测负载、切到最闲的那台。同一时间只连一台（隧道端口是一套），切换会重连。
struct CloudServersView: View {
    @ObservedObject private var connection = CloudConnection.shared
    @State private var servers = CloudServerList.load()
    @State private var loads: [String: CloudServerLoad] = [:]
    @State private var failures: [String: String] = [:]
    @State private var probing: String?
    @State private var busy = false
    @State private var adding = false
    @State private var draft = CloudServerDraft.blank(count: 0)

    private var currentId: String { current.id }
    private var current: CloudServerProfile {
        CloudServerProfile(name: connection.name, host: connection.host, sshPort: connection.sshPort, username: connection.username)
    }
    private var shown: [CloudServerProfile] { CloudServerList.upsert(current, into: servers) }

    var body: some View {
        List {
            Section {
                ForEach(shown) { s in row(s) }
                    .onDelete { idx in
                        let ids = idx.map { shown[$0].id }
                        servers.removeAll { ids.contains($0.id) && $0.id != currentId }
                        CloudServerList.save(servers)
                    }
            } footer: {
                Text("密码和令牌按每台各自存在钥匙串里。同一时间只连一台，切换会重连；新建的对话和任务都在当前这台上跑。")
            }
            Section {
                Button { Task { await probeAll(thenSwitch: false) } } label: { Label("逐台测负载", systemImage: "speedometer") }
                Button { Task { await probeAll(thenSwitch: true) } } label: { Label("切到最闲的那台", systemImage: "arrow.triangle.swap") }
                Button { startAdd() } label: { Label("添加另一台", systemImage: "plus") }
                    .accessibilityIdentifier("cloudAddAnotherServer")
            }
            .disabled(busy)
        }
        .navigationTitle("多台云电脑")
        .sheet(isPresented: $adding) {
            NavigationStack {
                CloudAddServerForm(draft: $draft, onSave: saveDraft, onCancel: { adding = false })
            }
        }
        .onAppear {
            // 只把当前正在用、且地址有效的那台记进列表，不会把空草稿写成当前连接
            servers = CloudServerList.upsert(current, into: servers)
            CloudServerList.save(servers)
        }
    }

    private func row(_ s: CloudServerProfile) -> some View {
        Button { Task { await use(s) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.isEmpty ? s.host : s.name).foregroundColor(.primary)
                    Text("\(s.username)@\(s.host):\(s.sshPort)").font(.caption).foregroundColor(.secondary)
                    if let l = loads[s.id] { Text(l.summary).font(.caption2).foregroundColor(.secondary) }
                    if let f = failures[s.id] { Text(f).font(.caption2).foregroundColor(.red) }
                }
                Spacer()
                if probing == s.id { ProgressView() }
                else if s.id == currentId { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
        }
        .disabled(busy)
        .accessibilityIdentifier("cloudServer-\(s.id)")
        .accessibilityLabel(s.name.isEmpty ? s.host : s.name)
        .accessibilityValue(s.id == currentId ? "已选用" : "")
    }

    /// 点「添加另一台」只打开表单，不改当前连接、不把空草稿写入列表。
    private func startAdd() {
        draft = CloudServerDraft.blank(count: shown.count)
        adding = true
    }

    private func saveDraft() {
        let result = CloudServerDraft.commit(draft, into: servers)
        guard result.error == nil else { return }
        servers = result.list
        CloudServerList.save(servers)
        adding = false
        // 新加的那台只进列表，不切换当前正在用的
    }

    private func select(_ s: CloudServerProfile) {
        guard s.id != currentId || s.name != connection.name else { return }
        connection.name = s.name; connection.host = s.host
        connection.sshPort = s.sshPort; connection.username = s.username
    }

    private func use(_ s: CloudServerProfile) async {
        guard s.id != currentId else { return }
        busy = true; defer { busy = false }
        select(s)
        try? await connection.ensureConnected()
    }

    /// 逐台连上去读 /v1/live-stats；没存密码的跳过。测完回到原来那台，或切到最闲的
    private func probeAll(thenSwitch: Bool) async {
        busy = true; defer { busy = false; probing = nil }
        let original = current
        servers = CloudServerList.upsert(original, into: servers); CloudServerList.save(servers)
        for s in servers {
            probing = s.id
            select(s)
            guard connection.canAutoConnect else { failures[s.id] = "没存密码或令牌，先在设置里连一次"; continue }
            do {
                try await connection.ensureConnected()
                let stats = try await connection.request(method: "GET", path: "/v1/live-stats")
                if let l = CloudServerLoad(stats: stats) { loads[s.id] = l; failures[s.id] = nil }
                else { failures[s.id] = "服务器太旧，读不到负载" }
            } catch {
                failures[s.id] = error.localizedDescription; loads[s.id] = nil
            }
        }
        let target = thenSwitch ? CloudServerList.leastLoaded(loads, current: original.id) : original.id
        let pick = servers.first { $0.id == target } ?? original
        select(pick)
        try? await connection.ensureConnected()
        CloudHaptics.selection()
    }
}

/// 添加另一台时的表单：保存并通过校验才写入列表；取消或返回丢弃草稿，当前那台不动。
struct CloudAddServerForm: View {
    @Binding var draft: CloudServerProfile
    var onSave: () -> Void
    var onCancel: () -> Void
    @FocusState private var focus: Field?
    @State private var error: String?
    private enum Field: Hashable { case name, host, port, user }

    var body: some View {
        Form {
            Section {
                TextField("连接名称 (如: 我的云电脑)", text: $draft.name)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("cloudAddServerName")
                TextField("IP地址 / 域名", text: $draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focus, equals: .host)
                    .accessibilityIdentifier("cloudAddServerHost")
                HStack {
                    Text("SSH端口")
                    Spacer()
                    TextField("22", value: $draft.sshPort, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .port)
                        .accessibilityIdentifier("cloudAddServerPort")
                }
                TextField("用户名", text: $draft.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focus, equals: .user)
                    .accessibilityIdentifier("cloudAddServerUser")
            } header: {
                Text("新云电脑")
            } footer: {
                if let error {
                    Text(error).foregroundColor(.red)
                } else {
                    Text("填好并保存后才会加入列表，不会切换当前正在用的那台。取消或返回会丢掉这份草稿。")
                }
            }
        }
        .accessibilityIdentifier("cloudAddServerForm")
        .navigationTitle("添加云电脑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { onCancel() }
                    .accessibilityIdentifier("cloudAddServerCancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    if let e = CloudServerDraft.validate(draft) { error = e; return }
                    onSave()
                }
                .accessibilityIdentifier("cloudAddServerSave")
            }
        }
        .onAppear {
            DispatchQueue.main.async { focus = .name }
        }
    }
}
