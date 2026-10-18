import AppKit
import SwiftUI
import Vision

private final class InteractionTestHost<Content: View>: NSHostingView<Content> {
    // Exercise canvas gestures without activating the test process on the user's desktop.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SelectionTestWindow: NSWindow {
    // CI and background test processes cannot become the desktop's key app.
    // Drive that external condition while retaining real responder transitions
    // and SwiftUI rendering inside this window.
    private var active = true
    override var isKeyWindow: Bool { active }
    func setActive(_ value: Bool) {
        active = value
        NotificationCenter.default.post(name: value ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self)
    }
}

@MainActor private final class FilterLayoutProbe: ObservableObject {
    @Published var inset: CGFloat = 190
    @Published var selection = 0
}

private struct MovingFilterProbe: View {
    @ObservedObject var probe: FilterLayoutProbe
    var titles = ["全部", "进行中", "已完成"]
    var palette = ThemePalette(canvas: 0xFFFFFF, surface: 0xFFFFFF, text: 0x000000, secondary: 0x555555,
                                       border: 0xDDDDDD, accent: 0xFF0000, action: 0xFF0000, onAction: 0xFFFFFF)
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: probe.inset)
            FilterTabs(options: Array(titles.indices), selection: $probe.selection, title: { titles[$0] }, palette: palette)
            Spacer(minLength: 0)
        }.frame(width: 600, height: 36).background(Color.white)
    }
}

extension CoreTests {
    @MainActor static func selectionFocusTests() async throws {
        _ = NSApplication.shared
        let suite = "folioak-selection-focus-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.theme = .graphite
        model.history = [DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .saved,
                                      savedURL: URL(fileURLWithPath: "/tmp/selection.pdf"), documentTitle: "Selection fixture")]
        let view = InteractionTestHost(rootView: DownloaderView(model: model).environment(\.colorScheme, .light))
        let window = SelectionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.orderFront(nil); window.makeKey()
        defer { window.close() }
        func settle() async {
            try? await Task.sleep(nanoseconds: 150_000_000)
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        func shade(_ keys: PaperListKeyboard.KeyView) throws -> CGFloat {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("selection bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let point = keys.convert(NSPoint(x: 400, y: keys.isFlipped ? 32 : keys.bounds.height - 32), to: view)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let y = view.isFlipped ? point.y : view.bounds.height - point.y
            return bitmap.colorAt(x: Int(point.x * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!.redComponent
        }
        await settle(); model.listRequest = UUID(); await settle()
        for _ in 0..<10 where !(window.firstResponder is PaperListKeyboard.KeyView) { await settle() }
        guard window.isKeyWindow, let keys = window.firstResponder as? PaperListKeyboard.KeyView else { throw TestFailure.failed("selection test active list: key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder))") }
        let selected = try shade(keys)
        model.focusInput(); await settle()
        try expect(window.firstResponder is LinkTextView && (try shade(keys)) - selected > 0.03, "moving from selected row to input removes the row highlight")
        model.listRequest = UUID(); await settle()
        try expect(abs((try shade(keys)) - selected) < 0.01, "returning to list restores the selection highlight")
        window.setActive(false); await settle()
        try expect((try shade(keys)) - selected > 0.03, "inactive windows do not show the active list highlight")
        window.setActive(true); await settle()
        try expect(abs((try shade(keys)) - selected) < 0.01, "window activation restores a focused selection")
        // Multiple native transitions in the same run loop must publish only
        // the final responder, including a rapid return from the composer.
        let input = LinkTextView(frame: .zero, textContainer: nil)
        window.contentView?.addSubview(input)
        window.makeFirstResponder(input); window.makeFirstResponder(keys); await settle()
        try expect(abs((try shade(keys)) - selected) < 0.01, "stale focus loss cannot hide a newly focused selection")
        keys.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!)
        try expect(model.diagnosticItem?.id == model.history[0].id, "logical selection survives input and window focus changes")
        model.diagnosticItem = nil
        print("PASS selection highlight: actual responder, input return, window activation, rapid transitions and remembered selection")
    }

    @MainActor static func blankCanvasFocusTests() async throws {
        _ = NSApplication.shared
        let suite = "folioak-blank-focus-\(UUID().uuidString)"
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
            model.navigation = WorkspaceNavigation(page: page)
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
            func openSearch() async throws -> NSTextView {
                model.searchRequest = UUID()
                // Mounting the SwiftUI field and assigning its native editor are
                // separate updates. Wait for ownership, without forcing focus
                // or issuing another request, before exercising dismissal.
                for _ in 0..<20 {
                    await settle()
                    if let search = field(view), search.window === window,
                       let editor = search.currentEditor() as? NSTextView,
                       window.firstResponder === editor { return editor }
                }
                throw TestFailure.failed("\(page): search opens focused (field: \(field(view) as Any), editor: \(field(view)?.currentEditor() as Any), responder: \(window.firstResponder as Any))")
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
                await fromTop(550, 100)
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
            _ = try await openSearch()
            await blank()
            try expect(field(view) == nil, "\(page): empty search collapses on blank canvas")
            _ = try await openSearch()
            await fromTop(90, 500)
            try expect(field(view) == nil, "\(page): sidebar blank collapses empty search")
            let editor = try await openSearch()
            editor.insertText("no-matching-result", replacementRange: editor.selectedRange()); await settle()
            await blank()
            try expect(field(view)?.stringValue == "no-matching-result" && field(view)?.currentEditor() == nil,
                       "\(page): blank no-results view ends editing but preserves the filter")
            let reopened = try await openSearch()
            reopened.selectAll(nil); reopened.insertText("", replacementRange: reopened.selectedRange()); await settle()
            await blank()
            try expect(field(view) == nil, "\(page): cleared search collapses again")
        }
        print("PASS blank canvas: input dismissal, preserved draft, refocus and search closure on every page")
    }

    @MainActor static func initialDirectoryTests() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-first-launch-\(UUID().uuidString)")
        let suite = "folioak-first-launch-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: home)
            preferences.removePersistentDomain(forName: suite)
        }
        let root = home.appendingPathComponent("Downloads/Folioak")
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
        let suite = "folioak-sidebar-layout-\(UUID().uuidString)"
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
        try await workspacePolishTests()
    }

