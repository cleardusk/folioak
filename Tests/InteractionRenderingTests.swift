import AppKit
import SwiftUI

@MainActor private final class FilterLayoutProbe: ObservableObject {
    @Published var inset: CGFloat = 190
    @Published var selection = 0
}

private struct MovingFilterProbe: View {
    @ObservedObject var probe: FilterLayoutProbe
    private let palette = ThemePalette(canvas: 0xFFFFFF, surface: 0xFFFFFF, text: 0x000000, secondary: 0x555555,
                                       border: 0xDDDDDD, accent: 0xFF0000, action: 0xFF0000, onAction: 0xFFFFFF)
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: probe.inset)
            FilterTabs(options: [0, 1, 2], selection: $probe.selection, title: { ["全部", "进行中", "已完成"][$0] }, palette: palette)
            Spacer(minLength: 0)
        }.frame(width: 600, height: 36).background(Color.white)
    }
}

extension CoreTests {
    @MainActor static func filterRenderingTests() throws {
        _ = NSApplication.shared
        let probe = FilterLayoutProbe()
        let view = NSHostingView(rootView: MovingFilterProbe(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 36), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }

        func sample(_ label: String) throws {
            try autoreleasepool {
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("filter frame bitmap") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / 600
                var textMin = bitmap.pixelsWide, textMax = -1
                var lineMin = bitmap.pixelsWide, lineMax = -1
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.redComponent > 0.7, color.greenComponent < 0.3, color.blueComponent < 0.3 else { continue }
                        if CGFloat(y) < 29 * scale {
                            textMin = min(textMin, x); textMax = max(textMax, x)
                        } else {
                            lineMin = min(lineMin, x); lineMax = max(lineMax, x)
                        }
                    }
                }
                try expect(textMax >= textMin && lineMax >= lineMin, "\(label): text and underline rendered")
                let offset = abs(CGFloat(textMin + textMax - lineMin - lineMax) / (2 * scale))
                try expect(offset <= 2, "\(label): underline follows text during parent motion (offset \(offset) pt)")
            }
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        try sample("initial")
        // Sample the animation itself, not just its final layout. Reverse before it finishes.
        for (index, inset) in [CGFloat(74), 190, 74].enumerated() {
            withAnimation(.linear(duration: 1)) { probe.inset = inset }
            for frame in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                try sample("transition \(index), frame \(frame)")
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.1))
        try sample("settled")
        withAnimation(.linear(duration: 1)) { probe.inset = 190 }
        probe.selection = 2
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try sample("tab change during parent motion")
        let outline = ActivityOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        outline.update(color: .red, animate: true)
        try expect(outline.layer?.sublayers?.first?.animation(forKey: "breathing") != nil, "active border uses a system layer animation")
        try expect(outline.hitTest(NSPoint(x: 1, y: 50)) == nil, "breathing border must not intercept input")
        outline.update(color: .red, animate: false)
        try expect(outline.layer?.sublayers?.first?.animationKeys()?.isEmpty != false, "reduced motion removes the running layer animation")
        print("PASS rendered filter motion: intermediate frames and rapid parent reversal stay aligned")
    }
}
