//
//  CloudBotChatKit.swift
//  Minis - 多 Bot 模式对话页组件：Bot 主题色气泡、工作中的动态头像与进度、
//  「+」附件（照片 / 拍照 / 扫描文档 / 文件）、听写与语音对话。
//

import SwiftUI
import UIKit
import PhotosUI
import VisionKit
import Speech
import AVFoundation
import UniformTypeIdentifiers

struct CloudBotChatTheme {
    let botId: String
    let name: String
    let spec: CloudBotAvatarSpec
    var model: String = ""
    var credential: String = ""
    var effort: String = ""
    var accent: Color { spec.fill }
    var backdrop: CloudChatBackdrop { CloudChatBackdrop.of(botId) }

    init(bot: CloudBot) {
        botId = bot.id
        name = bot.name
        spec = CloudBotAvatarSpec.of(bot)
        model = bot.model
        credential = bot.credential
        effort = bot.reasoningEffort
    }

    /// 输入框上方的小标签，如「gpt-5 · 中」
    var chipText: String {
        let m = model.isEmpty ? (UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "默认模型") : model
        let e = CloudEffort(rawValue: effort) ?? CloudEffort.globalDefault
        return CloudEffort.short(m) + (e == .off ? "" : " · " + e.label)
    }
}

// MARK: - 消息气泡

