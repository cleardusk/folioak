import SwiftUI

// Live breakdown of the draft so users see what Folioak understood before
// starting. Parsing is bounded by the batch limit and has no side effects.
struct InputRecognition: Equatable {
    var papers = 0, media = 0, files = 0, invalid = 0
    let total: Int
    var isOverLimit: Bool { total > ResourceLimits.batchCount }

    init(_ text: String) {
        let tokens = DownloadSource.tokens(in: text)
        total = tokens.count
        guard !isOverLimit else { return }
        for token in tokens {
            switch try? DownloadSource.parse(token) {
            case .arxiv?, .pdf?: papers += 1
            case .media?: media += 1
            case .file?: files += 1
            case nil: invalid += 1
            }
        }
    }
}

struct InputRecognitionChips: View {
    @ObservedObject private var localization = AppLocalization.shared
    let recognition: InputRecognition
    let palette: ThemePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parts: [(id: String, symbol: String, label: String, count: Int, error: Bool)] {
        [("papers", "doc.text", L("论文"), recognition.papers, false),
         ("media", "play.rectangle", L("视频"), recognition.media, false),
         ("files", "doc", L("文件"), recognition.files, false),
         ("invalid", "exclamationmark.circle", L("无法识别"), recognition.invalid, true)].filter { $0.count > 0 }
    }
    private var limitMessage: String { L("每批最多 200 条输入，请分批下载。") }

    var body: some View {
        HStack(spacing: 6) {
            if recognition.isOverLimit {
                Label(L("最多 200 项"), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(UIColors.error)
                    .help(limitMessage)
            }
            ForEach(parts, id: \.id) { part in
                HStack(spacing: 4) {
                    Image(systemName: part.symbol).font(.system(size: 10, weight: .semibold))
                    Text("\(part.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(part.error ? UIColors.error : ThemePalette.color(palette.accent))
                .padding(.horizontal, 8).frame(height: 22)
                .background((part.error ? UIColors.error : ThemePalette.color(palette.accent)).opacity(0.10), in: Capsule())
                .help(part.label + " · " + L("\(part.count) 项"))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: recognition)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recognition.isOverLimit ? limitMessage : parts.map { $0.label + " " + L("\($0.count) 项") }.joined(separator: "，"))
        .accessibilityHidden(recognition.total == 0)
    }
}

// First-run state for the download page: explains scope in one glance and
// offers a single example so a new user reaches a finished file quickly.
struct DownloadsWelcome: View {
    @ObservedObject private var localization = AppLocalization.shared
    let palette: ThemePalette
    let busy: Bool
    let tryExample: () -> Void
    private static let sources = ["arXiv", "OpenReview", "ACL", "CVF", "YouTube", "Bilibili", "X", "抖音", "小红书", "PDF"]
    private var accent: Color { ThemePalette.color(palette.accent) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(decorated: true).fixedSize(horizontal: false, vertical: true)
            content(decorated: false).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(decorated: Bool) -> some View {
        VStack(spacing: 14) {
            if decorated {
                ZStack {
                    Circle().fill(accent.opacity(0.10)).frame(width: 64, height: 64)
                    Circle().strokeBorder(accent.opacity(0.18), lineWidth: 1).frame(width: 88, height: 88)
                    FolioakGlyph().foregroundStyle(accent).frame(width: 28, height: 28)
                }.accessibilityHidden(true).padding(.bottom, 4)
            }
            Text(L("粘贴链接，开始下载")).font(.system(size: 15, weight: .semibold))
            Text(L("论文、视频与文件直链，自动按类型归档到本地。"))
                .font(WorkspaceMetrics.TypeScale.body).foregroundStyle(secondary).multilineTextAlignment(.center)
            if decorated {
                WelcomeFlow(spacing: 6) {
                    ForEach(Self.sources, id: \.self) { source in
                        Text(L(source)).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                            .padding(.horizontal, 9).frame(height: 22)
                            .overlay(Capsule().strokeBorder(ThemePalette.color(palette.border), lineWidth: 1))
                    }
                }.frame(maxWidth: 420).padding(.top, 2)
            }
            Button(action: tryExample) {
                Label(L("试试示例：Attention Is All You Need"), systemImage: "sparkles")
            }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy).padding(.top, 6)
                .help("arxiv.org/abs/1706.03762")
        }.frame(maxWidth: .infinity)
    }
}

// Wrapping row for short chips; avoids GeometryReader feedback loops.
private struct WelcomeFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else { rows.append(([index], size.width, size.height)) }
        }
        return rows
    }
}

