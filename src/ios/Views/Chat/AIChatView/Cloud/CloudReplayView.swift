import SwiftUI
import UIKit

/// 最近任务的录屏回放列表
struct CloudReplayListView: View {
    @State private var items: [CloudReplaySummary] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loaded && items.isEmpty { Text("还没有回放。Bot 用浏览器或桌面截图时会自动存帧。").foregroundStyle(.secondary) }
                ForEach(items) { r in
                    NavigationLink { CloudReplayView(taskId: r.taskId) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Date(timeIntervalSince1970: r.endedAt).formatted(date: .abbreviated, time: .shortened))
                            Text("\(r.frames) 帧 · \(CloudReplayClock.durationText(r.endedAt - r.startedAt))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("只保存 Bot 自己拍的截图和每一步做了什么；输入的文字不会记下原文，网址只留域名。保留最近 20 个任务。")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle("录屏回放")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            items = CloudReplaySummary.list(try await CloudConnection.shared.request(method: "GET", path: "/v1/replays"))
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
}

/// 逐帧 / 自动播放一个任务的截图
struct CloudReplayView: View {
    let taskId: String
    @State private var frames: [CloudReplayFrame] = []
    @State private var current = 0
    @State private var images: [Int: UIImage] = [:]
    @State private var playing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            CloudReplayImage(image: images[current], loading: !frames.isEmpty)
            if let f = frames.first(where: { $0.index == current }) {
                CloudReplaySteps(frame: f, total: frames.count)
            }
            if frames.count > 1 {
                Slider(value: Binding(get: { Double(current) }, set: { current = Int($0.rounded()); playing = false }),
                       in: 0...Double(frames.count - 1), step: 1)
            }
            HStack(spacing: 28) {
                Button { current = max(0, current - 1); playing = false } label: { Image(systemName: "backward.frame.fill") }
                    .disabled(current == 0)
                Button { playing.toggle(); if playing && current == frames.count - 1 { current = 0 } } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                }
                .disabled(frames.count < 2)
                Button { current = min(frames.count - 1, current + 1); playing = false } label: { Image(systemName: "forward.frame.fill") }
                    .disabled(current >= frames.count - 1)
            }
            .font(.title2)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("回放")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadFrames() }
        .task(id: current) { await loadImage(current); await loadImage(current + 1) }
        .task(id: playing) { await play() }
    }

    private func loadFrames() async {
        do {
            frames = CloudReplayFrame.list(try await CloudConnection.shared.request(method: "GET", path: "/v1/tasks/\(taskId)/replay"))
            if frames.isEmpty { error = "这个任务没有截图" }
        } catch { self.error = error.localizedDescription }
    }

    private func loadImage(_ i: Int) async {
        guard i < frames.count, images[i] == nil else { return }
        if let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/tasks/\(taskId)/replay/\(i)"),
           let b64 = r["image_b64"] as? String, let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
            images[i] = img
        }
    }

    private func play() async {
        while playing && !Task.isCancelled {
            guard current < frames.count, let n = CloudReplayClock.next(current, count: frames.count) else { playing = false; return }
            let wait = CloudReplayClock.delay(from: frames[current], to: frames[n])
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if playing { current = n }
        }
    }
}

struct CloudReplayImage: View {
    let image: UIImage?
    let loading: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
            } else if loading {
                ProgressView()
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityLabel("截图")
    }
}

struct CloudReplaySteps: View {
    let frame: CloudReplayFrame
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("第 \(frame.index + 1) / \(total) 帧 · \(Date(timeIntervalSince1970: frame.time).formatted(date: .omitted, time: .standard))")
                .font(.caption.weight(.semibold))
            if frame.steps.isEmpty {
                Text("（这一帧之前没有新动作）").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(frame.steps.enumerated()), id: \.offset) { _, s in
                    Label(s, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
