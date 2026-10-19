import Foundation
import AppKit
import SwiftUI
import Combine

private actor QuickTransport: HTTPTransport {
    let pdf: URL
    private var blocked = Set<String>()
    private(set) var paths: [String] = []
    init(pdf: URL) { self.pdf = pdf }
    func block(_ path: String) { blocked.insert(path) }
    func release(_ path: String) { blocked.remove(path) }
    func waitFor(_ path: String) async throws {
        paths.append(path)
        while blocked.contains(path) { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        let path = request.url!.path
        paths.append(path)
        while blocked.contains(path) { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.copyItem(at: pdf, to: temporary)
        return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/pdf"])!)
    }
}

private final class QuickTestHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class QuickTestWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private var dispatchedMouseEvents: [Int: TimeInterval] = [:]
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            dispatchedMouseEvents[event.eventNumber] = event.timestamp
        }
    }
    func dispatchQueuedMouseEvent(_ event: NSEvent) async throws {
        NSApp.postEvent(event, atStart: false)
        // Native gesture resets happen at AppKit event boundaries. Fetch each
        // queued event instead of injecting directly into an active callback.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let queued = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
                // AppKit's CGEvent bridge can round timestamp fractions below a
                // nanosecond; identity still requires type, window and event number.
                if queued.type == event.type && queued.windowNumber == event.windowNumber &&
                   queued.eventNumber == event.eventNumber && abs(queued.timestamp - event.timestamp) < 0.000001 {
                    try expect(dispatchedMouseEvents[event.eventNumber] == queued.timestamp, "queued mouse event completes native dispatch")
                    // Enter AppKit's next-event boundary after dispatch, including
                    // when this is the last event before an async assertion wait.
                    // Peeking leaves any unrelated queued input untouched.
                    _ = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(), inMode: .default, dequeue: false)
                    return
                }
                // Other windows' queued events are dispatched once, never discarded.
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        throw TestFailure.failed("queued mouse event was not dispatched by AppKit")
    }
}