// Hidden delight: five quick taps on the sidebar mark fill the window with
// folios and oak leaves that ripen from green to autumn as they fall ("Folio + Oak").
struct BrandMarkAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

struct BrandMark: View {
    let palette: ThemePalette
    let reduceMotion: Bool
    let tapped: () -> Void
    let celebrate: (_ grand: Bool) -> Void
    static let threshold = 5
    #if TESTING
    static var tapTimeOverride: Date?
    #endif
    @WorkspaceViewState private var taps = 0
    @WorkspaceViewState private var lastTap = Date.distantPast
    @WorkspaceViewState private var spin = 0.0
    @WorkspaceViewState private var tilt = 0.0
    @WorkspaceViewState private var scale = 1.0

    var body: some View {
        HStack(spacing: 7) {
            FolioakGlyph().foregroundStyle(ThemePalette.color(palette.accent)).frame(width: 17, height: 17)
                .rotationEffect(.degrees(spin + tilt)).scaleEffect(scale)
                .anchorPreference(key: BrandMarkAnchor.self, value: .bounds) { $0 }
                .accessibilityHidden(true)
            Text("Folioak").font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ThemePalette.color(palette.text))
        }.contentShape(Rectangle()).onTapGesture(perform: tap)
    }

    private func tap() {
        tapped()
        #if TESTING
        let now = Self.tapTimeOverride ?? Date()
        #else
        let now = Date()
        #endif
        taps = now.timeIntervalSince(lastTap) < 0.6 ? taps + 1 : 1
        lastTap = now
        // Every fifth tap of a streak is a full round; taps between rounds
        // add small gusts, and a pause starts the count over.
        let grand = taps.isMultiple(of: Self.threshold)
        guard taps >= Self.threshold else {
            guard !reduceMotion else { return }
            // Each tap winds the mark a little further so the build-up is felt.
            let direction: Double = taps.isMultiple(of: 2) ? -1 : 1
            withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { tilt = Double(taps) * 6 * direction; scale = 1 + Double(taps) * 0.07 }
            settle(after: 0.16)
            return
        }
        celebrate(grand)
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { spin += grand ? 360 : 0; tilt = grand ? 0 : (taps.isMultiple(of: 2) ? -14 : 14) }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { scale = grand ? 1.5 : 1.25 }
        settle(after: 0.18)
    }

    private func settle(after delay: Double) {
        let mark = taps
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard mark == taps else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) { tilt = 0; scale = 1 }
        }
    }
}

struct LeafBurst: Identifiable {
    enum Kind { case leaf, page, spark }
    struct Particle {
        var kind: Kind, sky: Bool, column: Double, angle: Double, reach: Double, drag: Double, fall: Double, wind: Double
        var sway: Double, swayRate: Double, phase: Double, rotation: Double, spin: Double, flipRate: Double
        var size: Double, life: Double, delay: Double, rest: Double, from: UInt32, to: UInt32
    }
    #if TESTING
    static var triggered = 0, grandTriggered = 0
    #endif
    let id = UUID()
    let start = Date()
    let grand: Bool
    let duration: Double
    let particles: [Particle]
    var retired: Date?
    static let retireDuration = 0.7

    // Visibility multiplier: 1 while live, easing to 0 once retired early.
    func presence(at now: Date) -> Double {
        guard let retired else { return 1 }
        let t = min(1, max(0, now.timeIntervalSince(retired) / Self.retireDuration))
        return 1 - t * t * (3 - 2 * t)
    }

