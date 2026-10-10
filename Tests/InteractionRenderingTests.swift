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
    @MainActor static func inputFocusRaceTests() async throws {
        let suite = "arxiv-input-focus-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        var focused = false
        let view = NSHostingView(rootView: LinkInput(model: model, focused: Binding(get: { focused }, set: { focused = $0 }), palette: model.theme.palette(dark: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func settle() async {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
        }
        func editor(_ root: NSView) -> LinkTextView? {
            (root as? LinkTextView) ?? root.subviews.lazy.compactMap(editor).first
        }
        await settle()
        guard let input = editor(view) else { throw TestFailure.failed("focus test input") }
        window.makeFirstResponder(input)
        await settle()
        input.focusChanged?(true)
        focused = false; model.listRequest = UUID()
        await settle()
        try expect(!focused, "queued input gain must not overwrite a newer list request before list focus arrives")
        window.makeFirstResponder(nil)
        await settle()
        input.focusChanged?(false)
        focused = true; model.focusInput()
        await settle()
        try expect(focused && window.firstResponder === input, "queued input loss must not overwrite a newer input request")
        print("PASS input focus: stale gain and loss cannot supersede newer keyboard requests")
    }

    @MainActor static func settingsLayoutTests() async throws {
        _ = NSApplication.shared
        let suite = "arxiv-settings-layout-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        let view = NSHostingView(rootView: SettingsView(model: model).id("通用"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 456), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func header(_ tab: String) async throws -> [Bool] {
            view.rootView = SettingsView(model: model, tab: tab).id(tab)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("settings bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / 470
            let background = bitmap.colorAt(x: 0, y: 0)!
            // Selection changes the fill, but never the control's occupied rows.
            return (0..<Int(50 * scale)).map { y in
                (0..<bitmap.pixelsWide).contains { x in
                    bitmap.colorAt(x: x, y: y)! != background
                }
            }
        }
        let general = try await header("通用")
        let shortcuts = try await header("快捷键")
        try expect(general.contains(true) && general == shortcuts, "settings category control must not move when switching pages")
        func recorders(_ root: NSView) -> [NSView] {
            if root is ShortcutRecorder.Recorder { return [root] }
            return root.subviews.flatMap(recorders)
        }
        let frames = recorders(view).map { $0.convert($0.bounds, to: view) }
        try expect(frames.count == 4 && frames.allSatisfy { abs($0.minX - frames[0].minX) < 1 && abs($0.width - frames[0].width) < 1 && view.bounds.contains($0) }, "shortcut recorders share one column and remain inside the window")
        try expect(try await header("通用") == general, "returning to general preserves header position")
        print("PASS settings layout: stable category header and aligned shortcut column")
    }

    @MainActor static func listFocusTests() async throws {
        _ = NSApplication.shared
        let suite = "arxiv-list-focus-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.history = [
            DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .saved, savedURL: URL(fileURLWithPath: "/tmp/focus-first.pdf"), finishedAt: Date()),
            DownloadItem(original: "2003.07733", reference: try ArxivReference.parse("2003.07733"), state: .saved, savedURL: URL(fileURLWithPath: "/tmp/focus-second.pdf"), finishedAt: Date().addingTimeInterval(-1))
        ]
        model.history.forEach { model.upsertPaper($0) }
        model.items = model.history
        model.record(.info, "下载中", item: model.history[1])
        let view = NSHostingView(rootView: DownloaderView(model: model, page: .logs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func settle() async {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
        }
        func searchField(_ root: NSView) -> NSTextField? {
            if let field = root as? NSTextField, field.placeholderString == "搜索" { return field }
            return root.subviews.lazy.compactMap { searchField($0) }.first
        }
        func search(_ text: String) async throws -> NSTextView {
            guard let field = searchField(view), window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                throw TestFailure.failed("search editor available")
            }
            editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
            await settle()
            return editor
        }
        await settle()
        _ = try await search("2003.07733")
        model.listRequest = UUID()
        await settle()
        for _ in 0..<10 where !(window.firstResponder is PaperListKeyboard.KeyView) { await settle() }
        var keyStep = 0
        func key(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            keyStep += 1
            guard let keys = window.firstResponder as? PaperListKeyboard.KeyView else {
                throw TestFailure.failed("paper list must be first responder at key step \(keyStep), got \(String(describing: window.firstResponder))")
            }
            keys.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        try key(34, "i", .command)
        try expect(model.diagnosticItem?.id == model.downloads.first?.id, "cross-page focus selects the first download after navigation resets selection")
        model.diagnosticItem = nil
        try key(125, "\u{F701}")
        await settle()
        try key(34, "i", .command)
        try expect(model.diagnosticItem?.id == model.downloads.last?.id, "arrow navigation remains available after cross-page focus")
        model.diagnosticItem = nil
        let editor = try await search("no-matching-paper")
        editor.selectAll(nil); editor.insertText("", replacementRange: editor.selectedRange())
        await settle()
        try expect(window.firstResponder === editor, "restoring search results does not replay a consumed list focus request")
        model.focusInput()
        await settle()
        try expect(window.firstResponder is LinkTextView, "Command L moves focus back to the input without list focus stealing it")
        model.listRequest = UUID()
        await settle()
        try key(34, "i", .command)
        model.diagnosticItem = nil
        model.focusInput()
        await settle()
        try expect(window.firstResponder is LinkTextView, "same-page Command L wins over list focus with populated download rows")
        model.items = []; model.history = []
        await settle()
        model.listRequest = UUID()
        await settle()
        try expect(!(window.firstResponder is PaperListKeyboard.KeyView), "empty list does not create a stale keyboard responder")
        print("PASS keyboard focus: filtered logs to list, selection, arrows, search remount and input return")
    }

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
        print("PASS rendered filter motion: intermediate frames and rapid parent reversal stay aligned")
    }
}


@MainActor private final class LogRegressionProbe: ObservableObject {
    @Published var query = ""
    @Published var level: ActivityLevel?
    @Published var entries: [ActivityEntry] = []
}
private struct LogRegressionView: View {
    @ObservedObject var probe: LogRegressionProbe
    var body: some View {
        LogContent(entries: probe.entries.filter { (probe.query.isEmpty || $0.message.contains(probe.query)) && (probe.level == nil || $0.level == probe.level) },
                   hasLogs: !probe.entries.isEmpty, query: probe.query, level: $probe.level, palette: AppTheme.graphite.palette(dark: false))
    }
}
extension CoreTests {
    @MainActor static func logScrollTests() async throws {
        let probe = LogRegressionProbe()
        let task = UUID()
        probe.entries = (0..<1500).map { i in
            ActivityEntry(level: i % 9 == 0 ? .warning : .info, message: "日志 \(i) · " + String(repeating: "较长的消息，检查实际滚动边界。", count: i % 5), subject: "回归检查", itemID: task)
        }
        let view = NSHostingView(rootView: LogRegressionView(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 450_000_000)
            view.layoutSubtreeIfNeeded()
        }
        func observer(_ root: NSView) -> LogScrollObserver.Observer? {
            (root as? LogScrollObserver.Observer) ?? root.subviews.lazy.compactMap(observer).first
        }
        func userScroll(_ scroll: NSScrollView, y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        await settle()
        guard let scroll = observer(view)?.scroll else { throw TestFailure.failed("logs expose native clip bounds") }
        for _ in 0..<10 where !LogScrollPosition(scroll: scroll).atBottom {
            try? await Task.sleep(nanoseconds: 50_000_000)
            view.layoutSubtreeIfNeeded()
        }
        try expect(LogScrollPosition(scroll: scroll).canScroll && LogScrollPosition(scroll: scroll).atBottom, "long variable-height logs start at latest entry; clip=\(scroll.contentView.bounds), content=\(String(describing: scroll.documentView?.bounds))")
        window.setContentSize(NSSize(width: 420, height: 400))
        await settle()
        try expect(LogScrollPosition(scroll: scroll).atBottom, "tail stays aligned when wrapping changes row heights")
        userScroll(scroll, y: scroll.contentView.bounds.minY - 200)
        await settle()
        let readingY = scroll.contentView.bounds.minY
        probe.entries.append(ActivityEntry(level: .info, message: "手动上滚后不拉回", subject: nil, itemID: nil))
        await settle()
        try expect(abs(scroll.contentView.bounds.minY - readingY) < 2, "new log preserves historical reading position")
        userScroll(scroll, y: scroll.documentView!.bounds.maxY - scroll.contentView.bounds.height)
        await settle()
        probe.entries.append(ActivityEntry(level: .info, message: "尾部继续跟随", subject: nil, itemID: nil))
        await settle()
        try expect(LogScrollPosition(scroll: scroll).atBottom, "new logs follow at actual tail")
        for byLevel in [false, true] {
            let current = observer(view)!.scroll!
            userScroll(current, y: current.contentView.bounds.minY - 200)
            await settle()
            if byLevel { probe.level = .error } else { probe.query = "no-match" }
            await settle()
            try expect(observer(view)?.scroll == nil, "empty filter removes scroll content")
            if byLevel { probe.level = nil } else { probe.query = "" }
            await settle()
            guard let returned = observer(view)?.scroll else { throw TestFailure.failed("filtered log content restored") }
            try expect(LogScrollPosition(scroll: returned).atBottom, "clearing empty search/filter returns to tail")
            probe.entries.append(ActivityEntry(level: .info, message: "恢复筛选后继续跟随", subject: nil, itemID: nil))
            await settle()
            try expect(LogScrollPosition(scroll: returned).atBottom, "clearing empty search/filter restores following latest")
        }
        probe.entries = [ActivityEntry(level: .info, message: "短日志", subject: nil, itemID: nil)]
        await settle()
        try expect(observer(view).flatMap(\.scroll).map { !LogScrollPosition(scroll: $0).canScroll } == true, "short list needs no scroll control")
        // Exercise native animation frames and cancellation independently of SwiftUI rendering.
        let native = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 2500))
        let driver = LogScrollObserver.Observer(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(driver); native.documentView = document; window.contentView = native
        driver.connect(); driver.jump(toBottom: true, animated: false)
        let bottom = native.contentView.bounds.minY
        driver.jump(toBottom: false, animated: true)
        try await Task.sleep(nanoseconds: 90_000_000)
        let middle = native.contentView.bounds.minY
        try expect(middle > 2 && middle < bottom - 2, "log jump renders intermediate frames")
        driver.jump(toBottom: true, animated: true)
        try expect(abs(native.contentView.bounds.minY - middle) < 2, "reversed log animation starts at the displayed position")
        try await Task.sleep(nanoseconds: 350_000_000)
        try expect(LogScrollPosition(scroll: native).atBottom, "reversed animation reaches exact tail")
        driver.jump(toBottom: false, animated: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        userScroll(native, y: 200)
        try await Task.sleep(nanoseconds: 350_000_000)
        try expect(abs(native.contentView.bounds.minY - 200) < 2, "manual scrolling cancels an in-flight jump")
        driver.jump(toBottom: false, animated: false)
        try expect(LogScrollPosition(scroll: native).atTop, "reduced motion jumps directly to exact top")
        driver.jump(toBottom: true, animated: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        driver.finishTransition(toBottom: true)
        try expect(LogScrollPosition(scroll: native).atBottom, "enabling reduced motion settles an in-flight jump immediately")
        print("PASS logs: 1500 variable-height rows, tail following, manual reading, empty-search/filter restoration, animation reversal/cancellation and reduced motion")
    }

    @MainActor static func inputColorTransitionTests() async throws {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 120))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let editor = LinkTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120), textContainer: container)
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.string = "https://arxiv.org/abs/1706.03762 test"
        editor.setSelectedRange(NSRange(location: 2, length: 5))
        editor.updateColors(text: .white, accent: .white, placeholder: .white, underline: true, animated: false)
        editor.updateColors(text: .black, accent: .black, placeholder: .black, underline: true, animated: true)
        // Sample rendered frames, rather than requiring a particular frame at 90 ms.
        // Older AppKit versions schedule the first frame differently under CI load.
        var halfway: CGFloat = 1
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            try await Task.sleep(nanoseconds: 10_000_000)
            halfway = editor.placeholderColor.usingColorSpace(.sRGB)!.redComponent
        } while (halfway <= 0.05 || halfway >= 0.95) && Date() < deadline
        try expect(halfway > 0.05 && halfway < 0.95, "native placeholder interpolates instead of flashing; value=\(halfway)")
        try expect(abs(editor.insertionPointColor.usingColorSpace(.sRGB)!.redComponent - halfway) < 0.01, "caret and placeholder share transition progress")
        editor.updateColors(text: .white, accent: .white, placeholder: .white, underline: true, animated: true)
        let reversed = editor.placeholderColor.usingColorSpace(.sRGB)!.redComponent
        try expect(abs(reversed - halfway) < 0.08, "rapid appearance reversal starts from displayed color")
        editor.updateColors(text: .white, accent: .white, placeholder: .white, underline: true, animated: false)
        try expect(editor.placeholderColor == .white, "reduced motion immediately reaches final color")
        try expect(editor.string == "https://arxiv.org/abs/1706.03762 test" && editor.selectedRange() == NSRange(location: 2, length: 5), "color transition preserves text and selection")
        print("PASS native colors: intermediate frame, synchronized caret, rapid reversal, reduced motion, text and selection")
    }
}
