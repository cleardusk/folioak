import Foundation

extension CoreTests {
    @MainActor static func backgroundPersistenceTests(root: URL, pdf: URL) async throws {
        try libraryRecoveryTests(root: root, pdf: pdf)
        let suite = "folioak-background-save-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("background-save")
        let state = folder.appendingPathComponent("workspace.json")
        let model = DownloadModel(preferences: preferences, stateURL: state)
        let paper = DownloadItem(original: "1706.03762v1", reference: try ArxivReference.parse("1706.03762v1"),
                                 state: .saved, savedURL: pdf, pages: 1, documentTitle: "Keep this paper")
        model.items = [paper]; model.upsertPaper(paper)
        model.logs = (0..<1500).map { n in ActivityEntry(level: .info, message: "event \(n)", subject: nil, itemID: nil) }
        model.input = "old draft"; model.saveWorkspace()
        for n in 0..<50 {
            model.input = "draft-\(n)"
            model.changePaper(model.papers[0].id) { $0.tags = ["tag-\(n)"] }
            model.saveWorkspace()
        }
        let library = folder.appendingPathComponent("library.json")
        try await awaitPersistence {
            (try? WorkspaceStore.read(state)?.input) == "draft-49" &&
            (try? LibraryStore.read(library)?.first?.tags) == ["tag-49"]
        }
        try expect(model.input == "draft-49" && model.papers[0].tags == ["tag-49"], "older completion preserves newer draft and library edits")

        // No main-actor yield: an earlier queued save must finish before clear,
        // and its later completion must not restore the removed records.
        model.input = "draft retained after clear"; model.saveWorkspace()
        model.clearDownloadRecords()
        try await Task.sleep(nanoseconds: 50_000_000)
        let cleared = DownloadModel(preferences: preferences, stateURL: state)
        try expect(model.downloads.isEmpty && cleared.downloads.isEmpty && cleared.input == model.input && cleared.papers.count == 1,
                   "clear drains older writes and preserves the independent library")

        // An oversized older snapshot may be trimmed on disk, but cannot trim
        // newly edited in-memory history or diagnostics.
        model.history = (0..<500).map { _ in DownloadItem(original: String(repeating: "x", count: 20_000), state: .failed) }
        model.saveWorkspace()
        let latest = DownloadItem(original: "newest record", state: .failed)
        let event = ActivityEntry(level: .info, message: "newest diagnostic", subject: nil, itemID: nil)
        model.history = [latest]; model.logs = [event]; model.input = "latest draft"
        await model.persistWorkspaceAndWait()
        try await Task.sleep(nanoseconds: 20_000_000)
        let loaded = try WorkspaceStore.read(state)!
        try expect(model.history.map(\.id) == [latest.id] && model.logs.map(\.id) == [event.id] &&
                   loaded.history.map(\.id) == [latest.id] && loaded.logs.map(\.id) == [event.id] && loaded.input == "latest draft",
                   "byte-pressure completion cannot roll back newer records; async flush commits the latest snapshot")

        let damaged = folder.appendingPathComponent("damaged.json"), original = Data("damaged original".utf8)
        try original.write(to: damaged)
        let recovering = DownloadModel(preferences: preferences, stateURL: damaged)
        recovering.input = "recovered draft"; recovering.saveWorkspace()
        recovering.input = "latest recovered draft"
        await recovering.persistWorkspaceAndWait()
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("damaged.json.backup-") }
        try expect(backups.count == 1 && (try Data(contentsOf: backups[0])) == original &&
                   (try WorkspaceStore.read(damaged))?.input == "latest recovered draft", "damaged input is backed up exactly once before background recovery")

