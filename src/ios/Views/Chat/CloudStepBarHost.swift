import SwiftUI

/// Bot 对话里的步骤条：直接用本地模式的 FloatingToolBar（左边预览卡、状态胶囊、N/M 翻页、点开看完整输出），
/// 数据来自 Bot 的实时工具事件——步骤块、运行中那一步的实时输出、每步预览（文字末尾 / 浏览器桌面缩略图）。
struct CloudStepBar: View {
    @ObservedObject var message: ChatMessage
    let liveToolId: String?
    let liveOutput: String
    let working: Bool
    @State private var pager = CloudStepPager()
    @State private var finishedAt: Date?
    @State private var now = Date()

    private var steps: [AssistantBlock] { message.blocks.filter { $0.toolStatus != nil } }

    var body: some View {
        let steps = self.steps
        Group {
            if CloudStepBarVisibility.isVisible(working: working, stepCount: steps.count, finishedAt: finishedAt, now: now) {
                FloatingToolBar(toolBlocks: steps, toolSnapshots: snapshots(for: steps), browserPool: nil,
                                followResetToken: pager.followToken)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: working)
        .onAppear { pager.sync(count: steps.count) }
        .onChange(of: steps.count) { n in pager.sync(count: n) }
        .onChange(of: working) { running in
            if running {
                finishedAt = nil
            } else {
                finishedAt = Date()
                now = Date()
                // 结束后停留一会再收起
                DispatchQueue.main.asyncAfter(deadline: .now() + CloudStepBarVisibility.linger + 0.1) { now = Date() }
            }
        }
    }

    /// 每步一份预览：有缩略图用图，运行中那一步用实时输出，其余用服务器给的文字末尾
    private func snapshots(for steps: [AssistantBlock]) -> [ToolSnapshotItem] {
        let store = CloudStepPreviews.shared
        return steps.compactMap { block -> ToolSnapshotItem? in
            guard let id = block.toolUseId else { return nil }
            let name = CloudStepBar.toolName(block.kind)
            if let file = store.thumbFile(id) {
                let ref = MediaRef(id: "cloud-step-\(id)", relativePath: file.lastPathComponent, mimeType: "image/jpeg", originalFileName: nil)
                return ToolSnapshotItem(id: id, toolName: name, snapshot: ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: nil),
                                        mediaResolver: { _ in file })
            }
            let text: String? = {
                if id == liveToolId, !liveOutput.isEmpty { return CloudStepText.tail(liveOutput) }
                return store.get(id)?.text
            }()
            guard let text, !text.isEmpty else { return nil }
            return ToolSnapshotItem(id: id, toolName: name, snapshot: ToolSnapshot(type: .text, text: text, mediaRef: nil, duration: nil),
                                    mediaResolver: { _ in URL(fileURLWithPath: "/dev/null") })
        }
    }

    private static func toolName(_ kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return "shell_execute"
        case .fileReadTool: return "file_read"
        case .fileWriteTool: return "file_write"
        case .fileEditTool: return "file_edit"
        case .browserTool: return "browser_action"
        default: return "tool"
        }
    }
}
