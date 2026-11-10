import SwiftUI

/// 工作流画布：每个例行任务一张卡，箭头表示「接着」。拖卡片挪位置；从卡片右边的圆点拖到另一张卡上，就让那张接在这张后面。
struct CloudWorkflowCanvasView: View {
    @State private var routines: [[String: Any]] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var dragOrigin: [String: CGPoint] = [:]
    @State private var linkFrom: String?
    @State private var linkPoint: CGPoint?
    @State private var pending: (node: String, upstream: String)?
    @State private var errorText: String?
    @State private var loading = false

    private var graph: CloudWorkflowGraph { CloudWorkflowGraph(routines: routines) }
    private typealias G = CloudWorkflowGraph

    var body: some View {
        let g = graph
        let size = G.canvasSize(positions)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in g.edges {
                        guard let a = positions[e.from], let b = positions[e.to] else { continue }
                        ctx.stroke(arrow(from: CGPoint(x: a.x + G.nodeSize.width / 2, y: a.y), to: CGPoint(x: b.x - G.nodeSize.width / 2, y: b.y)),
                                   with: .color(.accentColor), lineWidth: 2)
                    }
                    if let f = linkFrom, let a = positions[f], let p = linkPoint {
                        ctx.stroke(arrow(from: CGPoint(x: a.x + G.nodeSize.width / 2, y: a.y), to: p),
                                   with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .frame(width: size.width, height: size.height)
                ForEach(g.nodes, id: \.id) { n in
                    node(n, depth: g.depth(n.id))
                        .position(positions[n.id] ?? .zero)
                }
            }
            .frame(width: max(size.width, 320), height: max(size.height, 400), alignment: .topLeading)
            .coordinateSpace(name: "workflow")
        }
        .background(Color(.systemGroupedBackground))
        .overlay {
            if loading && routines.isEmpty { ProgressView() }
            else if routines.isEmpty { Text("还没有例行任务。先在列表里新建，再回来连线。").font(.footnote).foregroundStyle(.secondary).padding() }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if let e = errorText { Text(e).font(.footnote).foregroundStyle(.red) }
                Text("拖卡片挪位置；从右边的圆点拖到另一张卡上，让它「接着」这一步跑（最多连 \(G.maxDepth) 层）。长按卡片可断开。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity).background(.bar)
        }
        .navigationTitle("工作流画布")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("自动排列") { positions = graph.defaultPositions(); G.save(positions) }
            }
        }
        .confirmationDialog("连上这一步？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let p = pending {
                Button("「\(name(p.node))」接在「\(name(p.upstream))」完成后") { Task { await link(p.node, after: p.upstream, any: false) } }
                Button("「\(name(p.upstream))」结束后都接着跑（失败也跑）") { Task { await link(p.node, after: p.upstream, any: true) } }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            Text("会替换「\(pending.map { name($0.node) } ?? "")」原来的定时设置。")
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func node(_ n: CloudWorkflowGraph.Node, depth: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(n.upstream == nil ? "起点" : "第 \(depth) 步").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle().fill(Color.accentColor).frame(width: 16, height: 16)
                .overlay(Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                .frame(width: 32, height: 44).contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .named("workflow"))
                    .onChanged { v in linkFrom = n.id; linkPoint = v.location }
                    .onEnded { v in
                        linkFrom = nil; linkPoint = nil
                        guard let target = G.hit(v.location, positions: positions, excluding: n.id) else { return }
                        propose(node: target, upstream: n.id)
                    })
                .accessibilityLabel("从「\(n.name)」连到下一步")
        }
        .padding(.leading, 12)
        .frame(width: G.nodeSize.width, height: G.nodeSize.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(linkFrom != nil && linkFrom != n.id ? Color.orange : Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .gesture(DragGesture(coordinateSpace: .named("workflow"))
            .onChanged { v in
                let start = dragOrigin[n.id] ?? positions[n.id] ?? .zero
                dragOrigin[n.id] = start
                positions[n.id] = CGPoint(x: max(G.nodeSize.width / 2, start.x + v.translation.width),
                                          y: max(G.nodeSize.height / 2, start.y + v.translation.height))
            }
            .onEnded { _ in dragOrigin[n.id] = nil; G.save(positions) })
        .contextMenu {
            Button { Task { _ = try? await CloudRoutineService.runNow(routineId: n.id) } } label: { Label("立即运行", systemImage: "play") }
            if n.upstream != nil {
                Button(role: .destructive) { Task { await unlink(n.id) } } label: { Label("断开，改成每天 9:00", systemImage: "scissors") }
            }
        }
    }

    private func name(_ id: String) -> String { graph.nodes.first { $0.id == id }?.name ?? id }

    private func propose(node: String, upstream: String) {
        let g = graph
        if g.wouldCycle(node: node, upstream: upstream) { errorText = "这样连会绕成圈。"; return }
        if g.exceedsDepth(node: node, upstream: upstream) { errorText = "最多连 \(G.maxDepth) 层，再往后的不会跑。"; return }
        errorText = nil
        CloudHaptics.selection()
        pending = (node, upstream)
    }

    private func arrow(from a: CGPoint, to b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        let mid = (a.x + b.x) / 2
        p.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        let ang = atan2(b.y - a.y, b.x - mid)
        for d in [-0.5, 0.5] {
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x - 9 * cos(ang + d), y: b.y - 9 * sin(ang + d)))
        }
        return p
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            routines = try await CloudRoutineService.list()
            CloudRoutineService.rememberNames(routines)
            var pos = G.savedPositions()
            let defaults = graph.defaultPositions()
            for (id, p) in defaults where pos[id] == nil { pos[id] = p }
            positions = pos.filter { defaults[$0.key] != nil }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func link(_ node: String, after upstream: String, any: Bool) async {
        pending = nil
        do {
            try await CloudRoutineService.setSchedule(routineId: node, ["kind": "after", "routine_id": upstream, "on": any ? "any" : "completed"])
            await reload()
        } catch {
            errorText = "没连上：\(error.localizedDescription)"
        }
    }

    private func unlink(_ node: String) async {
        do {
            try await CloudRoutineService.setSchedule(routineId: node, ["kind": "cron", "expr": "0 9 * * *", "timezone": TimeZone.current.identifier])
            await reload()
        } catch {
            errorText = "没断开：\(error.localizedDescription)"
        }
    }
}
