import SwiftUI

struct SidebarToggleGlyph: View {
    let expanded: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.5)
            SidebarToggleDetail(progress: expanded ? 1 : 0)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.frame(width: 22, height: 18).accessibilityHidden(true)
    }
}

// The pane narrows while the chevron folds toward the next available action.
struct SidebarToggleDetail: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        let divider = rect.minX + 2 + 5 * p
        let center = rect.minX + 11 + 3 * p
        let direction = 1 - 2 * p
        return Path { path in
            path.move(to: CGPoint(x: divider, y: rect.minY + 1))
            path.addLine(to: CGPoint(x: divider, y: rect.maxY - 1))
            path.move(to: CGPoint(x: center - 2 * direction, y: rect.midY - 3))
            path.addLine(to: CGPoint(x: center + 2 * direction, y: rect.midY))
            path.addLine(to: CGPoint(x: center - 2 * direction, y: rect.midY + 3))
        }
    }
}

// FlClash's two-edge indicator timing, expressed independently for SwiftUI.
// Using the current geometry as the origin keeps quick reversals continuous.
struct SelectionIndicatorMotion {
    static let duration = 0.320
    static let height: CGFloat = 16
    let axis: Axis
    var origin: CGRect
    var target: CGRect
    var startedAt: Date

    init(index: Int, stride: CGFloat = 50) {
        let rect = Self.restingRect(index: index, stride: stride)
        self.init(rect: rect, axis: .vertical)
    }

    init(rect: CGRect, axis: Axis) {
        self.axis = axis
        origin = rect; target = rect; startedAt = .distantPast
    }

    static func restingRect(index: Int, stride: CGFloat) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * stride + (44 - height) / 2, width: 3, height: height)
    }

    mutating func select(_ index: Int, stride: CGFloat, at date: Date, reduceMotion: Bool) {
        select(Self.restingRect(index: index, stride: stride), at: date, reduceMotion: reduceMotion)
    }

    mutating func select(_ next: CGRect, at date: Date, reduceMotion: Bool) {
        guard next != target else { return }
        origin = rect(at: date); target = next
        startedAt = reduceMotion ? .distantPast : date
    }

    func rect(at date: Date) -> CGRect {
        let t = min(1, max(0, date.timeIntervalSince(startedAt) / Self.duration))
        if t >= 1 { return target }
        let lead = Self.bezier(min(1, t / 0.6), 0.215, 0.61, 0.355, 1)
        let trail = Self.bezier(max(0, (t - 0.35) / 0.65), 0.645, 0.045, 0.355, 1)
        let horizontal = axis == .horizontal
        let originStart = horizontal ? origin.minX : origin.minY
        let originEnd = horizontal ? origin.maxX : origin.maxY
        let targetStart = horizontal ? target.minX : target.minY
        let targetEnd = horizontal ? target.maxX : target.maxY
        let forward = targetStart + targetEnd >= originStart + originEnd
        let start = originStart + (targetStart - originStart) * (forward ? trail : lead)
        let end = originEnd + (targetEnd - originEnd) * (forward ? lead : trail)
        return horizontal
            ? CGRect(x: start, y: target.minY, width: max(0, end - start), height: target.height)
            : CGRect(x: target.minX, y: start, width: target.width, height: max(0, end - start))
    }

    // Cubic timing curves use x as time, so solve x before evaluating y.
    static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        guard x > 0 && x < 1 else { return min(1, max(0, x)) }
        func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if sample(mid, x1, x2) < x { low = mid } else { high = mid }
        }
        return sample((low + high) / 2, y1, y2)
    }
}

struct SidebarSelectionIndicator: View {
    let index: Int
    let color: Color
    var body: some View {
        AnimatedSelectionIndicator(target: SelectionIndicatorMotion.restingRect(index: index, stride: 50), axis: .vertical, color: color)
    }
}

