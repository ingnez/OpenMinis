import Foundation
import UIKit
import UniformTypeIdentifiers

/// Processes NSExtensionItems from the share sheet, saves files to the shared
/// container, and writes a PendingShare for the main app to consume.
///
/// Main-actor bound: the view controller reads its state when the time limit
/// cuts processing short, while a provider load may still be suspended.
@MainActor
final class ShareViewModel {
    private var pendingItems: [PendingShare.Item] = []
    private let inlineTextLimit = 1000
    /// [T-share-one-link] What the providers returned, before the rules in
    /// `ShareItemRules.reduce` decide what one share keeps.
    private var candidates: [ShareItemRules.Candidate] = []
    private var currentGroup = 0

    /// How many items this share produced (after `processExtensionItems`).
    var itemCount: Int { pendingItems.count }

    /// Process all extension items from the share context.
    func processExtensionItems(_ extensionItems: [NSExtensionItem]) async {
        pendingItems.removeAll()
        candidates.removeAll()

        let fm = FileManager.default
        if let dir = SharedContainerStore.sharedFileDirectory {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for (group, extensionItem) in extensionItems.enumerated() {
            guard let attachments = extensionItem.attachments else { continue }
            currentGroup = group

            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    await processURL(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    await processText(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    await processImage(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    await processVideo(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    await processFile(provider)
                }
            }
        }
        finalizeItems()
    }

    /// [T-share-one-link] Apply the rules, then turn what is left into items.
    /// Also called when processing is cut short by the extension's time limit,
    /// so whatever was loaded by then is still delivered.
    func finalizeItems() {
        let kept = ShareItemRules.reduce(candidates)
        if kept.count != candidates.count {
            NSLog("[ShareExt] rules kept %d of %d loaded values", kept.count, candidates.count)
        }
        pendingItems = kept.compactMap { candidate in
            switch candidate.source {
            case .attachment:
                return .init(kind: .attachment, value: candidate.value)
            case .webURL:
                return .init(kind: .inlineText, value: candidate.value)
            case .text:
                guard candidate.value.count > inlineTextLimit else {
                    return .init(kind: .inlineText, value: candidate.value)
                }
                let fileName = "shared-text-\(UUID().uuidString.prefix(8)).txt"
                guard let dir = SharedContainerStore.sharedFileDirectory else { return nil }
                try? candidate.value.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                return .init(kind: .attachment, value: fileName)
            }
        }
    }

    private func add(_ source: ShareItemRules.Candidate.Source, _ value: String) {
        candidates.append(.init(source: source, value: value, group: currentGroup))
    }

    /// Save pending share and return true on success.
    /// [T-share-buffer-merge] MERGE with any unconsumed previous share instead
    /// of overwriting it. Rapid consecutive shares (user shares screenshot A,
    /// then B a few seconds later, before the main app ran
    /// processPendingShare) used to silently lose A: this save() replaced the
    /// App Group record wholesale. Attachment file names are UUID-suffixed so
    /// the merged item lists never collide on disk. The 300s window matches
    /// checkForPendingShare's staleness cutoff; anything older is abandoned
    /// content whose files the main app will clean up.
    func save() -> Bool {
        guard !pendingItems.isEmpty else { return false }
        var items = pendingItems
        if let existing = SharedContainerStore.loadPendingShare(),
           Date().timeIntervalSince(existing.timestamp) < 300 {
            NSLog("[ShareExt] save: merging %d existing unconsumed items with %d new",
                  existing.items.count, pendingItems.count)
            // [T-share-one-link] The same link shared twice in a row stays one line.
            items = ShareItemRules.merge(existing: existing.items, new: items)
        }
        let share = PendingShare(items: items, timestamp: Date())
        SharedContainerStore.savePendingShare(share)
        return true
    }

    // MARK: - Processors

    /// 文件没能落进共享容器时，别记一个不存在的附件。
    ///
    /// 以前是 `try? copyItem` 之后无条件 `add(.attachment, fileName)`：拷贝失败也记账，
    /// 主 App 读到的是一个没有文件的「幽灵附件」，界面上什么也不会发生——这就是
    /// 「分享进来偶尔没反应」。现在留给用户一句话，说明是哪一个、为什么。
    private func noteFailure(_ name: String, _ error: Error?) {
        NSLog("[ShareExt] %@ 没能加入共享容器: %@", name, error?.localizedDescription ?? "-")
        add(.text, "（「\(name)」没能加入：文件读不出来，请先在「文件」里下载到本机再分享）")
    }

    /// 用 provider 的 file representation 直接拷进共享容器：系统给的临时 URL 只在
    /// 回调内有效，所以复制必须在回调里做完。
    ///
    /// 为什么不用 `loadItem`：那会把整个文件读进扩展的内存。分享扩展的内存上限很小，
    /// 分享一个 100MB+ 的 .ipa 会被系统直接杀掉，表现就是「点了分享什么都没发生」。
    /// 返回 false 表示这个 provider 没有 file representation 或复制失败，调用方退回老路。
    private func copyFileRepresentation(_ provider: NSItemProvider, type: UTType, fileName: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url, let dir = SharedContainerStore.sharedFileDirectory else {
                    NSLog("[ShareExt] no file representation for %@: %@",
                          type.identifier, error?.localizedDescription ?? "-")
                    cont.resume(returning: false)
                    return
                }
                do {
                    try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(fileName))
                    cont.resume(returning: true)
                } catch {
                    NSLog("[ShareExt] copy of %@ failed: %@", url.lastPathComponent, error.localizedDescription)
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// 老接口拿到的 URL（可能带安全作用域）→ 共享容器；失败留话给用户。
    private func copyLocalFile(_ url: URL, fileName: String, displayName: String) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let dir = SharedContainerStore.sharedFileDirectory else {
            noteFailure(displayName, nil)
            return
        }
        do {
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(fileName))
            add(.attachment, fileName)
        } catch {
            noteFailure(displayName, error)
        }
    }

    private func processURL(_ provider: NSItemProvider) async {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
              let url = item as? URL else { return }

        // file:// URLs are local files — treat as file attachment, not inline text
        if url.isFileURL {
            await copyFileToShared(from: url)
            return
        }

        add(.webURL, url.absoluteString)
    }

    /// Copy a local file URL to the shared container as an attachment.
    private func copyFileToShared(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // If it's an image, process through image pipeline for JPEG conversion
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            let fileName = "shared-image-\(UUID().uuidString.prefix(8)).jpg"
            if let dir = SharedContainerStore.sharedFileDirectory,
               let jpegData = image.jpegData(compressionQuality: 0.85) {
                do {
                    try jpegData.write(to: dir.appendingPathComponent(fileName))
                    add(.attachment, fileName)
                } catch {
                    noteFailure(url.lastPathComponent, error)
                }
            } else {
                noteFailure(url.lastPathComponent, nil)
            }
            return
        }

        // General file copy
        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
        await copyLocalFile(url, fileName: fileName, displayName: url.lastPathComponent)
    }

    private func processText(_ provider: NSItemProvider) async {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
              let text = item as? String else { return }

        // Long text becomes a file in `finalizeItems`, after the rules ran.
        add(.text, text)
    }

    private func processImage(_ provider: NSItemProvider) async {
        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
            var image: UIImage?
            if let uiImage = item as? UIImage {
                image = uiImage
            } else if let imageData = item as? Data {
                image = UIImage(data: imageData)
            } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                image = UIImage(data: data)
            }

            if let image {
                let fileName = "shared-image-\(UUID().uuidString.prefix(8)).jpg"
                if let dir = SharedContainerStore.sharedFileDirectory,
                   let jpegData = image.jpegData(compressionQuality: 0.85) {
                    do {
                        try jpegData.write(to: dir.appendingPathComponent(fileName))
                        add(.attachment, fileName)
                    } catch {
                        noteFailure(provider.suggestedName ?? "图片", error)
                    }
                } else {
                    noteFailure(provider.suggestedName ?? "图片", nil)
                }
            } else {
                noteFailure(provider.suggestedName ?? "图片", nil)
            }
        }
    }

    private func processVideo(_ provider: NSItemProvider) async {
        // suggestedName 可能带路径，取最后一段，别让它写到共享目录外面去
        let name = ((provider.suggestedName ?? "视频") as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let fileName = "shared-video-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "mov" : ext)"
        if await copyFileRepresentation(provider, type: .movie, fileName: fileName) {
            add(.attachment, fileName)
            return
        }
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.movie.identifier),
              let url = item as? URL else {
            noteFailure(name, nil)
            return
        }
        await copyLocalFile(url, fileName: fileName, displayName: name)
    }

    private func processFile(_ provider: NSItemProvider) async {
        let rawName = (provider.suggestedName?.isEmpty == false ? provider.suggestedName! : "文件")
        let name = (rawName as NSString).lastPathComponent
        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(name)"
        if await copyFileRepresentation(provider, type: .item, fileName: fileName) {
            add(.attachment, fileName)
            return
        }
        // 退一步：老 provider 只给 fileURL / item 的 Data
        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
           let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            await copyLocalFile(url, fileName: fileName, displayName: name)
            return
        }
        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.item.identifier),
           let url = item as? URL {
            await copyLocalFile(url, fileName: fileName, displayName: name)
            return
        }
        noteFailure(name, nil)
    }
}
