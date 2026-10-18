import AppKit
import Combine
import Foundation

@MainActor private enum LibraryManagementFixture {
    static func state(_ root: URL, _ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("workspace.json")
    }
    static func file(_ state: URL, _ name: String) throws -> URL {
        let url = state.deletingLastPathComponent().appendingPathComponent(name)
        try Data(("fixture: " + name).utf8).write(to: url)
        return url
    }
    static func media(_ url: URL, name: String = "media") -> DownloadItem {
        DownloadItem(original: "https://example.com/" + name + ".png", directURL: URL(string: "https://example.com/" + name + ".png"),
                     state: .saved, savedURL: url, documentTitle: name, createdAt: Date(timeIntervalSince1970: 100),
                     finishedAt: Date(timeIntervalSince1970: 200), mediaFormat: .automatic)
    }
    static func model(_ state: URL, _ preferences: UserDefaults, recycle: @escaping (URL) throws -> Void = { _ in throw CocoaError(.fileWriteNoPermission) }) -> DownloadModel {
        DownloadModel(preferences: preferences, opener: { _ in true }, stateURL: state, recycleFile: recycle)
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    static func request(_ model: DownloadModel, ids: Set<UUID>, in collection: RecordCollection) throws -> FileTrashRequest {
        model.requestFileTrash(ids, in: collection)
        guard let request = model.pendingFileTrash else { throw TestFailure.failed("missing file-trash confirmation") }
        try expect(request.ids == ids && request.collection == collection, "confirmation retains the exact requested collection and IDs")
        return request
    }
    static func recycle(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("recycled-" + UUID().uuidString + "-" + url.lastPathComponent))
    }
}

