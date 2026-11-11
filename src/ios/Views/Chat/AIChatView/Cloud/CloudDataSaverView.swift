import SwiftUI

/// 省流模式设置：蜂窝自动 / 常开 / 关闭；列出已推迟的大文件。
struct CloudDataSaverPage: View {
    @AppStorage(CloudLowBandwidth.key) private var setting = "auto"
    @State private var items: [CloudDataSaverItem] = []

    var body: some View {
        List {
            Section {
                Picker(selection: $setting) {
                    Text("蜂窝时自动").tag("auto")
                    Text("常开").tag("on")
                    Text("关闭").tag("off")
                } label: {
                    Text("省流模式")
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("dataSaverPicker")
            } footer: {
                Text("打开后，云电脑画面改用最省画质；超过 512 KB 的上传会推迟，连上 Wi-Fi 后再发。也可随时手动打开或关闭。")
            }
            Section {
                Text(statusLine)
                    .font(.subheadline)
                    .accessibilityIdentifier("dataSaverStatus")
                    .accessibilityValue(saving ? "on" : "off")
                if !banner.isEmpty {
                    Text(banner).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dataSaverBanner")
                }
            } header: { Text("当前") }
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        HStack {
                            Text(item.filename)
                            Spacer()
                            Text(CloudDataSaver.bytesText(item.bytes)).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("dataSaverQueued-\(item.id)")
                    }
                } header: { Text("已推迟") }
            }
            #if DEBUG
            if CloudE2E.token != nil {
                Section {
                    Button("演示：放入一个推迟的大文件") {
                        CloudDataSaver.enqueue(CloudDataSaverItem(id: "e2e-demo", filename: "演示大文件.bin",
                                                                  bytes: 1024 * 1024, sessionId: "e2e",
                                                                  createdAt: Date().timeIntervalSince1970),
                                               defaults: .standard)
                        items = CloudDataSaver.load(from: .standard)
                    }
                    .accessibilityIdentifier("dataSaverDemoEnqueue")
                } footer: {
                    Text("只在端到端测试里出现，用来确认推迟队列和横幅。")
                }
            }
            #endif
        }
        .navigationTitle("省流模式")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            CloudDataSaverMonitor.start()
            items = CloudDataSaver.load(from: .standard)
        }
        .onChange(of: setting) { _ in items = CloudDataSaver.load(from: .standard) }
    }

    private var saving: Bool {
        CloudLowBandwidth.active(setting: setting, expensive: CloudDataSaver.expensiveNetwork)
    }

    private var statusLine: String {
        saving ? "省流已开：画面降画质，大文件会推迟上传" : "省流未开：按原画质，上传立即发出"
    }

    private var banner: String {
        CloudDataSaver.bannerText(count: items.count, bytes: items.reduce(0) { $0 + $1.bytes })
    }
}

/// 云电脑菜单里的省流三档（已有实现时复用同一把钥匙）。
struct CloudDataSaverMenu: View {
    @AppStorage(CloudLowBandwidth.key) private var setting = "auto"

    var body: some View {
        Picker(selection: $setting) {
            Text("蜂窝时自动").tag("auto")
            Text("常开").tag("on")
            Text("关闭").tag("off")
        } label: {
            Label("省流模式（蜂窝降画质、推迟大文件）", systemImage: "antenna.radiowaves.left.and.right")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("dataSaverMenu")
    }
}
