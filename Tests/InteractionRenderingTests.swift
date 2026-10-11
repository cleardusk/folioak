import AppKit
import SwiftUI

private final class InteractionTestHost<Content: View>: NSHostingView<Content> {
    // Exercise canvas gestures without activating the test process on the user's desktop.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

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
    @MainActor static func blankCanvasFocusTests() async throws {
        _ = NSApplication.shared
        let suite = "leafpeak-blank-focus-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func field(_ root: NSView) -> NSTextField? {
            if let text = root as? NSTextField, text.placeholderString?.hasPrefix("搜索") == true { return text }
            return root.subviews.lazy.compactMap(field).first
        }
        for page in WorkspacePage.allCases {
            let model = DownloadModel(preferences: preferences)
            let item = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"),
                                    state: .saved, savedURL: URL(fileURLWithPath: "/tmp/focus-fixture.pdf"), documentTitle: "Focus fixture")
            model.history = [item]; model.upsertPaper(item)
            model.mediaLibrary = [DownloadItem(original: "https://example.com/focus.mp4", directURL: URL(string: "https://example.com/focus.mp4"),
                                               state: .saved, savedURL: URL(fileURLWithPath: "/tmp/focus-fixture.mp4"), documentTitle: "Focus fixture")]
            model.record(.info, "Focus fixture")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            var endEditingCount = 0
            let view = InteractionTestHost(rootView: DownloaderView(model: model, page: page, endTextEditing: { [weak window] in
                endEditingCount += 1
                if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
            }))
            window.isReleasedWhenClosed = false
            window.contentView = view; window.orderFront(nil)
            defer { window.close() }
            func settle() async {
                try? await Task.sleep(nanoseconds: 100_000_000)
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
            func click(_ point: NSPoint, in target: NSView) async {
                let location = target.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                await settle()
            }
            func blank() async { await click(NSPoint(x: 650, y: view.isFlipped ? view.bounds.height - 90 : 90), in: view) }
            func fromTop(_ x: CGFloat, _ y: CGFloat) async {
                await click(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), in: view)
            }
            await settle()
            if page == .downloads {
                model.focusInput(); await settle()
                guard let editor = window.firstResponder as? LinkTextView else { throw TestFailure.failed("input gains focus") }
                editor.insertText("1706.03762", replacementRange: editor.selectedRange())
                await blank()
                try expect(window.firstResponder !== editor && model.input == "1706.03762", "canvas ends input editing without clearing the draft (dismissals: \(endEditingCount))")
                model.objectWillChange.send(); await settle()
                try expect(window.firstResponder !== editor, "ordinary view updates do not restore dismissed input focus")
                await fromTop(550, 70)
                try expect(window.firstResponder is LinkTextView, "clicking the composer background restores editing")
                await fromTop(75, 158)
                try expect(editor.window == nil, "document-library navigation removes the input")
                await fromTop(75, 108)
                try expect(!(window.firstResponder is LinkTextView), "returning to downloads does not restore stale input focus")
                await fromTop(75, 158)
                model.focusInput(); await settle()
                try expect(window.firstResponder is LinkTextView, "input shortcut still focuses after changing pages")
                await blank()
            }
            model.searchRequest = UUID(); await settle()
            try expect(field(view)?.currentEditor() === window.firstResponder, "\(page): search opens focused (field: \(field(view) as Any), responder: \(window.firstResponder as Any))")
            await blank()
            try expect(field(view) == nil, "\(page): empty search collapses on blank canvas")
            model.searchRequest = UUID(); await settle()
            await fromTop(90, 500)
            try expect(field(view) == nil, "\(page): sidebar blank collapses empty search")
            model.searchRequest = UUID(); await settle()
            guard let editor = field(view)?.currentEditor() as? NSTextView else { throw TestFailure.failed("search reopens") }
            editor.insertText("no-matching-result", replacementRange: editor.selectedRange()); await settle()
            await blank()
            try expect(field(view)?.stringValue == "no-matching-result" && field(view)?.currentEditor() == nil,
                       "\(page): blank no-results view ends editing but preserves the filter")
            model.searchRequest = UUID(); await settle()
            guard let reopened = field(view)?.currentEditor() as? NSTextView else { throw TestFailure.failed("filtered search refocuses") }
            reopened.selectAll(nil); reopened.insertText("", replacementRange: reopened.selectedRange()); await settle()
            await blank()
            try expect(field(view) == nil, "\(page): cleared search collapses again")
        }
        print("PASS blank canvas: input dismissal, preserved draft, refocus and search closure on every page")
    }

    @MainActor static func initialDirectoryTests() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("leafpeak-first-launch-\(UUID().uuidString)")
        let suite = "leafpeak-first-launch-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: home)
            preferences.removePersistentDomain(forName: suite)
        }
        let root = home.appendingPathComponent("Downloads/Leafpeak")
        preferences.set(root.path, forKey: "downloadRootDirectory")
        let model = DownloadModel(preferences: preferences)
        model.prepareDefaultDirectory(home: home)
        try expect(model.directoryExists && model.directoryNotice == nil, "fresh launch creates the default root")
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "type folders stay lazy")
        let file = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        model.prepareDefaultDirectory(home: home)
        try expect(try String(contentsOf: file, encoding: .utf8) == "keep", "repeated launch preserves existing files")
        model.directory = home.appendingPathComponent("OfflineCustomFolder")
        model.prepareDefaultDirectory(home: home)
        try expect(!model.directoryExists, "launch never recreates an unavailable custom destination")
        try FileManager.default.removeItem(at: root)
        try Data("occupied".utf8).write(to: root)
        model.directory = root
        model.prepareDefaultDirectory(home: home)
        try expect(model.directoryNotice != nil && (try String(contentsOf: root, encoding: .utf8)) == "occupied", "blocked default root reports a recoverable error without overwriting")
        print("PASS first launch: default folder creation, preserved files, custom paths and occupied-path recovery")
    }

    @MainActor static func sidebarLayoutTests() async throws {
        _ = NSApplication.shared
        let suite = "leafpeak-sidebar-layout-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.theme = .graphite
        let view = NSHostingView(rootView: DownloaderView(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async throws {
            try await Task.sleep(nanoseconds: 400_000_000)
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        func toggle() throws {
            // Send events to this test window only; no system accessibility grant.
            let point = NSPoint(x: 37, y: view.bounds.height - 55)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw TestFailure.failed("sidebar mouse event")
                }
                window.sendEvent(event)
            }
        }
        func input(_ root: NSView) -> LinkTextView? {
            (root as? LinkTextView) ?? root.subviews.lazy.compactMap(input).first
        }
        func verify(collapsed: Bool) throws {
            guard let editor = input(view), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw TestFailure.failed("sidebar layout input and bitmap")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            // Inspect actual pixels away from controls: stale sidebar paint must not
            // survive on either side of the new divider after folding or resizing.
            let sidebarWidth: CGFloat = collapsed ? 74 : 190
            let y = Int((view.bounds.height - 120) * scale)
            let left = bitmap.colorAt(x: Int((sidebarWidth - 4) * scale), y: y)!.usingColorSpace(.deviceRGB)!
            let right = bitmap.colorAt(x: Int((sidebarWidth + 4) * scale), y: y)!.usingColorSpace(.deviceRGB)!
            try expect(left.redComponent - right.redComponent > 0.025, "sidebar background ends at \(sidebarWidth) pt")
            let frame = editor.convert(editor.bounds, to: view)
            try expect(abs(frame.minX + editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0) - (sidebarWidth + 1 + 24 + 20)) < 1,
                       "input follows the divider without overlap: \(frame.minX), sidebar \(sidebarWidth)")
        }
        try await settle(); try verify(collapsed: false)
        for size in [NSSize(width: 960, height: 700), NSSize(width: 780, height: 540), NSSize(width: 1120, height: 900)] {
            window.setContentSize(size); try await settle()
            try toggle()
            try await settle(); try verify(collapsed: true)
            window.setContentSize(NSSize(width: size.width, height: size.height + 80))
            try await settle(); try verify(collapsed: true)
            try toggle()
            try await settle(); try verify(collapsed: false)
        }
        print("PASS sidebar layout: real fold/unfold actions, 74/190 pt boundaries, input alignment and window resizing")
    }

    @MainActor static func menuChevronTests() throws {
        _ = NSApplication.shared
        let view = MenuChevron.ChevronView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        content.addSubview(view); window.contentView = content; window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.configure(menuTitle: "/test/Leafpeak", color: .white, animated: true)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let menu = NSMenu(), other = NSMenu()
        menu.addItem(withTitle: "/test/Leafpeak", action: nil, keyEquivalent: "")
        other.addItem(withTitle: "Other menu", action: nil, keyEquivalent: "")
        func tip(_ path: CGPath?) -> CGFloat {
            // Core Animation may normalize interpolated paths to cubic curves.
            // The tip and either wing stay symmetric about y=5 throughout.
            path.map { 10 - $0.currentPoint.y } ?? -1
        }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: other)
        try expect(view.mark.animation(forKey: "fold") == nil, "unrelated menus leave the directory arrow alone")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        var middle: CGFloat = 3.5
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
            CATransaction.flush()
            middle = tip(view.mark.presentation()?.path)
        } while (middle <= 3.55 || middle >= 6.45) && Date() < deadline
        try expect(middle > 3.55 && middle < 6.45, "chevron renders intermediate shapes during native menu tracking")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: other)
        try expect(tip(view.mark.path) == 6.5, "unrelated menu closing cannot reset the directory arrow")
        for opening in [false, true, false] {
            let displayed = tip(view.mark.presentation()?.path)
            NotificationCenter.default.post(name: opening ? NSMenu.didBeginTrackingNotification : NSMenu.didEndTrackingNotification, object: menu)
            guard let fold = view.mark.animation(forKey: "fold") as? CABasicAnimation,
                  let fromValue = fold.fromValue else { throw TestFailure.failed("chevron reversal animation") }
            try expect(abs(tip(fromValue as! CGPath) - displayed) < 0.2, "rapid reversal continues from the displayed shape")
            try expect(fold.duration == 0.12, "both directions use the same short response")
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
            CATransaction.flush()
        }
        view.configure(menuTitle: "/test/Leafpeak", color: .white, animated: false)
        try expect(view.mark.animation(forKey: "fold") == nil && tip(view.mark.path) == 3.5,
                   "reduced motion settles an in-flight fold without leaving an animation")
        try expect(view.hitTest(.zero) == nil, "decorative chevron cannot steal menu clicks")
        view.removeFromSuperview()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        try expect(view.mark.animation(forKey: "fold") == nil && tip(view.mark.path) == 3.5, "detached arrows stop observing menus")
        print("PASS menu chevron: native tracking, continuous shape reversal, reduced motion and menu isolation")
    }

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
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
        }
        func searchField(_ root: NSView) -> NSTextField? {
            if let field = root as? NSTextField, field.placeholderString?.hasPrefix("搜索") == true { return field }
            return root.subviews.lazy.compactMap { searchField($0) }.first
        }
        func search(_ text: String) async throws -> NSTextView {
            model.searchRequest = UUID()
            await settle()
            guard let field = searchField(view), let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else {
                throw TestFailure.failed("search opens with its editor focused")
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
        model.busy = true
        let searching = try await search("1706")
        searching.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await settle()
        try expect(searchField(view)?.stringValue == "" && !model.cancelling, "Escape clears search without cancelling downloads")
        searching.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await settle()
        try expect(searchField(view) == nil && !model.cancelling, "second Escape closes search without cancelling downloads")
        model.busy = false
        for fromList in [true, false] {
            if fromList { model.listRequest = UUID() } else { model.focusInput() }
            model.searchRequest = UUID()
            await settle()
            try expect(searchField(view)?.currentEditor() === window.firstResponder, "new search wins over pending list and input focus")
        }
        for toList in [true, false] {
            model.searchRequest = UUID()
            if toList { model.listRequest = UUID() } else { model.focusInput() }
            await settle()
            try expect(toList ? window.firstResponder is PaperListKeyboard.KeyView : window.firstResponder is LinkTextView,
                       "new list and input requests win over pending search focus")
        }
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
        model.listRequest = UUID()
        await settle()
        guard let list = window.firstResponder as? PaperListKeyboard.KeyView else { throw TestFailure.failed("list focus before deselection") }
        let blank = list.convert(NSPoint(x: 80, y: list.isFlipped ? list.bounds.height - 24 : 24), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: blank, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        await settle()
        try key(34, "i", .command)
        try expect(model.diagnosticItem == nil, "clicking the list's blank area deselects without opening a stale row")
        try key(125, "\u{F701}")
        await settle()
        try key(34, "i", .command)
        try expect(model.diagnosticItem?.id == model.downloads.first?.id, "arrow navigation can select again after blank-area deselection")
        model.diagnosticItem = nil
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
