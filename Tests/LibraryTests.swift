import AppKit
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

        let shortcuts = ShortcutSettings(preferences)
        try expect(shortcuts.set(AppShortcut(key: "w"), for: .input) != nil, "window close shortcut is reserved")
        try expect(shortcuts.set(AppShortcut(key: "j"), for: .input) != nil, "duplicate app shortcuts rejected")
        let custom = AppShortcut(key: "l", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        try expect(shortcuts.set(custom, for: .input) == nil && ShortcutSettings(preferences)[.input] == custom, "custom shortcuts persist")
        shortcuts.reset()
        try expect(ShortcutSettings(preferences)[.input].key == "l", "restore default shortcuts")

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
        try expect(versionModel.diagnosticItem?.id == versionModel.items[0].id, "library details resolve the latest real task, even when record ID differs")
        versionModel.diagnosticItem = nil
        versionModel.showPaperDetails(imported)
        try expect(versionModel.diagnosticItem == nil, "local imports do not open empty download diagnostics")
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
