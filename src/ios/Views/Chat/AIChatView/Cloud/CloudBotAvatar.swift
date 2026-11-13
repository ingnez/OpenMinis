//
//  CloudBotAvatar.swift
//  Minis - Bot 头像及其保存在 emoji 字段中的形状和颜色选择。
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

    var accentOverride: Int? = nil

    static var shapeCount: Int { GrokBotAvatarAssets.shapeCount }
    /// 聊天主题和自定义表情头像使用 OpenMinis 原有的配色。
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
    var fill: Color { Self.colors[min(max(accentOverride ?? color, 0), Self.colors.count - 1)] }

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
        if primary { return CloudBotAvatarSpec(shape: 0, color: 0, accentOverride: 10) }
        var h: UInt32 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt32(b) }
        let shapeCount = UInt32(GrokBotAvatarAssets.legacyShapeCount)
        return CloudBotAvatarSpec(shape: Int(h % shapeCount), color: 1 + Int((h / shapeCount) % 11))
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

struct CloudBotShape: Shape {
    let kind: Int
    var showsFace = false
    var gaze: CGSize = .zero
    var eyeOpen: CGFloat = 1
    var mood: CloudBotMood = .calm

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(eyeOpen, AnimatablePair(gaze.width, gaze.height)) }
        set {
            eyeOpen = newValue.first
            gaze = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let asset = GrokBotAvatarAssets.shape(at: kind)
        var mark = asset.body
        if showsFace {
            for eye in asset.eyes {
                mark.addPath(expression(eye))
            }
        }
        return GrokBotAvatarAssets.fitted(mark, in: rect)
    }

    private func expression(_ eye: Path) -> Path {
        let bounds = eye.boundingRect
        let open = min(max(eyeOpen, 0.1), 1)
        let dx = 3 * min(max(gaze.width, -1), 1)
        let dy = 3 * min(max(gaze.height, -1), 1)
        switch mood {
        case .happy where open > 0.5, .frown where open > 0.5, .shy where open > 0.5:
            let stroke = bounds.width * 0.28
            let direction: CGFloat = mood == .happy ? -1 : 1
            var curve = Path()
            curve.move(to: CGPoint(x: bounds.minX + stroke, y: bounds.midY))
            curve.addQuadCurve(to: CGPoint(x: bounds.maxX - stroke, y: bounds.midY),
                               control: CGPoint(x: bounds.midX, y: bounds.midY + direction * bounds.height * 0.45))
            return curve.strokedPath(StrokeStyle(lineWidth: stroke, lineCap: .round))
                .applying(CGAffineTransform(translationX: dx, y: dy))
        default:
            let openness = mood == .dozing ? 0.11 : mood == .focused ? open * 0.64 : open
            return eye.applying(CGAffineTransform(
                a: 1, b: 0, c: 0, d: openness,
                tx: dx, ty: bounds.midY * (1 - openness) + dy
            ))
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
    /// 渲染测试用：只画身体，检查里面有没有接缝
    var showsFace = true
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
            CloudBotShape(kind: spec.shape, showsFace: showsFace, gaze: gaze, eyeOpen: eyeOpen, mood: mood)
                .fill(GrokBotAvatarAssets.color(at: spec.color, scheme: colorScheme), style: FillStyle(eoFill: true))
            if showsFace {
                paintedDetails
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
                    Text("z").font(.system(size: size * 0.22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .offset(x: size * 0.3, y: -size * 0.3)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var paintedDetails: some View {
        let paint = GrokBotAvatarAssets.shape(at: spec.shape).paint
        if !paint.isEmpty {
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                ForEach(paint.indices, id: \.self) { index in
                    let layer = paint[index]
                    GrokBotAvatarAssets.fitted(layer.path, in: bounds).fill(layer.color)
                }
            }
            .accessibilityHidden(true)
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

/// 形状网格 + 颜色点；创建页与编辑页共用
struct CloudBotAvatarPicker: View {
    @Binding var spec: CloudBotAvatarSpec
    @State private var mode = 0
    @Environment(\.colorScheme) private var colorScheme

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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 10)], spacing: 12) {
            ForEach(GrokBotAvatarAssets.pickerIndices, id: \.self) { shape in
                let selected = spec.isShape && spec.shape == shape
                Button {
                    CloudHaptics.selection()
                    spec.shape = shape
                    spec.emoji = nil
                    spec.photo = nil
                    spec.pendingPhoto = nil
                } label: {
                    CloudBotAvatarView(spec: CloudBotAvatarSpec(shape: shape, color: spec.color), size: 40)
                        .frame(width: 46, height: 46)
                        .background { if selected { Circle().fill(.primary.opacity(0.08)) } }
                        .overlay { if selected { Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1.5) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(GrokBotAvatarAssets.shape(at: shape).name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 24)
    }

    private var colorGrid: some View {
        let indices = spec.isShape ? GrokBotAvatarAssets.colorIndices : Array(CloudBotAvatarSpec.colors.indices)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 10) {
            ForEach(indices, id: \.self) { color in
                let selected = (spec.isShape ? GrokBotAvatarAssets.swatchIndex(spec.color) : spec.color) == color
                Button {
                    CloudHaptics.selection()
                    spec.color = color
                    spec.accentOverride = nil
                } label: {
                    Circle()
                        .fill(spec.isShape ? GrokBotAvatarAssets.color(at: color, scheme: colorScheme) : CloudBotAvatarSpec.colors[color])
                        .frame(width: 27, height: 27)
                        .frame(width: 44, height: 44)
                        .overlay { if selected { Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1.5) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("颜色 \(color + 1)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 24)
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
                        .appTextFont(size: 20, weight: .semibold)
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
    /// 首页大头像跟着状态变表情：出错时 .frown；working = 正在思考 / 干活，眨眼更勤
    var mood: CloudBotMood = .calm
    var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cloudScrollInMotion) private var scrolling
    @State private var gaze: CGSize = .zero
    @State private var eyeOpen: CGFloat = 1
    @State private var touching = false
    @State private var bounce: CGFloat = 1
    @State private var shy = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scrolling || reduceMotion || CloudE2E.pauseIdleAnimations)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0 : sin(t * 1.6)
            let tilt = CloudBotMood.tilt(gaze: (Double(gaze.width), Double(gaze.height)), shy: shy)
            CloudBotAvatarView(spec: spec, size: size, gaze: shy ? CGSize(width: tilt.yaw > 0 ? 0.8 : -0.8, height: 0.6) : gaze,
                               eyeOpen: eyeOpen, mood: shy ? .shy : mood)
                .overlay {
                    if !spec.isShape {
                        CloudAvatarSheen(yaw: reduceMotion ? 0 : tilt.yaw, pitch: reduceMotion ? 0 : tilt.pitch)
                            .allowsHitTesting(false)
                    }
                }
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
        .task(id: scrolling ? 3 : (reduceMotion ? 2 : (working ? 1 : 0))) {
            eyeOpen = 1
            if !scrolling, !CloudE2E.pauseIdleAnimations { await live() }
        }
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
            let wait = CloudHomeHeaderRules.blinkWait(working: working)
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: wait) * 1_000_000_000))
            if Task.isCancelled { return }
            if working || Int.random(in: 0..<3) > 0 {
                withAnimation(.easeInOut(duration: 0.07)) { eyeOpen = 0.1 }
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.1)) { eyeOpen = 1 }
                if Int.random(in: 0..<5) == 0 {     // 偶尔连眨两下
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.07)) { eyeOpen = 0.1 }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
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