    // The grand burst is a gust from the mark followed by a canopy shower
    // across the whole window; leaves settle on the bottom edge, then fade.
    // Extra taps add smaller gusts. Distances are window fractions.
    init(grand: Bool, accent: UInt32) {
        self.grand = grand
        duration = grand ? 7.4 : 4.6
        #if TESTING
        Self.triggered += 1; if grand { Self.grandTriggered += 1 }
        #endif
        let greens: [UInt32] = [accent, 0x2F9E63, 0x6DBE4B, 0x1F6B45]
        let autumn: [UInt32] = [0xF2CC5B, 0xE8B53A, 0xE07B2C, 0xC2502F, 0x9C6B3C, 0xD9893B]
        let duration = duration
        func particle(_ index: Int, sky: Bool) -> Particle {
            let roll = Double.random(in: 0..<1)
            let kind: Kind = sky ? (roll < 0.8 ? .leaf : .page) : roll < 0.6 ? .leaf : roll < 0.8 ? .page : .spark
            let from = kind == .page ? 0 : greens[index % greens.count]
            // A fifth of the leaves stay green; the rest turn as they fall.
            let to = kind == .page ? 0 : Double.random(in: 0..<1) < 0.2 ? from : autumn.randomElement()!
            let delay = sky ? Double.random(in: 0.12...1.9) : .random(in: 0...0.08)
            let spark = kind == .spark
            return Particle(kind: kind, sky: sky, column: .random(in: -0.08...1.0), angle: .random(in: -1.25...1.45),
                            reach: spark ? .random(in: 0.12...0.42) : grand ? .random(in: 0.3...1.05) : .random(in: 0.18...0.55),
                            drag: spark ? .random(in: 3.2...4.2) : .random(in: 1.6...2.4),
                            fall: spark ? .random(in: 0.01...0.04) : .random(in: 0.2...0.36), wind: .random(in: -10...42),
                            sway: .random(in: 14...42), swayRate: .random(in: 1.3...2.6), phase: .random(in: 0...(2 * .pi)),
                            rotation: .random(in: 0...(2 * .pi)), spin: .random(in: -2.8...2.8), flipRate: .random(in: 2.2...5.5),
                            size: spark ? .random(in: 6...11) : kind == .page ? .random(in: 13...20) : .random(in: 13...26),
                            life: spark ? .random(in: 0.9...1.8) : duration - delay - .random(in: 0...0.9),
                            delay: delay, rest: .random(in: 3...22), from: from, to: to)
        }
        particles = (0..<(grand ? 64 : 22)).map { particle($0, sky: false) } + (0..<(grand ? 120 : 0)).map { particle($0, sky: true) }
    }
}

// Live bursts across repeated rounds. New rounds never cut an older one
// off mid-frame: when the particle budget is exceeded the oldest bursts
// retire and fade out quickly instead of popping, so rapid or overlapping
// rounds stay smooth. Retiring particles remain for the short fade-out.
struct LeafBurstStack {
    static let particleBudget = 420
    private(set) var bursts: [LeafBurst] = []
    var isEmpty: Bool { bursts.isEmpty }
    var liveParticles: Int { bursts.filter { $0.retired == nil }.reduce(0) { $0 + $1.particles.count } }

    /// Adds a burst and returns the bursts retired to make room.
    mutating func push(_ burst: LeafBurst, now: Date = Date()) -> [UUID] {
        bursts.append(burst)
        var retired: [UUID] = []
        for index in bursts.indices where bursts[index].id != burst.id && bursts[index].retired == nil {
            guard liveParticles > Self.particleBudget else { break }
            bursts[index].retired = now
            retired.append(bursts[index].id)
        }
        return retired
    }

    mutating func remove(_ id: UUID) { bursts.removeAll { $0.id == id } }
}

// Tinted copies of the leaf glyph, quantized so ripening reuses bitmaps.
enum LeafTint {
    private static var cache: [UInt32: NSImage] = [:]
    private static let lock = NSLock()
    static func image(_ hex: UInt32) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        if let image = cache[hex] { return image }
        guard let base = FolioakGlyph.image,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        let rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: rect)
        ThemePalette.nativeColor(hex).set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        cache[hex] = image
        return image
    }
}

struct LeafBurstOverlay: View {
    let bursts: [LeafBurst]
    let origin: CGPoint
    let palette: ThemePalette
    @Environment(\.colorScheme) private var scheme
    #if TESTING
    static var mounted = 0
    #endif

    var body: some View {
        TimelineView(.animation) { timeline in
            canvas(at: timeline.date)
        }.allowsHitTesting(false).accessibilityHidden(true)
        #if TESTING
        .onAppear { Self.mounted += 1 }
        .onDisappear { Self.mounted -= 1 }
        #endif
    }

