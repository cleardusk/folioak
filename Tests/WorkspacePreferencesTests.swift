import AppKit
import SwiftUI
import Vision

private final class PreferencesTestHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private final class PreferencesTestWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor enum WorkspacePreferencesTests {
    private static var fixtureVersion: String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "QA" }
        return info["CFBundleShortVersionString"] as? String ?? "QA"
    }
    @MainActor private final class Surface {
        let host: PreferencesTestHost
        let window: PreferencesTestWindow
        init(_ view: some View, size: NSSize = NSSize(width: 780, height: 540)) {
            host = PreferencesTestHost(rootView: AnyView(view))
            window = PreferencesTestWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func settle() async {
            try? await Task.sleep(nanoseconds: 120_000_000)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        var descendants: [NSView] { Self.children(host) }
        private static func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        func bitmap() throws -> NSBitmapImageRep {
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure.failed("preferences bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        func save(_ name: String, enabled: Bool) throws {
            guard enabled else { return }
            let folder = URL(fileURLWithPath: "build/qa/workspace-preferences")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bitmap().representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
        func labels() throws -> [(String, NSPoint)] {
            guard let image = try bitmap().cgImage else { throw TestFailure.failed("preferences CGImage") }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let result = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return (result.string, NSPoint(x: box.midX * host.bounds.width,
                    y: (host.isFlipped ? 1 - box.midY : box.midY) * host.bounds.height))
            }
        }
        private func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "…", with: "").lowercased()
        }
        func location(_ title: String, sidebar: Bool = false) throws -> NSPoint? {
            let target = normalized(title)
            let navigation = Set(["下载", "文档库", "媒体库", "日志", "设置", "关于"].map { normalized(L($0)) })
            return try labels().first { label, point in
                if sidebar { return point.x < 190 && navigation.contains(target) && normalized(label).hasSuffix(target) }
                return point.x > 190 && normalized(label) == target
            }?.1
        }
        func click(_ point: NSPoint, count: Int = 1) async {
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!)
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            await settle()
        }
        func press(_ title: String, sidebar: Bool = false, scroll: NSScrollView? = nil) async throws {
            await settle()
            if try location(title, sidebar: sidebar) == nil, let scroll, let document = scroll.documentView {
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                await settle()
            }
            guard let point = try location(title, sidebar: sidebar) else {
                throw TestFailure.failed("visible preferences control: " + title + "; actual " + (try labels().map(\.0).joined(separator: " | ")))
            }
            await click(point)
        }
        func field(_ placeholder: String) -> NSTextField? {
            descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder && !$0.isHiddenOrHasHiddenAncestor }
        }
        func edit(_ placeholder: String, text: String) throws {
            guard let field = field(placeholder) else { throw TestFailure.failed("preferences editable field: " + placeholder) }
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else { throw TestFailure.failed("preferences field editor") }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        func key(_ view: PaperListKeyboard.KeyView, code: UInt16 = 36, text: String = "\r") {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!)
        }
    }

    static func run(snapshots: Bool) async throws {
        _ = NSApplication.shared
        try navigationHistory()
        let oldLanguage = AppLocalization.shared.language, oldAppearance = NSApp.appearance
        defer { AppLocalization.shared.language = oldLanguage; NSApp.appearance = oldAppearance }
        let suite = "folioak-workspace-preferences-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(false, forKey: "updates.automatic")
        preferences.set(root.path, forKey: "downloadRootDirectory")
        preferences.set("chinese", forKey: "language")
        var opened: [URL] = []
        let model = DownloadModel(preferences: preferences, opener: { opened.append($0); return true },
            updates: UpdateChecker(preferences: preferences, currentVersion: fixtureVersion))
        model.language = .chinese
        let pdf = root.appendingPathComponent("fixture.pdf"); try createPDF(at: pdf)
        model.papers = (0..<50).map { index in
            let source = URL(string: "https://example.com/keep-\(index).pdf")!
            var paper = LibraryPaper(DownloadItem(original: source.absoluteString, directURL: source,
                state: .saved, savedURL: pdf, documentTitle: String(format: "Keep row %02d", index),
                createdAt: Date(timeIntervalSince1970: Double(index))))
            paper.favorite = index.isMultiple(of: 2)
            return paper
        }
        model.input = "keep this draft"
        var rules = model.namingRules; rules[.papers] = "Saved - {title}"; model.namingRules = rules
        let originalIDs = model.papers.map(\.id), originalPaths = model.papers.map(\.file)
        let surface = Surface(DownloaderView(model: model, page: .library))
        defer { surface.window.close() }
        await surface.settle()
        try await libraryRoundTrip(model, surface: surface, opened: { opened.count }, snapshots: snapshots)
        try await navigationRoundTrip(model, surface: surface, opened: { opened.count }, snapshots: snapshots)
        try await mediaGridRoundTrip(preferences: preferences, root: root, snapshots: snapshots)
        try await pdfDirectorySettings(model, preferences: preferences, root: root, surface: surface, snapshots: snapshots)
        try await namingAndSettings(model, preferences: preferences, surface: surface, snapshots: snapshots)
        try await layouts(model, surface: surface, snapshots: snapshots)
        try await delegateRoutes(model)
        try expect(model.papers.map(\.id) == originalIDs && model.papers.map(\.file) == originalPaths && model.input == "keep this draft",
            "workspace preferences preserve library IDs, file paths and the working draft")
        print("PASS workspace preferences: one-window routes, preserved library search/filter/selection/scroll, disabled hidden file actions, naming draft persistence, saved preferences and minimum-window layouts")
    }

    private static func navigationHistory() throws {
        var history = WorkspaceNavigation()
        history.goBack(); history.goForward()
        try expect(history.back.isEmpty && history.forward.isEmpty, "empty navigation is a no-op")
        let library = WorkspaceRoute(page: .library)
        history.visit(library); history.visit(library)
        try expect(history.back.count == 1, "reselecting the current page creates no duplicate entry")
        history.visit(WorkspaceRoute(page: .library, preferences: .about))
        history.goBack()
        try expect(history.current == library && history.forward.count == 1, "About returns to its exact originating workspace")
        history.visit(library)
        try expect(history.forward.count == 1, "reselecting the page preserves forward history")
        history.visit(WorkspaceRoute(page: .media))
        try expect(history.forward.isEmpty, "a new destination after Back discards the old forward branch")
        for index in 0..<100 { history.visit(WorkspaceRoute(page: index.isMultiple(of: 2) ? .downloads : .library)) }
        try expect(history.back.count == 20, "navigation history stays bounded at 20 prior destinations")
        let current = history.current
        for _ in 0..<30 { history.goBack() }
        try expect(history.back.isEmpty && history.forward.count == 20, "Back stops at the bounded beginning")
        for _ in 0..<30 { history.goForward() }
        try expect(history.forward.isEmpty && history.current == current && history.back.count == 20, "Forward stops at the original end")
        print("PASS navigation history: boundaries, duplicate routes, branching and 20-entry cap")
    }

    private static func navigationRoundTrip(_ model: DownloadModel, surface: Surface, opened: () -> Int, snapshots: Bool) async throws {
        func contentScroll() -> NSScrollView? {
            surface.descendants.compactMap { $0 as? NSScrollView }.first {
                $0.convert($0.bounds, to: surface.host).minX >= 190 && $0.documentView != nil && $0.bounds.height > 150
            }
        }
        guard let scroll = contentScroll() else { throw TestFailure.failed("navigation source scroll") }
        let origin = scroll.contentView.bounds.origin
        try await surface.press("下载", sidebar: true)
        try expect(model.navigation.current.page == .downloads && model.preferencesPage == nil, "sidebar uses shared navigation")
        let y: CGFloat = surface.host.isFlipped ? 38 : surface.host.bounds.height - 38
        await surface.click(NSPoint(x: 230, y: y))
        try expect(model.navigation.current.page == .library, "native Back button returns to the previous page")
        try expect(surface.field("搜索文档")?.stringValue == "Keep row", "Back restores per-page search")
        try expect(abs((contentScroll()?.contentView.bounds.origin.y ?? -1000) - origin.y) < 2, "Back restores the library scroll after its content was unmounted")
        guard let keyboard = surface.descendants.compactMap({ $0 as? PaperListKeyboard.KeyView }).first else { throw TestFailure.failed("navigation restored keyboard") }
        let count = opened(); surface.key(keyboard)
        try expect(opened() == count + 1, "Back restores the selected file")
        let labels = try surface.labels().map(\.0)
        let rows = labels.filter { $0.hasPrefix("Keep row ") }.compactMap { Int($0.suffix(2)) }
        try expect(!rows.isEmpty && rows.allSatisfy { $0.isMultiple(of: 2) }, "Back restores favorites filter")
        try surface.save("navigation-restored", enabled: snapshots)
        await surface.click(NSPoint(x: 262, y: y))
        try expect(model.navigation.current.page == .downloads, "native Forward button restores the next page")
        await surface.click(NSPoint(x: 230, y: y))
        model.preferencesPage = .about; await surface.settle()
        await surface.click(NSPoint(x: 230, y: y))
        try expect(model.navigation.current.page == .library && model.preferencesPage == nil, "Back from About returns to the originating page")
        try expect(model.navigation.forward.last?.preferences == .about, "About remains forward-reachable")
        try await surface.press("媒体库", sidebar: true)
        try expect(model.navigation.forward.isEmpty, "a sidebar jump after Back clears Forward")
        model.navigation.goBack(); await surface.settle()
        let originalLogs = model.logs
        model.logs = (0..<80).map { ActivityEntry(level: .info, message: "Navigation log \($0)", subject: nil, itemID: nil) }
        model.navigation.visit(WorkspaceRoute(page: .logs)); await surface.settle()
        guard let logs = contentScroll() else { throw TestFailure.failed("navigation logs scroll") }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: logs)
        logs.contentView.scroll(to: NSPoint(x: 0, y: 350)); logs.reflectScrolledClipView(logs.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: logs)
        await surface.settle()
        let logsOrigin = logs.contentView.bounds.origin.y
        model.navigation.visit(WorkspaceRoute(page: .downloads)); await surface.settle()
        model.navigation.goBack(); await surface.settle()
        try expect(abs((contentScroll()?.contentView.bounds.origin.y ?? -1000) - logsOrigin) < 2, "Back restores log reading position")
        model.logs = originalLogs
        model.navigation.visit(WorkspaceRoute(page: .library)); await surface.settle()
        print("PASS navigation UI: native Back/Forward, About return, sidebar branching, search/filter/selection/scroll restoration")
    }

    private static func libraryRoundTrip(_ model: DownloadModel, surface: Surface, opened: () -> Int, snapshots: Bool) async throws {
        // Apply a real filter and search; navigation must retain the existing subtree.
        try await surface.press("收藏")
        model.searchRequest = UUID(); await surface.settle()
        try surface.edit("搜索文档", text: "Keep row"); await surface.settle()
        guard let scroll = surface.descendants.compactMap({ $0 as? NSScrollView }).first(where: {
            $0.convert($0.bounds, to: surface.host).minX >= 190 && $0.documentView != nil && $0.bounds.height > 150
        }), let document = scroll.documentView else { throw TestFailure.failed("library scroll for preferences round trip") }
        let lower = min(CGFloat(560), max(0, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: lower)); scroll.reflectScrolledClipView(scroll.contentView)
        await surface.settle()
        guard let row = surface.descendants.compactMap({ $0 as? FileRowClickRegion.Region }).first(where: {
            !$0.isControls && scroll.convert(scroll.bounds, to: surface.host).contains($0.convert(NSPoint(x: 40, y: $0.bounds.midY), to: surface.host))
        }), let keyboard = surface.descendants.compactMap({ $0 as? PaperListKeyboard.KeyView }).first else {
            throw TestFailure.failed("library row and keyboard before preferences")
        }
        await surface.click(row.convert(NSPoint(x: 40, y: row.bounds.midY), to: surface.host))
        let before = opened(); surface.key(keyboard); try expect(opened() == before + 1, "library selection opens before preferences")
        let origin = scroll.contentView.bounds.origin
        let header = try surface.labels().map(\.0)
        try surface.save("library-before", enabled: snapshots)
        try await surface.press("设置", sidebar: true)
        try expect(model.preferencesPage == .settings, "sidebar routes settings inside the workspace")
        let hiddenCount = opened(); surface.key(keyboard)
        try expect(opened() == hiddenCount, "hidden library keyboard cannot open a selected file from settings")
        model.preferencesPage = .about; await surface.settle()
        surface.key(keyboard)
        try expect(opened() == hiddenCount, "hidden library keyboard cannot open a selected file from About")
        surface.window.orderOut(nil); surface.window.makeKeyAndOrderFront(nil); await surface.settle()
        try expect(model.preferencesPage == .about && surface.window.isVisible, "reopening the same main window retains its About route")
        try await surface.press("文档库", sidebar: true)
        try expect(model.preferencesPage == nil, "library navigation returns from preferences")
        try expect(surface.field("搜索文档")?.stringValue == "Keep row", "library search survives settings and About")
        try expect(surface.descendants.contains { $0 === scroll } && abs(scroll.contentView.bounds.origin.y - origin.y) < 2,
            "the same mounted library scroll view and position survive preferences")
        let selected = opened(); surface.key(keyboard)
        try expect(opened() == selected + 1, "library selection survives settings and About")
        let after = try surface.labels().map(\.0)
        try expect(header.contains { $0.contains("已选") } && after.contains { $0.contains("已选") }, "selected library status survives preferences")
        let visibleRows = after.filter { $0.hasPrefix("Keep row ") }.compactMap { Int($0.suffix(2)) }
        try expect(!visibleRows.isEmpty && visibleRows.allSatisfy { $0.isMultiple(of: 2) }, "favorites filter survives the preferences round trip")
        try surface.save("library-after", enabled: snapshots)
    }

    private static func mediaGridRoundTrip(preferences: UserDefaults, root: URL, snapshots: Bool) async throws {
        var opened: [URL] = []
        let model = DownloadModel(preferences: preferences, opener: { opened.append($0); return true },
            updates: UpdateChecker(preferences: preferences, currentVersion: fixtureVersion))
        model.language = .chinese; model.mediaDisplayMode = .grid
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill(); image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure.failed("media grid PNG fixture") }
        model.mediaLibrary = try (0..<15).map { index in
            let file = root.appendingPathComponent("grid-\(index).png"); try png.write(to: file)
            let source = URL(string: "https://example.com/grid-\(index).png")!
            return DownloadItem(original: source.absoluteString, directURL: source, state: .saved, savedURL: file,
                documentTitle: String(format: "Keep media %02d", index), createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let surface = Surface(DownloaderView(model: model, page: .media))
        defer { surface.window.close() }
        await surface.settle()
        model.searchRequest = UUID(); await surface.settle()
        try surface.edit("搜索媒体", text: "Keep media"); await surface.settle()
        guard let scroll = surface.descendants.compactMap({ $0 as? NSScrollView }).first(where: {
            $0.convert($0.bounds, to: surface.host).minX >= 190 && $0.documentView != nil && $0.bounds.height > 150
        }), let document = scroll.documentView else { throw TestFailure.failed("media grid scroll before preferences") }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(400, max(0, document.bounds.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView); await surface.settle()
        guard let row = surface.descendants.compactMap({ $0 as? FileRowClickRegion.Region }).first(where: {
            !$0.isControls && scroll.convert(scroll.bounds, to: surface.host).contains($0.convert(NSPoint(x: 40, y: $0.bounds.midY), to: surface.host))
        }), let keyboard = surface.descendants.compactMap({ $0 as? PaperListKeyboard.KeyView }).first else {
            throw TestFailure.failed("media grid row and keyboard before preferences")
        }
        await surface.click(row.convert(NSPoint(x: 40, y: row.bounds.midY), to: surface.host))
        surface.key(keyboard)
        guard let selectedFile = opened.last else { throw TestFailure.failed("media grid selection opens before preferences") }
        let count = opened.count, origin = scroll.contentView.bounds.origin
        try surface.save("media-grid-before", enabled: snapshots)
        try await surface.press("设置", sidebar: true)
        try expect(model.preferencesPage == .settings && !row.enabled, "settings disable native media-grid click recognizers")
        surface.key(keyboard); try expect(opened.count == count, "settings cannot open the hidden media selection")
        model.preferencesPage = .about; await surface.settle()
        surface.key(keyboard); try expect(opened.count == count, "About cannot open the hidden media selection")
        try await surface.press("媒体库", sidebar: true)
        try expect(model.preferencesPage == nil && model.mediaDisplayMode == .grid && surface.field("搜索媒体")?.stringValue == "Keep media",
            "media grid mode and query survive settings and About")
        try expect(surface.descendants.contains { $0 === scroll } && abs(scroll.contentView.bounds.origin.y - origin.y) < 2,
            "media grid preserves the same scroll view and position")
        surface.key(keyboard)
        try expect(opened.count == count + 1 && opened.last == selectedFile, "media grid preserves the exact selected file")
        model.navigation.visit(WorkspaceRoute(page: .downloads)); await surface.settle()
        model.navigation.goBack(); await surface.settle()
        let restoredScroll = surface.descendants.compactMap { $0 as? NSScrollView }.first {
            $0.convert($0.bounds, to: surface.host).minX >= 190 && $0.documentView != nil && $0.bounds.height > 150
        }
        try expect(surface.field("搜索媒体")?.stringValue == "Keep media" && abs((restoredScroll?.contentView.bounds.origin.y ?? -1000) - origin.y) < 2,
            "Back restores media grid query and scroll after another workspace page")
        if let restoredKeyboard = surface.descendants.compactMap({ $0 as? PaperListKeyboard.KeyView }).first { surface.key(restoredKeyboard) }
        try expect(opened.count == count + 2 && opened.last == selectedFile, "Back restores exact media selection")
        try surface.save("media-grid-after", enabled: snapshots)
        print("PASS media grid preferences: search, exact selection, scroll and disabled hidden native actions survive Settings/About")
    }

    private static func pdfDirectorySettings(_ model: DownloadModel, preferences: UserDefaults, root: URL, surface: Surface, snapshots: Bool) async throws {
        // OCR may merge the checkmark into the label. Match its text suffix.
        func checkboxPoint() throws -> NSPoint? {
            let expected = L("使用单独目录").replacingOccurrences(of: " ", with: "").lowercased()
            return try surface.labels().first { label, point in
                point.x > 190 && label.replacingOccurrences(of: " ", with: "").lowercased().hasSuffix(expected)
            }?.1
        }
        func toggle() async throws {
            await surface.settle()
            guard let point = try checkboxPoint() else { throw TestFailure.failed("visible PDF checkbox") }
            await surface.click(point)
        }
        defer { surface.host.appearance = nil; surface.window.appearance = nil }
        model.preferencesPage = .settings; model.settingsTab = "通用"; model.language = .chinese
        await surface.settle()
        for scroll in surface.descendants.compactMap({ $0 as? NSScrollView }) {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        await surface.settle()
        try expect(!model.usesPDFDirectory && model.pdfDirectory == nil, "general settings start with PDF override disabled")
        try await toggle()
        guard let panel = surface.window.attachedSheet as? NSOpenPanel else { throw TestFailure.failed("PDF toggle opens a directory picker") }
        try expect(panel.canChooseDirectories && !panel.canChooseFiles && !model.usesPDFDirectory, "folder selection must complete before enabling")
        panel.cancel(nil); await surface.settle()
        try expect(model.pdfDirectory == nil && !model.usesPDFDirectory, "cancelling initial folder selection keeps the feature off")
        model.pdfDirectory = root.appendingPathComponent("a-long-research-project-directory/PapersRepo", isDirectory: true)
        try await toggle()
        try expect(model.usesPDFDirectory && DownloadPreferences(preferences).activePDFDirectory?.path == model.pdfDirectory?.path,
            "visible PDF checkbox enables and persists the remembered folder")
        for language in [AppLanguage.chinese, .english] {
            model.language = language
            for appearance in [AppAppearance.light, .dark] {
                model.appearance = appearance; NSApp.appearance = appearance.native
                surface.window.appearance = appearance.native; surface.host.appearance = appearance.native
                surface.host.layoutSubtreeIfNeeded(); surface.window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 450_000_000)
                await surface.settle()
                try surface.save("pdf-directory-\(language.rawValue)-\(appearance.rawValue)", enabled: snapshots)
                try expect(try checkboxPoint() != nil,
                    "localized PDF setting fits the minimum window: " + L("使用单独目录") + "; visible " + (try surface.labels().map(\.0).joined(separator: " | ")))
            }
        }
        model.language = .chinese; await surface.settle()
        try await toggle()
        try expect(!model.usesPDFDirectory && DownloadPreferences(preferences).pdfDirectory != nil, "turning off keeps the last selected folder")
        print("PASS PDF settings UI: folder-only picker, cancel, persisted checkbox, long path, Chinese/English and light/dark layouts")
    }

    private static func namingAndSettings(_ model: DownloadModel, preferences: UserDefaults, surface: Surface, snapshots: Bool) async throws {
        model.preferencesPage = .settings; model.settingsTab = "通用"; await surface.settle()
        let generalScroll = surface.descendants.compactMap { $0 as? NSPopUpButton }.first(where: { $0.isEnabled })?.enclosingScrollView
        try await surface.press("浅色", scroll: generalScroll)
        try expect(model.appearance == .light && preferences.string(forKey: "appearance") == "light", "appearance changes are actually persisted")
        try await surface.press("命名规则")
        try expect(model.settingsTab == "命名规则", "settings category click routes naming inline")
        try surface.edit("命名模板", text: "Draft - {title}"); await surface.settle()
        try expect(model.namingRules[.papers] == "Saved - {title}", "typing a naming draft does not silently save it")
        model.settingsTab = "快捷键"; await surface.settle()
        model.settingsTab = "命名规则"; await surface.settle()
        try expect(surface.field("命名模板")?.stringValue == "Draft - {title}", "naming draft survives settings category switches")
        model.preferencesPage = .about; await surface.settle()
        model.preferencesPage = .settings; await surface.settle()
        try expect(model.settingsTab == "命名规则" && surface.field("命名模板")?.stringValue == "Draft - {title}", "naming draft and category survive About navigation")
        try await surface.press("保存", scroll: surface.field("命名模板")?.enclosingScrollView)
        try expect(model.preferencesPage == .settings && model.namingRules[.papers] == "Draft - {title}" &&
            AssetNamingRules.read(preferences)[.papers] == "Draft - {title}", "inline Save persists naming without dismissing the workspace page")
        let restored = DownloadModel(preferences: preferences)
        try expect(restored.appearance == .light && restored.namingRules[.papers] == "Draft - {title}", "saved settings survive model restart")
        try surface.save("naming-saved", enabled: snapshots)
    }

    private static func delegateRoutes(_ model: DownloadModel) async throws {
        let originalMenu = NSApp.mainMenu
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.mainMenu = originalMenu; NSApp.setActivationPolicy(originalPolicy) }
        model.language = .chinese; model.showsMenuBarIcon = true
        let delegate = AppDelegate(model: model)
        let window = delegate.prepareWorkspaceForTesting()
        defer { window.delegate = nil; window.close() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<30 {
            if NSApp.keyWindow === window { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(NSApp.keyWindow === window, "native menu fixture owns keyboard focus")
        let originalContent = window.contentView
        try expect(window.frameAutosaveName.isEmpty, "test window does not touch personal saved window frames")
        delegate.makeMenu()
        guard let menu = NSApp.mainMenu, let application = menu.items.first?.submenu,
              let settings = application.item(withTitle: "设置…"), let about = application.item(withTitle: "关于 Folioak"),
              let settingsAction = settings.action, let aboutAction = about.action else {
            throw TestFailure.failed("workspace preferences application menu")
        }
        try expect(settings.image?.isTemplate == true && settings.image?.size == NSSize(width: 16, height: 16),
            "Settings has a matching template gear icon")
        try expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == .command,
            "the native Settings menu retains Command-comma")
        try expect(NSApp.sendAction(aboutAction, to: about.target, from: about) && model.preferencesPage == .about,
            "native About menu routes into the existing main window")
        let comma = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
        try expect(menu.performKeyEquivalent(with: comma) && model.preferencesPage == .settings,
            "Command-comma invokes the native Settings route")
        guard let go = menu.item(withTitle: "前往")?.submenu,
              let back = go.item(withTitle: "后退"), let forward = go.item(withTitle: "前进") else {
            throw TestFailure.failed("native navigation menu")
        }
        func navigationKey(_ text: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        let keyWindowMatches = NSApp.keyWindow === window
        let backEnabled = delegate.validateMenuItem(back)
        let backPerformed = menu.performKeyEquivalent(with: navigationKey("[", code: 33))
        try expect(backPerformed && model.preferencesPage == .about,
            "Command-left-bracket invokes Back through the native menu: key=\(keyWindowMatches), enabled=\(backEnabled), performed=\(backPerformed), route=\(model.navigation.current)")
        try expect(menu.performKeyEquivalent(with: navigationKey("]", code: 30)) && model.preferencesPage == .settings,
            "Command-right-bracket invokes Forward through the native menu")
        try expect(!delegate.validateMenuItem(forward), "Forward is disabled at the end of history")
        try expect(window.contentView === originalContent && window.attachedSheet == nil,
            "menu routes reuse the main workspace host without a settings sheet")
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.animationBehavior = .none
        model.preferencesPage = .about
        var sheetEnded = false
        window.beginSheet(sheet, completionHandler: { _ in sheetEnded = true })
        let modalRoute = model.navigation.current
        try expect(!delegate.validateMenuItem(back) && !delegate.validateMenuItem(forward), "navigation is disabled during a modal operation")
        if let action = back.action { _ = NSApp.sendAction(action, to: back.target, from: back) }
        try expect(model.navigation.current == modalRoute, "navigation actions cannot bypass modal protection")
        delegate.showPreferences(.settings)
        try expect(window.attachedSheet === sheet && model.preferencesPage == .about,
            "preferences commands preserve an existing modal operation instead of switching the page behind it")
        window.endSheet(sheet)
        for _ in 0..<50 {
            if sheetEnded { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(sheetEnded && window.attachedSheet == nil, "modal completion drains before its fixture is destroyed")
        sheet.orderOut(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        model.preferencesPage = .settings
        window.performClose(nil)
        try expect(!window.isVisible && model.preferencesPage == .settings,
            "closing the main window hides it with the current preferences route retained")
        try expect(NSApp.sendAction(aboutAction, to: about.target, from: about) && window.isVisible && model.preferencesPage == .about && window.contentView === originalContent,
            "About reopens the same hidden main window and host")
        try expect(NSApp.sendAction(settingsAction, to: settings.target, from: settings) && model.preferencesPage == .settings,
            "Settings remains reachable after closing and reopening the main window")
        print("PASS preferences routes: native Command-comma/About menus, one retained main window, close/reopen and modal-operation protection")
    }

    private static func layouts(_ model: DownloadModel, surface: Surface, snapshots: Bool) async throws {
        for (language, suffix) in [(AppLanguage.chinese, "zh"), (.english, "en")] {
            model.language = language
            for (appearance, theme) in [(AppAppearance.light, "light"), (.dark, "dark")] {
                model.appearance = appearance
                NSApp.appearance = appearance.native
                model.preferencesPage = .settings; model.settingsTab = "通用"
                // Language, theme and route may share a SwiftUI animation transaction.
                // Render its initial state, then wait past the real 240 ms animation.
                surface.host.layoutSubtreeIfNeeded(); surface.window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 450_000_000)
                await surface.settle()
                for (category, slug) in [("通用", "general"), ("命名规则", "naming"), ("快捷键", "shortcuts"), ("浏览器认证", "authentication")] {
                    model.settingsTab = category; await surface.settle()
                    for scroll in surface.descendants.compactMap({ $0 as? NSScrollView }) {
                        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    await surface.settle()
                    try expect(surface.window.contentView === surface.host && surface.window.attachedSheet == nil && surface.host.bounds.width == 780,
                        "settings stay in the minimum-size main content without another window or sheet")
                    try surface.save("\(slug)-\(suffix)-\(theme)", enabled: snapshots)
                    let categoryOCR = try surface.labels().filter { _, point in
                        let top = surface.host.isFlipped ? point.y : surface.host.bounds.height - point.y
                        return point.x > 190 && top >= 54 && top <= 120
                    }.map(\.0)
                    let expected = L(category)
                    let words = expected.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
                    let pattern = "(?i)(?<![A-Za-z0-9])" + words + "(?![A-Za-z0-9])"
                    let categoryVisible = categoryOCR.contains { $0.range(of: pattern, options: .regularExpression) != nil }
                    try expect(categoryVisible, "localized settings category remains visible at minimum width: " + expected + "; top navigation OCR: " + categoryOCR.joined(separator: " | "))
                    if category == "通用" {
                        guard let popup = surface.descendants.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.isEnabled }),
                              let scroll = popup.enclosingScrollView, let document = scroll.documentView else {
                            throw TestFailure.failed("general preferences native scroll and language picker")
                        }
                        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                        await surface.settle()
                        try surface.save("general-bottom-\(suffix)-\(theme)", enabled: snapshots)
                        try expect(bottom > 0 && abs(scroll.contentView.bounds.origin.y - bottom) < 2,
                            "the full theme palette remains reachable by scrolling at minimum height")
                    }
                    if category == "快捷键" {
                        let recorders = surface.descendants.compactMap { $0 as? ShortcutRecorder.Recorder }
                        try expect(recorders.count == 4 && recorders.allSatisfy { recorder in
                            let frame = recorder.convert(recorder.bounds, to: surface.host)
                            return frame.minX >= 190 && frame.maxX <= surface.host.bounds.maxX + 1 && frame.width > 0
                        }, "shortcut recorder columns fit the minimum window in both languages")
                    }
                }
                model.preferencesPage = .about
                surface.host.layoutSubtreeIfNeeded(); surface.window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 300_000_000)
                await surface.settle()
                let labels = try surface.labels().map(\.0).joined(separator: " ")
                try expect(labels.contains("Folioak") && labels.contains("Jianzhu Guo") && labels.contains("Codex"), "About shows product and authors in both languages and appearances")
                try expect(surface.window.attachedSheet == nil, "About is a normal main-window page")
                try surface.save("about-\(suffix)-\(theme)", enabled: snapshots)
            }
        }
    }
}