enum CloudMessageText {
    /// 消息内容可能是 message_parts 的 JSON：取出文字，图片显示为占位
    /// 附件说明行（「[附件] … → 工作区 attachments/…」）只给模型看：图片换成缩略图，其它文件显示成「📎 文件名」
    static func display(_ content: String) -> (text: String, images: Int) {
        var text = content, images = 0
        if content.hasPrefix("["), let data = content.data(using: .utf8),
           let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            images = parts.filter { $0["type"] as? String == "image_url" }.count
        }
        let s = CloudAttachmentLines.split(text)
        guard !s.items.isEmpty else { return (text, images) }
        let files = s.items.filter { !$0.isImage }.map { "📎 " + $0.filename }
        let shown = ([s.text] + files).filter { !$0.isEmpty }.joined(separator: "\n")
        return (shown, images > 0 ? images : s.items.filter(\.isImage).count)
    }

    /// 一行预览（主页、列表）：图片写成「[图片]」
    static func preview(_ content: String) -> String {
        let shown = display(content)
        let line = CloudPreviewText.plain(shown.text).replacingOccurrences(of: "📎 ", with: "[文件] ")
        return ([line] + Array(repeating: "[图片]", count: shown.images)).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct CloudThemedBubble: View {
    let role: String
    let content: String
    let accent: Color

    var body: some View {
        if let mark = CloudDelegationMark.parse(content) {
            CloudDelegationCard(mark: mark, accent: accent)
        } else {
            plainBubble
        }
    }

    private var plainBubble: some View {
        let shown = CloudMessageText.display(content)
        return HStack {
            if role == "user" { Spacer(minLength: 48) }
            VStack(alignment: role == "user" ? .trailing : .leading, spacing: 6) {
                if shown.images > 0 {
                    CloudMessageImages(content: content, alignment: role == "user" ? .trailing : .leading)
                }
                if !shown.text.isEmpty {
                    Text(shown.text).textSelection(.enabled)
                        .font(.body)
                        .foregroundStyle(role == "user" ? Color.white : Color.primary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(role == "user" ? accent : Color(.systemGray6)))
                }
            }
            if role != "user" { Spacer(minLength: 24) }
        }
    }
}

// MARK: - Bot 之间的委托卡片

/// 服务器写进消息开头的标记：「【来自 X·委托】」（别的 Bot 交来的）或「【X 的委托结果·已完成】」（交回的结果）
struct CloudDelegationMark {
    enum Kind { case incoming, result }
    let kind: Kind
    let botName: String
    let label: String
    let body: String

    static func parse(_ content: String) -> CloudDelegationMark? {
        guard content.hasPrefix("【"), let end = content.firstIndex(of: "】") else { return nil }
        let inner = String(content[content.index(after: content.startIndex)..<end])
        let body = String(content[content.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("来自 "), let dot = inner.lastIndex(of: "·") {
            let name = String(inner[inner.index(inner.startIndex, offsetBy: 3)..<dot])
            return CloudDelegationMark(kind: .incoming, botName: name, label: String(inner[inner.index(after: dot)...]), body: body)
        }
        if let r = inner.range(of: " 的委托结果·") {
            return CloudDelegationMark(kind: .result, botName: String(inner[..<r.lowerBound]),
                                       label: String(inner[r.upperBound...]), body: body)
        }
        return nil
    }

    /// 去掉服务器附加的「（委托编号 …）」说明，只给人看任务本身
    var shownBody: String {
        guard kind == .incoming, let r = body.range(of: "\n\n（委托编号") else { return body }
        return String(body[..<r.lowerBound])
    }
}

struct CloudDelegationCard: View {
    let mark: CloudDelegationMark
    let accent: Color
    @ObservedObject private var home = CloudBotHomeModel.shared
    @Environment(\.cloudChatBotId) private var selfId
    @State private var expanded = false

    var body: some View {
        let other = home.bots.first(where: { $0.name == mark.botName })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let other {
                    CloudBotAvatarView(spec: CloudBotAvatarSpec.of(other), size: 22)
                } else {
                    Image(systemName: "person.2.circle.fill").foregroundStyle(accent)
                }
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(mark.label).font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(badgeColor.opacity(0.15)))
                    .foregroundStyle(badgeColor)
            }
            Text(mark.shownBody.isEmpty ? "（没有文字内容）" : mark.shownBody)
                .font(.callout)
                .lineLimit(expanded ? nil : 6)
                .textSelection(.enabled)
            HStack {
                if mark.shownBody.count > 240 {
                    Button(expanded ? "收起" : "展开全部") { withAnimation { expanded.toggle() } }
                        .font(.caption).foregroundStyle(accent)
                }
                Spacer()
                if let other, !selfId.isEmpty {
                    // 两个 Bot 之间来回的消息（只读线程）
                    NavigationLink {
                        CloudBotThreadView(a: selfId, b: other.id)
                    } label: {
                        Label("对话", systemImage: "bubble.left.and.bubble.right").font(.caption.weight(.medium))
                    }
                    .foregroundStyle(accent)
                    .accessibilityLabel("查看和 \(other.name) 之间的对话")
                }
                if let other {
                    // 点一下进入被委托 Bot 的对话（同一个导航栈，返回回到这里）
                    NavigationLink(value: other.id) {
                        Label("打开 \(other.name) 的对话", systemImage: "arrow.up.right.circle")
                            .font(.caption.weight(.medium))
                    }
                    .simultaneousGesture(TapGesture().onEnded { CloudHaptics.tap() })
                    .foregroundStyle(accent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        mark.kind == .incoming ? "来自 \(mark.botName) 的\(mark.label)" : "\(mark.botName) 交回的结果"
    }

    private var badgeColor: Color {
        switch mark.label {
        case "已完成", "委托", "消息": return .green
        case "进行中": return .blue
        default: return .orange
        }
    }
}

// MARK: - 工作进度

enum CloudBotProgress {
    static func label(forTool tool: String) -> String {
        switch tool {
        case "browser_action": return "正在浏览网页…"
        case "shell_execute": return "正在运行命令…"
        case "file_read": return "正在读取文件…"
        case "file_write", "file_edit": return "正在写文件…"
        case "desktop_action": return "正在操作云电脑…"
        case "memory_search": return "正在回忆…"
        case "memory_write": return "正在记下来…"
        case "skill_load": return "正在加载技能…"
        case "page_write": return "正在写页面…"
        case "subagent_task": return "正在分派子任务…"
        case "image_generate": return "正在生成图片…"
        case "send_message": return "正在准备消息…"
        case "request_user_takeover": return "需要你帮忙…"
        case "list_bots": return "正在看看其他 Bot…"
        case "send_to_bot": return "正在给其他 Bot 发消息…"
        case "delegate_task": return "正在交给其他 Bot…"
        default:
            if tool.contains("search") { return "正在搜索…" }
            return "正在调用 \(tool)…"
        }
    }

    /// (当前状态, 已完成步数, 步骤列表)
    static func summarize(_ events: [[String: Any]], status: String) -> (String, Int, [String]) {
        var steps: [String] = []
        var done = 0
        var current = "正在思考…"
        for e in events {
            let type = e["type"] as? String ?? ""
            let payload = e["payload"] as? [String: Any] ?? [:]
            switch type {
            case "tool_call":
                let tool = payload["tool"] as? String ?? ""
                current = label(forTool: tool)
                steps.append(current.replacingOccurrences(of: "…", with: ""))
            case "tool_result":
                done += 1
                current = "正在思考…"
            case "approval_required":
                current = "等你批准"
            case "queued":
                current = payload["message"] as? String ?? "排队中…"
            case "started":
                current = "正在思考…"
            case "status":
                current = payload["message"] as? String ?? current
            case "delegation_started":
                let name = payload["to_name"] as? String ?? "其他 Bot"
                current = "\(name) 正在处理…"
                steps.append("交给 \(name)")
            case "delegation_finished":
                let name = payload["to_name"] as? String ?? "其他 Bot"
                steps.append("\(name) " + ((payload["status"] as? String) == "completed" ? "已完成" : "已结束"))
                current = "正在思考…"
            case "thought":
                current = "正在思考…"
            default:
                break
            }
        }
        if status == "waiting_user" { current = "等你批准" }
        return (current, done, steps)
    }
}

/// 工作中的 Bot 头像：上下轻跳、挤压、微微歪头，随机眨眼和东张西望（尊重“减弱动态效果”）
struct CloudBotLivelyAvatar: View {
    let spec: CloudBotAvatarSpec
    var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gaze: CGSize = .zero
    @State private var eyeOpen: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || CloudE2E.pauseIdleAnimations)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let bob = reduceMotion ? 0 : sin(t * 3.2)
            CloudBotAvatarView(spec: spec, size: size, gaze: gaze, eyeOpen: eyeOpen)
                .scaleEffect(x: 1 + 0.04 * bob, y: 1 - 0.05 * bob, anchor: .bottom)
                .rotationEffect(.degrees(reduceMotion ? 0 : 5 * sin(t * 1.3)))
                .offset(y: reduceMotion ? 0 : -3 * abs(sin(t * 3.2)))
        }
        .frame(width: size, height: size + 4)
        .modifier(CloudFollowTouch(gaze: $gaze, enabled: !reduceMotion))
        .task(id: reduceMotion) { await animateEyes() }
        .accessibilityHidden(true)
    }

    private func animateEyes() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 900_000_000...2_600_000_000))
            if Task.isCancelled { return }
            if Bool.random() || reduceMotion {
                withAnimation(.easeInOut(duration: 0.08)) { eyeOpen = 0.1 }
                try? await Task.sleep(nanoseconds: 120_000_000)
                withAnimation(.easeInOut(duration: 0.1)) { eyeOpen = 1 }
            }
            if !reduceMotion && CloudTouchTracker.shared.point == nil {
                let looks = [CGSize(width: -1, height: 0), CGSize(width: 1, height: 0), CGSize(width: 0, height: -1),
                             CGSize(width: 0.6, height: -0.6), .zero, .zero]
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { gaze = looks.randomElement() ?? .zero }
            }
        }
    }
}

