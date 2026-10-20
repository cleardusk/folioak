import AppKit
import SwiftUI

private final class LibraryPolishHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private final class LibraryPolishWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension CoreTests {
    @MainActor static func libraryBlankSelectionUITests(root: URL, pdf: URL) async throws {
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        // This fixture checks selection across draggable chrome. Observe its
        // callback without entering window-server dragging with synthetic input.
        let previousDragProbe = WindowDragRegion.Region.dragProbe
        WindowDragRegion.Region.dragProbe = {}
        defer { WindowDragRegion.Region.dragProbe = previousDragProbe }
        for page in [WorkspacePage.library, .media] {
            for mode in [LibraryDisplayMode.list, .grid] {
              for scrollerStyle in [NSScroller.Style.overlay, .legacy] {
               // Keep native menu observation terminal in each scenario.
               // The CLI host has no normal application menu-event loop.
               for selectionScenario in 0..<4 {
                let suite = "folioak-blank-selection-" + UUID().uuidString
                let preferences = UserDefaults(suiteName: suite)!
                defer { preferences.removePersistentDomain(forName: suite) }
                var opened = 0
                let model = DownloadModel(preferences: preferences, opener: { _ in opened += 1; return true },
                    stateURL: root.appendingPathComponent(suite).appendingPathComponent("workspace.json"))
                let folder = root.appendingPathComponent(suite)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let fixture = page == .library ? pdf : URL(fileURLWithPath: "Tests/Fixtures/Media/h264.mp4")
                for index in 0..<2 {
                    let file = folder.appendingPathComponent("polish-\(index)." + fixture.pathExtension)
                    try FileManager.default.copyItem(at: fixture, to: file)
                    let source = URL(string: "https://example.com/polish-\(index)." + file.pathExtension)!
                    let item = DownloadItem(original: source.absoluteString, directURL: source,
                        state: .saved, savedURL: file, documentTitle: "Selection fixture \(index)")
                    if page == .library { model.upsertPaper(item) } else { model.upsertMedia(item) }
                }
                model.documentDisplayMode = mode; model.mediaDisplayMode = mode
                let host = LibraryPolishHost(rootView: DownloaderView(model: model, page: page))
                let window = LibraryPolishWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
                window.animationBehavior = .none
                window.contentView = host; window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                let fixtureIDs = Set(page == .library ? model.papers.map(\.id) : model.mediaLibrary.map(\.id))
                var selectionCallbacks: [(id: UUID, ids: Set<UUID>, modifiers: NSEvent.ModifierFlags, key: Bool, active: Bool)] = []
                var selectionCallbackCount = 0
                let previousSelectionProbe = DownloaderView.selectionProbe
                DownloaderView.selectionProbe = { id, ids, modifiers in
                    guard fixtureIDs.contains(id) else { return }
                    selectionCallbackCount += 1
                    if selectionCallbacks.count == 32 { selectionCallbacks.removeFirst() }
                    selectionCallbacks.append((id, ids, modifiers, window.isKeyWindow, NSApp.isActive))
                }
                defer { DownloaderView.selectionProbe = previousSelectionProbe }
                func settle() async {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                }
                func descendants(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(descendants) }
                func key(_ code: UInt16, _ text: String) throws {
                    guard let keys = descendants(host).compactMap({ $0 as? PaperListKeyboard.KeyView }).first else {
                        throw TestFailure.failed("polish fixture has a native list keyboard")
                    }
                    keys.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!)
                }
                var eventNumber = 0
                func click(_ point: NSPoint, modifiers: NSEvent.ModifierFlags = [], tracksMouse: Bool = false) async throws {
                    try expect(window.isKeyWindow, "library pointer fixture retains keyboard focus before click: page=\(page.rawValue) mode=\(mode) style=\(scrollerStyle) scenario=\(selectionScenario) appActive=\(NSApp.isActive)")
                    func describe(_ event: NSEvent) -> String {
                        "type=\(event.type.rawValue) window=\(event.windowNumber) eventNumber=\(event.eventNumber) location=\(event.locationInWindow) modifiers=\(event.modifierFlags.rawValue) timestamp=\(event.timestamp)"
                    }
                    func dequeueOwn(_ expected: NSEvent, waits: Bool) -> (event: NSEvent?, seen: String) {
                        var deferred: [NSEvent] = []
                        // Preserve unrelated events in their original order. Posting
                        // them back does not replace NSApp.currentEvent.
                        defer { for event in deferred.reversed() { NSApp.postEvent(event, atStart: true) } }
                        let deadline = Date(timeIntervalSinceNow: 1)
                        repeat {
                            if let queued = NSApp.nextEvent(matching: NSEvent.EventTypeMask(rawValue: 1 << expected.type.rawValue),
                                until: waits ? deadline : .distantPast, inMode: .default, dequeue: true) {
                                if queued.type == expected.type && queued.windowNumber == expected.windowNumber &&
                                    queued.eventNumber == expected.eventNumber && abs(queued.timestamp - expected.timestamp) < 0.000001 {
                                    return (queued, deferred.suffix(12).map(describe).joined(separator: " | "))
                                }
                                deferred.append(queued)
                            } else if !waits { break }
                        } while Date() < deadline
                        return (nil, deferred.suffix(12).map(describe).joined(separator: " | "))
                    }
                    func dispatch(_ event: NSEvent) {
                        NSApp.sendEvent(event)
                        // Let AppKit commit/reset the native gesture before an
                        // async wait without consuming unrelated queued input.
                        _ = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(), inMode: .default, dequeue: false)
                    }
                    func send(_ event: NSEvent) throws {
                        // The normal event-loop dequeue updates NSApp.currentEvent.
                        // Calling sendEvent directly leaves it stale, so a SwiftUI
                        // tap would lose this click's Command/Shift modifiers.
                        NSApp.postEvent(event, atStart: true)
                        let result = dequeueOwn(event, waits: true)
                        guard let queued = result.event else {
                            throw TestFailure.failed("library click dequeues its own native event within 1s: page=\(page.rawValue) mode=\(mode) style=\(scrollerStyle) target=\(point) hit=\(String(describing: host.hitTest(point))) expected={\(describe(event))} encountered={\(result.seen)}")
                        }
                        dispatch(queued)
                    }
                    if tracksMouse {
                        // Text fields, scrollers and native menus can consume the
                        // release in a nested tracking loop. Queue it before down.
                        let location = host.convert(point, to: nil)
                        let timestamp = ProcessInfo.processInfo.systemUptime
                        eventNumber += 1
                        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: modifiers,
                            timestamp: timestamp, windowNumber: window.windowNumber,
                            context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1)!
                        eventNumber += 1
                        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: modifiers,
                            timestamp: timestamp + 0.001, windowNumber: window.windowNumber,
                            context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0)!
                        NSApp.postEvent(up, atStart: true)
                        try send(down)
                        // Disabled scrollbars need not enter tracking. Deliver
                        // any release still queued rather than leaking it into
                        // the next independent click/menu scenario.
                        if let release = dequeueOwn(up, waits: false).event {
                            dispatch(release)
                        }
                        await settle()
                        return
                    }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        eventNumber += 1
                        try send(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: modifiers,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                        try await Task.sleep(nanoseconds: 15_000_000)
                    }
                    await settle()
                }
                @discardableResult
                func selectRow(_ point: NSPoint, modifiers: NSEvent.ModifierFlags = [],
                               expected: Set<UUID>? = nil, stage: String) async throws -> UUID {
                    let previousCount = selectionCallbackCount
                    try await click(point, modifiers: modifiers)
                    let callback = selectionCallbacks.last
                    let actualModifiers = callback?.modifiers.intersection([.command, .shift, .option, .control])
                    let expectedIDs = expected ?? callback.map { Set([$0.id]) } ?? []
                    guard let observation = callback, selectionCallbackCount == previousCount + 1,
                          observation.ids == expectedIDs, actualModifiers == modifiers else {
                        throw TestFailure.failed("real row click publishes its expected selection: stage=\(stage) page=\(page.rawValue) mode=\(mode) style=\(scrollerStyle) scenario=\(selectionScenario) callbacks=\(selectionCallbackCount - previousCount) expectedIDs=\(expectedIDs) actualIDs=\(String(describing: callback?.ids)) expectedModifiers=\(modifiers.rawValue) actualModifiers=\(String(describing: actualModifiers?.rawValue)) callbackKey=\(String(describing: callback?.key)) callbackActive=\(String(describing: callback?.active)) windowKey=\(window.isKeyWindow) appActive=\(NSApp.isActive) firstResponder=\(String(describing: window.firstResponder)) hit=\(String(describing: host.hitTest(point)))")
                    }
                    return observation.id
                }
                func preserveSelection(after point: NSPoint, tracksMouse: Bool = false, message: String) async throws {
                    try await click(point, tracksMouse: tracksMouse)
                    let before = opened
                    try key(36, "\r")
                    try expect(opened == before + 1, message)
                }
                func separateClickSequence() async throws {
                    // Independent selection scenarios must not become a double
                    // click in the row's native recognizer on the hosting root.
                    try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.1) * 1_000_000_000))
                }
                func enqueueMenuEscape() {
                    // The release queued before menu mouse-down stays first.
                    // Dismiss through native keyboard tracking only after it.
                    let timestamp = max(ProcessInfo.processInfo.systemUptime, (NSApp.currentEvent?.timestamp ?? 0) + 0.002)
                    for (index, type) in [NSEvent.EventType.keyDown, .keyUp].enumerated() {
                        NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                            timestamp: timestamp + Double(index) * 0.001, windowNumber: window.windowNumber,
                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                            isARepeat: false, keyCode: 53)!, atStart: false)
                    }
                }
                await settle()
                guard let scroll = descendants(host).compactMap({ $0 as? FileRowClickRegion.Region })
                    .first(where: { !$0.isControls })?.enclosingScrollView else {
                    throw TestFailure.failed("library rows belong to a native scroll view")
                }
                // Exercise the persistent-scrollbar hit-testing regression
                // without modifying the user's global scrollbar preference.
                scroll.scrollerStyle = scrollerStyle
                scroll.autohidesScrollers = scrollerStyle == .overlay
                scroll.hasVerticalScroller = true
                scroll.tile()
                await settle()
                try expect(scroll.scrollerStyle == scrollerStyle, "library fixture uses the requested scrollbar style")
                let regions = descendants(host).compactMap { $0 as? FileRowClickRegion.Region }
                let rowRegions = regions.filter { !$0.isControls }
                let rowFrames: [CGRect] = rowRegions.map { $0.convert($0.bounds, to: host) }
                let rows = rowFrames.sorted { left, right in
                    if left.minX == right.minX { return left.minY < right.minY }
                    return left.minX < right.minX
                }
                guard rows.count == 2, let row = rows.first,
                      let controls = regions.first(where: { $0.isControls }),
                      let keyboard = descendants(host).compactMap({ $0 as? PaperListKeyboard.KeyView }).first else {
                    throw TestFailure.failed("polish fixture mounts two file rows and controls")
                }
                window.makeFirstResponder(keyboard)
                for _ in 0..<50 {
                    if window.isKeyWindow && window.firstResponder === keyboard { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(window.isKeyWindow && window.firstResponder === keyboard,
                    "library pointer fixture owns keyboard focus before interaction: page=\(page.rawValue) mode=\(mode) style=\(scrollerStyle) scenario=\(selectionScenario) windowKey=\(window.isKeyWindow) appActive=\(NSApp.isActive) firstResponder=\(String(describing: window.firstResponder))")
                let rowPoint = NSPoint(x: row.minX + 40, y: row.midY)
                func assertSelectionCount(_ count: Int) async throws {
                    var titles: [String] = []
                    var trackedMenu: NSMenu?
                    var trackingEnded = false
                    var forcedDismissal = false
                    var cancel: Timer?
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                        guard trackedMenu == nil, let menu = note.object as? NSMenu else { return }
                        trackedMenu = menu
                        titles = menu.items.filter(\.isEnabled).map(\.title)
                        let timer = Timer(timeInterval: 1, repeats: false) { _ in
                            forcedDismissal = true; menu.cancelTrackingWithoutAnimation()
                        }
                        cancel = timer
                        RunLoop.main.add(timer, forMode: .eventTracking)
                        enqueueMenuEscape()
                    }
                    let endObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
                        guard let menu = note.object as? NSMenu, menu === trackedMenu else { return }
                        trackingEnded = true
                    }
                    defer {
                        NotificationCenter.default.removeObserver(observer)
                        NotificationCenter.default.removeObserver(endObserver)
                        cancel?.invalidate()
                    }
                    try await click(NSPoint(x: host.bounds.width - 40, y: host.isFlipped ? 38 : host.bounds.height - 38), tracksMouse: true)
                    for _ in 0..<80 where !trackingEnded { try await Task.sleep(nanoseconds: 25_000_000) }
                    try expect(trackedMenu != nil && trackingEnded && !forcedDismissal,
                        "selection-count menu finishes native Escape tracking in \(page.rawValue) \(mode) \(scrollerStyle): began=\(trackedMenu != nil), ended=\(trackingEnded), forced=\(forcedDismissal), titles=\(titles)")
                    try expect(titles.contains(L("移出所选 \(count) 项")),
                        "native pointer modifiers keep \(count) selected rows in \(page.rawValue) \(mode) \(scrollerStyle), scenario=\(selectionScenario): \(titles)")
                }
                let secondPoint = NSPoint(x: rows[1].minX + 40, y: rows[1].midY)
                let firstID = try await selectRow(rowPoint, stage: "plain before modifier")
                if selectionScenario == 2 {
                    try await selectRow(secondPoint, modifiers: .shift, expected: fixtureIDs, stage: "Shift range")
                    try await assertSelectionCount(2)
                    continue
                } else if selectionScenario < 2 {
                    try await selectRow(secondPoint, modifiers: .command, expected: fixtureIDs, stage: "Command add")
                    if selectionScenario == 1 {
                        try await selectRow(secondPoint, modifiers: .command, expected: [firstID], stage: "Command toggle")
                    }
                    try await assertSelectionCount(selectionScenario == 0 ? 2 : 1)
                    continue
                }
                try await selectRow(secondPoint, modifiers: .shift, expected: fixtureIDs, stage: "range before plain replacement")
                try await separateClickSequence()
                let beforeRowClick = opened
                try await selectRow(rowPoint, expected: [firstID], stage: "plain replaces range")
                try expect(opened == beforeRowClick,
                    "an isolated row click selects without opening in \(page.rawValue) \(mode): before=\(beforeRowClick), opened=\(opened)")
                try key(36, "\r")
                try expect(opened == beforeRowClick + 1,
                    "row click selects without the background clearing it in \(page.rawValue) \(mode): before=\(beforeRowClick), opened=\(opened)")
                try key(49, " ")
                try expect(model.previewURL != nil, "Space still previews a pointer-selected file")
                model.previewURL = nil; await settle()
                let action = controls.convert(controls.bounds, to: host)
                let beforeAction = opened
                try await click(NSPoint(x: action.minX + 16, y: action.midY))
                try expect(opened == beforeAction + 1, "visible row button opens once")
                try key(36, "\r")
                try expect(opened == beforeAction + 2, "row button preserves selection")
                if CommandLine.arguments.contains("--snapshots"), let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let folder = URL(fileURLWithPath: "build/qa/library-polish")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = (page == .library ? "documents" : "media") + "-" + mode.rawValue + "-" + (scrollerStyle == .legacy ? "legacy" : "overlay") + ".png"
                    try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                }
                let fromTop: (CGFloat, CGFloat) -> NSPoint = { x, y in
                    NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
                }
                try await preserveSelection(after: fromTop(230, 38), message: "toolbar blank preserves selection")
                try await preserveSelection(after: fromTop(100, 320), message: "sidebar blank preserves selection")
                model.searchRequest = UUID(); await settle()
                if let search = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == L(page == .library ? "搜索文档" : "搜索媒体") }) {
                    try await preserveSelection(after: search.convert(NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: host), tracksMouse: true,
                        message: "search click preserves selection")
                } else { throw TestFailure.failed("search control is present") }
                let viewport = keyboard.convert(keyboard.bounds, to: host)
                let clip = scroll.contentView.convert(scroll.contentView.bounds.intersection(scroll.contentView.visibleRect), to: host)
                let scrollerFrame = scroll.verticalScroller.map { $0.convert($0.bounds.intersection($0.visibleRect), to: host) }
                func hitsVerticalScroller(_ point: NSPoint) -> Bool {
                    guard let scroller = scroll.verticalScroller, !scroller.isHiddenOrHasHiddenAncestor,
                          scrollerFrame?.contains(point) == true, let hit = host.hitTest(point) else { return false }
                    return hit === scroller || hit.isDescendant(of: scroller)
                }
                let bottomY = host.isFlipped ? viewport.maxY - 12 : viewport.minY + 12
                var blankPoints = [NSPoint(x: viewport.minX + 40, y: bottomY),
                    NSPoint(x: viewport.maxX - 4, y: row.midY),
                    NSPoint(x: viewport.minX - 12, y: row.midY),
                    NSPoint(x: viewport.maxX + 12, y: row.midY)]
                // A persistent scrollbar consumes part of the right margin.
                // Keep an explicit canvas sample immediately inside its clip.
                let rightCanvas = NSPoint(x: clip.maxX - 4, y: row.midY)
                if !blankPoints.contains(rightCanvas) { blankPoints.append(rightCanvas) }
                if mode == .grid {
                    try expect(rows[1].minX > row.maxX, "grid fixture has a real inter-card gap")
                    blankPoints.append(NSPoint(x: (row.maxX + rows[1].minX) / 2, y: row.midY))
                }
                for blank in blankPoints {
                    try await separateClickSequence()
                    try await selectRow(rowPoint, expected: [firstID], stage: "plain before blank canvas")
                    let before = opened
                    let location = "\(page.rawValue) \(mode) style=\(scrollerStyle) point=\(blank) clip=\(clip) scroller=\(String(describing: scrollerFrame)) hit=\(String(describing: host.hitTest(blank)))"
                    if hitsVerticalScroller(blank) {
                        try await click(blank, tracksMouse: true)
                        try key(36, "\r")
                        try expect(opened == before + 1, "actual scrollbar click preserves selection: \(location)")
                        continue
                    }
                    try expect(clip.contains(blank), "blank selection test samples the actual scroll canvas: \(location)")
                    try await click(blank)
                    try key(36, "\r"); try key(49, " ")
                    try expect(opened == before && model.previewURL == nil,
                        "content bottom/gutter/outer margins/grid gap clears selection before Return or Space: \(location)")
                    try key(125, "\u{F701}"); try key(36, "\r")
                    try expect(opened == before + 1, "arrow navigation selects again after blank click")
                }
                // Dismiss real native menu tracking; opening an action menu must
                // not be interpreted as a tap on the scroll background.
                do {
                var tracked = false
                var rowTrackingEnded = false
                var rowForcedDismissal = false
                var trackedRowMenu: NSMenu?
                var menuTitles: [String] = []
                var cancel: Timer?
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard trackedRowMenu == nil, let menu = note.object as? NSMenu else { return }
                    tracked = true
                    trackedRowMenu = menu
                    menuTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                    cancel = Timer(timeInterval: 1, repeats: false) { _ in
                        rowForcedDismissal = true; menu.cancelTrackingWithoutAnimation()
                    }
                    RunLoop.main.add(cancel!, forMode: .eventTracking)
                    enqueueMenuEscape()
                }
                let rowEndObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
                    guard let menu = note.object as? NSMenu, menu === trackedRowMenu else { return }
                    rowTrackingEnded = true
                }
                defer {
                    NotificationCenter.default.removeObserver(observer)
                    NotificationCenter.default.removeObserver(rowEndObserver); cancel?.invalidate()
                }
                try await preserveSelection(after: NSPoint(x: action.maxX - 16, y: action.midY), tracksMouse: true, message: "native row menu preserves selection")
                try expect(tracked && rowTrackingEnded && !rowForcedDismissal, "row action menu receives its native click and Escape dismissal")
                try expect(menuTitles.count == (page == .library ? 8 : 6), "healthy library row exposes its compact action count: \(menuTitles)")
                for title in ["快速预览", "重命名…", "在 Finder 中显示", "详情…", "移到废纸篓…"] {
                    try expect(menuTitles.contains(L(title)), "native compact menu preserves reachable \(title)")
                }
                for title in ["打开来源页面", "复制来源链接", "整理文档…", "查看任务日志", "复制文件名", "重新关联文件…"] {
                    try expect(!menuTitles.contains(L(title)), "healthy library row omits secondary \(title)")
                }
                }
                window.close()
               }
              }
            }
        }
        print("PASS library blank selection UI: overlay/persistent scrollbars, native Command/Shift selection, list/grid row, button, menu, toolbar, sidebar, search, bottom, gutter, outer margins, grid gap and keyboard recovery")
    }
}

