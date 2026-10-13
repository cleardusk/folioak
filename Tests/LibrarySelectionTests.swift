import AppKit
import SwiftUI

// These hosts receive only events sent to their own window. They do not require
// Accessibility permission or activation of the user's desktop application.
private final class LibrarySelectionHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class LibrarySelectionWindow: NSWindow {
    // Match SelectionTestWindow: background runners cannot activate the desktop,
    // but still exercise real responders while rendering an active selection.
    override var isKeyWindow: Bool { true }
}

extension CoreTests {
    @MainActor static func fileListSelectionTests() throws {
        let rows = (0..<5).map { _ in UUID() }
        var selection = FileListSelection()
        selection.select(rows[1], visible: rows)
        try expect(selection.ids == [rows[1]] && selection.primary == rows[1], "plain click selects one file")
        selection.select(rows[3], visible: rows, modifiers: .command)
        try expect(selection.ids == [rows[1], rows[3]] && selection.primary == rows[3], "Command click adds a nonadjacent file")
        selection.select(rows[3], visible: rows, modifiers: .command)
        try expect(selection.ids == [rows[1]] && selection.primary == rows[1], "Command click removes a selected file and keeps a valid primary")
        selection.select(rows[2], visible: rows)
        selection.select(rows[4], visible: rows, modifiers: .shift)
        try expect(selection.ids == Set(rows[2...4]) && selection.anchor == rows[2], "Shift click selects the inclusive anchored range")
        selection.select(rows[0], visible: rows, modifiers: .shift)
        try expect(selection.ids == Set(rows[0...2]) && selection.primary == rows[0], "reversing a Shift range uses its original anchor")
        selection.select(rows[4], visible: rows, modifiers: .command)
        selection.select(rows[3], visible: rows, modifiers: [.command, .shift])
        try expect(selection.ids == Set(rows), "Command Shift adds a range without dropping the earlier selection")
        selection.select(rows[2], visible: rows)
        _ = selection.move(1, visible: rows, extend: true)
        _ = selection.move(1, visible: rows, extend: true)
        try expect(selection.ids == Set(rows[2...4]), "Shift Down extends the keyboard range")
        _ = selection.move(-1, visible: rows, extend: true)
        try expect(selection.ids == Set(rows[2...3]), "Shift Up contracts the keyboard range")
        _ = selection.move(-1, visible: rows, extend: false)
        try expect(selection.ids == [rows[2]], "unmodified arrow navigation returns to one selection")
        selection.selectAll(rows)
        try expect(selection.ids == Set(rows) && selection.primary == rows[2], "Select All keeps the keyboard's current primary file")
        selection.retainVisible([rows[0], rows[4]])
        try expect(selection.ids == [rows[0], rows[4]] && selection.primary == rows[0] && selection.anchor == rows[0], "filtering removes hidden selected IDs and repairs primary and anchor")
        selection.selectAll([])
        try expect(selection.ids.isEmpty && selection.primary == nil && selection.anchor == nil, "Select All on empty results clears stale selection")
        selection.select(rows[0], visible: rows)
        selection.select(rows[4], visible: rows, modifiers: [.command, .shift], multiple: false)
        try expect(selection.ids == [rows[4]], "download rows keep single selection even with modifiers")
        selection.select(UUID(), visible: rows)
        try expect(selection.ids == [rows[4]], "a stale row callback cannot select an invisible ID")
        selection.retainVisible([])
        try expect(selection.ids.isEmpty && selection.primary == nil && selection.anchor == nil, "empty filters discard every selection reference")

        var actions: [PaperListKeyboard.Action] = []
        let keys = PaperListKeyboard.KeyView(request: nil, didFocus: { _ in }, action: { actions.append($0) })
        keys.allowsMultipleSelection = true
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) {
            keys.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        key(126, "\u{F700}"); key(125, "\u{F701}")
        key(126, "\u{F700}", .shift); key(125, "\u{F701}", .shift)
        key(0, "a", .command); key(49, " "); key(36, "\r"); key(34, "i", .command)
        try expect(actions == [.up, .down, .extendUp, .extendDown, .selectAll, .preview, .open, .diagnostics],
                   "native KeyView events dispatch multi-selection and existing file actions")
        actions = []; keys.allowsMultipleSelection = false
        key(0, "a", .command); key(125, "\u{F701}", .shift); key(125, "\u{F701}")
        try expect(actions == [.down], "download keyboard ignores library-only multi-selection shortcuts")
        print("PASS file selection: plain/Command/Shift clicks, reversible keyboard ranges, visible-only Select All, filter pruning and native KeyView events")
    }