extension CoreTests {
    @MainActor static func libraryManagementTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-library-management-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        try await libraryRemovalTests(root: root, pdf: pdf, preferences: preferences)
        try await libraryReplayTests(root: root, preferences: preferences)
        try await libraryRemovalFailureTests(root: root, pdf: pdf, preferences: preferences)
        try await libraryFileTrashTests(root: root, pdf: pdf, preferences: preferences)
        try downloadFileTrashClearsRecordTests(root: root, pdf: pdf, preferences: preferences)
        try libraryFileTrashFailureTests(root: root, preferences: preferences)
        print("PASS library management: asynchronous remove/restore/undo, legacy migration, replay tombstones, bulk retention, shared-file trash, stale confirmations and failure recovery")
    }

    @MainActor private static func libraryRemovalTests(root: URL, pdf: URL, preferences: UserDefaults) async throws {
        let state = try LibraryManagementFixture.state(root, "library-removal")
        let model = LibraryManagementFixture.model(state, preferences)
        let copy = state.deletingLastPathComponent().appendingPathComponent("paper.pdf")
        try FileManager.default.copyItem(at: pdf, to: copy)
        let reference = try ArxivReference.parse("1706.03762v1")
        let item = DownloadItem(original: reference.identifier, reference: reference, state: .saved, savedURL: copy, pages: 1, documentTitle: "Original title")
        model.items = [item]; model.history = [item]; model.upsertPaper(item)
        model.changePaper(item.id) {
            $0.title = "Personal title"; $0.authors = "Personal author"; $0.tags = ["keep", "视觉"]
            $0.favorite = true; $0.read = true; $0.latest = try? ArxivReference.parse("1706.03762v2")
            $0.checkedAt = Date(timeIntervalSince1970: 300)
        }
        model.input = "keep this draft"; model.record(.info, "Keep diagnostic", item: item); model.persistWorkspace()
        let baseline = try LibraryManagementFixture.encoded(model.papers[0]), fileBytes = try Data(contentsOf: copy)
        let logIDs = model.logs.map(\.id)
        var publishedAfterCommit = true
        let observation = model.$papers.dropFirst().sink { proposed in
            let onDisk = try? LibraryStore.read(state.deletingLastPathComponent().appendingPathComponent("library.json"))
            publishedAfterCommit = publishedAfterCommit && onDisk?.map(\.removed) == proposed.map(\.removed)
        }
        try expect((await model.setLibraryRemoved([item.id], in: .documents, removed: true)), "document removal commits successfully")
        try expect(publishedAfterCommit && model.papers[0].removed && model.library.isEmpty &&
                   model.libraryUndo?.collection == .documents && model.libraryUndo?.ids == [item.id], "document removal is durable before publication and registers exact undo IDs")
        let restarted = LibraryManagementFixture.model(state, preferences)
        try expect(restarted.library.isEmpty && restarted.papers[0].removed && restarted.downloads.count == 1 &&
                   restarted.input == model.input && restarted.logs.map(\.id) == logIDs && (try Data(contentsOf: copy)) == fileBytes,
                   "removed documents stay removed across restart without clearing files, history or draft")
        try expect((await model.undoLibraryRemoval()) && model.libraryUndo == nil && (try LibraryManagementFixture.encoded(model.papers[0])) == baseline,
                   "undo restores all document organization and metadata without rewriting it from history")
        observation.cancel()
        try expect((await model.setLibraryRemoved([item.id], in: .documents, removed: true)), "document can be removed again")
        var refreshed = item; refreshed.documentTitle = "Downloaded title"
        model.upsertPaper(refreshed)
        try expect(model.papers[0].removed && model.papers[0].title == "Personal title", "passive document upsert preserves removal and personal metadata")
        try expect((await model.setLibraryRemoved([item.id], in: .documents, removed: false)), "explicit document restore succeeds")
        model.busy = true
        try expect(!(await model.setLibraryRemoved([item.id], in: .documents, removed: true)) && !model.papers[0].removed, "busy model rejects catalog removal")
        model.busy = false
        _ = await model.setLibraryRemoved([UUID()], in: .documents, removed: true)
        try expect(!model.papers[0].removed, "unknown catalog IDs do not change other entries")

        let first = try LibraryManagementFixture.file(state, "first.png"), second = try LibraryManagementFixture.file(state, "second.png")
        let media = LibraryManagementFixture.media(first)
        var alreadyRemoved = LibraryManagementFixture.media(second, name: "second")
        alreadyRemoved.libraryRemovedAt = Date(timeIntervalSince1970: 50)
        model.mediaLibrary = [media, alreadyRemoved]; model.persistWorkspace()
        try expect((await model.setLibraryRemoved([media.id, alreadyRemoved.id], in: .media, removed: true)), "mixed batch removal changes active media")
        try expect(model.libraryUndo?.ids == [media.id], "undo records only IDs whose removal status actually changed")
        try expect((await model.undoLibraryRemoval()) && !model.mediaLibrary[0].isLibraryRemoved && model.mediaLibrary[1].isLibraryRemoved,
                   "undo never resurrects entries that were already removed before the batch")

        let many = try (0..<502).map { index -> DownloadItem in
            LibraryManagementFixture.media(try LibraryManagementFixture.file(state, "bulk-\(index).png"), name: "bulk-\(index)")
        }
        model.mediaLibrary = many; model.items = Array(many.prefix(3)); model.history = Array(many.prefix(20)); model.persistWorkspace()
        let selected = Set(many.prefix(501).map(\.id))
        try expect((await model.setLibraryRemoved(selected, in: .media, removed: true)), "bulk catalog removal is not limited by download-history retention")
        let bulkRestart = LibraryManagementFixture.model(state, preferences)
        try expect(bulkRestart.mediaLibrary.count == 502 && bulkRestart.mediaLibrary.filter(\.isLibraryRemoved).count == 501 &&
                   bulkRestart.mediaLibrary.first { $0.id == many.last!.id }?.isLibraryRemoved == false,
                   "all 501 tombstones survive restart while the unselected entry remains active")
        try expect((await bulkRestart.setLibraryRemoved(selected, in: .media, removed: false)) && bulkRestart.mediaLibrary.allSatisfy { !$0.isLibraryRemoved },
                   "bulk restore retains every original entry beyond the history limit")

        // The old asynchronous write is already queued when removal commits.
        model.mediaLibrary = [media]; model.saveWorkspace()
        try expect((await model.setLibraryRemoved([media.id], in: .media, removed: true)), "catalog commit drains earlier queued saves")
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterLateCompletion = LibraryManagementFixture.model(state, preferences)
        try expect(model.mediaLibrary[0].isLibraryRemoved && afterLateCompletion.mediaLibrary.first { $0.id == media.id }?.isLibraryRemoved == true,
                   "a delayed save completion cannot roll back the committed removal")
    }

    @MainActor private static func libraryReplayTests(root: URL, preferences: UserDefaults) async throws {
        let legacyState = try LibraryManagementFixture.state(root, "library-legacy")
        let legacy = LibraryManagementFixture.media(try LibraryManagementFixture.file(legacyState, "legacy.png"))
        let oldData = try JSONEncoder().encode(WorkspaceSnapshot(input: "legacy draft", items: [legacy], history: [legacy], logs: []))
        try expect(!String(decoding: oldData, as: UTF8.self).contains("libraryRemovedAt"), "legacy fixture really omits the new optional field")
        try oldData.write(to: legacyState)
        let migrated = LibraryManagementFixture.model(legacyState, preferences)
        try expect(migrated.mediaLibrary.count == 1 && !migrated.mediaLibrary[0].isLibraryRemoved && migrated.input == "legacy draft",
                   "old workspace records decode and migrate without a removal timestamp")
        try expect((await migrated.setLibraryRemoved([legacy.id], in: .media, removed: true)), "migrated media can be removed")
        migrated.clearDownloadRecords()
        let afterClear = LibraryManagementFixture.model(legacyState, preferences)
        try expect(afterClear.downloads.isEmpty && afterClear.mediaLibrary[0].isLibraryRemoved, "clearing download history preserves media tombstones")
        // A retained old workspace can reappear after a previously interrupted save.
        try oldData.write(to: legacyState)
        let replayedLegacy = LibraryManagementFixture.model(legacyState, preferences)
        try expect(replayedLegacy.mediaLibrary.count == 1 && replayedLegacy.mediaLibrary[0].isLibraryRemoved,
                   "replaying legacy workspace history cannot resurrect an independently removed media entry")

        let schemaState = try LibraryManagementFixture.state(root, "library-schema-one")
        let schemaMedia = LibraryManagementFixture.media(try LibraryManagementFixture.file(schemaState, "schema-one.png"))
        var schemaOne = MediaLibraryStore.Snapshot(items: [schemaMedia]); schemaOne.schema = 1
        let schemaOneBytes = try JSONEncoder().encode(schemaOne)
        let schemaLibrary = schemaState.deletingLastPathComponent().appendingPathComponent("media-library.json")
        try schemaOneBytes.write(to: schemaLibrary)
        let schemaMigrated = LibraryManagementFixture.model(schemaState, preferences)
        try expect(schemaMigrated.mediaLibrary.map(\.id) == [schemaMedia.id] && !schemaMigrated.mediaLibrary[0].isLibraryRemoved,
                   "schema-one media catalogs remain readable without optional removal markers")
        try expect((await schemaMigrated.setLibraryRemoved([schemaMedia.id], in: .media, removed: true)), "schema-one media can be removed")
        let schemaObject = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaLibrary)) as? [String: Any]
        let schemaReloaded = try MediaLibraryStore.read(schemaLibrary)
        try expect(schemaObject?["schema"] as? Int == 2 && schemaReloaded?.first?.isLibraryRemoved == true,
                   "the first catalog change writes schema two and durably preserves its removal marker")

        let state = try LibraryManagementFixture.state(root, "library-pruned-replay")
        let first = try LibraryManagementFixture.file(state, "full-a.png"), second = try LibraryManagementFixture.file(state, "full-b.png")
        var original = LibraryManagementFixture.media(first, name: "group"); original.additionalURLs = [second]
        var recent = original; recent.id = UUID(); recent.createdAt = original.createdAt.addingTimeInterval(1)
        recent.finishedAt = original.finishedAt!.addingTimeInterval(1)
        let model = LibraryManagementFixture.model(state, preferences)
        model.upsertMedia(original); model.upsertMedia(recent)
        let unrelatedFile = try LibraryManagementFixture.file(state, "unrelated.png")
        var unrelated = recent; unrelated.id = UUID(); unrelated.savedURL = unrelatedFile; unrelated.additionalURLs = nil
        unrelated.createdAt = recent.createdAt.addingTimeInterval(1); unrelated.finishedAt = recent.finishedAt!.addingTimeInterval(1)
        model.upsertMedia(unrelated)
        try FileManager.default.removeItem(at: first)
        model.items = [recent]; model.preview(recent)
        // Explicitly model history written by the old path-pruning version.
        model.items[0].savedURL = second; model.items[0].additionalURLs = nil
        model.items[0].incompleteFileList = nil
        try expect(model.items[0].id != original.id && model.items[0].localURLs == [second], "fixture has a new history ID with pruned attachments")
        try expect((await model.setLibraryRemoved([original.id], in: .media, removed: true)), "complete retained group can be removed independently")
        model.persistWorkspace()
        let restarted = LibraryManagementFixture.model(state, preferences)
        guard let retained = restarted.mediaLibrary.first(where: { $0.id == original.id }) else { throw TestFailure.failed("missing retained media group") }
        try expect(restarted.mediaLibrary.count == 2 && retained.isLibraryRemoved && Set(retained.localURLs) == Set([first, second]) &&
                   restarted.mediaLibrary.first { $0.id == unrelated.id }?.isLibraryRemoved == false,
                   "same-save matching preserves tombstones and full groups across different IDs and pruned history")
        var moves: [URL] = []
        let deleting = LibraryManagementFixture.model(state, preferences, recycle: { moves.append($0); try LibraryManagementFixture.recycle($0) })
        try Data("restored attachment".utf8).write(to: first)
        let request = try LibraryManagementFixture.request(deleting, ids: [recent.id], in: .downloads)
        try expect(Set(request.files) == Set([first, second]), "download deletion confirmation expands the unique retained saved copy")
        try expect(deleting.confirmFileTrash(request) && Set(moves) == Set([first, second]) && moves.count == 2 &&
                   !deleting.downloads.contains { $0.id == recent.id } && deleting.mediaLibrary.first { $0.id == original.id }?.isLibraryRemoved == true &&
                   FileManager.default.fileExists(atPath: unrelatedFile.path), "download trash clears only its record, preserves library tombstones and never expands a different same-source save")
    }

    @MainActor private static func libraryRemovalFailureTests(root: URL, pdf: URL, preferences: UserDefaults) async throws {
        for collection in [LibraryCollection.documents, .media] {
            let name = collection == .documents ? "documents" : "media"
            let state = try LibraryManagementFixture.state(root, "library-blocked-" + name)
            let model = LibraryManagementFixture.model(state, preferences)
            let file = state.deletingLastPathComponent().appendingPathComponent("entry." + (collection == .documents ? "pdf" : "png"))
            if collection == .documents { try FileManager.default.copyItem(at: pdf, to: file) } else { try Data("media".utf8).write(to: file) }
            let media = LibraryManagementFixture.media(file)
            let paper = LibraryPaper(DownloadItem(original: "local", state: .saved, savedURL: file, documentTitle: "Local"))
            if collection == .documents { model.papers = [paper] } else { model.mediaLibrary = [media] }
            model.persistWorkspace()
            let id = collection == .documents ? paper.id : media.id
            let library = state.deletingLastPathComponent().appendingPathComponent(collection == .documents ? "library.json" : "media-library.json")
            let originalBytes = try Data(contentsOf: library)
            try FileManager.default.removeItem(at: library)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try expect(!(await model.setLibraryRemoved([id], in: collection, removed: true)) && model.libraryUndo == nil,
                       "failed \(name) commit does not publish removal or undo")
            try expect(collection == .documents ? !model.papers[0].removed : !model.mediaLibrary[0].isLibraryRemoved,
                       "failed removal keeps the in-memory entry active")
            try FileManager.default.removeItem(at: library); try originalBytes.write(to: library)
            try expect((await model.setLibraryRemoved([id], in: collection, removed: true)), "removal can be retried after storage recovery")
            let removedBytes = try Data(contentsOf: library)
            try FileManager.default.removeItem(at: library); try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try expect(!(await model.undoLibraryRemoval()) && model.libraryUndo != nil, "failed undo remains available for retry")
            try expect(collection == .documents ? model.papers[0].removed : model.mediaLibrary[0].isLibraryRemoved,
                       "failed restore does not falsely publish an active entry")
            try FileManager.default.removeItem(at: library); try removedBytes.write(to: library)
            try expect((await model.undoLibraryRemoval()), "undo succeeds after the store becomes writable")

            let future = Data((collection == .documents ? "{\"schema\":99,\"papers\":[]}" : "{\"schema\":99,\"items\":[]}").utf8)
            try future.write(to: library)
            var trashCalls = 0
            let readOnly = LibraryManagementFixture.model(state, preferences, recycle: { _ in trashCalls += 1 })
            try expect(!(await readOnly.setLibraryRemoved([id], in: collection, removed: true)) && (try Data(contentsOf: library)) == future,
                       "future-schema \(name) stores remain read-only and byte-preserved")
            readOnly.items = [media]
            let request = try LibraryManagementFixture.request(readOnly, ids: [media.id], in: .downloads)
            try expect(!readOnly.canTrashFiles([media.id], in: .downloads) && !readOnly.confirmFileTrash(request) && trashCalls == 0 &&
                       FileManager.default.fileExists(atPath: file.path) && (try Data(contentsOf: library)) == future,
                       "future-schema catalogs also prevent file trashing and retain the original file and bytes")
        }
    }

    @MainActor private static func libraryFileTrashTests(root: URL, pdf: URL, preferences: UserDefaults) async throws {
        let state = try LibraryManagementFixture.state(root, "library-trash-shared")
        let real = state.deletingLastPathComponent().appendingPathComponent("real"), alias = state.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let file = real.appendingPathComponent("shared.png"), aliasFile = alias.appendingPathComponent("shared.png")
        try Data("shared".utf8).write(to: file)
        let untouched = try LibraryManagementFixture.file(state, "untouched.png")
        var group = LibraryManagementFixture.media(aliasFile); group.additionalURLs = [file, file]
        var shared = LibraryManagementFixture.media(file, name: "shared-copy"); shared.additionalURLs = [untouched]
        var moves: [URL] = []
        let model = LibraryManagementFixture.model(state, preferences, recycle: { moves.append($0); try LibraryManagementFixture.recycle($0) })
        model.mediaLibrary = [group, shared]; model.items = [group, shared]; model.history = [group]; model.previewURL = aliasFile
        try expect((await model.setLibraryRemoved([group.id], in: .media, removed: true)), "selected group is removed before independent file deletion")
        let request = try LibraryManagementFixture.request(model, ids: [group.id], in: .media)
        try expect(request.files == [file] && moves.isEmpty && FileManager.default.fileExists(atPath: file.path), "requesting confirmation does not mutate files and deduplicates aliases")
        try expect(model.confirmFileTrash(request) && moves == [file] && model.pendingFileTrash == nil,
                   "explicit confirmation moves each physical path once")
        try expect(model.items.count == 2 && model.history.count == 1 && model.mediaLibrary.count == 2 &&
                   model.mediaLibrary.allSatisfy { $0.state == .missing } && model.mediaLibrary[0].isLibraryRemoved &&
                   model.mediaLibrary[0].localURLs == group.localURLs && model.previewURL == nil && FileManager.default.fileExists(atPath: untouched.path),
                   "shared references retain complete paths and removal flags, close the deleted preview and preserve unrelated attachments")
        let restarted = LibraryManagementFixture.model(state, preferences)
        try expect(restarted.mediaLibrary.count == 2 && restarted.mediaLibrary[0].isLibraryRemoved && restarted.mediaLibrary.allSatisfy { $0.state == .missing },
                   "trash and catalog-removal state survive a real model restart")
        try expect((await restarted.setLibraryRemoved([group.id], in: .media, removed: false)) && restarted.mediaLibrary[0].state == .missing,
                   "restoring a trashed catalog item does not pretend its file was restored from Trash")

        let paperFile = state.deletingLastPathComponent().appendingPathComponent("shared.pdf")
        try FileManager.default.copyItem(at: pdf, to: paperFile)
        let version = try ArxivReference.parse("2501.12345v2")
        let download = DownloadItem(original: "2501.12345", reference: try ArxivReference.parse("2501.12345"),
                                    metadata: PaperMetadata(reference: version, title: "Shared PDF", year: 2025, month: 1), state: .saved, savedURL: paperFile)
        var paper = LibraryPaper(download); paper.favorite = true; paper.tags = ["preserved"]; paper.removed = true
        var sharedPaper = paper; sharedPaper.id = UUID(); sharedPaper.removed = false
        model.items = [download]; model.history = [download]; model.papers = [paper, sharedPaper]; model.persistWorkspace()
        let paperRequest = try LibraryManagementFixture.request(model, ids: [paper.id, sharedPaper.id], in: .documents)
        try expect(paperRequest.files == [paperFile] && model.confirmFileTrash(paperRequest) && model.papers.allSatisfy(\.missing) && model.papers[0].removed &&
                   model.papers[0].tags == ["preserved"] && model.items[0].restoreReference == version && model.history[0].restoreReference == version,
                   "document trash updates all shared references and preserves organization and the exact saved arXiv version")
        try expect((await model.setLibraryRemoved([paper.id], in: .documents, removed: false)) && model.papers[0].missing,
                   "restoring a removed document preserves its missing-file state")

        let staleFile = try LibraryManagementFixture.file(state, "stale.png"), replacement = try LibraryManagementFixture.file(state, "replacement.png")
        let stale = LibraryManagementFixture.media(staleFile)
        model.items = [stale]; model.history = []; model.mediaLibrary = []
        let staleRequest = try LibraryManagementFixture.request(model, ids: [stale.id], in: .downloads)
        model.items[0].savedURL = replacement
        let previousMoves = moves.count
        try expect(!model.confirmFileTrash(staleRequest) && moves.count == previousMoves && FileManager.default.fileExists(atPath: staleFile.path) &&
                   FileManager.default.fileExists(atPath: replacement.path), "stale confirmation cannot delete a file after the selected record changed paths")
        model.items = [stale]
        let cancelled = try LibraryManagementFixture.request(model, ids: [stale.id], in: .downloads)
        model.pendingFileTrash = nil
        try expect(!model.confirmFileTrash(cancelled) && moves.count == previousMoves && FileManager.default.fileExists(atPath: staleFile.path),
                   "a cancelled confirmation token cannot later delete files")
        let superseded = try LibraryManagementFixture.request(model, ids: [stale.id], in: .downloads)
        let current = try LibraryManagementFixture.request(model, ids: [stale.id], in: .downloads)
        try expect(!model.confirmFileTrash(superseded) && model.pendingFileTrash?.id == current.id && moves.count == previousMoves,
                   "an older confirmation cannot delete files or dismiss its replacement")
        try expect(model.confirmFileTrash(current) && moves.count == previousMoves + 1 && !model.confirmFileTrash(current) &&
                   FileManager.default.fileExists(atPath: replacement.path), "the current token is single-use and affects only its selected file")

        let batchA = try LibraryManagementFixture.file(state, "batch-a.png"), batchB = try LibraryManagementFixture.file(state, "batch-b.png")
        let itemA = LibraryManagementFixture.media(batchA, name: "batch-a"), itemB = LibraryManagementFixture.media(batchB, name: "batch-b")
        let unselected = LibraryManagementFixture.media(replacement, name: "unselected")
        model.items = [itemA, itemB, unselected]; model.history = [itemA, itemB]; model.mediaLibrary = [itemA, itemB, unselected]
        let batch = try LibraryManagementFixture.request(model, ids: [itemA.id, itemB.id], in: .media)
        try expect(Set(batch.files) == Set([batchA, batchB]) && model.confirmFileTrash(batch) && model.items.count == 3 && model.history.count == 2 &&
                   model.mediaLibrary.count == 3 && model.items[0].state == .missing && model.items[1].state == .missing && model.items[2].state == .saved &&
                   FileManager.default.fileExists(atPath: replacement.path), "batch file deletion retains every record and leaves unselected files usable")
    }

    @MainActor private static func downloadFileTrashClearsRecordTests(root: URL, pdf: URL, preferences: UserDefaults) throws {
        let state = try LibraryManagementFixture.state(root, "download-trash-clear")
        let first = try LibraryManagementFixture.file(state, "first.png"), second = try LibraryManagementFixture.file(state, "second.png")
        let untouched = try LibraryManagementFixture.file(state, "untouched.png")
        var group = LibraryManagementFixture.media(first); group.additionalURLs = [second, first]
        let shared = LibraryManagementFixture.media(first, name: "shared"), other = LibraryManagementFixture.media(untouched, name: "other")
        var moves: [URL] = []
        let model = LibraryManagementFixture.model(state, preferences, recycle: { moves.append($0); try LibraryManagementFixture.recycle($0) })
        model.items = [group, shared, other]; model.history = [group, shared]
        model.mediaLibrary = [group, shared, other]
        model.input = "unfinished draft"; model.duplicateCount = 3
        model.previewURL = first; model.diagnosticItem = group
        model.record(.info, "Keep logs", item: group); model.persistWorkspace()
        let logs = model.logs.map(\.id), batch = model.batchID, animation = model.recordAnimation
        let request = try LibraryManagementFixture.request(model, ids: [group.id], in: .downloads)
        try expect(request.confirmationMessage.contains("同时清除对应下载记录"), "download Trash confirmation discloses record clearing")
        let language = AppLocalization.shared.language
        AppLocalization.shared.language = .english
        try expect(L(request.confirmationMessage).contains("download records will also be cleared"), "English confirmation discloses record clearing")
        AppLocalization.shared.language = language
        try expect(model.confirmFileTrash(request) && Set(moves) == Set([first, second]) && moves.count == 2 &&
                   model.items.map(\.id) == [shared.id, other.id] && model.history.map(\.id) == [shared.id],
                   "successful file Trash clears the selected ID from both current and historical records")
        try expect(model.items[0].state == .missing && model.items[1].state == .saved &&
                   model.mediaLibrary.count == 3 && model.mediaLibrary[0].state == .missing &&
                   model.mediaLibrary[0].localURLs == group.localURLs && FileManager.default.fileExists(atPath: untouched.path),
                   "shared references remain as missing, complete library paths and unrelated files are preserved")
        try expect(model.previewURL == nil && model.diagnosticItem == nil && model.recordAnimation != animation &&
                   model.input == "unfinished draft" && model.logs.map(\.id) == logs && model.batchID == batch && model.duplicateCount == 3,
                   "combined removal closes deleted content and animates without clearing drafts, logs or list context")
        let restarted = LibraryManagementFixture.model(state, preferences)
        try expect(!restarted.downloads.contains { $0.id == group.id } && restarted.downloads.count == 2 && restarted.mediaLibrary.count == 3,
                   "cleared download records stay cleared across restart while library entries remain")

        let paperState = try LibraryManagementFixture.state(root, "download-trash-clear-paper")
        let paperFile = paperState.deletingLastPathComponent().appendingPathComponent("paper.pdf")
        try FileManager.default.copyItem(at: pdf, to: paperFile)
        let paperDownload = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .saved, savedURL: paperFile)
        let papers = LibraryManagementFixture.model(paperState, preferences, recycle: LibraryManagementFixture.recycle)
        papers.items = [paperDownload]; papers.history = [paperDownload]; papers.upsertPaper(paperDownload)
        papers.changePaper(paperDownload.id) { $0.favorite = true; $0.read = true; $0.tags = ["keep"] }
        let paperRequest = try LibraryManagementFixture.request(papers, ids: [paperDownload.id], in: .downloads)
        try expect(papers.confirmFileTrash(paperRequest) && papers.downloads.isEmpty && papers.papers.count == 1 &&
                   papers.papers[0].missing && papers.papers[0].favorite && papers.papers[0].read && papers.papers[0].tags == ["keep"],
                   "trashing a downloaded PDF clears its download row and preserves library organization")
        let restoredPapers = LibraryManagementFixture.model(paperState, preferences)
        try expect(restoredPapers.downloads.isEmpty && restoredPapers.papers.count == 1 && restoredPapers.papers[0].missing,
                   "PDF record clearing and missing library state survive restart")
        print("PASS download Trash: successful clear, shared references, retained libraries, confirmation copy and restart")
    }

    @MainActor private static func libraryFileTrashFailureTests(root: URL, preferences: UserDefaults) throws {
        for blockedName in ["workspace.json", "library.json", "media-library.json"] {
            let state = try LibraryManagementFixture.state(root, "trash-blocked-" + blockedName)
            let file = try LibraryManagementFixture.file(state, "preserved.png")
            let media = LibraryManagementFixture.media(file)
            var calls = 0
            let model = LibraryManagementFixture.model(state, preferences, recycle: { _ in calls += 1 })
            model.items = [media]; model.upsertMedia(media)
            // Both libraries are dirty so a failed preflight flush cannot hide
            // behind an unrelated previous successful store write.
            model.papers = []
            let request = try LibraryManagementFixture.request(model, ids: [media.id], in: .downloads)
            try FileManager.default.createDirectory(at: state.deletingLastPathComponent().appendingPathComponent(blockedName), withIntermediateDirectories: true)
            try expect(!model.confirmFileTrash(request) && calls == 0 && model.downloads.count == 1 && FileManager.default.fileExists(atPath: file.path),
                       "\(blockedName) preflight failure prevents every file move and retains recovery records")
        }
        let state = try LibraryManagementFixture.state(root, "trash-partial")
        let first = try LibraryManagementFixture.file(state, "a.png"), second = try LibraryManagementFixture.file(state, "b.png")
        var group = LibraryManagementFixture.media(first); group.additionalURLs = [second]
        var calls = 0
        let model = LibraryManagementFixture.model(state, preferences, recycle: { file in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
            try LibraryManagementFixture.recycle(file)
        })
        model.items = [group]; model.history = [group]; model.upsertMedia(group)
        let request = try LibraryManagementFixture.request(model, ids: [group.id], in: .downloads)
        model.busy = true
        try expect(!model.confirmFileTrash(request) && calls == 0, "download activity invalidates a previously opened deletion confirmation")
        model.busy = false
        try expect(!model.confirmFileTrash(request) && calls == 2 && model.items[0].state == .missing &&
                   model.mediaLibrary[0].state == .missing && model.mediaLibrary[0].localURLs == group.localURLs &&
                   !FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                   "partial trash failure reports failure and retains the full group plus surviving files")
        let restarted = LibraryManagementFixture.model(state, preferences, recycle: LibraryManagementFixture.recycle)
        try expect(restarted.downloads.count == 1 && restarted.mediaLibrary[0].localURLs == group.localURLs && restarted.mediaLibrary[0].state == .missing,
                   "partial deletion recovery survives restart")
        let retry = try LibraryManagementFixture.request(restarted, ids: [group.id], in: .downloads)
        try expect(restarted.confirmFileTrash(retry) && restarted.downloads.isEmpty && restarted.mediaLibrary.count == 1 && !FileManager.default.fileExists(atPath: second.path),
                   "successful retry skips missing files, clears the download record and keeps the catalog entry")

        let unsafeState = try LibraryManagementFixture.state(root, "trash-unsafe")
        let safe = try LibraryManagementFixture.file(unsafeState, "a-safe.png")
        let directory = unsafeState.deletingLastPathComponent().appendingPathComponent("z-directory.png")
        let symlink = unsafeState.deletingLastPathComponent().appendingPathComponent("z-symlink.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: safe)
        for unsafe in [directory, symlink] {
            var record = LibraryManagementFixture.media(safe); record.additionalURLs = [unsafe]
            var calls = 0
            let guarded = LibraryManagementFixture.model(unsafeState, preferences, recycle: { _ in calls += 1 })
            guarded.items = [record]; guarded.history = []; guarded.mediaLibrary = []
            let request = try LibraryManagementFixture.request(guarded, ids: [record.id], in: .downloads)
            try expect(!guarded.confirmFileTrash(request) && calls == 0 && FileManager.default.fileExists(atPath: safe.path),
                       "whole-group validation rejects directories or final symlinks before moving even safe siblings")
        }
        var remoteParts = URLComponents(string: "https://example.com")!; remoteParts.path = safe.path
        let remote = DownloadItem(original: "remote", state: .saved, savedURL: remoteParts.url!)
        var remoteCalls = 0
        let remoteModel = DownloadModel(preferences: preferences, recycleFile: { _ in remoteCalls += 1 })
        remoteModel.items = [remote]
        let remoteRequest = try LibraryManagementFixture.request(remoteModel, ids: [remote.id], in: .downloads)
        try expect(!remoteModel.confirmFileTrash(remoteRequest) && remoteCalls == 0 && FileManager.default.fileExists(atPath: safe.path),
                   "remote URLs cannot target a coincidentally matching local filesystem path")

        let finalState = try LibraryManagementFixture.state(root, "trash-final-save")
        let finalFile = try LibraryManagementFixture.file(finalState, "entry.png")
        let finalItem = LibraryManagementFixture.media(finalFile)
        let final = LibraryManagementFixture.model(finalState, preferences, recycle: { file in
            try LibraryManagementFixture.recycle(file)
            try FileManager.default.removeItem(at: finalState)
            try FileManager.default.createDirectory(at: finalState, withIntermediateDirectories: true)
        })
        final.items = [finalItem]; final.upsertMedia(finalItem)
        let finalRequest = try LibraryManagementFixture.request(final, ids: [finalItem.id], in: .downloads)
        try expect(!final.confirmFileTrash(finalRequest) && final.downloads.count == 1 && final.items[0].state == .missing &&
                   final.mediaLibrary[0].localURLs == [finalFile] && final.persistenceNotice != nil,
                   "a final save failure after trashing cannot report success or discard recovery paths")
    }
}