struct CloudBotWorkingRow: View {
    let spec: CloudBotAvatarSpec
    let events: [[String: Any]]
    let status: String
    @State private var expanded = false

    var body: some View {
        let s = CloudBotProgress.summarize(events, status: status)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .bottom, spacing: 8) {
                    CloudBotLivelyAvatar(spec: spec)
                    Text(s.0 + (s.1 > 0 ? " · 已完成 \(s.1) 步" : ""))
                        .font(.footnote).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: s.0)
                    if !s.2.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bot 正在工作：\(s.0)，已完成 \(s.1) 步")
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(s.2.enumerated()), id: \.offset) { i, step in
                        Label(step, systemImage: i < s.1 ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.caption).foregroundStyle(i < s.1 ? Color.secondary : Color.primary)
                    }
                }
                .padding(.leading, 42)
            }
        }
    }
}

// MARK: - 附件

struct CloudPendingAttachment: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
    let isImage: Bool
    var thumbnail: UIImage?
}

enum CloudAttachmentKit {
    /// 图片压成 ≤1600px 的 JPEG，控制上传体积
    static func image(_ image: UIImage, name: String) -> CloudPendingAttachment? {
        // 「保留原图」：原尺寸、高质量 JPEG 上传到工作区；发给模型的那份仍由 visionData 压到预算内
        let keep = ImageSendPolicy.keepOriginal
        let pixel = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let size = ImageSendPolicy.targetSize(for: pixel, keepOriginal: keep)
        // 按像素画（scale = 1）：默认按屏幕倍数画，1600pt 的图会变成 4800px，超过发给模型的大小上限后图片被丢掉
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let jpgName = (name as NSString).deletingPathExtension + ".jpg"   // HEIC 等一律转 JPEG
        guard let data = keep ? resized.jpegData(compressionQuality: 0.92) : CloudImageBudget.fit(resized) else { return nil }
        return CloudPendingAttachment(filename: jpgName, data: data, isImage: true, thumbnail: resized)
    }

