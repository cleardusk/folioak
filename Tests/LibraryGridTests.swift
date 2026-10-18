import AppKit
import SwiftUI

private final class GridTestWindow: NSWindow { override var isKeyWindow: Bool { true } }
private final class GridPickerHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private struct GridPickerFixture: View {
    @ObservedObject var model: DownloadModel
    var body: some View { LibraryDisplayPicker(selection: $model.documentDisplayMode, palette: AppTheme.graphite.palette(dark: false)) }
}

extension CoreTests {
    @MainActor static func libraryDisplayPickerClickTests() async throws {
        let suite = "folioak-picker-click-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        let host = GridPickerHost(rootView: GridPickerFixture(model: model))
        let window = GridTestWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.isMovableByWindowBackground = true
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 80_000_000); host.layoutSubtreeIfNeeded()
        var latencies: [Double] = []
        for edge in [true, false, true, false] {
            for mode in [LibraryDisplayMode.grid, .list] {
                let x = mode == .grid ? (edge ? host.bounds.maxX - 3 : host.bounds.width * 0.75) : (edge ? 3 : host.bounds.width * 0.25)
                let y: CGFloat = edge ? 3 : host.bounds.midY
                let location = host.convert(NSPoint(x: x, y: y), to: nil)
                let start = Date()
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                try expect(model.documentDisplayMode == mode, "native picker \(edge ? "edge" : "center") click switches on first mouse-up to \(mode.rawValue)")
                host.layoutSubtreeIfNeeded()
                latencies.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        print(String(format: "BENCH display picker: %d native edge/center clicks; max %.2f ms", latencies.count, latencies.max() ?? 0))
        print("PASS display picker: full segment hit area, first click, rapid alternating clicks and draggable window")
    }


    @MainActor static func libraryGridPointerTests(pdf: URL) async throws {
        for documents in [true, false] {
            let suite = "folioak-grid-pointer-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            var opened = 0, selected = 0
            let model = DownloadModel(preferences: preferences, opener: { _ in opened += 1; return true })
            let item = DownloadItem(original: "https://example.com/preview.pdf", state: .saved, savedURL: pdf,
                documentTitle: "A longer grid title with 中文文件名称 that needs room for a third line without crowding the actions")
            model.papers = [LibraryPaper(item)]; model.mediaLibrary = [item]
            let row: AnyView = documents
                ? AnyView(LibraryRow(paper: model.papers[0], model: model, selected: false, grid: true, select: { selected += 1 }))
                : AnyView(DownloadRow(item: item, model: model, inMediaLibrary: true, grid: true).onTapGesture { selected += 1 })
            let host = GridPickerHost(rootView: row.frame(width: LibraryGridLayout.minimumColumnWidth))
            let window = GridTestWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
            func children(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(children) }
            let regions = children(host).compactMap { $0 as? FileRowClickRegion.Region }
            guard let controls = regions.first(where: { $0.isControls }) else { throw TestFailure.failed("grid native action region") }
            let actionRect = controls.convert(controls.bounds, to: host)
            try expect(host.bounds.contains(actionRect) && actionRect.height >= 32, "grid action region remains inside the narrow card with full-height targets")
            func click(_ p: NSPoint, count: Int = 1) async throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: host.convert(p, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!)
                    try await Task.sleep(nanoseconds: 15_000_000)
                }
            }
            let cover = NSPoint(x: 70, y: host.isFlipped ? 50 : host.bounds.height - 50)
            try await click(cover)
            try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.05) * 1e9))
            try expect(selected > 0 && opened == 0, "grid cover single click selects without opening")
            try await click(cover); try await click(cover, count: 2)
            try await Task.sleep(nanoseconds: 80_000_000)
            try expect(opened == 1, "grid cover double click opens exactly once")
            try await click(NSPoint(x: actionRect.minX + 16, y: actionRect.midY))
            try expect(opened == 2, "grid visible open action remains independent of card selection")
            window.close()
        }
        print("PASS grid pointer: narrow-card controls, cover selection, double click and independent open action")
    }

    @MainActor static func libraryGridTests(root: URL, pdf: URL) async throws {
        try await libraryDisplayPickerClickTests()
        try await libraryGridPointerTests(pdf: pdf)
        let suite = "folioak-grid-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        try expect(model.documentDisplayMode == .list && model.mediaDisplayMode == .list, "both libraries default to list")
        model.documentDisplayMode = .grid
        let restored = DownloadModel(preferences: preferences)
        try expect(restored.documentDisplayMode == .grid && restored.mediaDisplayMode == .list, "independent display modes survive restart")
        for action in [PaperListKeyboard.Action.up, .extendUp] {
            try expect(LibraryGridLayout.destination(index: 1, count: 8, columns: 3, action: action) == 1, "top row does not jump sideways")
        }
        for action in [PaperListKeyboard.Action.down, .extendDown] {
            try expect(LibraryGridLayout.destination(index: 6, count: 8, columns: 3, action: action) == 6, "bottom row does not jump sideways")
            try expect(LibraryGridLayout.destination(index: 5, count: 8, columns: 3, action: action) == 7, "partial last row chooses nearest column")
        }
        let originalLanguage = AppLocalization.shared.language, originalAppearance = NSApp.appearance
        defer { AppLocalization.shared.language = originalLanguage; NSApp.appearance = originalAppearance }
        func descendants(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(descendants) }
        let qa = URL(fileURLWithPath: "build/qa/library-grid"); try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        func clickMode(_ mode: LibraryDisplayMode, host: NSView, window: NSWindow) async throws {
            let x = host.bounds.width - 24 - (mode == .grid ? 3 : 63)
            let fromTop = WorkspaceMetrics.headerHeight + 5
            let location = host.convert(NSPoint(x: x, y: host.isFlipped ? fromTop : host.bounds.height - fromTop), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        for language in [AppLanguage.chinese, .english] {
            for dark in [false, true] {
                AppLocalization.shared.language = language; model.language = language
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                model.theme = .graphite
                for page in [WorkspacePage.library, .media] {
                    let records: [DownloadItem] = (0..<7).map { index -> DownloadItem in
                        let source = URL(string: "https://example.com/asset-\(index).pdf")!
                        let file = page == .library ? pdf : URL(fileURLWithPath: "Tests/Fixtures/Media/h264.mp4")
                        let title = index == 1 ? "A longer title with 中文文件名称 for grid layout that needs a third line to remain readable" : "Asset \(index)"
                        let date = Date(timeIntervalSince1970: Double(100 - index))
                        return DownloadItem(original: source.absoluteString, directURL: source, state: .saved, savedURL: file,
                            documentTitle: title, createdAt: date, finishedAt: date)
                    }
                    if page == .library { model.papers = records.map(LibraryPaper.init); model.documentDisplayMode = .grid }
                    else { model.mediaLibrary = records; model.mediaDisplayMode = .grid }
                    // Each window is an independent fixture. Establish its
                    // route before mounting so the preceding page cannot leave
                    // a retiring keyboard view during the initial transition.
                    model.navigation = WorkspaceNavigation(page: page)
                    let host = GridPickerHost(rootView: DownloaderView(model: model, page: page).environment(\.colorScheme, dark ? .dark : .light))
                    let window = GridTestWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                    defer { window.close() }
                    func settle() async throws { try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded() }
                    try await settle()
                    guard let keys = descendants(host).compactMap({ $0 as? PaperListKeyboard.KeyView }).first else { throw TestFailure.failed("grid keyboard mounted") }
                    window.makeFirstResponder(keys)
                    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
                        keys.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: code == 34 ? "i" : "", charactersIgnoringModifiers: code == 34 ? "i" : "", isARepeat: false, keyCode: code)!)
                    }
                    key(125); try await settle(); key(124); try await settle(); key(34, flags: .command)
                    try expect(model.diagnosticItem?.id == records[1].id, "grid right arrow selects adjacent asset")
                    model.diagnosticItem = nil
                    try await clickMode(.list, host: host, window: window)
                    try expect((page == .library ? model.documentDisplayMode : model.mediaDisplayMode) == .list, "native toolbar edge click switches real library to list")
                    try await settle()
                    try expect(descendants(host).contains { $0 === keys } && window.firstResponder === keys, "mode switch retains keyboard responder and focus")
                    key(34, flags: .command)
                    try expect(model.diagnosticItem?.id == records[1].id, "selection survives grid-to-list switch")
                    model.diagnosticItem = nil
                    try await clickMode(.grid, host: host, window: window)
                    try expect((page == .library ? model.documentDisplayMode : model.mediaDisplayMode) == .grid, "native toolbar edge click switches real library to grid")
                    try await settle()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure.failed("grid screenshot") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("\(page == .library ? "documents" : "media")-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                    window.close()
                }
                let naming = NSHostingView(rootView: AssetNamingSettings(model: model, palette: model.theme.palette(dark: dark)).environment(\.colorScheme, dark ? .dark : .light))
                let namingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
                namingWindow.contentView = naming; naming.layoutSubtreeIfNeeded()
                if language == .chinese && !dark {
                    guard let format = descendants(naming).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("自定义模板") }) else { throw TestFailure.failed("native template format picker") }
                    if let index = format.menu?.items.firstIndex(where: { $0.title == "自定义模板" }) { format.menu?.performActionForItem(at: index) }
                    try await Task.sleep(nanoseconds: 80_000_000); naming.layoutSubtreeIfNeeded()
                    guard let field = descendants(naming).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.isEnabled }) else { throw TestFailure.failed("custom template is editable") }
                    field.stringValue = ""
                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                    try await Task.sleep(nanoseconds: 80_000_000); naming.layoutSubtreeIfNeeded()
                    try expect(field.isEnabled && format.titleOfSelectedItem == "自定义模板", "clearing custom template keeps editable custom mode")
                    if let index = format.menu?.items.firstIndex(where: { $0.title == "默认命名" }) { format.menu?.performActionForItem(at: index) }
                    try await Task.sleep(nanoseconds: 80_000_000); naming.layoutSubtreeIfNeeded()
                }
                if let bitmap = naming.bitmapImageRepForCachingDisplay(in: naming.bounds) {
                    naming.cacheDisplay(in: naming.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("naming-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                }
                namingWindow.orderOut(nil)
            }
        }
        try expect(MediaThumbnailCache.key(url: pdf, scale: 2) != MediaThumbnailCache.key(url: pdf, scale: 2, size: CGSize(width: 180, height: 112)), "grid and list thumbnails have different cache identities")
        // Mount the real library surface, counting native row regions and
        // thumbnail loads rather than benchmarking only its cached query.
        for page in [WorkspacePage.library, .media] {
            let records = (0..<20_000).map { index in
                DownloadItem(original: "asset-\(index)", state: .saved, savedURL: pdf, documentTitle: "Asset \(index)", createdAt: Date(timeIntervalSince1970: Double(index)))
            }
            if page == .library { model.papers = records.map(LibraryPaper.init); model.documentDisplayMode = .grid }
            else { model.mediaLibrary = records; model.mediaDisplayMode = .grid }
            model.navigation = WorkspaceNavigation(page: page)
            let baseline = MediaThumbnailCache.loadCount, start = Date()
            let host = GridPickerHost(rootView: DownloaderView(model: model, page: page))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            let mount = Date().timeIntervalSince(start) * 1000
            var pulses = 0
            for _ in 0..<10 { try await Task.sleep(nanoseconds: 20_000_000); pulses += 1 }
            let regions = descendants(host).compactMap { $0 as? FileRowClickRegion.Region }.filter { !$0.isControls }.count
            let requests = MediaThumbnailCache.loadCount - baseline
            try expect(regions > 0 && regions < 150 && requests < 150 && pulses == 10, "20k grid mounts and requests only viewport neighborhood")
            print(String(format: "BENCH 20k %@ grid: mount %.2f ms; native cards %d; thumbnail loads %d; pulses %d", page == .library ? "documents" : "media", mount, regions, requests, pulses))
            let queryBuilds = model.libraryQueries.documentBuilds + model.libraryQueries.mediaBuilds
            var switches: [Double] = []
            for mode in [LibraryDisplayMode.list, .grid, .list, .grid] {
                let started = Date()
                try await clickMode(mode, host: host, window: window)
                try expect((page == .library ? model.documentDisplayMode : model.mediaDisplayMode) == mode, "20k library responds to each real toolbar click")
                host.layoutSubtreeIfNeeded()
                switches.append(Date().timeIntervalSince(started) * 1000)
            }
            try expect(model.libraryQueries.documentBuilds + model.libraryQueries.mediaBuilds == queryBuilds, "20k mode switches reuse the same query result")
            print(String(format: "BENCH 20k %@ native mode switches: max %.2f ms; no query rebuild", page == .library ? "documents" : "media", switches.max() ?? 0))
            window.close()
        }
        print("PASS grid: independent persisted modes, native keyboard navigation, selection/focus across switching, bilingual light/dark minimum-window layouts")
    }
}