extension CoreTests {
    @MainActor static func quickDownloadTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-quick-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "folioak-quick-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let pdf = root.appendingPathComponent("sample.pdf")
        try createPDF(at: pdf)
        let gate = QuickTransport(pdf: pdf)
        await gate.block("/first.pdf"); await gate.block("/second.pdf"); await gate.block("/third.pdf")
        let engine = DownloadEngine(transport: gate, pdfTransport: gate, requestInterval: 0, retryDelay: 0)
        let url = root.appendingPathComponent("state/workspace.json")
        let model = DownloadModel(engine: engine, preferences: preferences, stateURL: url)
        model.directory = root.appendingPathComponent("downloads")
        let draft = "  https://example.com/first.pdf\n\n未提交的草稿，保留空白  "
        model.input = draft
        let pageRequest = model.batchID, editRequest = model.editRequest
        let state = QuickDownloadState(model: model)
        state.draft = "https://example.com/first.pdf"
        state.submit()
        try expect(!state.failed && state.draft.isEmpty && model.busy, "quick submission starts without needing a main window")
        try expect(model.input == draft && model.batchID == pageRequest && model.editRequest == editRequest,
            "quick submit preserves main draft, page and focus")
        try expect(try WorkspaceStore.read(url)?.items.count == 1, "accepted task is durable before the worker begins")
        for _ in 0..<400 {
            if await gate.paths.count == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.draft = "https://example.com/second.pdf"
        state.submit()
        try expect(!state.failed && model.items.count == 2 && model.items[1].state == .queued, "busy worker accepts a second batch without interrupting the first")
        try expect(await gate.paths == ["/first.pdf"], "appended batch waits behind the active batch")
        let restored = DownloadModel(preferences: preferences, stateURL: url)
        try expect(restored.items.count == 2 && restored.items.allSatisfy { $0.state == .cancelled && $0.canRetry && $0.preservesInput == true },
            "restart retains both active and appended tasks for explicit recovery without auto-downloading")
        state.draft = "https://example.com/second.pdf"
        state.submit()
        try expect(state.failed && !state.draft.isEmpty && model.items.count == 2, "duplicate active source is rejected with draft retained")
        state.draft = "https://example.com/new.pdf\ninvalid-link"
        state.submit()
        try expect(state.failed && model.items.count == 2, "mixed invalid quick input is rejected atomically")
        let tooMany = (0..<200).map { "https://example.com/capacity-\($0).pdf" }.joined(separator: "\n")
        try rejects({ _ = try model.submitQuickDownload(tooMany) }, "aggregate queue capacity is enforced")
        try expect(model.items.count == 2, "rejected capacity does not replace running tasks")
        await gate.release("/first.pdf")
        for _ in 0..<400 {
            if await gate.paths.count == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(await gate.paths == ["/first.pdf", "/second.pdf"], "worker drains the appended batch automatically")
        try expect(model.input == draft, "completed quick task leaves even identical main draft links and whitespace unchanged")
        _ = try model.submitQuickDownload("https://example.com/third.pdf")
        _ = try model.submitQuickDownload("https://example.com/fourth.pdf")
        await model.cancelAndWait()
        let pathsAfterStop = await gate.paths
        try expect(!model.busy && !model.cancelling && pathsAfterStop == ["/first.pdf", "/second.pdf"],
            "stop cancels active task and never begins appended tasks")
        try expect(model.downloads.filter { $0.state == .cancelled }.count == 3 && model.input == draft,
            "cancelled queued tasks remain visible, retryable and preserve drafts")
        try expect(model.logs.last(where: { $0.diagnostic?.id == DiagnosticMessage.ID.finished.rawValue })?.diagnostic?.arguments == ["1", "0"],
            "completion counts include the first success retired from items during append")
        let afterStop = DownloadModel(preferences: preferences, stateURL: url)
        try expect(afterStop.downloads.count == 4 && afterStop.input == draft, "stop flush preserves all records across restart")
        await gate.release("/second.pdf"); await gate.release("/third.pdf")
        model.retry()
        for _ in 0..<600 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(!model.busy && model.downloads.allSatisfy { $0.state == .saved || $0.state == .existing }, "explicit retry resumes cancelled queue")
        try expect(model.logs.last(where: { $0.diagnostic?.id == DiagnosticMessage.ID.finished.rawValue })?.diagnostic?.arguments == ["3", "0"], "completion count covers every task in the retried run")
        try expect(model.input == draft && model.papers.count == 4, "all quick completions preserve draft and populate the document library")

        // Schedule the append from the final state publication. The worker
        // next yields in its async flush; the earlier main-queue callback then
        // exercises append + stop inside that completion window.
        let flushGate = QuickTransport(pdf: pdf)
        let flushModel = DownloadModel(engine: DownloadEngine(transport: flushGate, pdfTransport: flushGate, requestInterval: 0),
            preferences: preferences, stateURL: root.appendingPathComponent("flush/workspace.json"))
        flushModel.directory = root.appendingPathComponent("flush-downloads")
        var scheduled = false, appendedAtFlush = false
        var submissionError: Error?
        let observation = flushModel.$items.sink { published in
            if !scheduled && published.contains(where: { $0.state == .saved || $0.state == .existing }) {
                scheduled = true
                DispatchQueue.main.async {
                    do {
                        appendedAtFlush = flushModel.busy
                        _ = try flushModel.submitQuickDownload("https://example.com/flush-b.pdf")
                        flushModel.cancel()
                    } catch { submissionError = error }
                }
            }
        }
        _ = try flushModel.submitQuickDownload("https://example.com/flush-a.pdf")
        for _ in 0..<600 {
            if scheduled && !flushModel.busy { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        withExtendedLifetime(observation) {}
        try expect(appendedAtFlush && submissionError == nil && !flushModel.busy, "append and stop execute during final flush")
        let flushCalls = await flushGate.paths.count
        try expect(flushModel.items.last?.state == .cancelled && flushCalls == 1,
            "stop in the final flush cancels appended task without requesting it")
        let flushSaved = try WorkspaceStore.read(root.appendingPathComponent("flush/workspace.json"))
        try expect(flushSaved?.items.last?.state == .cancelled && flushSaved?.logs.map(\.id) == flushModel.logs.map(\.id),
            "final-flush cancellation and completion log are durable before idle")

        let cooldownGate = QuickTransport(pdf: pdf)
        await cooldownGate.block("media")
        let cooldownEngine = DownloadEngine(mediaDownload: { _, _, _, _, _, _, _ in
            try await cooldownGate.waitFor("media")
            throw DownloadError.cooldown(60)
        })
        let cooldownModel = DownloadModel(engine: cooldownEngine, preferences: preferences)
        cooldownModel.directory = root.appendingPathComponent("cooldown")
        _ = try cooldownModel.submitQuickDownload("https://www.youtube.com/watch?v=aaaaaaaaaaa")
        for _ in 0..<400 {
            if await cooldownGate.paths.count == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = try cooldownModel.submitQuickDownload("https://www.youtube.com/watch?v=bbbbbbbbbbb")
        await cooldownGate.release("media")
        for _ in 0..<400 {
            if !cooldownModel.busy { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let cooldownCalls = await cooldownGate.paths.count
        try expect(!cooldownModel.busy && cooldownModel.items.allSatisfy { $0.state == .paused } && cooldownCalls == 1,
            "appended batches honor source cooldown without retrying the throttled site")
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let blocked = DownloadModel(engine: engine, preferences: preferences, stateURL: blocker.appendingPathComponent("workspace.json"))
        let failedState = QuickDownloadState(model: blocked)
        failedState.draft = "https://example.com/never.pdf"
        failedState.submit()
        try expect(failedState.failed && !failedState.draft.isEmpty && blocked.items.isEmpty && !blocked.busy,
            "failed durable acceptance preserves draft and never launches a download")
        try expect(!(await gate.paths).contains("/never.pdf"), "failed persistence produces no network request")
        print("PASS quick download: durable busy append, duplicates, invalid input, capacity, automatic drain, cancellation, restart/retry, independent drafts and failed commits")
    }

    @MainActor static func quickFileInteractionCancellationTests() throws {
        let window = QuickTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let region = QuickDownloadFileInteraction.Region(frame: container.bounds)
        var opened = 0
        region.isActive = true; region.open = { opened += 1 }
        container.addSubview(region); window.contentView = container; window.orderFront(nil)
        defer { window.close() }
        func event(_ type: NSEvent.EventType, inside: Bool = true, flags: NSEvent.ModifierFlags = [], count: Int = 2) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: inside ? NSPoint(x: 50, y: 50) : NSPoint(x: 250, y: 50),
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        for boundary in ["drag", "outside", "inactive", "hidden window", "detached", "modifier"] {
            region.mouseDown(with: event(.leftMouseDown))
            switch boundary {
            case "drag": region.mouseDragged(with: event(.leftMouseDragged))
            case "inactive": region.isActive = false
            case "hidden window": window.orderOut(nil)
            case "detached": region.removeFromSuperview()
            default: break
            }
            region.mouseUp(with: event(.leftMouseUp, inside: boundary != "outside", flags: boundary == "modifier" ? .command : []))
            try expect(opened == 0, "quick file double click cancels after \(boundary)")
            region.isActive = true
            if region.superview == nil { container.addSubview(region) }
            window.orderFront(nil)
            region.mouseUp(with: event(.leftMouseUp))
            try expect(opened == 0, "cancelled quick file click cannot reopen after restoring \(boundary)")
        }
        region.mouseDown(with: event(.leftMouseDown)); region.mouseUp(with: event(.leftMouseUp))
        region.mouseUp(with: event(.leftMouseUp))
        try expect(opened == 1, "valid quick file click opens once and consumes its armed state")
        print("PASS quick file cancellation: drag, bounds, inactive, hidden window, detach, modifiers and duplicate release")
    }

    @MainActor static func quickDownloadUITests() async throws {
        _ = NSApplication.shared
        try quickFileInteractionCancellationTests()
        let originalLanguage = AppLocalization.shared.language, originalAppearance = NSApp.appearance
        defer { AppLocalization.shared.language = originalLanguage; NSApp.appearance = originalAppearance }
        let root = URL(fileURLWithPath: "build/qa/quick-download", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "folioak-quick-ui-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var openedFiles: [URL] = [], revealedFiles: [[URL]] = []
        let model = DownloadModel(preferences: preferences,
            opener: { openedFiles.append($0); return true }, revealer: { revealedFiles.append($0) })
        model.directory = URL(fileURLWithPath: "/Users/Fixture/Downloads/A deliberately long saved folder for papers and media/Folioak")
        let state = QuickDownloadState(model: model)
        for language in [AppLanguage.chinese, .english] {
            AppLocalization.shared.language = language
            for scheme in [ColorScheme.light, .dark] {
                NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                var closes = 0
                let host = QuickTestHost(rootView: QuickDownloadView(state: state, model: model,
                    openWindow: {}, openSettings: {}, quit: {}, close: { closes += 1 }).environment(\.colorScheme, scheme))
                let size = host.fittingSize
                let window = QuickTestWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
                window.contentView = host; window.makeKeyAndOrderFront(nil)
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                var mountedEditor: QuickLinkEditor.Editor?
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 25_000_000)
                    host.layoutSubtreeIfNeeded()
                    if NSApp.keyWindow === window,
                       let mounted = descendants(host).compactMap({ $0 as? QuickLinkEditor.Editor }).first,
                       mounted.window === window {
                        mountedEditor = mounted
                        break
                    }
                }
                try expect(mountedEditor != nil, "quick editor mounts in the real key window: language=\(language.rawValue), scheme=\(scheme), realKey=\(NSApp.keyWindow === window), visible=\(window.isVisible), policy=\(NSApp.activationPolicy().rawValue), editorCount=\(descendants(host).compactMap { $0 as? QuickLinkEditor.Editor }.count)")
                // Match the focus request after popover.show and native attachment.
                state.focusRequest = UUID()
                var focusedEditor: QuickLinkEditor.Editor?
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 25_000_000)
                    host.layoutSubtreeIfNeeded()
                    if NSApp.keyWindow === window,
                       let mounted = descendants(host).compactMap({ $0 as? QuickLinkEditor.Editor }).first,
                       window.firstResponder === mounted {
                        focusedEditor = mounted
                        break
                    }
                }
                guard let editor = focusedEditor else {
                    throw TestFailure.failed("quick editor receives focus: language=\(language.rawValue), scheme=\(scheme), realKey=\(NSApp.keyWindow === window), responder=\(String(describing: window.firstResponder))")
                }
                editor.insertText("invalid-link", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                try expect(editor.undoManager?.canUndo == true, "native typing creates a real undo action before submission")
                try await Task.sleep(nanoseconds: 30_000_000)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                try expect(window.performKeyEquivalent(with: event), "window responder chain consumes Command Return before the main menu")
                try expect(state.failed && state.draft == "invalid-link", "Command Return invokes panel submission and retains invalid input")
                state.draft = ""
                try await Task.sleep(nanoseconds: 30_000_000)
                try expect(!editor.undoManager!.canUndo, "external clear discards stale native text undo actions")
                state.submit()
                try await Task.sleep(nanoseconds: 30_000_000)
                host.layoutSubtreeIfNeeded()
                let target = root.appendingPathComponent("\(language.rawValue)-\(scheme == .light ? "light" : "dark").png")
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: target)
                }
                try expect(host.bounds.width == 380 && host.fittingSize.height < 430, "panel has bounded readable dimensions with long path and error")
                model.busy = true
                model.items = [DownloadItem(original: "https://example.com/queued.pdf", directURL: URL(string: "https://example.com/queued.pdf"), state: .queued, preservesInput: true)]
                state.draft = "https://example.com/new.pdf"
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("\(language.rawValue)-\(scheme == .light ? "light" : "dark")-busy.png"))
                }
                guard let pendingResult = descendants(host).compactMap({ $0 as? QuickDownloadFileInteraction.Region }).first else {
                    throw TestFailure.failed("queued quick result is visible before completion")
                }
                try expect(!pendingResult.isActive, "queued result without a local file has no open interaction")
                model.busy = false
                let resultFile = root.appendingPathComponent("A long downloaded filename for menu bar verification.pdf")
                try createPDF(at: resultFile)
                var completedResult = model.items[0]
                completedResult.state = .saved; completedResult.savedURL = resultFile
                completedResult.documentTitle = "Downloaded document"
                model.items = [completedResult]
                state.draft = ""
                try await Task.sleep(nanoseconds: 50_000_000)
                window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                try expect(state.status == model.items[0].state.label && state.recentItems.count == 1, "completed download replaces idle with a findable result")
                try expect(descendants(host).compactMap { $0 as? QuickLinkEditor.Editor }.first === editor, "result insertion preserves native editor/undo identity")
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("\(language.rawValue)-\(scheme == .light ? "light" : "dark")-completed.png"))
                }
                guard let result = descendants(host).compactMap({ $0 as? QuickDownloadFileInteraction.Region }).first else {
                    throw TestFailure.failed("quick result native double-click region")
                }
                try expect(result === pendingResult && result.isActive, "download completion enables the existing row without remounting")
                var clickTrace: [String] = []
                result.clickTrace = { clickTrace.append($0) }
                let resultRect = result.convert(result.bounds, to: host)
                var resultEventNumber = 0
                var resultEventTimes: [TimeInterval] = []
                func resultClick(_ point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) async throws {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        resultEventNumber += 1
                        let timestamp = ProcessInfo.processInfo.systemUptime
                        resultEventTimes.append(timestamp)
                        let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: flags,
                            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                            eventNumber: resultEventNumber, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
                        try await window.dispatchQueuedMouseEvent(event)
                        try await Task.sleep(nanoseconds: 15_000_000)
                    }
                }
                let titlePoint = NSPoint(x: resultRect.midX, y: resultRect.minY + resultRect.height * 0.25)
                let pathPoint = NSPoint(x: resultRect.midX, y: resultRect.minY + resultRect.height * 0.75)
                let openCount = openedFiles.count
                try await resultClick(titlePoint)
                try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.05) * 1e9))
                try expect(openedFiles.count == openCount, "quick result single click never opens a file")
                for (index, point) in [titlePoint, pathPoint].enumerated() {
                    // These are separate double clicks, each restarting at count 1.
                    // End the previous multi-click sequence before starting another.
                    if index > 0 { try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.05) * 1e9)) }
                    resultEventTimes.removeAll(); clickTrace.removeAll()
                    try await resultClick(point); try await resultClick(point, count: 2)
                    let offsets = resultEventTimes.map { $0 - resultEventTimes[0] }
                    let downInterval = resultEventTimes[2] - resultEventTimes[0]
                    print("QUICK RESULT TIMING", language.rawValue, scheme, index,
                        "offsets", offsets, "downInterval", downInterval, "limit", NSEvent.doubleClickInterval)
                    try expect(downInterval < NSEvent.doubleClickInterval,
                        "quick result injected double click stays within the system double-click interval")
                    let expected = openCount + index + 1
                    // Wait for this native gesture, then allow any duplicate
                    // callbacks to settle before checking the exact open count.
                    for _ in 0..<20 {
                        if openedFiles.count >= expected { break }
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                    if openedFiles.count != expected || openedFiles.last != resultFile {
                        let recognizers = host.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
                        print("QUICK RESULT DOUBLE CLICK", language.rawValue, scheme, index,
                            "expected", expected, "actual", openedFiles.count, "last", String(describing: openedFiles.last),
                            "recognizers", recognizers.map { "\($0.numberOfClicksRequired):\($0.state.rawValue):\($0.isEnabled)" },
                            "region", result.bounds, result.visibleRect, "key", NSApp.keyWindow === window,
                            "point", point, "hit", String(describing: host.hitTest(host.convert(point, to: host.superview))), "trace", clickTrace)
                    }
                    try expect(openedFiles.count == expected && openedFiles.last == resultFile,
                        "quick result \(index == 0 ? "title" : "path") double click opens the saved file exactly once")
                }
                try await resultClick(titlePoint, flags: .command); try await resultClick(titlePoint, count: 2, flags: .command)
                try expect(openedFiles.count == openCount + 2, "modified quick result clicks do not open files")
                result.clickTrace = nil
                let revealCount = revealedFiles.count
                let finderPoint = NSPoint(x: resultRect.maxX + 8 + 16, y: resultRect.midY)
                try await resultClick(finderPoint)
                try expect(revealedFiles.count == revealCount + 1 && revealedFiles.last == [resultFile],
                    "quick result Finder button still reveals the exact file")
                try await resultClick(finderPoint); try await resultClick(finderPoint, count: 2)
                try expect(openedFiles.count == openCount + 2, "Finder double clicks never trigger the file-open region")
                model.items = []
                try await Task.sleep(nanoseconds: 50_000_000)
                try expect(result.window == nil || !result.isActive, "removed quick results detach their native click surface")
                state.draft = ""
                editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
                try expect(closes == 1, "Escape closes quick entry through its native responder")
                window.close()
            }
        }
        try await fileRowDoubleClickTests()
        try await removalAnimationUITests()
        try inputRecognitionTests()
        try WorkspacePreferencesTests.brandParticleFade()
        try await pageSwitchUITests()
        try await windowDragRegionTests()
        try await brandEasterEggTests()
        let controller = MenuBarController(model: model, openWindow: {}, openSettings: {}, quit: {})
        try await Task.sleep(nanoseconds: 150_000_000)
        // Check the whole pointer sequence, including the mouse-up frame that
        // performClick + a delayed final-state assertion used to miss.
        guard let statusButton = controller.item?.button, let statusWindow = statusButton.window else { throw TestFailure.failed("status mouse target") }
        func statusEvent(_ type: NSEvent.EventType, inside: Bool = true, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let point = inside ? NSPoint(x: statusButton.bounds.midX, y: statusButton.bounds.midY) : NSPoint(x: -50, y: -50)
            return NSEvent.mouseEvent(with: type, location: statusButton.convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: statusWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        for _ in 0..<3 {
            try expect(controller.handleStatusMouseEvent(statusEvent(.leftMouseDown)) == nil, "status pointer down is consumed before native tracking")
            try expect(controller.popover.isShown && statusButton.isHighlighted, "pointer down opens with immediate native highlight")
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 4_000_000)
                try expect(statusButton.isHighlighted, "held status press never loses highlight")
            }
            try expect(controller.handleStatusMouseEvent(statusEvent(.leftMouseUp)) == nil && statusButton.isHighlighted,
                "mouse-up frame keeps the open popover highlighted without deferred repair")
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 4_000_000)
                try expect(controller.popover.isShown && statusButton.isHighlighted, "post-release frames stay highlighted")
            }
            let closeDown = statusEvent(.leftMouseDown)
            _ = controller.handleStatusMouseEvent(closeDown)
            try expect(!controller.popover.isShown && !statusButton.isHighlighted, "second pointer down closes once")
            _ = controller.handleStatusMouseEvent(closeDown)
            try expect(!controller.popover.isShown && !statusButton.isHighlighted, "replayed down cannot reopen the just-closed popover")
            _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseUp))
        }
        let commandDrag = statusEvent(.leftMouseDown, flags: .command)
        try expect(controller.handleStatusMouseEvent(commandDrag) === commandDrag, "Command-drag stays with native status-item rearrangement")
        let commandRelease = statusEvent(.leftMouseUp)
        try expect(controller.handleStatusMouseEvent(commandRelease) === commandRelease, "native Command-drag release passes through even after releasing Command")
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseDown))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        let otherRelease = statusEvent(.leftMouseUp, inside: false)
        try expect(controller.handleStatusMouseEvent(otherRelease) === otherRelease, "deactivation cannot leave a press that consumes another control's release")
        controller.popover.close()
        let unrelated = statusEvent(.leftMouseDown, inside: false)
        try expect(controller.handleStatusMouseEvent(unrelated) === unrelated, "events outside status button pass through unchanged")
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseDown))
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseUp, inside: false))
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseDown))
        try expect(!controller.popover.isShown, "release outside clears the press so the next click works")
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseUp))
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseDown))
        _ = controller.handleStatusMouseEvent(statusEvent(.leftMouseUp))
        var rightMenuHighlighted = false, rightMenuStarted = false, rightMenuSampled = false
        var rightTimer: Timer?
        let rightMenu = controller.actionMenu
        let rightObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: rightMenu, queue: nil) { _ in
            MainActor.assumeIsolated {
                rightMenuStarted = true
                let timer = Timer(timeInterval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        rightMenuSampled = true
                        rightMenuHighlighted = statusButton.isHighlighted && !controller.popover.isShown
                        let release = statusEvent(.rightMouseUp, inside: false)
                        rightMenuHighlighted = rightMenuHighlighted && controller.handleStatusMouseEvent(release) === release
                        if !rightMenuHighlighted {
                            print("RIGHT MENU SAMPLE", statusButton.state.rawValue, statusButton.isHighlighted, controller.popover.isShown)
                        }
                        rightMenu.cancelTrackingWithoutAnimation()
                    }
                }
                rightTimer = timer
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        _ = controller.handleStatusMouseEvent(statusEvent(.rightMouseDown))
        try expect(!controller.popover.isShown && statusButton.isHighlighted,
            "right-click closes the transient popover before queuing menu activation without dropping highlight")
        for _ in 0..<20 {
            if rightMenuSampled && controller.item?.menu == nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        rightTimer?.invalidate()
        NotificationCenter.default.removeObserver(rightObserver)
        _ = controller.handleStatusMouseEvent(statusEvent(.rightMouseUp))
        try expect(rightMenuStarted && rightMenuSampled, "right-menu handoff is sampled during native tracking")
        try expect(rightMenuHighlighted && !statusButton.isHighlighted, "popover-to-right-menu handoff keeps native highlight until the menu closes")
        var cancelledRequestOpened = false
        let cancelTimer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                cancelledRequestOpened = true
                controller.actionMenu.cancelTracking()
            }
        }
        RunLoop.main.add(cancelTimer, forMode: .eventTracking)
        _ = controller.handleStatusMouseEvent(statusEvent(.rightMouseDown))
        model.showsMenuBarIcon = false
        model.showsMenuBarIcon = true
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelTimer.invalidate()
        try expect(!cancelledRequestOpened && controller.item?.button?.isHighlighted == false,
            "queued right-menu request cannot outlive a hidden/recreated status item")
        print("PASS status pointer: held/released frames, repeated clicks, replayed events, outside release and right-menu handoff")
        controller.state.draft = "keep popover draft"
        let statusQA = URL(fileURLWithPath: "build/qa/menu-highlight")
        try FileManager.default.createDirectory(at: statusQA, withIntermediateDirectories: true)
        func captureStatus(_ name: String) throws {
            guard let button = controller.item?.button else { throw TestFailure.failed("status button exists") }
            button.needsDisplay = true; button.displayIfNeeded()
            guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { throw TestFailure.failed("status button snapshot") }
            button.cacheDisplay(in: button.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: statusQA.appendingPathComponent(name + ".png"))
        }
        try captureStatus("closed")
        // A visible workspace behind another app must stay there when only
        // the menu-bar utility is requested. Keep a real ordinary window open.
        let originalActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(originalActivationPolicy) }
        let backgroundWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        backgroundWindow.isReleasedWhenClosed = false
        backgroundWindow.title = "Folioak focus regression"
        backgroundWindow.orderFront(nil)
        defer { backgroundWindow.close() }
        NSApp.deactivate()
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(!NSApp.isActive, "menu focus regression starts with Folioak inactive")
        let previousApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.item?.button?.performClick(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        if !controller.popover.isShown || !(controller.popover.contentViewController?.view.window?.firstResponder is QuickLinkEditor.Editor) {
            print("POPOVER DIAGNOSTIC", controller.popover.isShown, String(describing: controller.item?.button?.window),
                String(describing: controller.item?.button?.bounds), String(describing: controller.popover.contentViewController?.view.window),
                String(describing: controller.popover.contentViewController?.view.window?.firstResponder))
        }
        try expect(controller.popover.isShown && controller.popover.contentViewController?.view.window?.firstResponder is QuickLinkEditor.Editor,
            "real menu bar popover opens with native input focus")
        try expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication,
            "opening quick entry does not activate Folioak or replace the foreground app")
        try expect(backgroundWindow.isVisible && !backgroundWindow.isKeyWindow,
            "quick entry keeps the workspace open without making it key")
        try expect(controller.item?.button?.state == .on, "status button stays selected while its popover is open")
        try expect(controller.item?.button?.isHighlighted == true, "native mouse tracking keeps the status background highlighted after release")
        try captureStatus("open")
        let popoverFile = root.appendingPathComponent("Finder hit target #1.pdf")
        try createPDF(at: popoverFile)
        model.items = [DownloadItem(original: "https://example.com/result.pdf", state: .saved, savedURL: popoverFile, preservesInput: true)]
        let openedBeforeFinderClicks = openedFiles.count
        try await quickDownloadPopoverResultTests(controller: controller, file: popoverFile, revealedFiles: { revealedFiles })
        try expect(openedFiles.count == openedBeforeFinderClicks, "Finder button center and padding never open the file itself")
        model.items = []
        let originalMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = originalMenu }
        let delegate = AppDelegate(model: model, menuBar: controller)
        let mainEdit = model.editRequest, mainPage = model.batchID
        for shortcut in [AppShortcut(key: "l"), AppShortcut(key: "k", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)] {
            _ = model.shortcuts.set(shortcut, for: .input)
            delegate.makeMenu()
            let oldFocus = controller.state.focusRequest
            model.busy = true
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.flags, timestamp: 0,
                windowNumber: controller.popover.contentViewController!.view.window!.windowNumber, context: nil,
                characters: shortcut.key, charactersIgnoringModifiers: shortcut.key, isARepeat: false, keyCode: shortcut.key == "l" ? 37 : 40)!
            try expect(NSApp.mainMenu!.performKeyEquivalent(with: event), "actual input menu shortcut is consumed while popup is key")
            try await Task.sleep(nanoseconds: 20_000_000)
            try expect(controller.state.focusRequest != oldFocus && model.editRequest == mainEdit && model.batchID == mainPage &&
                controller.popover.contentViewController?.view.window?.firstResponder is QuickLinkEditor.Editor,
                "default/custom input shortcuts focus popup even during downloads without touching main-window focus/page")
        }
        model.busy = false; model.shortcuts.reset()
        try expect(!controller.popover.animates, "quick panel has no system fade delay on rapid toggles")
        let initialSize = controller.popover.contentSize
        controller.state.submit()
        try await Task.sleep(nanoseconds: 100_000_000)
        if let content = controller.popover.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            try expect(controller.popover.contentSize.width == 380 && controller.popover.contentSize.height + 1 >= content.fittingSize.height,
                "real popover expands to fit multiline error feedback")
            try expect(controller.popover.contentSize.height >= initialSize.height, "error feedback does not shrink the panel")
        }
        controller.togglePopover()
        for _ in 0..<20 {
            if !controller.popover.isShown { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try expect(!controller.popover.isShown && controller.state.draft == "keep popover draft", "popover dismissal retains unsubmitted draft")
        try expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication,
            "closing quick entry leaves the foreground app unchanged")
        try expect(controller.item?.button?.state == .off && controller.item?.button?.isHighlighted == false, "toggle close clears status selection")
        try captureStatus("closed-again")
        for dismiss in 0..<3 {
            controller.togglePopover()
            try await Task.sleep(nanoseconds: 40_000_000)
            try expect(controller.item?.button?.state == .on, "every reopen selects status button")
            if dismiss == 0 { controller.popover.performClose(nil) }
            else if dismiss == 1, let editor = controller.popover.contentViewController?.view.window?.firstResponder as? QuickLinkEditor.Editor {
                editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: editor.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
            } else if dismiss == 2 { controller.actionMenu.performActionForItem(at: 0) }
            try await Task.sleep(nanoseconds: 20_000_000)
            try expect(!controller.popover.isShown && controller.item?.button?.state == .off, "external/Escape/open-window dismissal clears status selection")
        }
        var menuSelected = false, menuSampled = false, menuStarted = false, menuEnded = false
        var menuStates: [String] = []
        var trackingSample: Timer?
        let menu = controller.actionMenu
        let beginTracking = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil) { _ in
            MainActor.assumeIsolated {
                menuStarted = true
                menuStates.append("begin state=\(controller.item?.button?.state.rawValue ?? -1) highlighted=\(controller.item?.button?.isHighlighted ?? false)")
                // Sample after the real tracking loop starts, then close it.
                // A wall-clock timer can miss a short-lived native menu entirely.
                let sample = Timer(timeInterval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        menuSelected = controller.item?.button?.state == .on && controller.item?.button?.isHighlighted == true
                        menuSampled = true
                        menuStates.append("sample state=\(controller.item?.button?.state.rawValue ?? -1) highlighted=\(controller.item?.button?.isHighlighted ?? false)")
                        menu.cancelTrackingWithoutAnimation()
                    }
                }
                trackingSample = sample
                RunLoop.main.add(sample, forMode: .eventTracking)
            }
        }
        let endTracking = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil) { _ in
            MainActor.assumeIsolated {
                menuEnded = true
                menuStates.append("end state=\(controller.item?.button?.state.rawValue ?? -1) highlighted=\(controller.item?.button?.isHighlighted ?? false)")
            }
        }
        guard let currentButton = controller.item?.button, let currentWindow = currentButton.window else {
            throw TestFailure.failed("current native action-menu target exists")
        }
        func currentMenuEvent(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                location: currentButton.convert(NSPoint(x: currentButton.bounds.midX, y: currentButton.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: currentWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0)!
        }
        _ = controller.handleStatusMouseEvent(currentMenuEvent(.rightMouseDown))
        for _ in 0..<20 {
            if menuEnded && controller.item?.menu == nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        _ = controller.handleStatusMouseEvent(currentMenuEvent(.rightMouseUp))
        trackingSample?.invalidate()
        NotificationCenter.default.removeObserver(beginTracking)
        NotificationCenter.default.removeObserver(endTracking)
        if !menuSelected || !menuStarted || !menuSampled || !menuEnded || controller.item?.button?.state != .off || controller.item?.button?.isHighlighted != false || controller.item?.menu != nil {
            print("MENU LIFECYCLE", menuStates, "returned", controller.item?.button?.state.rawValue ?? -1, controller.item?.button?.isHighlighted ?? false, controller.item?.menu == nil)
        }
        try expect(menuStarted && menuSampled && menuEnded, "native action menu begins, is sampled while tracking, and finishes")
        try expect(menuSelected && controller.item?.button?.state == .off && controller.item?.button?.isHighlighted == false && controller.item?.menu == nil,
            "native action menu keeps selection until tracking ends")
        for _ in 0..<5 {
            let start = Date()
            controller.togglePopover()
            try expect(controller.popover.isShown && controller.item?.button?.state == .on, "rapid open completes synchronously with selected status button")
            controller.togglePopover()
            try expect(!controller.popover.isShown && controller.item?.button?.state == .off, "rapid close leaves no stale visible popup or selection")
            print(String(format: "BENCH menu toggle pair %.2f ms", Date().timeIntervalSince(start) * 1000))
        }
        controller.togglePopover()
        model.showsMenuBarIcon = false
        for _ in 0..<20 {
            if !controller.popover.isShown { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try expect(!controller.popover.isShown && controller.item == nil, "disabling menu bar closes its active popover")
        print("PASS quick download UI: bilingual light/dark focus, long paths, native Command Return, Escape, feedback and undo reset")
    }

    @MainActor static func quickDownloadPopoverResultTests(controller: MenuBarController, file: URL,
                                                          revealedFiles: () -> [[URL]]) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        try expect(controller.popover.isShown, "real quick popover remains open for Finder hit-target checks")
        guard let host = controller.popover.contentViewController?.view, let window = host.window else {
            throw TestFailure.failed("real quick popover mounts downloaded result")
        }
        try expect(window.isVisible, "Finder hit-target regression uses a visible native popover")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        guard let region = descendants(host).compactMap({ $0 as? QuickDownloadFileInteraction.Region }).first else {
            throw TestFailure.failed("real quick popover has downloaded result interaction")
        }
        let bounds = region.convert(region.bounds, to: host)
        let center = NSPoint(x: bounds.maxX + 8 + 16, y: bounds.midY)
        let offsets: [NSPoint] = [.zero, NSPoint(x: -12, y: 0), NSPoint(x: 12, y: 0), NSPoint(x: 0, y: -12), NSPoint(x: 0, y: 12)]
        let initialCount = revealedFiles().count
        for (index, offset) in offsets.enumerated() {
            let point = NSPoint(x: center.x + offset.x, y: center.y + offset.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event, atStart: true)
                var dispatched = false
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline {
                    if let queued = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                        NSApp.sendEvent(queued)
                        if queued.type == event.type && queued.windowNumber == window.windowNumber &&
                            abs(queued.timestamp - event.timestamp) < 0.000001 { dispatched = true; break }
                    } else { try await Task.sleep(nanoseconds: 5_000_000) }
                }
                try expect(dispatched, "Finder hit-target click completes native event dispatch")
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try expect(revealedFiles().count == initialCount + index + 1 && revealedFiles().last == [file],
                "real popover Finder button reveals the saved file exactly once at offset \(offset); count=\(revealedFiles().count - initialCount)")
        }
        print("PASS quick popover result: Finder button center and four edges reveal the exact file without opening it")
    }
}