private struct AnimatedSelectionIndicator: View {
    let target: CGRect
    let color: Color
    @WorkspaceViewState private var motion: SelectionIndicatorMotion
    @WorkspaceViewState private var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(target: CGRect, axis: Axis, color: Color) {
        self.target = target; self.color = color
        _motion = WorkspaceViewState(initialValue: SelectionIndicatorMotion(rect: target, axis: axis))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
            let rect = moving ? motion.rect(at: timeline.date) : motion.target
            // Draw in local coordinates without animatable frame/position modifiers.
            // The canvas still inherits its parent's movement during sidebar resizing.
            Canvas { context, _ in
                context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(color))
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onChange(of: target) { destination in
            motion.select(destination, at: Date(), reduceMotion: reduceMotion)
            moving = !reduceMotion
        }
        .onChange(of: reduceMotion) { reduced in if reduced { moving = false } }
        .task(id: motion.startedAt) {
            guard moving else { return }
            do { try await Task.sleep(nanoseconds: 320_000_000) } catch { return }
            moving = false
        }
    }
}

private struct FilterTabWidths: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum FilterTabLayout {
    // Widths are local to the tabs: moving their parent must not retarget the underline.
    static func indicator(widths: [Int: CGFloat], index: Int) -> CGRect? {
        guard index >= 0, let width = widths[index] else { return nil }
        var x: CGFloat = 12
        for previous in 0..<index {
            guard let precedingWidth = widths[previous] else { return nil }
            x += precedingWidth + 4
        }
        return CGRect(x: x, y: 33, width: max(0, width - 24), height: 3)
    }
}

struct FilterTabs<Selection: Hashable>: View {
    @ObservedObject private var localization = AppLocalization.shared
    let options: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option } label: {
                    // Keep glyph metrics unchanged when selecting a tab. A weight
                    // change shifts every tab after it, including the underline.
                    Text(title(option)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ThemePalette.color(selection == option ? palette.accent : palette.secondary))
                        .padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: FilterTabWidths.self, value: [index: geometry.size.width])
                })
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .overlayPreferenceValue(FilterTabWidths.self) { widths in
            if let index = options.firstIndex(of: selection), let rect = FilterTabLayout.indicator(widths: widths, index: index) {
                AnimatedSelectionIndicator(target: rect, axis: .horizontal, color: ThemePalette.color(palette.accent))
            }
        }
    }
}

struct SidebarButtonStyle: ButtonStyle {
    let palette: ThemePalette
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonSurface(palette: palette, selected: selected, pressed: configuration.isPressed, label: configuration.label)
    }
}

private struct SidebarButtonSurface<Label: View>: View {
    let palette: ThemePalette
    let selected: Bool
    let pressed: Bool
    let label: Label
    @WorkspaceViewState private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        label
            .background(ThemePalette.color(palette.text).opacity(selected ? 0.08 : 0))
            .overlay(RoundedRectangle(cornerRadius: 12).fill(ThemePalette.color(palette.text).opacity(pressed ? 0.06 : hovered ? 0.04 : 0)).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
            .onHover { hovered = $0 }
    }
}

struct SidebarGlyph: View {
    let symbol: String
    let filledSymbol: String
    let selected: Bool
    @WorkspaceViewState private var activatedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: activatedAt == nil || reduceMotion)) { timeline in
            let t = activatedAt.map { min(1, max(0, timeline.date.timeIntervalSince($0) / 0.35)) } ?? 1
            ZStack {
                if symbol == filledSymbol { Image(systemName: symbol) }
                else {
                    Image(systemName: symbol).opacity(selected ? 0 : 1)
                    Image(systemName: filledSymbol).opacity(selected ? 1 : 0)
                }
            }
            .animation(reduceMotion ? nil : .timingCurve(0.645, 0.045, 0.355, 1, duration: 0.35), value: selected)
            .scaleEffect(reduceMotion ? 1 : 1 + 0.1 * sin(.pi * t))
        }
        .onChange(of: selected) { active in
            if active && !reduceMotion { activatedAt = Date() }
        }
        .task(id: activatedAt) {
            guard activatedAt != nil else { return }
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            activatedAt = nil
        }
    }
}

struct SidebarLabelFade: AnimatableModifier {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View { content.opacity(min(1, max(0, (progress - 0.4) / 0.6))) }
}