extension CoreTests {
    @MainActor static func sidebarIndicatorUITests() async throws {
        let suite = "folioak-sidebar-indicator-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let originalLanguage = AppLocalization.shared.language
        // AppDelegate applies the fresh model's .system language to the singleton.
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = originalLanguage }
        let model = DownloadModel(preferences: preferences)
        model.theme = .graphite
        let previousMenu = NSApp.mainMenu
        let delegate = AppDelegate(model: model)
        delegate.makeMenu()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let about = appMenu?.item(withTitle: L("关于 Folioak"))?.image
        let update = appMenu?.item(withTitle: L("检查更新…"))?.image
        try expect(about?.isTemplate == true && update?.isTemplate == true && about?.size == NSSize(width: 16, height: 16) && about?.size == update?.size,
                   "About and Check for Updates use matching small template menu icons")
        NSApp.mainMenu = previousMenu
        let host = LibraryPolishHost(rootView: DownloaderView(model: model)
            .environment(\.colorScheme, .light))
        let window = LibraryPolishWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async {
            try? await Task.sleep(nanoseconds: 270_000_000)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        func click(_ x: CGFloat, _ topY: CGFloat) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let point = NSPoint(x: x, y: host.isFlipped ? topY : host.bounds.height - topY)
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            await settle()
        }
        func indicatorCenter(_ suffix: String) throws -> CGFloat {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure.failed("sidebar indicator bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            var marks: [CGFloat] = []
            for y in 0..<bitmap.pixelsHigh {
                let color = bitmap.colorAt(x: Int(13.5 * scale), y: y)!.usingColorSpace(.deviceRGB)!
                if color.redComponent < 0.50 { marks.append((CGFloat(y) + 0.5) / scale) }
            }
            try expect((14...18).contains(CGFloat(marks.count) / scale), "exactly one resting 16-point sidebar indicator is mounted: \(suffix), pixels=\(marks.count)")
            if CommandLine.arguments.contains("--snapshots") {
                let folder = URL(fileURLWithPath: "build/qa/library-polish")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("sidebar-" + suffix + ".png"))
            }
            return marks.reduce(0, +) / CGFloat(marks.count)
        }
        await settle()
        let initial = try indicatorCenter("downloads")
        let flipped = abs(initial - 114) < abs(initial - (540 - 114))
        func renderedY(_ top: CGFloat) -> CGFloat { flipped ? top : 540 - top }
        try expect(abs(initial - renderedY(114)) < 2, "download indicator rests beside the first row")
        try await click(37, 164)
        try expect(abs((try indicatorCenter("documents")) - renderedY(164)) < 2, "document click moves the real indicator")
        try await click(37, 214)
        try expect(abs((try indicatorCenter("media")) - renderedY(214)) < 2, "media click keeps the indicator at the third row")
        try await click(37, 402)
        try expect(abs((try indicatorCenter("logs")) - renderedY(402)) < 2, "logs replace the top indicator with exactly one bottom indicator")
        try await click(37, 452)
        try expect(abs((try indicatorCenter("settings")) - renderedY(452)) < 2, "settings shares the bottom navigation indicator")
        try await click(37, 502)
        try expect(abs((try indicatorCenter("about")) - renderedY(502)) < 2, "about moves the same bottom navigation indicator")
        try await click(37, 402)
        try await click(37, 55)
        try expect(abs((try indicatorCenter("logs-collapsed")) - renderedY(402)) < 2, "collapsed sidebar keeps its short indicator at the left edge")
        try await click(37, 164)
        try expect(abs((try indicatorCenter("documents-collapsed")) - renderedY(164)) < 2, "indicator cannot block the collapsed document icon")
        print("PASS sidebar indicator UI: mounted 16-point bar, native navigation, logs and collapsed hit targets")
    }
}