extension CoreTests {
    @MainActor static func fileRowDoubleClickTests() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-double-click-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.pdf")
        try createPDF(at: file)
        for page in WorkspacePage.navigation {
            let suite = "folioak-double-click-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            var opened = 0, selected = 0
            let model = DownloadModel(preferences: preferences, opener: { _ in opened += 1; return true })
            let item = DownloadItem(original: "https://example.com/sample.pdf", directURL: URL(string: "https://example.com/sample.pdf"),
                state: .saved, savedURL: file, documentTitle: "Double click fixture")
            model.items = [item]; model.mediaLibrary = [item]; model.upsertPaper(item)
            let row: AnyView
            if page == .library {
                row = AnyView(LibraryRow(paper: model.papers[0], model: model, selected: false, select: { selected += 1 }))
            } else {
                row = AnyView(DownloadRow(item: item, model: model, inMediaLibrary: page == .media)
                    .onTapGesture { selected += 1 })
            }
            let host = QuickTestHost(rootView: row.frame(width: 600).background(Color.white))
            let window = QuickTestWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            var eventNumber = 0
            var eventTimes: [TimeInterval] = [], rowTrace: [String] = []
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            for region in descendants(host).compactMap({ $0 as? FileRowClickRegion.Region }) where !region.isControls {
                region.clickTrace = { rowTrace.append($0) }
            }
            func click(_ x: CGFloat, _ y: CGFloat, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async throws {
                let location = host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    eventNumber += 1
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    eventTimes.append(timestamp)
                    let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                        timestamp: timestamp, windowNumber: window.windowNumber,
                        context: nil, eventNumber: eventNumber, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
                    try await window.dispatchQueuedMouseEvent(event)
                }
            }
            func doubleClick(_ x: CGFloat, _ y: CGFloat, modifiers: NSEvent.ModifierFlags = []) async throws {
                // Separate user gestures, but do not suspend between their four
                // native events: scheduler latency must not invalidate the input.
                try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.05) * 1e9))
                eventTimes.removeAll(); rowTrace.removeAll()
                try await click(x, y, modifiers: modifiers)
                try await click(x, y, count: 2, modifiers: modifiers)
                let interval = eventTimes[2] - eventTimes[0]
                print("ROW DOUBLE TIMING", page.rawValue, x, y, "interval", interval, "limit", NSEvent.doubleClickInterval)
                try expect(interval < NSEvent.doubleClickInterval, "row double click input stays within the system interval")
            }
            try await click(130, 24)
            try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.05) * 1e9))
            if opened != 0 || selected == 0 {
                print("ROW DIAGNOSTIC", page.rawValue, "opened", opened, "selected", selected, "bounds", host.bounds,
                    "hit", String(describing: host.hitTest(NSPoint(x: 130, y: host.isFlipped ? 24 : host.bounds.height - 24))))
            }
            try expect(opened == 0 && selected > 0, "single click selects without opening on \(page.rawValue)")
            try await doubleClick(130, 24)
            for _ in 0..<20 {
                if opened > 0 { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            if opened != 1 {
                func children(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(children) }
                print("DOUBLE DIAGNOSTIC", page.rawValue, opened, host.gestureRecognizers.map { String(describing: type(of: $0)) + ":" + String($0.state.rawValue) },
                    children(host).compactMap { $0 as? FileRowClickRegion.Region }.map { "\($0.isControls) bounds=\($0.bounds) visible=\($0.visibleRect) frame=\($0.convert($0.bounds, to: host))" }, "trace", rowTrace)
            }
            try expect(opened == 1, "native double click opens exactly once on \(page.rawValue)")
            try await doubleClick(300, 3)
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(opened == 2, "row padding also supports double click on \(page.rawValue)")
            try await doubleClick(130, 24, modifiers: .command)
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(opened == 2, "modified selection never opens files on \(page.rawValue)")
            let recognizers = host.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.filter { $0.numberOfClicksRequired == 2 }
            try expect(recognizers.count == 1, "one native double-click recognizer per row")
            try expect(!recognizers[0].delaysPrimaryMouseButtonEvents, "double-click recognizer does not delay single-click events")
            recognizers.forEach { $0.isEnabled = false }
            let beforeBaseline = opened
            try await doubleClick(530, 25)
            try await Task.sleep(nanoseconds: 50_000_000)
            let baseline = opened - beforeBaseline
            try expect(baseline > 0, "button baseline hits the open action")
            recognizers.forEach { $0.isEnabled = true }
            let beforeButton = opened
            try await doubleClick(530, 25)
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(opened - beforeButton == baseline, "action buttons behave identically with row double-click enabled on \(page.rawValue)")
            let beforeRemoval = opened
            if page == .library { _ = (await model.setLibraryRemoved([model.papers[0].id], in: .documents, removed: true)) }
            else if page == .media { _ = (await model.setLibraryRemoved([item.id], in: .media, removed: true)) }
            else { model.clearDownloadRecord(item.id) }
            try await doubleClick(130, 24)
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(opened == beforeRemoval, "stale fading rows cannot open removed records")
            window.contentView = nil
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(!host.gestureRecognizers.contains { $0 is NSClickGestureRecognizer }, "row recognizer is removed when its native view leaves the window")
            print("PASS native row double click: \(page.rawValue), selection, padding, modifiers and action isolation")
        }
    }
}