    func canvas(at now: Date) -> some View {
        Canvas { context, size in
            var leaves: [UInt32: GraphicsContext.ResolvedImage] = [:]
            let resolver = context
            func leaf(_ hex: UInt32) -> GraphicsContext.ResolvedImage? {
                if let image = leaves[hex] { return image }
                guard let tinted = LeafTint.image(hex) else { return nil }
                let image = resolver.resolve(Image(nsImage: tinted)); leaves[hex] = image; return image
            }
            // Overlapping rounds share one light: each keeps its own sweep, but
            // levels are normalized so the total never exceeds the brightest
            // and the handoff between rounds stays continuous.
            let glows = bursts.filter(\.grand).map { burst -> (level: Double, age: Double) in
                let age = now.timeIntervalSince(burst.start)
                return (glowLevel(age: age, duration: burst.duration) * burst.presence(at: now), age)
            }
            let total = glows.reduce(0) { $0 + $1.level }, peak = glows.map(\.level).max() ?? 0
            for glow in glows where glow.level > 0.001 { drawGlow(&context, size: size, level: glow.level * peak / total, age: glow.age) }
            for burst in bursts {
                let age = now.timeIntervalSince(burst.start), presence = burst.presence(at: now)
                guard presence > 0.001 else { continue }
                var layer = context
                layer.opacity = presence
                if burst.grand { drawRipple(&layer, age: age) }
                for particle in burst.particles { draw(particle, age: age - particle.delay, size: size, leaf: leaf, in: &layer) }
            }
        }
    }

    // A soft wash of light sweeps out from the mark as the gust leaves it,
    // lingers through the leaf shower and dims with it rather than ahead of it.
    private func glowLevel(age: Double, duration: Double) -> Double {
        let end = duration - 0.4
        guard age > 0, age < end else { return 0 }
        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        // Flash on launch, settle to a warm afterglow, then ease out with the shower.
        let flash = 1 - 0.45 * smooth((age - 0.35) / 1.2)
        return smooth(age / 0.25) * flash * (1 - smooth((age - 2.6) / (end - 2.6)))
    }

