import SwiftUI

/// 当前审批与口令设置。实际操作绑定到服务器仍待处理的审批记录。
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
                Text("口令只在本机保存摘要。口令匹配后，仅批准当前仍有效的这一次调用。锁屏与灵动岛入口会打开实际操作的确认页；显示需要系统允许实时活动。")
            }
            Section {
                if let snap {
                CloudLockApprovalPreviewCard(item: snap)
                    .accessibilityIdentifier("lockApprovalCard")
                CloudDynamicIslandApprovalPreview(item: snap)
                    .accessibilityIdentifier("dynamicIslandApproval")
                } else { Text("当前没有待审批操作") }
            } header: { Text("锁屏 / 灵动岛") }
            Section {
                TextField("试说或输入口令（测试用）", text: $spoken)
                    .accessibilityIdentifier("lockApprovalSpokenField")
                Button("用口令批准") { trySpoken() }
                    .accessibilityIdentifier("lockApprovalSpeakApprove")
                    .disabled(!enabled)
                HStack {
                    Button("批准一次") { submit("approve_once") }
                        .accessibilityIdentifier("lockApprovalOnce")
                    Button("本班次都批准") { submit("approve_shift") }
                        .accessibilityIdentifier("lockApprovalShift")
                    Button("拒绝", role: .destructive) { submit("deny") }
                        .accessibilityIdentifier("lockApprovalDeny")
                }
                .buttonStyle(.bordered)
                .disabled(snap == nil)
            } header: { Text("当前操作") }
        }
        .navigationTitle("锁屏审批与口令")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if CloudLockApprovalSnapshot.e2eForced { snap = .e2eItem() }
            else { snap = CloudLockApprovalSnapshot.load(defaults: .standard) }
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudApprovalCenter.changed)) { _ in
            snap = CloudLockApprovalSnapshot.load(defaults: .standard)
        }
    }

    private func submit(_ decision: String) {
        guard let snap else { notice = "当前没有待审批操作"; return }
        if CloudLockApprovalSnapshot.e2eForced { notice = "演示操作，不执行命令"; return }
        Task { @MainActor in
            do {
                try await CloudApprovalCenter.shared.submit(snap, decision: decision)
                notice = decision == "deny" ? "已拒绝" : "审批已提交"
                self.snap = CloudLockApprovalSnapshot.load(defaults: .standard)
            } catch { notice = error.localizedDescription }
        }
    }

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
            notice = "口令相符"
            submit("approve_once")
        } else if CloudLockApprovalSnapshot.e2eForced,
                  CloudLockPassphrase.normalize(spoken) == CloudLockPassphrase.normalize("批准测试口令") {
            notice = "口令相符（演示，不执行命令）"
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
            Text("操作前请核对当前审批内容").font(.caption2).foregroundStyle(.tertiary)
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
