//
//  CloudBotAvatar.swift
//  Minis - Bot 头像：13 种形状 × 12 种颜色，带白色“眼睛”；保存在 Bot 的 emoji 字段（"av:s<形状>c<颜色>"）。
//

import SwiftUI

struct CloudBotAvatarSpec: Hashable {
    var shape: Int
    var color: Int
    /// 表情头像（彩色圆底 + 表情）；nil = 形状头像
    var emoji: String? = nil
    /// 照片头像的内容哈希（服务器 /v1/bots/<id>/avatar 保存图片）；nil = 不是照片
    var photo: String? = nil
    /// 照片属于哪个 Bot（取图用）；of(bot) 时填入
    var owner: String? = nil
    /// 刚在手机上选的照片（还没上传）：保存 Bot 后上传
    var pendingPhoto: Data? = nil

    static let shapeCount = 13
    /// 颜色随外观变化：深色模式下黑色换成石墨灰（见 CloudAvatarPalette），身体不会融进背景
    static let colors: [Color] = (0..<CloudAvatarPalette.count).map { i in
        Color(UIColor { trait in
            let c = CloudAvatarPalette.rgb(i, dark: trait.userInterfaceStyle == .dark)
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    var encoded: String {
        if let photo { return "av:p\(photo)c\(color)" }
        if let emoji, !emoji.isEmpty { return "av:e\(emoji)c\(color)" }
        return "av:s\(shape)c\(color)"
    }
    var fill: Color { Self.colors[min(max(color, 0), Self.colors.count - 1)] }

    static func parse(_ text: String) -> CloudBotAvatarSpec? {
        if text.hasPrefix("av:e") || text.hasPrefix("av:p"), let cIdx = text.lastIndex(of: "c"), cIdx > text.index(text.startIndex, offsetBy: 4) {
            let body = String(text[text.index(text.startIndex, offsetBy: 4)..<cIdx])
            guard let c = Int(text[text.index(after: cIdx)...]), (0..<colors.count).contains(c), !body.isEmpty else { return nil }
            if text.hasPrefix("av:p") {
                guard body.range(of: "^[a-f0-9]{6,16}$", options: .regularExpression) != nil else { return nil }
                return CloudBotAvatarSpec(shape: 0, color: c, photo: body)
            }
            return CloudBotAvatarSpec(shape: 0, color: c, emoji: body)
        }
        guard text.hasPrefix("av:s"), let cIdx = text.firstIndex(of: "c") else { return nil }
        let s = Int(text[text.index(text.startIndex, offsetBy: 4)..<cIdx])
        let c = Int(text[text.index(after: cIdx)...])
        guard let s, let c, (0..<shapeCount).contains(s), (0..<colors.count).contains(c) else { return nil }
        return CloudBotAvatarSpec(shape: s, color: c)
    }

    /// 没有保存头像时按 Bot ID 生成稳定的默认值；主 Bot 默认黑色圆形
    static func `default`(for id: String, primary: Bool) -> CloudBotAvatarSpec {
        // 主 Bot 默认用靛蓝（以前是黑色，小尺寸下像一团黑影）；用户自己选了黑色照样尊重
        if primary { return CloudBotAvatarSpec(shape: 0, color: 10) }
        var h: UInt32 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt32(b) }
        return CloudBotAvatarSpec(shape: Int(h % 13), color: 1 + Int((h / 13) % 11))
    }

    static func of(_ bot: CloudBot) -> CloudBotAvatarSpec {
        var spec = parse(bot.emoji) ?? .default(for: bot.id, primary: bot.isPrimary)
        // 模板 / 旧版存的是单个表情（如 🧭）：显示为表情头像
        if !bot.emoji.isEmpty, !bot.emoji.hasPrefix("av:"), bot.emoji.count <= 2,
           bot.emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            spec.emoji = bot.emoji
        }
        spec.owner = bot.id
        return spec
    }

    var isShape: Bool { emoji == nil && photo == nil }
}

/// 13 种头像形状（单位方框内绘制后缩放）
struct CloudBotShape: Shape {
    let kind: Int

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let o = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        func circles(_ list: [(CGFloat, CGFloat, CGFloat)]) -> Path {
            var p = Path()
            for (x, y, r) in list { p.addEllipse(in: CGRect(x: o.x + (x - r) * s, y: o.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s)) }
            return p
        }
        func rounded(_ points: [CGPoint], radius: CGFloat) -> Path {
            var p = Path()
            let n = points.count
            let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            p.move(to: mid(points[n - 1], points[0]))
            for i in 0..<n {
                p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius * s)
            }
            p.closeSubpath()
            return p
        }
        func polygon(_ count: Int, rotation: Double, radius: CGFloat = 0.48) -> [CGPoint] {
            (0..<count).map { i in
                let a = rotation + Double(i) * 2 * .pi / Double(count)
                return pt(0.5 + radius * CGFloat(cos(a)), 0.5 + radius * CGFloat(sin(a)))
            }
        }
        func star(_ points: Int, inner: CGFloat, rotation: Double) -> Path {
            var verts: [CGPoint] = []
            for i in 0..<(points * 2) {
                let r: CGFloat = i % 2 == 0 ? 0.5 : inner
                let a = rotation + Double(i) * .pi / Double(points)
                verts.append(pt(0.5 + r * CGFloat(cos(a)), 0.5 + r * CGFloat(sin(a))))
            }
            return rounded(verts, radius: 0.06)
        }
        switch kind {
        case 1:  // 四叶草
            return circles([(0.32, 0.36, 0.24), (0.68, 0.36, 0.24), (0.36, 0.66, 0.24), (0.66, 0.66, 0.24), (0.5, 0.5, 0.2)])
        case 2:  // 倾斜圆角方
            let r = s * 0.2
            let box = CGRect(x: o.x + s * 0.14, y: o.y + s * 0.14, width: s * 0.72, height: s * 0.72)
            return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: box)
                .applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                    .concatenating(CGAffineTransform(rotationAngle: .pi / 9))
                    .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
        case 3:  // 四角星
            return star(4, inner: 0.24, rotation: -.pi / 2)
        case 4:  // 蓬松云
            return circles([(0.5, 0.3, 0.22), (0.28, 0.45, 0.22), (0.72, 0.45, 0.22), (0.38, 0.7, 0.22), (0.64, 0.7, 0.22), (0.5, 0.5, 0.22)])
        case 5:  // 豆子
            var p = Path()
            p.addEllipse(in: CGRect(x: o.x + s * 0.08, y: o.y + s * 0.2, width: s * 0.84, height: s * 0.6))
            return p.applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(rotationAngle: -.pi / 10)).concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
        case 6:  // 花
            var list: [(CGFloat, CGFloat, CGFloat)] = [(0.5, 0.5, 0.26)]
            for i in 0..<6 {
                let a = Double(i) * .pi / 3
                list.append((0.5 + 0.24 * CGFloat(cos(a)), 0.5 + 0.24 * CGFloat(sin(a)), 0.17))
            }
            return circles(list)
        case 7:  // 水滴
            var p = Path()
            p.move(to: pt(0.5, 0.04))
            p.addCurve(to: pt(0.9, 0.62), control1: pt(0.62, 0.22), control2: pt(0.9, 0.38))
            p.addArc(center: pt(0.5, 0.62), radius: 0.4 * s, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.addCurve(to: pt(0.5, 0.04), control1: pt(0.1, 0.38), control2: pt(0.38, 0.22))
            p.closeSubpath()
            return p
        case 8:  // 胶囊
            return Capsule().path(in: CGRect(x: o.x + s * 0.04, y: o.y + s * 0.22, width: s * 0.92, height: s * 0.56))
        case 9:  // 三角
            return rounded([pt(0.12, 0.12), pt(0.95, 0.5), pt(0.12, 0.88)], radius: 0.14)
        case 10: // 六边形宝石
            return rounded(polygon(6, rotation: .pi / 6), radius: 0.12)
        case 11: // 八角星
            return star(8, inner: 0.34, rotation: 0)
        case 12: // 五边形
            return rounded(polygon(5, rotation: -.pi / 2), radius: 0.12)
        default: // 圆
            return Circle().path(in: CGRect(x: o.x, y: o.y, width: s, height: s))
        }
    }
}