    /// 发给模型看的图片：拍照 / 相册的直接用；从「文件」里选的图片解码后同样压缩；不是图片返回 nil
    static func visionData(_ item: CloudPendingAttachment) -> Data? {
        if item.isImage { return item.data.count <= CloudImageBudget.maxBytes ? item.data : UIImage(data: item.data).flatMap(CloudImageBudget.fit) }
        guard CloudImageBudget.isImageName(item.filename), let img = UIImage(data: item.data) else { return nil }
        return image(img, name: item.filename)?.data
    }

    /// 扫描的多页文档合成一个 PDF
    static func pdf(from scan: VNDocumentCameraScan) -> CloudPendingAttachment? {
        guard scan.pageCount > 0 else { return nil }
        let first = scan.imageOfPage(at: 0)
        let bounds = CGRect(origin: .zero, size: first.size)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for i in 0..<scan.pageCount {
                let page = scan.imageOfPage(at: i)
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                page.draw(in: CGRect(origin: .zero, size: page.size))
            }
        }
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        let name = (scan.title.isEmpty ? "扫描文档" : scan.title) + " " + stamp + ".pdf"
        return CloudPendingAttachment(filename: name.replacingOccurrences(of: "/", with: "-"), data: data, isImage: false, thumbnail: first)
    }

    /// 上传非图片附件（以及图片的原件，便于在资料库里找到），返回给 Agent 的说明行
    static func upload(_ items: [CloudPendingAttachment], sessionId: String,
                       progress: (@MainActor (UUID, ImageStackSource.Upload) -> Void)? = nil) async throws -> [String] {
        // 并行上传（每张各自的进度圈）；说明行按原来的顺序
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask {
                    await progress?(item.id, .uploading(nil))
                    let setting = UserDefaults.standard.string(forKey: CloudLowBandwidth.key) ?? "auto"
                    if CloudLowBandwidth.shouldDefer(bytes: item.data.count, setting: setting, expensive: CloudDataSaver.expensiveNetwork) {
                        var queued = CloudDataSaverItem(id: item.id.uuidString, filename: item.filename,
                                                        bytes: item.data.count, sessionId: sessionId,
                                                        createdAt: Date().timeIntervalSince1970, localName: nil)
                        queued.localName = try? CloudDataSaver.writePayload(item.data, id: queued.id, filename: item.filename,
                                                                            base: CloudDataSaver.defaultCacheBase())
                        CloudDataSaver.enqueue(queued, defaults: .standard)
                        await progress?(item.id, .failed)
                        throw CloudDataSaverError.deferred
                    }
                    let resp: [String: Any]
                    do {
                        resp = try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/\(sessionId)/upload",
                                                                        body: ["filename": item.filename, "data_base64": item.data.base64EncodedString()])
                    } catch {
                        await progress?(item.id, .failed)
                        throw error
                    }
                    await progress?(item.id, .done)
                    let path = resp["file_path"] as? String ?? item.filename
                    if item.isImage || CloudImageBudget.isImageName(item.filename) {
                        await CloudAttachmentCache.save(item.data, name: (path as NSString).lastPathComponent)   // 气泡缩略图先用本机这份
                    }
                    return (i, "[附件] \(item.filename) → 工作区 \(path)")
                }
            }
            var lines = [String](repeating: "", count: items.count)
            for try await (i, line) in group { lines[i] = line }
            return lines
        }
    }
}

