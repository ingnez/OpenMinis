import SwiftUI

/// 设置里的测试清单：这个 IPA 已经覆盖的流程，以及还需要真机看的项目。
struct CloudIPAChecklistView: View {
    var body: some View {
        List {
            Section {
                ForEach(CloudIPAChecklist.tested) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body.weight(.medium))
                        Text(item.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("已测流程") } footer: {
                Text("这些项目有 Linux / 服务器单测和 XCUITest 截图钩子。模拟器跑通不算真机验收。")
            }
            Section {
                ForEach(CloudIPAChecklist.needsDevice) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body.weight(.medium))
                        Text(item.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("需真机验证") }
        }
        .navigationTitle("测试清单")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ipaChecklist")
    }
}
