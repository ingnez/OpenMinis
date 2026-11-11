import SwiftUI

/// 静默时段设置：上班时间内只应答主动提问，完成通知下班后汇总推送。
struct CloudQuietHoursView: View {
    @State private var cfg = CloudQuietHoursConfig.defaultConfig
    @State private var active = false
    @State private var digest: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Toggle("开启静默时段", isOn: $cfg.enabled)
                    .accessibilityIdentifier("quietHoursToggle")
                if cfg.enabled {
                    CloudQuietHoursPickers(cfg: $cfg)
                }
            } footer: {
                Text("上班时间内，Bot 只在你主动问的时候回复；任务做完的通知先攒着，到点后一次推送给你。审批卡仍会立刻出现。")
            }
            if active {
                Section {
                    Label("现在处于静默时段：只应答你的提问", systemImage: "moon.zzz")
                        .foregroundStyle(.orange)
                }
            }
            if let digest, !digest.isEmpty {
                Section("上次下班汇总") {
                    Text(digest).font(.footnote)
                        .accessibilityIdentifier("quietHoursDigest")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle("静默时段")
        .accessibilityIdentifier("quietHoursView")
        .task { await load() }
        .onChange(of: cfg) { _ in Task { await save() } }
    }

    @MainActor
    private func load() async {
        do {
            try await CloudConnection.shared.ensureConnected()
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/quiet-hours")
            if let d = r["quiet_hours"] as? [String: Any] { cfg = CloudQuietHoursConfig.parse(d) }
            active = r["active"] as? Bool ?? false
            let dig = try? await CloudConnection.shared.request(method: "GET", path: "/v1/quiet-hours/digest")
            digest = ((dig?["digest"] as? [String: Any])?["text"] as? String)
            error = nil
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
        }
        loaded = true
    }

    @MainActor
    private func save() async {
        guard loaded else { return }
        do {
            let r = try await CloudConnection.shared.request(method: "PUT", path: "/v1/quiet-hours", body: cfg.body)
            active = r["active"] as? Bool ?? false
            error = nil
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct CloudQuietHoursPickers: View {
    @Binding var cfg: CloudQuietHoursConfig
    private static let times: [String] = (0..<48).map { String(format: "%02d:%02d", $0 / 2, ($0 % 2) * 30) }

    var body: some View {
        Picker("开始", selection: $cfg.start) {
            ForEach(Self.times, id: \.self) { Text($0).tag($0) }
        }
        Picker("结束", selection: $cfg.end) {
            ForEach(Self.times, id: \.self) { Text($0).tag($0) }
        }
        CloudQuietWeekdays(days: $cfg.weekdays)
    }
}

struct CloudQuietWeekdays: View {
    @Binding var days: [Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { if days.count > 1 { days.removeAll { $0 == d } } }
                    else { days = (days + [d]).sorted() }
                } label: {
                    Text("周" + CloudQuietHours.weekdayTitle(d))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Color.accentColor.opacity(0.2) : Color(.systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("周" + CloudQuietHours.weekdayTitle(d) + (on ? "已选" : "未选"))
            }
        }
    }
}