struct CloudPhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([CloudPendingAttachment]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 9
        config.filter = .any(of: [.images, .videos])
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([CloudPendingAttachment]) -> Void
        init(onPicked: @escaping ([CloudPendingAttachment]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let group = DispatchGroup()
            let box = Box()
            for (i, r) in results.enumerated() {
                let provider = r.itemProvider
                group.enter()
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        if let url, let data = try? Data(contentsOf: url), data.count < 24_000_000 {
                            box.add(i, CloudPendingAttachment(filename: "视频\(i + 1).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)", data: data, isImage: false))
                        }
                        group.leave()
                    }
                } else if provider.canLoadObject(ofClass: UIImage.self) {
                    provider.loadObject(ofClass: UIImage.self) { obj, _ in
                        if let img = obj as? UIImage, let a = CloudAttachmentKit.image(img, name: "照片\(i + 1).jpg") {
                            box.add(i, a)
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
            group.notify(queue: .main) { self.onPicked(box.items) }
        }

        /// 各张图异步加载、谁先好谁先到：按相册里点选的顺序（下标）排回去，不按加载完成的先后
        private final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var slots: [(Int, CloudPendingAttachment)] = []
            var items: [CloudPendingAttachment] { lock.lock(); defer { lock.unlock() }; return CloudPickOrder.sorted(slots) }
            func add(_ index: Int, _ item: CloudPendingAttachment) { lock.lock(); slots.append((index, item)); lock.unlock() }
        }
    }
}

struct CloudCameraPicker: UIViewControllerRepresentable {
    let onPicked: (CloudPendingAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CloudCameraPicker
        init(parent: CloudCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let a = CloudAttachmentKit.image(img, name: "拍照.jpg") { parent.onPicked(a) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// 系统文档扫描器（自动快门、闪光灯、滤镜），结果合成多页 PDF
struct CloudDocumentScanner: UIViewControllerRepresentable {
    let onScanned: (CloudPendingAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: CloudDocumentScanner
        init(parent: CloudDocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            if let pdf = CloudAttachmentKit.pdf(from: scan) { parent.onScanned(pdf) }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }
    }
}

struct CloudFilePicker: UIViewControllerRepresentable {
    let onPicked: ([CloudPendingAttachment]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([CloudPendingAttachment]) -> Void
        init(onPicked: @escaping ([CloudPendingAttachment]) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let items = urls.compactMap { url -> CloudPendingAttachment? in
                guard let data = try? Data(contentsOf: url), data.count < 24_000_000 else { return nil }
                return CloudPendingAttachment(filename: url.lastPathComponent, data: data, isImage: false)
            }
            onPicked(items)
        }
    }
}

// MARK: - 听写

/// 音频线程上的计数（只在 tap 回调里用）
final class DictationTick: @unchecked Sendable {
    private var n = 0
    func next() -> Int { n += 1; return n }
}

@MainActor
final class CloudDictation: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var errorText: String?
    /// 最近一次识别到新文字的时间（语音对话用来判断说完了）
    @Published var lastHeard = Date()
    /// 听写卡片上的滚动波形（新的在后面）
    @Published private(set) var levels: [Float] = []
    private var levelBuffer = DictationLevels()
    private var fakeTask: Task<Void, Never>?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(language: String = "") {
        guard !isRecording else { return }
        // 实时通话占着麦克风：听写会改音频会话类别，把通话掐断
        guard !AudioSessionCoordinator.shared.isRealtimeActive else { errorText = "正在实时通话，挂断后再听写"; return }
        levelBuffer.reset(); levels = []
        if CloudE2E.fakeDictation { startFake(); return }
        errorText = nil
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.errorText = "请在 设置 → 隐私 中允许语音识别"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    Task { @MainActor in
                        if ok { self.begin(language: language) } else { self.errorText = "请在 设置 → 隐私 中允许麦克风" }
                    }
                }
            }
        }
    }

    private func begin(language: String) {
        let locale = Locale(identifier: language.isEmpty ? (Locale.preferredLanguages.first ?? "zh-CN") : language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            errorText = "语音识别暂不可用"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // 病区降噪打开时用系统通话语音处理（回声消除 + 降噪），否则保持原声 .measurement
            let denoise = CloudWardVoice.denoise
            try session.setCategory(.playAndRecord, mode: denoise ? .voiceChat : .measurement,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            // 必须在读输入格式、装 tap 之前切换；失败就当没开（照常录原声）
            if input.isVoiceProcessingEnabled != denoise { try? input.setVoiceProcessingEnabled(denoise) }
            input.removeTap(onBus: 0)
            let tick = DictationTick()
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                req.append(buffer)
                // 每两块算一次音量给波形（约 20 次每秒），只在主线程改界面状态
                guard tick.next() % 2 == 0, let ch = buffer.floatChannelData?[0] else { return }
                let level = DictationLevels.level(ch, count: Int(buffer.frameLength))
                Task { @MainActor [weak self] in self?.pushLevel(level) }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            lastHeard = Date()
            task = recognizer.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.transcript { self.transcript = text; self.lastHeard = Date() }
                    }
                    if error != nil || (result?.isFinal ?? false) { self.stop() }
                }
            }
        } catch {
            errorText = "无法开始录音：\(error.localizedDescription)"
            stop()
        }
    }

    private func pushLevel(_ v: Float) {
        guard isRecording else { return }
        levelBuffer.push(v); levels = levelBuffer.values
    }

    /// 模拟器 E2E：没有麦克风和语音识别，用假音量和一句逐字出来的假文字（全是假数据）
    private func startFake() {
        isRecording = true
        lastHeard = Date()
        let words = ["e2e", "听写", "的", "文字"]
        fakeTask = Task { @MainActor [weak self] in
            var k = 0
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                self.pushLevel(Float(0.35 + 0.3 * sin(Double(k) / 3)))
                if k % 8 == 7, k / 8 < words.count {
                    self.transcript = words.prefix(k / 8 + 1).joined(separator: " ")
                    self.lastHeard = Date()
                }
                k += 1
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    func stop() {
        fakeTask?.cancel(); fakeTask = nil
        if CloudE2E.fakeDictation { isRecording = false; return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        // 实时通话已经接管音频会话时不能停用它（停用会让通话两边都没声音）
        guard !AudioSessionCoordinator.shared.isRealtimeActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - 语音对话

/// 和这个 Bot 语音对话：听你说完（停顿 1.5 秒）就发送，Bot 回复后按它的语音设置朗读，再继续听
struct CloudBotVoiceCallView: View {
    let theme: CloudBotChatTheme
    let isWorking: Bool
    let progress: String
    /// 切到实时双向通话；nil 时不显示入口
    var onRealtime: (() -> Void)? = nil
    let onUtterance: (String) -> Void
    @StateObject private var dictation = CloudDictation()
    @Environment(\.dismiss) private var dismiss
    private let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            CloudBotLivelyAvatar(spec: theme.spec, size: 150)
            Text(theme.name).font(.title2.bold())
            Text(statusText).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            if !dictation.transcript.isEmpty {
                Text(dictation.transcript).font(.body).multilineTextAlignment(.center).padding(.horizontal, 32).lineLimit(4)
            }
            if let err = dictation.errorText { Text(err).font(.footnote).foregroundStyle(.red) }
            if let onRealtime {
                Button { dictation.stop(); onRealtime() } label: {
                    Label("切到实时双向通话（可随时插话）", systemImage: "waveform.circle")
                }
                .font(.footnote)
            }
            Spacer()
            HStack(spacing: 40) {
                Button {
                    if dictation.isRecording { dictation.stop() } else { CloudBotSpeaker.stop(); dictation.start(language: CloudBotVoiceSettings.load(theme.botId).language) }
                } label: {
                    Image(systemName: dictation.isRecording ? "mic.fill" : "mic.slash.fill").font(.title2).foregroundStyle(.primary)
                        .frame(width: 64, height: 64).background(Circle().fill(Color(.systemGray5)))
                }
                .accessibilityLabel(dictation.isRecording ? "暂停收听" : "继续收听")
                Button {
                    dictation.stop(); CloudBotSpeaker.stop(); dismiss()
                } label: {
                    Image(systemName: "xmark").font(.title2.bold()).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(Circle().fill(Color.red))
                }
                .accessibilityLabel("结束语音对话")
            }
            .padding(.bottom, 30)
        }
        .onAppear { dictation.start(language: CloudBotVoiceSettings.load(theme.botId).language) }
        .onDisappear { dictation.stop() }
        .onReceive(tick) { _ in
            let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if dictation.isRecording, !text.isEmpty, Date().timeIntervalSince(dictation.lastHeard) > 1.5, !isWorking {
                dictation.stop()
                onUtterance(text)
                dictation.transcript = ""
            }
        }
        .onChange(of: isWorking) { working in
            // Bot 说完（任务结束后朗读）再继续听；朗读由对话页负责
            if !working {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    while CloudBotSpeaker.isSpeaking { try? await Task.sleep(nanoseconds: 300_000_000) }
                    if !dictation.isRecording { dictation.start(language: CloudBotVoiceSettings.load(theme.botId).language) }
                }
            }
        }
    }

    private var statusText: String {
        if isWorking { return progress }
        if dictation.isRecording { return "正在听…说完停顿一下就会发送" }
        return "已暂停，点麦克风继续"
    }
}