struct CloudBotAvatarView: View {
    let spec: CloudBotAvatarSpec
    var size: CGFloat = 46
    /// 眼睛看向的方向（-1...1），工作动画用
    var gaze: CGSize = .zero
    /// 眼睛睁开程度（1 = 睁开，0.1 = 眨眼）
    var eyeOpen: CGFloat = 1
    /// 心情：排队时眯眼专注、等你审批时睁大眼、有新回复时笑眯眯
    var mood: CloudBotMood = .calm
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if spec.photo != nil {
            CloudAvatarPhotoView(spec: spec, size: size)
        } else if let emoji = spec.emoji {
            ZStack {
                Circle().fill(spec.fill.opacity(0.2))
                Circle().stroke(spec.fill.opacity(0.35), lineWidth: max(1, size * 0.03))
                Text(emoji).font(.system(size: size * 0.56))
                    .scaleEffect(y: 0.92 + 0.08 * max(eyeOpen, 0.1))   // 眨眼时表情轻轻一缩
                    .offset(x: size * 0.04 * gaze.width, y: size * 0.04 * gaze.height)
            }
            .frame(width: size, height: size)
        } else {
            shapeBody
        }
    }

    private var shapeBody: some View {
        ZStack {
            CloudBotShape(kind: spec.shape).fill(spec.fill)
            // 深色模式下黑色头像（主 Bot 默认）会融进背景：加一圈随外观变化的细描边
            CloudBotShape(kind: spec.shape).stroke(Color.primary.opacity(colorScheme == .dark ? 0.35 : 0.06), lineWidth: max(1, size * 0.025))
            HStack(spacing: size * 0.13) {
                eye
                eye
            }
            .rotationEffect(.degrees(mood == .curious ? -4 : -14))
            .offset(x: size * (0.06 + 0.08 * gaze.width), y: size * (-0.08 + 0.07 * gaze.height))
            if mood == .shy {
                HStack(spacing: size * 0.3) {
                    Ellipse().fill(Color.pink.opacity(0.75))
                    Ellipse().fill(Color.pink.opacity(0.75))
                }
                .frame(width: size * 0.55, height: size * 0.08)
                .blur(radius: size * 0.015)
                .offset(x: size * 0.06, y: size * 0.08)
                .accessibilityHidden(true)
            }
            if mood == .dozing {
                Text("z").font(.system(size: size * 0.22, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                    .offset(x: size * 0.3, y: -size * 0.3)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }
}

extension CloudBotAvatarView {
    @ViewBuilder fileprivate var eye: some View {
        let open = max(eyeOpen, 0.12)
        switch mood {
        case .happy where eyeOpen > 0.5:
            // 笑眼：向上弯的弧
            CloudHappyEye().stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .frame(width: size * 0.14, height: size * 0.09)
        case .focused:
            Capsule().fill(Color.white).frame(width: size * 0.11, height: size * 0.12 * open)
        case .curious:
            Capsule().fill(Color.white).frame(width: size * 0.12, height: size * 0.27 * open)
        case .frown:
            // 出错：向下弯的眼，像皱着眉
            CloudHappyEye().stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .frame(width: size * 0.14, height: size * 0.07).rotationEffect(.degrees(180))
        case .shy:
            // 害羞：眯成向下弯的笑眼
            CloudHappyEye().stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.06).rotationEffect(.degrees(180))
        case .dozing:
            // 闲太久：闭眼成一条线
            Capsule().fill(Color.white).frame(width: size * 0.13, height: max(1.5, size * 0.035))
        default:
            Capsule().fill(Color.white).frame(width: size * 0.1, height: size * 0.22 * open)
        }
    }
}

extension CloudBotMood {
    /// lastTaskStatus：上一次任务的状态（失败时皱眉）；lastAt：最后活动时间（闲太久打瞌睡）
    static func of(_ status: CloudBotStatus, unread: Bool, lastTaskStatus: String? = nil, lastAt: Double = 0, now: Double = Date().timeIntervalSince1970) -> CloudBotMood {
        switch status {
        case .waiting: return .curious
        case .queued, .working: return .focused
        case .idle: return idle(unread: unread, failed: lastTaskStatus.map(CloudBotPresence.failedStatuses.contains) ?? false,
                                idleSeconds: lastAt > 0 ? now - lastAt : 0)
        }
    }
}

struct CloudHappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return p
    }
}

