import SwiftUI
import UIKit

/// 消息里的一组图片（本地对话和 Bot 对话共用）
struct ImageStackSource: Identifiable {
    enum Upload: Equatable { case done, uploading(Double?), failed }
    let id: String
    let load: () async -> UIImage?
    var state: Upload = .done
}

/// 一张 = 一张圆角卡；多张 = 略微旋转错开的一摞 +「N 张图片」。
/// 长按铺开；手指不松开左右滑时，CADisplayLink 跟手高亮/放大当前那张，滑动后松手即全屏打开那张。
struct ImageCardStack: View {
    let sources: [ImageStackSource]
    var alignment: HorizontalAlignment = .trailing
    let onOpen: (Int) -> Void
    var onRetry: (() -> Void)? = nil

    var body: some View {
        let count = sources.count
        VStack(alignment: alignment, spacing: ImageStackLayout.captionSpacing) {
            ImageStackScrubHost(sources: sources, onOpen: onOpen, onRetry: onRetry)
                .frame(width: ImageStackLayout.stackSize(count: count).width,
                       height: ImageStackLayout.stackSize(count: count).height)
            if let caption = ImageStackLayout.caption(count) {
                Label(caption, systemImage: "square.stack")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(height: ImageStackLayout.captionHeight)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// UIKit 宿主：长按 / 滑动由 UILongPress 处理，位置与缩放用 CADisplayLink 跟到 120Hz。
struct ImageStackScrubHost: UIViewRepresentable {
    let sources: [ImageStackSource]
    let onOpen: (Int) -> Void
    var onRetry: (() -> Void)?

    func makeUIView(context: Context) -> ImageStackScrubView {
        let v = ImageStackScrubView()
        v.onOpen = onOpen
        v.onRetry = onRetry
        v.apply(sources: sources)
        return v
    }

    func updateUIView(_ uiView: ImageStackScrubView, context: Context) {
        uiView.onOpen = onOpen
        uiView.onRetry = onRetry
        uiView.apply(sources: sources)
    }
}

final class ImageStackScrubView: UIView {
    var onOpen: (Int) -> Void = { _ in }
    var onRetry: (() -> Void)?

    private var sources: [ImageStackSource] = []
    private var cardViews: [UIImageView] = []
    private var badges: [UIView] = []
    private var images: [String: UIImage] = [:]
    private var loadIDs: [String: UUID] = [:]
    private var fanned = false
    private var focused = 0
    private var startedFanned = false
    private var startLocation: CGPoint = .zero
    private var displayLink: CADisplayLink?
    private var currentScale: [CGFloat] = []
    private var currentCenter: [CGPoint] = []
    private var currentRotation: [CGFloat] = []
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "imageStack"
        accessibilityTraits.insert(.button)
        accessibilityHint = "轻点全屏查看"
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(press(_:)))
        lp.minimumPressDuration = 0.35
        lp.allowableMovement = 10_000
        addGestureRecognizer(lp)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: lp)
        addGestureRecognizer(tap)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { ImageStackLayout.stackSize(count: sources.count) }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout(animated: false)
    }

    override func accessibilityActivate() -> Bool {
        onOpen(0)
        return true
    }

    func apply(sources newSources: [ImageStackSource]) {
        let ids = newSources.map(\.id)
        let old = sources.map(\.id)
        sources = newSources
        if ids != old {
            rebuildCards()
            if !fanned { focused = 0 }
        }
        refreshBadges()
        loadMissingImages()
        updateAccessibility()
        applyLayout(animated: false)
        invalidateIntrinsicContentSize()
    }

    private func rebuildCards() {
        cardViews.forEach { $0.removeFromSuperview() }
        badges.forEach { $0.removeFromSuperview() }
        cardViews = []
        badges = []
        currentScale = []
        currentCenter = []
        currentRotation = []
        let count = sources.count
        let size = count == 1 ? ImageStackLayout.singleSize : ImageStackLayout.cardSize
        for _ in 0..<count {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = ImageStackLayout.cornerRadius
            iv.layer.cornerCurve = .continuous
            iv.layer.borderWidth = 0.5
            iv.layer.borderColor = UIColor.label.withAlphaComponent(0.08).cgColor
            iv.backgroundColor = .secondarySystemFill
            iv.layer.shadowColor = UIColor.black.cgColor
            iv.layer.shadowOpacity = count == 1 ? 0 : 0.12
            iv.layer.shadowRadius = 6
            iv.layer.shadowOffset = CGSize(width: 0, height: 2)
            iv.frame = CGRect(origin: .zero, size: size)
            addSubview(iv)
            cardViews.append(iv)
            let badge = UIView()
            badge.isUserInteractionEnabled = true
            iv.addSubview(badge)
            badges.append(badge)
            currentScale.append(1)
            currentCenter.append(CGPoint(x: bounds.midX, y: bounds.midY))
            currentRotation.append(0)
        }
    }

    private func loadMissingImages() {
        for (i, src) in sources.enumerated() {
            if let img = images[src.id] {
                if i < cardViews.count { cardViews[i].image = img }
                continue
            }
            let token = UUID()
            loadIDs[src.id] = token
            Task { [weak self] in
                let img = await src.load()
                await MainActor.run {
                    guard let self, self.loadIDs[src.id] == token else { return }
                    if let img {
                        self.images[src.id] = img
                        if i < self.cardViews.count, self.sources.indices.contains(i), self.sources[i].id == src.id {
                            self.cardViews[i].image = img
                        }
                    }
                }
            }
        }
    }

    private func refreshBadges() {
        for (i, src) in sources.enumerated() where i < badges.count {
            let host = badges[i]
            host.subviews.forEach { $0.removeFromSuperview() }
            let size = sources.count == 1 ? ImageStackLayout.singleSize : ImageStackLayout.cardSize
            host.frame = CGRect(origin: .zero, size: size)
            switch src.state {
            case .done:
                break
            case .uploading(let p):
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.color = .white
                spinner.startAnimating()
                spinner.center = CGPoint(x: size.width / 2, y: size.height / 2)
                let dim = UIView(frame: host.bounds)
                dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
                dim.isUserInteractionEnabled = false
                host.addSubview(dim)
                host.addSubview(spinner)
                if let p {
                    let ring = ImageStackProgressRing(progress: p)
                    ring.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
                    ring.center = spinner.center
                    host.addSubview(ring)
                    spinner.isHidden = true
                }
            case .failed:
                let btn = UIButton(type: .system)
                btn.setTitle("重试", for: .normal)
                btn.setTitleColor(.white, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
                btn.backgroundColor = UIColor.red.withAlphaComponent(0.85)
                btn.layer.cornerRadius = 14
                btn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
                btn.sizeToFit()
                btn.center = CGPoint(x: size.width / 2, y: size.height / 2)
                btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
                host.addSubview(btn)
            }
        }
    }

    @objc private func retryTapped() { onRetry?() }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        onOpen(ImageStackLayout.hitIndex(at: p, count: sources.count, fanned: fanned))
    }

    @objc private func press(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        let count = sources.count
        guard count > 1 else { return }
        switch g.state {
        case .began:
            startLocation = p
            startedFanned = fanned
            focused = ImageStackLayout.focusedIndex(atX: p.x, count: count)
            if !fanned {
                fanned = true
                impact.prepare()
                impact.impactOccurred()
            }
            updateAccessibility()
            startLink()
        case .changed:
            let next = ImageStackLayout.focusedIndex(atX: p.x, count: count)
            if next != focused {
                focused = next
                selection.selectionChanged()
                updateAccessibility()
            }
        case .ended, .cancelled:
            let trans = hypot(p.x - startLocation.x, p.y - startLocation.y)
            if ImageStackLayout.shouldOpenOnRelease(translation: trans) {
                let idx = focused
                fanned = false
                updateAccessibility()
                onOpen(idx)
            } else if startedFanned {
                fanned = false
                focused = 0
                updateAccessibility()
            }
            // 刚展开、几乎没滑：保持展开，等下一次长按收回，或轻点打开
            updateAccessibility()
        default:
            break
        }
    }

    private func startLink() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stopLinkIfIdle() {
        let done = zip(currentScale, targetScales()).allSatisfy { abs($0 - $1) < 0.005 }
        if done {
            displayLink?.invalidate()
            displayLink = nil
            applyLayout(animated: false)
        }
    }

    private func targetScales() -> [CGFloat] {
        sources.indices.map { ImageStackLayout.scale(index: $0, focused: focused, fanned: fanned) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        applyLayout(animated: true, dt: link.duration > 0 ? link.duration : 1.0 / 120.0)
        stopLinkIfIdle()
    }

    private func applyLayout(animated: Bool, dt: CFTimeInterval = 1.0 / 120.0) {
        let count = sources.count
        guard count > 0, cardViews.count == count else { return }
        let box = ImageStackLayout.stackSize(count: count)
        let size = count == 1 ? ImageStackLayout.singleSize : ImageStackLayout.cardSize
        let cards = ImageStackLayout.cards(count: count, fanned: fanned)
        let k: CGFloat = animated ? CGFloat(1 - exp(-dt / 0.08)) : 1
        // index -> card layout
        var byIndex: [Int: ImageStackLayout.Card] = [:]
        for c in cards { byIndex[c.index] = c }
        for i in 0..<count {
            let card = byIndex[i] ?? ImageStackLayout.Card(index: i, rotation: 0, offset: .zero, zIndex: 0)
            let targetCenter = CGPoint(x: box.width / 2 + card.offset.width,
                                       y: box.height / 2 + card.offset.height)
            let targetScale = ImageStackLayout.scale(index: i, focused: focused, fanned: fanned)
            let targetRot = CGFloat(card.rotation) * .pi / 180
            if currentCenter.indices.contains(i) {
                currentCenter[i].x += (targetCenter.x - currentCenter[i].x) * k
                currentCenter[i].y += (targetCenter.y - currentCenter[i].y) * k
                currentScale[i] += (targetScale - currentScale[i]) * k
                currentRotation[i] += (targetRot - currentRotation[i]) * k
            }
            let iv = cardViews[i]
            iv.bounds = CGRect(origin: .zero, size: size)
            iv.center = currentCenter.indices.contains(i) ? currentCenter[i] : targetCenter
            let s = currentScale.indices.contains(i) ? currentScale[i] : targetScale
            let r = currentRotation.indices.contains(i) ? currentRotation[i] : targetRot
            iv.transform = CGAffineTransform(rotationAngle: r).scaledBy(x: s, y: s)
            iv.layer.zPosition = card.zIndex + (fanned && i == focused ? 10 : 0)
            iv.layer.borderWidth = (fanned && i == focused) ? 2 : 0.5
            iv.layer.borderColor = (fanned && i == focused)
                ? UIColor.white.withAlphaComponent(0.9).cgColor
                : UIColor.label.withAlphaComponent(0.08).cgColor
        }
    }

    private func updateAccessibility() {
        let count = sources.count
        accessibilityLabel = count == 1 ? "图片" : "\(count) 张图片"
        if count > 1 {
            if fanned {
                accessibilityValue = "已展开"
            } else {
                accessibilityValue = "叠放"
            }
        } else {
            accessibilityValue = nil
        }
    }

    deinit { displayLink?.invalidate() }
}

/// 上传进度环（跟手选择不依赖它，只给上传中的卡用）
private final class ImageStackProgressRing: UIView {
    var progress: Double = 0 { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        let inset = rect.insetBy(dx: 3, dy: 3)
        let path = UIBezierPath(arcCenter: CGPoint(x: rect.midX, y: rect.midY),
                                radius: inset.width / 2,
                                startAngle: -.pi / 2,
                                endAngle: -.pi / 2 + 2 * .pi * CGFloat(max(0.02, progress)),
                                clockwise: true)
        UIColor.white.setStroke()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.stroke()
    }
}

/// 卡片上的上传进度圈 / 失败重试（SwiftUI 托盘仍用这一套）
struct ImageUploadBadge: View {
    let state: ImageStackSource.Upload
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .done:
            EmptyView()
        case .uploading(let p):
            ZStack {
                Circle().fill(.black.opacity(0.35))
                Circle().stroke(.white.opacity(0.3), lineWidth: 3).padding(6)
                if let p {
                    Circle().trim(from: 0, to: max(0.02, p)).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(6)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("正在上传")
        case .failed:
            Button { onRetry?() } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .disabled(onRetry == nil)
        }
    }
}
