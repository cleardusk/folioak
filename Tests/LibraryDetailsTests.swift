import AppKit
import SwiftUI

private final class DetailsPolishHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private final class DetailsPolishWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension CoreTests {
    @MainActor static func libraryDetailsPolishTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-polish-details-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let oldLanguage = AppLocalization.shared.language
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = oldLanguage }
        AppLocalization.shared.language = .chinese
        let model = DownloadModel(engine: DownloadEngine(transport: MockTransport(sourcePDF: pdf, latestVersion: 3), requestInterval: 0, retryDelay: 0), preferences: preferences)
        let ref = try ArxivReference.parse("1706.03762v1")
        let task = DownloadItem(original: ref.identifier, reference: ref, state: .saved, savedURL: pdf, documentTitle: "Original title",
            origin: DownloadOrigin(input: "https://arxiv.org/abs/1706.03762v1?context=original", capturedAt: Date()))
        var paper = LibraryPaper(task); paper.id = UUID(); paper.tags = ["original tag"]
        model.papers = [paper]; model.history = [task]
        model.logs = (0..<85).map { ActivityEntry(level: .info, message: "Entry \($0)", subject: "Original title", itemID: task.id) }
        var logRequest: DownloadItem?
        let details = TaskDiagnosticView(model: model, item: paper.downloadItem, libraryPaperID: paper.id, showTaskLogs: { logRequest = $0 }, showingDiagnostics: true)
        try expect(details.taskLogItem?.id == task.id, "details log route uses task ID, independently of library ID")
        let host = DetailsPolishHost(rootView: details.environment(\.colorScheme, .light))
        let window = DetailsPolishWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async { try? await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded() }
        func snapshot(_ suffix: String) throws {
            guard CommandLine.arguments.contains("--snapshots"), let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: "build/qa/library-polish")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("details-" + suffix + ".png"))
        }
        func actionLocation(_ identifier: String, scroll: NSScrollView) -> NSPoint? {
            let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host).intersection(host.bounds)
            guard let region = descendants(host).compactMap({ $0 as? DetailActionRegion.Region }).first(where: {
                $0.identifier?.rawValue == identifier && $0.enabled && $0.window === window && !$0.isHiddenOrHasHiddenAncestor
            }) else { return nil }
            let bounds = region.convert(region.bounds, to: host)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let visible = region.convert(region.bounds.intersection(region.visibleRect), to: host).intersection(clip)
            // Require a substantial part of the real control to be visible.
            // Never click an offscreen marker or the adjacent scroll gutter.
            guard !visible.isNull, visible.width >= min(16, bounds.width), visible.height >= min(20, bounds.height) else { return nil }
            return NSPoint(x: visible.midX, y: visible.midY)
        }
        func revealAction(_ identifier: String) async throws -> NSPoint {
            await settle()
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else { throw TestFailure.failed("details native scroll") }
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            for step in 0..<12 {
                await settle()
                // File metadata and editor transitions change the layout, so
                // reacquire native control geometry after every scroll/layout.
                if let point = actionLocation(identifier, scroll: scroll) { return point }
                let next = min(CGFloat(step + 1) * max(1, scroll.contentView.bounds.height * 0.7), max(0, document.bounds.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: next)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            let actions = descendants(host).compactMap { $0 as? DetailActionRegion.Region }.map {
                "\($0.identifier?.rawValue ?? "unnamed") enabled=\($0.enabled) bounds=\($0.convert($0.bounds, to: host)) visible=\($0.convert($0.visibleRect, to: host))"
            }
            try snapshot("missing-action-" + identifier)
            throw TestFailure.failed("rendered details action is reachable: \(identifier); clip=\(scroll.contentView.convert(scroll.contentView.bounds, to: host)); actions=\(actions)")
        }
        func press(_ identifier: String) async throws {
            let point = try await revealAction(identifier)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            await settle()
        }
        func descendants(_ item: NSView) -> [NSView] { [item] + item.subviews.flatMap(descendants) }
        func edit(_ placeholder: String, _ value: String) throws {
            guard let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == placeholder }) else {
                throw TestFailure.failed("editable details field: " + placeholder)
            }
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else { throw TestFailure.failed("details text editor") }
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        await settle()
        try snapshot("initial")
        try await press("details-edit-metadata")
        try edit("显示标题", "Cancelled title")
        try await press("details-cancel-edit")
        try expect(model.papers[0].title == "Original title", "Cancel keeps the existing display title")
        try await press("details-edit-metadata")
        try edit("显示标题", "Edited title")
        try edit("用逗号分隔", "design, 文档, design")
        try snapshot("editing")
        try await press("details-save-edit")
        try snapshot("after-save")
        print("DETAILS SAVED", model.papers[0].title, model.papers[0].tags,
            "file preserved:", model.papers[0].file == pdf, "source preserved:", model.papers[0].origin == task.origin)
        try expect(model.papers[0].title == "Edited title" && model.papers[0].tags == ["design", "文档"] && model.papers[0].file == pdf && model.papers[0].origin == task.origin,
            "details saves title/tags while preserving file and original source")
        try await press("details-check-version")
        for _ in 0..<50 { if model.checkingVersions.isEmpty { break }; await settle() }
        try expect(model.papers[0].latest?.version == 3 && model.papers[0].checkedAt != nil, "paper checks and timestamp remain reachable from details")
        _ = try await revealAction("details-download-version")
        try snapshot("saved")
        try await press("details-show-task-logs")
        try expect(logRequest?.id == task.id && model.logs.filter { $0.itemID == logRequest?.id }.count == 85,
            "full task log route includes entries beyond the detail preview's 80-row limit")
        try snapshot("logs")
        print("PASS details polish: real title/tag edit and Cancel/Save, paper version check, original source, and complete task log routing")
    }
}
