import Foundation

extension CoreTests {
    @MainActor static func backgroundPersistenceTests(root: URL, pdf: URL) async throws {
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
}