    private func drawGlow(_ context: inout GraphicsContext, size: CGSize, level: Double, age: Double) {
        let diagonal = hypot(size.width, size.height)
        let alpha = (scheme == .dark ? 0.18 : 0.14) * level
        let radius = 40 + diagonal * (1 - pow(1 - min(1, age / 1.4), 3))
        let tint = ThemePalette.color(palette.accent)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(stops: [.init(color: Color(.sRGB, red: 1, green: 0.86, blue: 0.5).opacity(alpha), location: 0),
                             .init(color: tint.opacity(alpha * 0.7), location: 0.45), .init(color: tint.opacity(0), location: 1)]),
            center: origin, startRadius: 0, endRadius: radius))
    }

    private func drawRipple(_ context: inout GraphicsContext, age: Double) {
        for (offset, reach) in [(0.0, 120.0), (0.12, 70.0), (0.24, 40.0)] {
            let t = (age - offset) / 0.75
            guard t > 0, t < 1 else { continue }
            let eased = 1 - pow(1 - t, 3), radius = 8 + reach * eased
            let ring = Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(ThemePalette.color(palette.accent).opacity(0.55 * (1 - t))), lineWidth: 2.4 * (1 - t) + 0.4)
        }
    }

    private func draw(_ p: LeafBurst.Particle, age t: Double, size: CGSize, leaf: (UInt32) -> GraphicsContext.ResolvedImage?,
                      in context: inout GraphicsContext) {
        guard t > 0, t < p.life else { return }
        // Air drag pulls each piece from its launch velocity to a slow,
        // swaying terminal fall, like a leaf rather than a ball.
        let diagonal = hypot(size.width, size.height), terminal = p.fall * size.height
        let start = p.sky ? CGPoint(x: p.column * size.width, y: -24) : origin
        let speed = p.reach * diagonal * p.drag
        let vx = p.sky ? p.wind : cos(p.angle) * speed, vy = p.sky ? terminal : sin(p.angle) * speed
        func position(_ t: Double) -> CGPoint {
            let settled = 1 - exp(-p.drag * t)
            return CGPoint(x: start.x + p.wind * t + (vx - p.wind) / p.drag * settled + p.sway * sin(p.swayRate * t + p.phase) * settled,
                           y: start.y + terminal * t + (vy - terminal) / p.drag * settled)
        }
        var time = t, point = position(t)
        let floor = size.height - p.rest
        let landed = p.kind != .spark && point.y > floor
        if landed {
            // Falling is monotonic after the apex; search for the landing moment.
            var low = vy < 0 ? log((terminal - vy) / terminal) / p.drag : 0, high = t
            for _ in 0..<18 { let mid = (low + high) / 2; if position(mid).y > floor { high = mid } else { low = mid } }
            time = high; point = CGPoint(x: position(high).x, y: floor)
        }
        let progress = t / p.life
        let fade = min(1, t / 0.08) * (p.kind == .spark ? (progress > 0.6 ? max(0, 1 - (progress - 0.6) / 0.4) : 1)
                                                      : min(1, (p.life - t) / 0.9))
        var c = context
        c.opacity *= fade
        c.translateBy(x: point.x, y: point.y)
        c.rotate(by: .radians(p.rotation + p.spin * time))
        let flip = cos(p.flipRate * time + p.phase)
        // Settled pieces lie face up instead of freezing edge-on.
        let face = landed ? (flip < 0 ? -1 : 1) * max(0.6, abs(flip)) : flip
        let s = p.size
        switch p.kind {
        case .leaf:
            c.scaleBy(x: face, y: 1)
            let ripen = min(1, max(0, (time / max(1, p.life - 1) - 0.1) / 0.6))
            let step = (ripen * ripen * (3 - 2 * ripen) * 10).rounded() / 10
            let rect = CGRect(x: -s / 2, y: -s / 2, width: s, height: s)
            if let image = leaf(Self.blend(p.from, p.to, step)) { c.draw(image, in: rect) }
            else { c.fill(Path(ellipseIn: rect.insetBy(dx: s * 0.2, dy: 0)), with: .color(ThemePalette.color(Self.blend(p.from, p.to, step)))) }
        case .page:
            c.scaleBy(x: face, y: 1)
            let rect = CGRect(x: -s * 0.38, y: -s / 2, width: s * 0.76, height: s)
            let sheet = Path(roundedRect: rect, cornerRadius: 1.6)
            c.fill(sheet, with: .color(ThemePalette.color(scheme == .dark ? 0xE7EEE9 : 0xFFFDF6)))
            c.stroke(sheet, with: .color(ThemePalette.color(palette.accent).opacity(0.8)), lineWidth: 1)
            for line in 0..<3 {
                let lineY = rect.minY + s * (0.28 + Double(line) * 0.2)
                let width = rect.width * (line == 2 ? 0.4 : 0.64)
                c.fill(Path(CGRect(x: rect.minX + rect.width * 0.18, y: lineY, width: width, height: 0.9)),
                       with: .color(ThemePalette.color(palette.accent).opacity(0.5)))
            }
        case .spark:
            c.opacity *= 0.55 + 0.45 * sin(t * 18 + p.phase)
            c.fill(Self.star(s), with: .color(ThemePalette.color(Self.blend(p.from, 0xF2CC5B, progress))))
        }
    }

    private static func star(_ size: Double) -> Path {
        var path = Path()
        for index in 0..<8 {
            let radius = index.isMultiple(of: 2) ? size / 2 : size * 0.14
            let angle = Double(index) * .pi / 4 - .pi / 2
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 255), y = Double((b >> shift) & 255)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

struct FolioNote: View {
    #if TESTING
    static var presented = 0
    #endif
    @ObservedObject private var localization = AppLocalization.shared
    let palette: ThemePalette
    let round: Int
    // Later rounds continue the story instead of repeating the first line.
    static let lines = ["每一页，都是一片叶子。", "风起时，书页翻动。", "落叶归根，文件归档。", "满园秋色，尽在一页。"]

    var body: some View {
        HStack(spacing: 10) {
            FolioakGlyph().foregroundStyle(ThemePalette.color(palette.accent)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Folio + Oak").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(L(Self.lines[round % Self.lines.count])).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
            }
        }
        .padding(.leading, 14).padding(.trailing, 18).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(ThemePalette.color(palette.border).opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
