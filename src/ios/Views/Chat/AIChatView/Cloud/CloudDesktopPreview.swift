//
//  CloudDesktopPreview.swift
//  Minis - Bot 用电脑时，对话里显示云电脑的实时小画面（WebSocket 推流，旧服务器退回每 2.5 秒一张缩略图；点开进入「电脑」页）。
//

import SwiftUI
import UIKit

struct CloudDesktopPreview: View {
    let botId: String
    let onOpen: () -> Void
    @State private var image: UIImage?
    @State private var updatedAt: Date?

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Rectangle().fill(Color(.systemGray5)).aspectRatio(16 / 10, contentMode: .fit)
                            .overlay(ProgressView())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("实时画面 · 点开接管").font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(8)
            }
            .frame(maxWidth: 300, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("云电脑实时画面，点按打开")
        .task(id: botId) { await loop() }
    }

    private func loop() async {
        // 先用 WebSocket 推流（画面一变就到，约 3 帧/秒）；旧服务器或连不上时退回每 2.5 秒取一张缩略图
        var streamFailures = 0
        while !Task.isCancelled && streamFailures < 3 {
            let frames = await stream()
            if Task.isCancelled { return }
            streamFailures = frames > 0 ? 0 : streamFailures + 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        await poll()
    }

    /// 一次推流连接，返回收到的帧数
    private func stream() async -> Int {
        guard let task = CloudConnection.shared.desktopStream(botId: botId) else { return 0 }
        var count = 0
        task.resume()
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard let msg = try? await task.receive() else { break }
                if case .data(let data) = msg, let img = UIImage(data: data) {
                    image = img
                    updatedAt = Date()
                    count += 1
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
        task.cancel(with: .goingAway, reason: nil)
        return count
    }

    private func poll() async {
        var misses = 0
        while !Task.isCancelled {
            if let resp = try? await CloudConnection.shared.request(method: "GET", path: "/v1/desktop/thumbnail?bot_id=\(botId)"),
               let b64 = resp["data_base64"] as? String, let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                image = img
                updatedAt = Date()
                misses = 0
            } else {
                misses += 1   // 截屏偶尔失败不提示，保留上一张；连续失败就放慢
            }
            let wait: UInt64 = misses > 3 ? 10_000_000_000 : 2_500_000_000
            try? await Task.sleep(nanoseconds: wait)
        }
    }
}
