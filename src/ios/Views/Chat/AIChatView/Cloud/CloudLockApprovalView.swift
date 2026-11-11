import SwiftUI

/// 锁屏卡片和灵动岛审批的手机预览：真机才会出现在锁屏 / 灵动岛上。模拟器测文案、按钮和口令。
struct CloudLockApprovalPage: View {
    @AppStorage(CloudLockPassphrase.enabledKey) private var enabled = false
    @State private var phrase = ""
    @State private var confirm = ""
    @State private var spoken = ""
    @State private var notice: String?
    @State private var snap: CloudLockApprovalSnapshot? = CloudLockApprovalSnapshot.e2eForced ? .e2eItem() : CloudLockApprovalSnapshot.load(defaults: .standard)

    var body: some View {
        List {
            Section {
                Toggle("用语音口令批准", isOn: $enabled)
                    .accessibilityIdentifier("lockApprovalPassphraseToggle")
                SecureField("设置口令（至少 4 个字，不存原文）", text: $phrase)
                    .accessibilityIdentifier("lockApprovalPassphraseField")
                SecureField("再输一次确认", text: $confirm)
                    .accessibilityIdentifier("lockApprovalPassphraseConfirm")
                Button("保存口令") { savePhrase() }
                    .accessibilityIdentifier("lockApprovalPassphraseSave")
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("lockApprovalNotice")
                }
            } header: { Text("语音口令") } footer: {
                Text("口令只在本机保存摘要，不会上传、不会写入日志。说对口令视为「批准一次」。真机锁屏和灵动岛上的审批按钮需要系统允许实时活动；模拟器里用下面的预览验收。")
            }
            Section {
                CloudLockApprovalPreviewCard(item: displayItem)
                    .accessibilityIdentifier("lockApprovalCard")
                CloudDynamicIslandApprovalPreview(item: displayItem)
                    .accessibilityIdentifier("dynamicIslandApproval")
            } header: { Text("锁屏 / 灵动岛预览") }
            Section {
                TextField("试说或输入口令（测试用）", text: $spoken)
                    .accessibilityIdentifier("lockApprovalSpokenField")
                Button("用口令批准") { trySpoken() }
                    .accessibilityIdentifier("lockApprovalSpeakApprove")
                    .disabled(!enabled)
                HStack {
                    Button("批准一次") { notice = "预览：批准一次（真机才会发给云端）" }
                        .accessibilityIdentifier("lockApprovalOnce")
                    Button("本班次都批准") { notice = "预览：本班次都批准（真机才会发给云端）" }
                        .accessibilityIdentifier("lockApprovalShift")
                    Button("拒绝", role: .destructive) { notice = "预览：拒绝（真机才会发给云端）" }
                        .accessibilityIdentifier("lockApprovalDeny")
                }
                .buttonStyle(.bordered)
            } header: { Text("预览操作") }
        }
        .navigationTitle("锁屏审批与口令")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if CloudLockApprovalSnapshot.e2eForced { snap = .e2eItem() }
            else { snap = CloudLockApprovalSnapshot.load(defaults: .standard) }
        }
    }

    private var displayItem: CloudLockApprovalSnapshot { snap ?? .e2eItem() }

    private func savePhrase() {
        let a = CloudLockPassphrase.normalize(phrase)
        let b = CloudLockPassphrase.normalize(confirm)
        guard a == b, let digest = CloudLockPassphrase.digest(phrase) else {
            notice = "两次口令不一致，或少于 4 个字"
            return
        }
        UserDefaults.standard.set(digest, forKey: CloudLockPassphrase.digestKey)
        phrase = ""; confirm = ""
        notice = "口令已保存（只留下摘要）"
    }

    private func trySpoken() {
        let stored = UserDefaults.standard.string(forKey: CloudLockPassphrase.digestKey) ?? ""
        if CloudLockPassphrase.matches(spoken: spoken, storedDigest: stored) {
            notice = "口令相符：将按批准一次处理"
        } else if CloudLockApprovalSnapshot.e2eForced,
                  CloudLockPassphrase.normalize(spoken) == CloudLockPassphrase.normalize("批准测试口令") {
            notice = "口令相符：将按批准一次处理"
        } else {
            notice = "口令不符"
        }
    }
}

struct CloudLockApprovalPreviewCard: View {
    let item: CloudLockApprovalSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("锁屏审批").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(item.botName).font(.headline)
            Text(item.summary).font(.subheadline)
            Text("预览不会执行命令").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct CloudDynamicIslandApprovalPreview: View {
    let item: CloudLockApprovalSnapshot
    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(Color.primary).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("灵动岛").font(.caption2).foregroundStyle(.secondary)
                Text(item.summary).font(.footnote.weight(.semibold)).lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
