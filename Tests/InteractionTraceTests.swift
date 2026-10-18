import Foundation
import AppKit
import SwiftUI
import Combine

extension CoreTests {
    @MainActor static func interactionTraceTests() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("folioak-trace-tests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func events(_ folder: URL) throws -> [InteractionEvent] {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try Data(contentsOf: folder.appendingPathComponent("events.jsonl")).split(separator: 10)
                .map { try decoder.decode(InteractionEvent.self, from: Data($0)) }
        }
        func summary(_ folder: URL) throws -> InteractionTrace.ExportSummary {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(InteractionTrace.ExportSummary.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json")))
        }
        let location = root.appendingPathComponent("records")
        let trace = InteractionTrace(directory: location, version: "2.8.6")
        for _ in 0..<1000 { trace.record(.pageChanged) }
        await trace.flush()
        try expect(!manager.fileExists(atPath: location.path), "disabled trace creates no files or events")

        // The one-shot timer writes sparse events, then stops without idle writes.
        var timerLimits = InteractionTrace.Limits(); timerLimits.delay = 0.03
        let timed = InteractionTrace(directory: root.appendingPathComponent("timed"), limits: timerLimits)
        timed.setEnabled(true)
        try await Task.sleep(nanoseconds: 150_000_000)
        try expect(manager.fileExists(atPath: timed.directory!.path), "sparse events flush without explicit export/quit")
        await timed.flush()
        let batches = timed.writeBatches
        try await Task.sleep(nanoseconds: 100_000_000)
        await timed.flush()
        try expect(timed.writeBatches == batches, "idle recorder performs no repeated writes")
        timed.setEnabled(false); await timed.flush()
        try manager.removeItem(at: timed.directory!)
        try Data("occupied path".utf8).write(to: timed.directory!)
        timed.setEnabled(true); await timed.flush()
        try expect(timed.hasFailed, "a previously prepared writer suspends after its directory becomes unavailable")
        try manager.removeItem(at: timed.directory!)
        timed.setEnabled(false); timed.setEnabled(true); await timed.flush()
        try expect(!timed.hasFailed && manager.fileExists(atPath: timed.directory!.path), "explicit retry recreates an unavailable trace directory")
        timed.setEnabled(false); await timed.flush()

        trace.setEnabled(true)
        let item = UUID(), operation = UUID(), attempt = UUID()
        trace.record(.downloadSubmitted, context: .quickPanel, outcome: .requested, operation: operation)
        trace.record(.taskStarted, item: item, operation: operation, attempt: attempt, detail: .arxiv)
        trace.record(.taskFinished, outcome: .succeeded, item: item, attempt: attempt, durationMS: 123)
        await trace.finish()
        let output = try await trace.export(to: root, range: .session)
        let rows = try events(output)
        try expect(rows.map(\.action) == [.sessionStarted, .downloadSubmitted, .taskStarted, .taskFinished, .sessionEnded], "session/action/result order survives batch export")
        try expect(rows.map(\.sequence) == [1, 2, 3, 4, 5], "trace sequence is monotonic")
        try expect(rows[1].operation == operation && rows[2].attempt == rows[3].attempt, "operation and retry correlation")
        let metadata = try summary(output)
        try expect(metadata.incompleteSessions.isEmpty && metadata.appVersion == "2.8.6" && !metadata.writeFailure, "export completeness and version")
        let permissions = try manager.attributesOfItem(atPath: location.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o700, "trace directory is private")
        for file in try manager.contentsOfDirectory(at: location, includingPropertiesForKeys: nil) {
            let mode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            try expect(mode?.intValue == 0o600, "trace files are private")
        }
        trace.setEnabled(false)
        trace.record(.pageChanged)
        await trace.flush()
        let disabled = try await trace.export(to: root, range: .today)
        try expect(try events(disabled).last?.action == .recordingDisabled, "turning off stops event intake and drains prior events")

        // Force backpressure deterministically, with no UI-thread disk wait.
        var small = InteractionTrace.Limits()
        small.pending = 8; small.batch = 4
        let congested = InteractionTrace(directory: root.appendingPathComponent("congested"), limits: small)
        let gate = DispatchSemaphore(value: 0)
        congested.blockWriter { gate.wait() }
        congested.setEnabled(true)
        for _ in 0..<100 { congested.record(.taskPhase) }
        congested.record(.taskFinished, outcome: .failed, item: item, diagnostic: .storage)
        try expect(congested.pendingCount <= 8, "inbox remains bounded under a blocked writer")
        gate.signal()
        await congested.flush()
        let congestedOutput = try await congested.export(to: root, range: .session)
        try expect(try events(congestedOutput).contains { $0.action == .taskFinished }, "terminal event displaces low-value progress under pressure")
        try expect(try summary(congestedOutput).droppedEvents > 0, "export discloses lost events")

        // Small deterministic limits exercise rotation and retention without 20MB fixtures.
        var limits = InteractionTrace.Limits()
        limits.segment = 1500; limits.total = 4500
        let rotating = InteractionTrace(directory: root.appendingPathComponent("rotation"), limits: limits)
        rotating.setEnabled(true)
        for _ in 0..<30 { rotating.record(.pageChanged); await rotating.flush() }
        let files = try manager.contentsOfDirectory(at: rotating.directory!, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        try expect(bytes <= 4500 && files.count >= 2, "rotation enforces total disk budget")
        for file in files { try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: file.path) }
        let old = try await rotating.export(to: root, range: .week)
        try expect(try events(old).isEmpty, "expired segments are removed on export")
        let corrupt = rotating.directory!.appendingPathComponent("trace-corrupt.jsonl")
        try Data("{broken\n{\"partial".utf8).write(to: corrupt)
        let recovered = try await rotating.export(to: root, range: .week)
        try expect(try summary(recovered).skippedLines == 2, "damaged/truncated records do not break export")
        try await rotating.clear()
        try expect(try manager.contentsOfDirectory(atPath: rotating.directory!.path).isEmpty, "clear removes only local trace segments")

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocked)
        let failure = InteractionTrace(directory: blocked)
        failure.setEnabled(true); await failure.flush()
        try expect(failure.hasFailed && !failure.isEnabled, "write errors suspend intake without throwing into application")
        let exitGate = DispatchSemaphore(value: 0)
        failure.blockWriter { exitGate.wait() }
        let exitStart = Date()
        await failure.flushBeforeExit()
        try expect(Date().timeIntervalSince(exitStart) < 1, "diagnostic writer cannot indefinitely delay quit")
        exitGate.signal()
        await failure.flush()

