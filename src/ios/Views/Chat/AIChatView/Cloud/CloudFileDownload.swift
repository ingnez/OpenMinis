import Combine
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
        if case .running = state { return }
        if !force, case .ready(let url) = state, FileManager.default.fileExists(atPath: url.path) { return }
        if !force, let url = CloudFileCache.cached(id: item.id, name: item.name, bytes: item.bytes) {
            state = .ready(url)
            return
        }
        if item.source == "local", item.url == nil {
            if let path = item.path, let url = localURL(path), FileManager.default.fileExists(atPath: url.path) {
                state = .ready(url)
            } else {
                state = .failed("本地文件已移动或删除")
            }
            return
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
                Task { @MainActor in
                    guard let self, case .running = self.state else { return }
                    self.state = .running(frac)
                }
            }
            state = .ready(url)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() async { await start(force: true) }

    private func localURL(_ path: String) -> URL? {
        guard !sessionId.isEmpty, !path.hasPrefix("/") else { return nil }
        let workspace = AIChatViewModel.minisWorkspacePersistentDir(for: sessionId).resolvingSymlinksInPath()
        let url = workspace.appendingPathComponent(path).resolvingSymlinksInPath()
        return url.path.hasPrefix(workspace.path + "/") ? url : nil
    }
}
