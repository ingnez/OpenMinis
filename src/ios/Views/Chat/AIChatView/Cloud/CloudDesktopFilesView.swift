import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 「文件」面板：手机照片 / 文件 → 云电脑「下载」文件夹；云电脑下载的文件 → 手机
struct CloudDesktopFilesSheet: View {
    @ObservedObject private var connection = CloudConnection.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CloudDesktopFiles.Item] = []
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var busy: String?
    @State private var notice: String?
    @State private var fetched: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                        Label("从相册发一张", systemImage: "photo")
                    }
                    Button { importing = true } label: { Label("从「文件」发一个", systemImage: "folder") }
                } header: { Text("发到云电脑") } footer: { Text("放进云电脑的「下载」文件夹，桌面上的浏览器上传框里就能选到。≤ 20 MB。") }
                Section("云电脑最近下载") {
                    if items.isEmpty { Text("还没有文件").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        Button { Task { await fetch(item) } } label: { row(item) }
                    }
                }
                if let fetched {
                    Section("已取回") {
                        ShareLink(item: fetched) { Label("存到手机 / 分享 \(fetched.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .overlay { if let busy { ProgressView(busy).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("文件").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await reload() }
            .task { await reload() }
            .onChange(of: photo) { p in if let p { Task { await sendPhoto(p) } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { r in
                if case .success(let url) = r { Task { await sendFile(url) } }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好") {} }
        }
    }

    private func row(_ item: CloudDesktopFiles.Item) -> some View {
        HStack {
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(item.name).lineLimit(1).foregroundStyle(.primary)
                Text("\(CloudDesktopFiles.sizeText(item.bytes)) · \(item.modified.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.down.circle")
        }
    }

    private func reload() async {
        if let r = try? await connection.request(method: "GET", path: "/v1/desktop/files") { items = CloudDesktopFiles.parse(r) }
    }

    private func sendPhoto(_ p: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await p.loadTransferable(type: Data.self) else { notice = "读不出这张照片"; return }
        let ext = p.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        await upload(name: "手机照片-\(Int(Date().timeIntervalSince1970)).\(ext)", data: data)
    }

    private func sendFile(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { notice = "读不出这个文件"; return }
        await upload(name: url.lastPathComponent, data: data)
    }

    private func upload(name: String, data: Data) async {
        busy = "正在发到云电脑…"
        defer { busy = nil }
        do {
            let body = try CloudDesktopFiles.uploadBody(name: name, data: data)
            let r = try await connection.request(method: "POST", path: "/v1/desktop/files", body: body)
            notice = "已放进云电脑「下载」：\(r["name"] as? String ?? name)"
            await reload()
        } catch { notice = error.localizedDescription }
    }

    private func fetch(_ item: CloudDesktopFiles.Item) async {
        busy = "正在取回…"
        defer { busy = nil }
        do {
            let r = try await connection.request(method: "GET", path: "/v1/desktop/files/\(item.id)")
            guard let f = CloudDesktopFiles.decode(r) else { notice = "文件数据不对"; return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-files", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(f.name)
            try f.data.write(to: url, options: .atomic)
            fetched = url
        } catch { notice = error.localizedDescription }
    }
}

/// 云电脑页面的附属：文件 / 快照面板和智能键盘轮询。挂在一个始终存在的透明视图上（挂在可能为空的视图上 sheet 和 task 不会触发）
struct CloudComputerAux: View {
    @ObservedObject var ctl: CloudDesktopController
    let sessionId: String?
    let live: Bool
    @Binding var keyboardFocused: Bool
    let onPassword: () -> Void

    var body: some View {
        Color.clear
            .sheet(isPresented: $ctl.showFiles) { CloudDesktopFilesSheet() }
            .sheet(isPresented: $ctl.showSnapshots) { CloudSnapshotsSheet(sessionId: sessionId) }
            .modifier(CloudSmartFieldWatcher(active: ctl.controlling && live, keyboardFocused: $keyboardFocused, onPassword: onPassword))
    }
}


/// 控制云电脑时每 1.5 秒看一眼焦点；旧服务器没有这个接口就安静地停下
struct CloudSmartFieldWatcher: ViewModifier {
    let active: Bool
    @Binding var keyboardFocused: Bool
    let onPassword: () -> Void

    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active, CloudSmartField.enabled else { return }
            var last = CloudSmartField.Focus()
            while !Task.isCancelled {
                guard let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/desktop/focus") else { return }
                let now = CloudSmartField.Focus(r)
                switch CloudSmartField.decide(previous: last, now: now, keyboardUp: keyboardFocused) {
                case .showKeyboard: keyboardFocused = true
                case .offerVault: onPassword()
                case .none: break
                }
                last = now
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}