        let blockedParent = root.appendingPathComponent("blocked-background-save")
        try Data().write(to: blockedParent)
        let blockedState = blockedParent.appendingPathComponent("workspace.json")
        let blocked = DownloadModel(preferences: preferences, stateURL: blockedState)
        blocked.input = "keep after write failure"; blocked.saveWorkspace()
        try await awaitPersistence { blocked.persistenceNotice != nil }
        try FileManager.default.removeItem(at: blockedParent)
        blocked.saveWorkspace()
        try await awaitPersistence { (try? WorkspaceStore.read(blockedState)?.input) == blocked.input && blocked.persistenceNotice == nil }
        try expect(blocked.input == "keep after write failure", "failed automatic saves remain visible and recover without losing the draft")
        print("PASS background persistence: latest edits, coalescing, clear ordering, byte pressure, corruption backup, async flush and failure recovery")
    }

    @MainActor private static func awaitPersistence(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !ready() {
            guard ContinuousClock().now < deadline else { throw TestFailure.failed("background save timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor static func libraryRecoveryTests(root: URL, pdf: URL) throws {
        let suite = "folioak-library-recovery-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("library-recovery")
        let state = folder.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(state)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let old = DownloadItem(original: "1706.03762v1", reference: try ArxivReference.parse("1706.03762v1"),
            state: .saved, savedURL: pdf, pages: 1, documentTitle: "Original", finishedAt: date)
        var retained = LibraryPaper(old)
        retained.title = "My edited title"; retained.tags = ["Keep"]; retained.favorite = true
        retained.read = true; retained.removed = true
        retained.file = folder.appendingPathComponent("manually-relinked.pdf")
        retained.latest = try ArxivReference.parse("1706.03762v3"); retained.checkedAt = date
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let retainedBytes = try encoder.encode(retained)
        try persistence.writeLibrary([retained])

        let missing = DownloadItem(original: "2003.07733v1", reference: try ArxivReference.parse("2003.07733v1"),
            state: .saved, savedURL: folder.appendingPathComponent("newest.pdf"), pages: 1,
            documentTitle: "Recovered paper", finishedAt: date.addingTimeInterval(10))
        var olderCopy = missing
        olderCopy.id = UUID(); olderCopy.finishedAt = date.addingTimeInterval(5)
        olderCopy.savedURL = folder.appendingPathComponent("older.pdf")
        let newerVersion = DownloadItem(original: "1706.03762v2", reference: try ArxivReference.parse("1706.03762v2"),
            state: .saved, savedURL: pdf, pages: 1, documentTitle: "New version", finishedAt: date.addingTimeInterval(20))
        let failed = DownloadItem(original: "2310.00001v1", reference: try ArxivReference.parse("2310.00001v1"), state: .failed)
        // Force the catalog write to fail before replacing its valid prior data,
        // while the same save commits the successful downloads to the workspace.
        var invalid = retained; invalid.tags = Array(repeating: "tag", count: 21)
        let snapshot = WorkspaceSnapshot(input: "", items: [missing, newerVersion], history: [old, olderCopy, missing, failed], logs: [])
        let result = persistence.flush(WorkspacePersistence.Request(sequence: 1, revision: 1, libraryRevision: 1, mediaRevision: 0,
            snapshot: snapshot, stateURL: state, libraryURL: persistence.libraryURL, mediaURL: nil,
            papers: [invalid, LibraryPaper(missing)], media: nil))
        try expect(result.libraryError != nil, "fixture fails the catalog write independently")
        _ = try result.workspace.get()
        try expect(try LibraryStore.read(persistence.libraryURL)?.count == 1, "failed catalog save retains its prior valid records")

        let recovered = DownloadModel(preferences: preferences, stateURL: state)
        try expect(recovered.papers.count == 3, "restart recovers missing successes and distinct versions, not failed tasks or duplicate history")
        try expect(try encoder.encode(recovered.papers.first { $0.id == retained.id }!) == retainedBytes,
                   "recovery preserves edited title, tags, favorite, read/removal state, version check and relinked path exactly")
        try expect(recovered.papers.first { $0.identity == LibraryPaper(missing).identity }?.file == missing.savedURL,
                   "newest successful retry wins when the catalog lacks that resource")
        let recoveredBytes = try encoder.encode(recovered.papers)
        let restarted = DownloadModel(preferences: preferences, stateURL: state)
        try expect(try encoder.encode(restarted.papers) == recoveredBytes, "recovered catalog is durable and restart is idempotent")

        let corrupt = Data("unreadable catalog".utf8)
        try corrupt.write(to: persistence.libraryURL)
        let protected = DownloadModel(preferences: preferences, stateURL: state)
        protected.persistWorkspace()
        try expect(!protected.libraryWritable && protected.papers.isEmpty && protected.libraryNotice != nil &&
                   (try Data(contentsOf: persistence.libraryURL)) == corrupt,
                   "recovery never replaces a damaged read-only catalog with download history")
        print("PASS library recovery: independent write failure, restart, newest success, deduplication, metadata protection and corrupt catalog")
    }
}
