import SwiftUI

struct RealtimeModelPicker: View {
    @ObservedObject var catalog: RealtimeModelCatalog
    @Binding var model: String
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showAll = false
    private var filtered: [RealtimeModelChoice] {
        catalog.models.filter { item in
            let scope = showAll || item.kind.isRealtimeCandidate
            return scope && (search.isEmpty || (item.id + " " + item.name).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List {
            Section {
                Picker("范围", selection: $showAll) {
                    Text("语音候选").tag(false)
                    Text("全部模型").tag(true)
                }.pickerStyle(.segmented)
                Text("候选只列可能支持实时通话的模型（按名称与音频能力识别）。转写、语音合成、非实时模型和未标注能力的模型在「全部模型」里，并标明原因。支持音频不等于支持本页的 Realtime 通话协议。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if catalog.loading {
                HStack { ProgressView(); Text("正在刷新模型列表…") }
            }
            if let error = catalog.error {
                Text("刷新失败：\(error)").foregroundStyle(.red).font(.footnote)
            }
            if filtered.isEmpty {
                Section {
                    Text(showAll ? "没有匹配的模型" : "没有匹配的语音候选，请切换「全部模型」或刷新列表")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(filtered.count) 个模型") {
                    ForEach(filtered) { item in
                        Button {
                            model = item.id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.id).foregroundStyle(.primary)
                                    if item.name != item.id { Text(item.name).font(.caption).foregroundStyle(.secondary) }
                                    Text(item.kind.label).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model == item.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }.accessibilityIdentifier("voiceModel_" + item.id)
                    }
                }
            }
        }
        .navigationTitle("选择语音模型").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索模型名称或别名")
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新模型列表").disabled(catalog.loading)
            }
        }
    }
}
