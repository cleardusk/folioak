import SwiftUI

// Live breakdown of the draft so users see what Folioak understood before
// starting. Parsing is bounded by the batch limit and has no side effects.
struct InputRecognition: Equatable {
    var papers = 0, media = 0, files = 0, invalid = 0
    var total: Int { papers + media + files + invalid }

    init(_ text: String) {
        for token in DownloadSource.tokens(in: text).prefix(ResourceLimits.batchCount) {
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

    var body: some View {
        HStack(spacing: 6) {
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
        .accessibilityLabel(parts.map { $0.label + " " + L("\($0.count) 项") }.joined(separator: "，"))
        .accessibilityHidden(parts.isEmpty)
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
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.10)).frame(width: 64, height: 64)
                Circle().strokeBorder(accent.opacity(0.18), lineWidth: 1).frame(width: 88, height: 88)
                FolioakGlyph().foregroundStyle(accent).frame(width: 28, height: 28)
            }.accessibilityHidden(true).padding(.bottom, 4)
            Text(L("粘贴链接，开始下载")).font(.system(size: 15, weight: .semibold))
            Text(L("论文、视频与文件直链，自动按类型归档到本地。"))
                .font(WorkspaceMetrics.TypeScale.body).foregroundStyle(secondary).multilineTextAlignment(.center)
            WelcomeFlow(spacing: 6) {
                ForEach(Self.sources, id: \.self) { source in
                    Text(L(source)).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                        .padding(.horizontal, 9).frame(height: 22)
                        .overlay(Capsule().strokeBorder(ThemePalette.color(palette.border), lineWidth: 1))
                }
            }.frame(maxWidth: 420).padding(.top, 2)
            Button(action: tryExample) {
                Label(L("试试示例：Attention Is All You Need"), systemImage: "sparkles")
            }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy).padding(.top, 6)
                .help("arxiv.org/abs/1706.03762")
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
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

// Hidden delight: five quick taps on the sidebar mark scatter folios and oak
// leaves that ripen from green to autumn as they fall ("Folio + Oak").
struct BrandMarkAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

struct BrandMark: View {
    let palette: ThemePalette
    let tapped: () -> Void
    let celebrate: (_ grand: Bool) -> Void
    static let threshold = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let now = Date()
        taps = now.timeIntervalSince(lastTap) < 0.6 ? taps + 1 : 1
        lastTap = now
        guard taps >= Self.threshold else {
            guard !reduceMotion else { return }
            // Each tap winds the mark a little further so the build-up is felt.
            let direction: Double = taps.isMultiple(of: 2) ? -1 : 1
            withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { tilt = Double(taps) * 6 * direction; scale = 1 + Double(taps) * 0.07 }
            settle(after: 0.16)
            return
        }
        celebrate(taps == Self.threshold)
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { spin += 360; tilt = 0 }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { scale = taps == Self.threshold ? 1.5 : 1.25 }
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
        var kind: Kind, angle: Double, speed: Double, drag: Double, terminal: Double, wind: Double
        var sway: Double, swayRate: Double, phase: Double, rotation: Double, spin: Double, flipRate: Double
        var size: Double, life: Double, delay: Double, from: UInt32, to: UInt32
    }
    static let duration = 3.6
    #if TESTING
    static var triggered = 0
    #endif
    let id = UUID()
    let start = Date()
    let grand: Bool
    let particles: [Particle]