        // Original user input and title never enter the closed trace schema.
        let suite = "folioak-trace-model-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let pdf = root.appendingPathComponent("private-secret-title.pdf")
        try createPDF(at: pdf)
        prefs.set(root.path, forKey: "downloadRootDirectory")
        let engine = DownloadEngine(transport: MockTransport(sourcePDF: pdf), requestInterval: 0, retryDelay: 0)
        let model = DownloadModel(engine: engine, preferences: prefs, opener: { _ in true }, stateURL: root.appendingPathComponent("model/workspace.json"))
        try expect(!model.traceSettings.enabled, "preference defaults off")
        model.traceSettings.enabled = true
        model.input = "2501.12345"
        model.start()
        try await waitForQueue(model)
        guard let saved = model.items.first else { throw TestFailure.failed("trace model saved item") }
        model.preview(saved)
        model.openFile(saved)
        if let paper = model.papers.first {
            model.changePaper(paper.id) { $0.favorite = true; $0.tags = ["private-secret-tag"] }
        }
        do { _ = try model.submitQuickDownload("private-secret-input") } catch {}
        await model.trace.flush()
        let modelOutput = try await model.trace.export(to: root, range: .session)
        let modelRows = try events(modelOutput)
        try expect(modelRows.contains { $0.action == .taskFinished && $0.outcome == .succeeded }, "real engine completion is traced")
        try expect(modelRows.contains { $0.action == .downloadRejected && $0.context == .quickPanel }, "invalid quick input rejection is traced")
        try expect(modelRows.contains { $0.action == .favoriteChanged } && modelRows.contains { $0.action == .tagsChanged }, "library management is traced")
        let serialized = try String(contentsOf: modelOutput.appendingPathComponent("events.jsonl"), encoding: .utf8)
        try expect(!serialized.contains("private-secret") && !serialized.contains(root.path) && !serialized.contains("2501.12345"), "export excludes input, titles, tags, paths and identifiers from URLs")
        model.traceSettings.enabled = false
        try expect(!prefs.bool(forKey: InteractionTraceSettings.preferenceKey), "opt-out persists")