/// 形状网格 + 颜色点；创建页与编辑页共用
struct CloudBotAvatarPicker: View {
    @Binding var spec: CloudBotAvatarSpec
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 22) {
            Picker("头像类型", selection: $mode) {
                Text("形状").tag(0)
                Text("表情").tag(1)
                Text("照片").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .onAppear { mode = spec.photo != nil ? 2 : spec.emoji != nil ? 1 : 0 }
            switch mode {
            case 1: CloudEmojiAvatarPicker(spec: $spec)
            case 2: CloudPhotoAvatarPicker(spec: $spec)
            default: shapeGrid
            }
            colorGrid
        }
    }

    private var shapeGrid: some View {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 10), count: 5), spacing: 12) {
                ForEach(0..<CloudBotAvatarSpec.shapeCount, id: \.self) { k in
                    Button { CloudHaptics.selection(); spec.shape = k; spec.emoji = nil; spec.photo = nil; spec.pendingPhoto = nil } label: {
                        CloudBotBlinkingIcon(spec: CloudBotAvatarSpec(shape: k, color: spec.color), size: 38)
                            .frame(width: 50, height: 50)
                            .overlay(Circle().stroke(Color.gray.opacity(spec.isShape && spec.shape == k ? 0.45 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("形状 \(k + 1)")
                }
            }
    }

    private var colorGrid: some View {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 14), count: 6), spacing: 14) {
                ForEach(0..<CloudBotAvatarSpec.colors.count, id: \.self) { c in
                    Button { CloudHaptics.selection(); spec.color = c } label: {
                        Circle().fill(CloudBotAvatarSpec.colors[c]).frame(width: 28, height: 28)
                            .padding(5)
                            .overlay(Circle().stroke(Color.gray.opacity(spec.color == c ? 0.5 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("颜色 \(c + 1)")
                }
            }
    }
}

/// 「+」创建新 Bot：名称 + 形状 + 颜色，一步完成；模板为次要入口
struct CloudBotCreateSheet: View {
    let onCreated: @MainActor (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var spec = CloudBotAvatarSpec(shape: 4, color: 6)
    @State private var saving = false
    @State private var errorText: String?
    @State private var showTemplates = false
    @State private var modelOption: CloudModelOption?
    @State private var effort = CloudEffort.globalDefault
    @State private var showModel = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    CloudBotAliveAvatar(spec: spec, size: 150).padding(.top, 12)
                    TextField("为 Bot 取个名字", text: $name)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
                        .padding(.horizontal, 20)
                    VStack(spacing: 0) {
                        CloudModelEffortRows(modelText: modelOption?.model ?? "跟随手机默认", effort: effort) { showModel = true }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
                    .padding(.horizontal, 20)
                    CloudBotAvatarPicker(spec: $spec)
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                    Button("从模板创建…") { showTemplates = true }
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.bottom, 100)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button { create() } label: {
                    Text(saving ? "创建中…" : "创建").font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(Color(.systemBackground))
                        .background(Capsule().fill(trimmed.isEmpty ? Color.gray : Color.primary))
                }
                .disabled(trimmed.isEmpty || saving)
                .padding(.horizontal, 24).padding(.bottom, 8)
            }
            .navigationTitle("创建新 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
                }
            }
            .sheet(isPresented: $showModel) {
                CloudModelEffortSheet(title: "模型与思考深度",
                                      current: (modelOption?.instanceId ?? "", modelOption?.model ?? "", effort)) { option, e in
                    modelOption = option
                    effort = e
                }
            }
            .sheet(isPresented: $showTemplates) {
                NavigationStack { CloudBotEditor(existing: nil, onSaved: { await onCreated("") }) }
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 英文名转成 ID；中文等名称用随机后缀
    static func makeId(_ name: String) -> String {
        let ascii = name.lowercased().map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) ? c : "-"
        }
        var slug = String(ascii).split(separator: "-").joined(separator: "-")
        if slug.isEmpty || !(slug.first?.isLetter ?? false || slug.first?.isNumber ?? false) {
            slug = "bot"
        }
        let suffix = String(UUID().uuidString.lowercased().prefix(6))
        let id = String(slug.prefix(24)) + "-" + suffix
        return String(id.prefix(32))
    }

    private func create() {
        saving = true
        errorText = nil
        var bot = CloudBot(id: Self.makeId(trimmed), name: trimmed, emoji: spec.encoded, summary: "",
                           instructions: "你是「\(trimmed)」，用户的私人助手。用中文简洁回答，先给结论；需要时调用工具并核验真实结果，不要声称未执行的操作已完成。")
        bot.isPrimary = false
        Task {
            do {
                try await CloudConnection.shared.ensureConnected()
                try await CloudBotService.save(bot)
                try await CloudAvatarImages.uploadIfNeeded(spec, botId: bot.id)
                if modelOption != nil || effort != .off {
                    try await CloudBotService.setModelChoice(bot.id, option: modelOption, effort: effort)
                }
                CloudHaptics.success()
                await onCreated(bot.id)
                dismiss()
            } catch {
                CloudHaptics.warning()
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}

/// 创建 / 编辑页的大头像：轻轻呼吸起伏、随机眨眼、眼睛四处张望并跟随手指，换形状或颜色时弹一下。
/// 「减弱动态效果」开启时只保留眨眼。
struct CloudBotAliveAvatar: View {
    let spec: CloudBotAvatarSpec
    var size: CGFloat = 150
    /// 放在按钮里时传 false：头像自己的拖动手势（minimumDistance 0）会吞掉按钮的点按
    var interactive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gaze: CGSize = .zero
    @State private var eyeOpen: CGFloat = 1
    @State private var touching = false
    @State private var bounce: CGFloat = 1
    @State private var shy = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0 : sin(t * 1.6)
            let tilt = CloudBotMood.tilt(gaze: (Double(gaze.width), Double(gaze.height)), shy: shy)
            CloudBotAvatarView(spec: spec, size: size, gaze: shy ? CGSize(width: tilt.yaw > 0 ? 0.8 : -0.8, height: 0.6) : gaze,
                               eyeOpen: eyeOpen, mood: shy ? .shy : .calm)
                .overlay(CloudAvatarSheen(yaw: reduceMotion ? 0 : tilt.yaw, pitch: reduceMotion ? 0 : tilt.pitch).allowsHitTesting(false))
                .rotation3DEffect(.degrees(reduceMotion ? 0 : tilt.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : tilt.pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .scaleEffect(x: (1 + 0.015 * breath) * bounce, y: (1 - 0.02 * breath) * (2 - bounce), anchor: .bottom)
                .rotationEffect(.degrees(reduceMotion ? 0 : 2.5 * sin(t * 0.7)))
                .offset(y: reduceMotion ? 0 : -4 * (0.5 + 0.5 * sin(t * 1.6)))
        }
        .frame(width: size, height: size + 8)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    touching = true
                    let dx = (v.location.x - size / 2) / (size / 2)
                    let dy = (v.location.y - size / 2) / (size / 2)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        gaze = CGSize(width: max(-1, min(1, dx)), height: max(-1, min(1, dy)))
                    }
                }
                .onEnded { _ in
                    touching = false
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { gaze = .zero }
                },
            including: interactive ? .all : .subviews
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 30).onEnded { _ in becomeShy() },
            including: interactive ? .all : .subviews
        )
        .modifier(CloudFollowTouch(gaze: $gaze, enabled: !reduceMotion && !touching))
        .onChange(of: spec) { _ in
            guard !reduceMotion else { return }
            bounce = 1.12
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { bounce = 1 }
        }
        .task(id: reduceMotion) { await live() }
        .accessibilityHidden(true)
    }

    /// 长按：害羞地扭头、脸红，2.5 秒后恢复
    private func becomeShy() {
        CloudHaptics.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { shy = false }
        }
    }

    private func live() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 1_200_000_000...3_200_000_000))
            if Task.isCancelled { return }
            if Int.random(in: 0..<3) > 0 {
                withAnimation(.easeInOut(duration: 0.07)) { eyeOpen = 0.1 }
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.easeInOut(duration: 0.1)) { eyeOpen = 1 }
                if Int.random(in: 0..<5) == 0 {     // 偶尔连眨两下
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    withAnimation(.easeInOut(duration: 0.07)) { eyeOpen = 0.1 }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    withAnimation(.easeInOut(duration: 0.1)) { eyeOpen = 1 }
                }
            }
            if !reduceMotion && !touching && CloudTouchTracker.shared.point == nil {
                let looks = [CGSize(width: -0.9, height: 0), CGSize(width: 0.9, height: 0), CGSize(width: 0, height: -0.8),
                             CGSize(width: 0.6, height: 0.5), CGSize(width: -0.5, height: -0.6), .zero, .zero]
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { gaze = looks.randomElement() ?? .zero }
            }
        }
    }
}

/// 形状网格里的小图标：偶尔眨一下眼（各自错开，开销很小）
struct CloudBotBlinkingIcon: View {
    let spec: CloudBotAvatarSpec
    var size: CGFloat = 38
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyeOpen: CGFloat = 1

    var body: some View {
        CloudBotAvatarView(spec: spec, size: size, eyeOpen: eyeOpen)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                try? await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...4_000_000_000))
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.07)) { eyeOpen = 0.1 }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeInOut(duration: 0.1)) { eyeOpen = 1 }
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 4_000_000_000...11_000_000_000))
                }
            }
    }
}

/// 3D 倾斜时的一层高光：朝光的一侧亮、背光的一侧暗，让扁平头像有立体感
struct CloudAvatarSheen: View {
    let yaw: Double
    let pitch: Double

    var body: some View {
        let x = 0.5 - yaw / 80, y = 0.35 + pitch / 80
        RadialGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.12)],
                       center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: 120)
            .blendMode(.softLight)
            .mask(Circle().scale(0.95))
    }
}