    init(grand: Bool, accent: UInt32) {
        self.grand = grand
        #if TESTING
        Self.triggered += 1
        #endif
        let greens: [UInt32] = [accent, 0x2F9E63, 0x6DBE4B]
        let autumn: [UInt32] = [0xF2CC5B, 0xE8B53A, 0xE07B2C, 0xC2502F, 0x9C6B3C]
        particles = (0..<(grand ? 46 : 16)).map { index in
            let roll = Double.random(in: 0..<1)
            let kind: Kind = roll < 0.62 ? .leaf : roll < 0.84 ? .page : .spark
            let from = kind == .page ? 0 : greens[index % greens.count]
            // A quarter of the leaves stay green; the rest turn as they fall.
            let to = kind == .page ? 0 : Double.random(in: 0..<1) < 0.25 ? from : autumn.randomElement()!
            return Particle(kind: kind, angle: .random(in: -1.15...0.9), speed: .random(in: grand ? 240...700 : 160...420),
                            drag: kind == .spark ? .random(in: 3.2...4.2) : .random(in: 1.7...2.6),
                            terminal: kind == .spark ? .random(in: 10...30) : .random(in: 45...105), wind: .random(in: -8...28),
                            sway: .random(in: 10...30), swayRate: .random(in: 1.6...3.0), phase: .random(in: 0...(2 * .pi)),
                            rotation: .random(in: 0...(2 * .pi)), spin: .random(in: -3.2...3.2), flipRate: .random(in: 2.5...6.5),
                            size: kind == .spark ? .random(in: 6...10) : kind == .page ? .random(in: 12...18) : .random(in: 12...22),
                            life: kind == .spark ? .random(in: 0.9...1.6) : .random(in: 2.3...LeafBurst.duration - 0.2),
                            delay: .random(in: 0...0.09), from: from, to: to)
        }
    }
}

struct LeafBurstOverlay: View {
    let bursts: [LeafBurst]
    let origin: CGPoint
    let palette: ThemePalette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let now = timeline.date
                let leaf = context.resolve(FolioakGlyph.image.map { Image(nsImage: $0) } ?? Image(systemName: "leaf.fill"))
                for burst in bursts {
                    let age = now.timeIntervalSince(burst.start)
                    if burst.grand { drawRipple(&context, age: age) }
                    for particle in burst.particles { draw(particle, age: age - particle.delay, leaf: leaf, in: &context) }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func drawRipple(_ context: inout GraphicsContext, age: Double) {
        for (offset, reach) in [(0.0, 74.0), (0.1, 46.0)] {
            let t = (age - offset) / 0.65
            guard t > 0, t < 1 else { continue }
            let eased = 1 - pow(1 - t, 3), radius = 8 + reach * eased
            let ring = Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(ThemePalette.color(palette.accent).opacity(0.55 * (1 - t))), lineWidth: 2.2 * (1 - t) + 0.4)
        }
    }

    private func draw(_ p: LeafBurst.Particle, age t: Double, leaf: GraphicsContext.ResolvedImage, in context: inout GraphicsContext) {
        guard t > 0, t < p.life else { return }
        // Air drag pulls each piece from its launch velocity to a slow,
        // swaying terminal fall, like a leaf rather than a ball.
        let decay = exp(-p.drag * t), settled = 1 - decay
        let vx = cos(p.angle) * p.speed, vy = sin(p.angle) * p.speed
        let x = origin.x + p.wind * t + (vx - p.wind) / p.drag * settled + p.sway * sin(p.swayRate * t + p.phase) * settled
        let y = origin.y + p.terminal * t + (vy - p.terminal) / p.drag * settled
        let progress = t / p.life
        let fade = min(1, t / 0.08) * (progress > 0.7 ? max(0, 1 - (progress - 0.7) / 0.3) : 1)
        var c = context
        c.opacity = fade
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians(p.rotation + p.spin * t))
        let s = p.size
        switch p.kind {
        case .leaf:
            c.scaleBy(x: cos(p.flipRate * t + p.phase), y: 1)
            let ripen = min(1, max(0, (progress - 0.15) / 0.6))
            let rect = CGRect(x: -s / 2, y: -s / 2, width: s, height: s)
            // The glyph's alpha masks a solid fill so the leaf can ripen in color.
            c.clipToLayer { $0.draw(leaf, in: rect) }
            c.fill(Path(rect), with: .color(Self.blend(p.from, p.to, ripen * ripen * (3 - 2 * ripen))))
        case .page:
            c.scaleBy(x: cos(p.flipRate * t + p.phase), y: 1)
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
            c.opacity = fade * (0.55 + 0.45 * sin(t * 18 + p.phase))
            c.fill(Self.star(s), with: .color(Self.blend(p.from, 0xF2CC5B, progress)))
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

    private static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let x = Double((a >> shift) & 255), y = Double((b >> shift) & 255)
            return (x + (y - x) * t) / 255
        }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0))
    }
}

struct FolioNote: View {
    @ObservedObject private var localization = AppLocalization.shared
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 10) {
            FolioakGlyph().foregroundStyle(ThemePalette.color(palette.accent)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Folio + Oak").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(L("每一页，都是一片叶子。")).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
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