        // No ObservableObject notifications, cache rebuilding, or model snapshots per event.
        model.papers = (0..<20_000).map { index in
            LibraryPaper(DownloadItem(original: "fixture", state: .saved, documentTitle: "Paper \(index)"))
        }
        func cachedQuery() -> Int {
            model.libraryQueries.documents(model.papers, revision: model.libraryRevision, query: "paper", filter: .all, sort: .title, tag: nil).items.count
        }
        _ = cachedQuery()
        let builds = model.libraryQueries.documentBuilds
        var notifications = 0
        let observation = model.objectWillChange.sink { notifications += 1 }
        var timings: [[Double]] = []
        for enabled in [false, true] {
            model.traceSettings.enabled = enabled
            var samples: [Double] = []
            for index in 0..<4096 {
                let start = DispatchTime.now().uptimeNanoseconds
                model.trace.record(.pageChanged, context: .documents)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
                if index.isMultiple(of: 32) {
                    try expect(cachedQuery() == 20_000, "20k query remains usable while recording")
                    await model.trace.flush()
                }
            }
            await model.trace.flush()
            timings.append(samples.sorted())
        }
        try expect(notifications == 0 && builds == model.libraryQueries.documentBuilds, "trace events cause no model publications or 20k query rebuilds")
        observation.cancel()
        let off = timings[0][Int(Double(timings[0].count) * 0.95)]
        let on = timings[1][Int(Double(timings[1].count) * 0.95)]
        try expect(on < 100, "trace ingestion p95 stays below 0.1ms")
        print(String(format: "BENCH trace ingestion: disabled p95 %.3f us; enabled p95 %.3f us; 20k query builds unchanged; UI publications 0", off, on))
        var exportPulses = 0
        let responsiveness = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
                exportPulses += 1
            }
        }
        let outputDuringRecording = try await model.trace.export(to: root, range: .week)
        responsiveness.cancel()
        await responsiveness.value
        try expect(exportPulses > 1, "main actor runs while background export is in progress")
        model.trace.record(.pageChanged, context: .media)
        await model.trace.flush()
        let afterExport = try await model.trace.export(to: root, range: .session)
        try expect(try events(afterExport).count > events(outputDuringRecording).count, "recording continues after immutable export snapshot")
        await model.trace.finish()
        await model.persistWorkspaceAndWait()
        print("PASS local interaction trace: opt-in, ordering, privacy, bounded buffering, retention, corrupt recovery, export, failures and model integration")
    }
}


extension CoreTests {
    @MainActor static func interactionTraceSnapshots() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.language = previous }
        let suite = "folioak-trace-ui-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let settings = InteractionTraceSettings(preferences: prefs, recorder: InteractionTrace(directory: nil))
        let folder = URL(fileURLWithPath: "build/qa/interaction-trace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for language in [AppLanguage.chinese, .english] {
            AppLocalization.shared.language = language
            for dark in [false, true] {
                let palette = AppTheme(rawValue: "graphite")!.palette(dark: dark)
                let content = InteractionTraceControls(settings: settings, palette: palette)
                    .font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.text))
                    .padding(20).frame(width: 440, alignment: .leading)
                    .background(ThemePalette.color(palette.canvas))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, L10n.locale)
                let host = NSHostingView(rootView: content)
                let size = host.fittingSize
                try expect(size.height < 250, "trace controls fit a small settings pane")
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure.failed("trace control bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = (language == .english ? "en" : "zh") + (dark ? "-dark" : "-light") + ".png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                window.close()
            }
        }
        print("PASS interaction trace controls: Chinese/English light/dark compact layouts")
    }
}