    @MainActor static func menuChevronTests() throws {
        _ = NSApplication.shared
        let view = MenuChevron.ChevronView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        content.addSubview(view); window.contentView = content; window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.configure(menuTitle: "/test/Folioak", color: .white, animated: true)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let menu = NSMenu(), other = NSMenu()
        menu.addItem(withTitle: "/test/Folioak", action: nil, keyEquivalent: "")
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
        view.configure(menuTitle: "/test/Folioak", color: .white, animated: false)
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
        let originalTab = model.settingsTab
        defer { model.settingsTab = originalTab }
        model.settingsTab = "通用"
        let view = NSHostingView(rootView: WorkspaceSettingsView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func header(_ tab: String) async throws -> [Bool] {
            model.settingsTab = tab
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("settings bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / 680
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
        try expect(frames.count == 4 && frames.allSatisfy { abs($0.minX - frames[0].minX) < 1 && abs($0.width - frames[0].width) < 1 && view.bounds.contains($0) }, "shortcut recorders share one column and remain inside the window: frames=\(frames), bounds=\(view.bounds)")
        try expect(try await header("浏览器认证") == general, "authentication shares the settings header without shifting content")
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
        model.navigation = WorkspaceNavigation(page: .logs)
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
        // Isolate selection from foreground color and the moving underline.
        // Every text pixel should remain identical, including neighboring tabs.
        let stableProbe = FilterLayoutProbe()
        stableProbe.inset = 0
        let black = ThemePalette(canvas: 0xFFFFFF, surface: 0xFFFFFF, text: 0, secondary: 0,
                                 border: 0xDDDDDD, accent: 0, action: 0, onAction: 0xFFFFFF)
        let stableView = NSHostingView(rootView: MovingFilterProbe(probe: stableProbe, palette: black))
        let stableWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 36), styleMask: [.borderless], backing: .buffered, defer: false)
        stableWindow.contentView = stableView
        defer { stableWindow.orderOut(nil) }
        func textPixels() throws -> [UInt8] {
            stableView.layoutSubtreeIfNeeded(); stableWindow.displayIfNeeded()
            guard let bitmap = stableView.bitmapImageRepForCachingDisplay(in: stableView.bounds) else { throw TestFailure.failed("stable filter bitmap") }
            stableView.cacheDisplay(in: stableView.bounds, to: bitmap)
            let rows = Int(CGFloat(bitmap.pixelsHigh) * 29 / 36)
            return (0..<rows).flatMap { y in
                (0..<bitmap.pixelsWide).map { x in
                    UInt8(((bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 1) * 255).rounded())
                }
            }
        }
        for titles in [["All", "Info", "Success", "Warning", "Error"], ["全部", "信息", "成功", "注意", "错误"]] {
            stableView.rootView = MovingFilterProbe(probe: stableProbe, titles: titles, palette: black)
            stableProbe.selection = 0
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            let baseline = try textPixels()
            for selected in [1, 3, 2, 4, 0] {
                stableProbe.selection = selected
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                try expect(try textPixels() == baseline, "filter selection preserves every text pixel in \(titles[0])")
            }
        }
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
                   hasLogs: !probe.entries.isEmpty, query: probe.query, level: $probe.level, palette: AppTheme.graphite.palette(dark: false),
                   reduceMotionOverride: false)
    }
}
extension CoreTests {
    @MainActor static func logScrollTests() async throws {
        let probe = LogRegressionProbe()
        let task = UUID()
        probe.entries = (0..<1500).map { i in
            ActivityEntry(level: i % 9 == 0 ? .warning : .info, message: "日志 \(i) · " + String(repeating: "较长的消息，检查实际滚动边界。", count: i % 5), subject: "回归检查", itemID: task)
        }
        // This fixture asserts animated frames; the runner may enable Reduce Motion.
        // Direct and in-flight reduced-motion jumps are covered by the native checks below.
        let view = NSHostingView(rootView: LogRegressionView(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
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
        func clickJump(settles: Bool = true) async {
            let point = NSPoint(x: view.bounds.maxX - 18, y: view.bounds.maxY - 18)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            if settles { await settle() }
        }
        await clickJump(settles: false)
        try await Task.sleep(nanoseconds: 90_000_000)
        let upwardPosition = scroll.contentView.bounds.minY
        try expect(!LogScrollPosition(scroll: scroll).atTop && !LogScrollPosition(scroll: scroll).atBottom,
                   "upward log jump exposes an intermediate frame")
        await clickJump(settles: false)
        try await Task.sleep(nanoseconds: 90_000_000)
        try expect(scroll.contentView.bounds.minY < upwardPosition, "repeated arrow click continues upward until arrival")
        await settle()
        try expect(LogScrollPosition(scroll: scroll).atTop, "real log button reaches earliest entry after lazy row reflow")
        await clickJump(settles: false)
        try await Task.sleep(nanoseconds: 90_000_000)
        let downwardPosition = scroll.contentView.bounds.minY
        try expect(!LogScrollPosition(scroll: scroll).atTop && !LogScrollPosition(scroll: scroll).atBottom,
                   "downward log jump exposes an intermediate frame")
        await clickJump(settles: false)
        try await Task.sleep(nanoseconds: 90_000_000)
        try expect(scroll.contentView.bounds.minY > downwardPosition, "repeated arrow click continues downward until arrival")
        await settle()
        try expect(LogScrollPosition(scroll: scroll).atBottom, "arrow switches destination only after reaching the endpoint")
        await clickJump()
        try expect(LogScrollPosition(scroll: scroll).atTop, "arrival enables the next upward jump")
        // Deliver a real wheel event rather than synthesizing a live-scroll notification.
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                            wheel1: -120, wheel2: 0, wheel3: 0)!
        scroll.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        await settle()
        let readingFromTop = scroll.contentView.bounds.minY
        try expect(readingFromTop > 2, "manual wheel scrolling releases the requested top anchor")
        probe.entries.append(ActivityEntry(level: .info, message: "顶部阅读位置不被新增日志打断", subject: nil, itemID: nil))
        await settle()
        try expect(abs(scroll.contentView.bounds.minY - readingFromTop) < 2, "appending logs preserves manual reading after jumping to top")
        await clickJump()
        try expect(LogScrollPosition(scroll: scroll).atBottom, "real log button returns to latest entry after manual scrolling")
        await clickJump()
        try expect(LogScrollPosition(scroll: scroll).atTop, "repeated log button click reaches exact top")
        await clickJump()
        try expect(LogScrollPosition(scroll: scroll).atBottom, "repeated log button click reaches exact bottom")
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
        print("PASS logs: 1500 variable-height rows, arrow direction during repeated clicks, real button endpoints, wheel takeover, tail following, manual reading, empty-search/filter restoration, animation reversal/cancellation and reduced motion")
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


@MainActor private final class DisclosureRegressionProbe: ObservableObject {
    @Published var expanded = false
    @Published var revision = 0
}
private struct DisclosureRegressionView: View {
    @ObservedObject var probe: DisclosureRegressionProbe
    var body: some View {
        DisclosureGroup("下载记录", isExpanded: $probe.expanded) { Text("Selectable log \(probe.revision)").textSelection(.enabled) }
            .disclosureGroupStyle(RecordDisclosureStyle()).font(.system(size: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension CoreTests {
    @MainActor static func detailInteractionTests() async throws {
        let probe = DisclosureRegressionProbe()
        let host = InteractionTestHost(rootView: DisclosureRegressionView(probe: probe))
        let testWindow = SelectionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 436, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        testWindow.contentView = host; testWindow.orderFront(nil)
        defer { testWindow.orderOut(nil) }
        func settle(_ view: NSView) async {
            try? await Task.sleep(nanoseconds: 120_000_000)
            view.layoutSubtreeIfNeeded()
        }
        await settle(host)
        for fraction: CGFloat in [0.025, 0.22, 0.95] {
            let before = probe.expanded
            let point = host.convert(NSPoint(x: host.bounds.width * fraction, y: host.isFlipped ? 16 : host.bounds.height - 16), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                testWindow.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: testWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            await settle(host)
            try expect(probe.expanded != before, "arrow, title and trailing blank each toggle the full-height record header")
        }
        probe.revision += 1; await settle(host)
        try expect(probe.expanded, "parent updates preserve disclosure state")

        let suite = "folioak-detail-interaction-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder); AppLocalization.shared.language = .chinese }
        let pdf = folder.appendingPathComponent("A long file name for scroll gutter and selection.pdf")
        try createPDF(at: pdf)
        let model = DownloadModel(preferences: preferences)
        model.theme = .graphite
        var item = DownloadItem(original: "1706.03762", state: .saved, savedURL: pdf, documentTitle: "Details fixture")
        let start = Date().addingTimeInterval(-17.8)
        var trace = TaskDiagnostics(now: start)
        trace.receive(.metadata, now: start)
        trace.receive(.resolved(PaperMetadata(reference: try ArxivReference.parse("1706.03762"), title: "Details fixture", year: 2017, month: 6)), now: start.addingTimeInterval(0.8))
        trace.receive(.waiting(start.addingTimeInterval(17.8)), now: start.addingTimeInterval(2.5))
        trace.finish(now: start.addingTimeInterval(17.8)); item.diagnostics = trace
        model.history = [item]
        model.logs = (0..<90).map { ActivityEntry(level: .info, message: "Log \($0) " + String(repeating: "a long selectable message ", count: 8), subject: nil, itemID: item.id) }
        func nativeScroll(_ root: NSView) -> NSScrollView? { (root as? NSScrollView) ?? root.subviews.lazy.compactMap(nativeScroll).first }
        for language in [AppLanguage.chinese, .english] {
            AppLocalization.shared.language = language
            for scheme in [ColorScheme.light, .dark] {
                let view = InteractionTestHost(rootView: TaskDiagnosticView(model: model, item: item, showingDiagnostics: true).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view; window.orderFront(nil)
                defer { window.orderOut(nil) }
                await settle(view)
                guard let scroll = nativeScroll(view), let document = scroll.documentView else { throw TestFailure.failed("details native scroll") }
                for style in [NSScroller.Style.overlay, .legacy] {
                    scroll.scrollerStyle = style; scroll.tile(); await settle(view)
                    for bottom in [false, true] {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom ? document.bounds.maxY - scroll.contentView.bounds.height : 0))
                        scroll.reflectScrolledClipView(scroll.contentView); await settle(view)
                        // Hide only scroller paint so text can be checked independently of the thumb.
                        scroll.verticalScroller?.alphaValue = 0
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("detail bitmap") }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: view)
                        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                        let background = ThemePalette.nativeColor(model.theme.palette(dark: scheme == .dark).canvas).usingColorSpace(.deviceRGB)!
                        for y in stride(from: clip.minY + 2, to: clip.maxY - 2, by: 2) {
                            let py = view.isFlipped ? y : view.bounds.height - y
                            let pixel = bitmap.colorAt(x: Int((clip.maxX - 12) * scale), y: Int(py * scale))!.usingColorSpace(.deviceRGB)!
                            try expect(abs(pixel.redComponent - background.redComponent) < 0.03 && abs(pixel.greenComponent - background.greenComponent) < 0.03 && abs(pixel.blueComponent - background.blueComponent) < 0.03,
                                       "detail text and dividers stay outside the scroll gutter at top and tail")
                        }
                        scroll.verticalScroller?.alphaValue = 1
                    }
                }
                if CommandLine.arguments.contains("--snapshots"), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(200, max(0, document.bounds.height - scroll.contentView.bounds.height)))); scroll.reflectScrolledClipView(scroll.contentView); await settle(view)
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/detail-record-\(language.rawValue)-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
        print("PASS details: full-row mouse targets, stable expansion and clear text gutters in both languages, appearances and scroll styles")
    }

    @MainActor static func inputScrollGutterTests() async throws {
        let suite = "folioak-input-gutter-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.input = String(repeating: "https://example.com/" + String(repeating: "a", count: 150) + "\n", count: 20)
        let view = InteractionTestHost(rootView: LinkInput(model: model, focused: .constant(false), palette: model.theme.palette(dark: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 104), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func input(_ root: NSView) -> LinkTextView? { (root as? LinkTextView) ?? root.subviews.lazy.compactMap(input).first }
        try await Task.sleep(nanoseconds: 100_000_000); view.layoutSubtreeIfNeeded()
        guard let editor = input(view), let scroll = editor.enclosingScrollView, let container = editor.textContainer, let layout = editor.layoutManager else { throw TestFailure.failed("native gutter input") }
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            for width: CGFloat in [240, 400, 640] {
                window.setContentSize(NSSize(width: width, height: 104))
                view.layoutSubtreeIfNeeded(); scroll.tile(); layout.ensureLayout(for: container)
                let edge = editor.convert(NSPoint(x: editor.textContainerOrigin.x + layout.usedRect(for: container).maxX, y: 0), to: scroll)
                let track = scroll.verticalScroller.map { $0.convert($0.bounds, to: scroll).minX } ?? scroll.bounds.maxX
                try expect(edge.x <= track - 2, "wrapped URLs stay clear of \(style) scroll track at \(width): \(edge.x) vs \(track)")
                try expect(editor.textContainerOrigin == NSPoint(x: 7, y: 7), "scroll gutter preserves the input's leading baseline")
                try expect(editor.frame.height > scroll.contentSize.height && !scroll.hasHorizontalScroller, "long links wrap and scroll vertically")
            }
        }
        print("PASS input: wrapped URLs avoid overlay and legacy scrollers at narrow, normal and wide sizes")
    }
}


extension CoreTests {
    @MainActor static func aboutAndMenuBarTests() async throws {
        let components = AboutInformation.components(in: try MediaTools.installed())
        try expect(components.count == 4, "About reads all bundled tool and Python versions")
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance; AppLocalization.shared.language = .chinese }
        let aboutSuite = "folioak-about-workspace-" + UUID().uuidString
        let aboutPreferences = UserDefaults(suiteName: aboutSuite)!
        defer { aboutPreferences.removePersistentDomain(forName: aboutSuite) }
        let aboutModel = DownloadModel(preferences: aboutPreferences)
        for (language, suffix) in [(AppLanguage.chinese, "zh"), (.english, "en")] {
            AppLocalization.shared.language = language
            for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: appearance)
                let content = NSHostingView(rootView: WorkspaceAboutView(model: aboutModel)
                    .environment(\.colorScheme, theme == "light" ? .light : .dark))
                let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.contentView = content; panel.orderFront(nil)
                defer { panel.close() }
                try await Task.sleep(nanoseconds: 160_000_000)
                content.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw TestFailure.failed("About workspace bitmap") }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { throw TestFailure.failed("About workspace image") }
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLanguages = ["zh-Hans", "en-US"]; recognition.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([recognition])
                let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                try expect(visible.contains("Folioak") && visible.contains("Jianzhu") && visible.contains("Codex"),
                    "workspace About displays product and licensed authors: \(visible)")
                for component in components {
                    try expect(visible.contains(component.version), "workspace About displays the bundled \(component.name) version")
                }
                try expect(visible.replacingOccurrences(of: " ", with: "").contains(L("项目主页").replacingOccurrences(of: " ", with: "")),
                    "workspace About keeps the project link visible")
                if CommandLine.arguments.contains("--snapshots") {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/about-\(suffix)-\(theme).png"))
                }
            }
        }
        let suite = "folioak-menu-bar-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = .chinese }
        preferences.set("keep draft", forKey: "unrelatedPreference")
        let model = DownloadModel(preferences: preferences)
        try expect(model.showsMenuBarIcon && preferences.object(forKey: "showsMenuBarIcon") == nil, "menu bar defaults on without rewriting existing preferences")
        var opened = 0, settings = 0, quit = 0, disabled = 0
        var controller: MenuBarController? = MenuBarController(model: model, openWindow: { opened += 1 }, openSettings: { settings += 1 }, quit: { quit += 1 }, disabled: { disabled += 1 })
        weak var released = controller
        guard let first = controller?.item, let image = first.button?.image else { throw TestFailure.failed("default menu bar item and symbol") }
        try expect(image.isTemplate && first.button?.accessibilityLabel() == "Folioak", "menu bar symbol follows system appearance and has an accessible name")
        model.showsMenuBarIcon = true
        try expect(controller?.item === first, "unchanged preference does not create duplicate items")
        for entry in controller!.actionMenu.items where !entry.isSeparatorItem {
            try expect(NSApp.sendAction(entry.action!, to: entry.target, from: entry), "menu action reaches its controller")
        }
        try expect(opened == 1 && settings == 1 && quit == 1, "menu routes show, settings and explicit quit independently")
        model.language = .english
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(controller?.actionMenu.items.map(\.title).contains("Show Folioak") == true, "visible menu immediately follows language changes")
        model.showsMenuBarIcon = false
        try expect(controller?.item == nil && disabled == 1 && !DownloadModel(preferences: preferences).showsMenuBarIcon, "disabling removes the item, restores access and persists across relaunch")
        model.language = .chinese
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(controller?.item == nil, "language changes do not recreate a disabled menu item")
        model.showsMenuBarIcon = true
        try expect(controller?.actionMenu.items.first?.title == "显示 Folioak", "re-enabling creates one menu in the current language")
        controller = nil
        try expect(released == nil && preferences.string(forKey: "unrelatedPreference") == "keep draft", "menu controller releases observers and preserves other settings")
        print("PASS About/menu bar: original repo link, author, default on, runtime off/on, persisted preference, localized actions and released controller")
    }
}


extension CoreTests {
    @MainActor static func workspacePolishTests() async throws {
        let suite = "folioak-workspace-polish-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        func input(_ root: NSView) -> LinkTextView? { (root as? LinkTextView) ?? root.subviews.lazy.compactMap(input).first }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for scheme in [ColorScheme.light, .dark] {
            let model = DownloadModel(preferences: preferences)
            model.theme = .graphite
            model.history = [DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"),
                                          state: .saved, savedURL: folder.appendingPathComponent("fixture.pdf"), documentTitle: "Saved paper")]
            let window = SelectionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
            let view = InteractionTestHost(rootView: DownloaderView(model: model, endTextEditing: { [weak window] in
                if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
            }).environment(\.colorScheme, scheme))
            window.contentView = view; window.orderFront(nil)
            defer { window.orderOut(nil) }
            func settle() async {
                try? await Task.sleep(nanoseconds: 100_000_000)
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
            func clickFromTop(_ x: CGFloat, _ y: CGFloat) async {
                let point = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                await settle()
            }
            await settle()
            guard let editor = input(view), let scroll = editor.enclosingScrollView else { throw TestFailure.failed("full-size native input") }
            try expect(abs(scroll.bounds.height - WorkspaceMetrics.inputHeight) < 1,
                       "empty idle composer stays full-size with existing records at minimum window size")
            model.focusInput(); await settle()
            try expect(input(view) === editor && window.firstResponder === editor && abs(scroll.bounds.height - WorkspaceMetrics.inputHeight) < 1,
                       "keyboard focus preserves the editor and its full height without moving the layout")
            editor.insertText("1706.03762", replacementRange: editor.selectedRange())
            editor.setSelectedRange(NSRange(location: 2, length: 4))
            model.objectWillChange.send(); await settle()
            try expect(input(view) === editor && editor.selectedRange() == NSRange(location: 2, length: 4), "ordinary redraw preserves the input selection")
            await clickFromTop(680, 470)
            try expect(model.input == "1706.03762" && abs(scroll.bounds.height - WorkspaceMetrics.inputHeight) < 1,
                       "a nonempty draft stays expanded after focus leaves")
            model.input = ""; await settle()
            try expect(input(view) === editor && abs(scroll.bounds.height - WorkspaceMetrics.inputHeight) < 1, "cleared idle draft stays full-size without replacing its native view")
            model.input = "https://example.com/video.mp4"; await settle()
            try expect(input(view) === editor && abs(scroll.bounds.height - WorkspaceMetrics.inputHeight) < 1, "pasted and dropped content preserves the full-size input")
            model.input = ""; await settle()
            if CommandLine.arguments.contains("--snapshots"), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/workspace-input-\(scheme == .light ? "light" : "dark")-\(reducedMotion ? "reduced" : "motion").png"))
            }
            // Settings/About now share the sidebar footer. Locate the rendered
            // Logs label instead of assuming its old distance from the bottom.
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("sidebar log bitmap") }
            view.cacheDisplay(in: view.bounds, to: image)
            guard let cgImage = image.cgImage else { throw TestFailure.failed("sidebar log image") }
            let labels = VNRecognizeTextRequest()
            labels.recognitionLanguages = ["zh-Hans", "en-US"]; labels.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: cgImage).perform([labels])
            guard let label = labels.results?.first(where: {
                $0.boundingBox.midX * view.bounds.width < 190 &&
                ($0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "").hasSuffix(L("日志")) ?? false)
            }) else { throw TestFailure.failed("visible sidebar log label: " + (labels.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")) }
            await clickFromTop(label.boundingBox.midX * view.bounds.width, (1 - label.boundingBox.midY) * view.bounds.height)
            try expect(editor.window == nil, "the visible sidebar log entry navigates away from downloads")
            try expect(model.history.count == 1, "layout and navigation preserve every attempt record")
        }
        let authenticationModel = DownloadModel(preferences: preferences)
        let message = BrowserAuthenticationIssue.loginRequired.message
        let mediaURL = URL(string: "https://www.youtube.com/watch?v=fixture")!
        authenticationModel.history = [DownloadItem(original: mediaURL.absoluteString, directURL: mediaURL, state: .failed,
                                                   error: message.fallback, errorMessage: message, documentTitle: "Authentication fixture")]
        var settingsOpened = 0
        let authenticationView = InteractionTestHost(rootView: DownloaderView(model: authenticationModel, showSettings: { settingsOpened += 1 }))
        let authenticationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        authenticationWindow.contentView = authenticationView; authenticationWindow.orderFront(nil)
        defer { authenticationWindow.orderOut(nil) }
        try await Task.sleep(nanoseconds: 150_000_000); authenticationView.layoutSubtreeIfNeeded()
        func keys(_ root: NSView) -> PaperListKeyboard.KeyView? { (root as? PaperListKeyboard.KeyView) ?? root.subviews.lazy.compactMap(keys).first }
        guard let listKeys = keys(authenticationView) else { throw TestFailure.failed("authentication recovery list") }
        let listFrame = listKeys.convert(listKeys.bounds, to: authenticationView)
        let top = authenticationView.isFlipped ? listFrame.minY : authenticationView.bounds.height - listFrame.maxY
        // A real local mouse event exercises the rendered SwiftUI control.
        // Background processes may not expose an accessibilityChildren tree.
        let actionY = top + 1 + WorkspaceMetrics.Space.regular + 1 + WorkspaceMetrics.controlHeight + WorkspaceMetrics.Space.small + WorkspaceMetrics.controlHeight / 2
        let point = NSPoint(x: listFrame.maxX - 16 - 1 - 10 - 24,
                            y: authenticationView.isFlipped ? actionY : authenticationView.bounds.height - actionY)
        func clickAuthenticationAction() async {
            let location = authenticationView.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                authenticationWindow.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: authenticationWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            try? await Task.sleep(nanoseconds: 100_000_000); authenticationView.layoutSubtreeIfNeeded()
        }
        for language in [AppLanguage.chinese, .english] {
            // Settings is now a retained page in this window. Return to the
            // download row before testing the second language's recovery action.
            authenticationModel.preferencesPage = nil
            let originalLanguage = AppLocalization.shared.language
            AppLocalization.shared.language = language
            defer { AppLocalization.shared.language = originalLanguage }
            try await Task.sleep(nanoseconds: 100_000_000); authenticationView.layoutSubtreeIfNeeded()
            if CommandLine.arguments.contains("--snapshots"), let bitmap = authenticationView.bitmapImageRepForCachingDisplay(in: authenticationView.bounds) {
                authenticationView.cacheDisplay(in: authenticationView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/authentication-recovery-\(language.rawValue).png"))
            }
            authenticationModel.settingsTab = "通用"
            await clickAuthenticationAction()
            try expect(settingsOpened == (language == .chinese ? 1 : 2) && authenticationModel.preferencesPage == .settings && authenticationModel.settingsTab == "浏览器认证" && authenticationModel.history.count == 1,
                       "rendered media recovery button opens authentication settings in both languages without retrying or replacing history")
        }
        authenticationModel.preferencesPage = nil
        let pdfURL = URL(string: "https://example.com/paper.pdf")!
        authenticationModel.history = [DownloadItem(original: pdfURL.absoluteString, directURL: pdfURL, state: .failed,
                                                   error: message.fallback, errorMessage: message, documentTitle: "PDF fixture")]
        try await Task.sleep(nanoseconds: 100_000_000); authenticationView.layoutSubtreeIfNeeded()
        await clickAuthenticationAction()
        try expect(settingsOpened == 2, "PDF failures do not offer browser authentication")
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let normal = theme.palette(dark: dark), increased = normal.accessibilityAdjusted(.increased)
                try expect(normal.accessibilityAdjusted(.standard).secondary == normal.secondary && increased.border == increased.text,
                           "standard themes remain stable while increased contrast strengthens separators")
                try expect(increased.secondary != normal.secondary && increased.canvas == normal.canvas && increased.accent == normal.accent,
                           "increased contrast retains each theme's canvas and accent")
            }
        }
        let missing = folder.appendingPathComponent("missing.png")
        try expect(MediaThumbnailCache.key(url: missing, scale: 2) == nil && MediaThumbnailCache.key(url: URL(string: "https://example.com/image.png")!, scale: 2) == nil,
                   "thumbnail lookup skips missing and remote paths")
        let local = folder.appendingPathComponent("thumbnail.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<8 { for x in 0..<8 { bitmap.setColor(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1), atX: x, y: y) } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: local)
        guard let firstKey = MediaThumbnailCache.key(url: local, scale: 2) else { throw TestFailure.failed("local thumbnail key") }
        let cancelled = Task { await MediaThumbnailCache.shared.image(url: local, key: firstKey, scale: 2) }
        cancelled.cancel()
        try expect(await cancelled.value == nil, "a cancelled thumbnail request does not populate the image")
        // Exercise a real Quick Look request but bound it independently of service
        // availability; thumbnail failure is an intentional icon fallback.
        let generation = Task { await MediaThumbnailCache.shared.image(url: local, key: firstKey, scale: 2) }
        let timeout = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); generation.cancel() }
        let generated = await generation.value
        timeout.cancel()
        if let generated { try expect(generated.size.width > 0 && generated.size.height > 0, "Quick Look produces a usable image when available") }
        var changed = try Data(contentsOf: local); changed.append(0); try changed.write(to: local)
        try expect(MediaThumbnailCache.key(url: local, scale: 2) != firstKey, "file replacement invalidates the thumbnail key")
        try expect(MediaThumbnailCache.countLimit == 96 && MediaThumbnailCache.byteLimit <= 16 * 1024 * 1024, "thumbnail cache has count and byte budgets")
        print("PASS workspace polish: fixed input height/focus/paste identity and selection, minimum window, sidebar logs, light/dark/current motion setting, increased contrast, authentication recovery and bounded/cancellable local thumbnails")
    }
}
