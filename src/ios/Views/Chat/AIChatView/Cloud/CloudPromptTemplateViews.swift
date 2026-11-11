import SwiftUI

/// 一键模板列表：点一项填进输入框；可新增、编辑、删除、拖动排序。
struct CloudPromptTemplateSheet: View {
    @Binding var text: String
    var onDismiss: () -> Void
    @State private var items: [CloudPromptTemplate] = []
    @State private var editing: CloudPromptTemplate?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button {
                        text = CloudPromptTemplates.apply(item, to: text)
                        CloudHaptics.selection()
                        onDismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(item.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("promptTemplate-\(item.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(item) } label: { Text("删除") }
                        Button { editing = item } label: { Text("编辑") }
                    }
                }
                .onMove(perform: move)
            }
            .navigationTitle("一键模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { onDismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("addPromptTemplate")
                        .accessibilityLabel("新增模板")
                }
            }
            .environment(\.editMode, .constant(.active))
            .sheet(item: $editing) { item in
                CloudPromptTemplateEditor(item: item, isNew: false) { saved in
                    items = CloudPromptTemplates.update(saved, in: items)
                    persist()
                    editing = nil
                }
            }
            .sheet(isPresented: $isAdding) {
                CloudPromptTemplateEditor(item: CloudPromptTemplate(id: "", title: "", prompt: ""), isNew: true) { saved in
                    items = CloudPromptTemplates.add(saved, to: items)
                    persist()
                    isAdding = false
                }
            }
        }
        .onAppear { items = CloudPromptTemplates.load(from: .standard) }
        .accessibilityIdentifier("promptTemplateSheet")
    }

    private func delete(_ item: CloudPromptTemplate) {
        items = CloudPromptTemplates.delete(id: item.id, from: items)
        persist()
    }

    private func move(from: IndexSet, to: Int) {
        guard let i = from.first else { return }
        items = CloudPromptTemplates.move(from: i, to: to, in: items)
        persist()
    }

    private func persist() { CloudPromptTemplates.save(items, to: .standard) }
}

/// 新增 / 编辑一张模板。拆开以免把列表页的 body 拉长。
struct CloudPromptTemplateEditor: View {
    @State var item: CloudPromptTemplate
    let isNew: Bool
    var onSave: (CloudPromptTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题，例如「总结成三句话」", text: $item.title)
                    .accessibilityIdentifier("promptTemplateTitle")
                TextField("提示词", text: $item.prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("promptTemplatePrompt")
            }
            .navigationTitle(isNew ? "新增模板" : "编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let s = CloudPromptTemplates.sanitize(item) { onSave(s) }
                    }
                    .disabled(CloudPromptTemplates.sanitize(item) == nil)
                    .accessibilityIdentifier("savePromptTemplate")
                }
            }
        }
    }
}


extension Notification.Name {
    static let openLocalPromptTemplates = Notification.Name("OpenMinisOpenLocalPromptTemplates")
}

/// 本地对话输入栏的一键模板入口。单独抽成小视图，避免把 AIChatView 的类型检查再加深一层。
struct LocalPromptTemplateEntry: View {
    @Binding var text: String
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 28, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("一键模板")
        .accessibilityIdentifier("localComposerTemplatesButton")
        .sheet(isPresented: $show) {
            CloudPromptTemplateSheet(text: $text, onDismiss: { show = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLocalPromptTemplates)) { _ in
            show = true
        }
    }
}
