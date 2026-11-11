import SwiftUI

/// 交班卡：本班（最近 N 小时）各 Bot 的未完成任务、未收回授权、待盯事项，可存成图片分享。
/// 数据来自 GET /v1/shift-card（纯查库）。说「交班」或点「交班」会钉住，下次打开 App 先看到。
struct CloudShiftCardSheet: View {
    var pinOnOpen: Bool = true
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 12
    @State private var card: [String: Any]? = nil
    @State private var error: String? = nil
    @State private var shareImage: Image? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("时间", selection: $hours) {
                        ForEach([8, 12, 24], id: \.self) { Text("最近 \($0) 小时").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let card {
                        CloudShiftCardContent(card: card)
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Text("下次打开 App 会先看到这张卡。只汇总标题与结论，不调模型；无痕对话和上锁的 Bot 不进卡。分享前请确认没有病人身份信息。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("交班卡")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("shiftCardSheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { Task { await ackAndClose() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("交班卡", image: shareImage)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task(id: hours) { await load() }
            .onAppear { if pinOnOpen { CloudShiftPin.mark() } }
        }
        .accessibilityIdentifier("shiftCardSheet")
    }

    @MainActor
    private func ackAndClose() async {
        CloudShiftPin.consume()
        _ = try? await CloudConnection.shared.request(method: "POST", path: "/v1/shift-card/ack", body: [:])
        dismiss()
    }

    @MainActor
    private func load() async {
        card = nil
        error = nil
        shareImage = nil
        do {
            try await CloudConnection.shared.ensureConnected()
            let raw = try await CloudConnection.shared.request(method: "GET", path: "/v1/shift-card?hours=\(hours)")
            let shown = CloudShiftCardFilter.hideLocked(raw)
            card = shown
            if pinOnOpen {
                CloudShiftPin.mark()
                _ = try? await CloudConnection.shared.request(method: "POST", path: "/v1/shift-card", body: ["hours": hours])
            }
            let renderer = ImageRenderer(content: CloudShiftCardContent(card: shown).padding(20).frame(width: 390).background(Color(.systemBackground)))
            renderer.scale = 3
            if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
        }
    }
}

enum CloudShiftCardFilter {
    static func hideLocked(_ card: [String: Any]) -> [String: Any] {
        var out = card
        let bots = (card["bots"] as? [[String: Any]] ?? []).filter { b in
            guard let id = b["bot_id"] as? String else { return true }
            return !CloudBotLock.isLockedStored(id)
        }
        out["bots"] = bots
        return out
    }
}

struct CloudShiftCardContent: View {
    let card: [String: Any]

    private var bots: [[String: Any]] { card["bots"] as? [[String: Any]] ?? [] }
    private var approvals: [[String: Any]] { card["approvals"] as? [[String: Any]] ?? [] }
    private var grants: [[String: Any]] { card["grants"] as? [[String: Any]] ?? [] }
    private var watch: [[String: Any]] { card["watch"] as? [[String: Any]] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            totals
            CloudShiftGrantList(title: "未收回授权", items: grants, ident: "shiftCardGrants")
            CloudShiftGrantList(title: "待批准", items: approvals, ident: "shiftCardApprovals", hideIfEmpty: true)
            CloudShiftWatchList(items: watch)
            if bots.isEmpty && grants.isEmpty && approvals.isEmpty && watch.isEmpty {
                Text("这段时间没有对话").foregroundStyle(.secondary)
            }
            ForEach(Array(bots.enumerated()), id: \.offset) { _, b in
                CloudShiftCardBot(bot: b)
            }
        }
        .accessibilityIdentifier("shiftCardContent")
    }

    private var totals: some View {
        let t = card["totals"] as? [String: Any] ?? [:]
        let n = { (k: String) in t[k] as? Int ?? 0 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                chip("未完成", n("unfinished") > 0 ? n("unfinished") : n("running") + n("waiting_you") + n("unanswered"), .orange)
                chip("未收回", n("grants"), .red)
                chip("待盯", n("watch"), .purple)
            }
            HStack(spacing: 10) {
                chip("对话", n("sessions"), .blue)
                chip("在跑", n("running"), .orange)
                chip("等你", n("waiting_you"), .red)
                chip("没回", n("unanswered"), .purple)
            }
        }
    }

    private func chip(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.bold)).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CloudShiftGrantList: View {
    let title: String
    let items: [[String: Any]]
    let ident: String
    var hideIfEmpty: Bool = false

    var body: some View {
        if items.isEmpty && hideIfEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if items.isEmpty {
                    Text("没有\(title)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let label = (item["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (item["tool"] as? String ?? "")
                    let who = item["bot_name"] as? String ?? ""
                    HStack(alignment: .top, spacing: 8) {
                        Text(title == "待批准" ? "待批" : "授权").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.12), in: Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label.isEmpty ? title : label).font(.subheadline)
                            if !who.isEmpty { Text(who).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier(ident)
        }
    }
}

struct CloudShiftWatchList: View {
    let items: [[String: Any]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("待盯事项").font(.headline)
            if items.isEmpty {
                Text("没有待盯事项").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let title = item["title"] as? String ?? "待盯"
                let detail = item["detail"] as? String ?? ""
                HStack(alignment: .top, spacing: 8) {
                    Text(item["kind"] as? String == "task" ? "任务" : "盯").font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline)
                        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("shiftCardWatch")
    }
}

struct CloudShiftCardBot: View {
    let bot: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bot["bot_name"] as? String ?? "Bot").font(.headline)
            ForEach(Array((bot["items"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, item in
                CloudShiftCardRow(item: item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CloudShiftCardRow: View {
    let item: [String: Any]

    var body: some View {
        let state = item["state"] as? String ?? "done"
        let (label, tint): (String, Color) = {
            switch state {
            case "running": return ("在跑", .orange)
            case "waiting_you": return ("等你", .red)
            case "unanswered": return ("没回", .purple)
            default: return ("完成", .green)
            }
        }()
        let detail = (item["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["last_user"] as? String ?? "")
        return HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(item["title"] as? String ?? "对话").font(.subheadline)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}
