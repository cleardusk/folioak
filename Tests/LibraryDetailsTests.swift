import AppKit
import SwiftUI
import Vision

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
        func textLocation(_ title: String) throws -> NSPoint? {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first else { continue }
                // Match the complete visible label: the status "已保存" is not
                // the editor's "保存" button.
                let normalized = { (value: String) in value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "…", with: "") }
                guard normalized(text.string) == normalized(title) else { continue }
                for needle in [title.replacingOccurrences(of: "…", with: ""), title.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "…", with: "")] {
                    guard let range = text.string.range(of: needle) else { continue }
                    let box = try text.boundingBox(for: range)?.boundingBox ?? observation.boundingBox
                    return NSPoint(x: box.midX * host.bounds.width,
                        y: (host.isFlipped ? 1 - box.midY : box.midY) * host.bounds.height)
                }
            }
            return nil
        }
        func press(_ title: String) async throws {
            await settle()
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else { throw TestFailure.failed("details native scroll") }
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            for step in 0..<12 {
                await settle()
                if let point = try textLocation(title) {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                        try await Task.sleep(nanoseconds: 15_000_000)
                    }
                    await settle()
                    return
                }
                let next = min(CGFloat(step + 1) * 300, max(0, document.bounds.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: next)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            try snapshot("missing-action")
            throw TestFailure.failed("rendered details action is reachable: " + title)
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
        try await press("编辑文档信息…")
        try edit("显示标题", "Cancelled title")
        try await press("取消")
        try expect(model.papers[0].title == "Original title", "Cancel keeps the existing display title")
        try await press("编辑文档信息…")
        try edit("显示标题", "Edited title")
        try edit("用逗号分隔", "design, 文档, design")
        try snapshot("editing")
        try await press("保存")
        try snapshot("after-save")
        print("DETAILS SAVED", model.papers[0].title, model.papers[0].tags,
            "file preserved:", model.papers[0].file == pdf, "source preserved:", model.papers[0].origin == task.origin)
        try expect(model.papers[0].title == "Edited title" && model.papers[0].tags == ["design", "文档"] && model.papers[0].file == pdf && model.papers[0].origin == task.origin,
            "details saves title/tags while preserving file and original source")
        try await press("检查论文更新")
        for _ in 0..<50 { if model.checkingVersions.isEmpty { break }; await settle() }
        try expect(model.papers[0].latest?.version == 3 && model.papers[0].checkedAt != nil, "paper checks and timestamp remain reachable from details")
        try expect(try textLocation("下载 v3") != nil, "new paper version exposes download action")
        try snapshot("saved")
        try await press("查看任务日志")
        try expect(logRequest?.id == task.id && model.logs.filter { $0.itemID == logRequest?.id }.count == 85,
            "full task log route includes entries beyond the detail preview's 80-row limit")
        try snapshot("logs")
        print("PASS details polish: real title/tag edit and Cancel/Save, paper version check, original source, and complete task log routing")
    }
}
