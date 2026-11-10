//
//  CloudAvatarPhoto.swift
//  Minis - Bot 头像也可以是表情或照片：表情直接写进头像编码（av:e<表情>c<颜色>），
//  照片缩到 256px 后存到服务器（/v1/bots/<id>/avatar），头像编码只记内容哈希（av:p<哈希>c<颜色>），手机本地缓存。
//

import SwiftUI
import PhotosUI
import CryptoKit
import UIKit

@MainActor
final class CloudAvatarImages: ObservableObject {
    static let shared = CloudAvatarImages()
    @Published private(set) var images: [String: UIImage] = [:]     // key = 哈希
    private var loading = Set<String>()

    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BotAvatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    func image(hash: String, owner: String?) -> UIImage? {
        if let img = images[hash] { return img }
        let file = Self.dir.appendingPathComponent(hash + ".jpg")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            DispatchQueue.main.async { self.images[hash] = img }
            return img
        }
        if let owner, !loading.contains(hash) {
            loading.insert(hash)
            Task { @MainActor in
                defer { self.loading.remove(hash) }
                guard let resp = try? await CloudQuiet.retry(2, { try await CloudConnection.shared.request(method: "GET", path: "/v1/bots/\(owner)/avatar") }),
                      let b64 = resp["data_base64"] as? String, let data = Data(base64Encoded: b64), let img = UIImage(data: data) else { return }
                try? data.write(to: file, options: .atomic)
                self.images[hash] = img
            }
        }
        return nil
    }

    func store(_ data: Data) {
        let h = Self.hash(data)
        try? data.write(to: Self.dir.appendingPathComponent(h + ".jpg"), options: .atomic)
        if let img = UIImage(data: data) { images[h] = img }
    }

    /// 保存 Bot 之后上传还没上传的照片
    static func uploadIfNeeded(_ spec: CloudBotAvatarSpec, botId: String) async throws {
        guard let data = spec.pendingPhoto else { return }
        _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/bots/\(botId)/avatar",
                                                     body: ["data_base64": data.base64EncodedString()])
        shared.store(data)
    }

    /// 选中的照片：居中裁成正方形，缩到 256px，JPEG
    static func prepare(_ data: Data) -> Data? {
        guard let src = UIImage(data: data) else { return nil }
        let side = min(src.size.width, src.size.height)
        let target = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: target)
        let out = renderer.image { _ in
            let scale = 256 / side
            let w = src.size.width * scale, h = src.size.height * scale
            src.draw(in: CGRect(x: (256 - w) / 2, y: (256 - h) / 2, width: w, height: h))
        }
        return out.jpegData(compressionQuality: 0.82)
    }
}

struct CloudAvatarPhotoView: View {
    let spec: CloudBotAvatarSpec
    let size: CGFloat
    @ObservedObject private var cache = CloudAvatarImages.shared

    var body: some View {
        let img: UIImage? = spec.pendingPhoto.flatMap { UIImage(data: $0) } ?? spec.photo.flatMap { cache.image(hash: $0, owner: spec.owner) }
        ZStack {
            Circle().fill(spec.fill.opacity(0.2))
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: size * 0.5)).foregroundStyle(spec.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(spec.fill.opacity(0.5), lineWidth: max(1, size * 0.025)))
    }
}

struct CloudEmojiAvatarPicker: View {
    @Binding var spec: CloudBotAvatarSpec
    @State private var custom = ""
    static let choices = ["🤖", "🧭", "🩺", "💊", "📄", "📝", "🔎", "💻", "🏠", "✍️", "🏃", "🧠",
                          "🐱", "🐶", "🦊", "🐼", "🐧", "🦉", "🌟", "🔥", "🌈", "🍀", "☕️", "🎧",
                          "📚", "🧪", "🧬", "🫀", "🚑", "🎯", "📈", "🗂️", "🛒", "✈️", "🎨", "🎮"]

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 8), count: 6), spacing: 10) {
                ForEach(Self.choices, id: \.self) { e in
                    Button { pick(e) } label: {
                        Text(e).font(.system(size: 28)).frame(width: 46, height: 46)
                            .background(Circle().fill(spec.emoji == e ? Color(.systemGray4) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("其他表情", text: $custom)
                    .multilineTextAlignment(.center)
                    .frame(width: 120)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                    .onChange(of: custom) { v in
                        guard let first = v.first, String(first).unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF }) else { return }
                        pick(String(first))
                        custom = ""
                    }
            }
        }
    }

    private func pick(_ e: String) {
        CloudHaptics.selection()
        spec.emoji = e
        spec.photo = nil
        spec.pendingPhoto = nil
    }
}

struct CloudPhotoAvatarPicker: View {
    @Binding var spec: CloudBotAvatarSpec
    @State private var item: PhotosPickerItem?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $item, matching: .images) {
                Label(spec.photo == nil ? "从相册选一张照片" : "换一张照片", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color(.systemBackground)))
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
            Text("照片会裁成圆形，保存后存到你的云电脑上").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: item) { newItem in
            guard let newItem else { return }
            Task { @MainActor in
                guard let raw = try? await newItem.loadTransferable(type: Data.self), let data = CloudAvatarImages.prepare(raw) else {
                    errorText = "读不到这张照片"
                    return
                }
                errorText = nil
                CloudHaptics.success()
                spec.pendingPhoto = data
                spec.photo = CloudAvatarImages.hash(data)
                spec.emoji = nil
            }
        }
    }
}
