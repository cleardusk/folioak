import AppKit
import Combine
import Foundation

private actor SchedulingProbe {
    var active: [Int: Int] = [:]
    var peak = 0
    var sameSourceOverlap = false
    var finished: [Int] = []
    func begin(_ source: Int) { active[source, default: 0] += 1; peak = max(peak, active.values.reduce(0, +)); sameSourceOverlap = sameSourceOverlap || active[source]! > 1 }
    func end(_ source: Int) { active[source, default: 0] -= 1; finished.append(source) }
}

extension CoreTests {
    @MainActor static func libraryTests(root: URL, pdf: URL) async throws {
        let suite = "arxiv-library-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let ref = try ArxivReference.parse("1706.03762v1")
        let item = DownloadItem(original: "1706.03762", reference: ref, state: .saved, savedURL: pdf, pages: 1, documentTitle: "A paper", finishedAt: Date())
        let state = root.appendingPathComponent("library-migration.json")
        try WorkspaceStore.write(WorkspaceSnapshot(input: "", items: [item], history: [item], logs: []), to: state)
        let model = DownloadModel(preferences: preferences, opener: { _ in true }, stateURL: state)
        try expect(model.papers.count == 1 && model.papers[0].reference == ref, "history migration deduplicates queue and history into independent library")
        let id = model.papers[0].id
        model.changePaper(id) { $0.tags = ["Vision", "重点"]; $0.favorite = true }
        try expect(model.papers[0].matches("vision 1706") && !model.papers[0].matches("unknown"), "library multi-term search covers title, identifier and tags")
        model.openPaper(model.papers[0], preview: true)
        try expect(model.papers[0].read && model.previewURL == pdf, "successful preview marks read")
        var readChanges = 0
        let readObservation = model.$papers.dropFirst().sink { _ in readChanges += 1 }
        for _ in 0..<10 {
            model.openPaper(LibraryPaper(item)) // A caller may retain an older unread snapshot.
            model.openFile(item)
            model.preview(item)
        }
        try expect(readChanges == 0, "repeated open and preview do not dirty an already-read library")
        model.changePaper(id) { $0.read = false; $0.missing = true }
        model.openFile(item)
        try expect(model.papers[0].read && !model.papers[0].missing, "opening a readable file still updates changed read and missing state")
        readObservation.cancel()
        model.previewURL = nil
        model.history = []; model.items = []; model.persistWorkspace()
        let restored = DownloadModel(preferences: preferences, stateURL: state)
        try expect(restored.history.isEmpty && restored.papers.count == 1 && restored.papers[0].favorite && restored.papers[0].read && restored.papers[0].tags.count == 2, "library survives cleared download history and restart with organization intact")
        restored.changePaper(id) { $0.removed = true }; restored.persistWorkspace()
        let removed = DownloadModel(preferences: preferences, stateURL: state)
        try expect(removed.library.isEmpty && removed.papers.count == 1 && FileManager.default.fileExists(atPath: pdf.path), "remove from library is recoverable and preserves PDF")
        removed.changePaper(id) { $0.removed = false }
        let imported = try LibraryStore.imported(pdf)
        try expect(imported.taskID == nil && imported.file == pdf && imported.pages != nil, "local import has independent identity and original file location")
        removed.importPDFs([pdf, pdf])
        while removed.importingPDFs { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(removed.papers.count == 1, "repeat local import does not duplicate an existing file")
        removed.changePaper(id) { $0.file = root.appendingPathComponent("gone.pdf"); $0.read = false }
        removed.openPaper(removed.papers[0])
        try expect(removed.papers[0].missing && !removed.papers[0].read, "missing local PDF is marked for relinking without falsely marking read")
        try expect(LibraryPaper.cleanTags(" a, A；视觉\n B ") == ["a", "视觉", "B"], "tag normalization deduplicates and preserves display case")
        var many: [LibraryPaper] = []
        for n in 0..<600 {
            var paper = LibraryPaper(item); paper.id = UUID(); paper.original = "paper-\(n)"; many.append(paper)
        }
        let libraryURL = root.appendingPathComponent("large-library.json")
        try LibraryStore.write(many, to: libraryURL)
        try expect(try LibraryStore.read(libraryURL)?.count == 600, "independent library does not inherit 500-record history retention")
        var largeAuthorItem = item
        largeAuthorItem.metadata = PaperMetadata(reference: ref, title: "Large collaboration", year: 2017, month: 6, authors: [String(repeating: "Author ", count: 4_000)])
        let bounded = LibraryPaper(largeAuthorItem)
        let boundedURL = root.appendingPathComponent("bounded-authors.json")
        try LibraryStore.write([bounded], to: boundedURL)
        try expect(try LibraryStore.read(boundedURL)?.first?.authors.count == 16_384, "large collaboration authors remain readable after restart")
        var invalid = bounded; invalid.authors += "x"
        try rejects({ try LibraryStore.write([invalid], to: boundedURL) }, "invalid records rejected before replacing library")
        try expect(try LibraryStore.read(boundedURL)?.count == 1, "failed write preserves valid library")
        var future = try JSONSerialization.jsonObject(with: Data(contentsOf: libraryURL)) as! [String: Any]
        future["schema"] = 999
        let futureURL = state.deletingLastPathComponent().appendingPathComponent(state.lastPathComponent + ".library.json")
        let futureData = try JSONSerialization.data(withJSONObject: future)
        try futureData.write(to: futureURL)
        let protected = DownloadModel(preferences: preferences, stateURL: state); protected.persistWorkspace()
        try expect(protected.libraryNotice != nil && (try Data(contentsOf: futureURL)) == futureData, "future/corrupt library cannot be silently overwritten")
        protected.upsertPaper(item); protected.importPDFs([pdf])
        try expect(protected.papers.isEmpty && !protected.importingPDFs && protected.notice != nil, "read-only library rejects changes that cannot be saved")

        try await importTerminationTests(root: root, pdf: pdf)
        try await githubLibraryMigrationTests(root: root, pdf: pdf, ordinary: LibraryPaper(item))

        let shortcuts = ShortcutSettings(preferences)
        try expect(!shortcuts.isCustomized, "default shortcuts have no reset operation")
        try expect(shortcuts.set(AppShortcut(key: "w"), for: .input) != nil, "window close shortcut is reserved")
        try expect(shortcuts.set(AppShortcut(key: "j"), for: .input) != nil, "duplicate app shortcuts rejected")
        let custom = AppShortcut(key: "l", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        try expect(shortcuts.set(custom, for: .input) == nil && shortcuts.isCustomized && ShortcutSettings(preferences)[.input] == custom, "custom shortcuts persist")
        shortcuts.reset()
        try expect(!shortcuts.isCustomized && !ShortcutSettings(preferences).isCustomized && ShortcutSettings(preferences)[.input].key == "l", "restore default shortcuts")

        for (input, expected) in [
            ("https://openreview.net/forum?id=abc_123&noteId=ignored", "https://openreview.net/pdf?id=abc_123"),
            ("https://aclanthology.org/2023.emnlp-main.1/", "https://aclanthology.org/2023.emnlp-main.1.pdf"),
            ("https://aclanthology.org/P19-1001/", "https://aclanthology.org/P19-1001.pdf"),
            ("https://openaccess.thecvf.com/content/CVPR2024/html/Test_paper.html?utm_source=x", "https://openaccess.thecvf.com/content/CVPR2024/papers/Test_paper.pdf")
        ] { try expect(try DownloadSource.parse(input) == DownloadSource.parse(expected), "source preview conversion: \(input)") }
        try rejects({ _ = try DownloadSource.parse("https://openreview.net/forum?id=a&id=b") }, "ambiguous OpenReview IDs rejected")
        let versionTransport = MockTransport(sourcePDF: pdf, latestVersion: 3)
        let versionModel = DownloadModel(engine: DownloadEngine(transport: versionTransport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        versionModel.upsertPaper(item); versionModel.checkPaperVersions([id])
        while !versionModel.checkingVersions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let pdfRequests = await versionTransport.pdfCalls
        try expect(versionModel.papers[0].checkedAt != nil && versionModel.papers[0].hasUpdate && versionModel.papers[0].latest?.version == 3 && versionModel.papers[0].file == pdf && versionModel.items.isEmpty && pdfRequests == 0, "checking versions only fetches metadata and leaves old PDF and queue intact")
        var newer = item; newer.id = UUID(); newer.reference = ArxivReference(baseID: ref.baseID, version: 3)
        versionModel.changePaper(id) { $0.favorite = true; $0.tags = ["重点"] }
        versionModel.upsertPaper(newer)
        try expect(versionModel.papers.count == 2 && versionModel.papers.allSatisfy { $0.favorite && $0.tags == ["重点"] }, "distinct versions remain separate even when content shares a file, with organization carried forward")
        versionModel.directory = root.appendingPathComponent("version-download")
        try FileManager.default.createDirectory(at: versionModel.directory, withIntermediateDirectories: true)
        versionModel.input = "2310.00001"
        versionModel.downloadLatest(versionModel.papers.first { $0.id == id }!)
        while versionModel.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(versionModel.input == "2310.00001" && versionModel.items.count == 1 && versionModel.items[0].reference?.version == 3 && versionModel.items[0].state == .saved, "explicit version download preserves unrelated draft and only queues selected version")
        try expect(versionModel.papers.contains { $0.reference == ref && $0.file == pdf } && FileManager.default.fileExists(atPath: pdf.path), "downloading a new version preserves original record and PDF")
        let updated = versionModel.papers.first { $0.reference?.version == 3 }!
        versionModel.showPaperDetails(updated)
        try expect(versionModel.diagnosticItem?.id == updated.id, "library details retain the library record identity")
        let details = TaskDiagnosticView(model: versionModel, item: updated.downloadItem, libraryPaperID: updated.id)
        try expect(details.diagnosticTask?.id == versionModel.items[0].id && details.current.savedURL == updated.file, "library details resolve download diagnostics separately from the current file")
        let relinked = root.appendingPathComponent("relinked.pdf")
        versionModel.changePaper(updated.id) { $0.file = relinked }
        try expect(details.current.savedURL == relinked && details.diagnosticTask?.savedURL != relinked, "relinked library paths take priority over older task paths, including missing files")
        versionModel.diagnosticItem = nil
        versionModel.papers.append(imported)
        versionModel.showPaperDetails(imported)
        try expect(versionModel.diagnosticItem?.id == imported.id, "local imports open file details without a download task")
        let localDetails = TaskDiagnosticView(model: versionModel, item: imported.downloadItem, libraryPaperID: imported.id)
        try expect(localDetails.current.savedURL == imported.file && localDetails.diagnosticTask == nil, "imported PDF details use the local file without fabricated diagnostics")
        versionModel.items = []; versionModel.history = []
        try expect(details.current.savedURL == relinked && details.diagnosticTask == nil && localDetails.current.savedURL == imported.file, "library file information survives cleared download records")
        let partialTransport = MockTransport(sourcePDF: pdf, metadata: [.status(404), .status(200)], latestVersion: 3)
        let partial = DownloadModel(engine: DownloadEngine(transport: partialTransport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        partial.upsertPaper(item)
        var other = item; other.id = UUID(); other.reference = try ArxivReference.parse("2003.07733v1")
        partial.upsertPaper(other); partial.checkPaperVersions(partial.papers.map(\.id))
        while !partial.checkingVersions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(partial.papers.last?.hasUpdate == true && partial.notice?.contains("1 篇") == true, "one unavailable paper does not block later version checks")
        print("PASS library: migration, independent retention, local import, tags, read state, recoverable removal, corruption protection, shortcuts and source conversion")
    }
    static func sourceSchedulingTests() async throws {
        let groups = SourceScheduler.groups([0, 0, 1, 2, 3, 3, 4]) { String($0) }
        let probe = SchedulingProbe()
        let results = await SourceScheduler.run(groups) { batch -> Int in
            for source in batch {
                await probe.begin(source)
                try? await Task.sleep(nanoseconds: source == 0 ? 120_000_000 : 10_000_000)
                await probe.end(source)
            }
            return batch.count
        }
        let peak = await probe.peak, overlap = await probe.sameSourceOverlap, first = await probe.finished.first
        try expect(results.reduce(0, +) == 7 && peak == 3 && !overlap, "at most three sources overlap and each source remains sequential")
        try expect(first != 0, "a waiting source does not block independent sources")
        print("PASS source scheduling: bounded cross-source concurrency and sequential per-source requests")
    }
}


extension CoreTests {
    @MainActor static func githubLibraryMigrationTests(root: URL, pdf: URL, ordinary: LibraryPaper) async throws {
        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        let link = "https://github.com/Org/Repo/blob/main/actually-pdf.mp4?raw=true"
        let raw = URL(string: "https://raw.githubusercontent.com/Org/Repo/main/actually-pdf.mp4")!
        var legacy = LibraryPaper(DownloadItem(original: link, directURL: URL(string: link), state: .saved,
                                               savedURL: pdf, pages: 1, documentTitle: "Historical PDF"))
        legacy.favorite = true; legacy.read = true; legacy.tags = ["Keep", "旧资料"]
        let state = root.appendingPathComponent("github-library-migration.json")
        let library = state.deletingLastPathComponent().appendingPathComponent(state.lastPathComponent + ".library.json")
        let original = try JSONEncoder().encode(LibraryStore.Snapshot(papers: [legacy, ordinary]))
        try original.write(to: library)
        let loaded = try LibraryStore.read(library)!
        var expected = legacy; expected.directURL = raw
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try expect(try encoder.encode(loaded[0]) == encoder.encode(expected), "old media-looking PDF keeps every library field while its source is normalized")
        try expect(loaded.count == 2 && loaded[1].id == ordinary.id && loaded[1].reference == ordinary.reference && loaded[1].file == ordinary.file && (try Data(contentsOf: library)) == original, "mixed old library remains readable without rewriting the file on read")
        let suite = "folioak-github-library-\(UUID().uuidString)", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(root.appendingPathComponent(suite).path, forKey: "downloadRootDirectory")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let engine = DownloadEngine(pdfTransport: URLSessionTransport(testConfiguration: config, policy: .externalPDF), requestInterval: 0, retryDelay: 0)
        let path = "/Org/Repo/main/actually-pdf.mp4"
        FixtureProtocol.install(.init(headers: ["Content-Type": "application/pdf"], body: try Data(contentsOf: pdf)), path: path)
        let model = DownloadModel(engine: engine, preferences: prefs, stateURL: state)
        try expect(model.libraryNotice == nil && model.papers.count == 2 && model.papers[0].directURL == raw, "upgraded model loads the mixed library")
        model.retryFromLibrary(model.papers[0].downloadItem); try await waitForQueue(model)
        try expect(model.successes == 1 && FixtureProtocol.lastRequest(path)?.url?.host == "raw.githubusercontent.com" && FixtureProtocol.count("/Org/Repo/blob/main/actually-pdf.mp4") == 0, "old library retry downloads the PDF through the raw route")
        model.persistWorkspace()
        let saved = try LibraryStore.read(library)!
        try expect(saved.count == 2 && saved[0].id == legacy.id && saved[0].favorite && saved[0].read && saved[0].tags == legacy.tags && saved[0].directURL == raw, "retry and save preserve migrated library identity and organization")
        var unsafe = legacy; unsafe.directURL = URL(string: "http://example.org/file.mp4")
        let invalid = try JSONEncoder().encode(LibraryStore.Snapshot(papers: [unsafe, ordinary]))
        let invalidURL = root.appendingPathComponent("github-invalid-library.json")
        try invalid.write(to: invalidURL)
        try rejects({ _ = try LibraryStore.read(invalidURL) }, "source migration still rejects unsafe old library URLs")
        try expect(try Data(contentsOf: invalidURL) == invalid, "rejected library is not changed by migration")
        print("PASS GitHub library migration: mixed historical PDFs, preserved metadata and identity, raw retry, safe validation and read-only loading")
    }
}

// The importer is suspended explicitly, so termination tests do not depend on
// PDF complexity, disk speed, or sleeps racing the worker.
private actor ImportTerminationGate {
    private(set) var entered = false
    private var released = false
    private var release: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func hold() async {
        calls += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
        }
    }
    func resume() { released = true; release?.resume(); release = nil }
}

private actor ImportTerminationTransport: HTTPTransport {
    private(set) var entered = false
    private(set) var cancelled = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        entered = true
        do {
            while true { try await Task.sleep(nanoseconds: 30_000_000_000) }
        } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }
}

extension CoreTests {
    // Poll observable milestones instead of racing a non-cancellable continuation
    // in a task group: a failed milestone must let the test itself return.
    @MainActor private static func awaitImportMilestone(_ name: String,
                                                        _ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !(await ready()) {
            guard ContinuousClock().now < deadline else {
                throw TestFailure.failed("PDF import termination timed out: \(name)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor private static func finishHeldImport(_ model: DownloadModel, gate: ImportTerminationGate,
                                                    cancelDownloads: Bool = false) async throws {
        var started = false, cancellationFinished = !cancelDownloads, completed = false
        var importingAtFlush: [Bool] = []
        model.terminationPhaseObserver = { phase in
            switch phase {
            case .started: started = true
            case .willFlush: importingAtFlush.append(model.importingPDFs)
            }
        }
        defer { model.terminationPhaseObserver = nil }
        let termination = Task {
            if cancelDownloads {
                await model.cancelAndWait()
                cancellationFinished = true
            }
            await model.finishTermination()
            completed = true
        }
        do {
            try await awaitImportMilestone("download cancellation did not finish") { cancellationFinished }
            try await awaitImportMilestone("finishTermination did not report started") { started }
            // Release only after finishTermination starts. Without its import
            // await, willFlush runs in that same MainActor turn and records true.
            await gate.resume()
            try await awaitImportMilestone("finishTermination did not complete") { completed }
        } catch {
            await gate.resume()
            termination.cancel()
            model.cancel()
            throw error
        }
        try expect(importingAtFlush == [false], "termination must finish the held import before taking its final snapshot")
    }

    @MainActor static func importTerminationTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-import-termination-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = ImportTerminationGate()
        defer { Task { await gate.resume() } }
        let imported = try LibraryStore.imported(pdf)
        let invalid = root.appendingPathComponent("invalid-import.pdf")
        let state = root.appendingPathComponent("import-termination.json")
        let model = DownloadModel(preferences: preferences, stateURL: state, pdfImporter: { url in
            if url == invalid { throw DownloadError.invalidPDF }
            await gate.hold()
            return imported
        })
        model.importPDFs([pdf, invalid])
        try await awaitImportMilestone("importer did not start") { await gate.entered }
        try expect(model.importingPDFs && model.importWorker != nil && model.papers.isEmpty,
                   "accepted import retains its worker until the full batch is published")
        model.beginTermination()
        model.importPDFs([pdf])
        // The same held worker must survive termination and reject a second batch.
        try expect(model.isTerminating && model.importingPDFs, "termination preserves an already accepted import")
        try await finishHeldImport(model, gate: gate)
        try expect(!model.importingPDFs && model.importWorker == nil && model.papers.count == 1,
                   "termination waits for valid imports and releases the worker despite a failed file")
        try expect(model.notice != nil, "import failures retain the ordinary error notice during termination")
        let library = state.deletingLastPathComponent().appendingPathComponent(state.lastPathComponent + ".library.json")
        try expect(try LibraryStore.read(library)?.map(\.file) == [pdf],
                   "final termination flush durably stores the accepted import")
        model.importPDFs([pdf])
        let importerCalls = await gate.calls
        try expect(!model.importingPDFs && model.importWorker == nil && importerCalls == 1,
                   "termination rejects new imports even after the prior worker completes")
        let restored = DownloadModel(preferences: preferences, stateURL: state)
        try expect(restored.papers.count == 1 && restored.papers[0].file == pdf,
                   "an import completed during normal termination survives restart")
        model.beginTermination()
        try await finishHeldImport(model, gate: gate, cancelDownloads: true)
        try expect(try LibraryStore.read(library)?.count == 1, "download cancellation and repeated termination preserve the imported catalog")

        let activeGate = ImportTerminationGate(), transport = ImportTerminationTransport()
        defer { Task { await activeGate.resume() } }
        let activeState = root.appendingPathComponent("active-import-termination.json")
        let active = DownloadModel(engine: DownloadEngine(transport: transport, pdfTransport: transport,
            requestInterval: 0, retryDelay: 0), preferences: preferences, stateURL: activeState, pdfImporter: { _ in
                await activeGate.hold(); return imported
            })
        defer { active.cancel() }
        active.directory = root.appendingPathComponent("active-import-downloads")
        active.input = "https://example.com/held.pdf"
        active.start()
        try await awaitImportMilestone("download transport did not start") { await transport.entered }
        active.importPDFs([pdf])
        try await awaitImportMilestone("concurrent importer did not start") { await activeGate.entered }
        try expect(active.busy && active.importingPDFs, "download and accepted import are both active before termination")
        active.beginTermination()
        try await finishHeldImport(active, gate: activeGate, cancelDownloads: true)
        let cancelled = await transport.cancelled
        try expect(cancelled && !active.busy && !active.importingPDFs && active.importWorker == nil &&
                   active.items.count == 1 && active.items[0].state == .cancelled,
                   "download termination cancels its transport while allowing the held PDF import to finish")
        let activeRestored = DownloadModel(preferences: preferences, stateURL: activeState)
        try expect(activeRestored.papers.count == 1 && activeRestored.papers[0].file == pdf &&
                   activeRestored.items.first?.state == .cancelled,
                   "concurrent download cancellation and import completion are both durable on restart")

        let failureGate = ImportTerminationGate()
        defer { Task { await failureGate.resume() } }
        let failureState = root.appendingPathComponent("failed-import-termination.json")
        let allFailed = DownloadModel(preferences: preferences, stateURL: failureState, pdfImporter: { _ in
            await failureGate.hold(); throw DownloadError.invalidPDF
        })
        allFailed.importPDFs([invalid])
        try await awaitImportMilestone("failing importer did not start") { await failureGate.entered }
        allFailed.beginTermination()
        try await finishHeldImport(allFailed, gate: failureGate)
        try expect(!allFailed.importingPDFs && allFailed.importWorker == nil && allFailed.papers.isEmpty && allFailed.notice != nil,
                   "an entirely failed import releases its worker and permits final termination without fabricating a library record")
        try expect(try WorkspaceStore.read(failureState) != nil, "all-failed import still completes the final workspace flush")
    }
}
