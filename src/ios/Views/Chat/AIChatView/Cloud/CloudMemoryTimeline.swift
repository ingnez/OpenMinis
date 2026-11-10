//
//  CloudMemoryTimeline.swift
//  Minis - 云端记忆时间线
//  浏览 VPS 记忆索引（手机同步的日志、GLOBAL.md 与云端 Agent 写入的条目），按日期分组，
//  支持全文检索、分类筛选与删除云端条目。
//

import Foundation
import SwiftUI

struct CloudMemoryTimelineView: View {
    @State private var entries: [[String: Any]] = []
    @State private var query = ""
    @State private var category = ""
    @State private var errorText: String?
    @State private var loading = false

    private struct CategoryOption { let key: String; let label: String }
    private struct DayGroup { let day: String; let items: [[String: Any]] }

    private static let categories: [CategoryOption] = [
        CategoryOption(key: "", label: "全部"), CategoryOption(key: "profile", label: "关于我"),
        CategoryOption(key: "rules", label: "偏好"), CategoryOption(key: "people", label: "人物"),
        CategoryOption(key: "workstreams", label: "项目"), CategoryOption(key: "note", label: "笔记"),
    ]

    private var grouped: [DayGroup] {
        var order: [String] = []
        var map: [String: [[String: Any]]] = [:]
        for e in entries {
            let day = String((e["entry_time"] as? String ?? "").prefix(10))
            let key = day.isEmpty ? "长期（GLOBAL）" : day
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { DayGroup(day: $0, items: map[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                Picker("分类", selection: $category) {
                    ForEach(Self.categories, id: \.key) { c in Text(c.label).tag(c.key) }
                }
                .pickerStyle(.segmented)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if entries.isEmpty && !loading {
                Text(query.isEmpty ? "还没有记忆。开启“同步工作记忆”或让云端 Agent 记住一些事。" : "没有匹配的记忆。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(grouped, id: \.day) { (group: DayGroup) in
                Section(group.day) {
                    ForEach(group.items.indices, id: \.self) { i in
                        let e = group.items[i]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(Self.label(e["category"] as? String)).font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                Text((e["source"] as? String) == "cloud" ? "云端写入" : "手机同步")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(String((e["entry_time"] as? String ?? "").dropFirst(11).prefix(5)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(e["content"] as? String ?? "").font(.footnote).textSelection(.enabled)
                        }
                        .swipeActions {
                            if (e["source"] as? String) == "cloud", let id = (e["id"] as? NSNumber)?.intValue {
                                Button(role: .destructive) { delete(id) } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("记忆时间线")
        .searchable(text: $query, prompt: "全文检索（中文可用）")
        .onSubmit(of: .search) { Task { await reload() } }
        .onChange(of: category) { _ in Task { await reload() } }
        .onChange(of: query) { q in if q.isEmpty { Task { await reload() } } }
        .refreshable { await reload() }
        .task { await reload() }
        .overlay { if loading && entries.isEmpty { ProgressView() } }
    }

    static func label(_ category: String?) -> String {
        categories.first(where: { $0.key == (category ?? "note") })?.label ?? (category ?? "笔记")
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var params = ["limit=50"]
        params.append("query=" + (q.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
        if !category.isEmpty { params.append("category=" + category) }
        do {
            if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
            let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/memory?" + params.joined(separator: "&"), body: nil)
            entries = resp["entries"] as? [[String: Any]] ?? []
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ id: Int) {
        Task {
            do {
                _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/memory/\(id)", body: nil)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }
}