extension CoreTests {
    @MainActor static func removalAnimationUITests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: "build/qa/record-removal", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for page in WorkspacePage.navigation {
            let suite = "folioak-removal-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let model = DownloadModel(preferences: preferences)
            var records: [DownloadItem] = []
            for index in 0..<3 {
                let file = root.appendingPathComponent("file-\(page.rawValue)-\(index).pdf")
                try createPDF(at: file, shade: CGFloat(index + 1) / 4)
                let source = URL(string: "https://example.com/removal-\(index).pdf")!
                records.append(DownloadItem(original: source.absoluteString, directURL: source, state: .saved,
                    savedURL: file, documentTitle: "Record \(index + 1) · deletion animation", finishedAt: Date().addingTimeInterval(Double(-index))))
                model.upsertPaper(records.last!)
            }
            model.history = records; model.mediaLibrary = records
            model.navigation = WorkspaceNavigation(page: page)
            let host = QuickTestHost(rootView: DownloaderView(model: model, page: page)
                .environment(\.colorScheme, .light))
            let window = QuickTestWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 150_000_000)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func regions() -> [FileRowClickRegion.Region] { descendants(host).compactMap { $0 as? FileRowClickRegion.Region }.filter { !$0.isControls && $0.target?.active == true && !$0.isHiddenOrHasHiddenAncestor } }
            func snapshot(_ suffix: String) throws {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(page.rawValue)-\(suffix).png"))
                }
            }
            try expect(regions().count == 3, "three actual rows mounted before deletion")
            try snapshot("0-before")
            let firstID = page == .library ? model.papers.sorted { $0.addedAt > $1.addedAt }.first!.id : records[0].id
            if page == .downloads { model.clearDownloadRecord(firstID) }
            else { _ = (await model.setLibraryRemoved([firstID], in: page == .library ? .documents : .media, removed: true)) }
            try await Task.sleep(nanoseconds: 60_000_000); try snapshot("1-fading")
            try await Task.sleep(nanoseconds: 100_000_000); try snapshot("2-closing")
            try await Task.sleep(nanoseconds: 180_000_000); try snapshot("3-after")
            for _ in 0..<20 {
                if regions().count == 2 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
            }
            if regions().count != 2 { print("REMOVAL DIAGNOSTIC", page.rawValue, regions().map { "bounds=\($0.bounds), hidden=\($0.isHiddenOrHasHiddenAncestor), alpha=\($0.alphaValue)" }) }
            try expect(regions().count == 2 && host.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.count == 2,
                "deleted row has no active native recognizer after fade and reflow")
            if page == .downloads { model.clearDownloadRecords() }
            else { _ = await model.setLibraryRemoved(Set(page == .library ? model.papers.map(\.id) : records.map(\.id)), in: page == .library ? .documents : .media, removed: true) }
            try await Task.sleep(nanoseconds: 330_000_000); try snapshot("4-empty")
            for _ in 0..<20 {
                if regions().isEmpty { break }
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
            }
            try expect(regions().isEmpty && !host.gestureRecognizers.contains { $0 is NSClickGestureRecognizer }, "last-row transition cleans up every native recognizer")
        }
        print("PASS row removal UI: three lists, fade/reflow intermediate frames, batch removal, empty state and native recognizer cleanup")
    }

    // Record transitions belong to record mutations. Navigation must swap the
    // content column in one frame instead of fading the previous page over it.
    @MainActor static func pageSwitchUITests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-page-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "folioak-page-switch-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        for index in 0..<6 {
            let file = root.appendingPathComponent("file-\(index).pdf")
            let source = URL(string: "https://example.com/switch-\(index).pdf")!
            model.upsertPaper(DownloadItem(original: source.absoluteString, directURL: source, state: .saved, savedURL: file,
                documentTitle: "Page switch record \(index + 1)", finishedAt: Date().addingTimeInterval(Double(-index))))
        }
        // Navigation compares stable content. Missing-file rows use static icons:
        // real thumbnails intentionally load asynchronously after every remount,
        // including cache hits, and belong to the separate thumbnail tests.
        model.papers = model.papers.map { paper in var value = paper; value.missing = true; return value }
        model.navigation = WorkspaceNavigation(page: .library)
        var view = DownloaderView(model: model, page: .library)
        view.reduceMotionOverride = false
        let host = QuickTestHost(rootView: view.environment(\.colorScheme, .light))
        let window = QuickTestWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // A runner's parked cursor must not start row-hover animations between frames.
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        func content() -> NSBitmapImageRep? {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            // Exclude the sidebar, whose selection indicator animates by design.
            let rect = NSRect(x: 240, y: 0, width: host.bounds.width - 240, height: host.bounds.height)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            host.cacheDisplay(in: rect, to: bitmap); return bitmap
        }
        func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            var count = 0
            for x in stride(from: 0, to: min(a.pixelsWide, b.pixelsWide), by: 3) {
                for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh), by: 3) {
                    guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.06 { count += 1 }
                }
            }
            return count
        }
        for (from, to) in [(WorkspacePage.library, WorkspacePage.downloads), (.downloads, .library), (.library, .media), (.media, .downloads)] {
            if model.navigation.current.page != from { model.navigation.visit(WorkspaceRoute(page: from)); try await Task.sleep(nanoseconds: 400_000_000) }
            model.navigation.visit(WorkspaceRoute(page: to))
            try await Task.sleep(nanoseconds: 30_000_000)
            guard let early = content() else { throw TestFailure.failed("page switch snapshot") }
            try await Task.sleep(nanoseconds: 400_000_000)
            guard let settled = content() else { throw TestFailure.failed("page switch snapshot") }
            let changed = differing(early, settled)
            if changed >= 40 {
                let output = URL(fileURLWithPath: "build/qa/page-switch")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for (name, bitmap) in [("early", early), ("settled", settled)] {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(from.rawValue)-\(to.rawValue)-\(name).png"))
                }
            }
            try expect(changed < 40, "\(from.rawValue) → \(to.rawValue) shows the destination without a fading previous page: \(changed) samples differ")
        }
        print("PASS page switch UI: library, downloads and media swap content without ghost frames")
    }

    // Blank chrome behaves like a title bar; sidebar items and header controls
    // never hand their presses to window dragging.
    @MainActor static func windowDragRegionTests() async throws {
        let suite = "folioak-window-drag-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        let host = QuickTestHost(rootView: DownloaderView(model: model, page: .downloads).environment(\.colorScheme, .light))
        let window = QuickTestWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        var dragCount = 0
        WindowDragRegion.Region.dragProbe = { dragCount += 1 }
        defer { WindowDragRegion.Region.dragProbe = nil }
        func drags(_ x: CGFloat, _ yFromTop: CGFloat) async throws -> Bool {
            let before = dragCount
            let location = host.convert(NSPoint(x: x, y: host.isFlipped ? yFromTop : host.bounds.height - yFromTop), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                try await window.dispatchQueuedMouseEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            return dragCount > before
        }
        // Coordinates follow the 960 pt workspace: sidebar 190 pt, header row 76 pt.
        for (x, y, label) in [(CGFloat(100), CGFloat(380), "sidebar gap below navigation"), (160, 24, "sidebar top beside the toggle"),
                              (600, 38, "page header blank space")] {
            try expect(try await drags(x, y), "\(label) moves the window like a title bar")
        }
        for (destination, y) in [(WorkspacePage.downloads, CGFloat(114)), (.library, 164), (.media, 214)] {
            try expect(try await !drags(90, y), "\(destination.rawValue) keeps its press instead of dragging the window")
            try expect(model.navigation.current.page == destination, "queued sidebar click commits navigation before the next control probe")
        }
        try expect(!model.navigation.back.isEmpty, "back probe targets an enabled navigation button")
        try expect(try await !drags(230, 38), "back button keeps its press instead of dragging the window")
        try expect(model.navigation.current.page == .library, "back button actually navigates to the previous page")
        // Collapse last, after all coordinates based on the expanded sidebar.
        try expect(try await !drags(37, 55), "sidebar toggle keeps its press instead of dragging the window")
        print("PASS window drag regions: blank sidebar and header drag, navigation controls stay clickable")
    }

    static func inputRecognitionTests() throws {
        let empty = InputRecognition(" \n\t ")
        try expect(empty.total == 0 && !empty.isOverLimit,
            "empty input has no recognized items or batch-limit warning")
        let mixed = InputRecognition([
            "1706.03762", "https://example.com/paper.pdf",
            "https://www.youtube.com/watch?v=abcdefghijk",
            "https://example.com/archive.zip", "not-a-link"
        ].joined(separator: "\n"))
        try expect(mixed.total == 5 && mixed.papers == 2 && mixed.media == 1 && mixed.files == 1 && mixed.invalid == 1 && !mixed.isOverLimit,
            "input recognition distinguishes papers, media, files and invalid tokens")
        let atLimit = (0..<ResourceLimits.batchCount).map { "https://example.com/paper-\($0).pdf" }.joined(separator: "\n")
        let allowed = InputRecognition(atLimit)
        try expect(allowed.total == ResourceLimits.batchCount && allowed.papers == ResourceLimits.batchCount && !allowed.isOverLimit,
            "all 200 tokens are classified at the accepted batch boundary")
        try expect(try BatchInput(atLimit).entries.count == allowed.total,
            "recognized boundary count matches the accepted download batch")
        let overLimit = atLimit + "\nhttps://example.com/extra.pdf"
        let rejected = InputRecognition(overLimit)
        try expect(rejected.total == ResourceLimits.batchCount + 1 && rejected.isOverLimit,
            "201 tokens retain their full count and report the exceeded batch limit")
        try expect(rejected.papers == 0 && rejected.media == 0 && rejected.files == 0 && rejected.invalid == 0,
            "over-limit input does not present a misleading partial classification")
        do {
            _ = try BatchInput(overLimit)
            throw TestFailure.failed("over-limit recognition agrees with batch rejection")
        } catch DownloadError.limit(_) {}
        print("PASS input recognition: mixed source types, empty input and exact 200/201 batch limits")
    }

    @MainActor static func brandEasterEggTests() async throws {
        let suite = "folioak-brand-egg-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        var downloadView = DownloaderView(model: model, page: .downloads)
        downloadView.reduceMotionOverride = false
        let host = QuickTestHost(rootView: downloadView.environment(\.colorScheme, .light))
        let window = QuickTestWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        var drags = 0
        WindowDragRegion.Region.dragProbe = { drags += 1 }
        defer { WindowDragRegion.Region.dragProbe = nil }
        // The leaf mark sits beside the 50 pt sidebar toggle in the 76 pt header row.
        let location = host.convert(NSPoint(x: 80, y: host.isFlipped ? 55 : host.bounds.height - 55), to: nil)
        func taps(_ count: Int, interval: UInt64) async throws {
            for _ in 0..<count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    try await window.dispatchQueuedMouseEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                }
                try await Task.sleep(nanoseconds: interval)
            }
        }
        let start = LeafBurst.triggered, grandStart = LeafBurst.grandTriggered
        let mountedBefore = LeafBurstOverlay.mounted
        try await taps(4, interval: 120_000_000)
        try expect(LeafBurst.triggered == start, "four quick taps keep the leaf burst hidden")
        try await Task.sleep(nanoseconds: 700_000_000)
        try await taps(4, interval: 120_000_000)
        try expect(LeafBurst.triggered == start, "a pause resets the tap count")
        try await taps(1, interval: 120_000_000)
        try expect(LeafBurst.triggered == start + 1, "the fifth quick tap releases the leaf burst")
        try await taps(2, interval: 120_000_000)
        try expect(LeafBurst.triggered == start + 3, "every extra quick tap adds another burst")
        try await taps(3, interval: 120_000_000)
        try expect(LeafBurst.grandTriggered == grandStart + 2, "the tenth tap of a streak starts another full round")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try await taps(5, interval: 120_000_000)
        try expect(LeafBurst.grandTriggered == grandStart + 3, "five more taps after a pause start a new round over the first")
        try await taps(5, interval: 120_000_000)
        try expect(LeafBurst.grandTriggered == grandStart + 4, "overlapping rounds keep responding")
        for _ in 0..<80 where LeafBurstOverlay.mounted == mountedBefore {
            try await Task.sleep(nanoseconds: 25_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try expect(LeafBurstOverlay.mounted == mountedBefore + 1,
            "overlapping bursts share one mounted animation overlay")
        let triggeredBeforeReduction = LeafBurst.triggered
        // Preserve the hosting/root view identity so this exercises a live
        // preference change while particles are already on screen.
        downloadView.reduceMotionOverride = true
        host.rootView = downloadView.environment(\.colorScheme, .light)
        for _ in 0..<80 where LeafBurstOverlay.mounted != mountedBefore {
            try await Task.sleep(nanoseconds: 25_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try expect(LeafBurstOverlay.mounted == mountedBefore,
            "enabling reduced motion removes an already mounted particle overlay: before=\(mountedBefore), now=\(LeafBurstOverlay.mounted), override=\(String(describing: downloadView.reduceMotionOverride))")
        let notesBefore = FolioNote.presented
        try await taps(5, interval: 120_000_000)
        try expect(LeafBurst.triggered == triggeredBeforeReduction && LeafBurstOverlay.mounted == mountedBefore,
            "reduced-motion brand taps never create particles or mount an animation overlay")
        try expect(FolioNote.presented == notesBefore + 1,
            "five brand taps still present the text note with reduced motion")
        downloadView.reduceMotionOverride = false
        host.rootView = downloadView.environment(\.colorScheme, .light)
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        try expect(LeafBurst.triggered == triggeredBeforeReduction && LeafBurstOverlay.mounted == mountedBefore,
            "disabling reduced motion does not resurrect retired particle animations")
        if let directory = ProcessInfo.processInfo.environment["FOLIOAK_EGG_FRAMES"] {
            // The preference-change regression cleared the previous rounds.
            // Start a fresh round only when diagnostic frames were requested.
            try await taps(5, interval: 120_000_000)
            for (index, delay) in [UInt64(0), 300, 500, 800, 1200, 1500, 1800].enumerated() {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(window.windowNumber)", "\(directory)/egg-\(index).png"]
                try process.run(); process.waitUntilExit()
            }
        }
        var stack = LeafBurstStack(), retired = 0
        for _ in 0..<6 {
            let burst = LeafBurst(grand: true, accent: 0x0A7A50)
            retired += stack.push(burst).count
            try expect(stack.bursts.last?.retired == nil, "the newest round is never retired")
            try expect(stack.liveParticles <= LeafBurstStack.particleBudget, "live particles stay within the budget")
        }
        try expect(retired == 4 && stack.bursts.count == 6, "older rounds fade out instead of being dropped mid-frame")
        try expect(drags == 0, "tapping the brand mark never drags the window")
        print("PASS brand easter egg: five-tap rounds, pause reset, bounded overlap, live reduced-motion cancellation, text-note fallback and clickable mark")
    }
}
