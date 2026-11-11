import Foundation

/// 交付文件下载：进度、断点续传、缓存、失败可重试。
@MainActor
final class CloudFileDownload: ObservableObject {
    enum State: Equatable {
        case idle
        case running(Double)   // 0...1
        case failed(String)
        case ready(URL)
    }

    @Published var state: State = .idle
    let item: CloudDeliverable
    let sessionId: String

    init(item: CloudDeliverable, sessionId: String) {
        self.item = item
        self.sessionId = sessionId
        if let url = CloudFileCache.cached(id: item.id, name: item.name, bytes: item.bytes) {
            state = .ready(url)
        }
    }

    var fraction: Double {
        if case .running(let v) = state { return v }
        if case .ready = state { return 1 }
        return 0
    }

    func start(force: Bool = false) async {
        if item.kind == .link { return }
        if !force, case .ready = state { return }
        if !force, let url = CloudFileCache.cached(id: item.id, name: item.name, bytes: item.bytes) {
            state = .ready(url)
            return
        }
        if item.url == nil, let path = item.path, path.hasPrefix("/var/minis/") || path.hasPrefix("minis://") {
            // 本地文件：直接用已有路径
            if let url = localURL(path), FileManager.default.fileExists(atPath: url.path) {
                state = .ready(url)
                return
            }
        }
        guard let remote = item.url, !sessionId.isEmpty else {
            state = .failed("没有可下载的地址")
            return
        }
        state = .running(CloudFileCache.partialBytes(id: item.id, name: item.name) > 0
                         ? Double(CloudFileCache.partialBytes(id: item.id, name: item.name)) / Double(max(item.bytes, 1))
                         : 0)
        do {
            let url = try await CloudConnection.shared.downloadDeliverable(
                path: remote, id: item.id, name: item.name, expectedBytes: item.bytes
            ) { [weak self] frac in
                Task { @MainActor in self?.state = .running(frac) }
            }
            state = .ready(url)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() async { await start(force: true) }

    private func localURL(_ path: String) -> URL? {
        if path.hasPrefix("minis://") { return nil }
        return URL(fileURLWithPath: path)
    }
}