    @MainActor static func librarySelectionUITests() async throws {
        _ = NSApplication.shared
        let originalLanguage = AppLocalization.shared.language
        let originalAppearance = NSApp.appearance
        defer { AppLocalization.shared.language = originalLanguage; NSApp.appearance = originalAppearance }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-library-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for language in [AppLanguage.chinese, .english] {
            for scheme in [ColorScheme.light, .dark] {
                for page in [WorkspacePage.library, .media] {
                    try await exerciseLibrarySelection(page: page, language: language, scheme: scheme, root: root)
                }
            }
        }
        print("PASS library selection UI: bilingual light/dark minimum windows, repeated native menus, hidden-selection pruning, removal Cancel/Confirm, all-removed recovery and file Trash Cancel/Confirm with restart")
    }

    @MainActor private static func exerciseLibrarySelection(page: WorkspacePage, language: AppLanguage, scheme: ColorScheme, root: URL) async throws {
        let suite = "folioak-library-selection-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(language.rawValue, forKey: "language")
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var recycled: [URL] = []
        var opened = 0
        let model = DownloadModel(preferences: preferences, opener: { _ in opened += 1; return true },
            stateURL: folder.appendingPathComponent("workspace.json"), recycleFile: { file in
                // Exercise a real file move, entirely inside this disposable fixture.
                try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("trash-" + file.lastPathComponent))
                recycled.append(file)
            })
        model.theme = .graphite
        AppLocalization.shared.language = language
        NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        var records: [DownloadItem] = []
        for index in 0..<2 {
            let file = folder.appendingPathComponent("fixture-\(index)." + (page == .library ? "pdf" : "mp4"))
            if page == .library { try createPDF(at: file) }
            else { try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/Fixtures/Media/h264.mp4"), to: file) }
            let source = URL(string: "https://example.com/fixture-\(index)." + file.pathExtension)!
            let title = (index == 0 ? "First" : "Second") + " fixture with a long title for native library selection and action alignment"
            let item = DownloadItem(original: source.absoluteString, directURL: source, state: .saved, savedURL: file,
                documentTitle: title, createdAt: Date().addingTimeInterval(Double(-index)), finishedAt: Date().addingTimeInterval(Double(-index)))
            records.append(item)
            if page == .library { model.upsertPaper(item) } else { model.upsertMedia(item) }
        }
        model.history = records
        model.persistWorkspace()
        let files = records.compactMap(\.savedURL)
        let originalBytes = try files.map { try Data(contentsOf: $0) }
        let view = LibrarySelectionHost(rootView: DownloaderView(model: model, page: page)
            .environment(\.colorScheme, scheme))
        let window = LibrarySelectionWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        func settle() async {
            try? await Task.sleep(nanoseconds: 120_000_000)
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        func descendants(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(descendants) }
        func keyView() -> PaperListKeyboard.KeyView? { descendants(view).compactMap { $0 as? PaperListKeyboard.KeyView }.first }
        func keys(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            guard let responder = keyView() else { throw TestFailure.failed("library keyboard is mounted") }
            responder.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        func clickFromTop(_ x: CGFloat, _ y: CGFloat) {
            let location = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        func menu(_ title: String, perform: Bool = true) async throws {
            var found = false
            var titles: [String] = []
            var trackedMenu: NSMenu?
            var actionFinished = false
            var trackingEnded = false
            let point = NSPoint(x: view.bounds.width - 40, y: view.isFlipped ? 38 : view.bounds.height - 38)
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { notification in
                guard let menu = notification.object as? NSMenu, trackedMenu == nil else { return }
                trackedMenu = menu
                titles = menu.items.map(\.title)
                let index = menu.items.firstIndex(where: { $0.title == title })
                found = index.map { menu.items[$0].isEnabled } ?? false
                // Cancelling synchronously inside didBeginTracking leaves a
                // SwiftUI Menu pressed and prevents later openings. Let AppKit
                // enter tracking before dispatching this native menu action.
                DispatchQueue.main.async {
                    if perform, found, let index { menu.performActionForItem(at: index) }
                    menu.cancelTrackingWithoutAnimation()
                    actionFinished = true
                }
            }
            let endObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { notification in
                guard let menu = notification.object as? NSMenu, menu === trackedMenu else { return }
                trackingEnded = true
            }
            defer {
                NotificationCenter.default.removeObserver(observer)
                NotificationCenter.default.removeObserver(endObserver)
            }
            clickFromTop(view.bounds.width - 40, 38)
            // A following search request must not race native tracking teardown
            // and its responder restoration on slower AppKit/CI environments.
            for _ in 0..<20 {
                await settle()
                if actionFinished && trackingEnded { break }
            }
            if !found || !actionFinished || !trackingEnded {
                try snapshot("menu-failure")
                print("LIBRARY MENU AFTER", page.rawValue, language.rawValue, scheme, title,
                      "actionFinished", actionFinished, "trackingEnded", trackingEnded, "hit", String(describing: view.hitTest(point)),
                      "responder", String(describing: window.firstResponder), "actualKey", NSApp.keyWindow === window)
            }
            try expect(found, "native \(page.rawValue) menu exposes enabled \(title): \(titles)")
            try expect(actionFinished && trackingEnded, "native library menu finishes tracking before the next UI action")
        }
        func search(_ query: String) async throws {
            model.searchRequest = UUID()
            let placeholder = L(page == .library ? "搜索文档" : "搜索媒体")
            var field: NSTextField?
            // SwiftUI mounts the search field before its task and AppKit focus
            // transition finish. Re-query after each bounded wait because the
            // native field can be replaced during those updates, especially on CI.
            for _ in 0..<20 {
                await settle()
                field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == placeholder })
                guard let field, field.window === window,
                      let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else { continue }
                editor.selectAll(nil); editor.insertText(query, replacementRange: editor.selectedRange())
                await settle()
                try expect(field.stringValue == query, "native library search applies the requested text")
                return
            }
            try snapshot("search-failure")
            throw TestFailure.failed("native library search field owns the editor: page=\(page.rawValue), language=\(language.rawValue), scheme=\(scheme), field=\(String(describing: field)), editor=\(String(describing: field?.currentEditor())), responder=\(String(describing: window.firstResponder)), sheet=\(String(describing: window.attachedSheet))")
        }
        func snapshot(_ suffix: String, panel: NSWindow? = nil) throws {
            guard CommandLine.arguments.contains("--snapshots") else { return }
            let directory = URL(fileURLWithPath: "build/qa/library-selection")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target: NSView = panel?.contentView?.superview ?? panel?.contentView ?? view
            guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds), bitmap.pixelsWide > 0 else {
                throw TestFailure.failed("library selection snapshot")
            }
            target.cacheDisplay(in: target.bounds, to: bitmap)
            let name = "\(page == .library ? "documents" : "media")-\(language == .chinese ? "zh" : "en")-\(scheme == .light ? "light" : "dark")-\(suffix).png"
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        func alert(_ title: String, capture: String? = nil) async throws {
            await settle()
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw TestFailure.failed("native confirmation exposes \(title)")
            }
            if let capture { try snapshot(capture, panel: sheet) }
            button.performClick(nil)
            await settle()
        }
        func removedCount() -> Int { page == .library ? model.papers.filter(\.removed).count : model.mediaLibrary.filter(\.isLibraryRemoved).count }
        await settle()
        try expect(view.bounds.size == NSSize(width: 780, height: 540) && keyView()?.allowsMultipleSelection == true,
                   "both libraries retain the minimum layout and enable multi-selection")
        try await menu(L("移出当前结果 2 项…"))
        try await alert(L("取消"), capture: "remove-confirmation")
        try expect(removedCount() == 0 && recycled.isEmpty, "cancelling current-result removal preserves every library item")
        try await menu(L("移出当前结果 2 项…"))
        try await alert(L("移出"))
        try expect(removedCount() == 2 && model.downloads.count == 2 && recycled.isEmpty,
                   "the native removal confirmation commits the current results while preserving files and download history")
        try await menu(L(page == .library ? "已移除的文档" : "已移除的媒体"))
        model.listRequest = UUID(); await settle()
        try keys(49, " "); try keys(36, "\r")
        try expect(model.previewURL == nil && opened == 0, "removed document and media rows consistently offer recovery rather than keyboard opening")
        try await menu(L("恢复当前结果 2 项"))
        try await menu(L(page == .library ? "返回文档库" : "返回媒体库"))
        model.listRequest = UUID(); await settle()
        try keys(0, "a", .command); await settle()
        try await menu(L("移出所选 2 项"), perform: false)
        try await menu(L("移出所选 2 项"), perform: false)
        try await search("First")
        try await menu(L("移出所选 1 项"), perform: false)
        try await search("")
        model.listRequest = UUID(); await settle()
        try keys(0, "a", .command); await settle()
        try snapshot("selected")
        try await menu(L("移出所选 2 项"))
        try expect(removedCount() == 2 && model.downloads.count == 2 && recycled.isEmpty,
                   "native batch removal keeps both download records and every file")
        try snapshot("all-removed")
        try await menu(L(page == .library ? "已移除的文档" : "已移除的媒体"))
        try expect(keyView() != nil, "all removed records remain reachable from each library's header menu")
        try snapshot("removed-results")
        try await menu(L("恢复当前结果 2 项"))
        try expect(removedCount() == 0, "native batch restore returns every removed library record")
        try await menu(L(page == .library ? "返回文档库" : "返回媒体库"))
        model.listRequest = UUID(); await settle()
        try keys(0, "a", .command); await settle()
        try await menu(L("将所选文件移到废纸篓…"))
        try expect(model.pendingFileTrash?.files.count == 2 && recycled.isEmpty, "Trash is a separate pending file operation")
        try await alert(L("取消"), capture: "trash-confirmation")
        try expect(model.pendingFileTrash == nil && recycled.isEmpty && removedCount() == 0,
                   "cancelling native Trash keeps files and restored library records untouched")
        try expect(try files.map { try Data(contentsOf: $0) } == originalBytes,
                   "batch remove, restore and cancelled Trash preserve original file bytes")
        try snapshot("restored")
        try await menu(L("将所选文件移到废纸篓…"))
        try await alert(L("移到废纸篓"))
        try expect(Set(recycled) == Set(files) && files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                   "the native Trash confirmation invokes the recycler for every selected file")
        try expect(try files.map { try Data(contentsOf: folder.appendingPathComponent("trash-" + $0.lastPathComponent)) } == originalBytes,
                   "confirmed Trash moves only these fixtures and preserves their bytes")
        try expect(model.pendingFileTrash == nil && removedCount() == 0 && model.downloads.count == 2 && model.downloads.allSatisfy { $0.state == .missing },
                   "confirmed Trash keeps active library and download records with missing file status")
        try expect(page == .library ? model.papers.count == 2 && model.papers.allSatisfy(\.missing) :
                   model.mediaLibrary.count == 2 && model.mediaLibrary.allSatisfy { $0.state == .missing },
                   "document and media library entries both report the missing local files")
        try snapshot("trashed")
        let restored = DownloadModel(preferences: preferences, opener: { _ in true }, stateURL: folder.appendingPathComponent("workspace.json"))
        try expect(page == .library ? restored.papers.filter { !$0.removed }.count == 2 : restored.mediaLibrary.filter { !$0.isLibraryRemoved }.count == 2,
                   "separate file Trash does not remove library records after restart")
        try expect(restored.downloads.count == 2 && restored.downloads.allSatisfy { $0.state == .missing } &&
                   (page == .library ? restored.papers.allSatisfy(\.missing) : restored.mediaLibrary.allSatisfy { $0.state == .missing }),
                   "confirmed file status changes are durable across restart")
        print("PASS library UI fixture: \(page == .library ? "documents" : "media") \(language == .chinese ? "zh" : "en") \(scheme == .light ? "light" : "dark")")
    }
}
