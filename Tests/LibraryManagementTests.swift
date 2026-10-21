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
    @MainActor static func largeLibraryFileRefreshTests(root: URL, pdf: URL) throws {
        let suite = "folioak-large-file-refresh-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("large-file-refresh")
        let real = folder.appendingPathComponent("real"), alias = folder.appendingPathComponent("alias")
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let file = real.appendingPathComponent("shared.pdf"), aliasFile = alias.appendingPathComponent("shared.pdf")
        let unrelated = other.appendingPathComponent("shared.pdf")
        try FileManager.default.copyItem(at: pdf, to: file)
        try FileManager.default.copyItem(at: pdf, to: unrelated)
        let model = DownloadModel(preferences: preferences, recycleFile: LibraryManagementFixture.recycle)
        model.papers = (0..<20_000).map { index in
            let url = index < 100 ? (index.isMultiple(of: 2) ? file : aliasFile)
                : index == 100 ? unrelated : real.appendingPathComponent("document-\(index).pdf")
            return LibraryPaper(DownloadItem(original: "document-\(index)", state: .saved, savedURL: url))
        }
        model.items = [model.papers[0].downloadItem, model.papers[1].downloadItem, model.papers[100].downloadItem]
        model.history = model.items
        model.previewURL = aliasFile
        var paperPublications = 0, itemPublications = 0, historyPublications = 0
        let observations = [model.$papers.dropFirst().sink { _ in paperPublications += 1 },
                            model.$items.dropFirst().sink { _ in itemPublications += 1 },
                            model.$history.dropFirst().sink { _ in historyPublications += 1 }]
        defer { observations.forEach { $0.cancel() } }
        let request = try LibraryManagementFixture.request(model, ids: [model.papers[0].id], in: .documents)
        let start = Date()
        try expect(model.confirmFileTrash(request), "large-library file removal succeeds")
        let elapsed = Date().timeIntervalSince(start) * 1000
        try expect(model.papers.prefix(100).allSatisfy { $0.missing && $0.removed } &&
                   model.papers.dropFirst(100).allSatisfy { !$0.missing && !$0.removed } &&
                   model.items.map(\.id) == [model.papers[100].id] && model.items[0].state == .saved &&
                   model.history.map(\.id) == [model.papers[100].id] && model.previewURL == nil &&
                   FileManager.default.fileExists(atPath: unrelated.path),
                   "20k cleanup removes shared and aliased records while preserving same-name files in other folders")
        try expect(model.fileRefreshPathResolutions == 3 && paperPublications == 1 && itemPublications == 1 && historyPublications == 1,
                   "file refresh resolves only three relevant parents and publishes each affected collection once")
        print(String(format: "BENCH 20k file refresh: %.2f ms; path resolutions %d; collection publications %d", elapsed,
                     model.fileRefreshPathResolutions, paperPublications + itemPublications + historyPublications))
    }

    @MainActor static func libraryManagementTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-library-management-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        try await libraryRemovalTests(root: root, pdf: pdf, preferences: preferences)
        try await libraryReplayTests(root: root, preferences: preferences)
        try await libraryRemovalFailureTests(root: root, pdf: pdf, preferences: preferences)
        try await libraryFileTrashTests(root: root, pdf: pdf, preferences: preferences)
        try fileTrashDuringOtherTasksTests(root: root, preferences: preferences)
        try await trashFilesDuringDownloadTests(root: root, pdf: pdf, preferences: preferences)
        try downloadFileTrashClearsRecordTests(root: root, pdf: pdf, preferences: preferences)
        try fileTrashScopeTests(root: root, pdf: pdf, preferences: preferences)
        try libraryFileTrashFailureTests(root: root, preferences: preferences)
        print("PASS library management: asynchronous remove/restore/undo, legacy migration, replay tombstones, bulk retention, shared-file trash, stale confirmations and failure recovery")
    }

    @MainActor private static func fileTrashDuringOtherTasksTests(root: URL, preferences: UserDefaults) throws {
        let state = try LibraryManagementFixture.state(root, "trash-during-download")
        var moves: [URL] = []
        var active = LibraryManagementFixture.media(state.deletingLastPathComponent().appendingPathComponent("active.png"), name: "other")
        active.state = .downloading
        for collection in [RecordCollection.downloads, .media, .documents] {
            let file = try LibraryManagementFixture.file(state, "completed-\(collection)." + (collection == .documents ? "pdf" : "png"))
            let completed = LibraryManagementFixture.media(file)
            let model = LibraryManagementFixture.model(state, preferences, recycle: { moves.append($0); try LibraryManagementFixture.recycle($0) })
            model.items = [active]; model.history = [completed]; model.mediaLibrary = []; model.papers = []
            if collection == .documents { model.upsertPaper(completed) } else { model.upsertMedia(completed) }
            model.busy = true
            try expect(model.canTrashFiles([completed.id], in: collection), "unrelated active task permits completed file trash in \(collection)")
            let request = try LibraryManagementFixture.request(model, ids: [completed.id], in: collection)
            try expect(model.canConfirmFileTrash(request) && model.confirmFileTrash(request) && model.busy && model.items.count == 1 &&
                       model.items[0].state == .downloading && moves.last == file &&
                       model.history.isEmpty &&
                       (collection == .documents ? model.papers[0].missing && model.papers[0].removed :
                           model.mediaLibrary[0].state == .missing && model.mediaLibrary[0].isLibraryRemoved),
                       "each Trash entry point clears completed history and hides catalog rows without changing the unrelated worker")
        }

        // A shared file is protected even through another record, an attachment,
        // or a symlinked parent; selecting a safe sibling cannot bypass the guard.
        let shared = try LibraryManagementFixture.file(state, "shared.png")
        let safe = try LibraryManagementFixture.file(state, "safe.png")
        let alias = state.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: state.deletingLastPathComponent())
        let retained = LibraryManagementFixture.media(shared)
        let sibling = LibraryManagementFixture.media(safe, name: "safe")
        let model = LibraryManagementFixture.model(state, preferences, recycle: { moves.append($0); try LibraryManagementFixture.recycle($0) })
        model.history = [retained, sibling]; model.mediaLibrary = [retained, sibling]; model.papers = []; model.busy = true
        let before = moves.count
        for taskState: ItemState in [.queued, .coordinating, .metadata, .checkingLocal, .downloading, .validating, .retrying(1), .waiting(Date())] {
            active.state = taskState; active.additionalURLs = [alias.appendingPathComponent("shared.png")]
            model.items = [active]
            for collection in [RecordCollection.downloads, .media] {
                try expect(!model.canTrashFiles([retained.id], in: collection) && !model.canTrashFiles([retained.id, sibling.id], in: collection),
                           "shared file and whole selection stay protected during \(taskState) in \(collection)")
                model.requestFileTrash([retained.id], in: collection)
                try expect(model.pendingFileTrash == nil, "direct request also protects shared active files")
            }
        }
        active.additionalURLs = nil; active.savedURL = nil; active.id = retained.id
        model.items = [active]
        try expect(!model.canTrashFiles([retained.id], in: .media), "same-ID retry is protected before it has local paths")
        active.id = UUID(); active.directURL = retained.directURL; model.items = [active]
        try expect(!model.canTrashFiles([retained.id], in: .downloads), "new task for the same source is protected before path discovery")

        model.items = []
        let stale = try LibraryManagementFixture.request(model, ids: [retained.id], in: .downloads)
        model.items = [active]
        try expect(!model.confirmFileTrash(stale) && moves.count == before && FileManager.default.fileExists(atPath: shared.path),
                   "starting a related task after the dialog opens invalidates confirmation without touching any files")
        model.pendingFileTrash = nil
        model.items = []
        let independent = try LibraryManagementFixture.request(model, ids: [sibling.id], in: .downloads)
        model.items = [active]
        try expect(model.confirmFileTrash(independent) && moves.count == before + 1 && FileManager.default.fileExists(atPath: shared.path),
                   "starting an unrelated task after the dialog opens still permits confirmation")

        let paperFile = try LibraryManagementFixture.file(state, "protected.pdf")
        let ref = try ArxivReference.parse("1706.03762v1")
        let download = DownloadItem(original: ref.identifier, reference: ref, state: .saved, savedURL: paperFile)
        var paper = LibraryPaper(download); paper.id = UUID()
        model.papers = [paper]
        for version in [nil, 1, 2] as [Int?] {
            let reference = ArxivReference(baseID: ref.baseID, version: version)
            let task = DownloadItem(original: reference.identifier, reference: reference, state: .queued)
            model.items = [task]
            try expect(model.canTrashFiles([paper.id], in: .documents) == (version == 2),
                       "arXiv latest and matching-version tasks protect an existing paper; distinct explicit versions stay independent")
        }
        model.items = [DownloadItem(id: download.id, original: "retry", state: .queued)]
        try expect(!model.canTrashFiles([paper.id], in: .documents), "library taskID protects a pathless retry even without source metadata")
        paper.reference = ArxivReference(baseID: ref.baseID, version: 2); model.papers = [paper]
        var latest = DownloadItem(original: ref.baseID, reference: ArxivReference(baseID: ref.baseID, version: nil),
                                  metadata: PaperMetadata(reference: ref, title: "old version", year: 2017, month: 6), state: .queued)
        model.items = [latest]
        try expect(!model.canTrashFiles([paper.id], in: .documents), "stale metadata on a latest-version retry cannot bypass source protection")
        latest.restoreReference = ref; model.items = [latest]
        try expect(model.canTrashFiles([paper.id], in: .documents), "explicit restore version follows the worker's actual source")
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
            readOnly.requestFileTrash([media.id], in: .downloads)
            try expect(readOnly.pendingFileTrash == nil, "read-only catalogs reject opening a destructive confirmation")
            let request = FileTrashRequest(collection: .downloads, ids: [media.id], files: [file])
            readOnly.pendingFileTrash = request
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
        try expect(model.items.map(\.id) == [shared.id] && model.history.isEmpty && model.mediaLibrary.count == 2 &&
                   model.mediaLibrary.allSatisfy { $0.state == .missing } && model.mediaLibrary[0].isLibraryRemoved &&
                   !model.mediaLibrary[1].isLibraryRemoved && model.mediaLibrary[0].localURLs == group.localURLs &&
                   model.previewURL == nil && FileManager.default.fileExists(atPath: untouched.path),
                   "fully trashed groups disappear while partially shared groups retain paths and surviving attachments")
        let restarted = LibraryManagementFixture.model(state, preferences)
        try expect(restarted.downloads.map(\.id) == [shared.id] && restarted.mediaLibrary.count == 2 &&
                   restarted.mediaLibrary[0].isLibraryRemoved && !restarted.mediaLibrary[1].isLibraryRemoved &&
                   restarted.mediaLibrary.allSatisfy { $0.state == .missing },
                   "full-group cleanup and partial-group recovery survive restart")
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
        try expect(paperRequest.files == [paperFile] && model.confirmFileTrash(paperRequest) &&
                   model.papers.allSatisfy { $0.missing && $0.removed && $0.reference == version } &&
                   model.papers[0].tags == ["preserved"] && model.downloads.isEmpty,
                   "document trash clears shared download rows and hides both catalogs while retaining organization and exact arXiv version")
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
        try expect(Set(batch.files) == Set([batchA, batchB]) && model.confirmFileTrash(batch) && model.items.map(\.id) == [unselected.id] &&
                   model.history.isEmpty && model.mediaLibrary.count == 3 && model.mediaLibrary.prefix(2).allSatisfy(\.isLibraryRemoved) &&
                   !model.mediaLibrary[2].isLibraryRemoved && model.items[0].state == .saved &&
                   FileManager.default.fileExists(atPath: replacement.path), "batch file deletion clears all fully affected records and leaves unselected files usable")
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
        try expect([RecordCollection.documents, .media].allSatisfy {
            FileTrashRequest(collection: $0, ids: request.ids, files: request.files).confirmationMessage == request.confirmationMessage
        } && request.confirmationMessage.contains("从资料库移除"), "all three Trash entry points explain the same record cleanup")
        let language = AppLocalization.shared.language
        AppLocalization.shared.language = .english
        try expect(L(request.confirmationMessage).contains("download records will also be cleared"), "English confirmation discloses record clearing")
        AppLocalization.shared.language = language
        try expect(model.confirmFileTrash(request) && Set(moves) == Set([first, second]) && moves.count == 2 &&
                   model.items.map(\.id) == [other.id] && model.history.isEmpty,
                   "successful file Trash clears selected and fully shared current and historical records")
        try expect(model.items[0].state == .saved && model.mediaLibrary.count == 3 &&
                   model.mediaLibrary.prefix(2).allSatisfy { $0.state == .missing && $0.isLibraryRemoved } &&
                   !model.mediaLibrary[2].isLibraryRemoved && model.mediaLibrary[0].localURLs == group.localURLs &&
                   FileManager.default.fileExists(atPath: untouched.path),
                   "fully shared groups are hidden with complete recovery paths while unrelated files remain visible")
        try expect(model.previewURL == nil && model.diagnosticItem == nil && model.recordAnimation != animation &&
                   model.input == "unfinished draft" && model.logs.map(\.id) == logs && model.batchID == batch && model.duplicateCount == 3,
                   "combined removal closes deleted content and animates without clearing drafts, logs or list context")
        let restarted = LibraryManagementFixture.model(state, preferences)
        try expect(restarted.downloads.map(\.id) == [other.id] && restarted.mediaLibrary.count == 3 &&
                   restarted.mediaLibrary.filter { !$0.isLibraryRemoved }.map(\.id) == [other.id],
                   "cleared and fully shared download records do not return after restart and tombstones stay hidden")

        let paperState = try LibraryManagementFixture.state(root, "download-trash-clear-paper")
        let paperFile = paperState.deletingLastPathComponent().appendingPathComponent("paper.pdf")
        try FileManager.default.copyItem(at: pdf, to: paperFile)
        let paperDownload = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .saved, savedURL: paperFile)
        let papers = LibraryManagementFixture.model(paperState, preferences, recycle: LibraryManagementFixture.recycle)
        papers.items = [paperDownload]; papers.history = [paperDownload]; papers.upsertPaper(paperDownload)
        papers.changePaper(paperDownload.id) { $0.favorite = true; $0.read = true; $0.tags = ["keep"] }
        let paperRequest = try LibraryManagementFixture.request(papers, ids: [paperDownload.id], in: .downloads)
        try expect(papers.confirmFileTrash(paperRequest) && papers.downloads.isEmpty && papers.papers.count == 1 &&
                   papers.papers[0].missing && papers.papers[0].removed && papers.library.isEmpty &&
                   papers.papers[0].favorite && papers.papers[0].read && papers.papers[0].tags == ["keep"],
                   "trashing a downloaded PDF clears its download row and hides the library entry with organization intact")
        let restoredPapers = LibraryManagementFixture.model(paperState, preferences)
        try expect(restoredPapers.downloads.isEmpty && restoredPapers.library.isEmpty && restoredPapers.papers.count == 1 &&
                   restoredPapers.papers[0].missing && restoredPapers.papers[0].removed,
                   "PDF download clearing and hidden library recovery state survive restart")
        print("PASS download Trash: successful clear, shared references, retained libraries, confirmation copy and restart")
    }

    @MainActor private static func fileTrashScopeTests(root: URL, pdf: URL, preferences: UserDefaults) throws {
        for collection in [RecordCollection.downloads, .media] {
            let state = try LibraryManagementFixture.state(root, "trash-scope-\(collection)")
            let first = try LibraryManagementFixture.file(state, "first.png")
            let survivor = try LibraryManagementFixture.file(state, "survivor.png")
            let independent = try LibraryManagementFixture.file(state, "independent.png")
            let selected = LibraryManagementFixture.media(first, name: "selected")
            var partial = LibraryManagementFixture.media(first, name: "partial"); partial.additionalURLs = [survivor]
            var incomplete = LibraryManagementFixture.media(first, name: "incomplete"); incomplete.incompleteFileList = true
            var sameSource = selected; sameSource.id = UUID(); sameSource.savedURL = independent
            sameSource.createdAt = selected.createdAt.addingTimeInterval(1)
            sameSource.finishedAt = selected.finishedAt!.addingTimeInterval(1)
            let empty = DownloadItem(original: "no local paths", state: .failed)
            var stalePartial = partial; stalePartial.additionalURLs = nil
            let model = LibraryManagementFixture.model(state, preferences, recycle: LibraryManagementFixture.recycle)
            model.items = [selected, partial, incomplete, sameSource, empty]
            model.history = [selected, stalePartial, incomplete, sameSource, empty]
            model.mediaLibrary = [selected, partial, incomplete, sameSource]
            let request = try LibraryManagementFixture.request(model, ids: [selected.id], in: collection)
            try expect(request.files == [first] && model.confirmFileTrash(request), "scope fixture trashes only the confirmed path in \(collection)")
            let kept = Set([partial.id, incomplete.id, sameSource.id, empty.id])
            try expect(Set(model.items.map(\.id)) == kept && Set(model.history.map(\.id)) == kept &&
                       model.mediaLibrary.filter(\.isLibraryRemoved).map(\.id) == [selected.id],
                       "partial, unknown-length and empty groups are retained; source equality cannot expand cleanup")
            try expect(model.items.first { $0.id == partial.id }?.state == .missing &&
                       model.items.first { $0.id == incomplete.id }?.state == .missing &&
                       model.items.first { $0.id == sameSource.id }?.state == .saved &&
                       FileManager.default.fileExists(atPath: survivor.path) && FileManager.default.fileExists(atPath: independent.path),
                       "current complete group overrides its pruned history copy and every unconfirmed file survives")
            let restarted = LibraryManagementFixture.model(state, preferences)
            try expect(Set(restarted.downloads.map(\.id)) == kept &&
                       restarted.mediaLibrary.filter(\.isLibraryRemoved).map(\.id) == [selected.id],
                       "conservative group boundaries and explicit removal survive restart")

            // An incomplete legacy group can still be explicitly selected. Its
            // known paths are confirmed, without claiming other unknown copies.
            try Data("restored known path".utf8).write(to: first)
            let explicit = LibraryManagementFixture.model(state, preferences, recycle: LibraryManagementFixture.recycle)
            let explicitRequest = try LibraryManagementFixture.request(explicit, ids: [incomplete.id], in: collection)
            try expect(explicit.confirmFileTrash(explicitRequest) && !explicit.downloads.contains { $0.id == incomplete.id } &&
                       explicit.mediaLibrary.first { $0.id == incomplete.id }?.isLibraryRemoved == true &&
                       explicit.downloads.contains { $0.id == partial.id } && FileManager.default.fileExists(atPath: survivor.path),
                       "explicit selection can remove a legacy incomplete group without hiding a partially shared group")
        }

        let documentState = try LibraryManagementFixture.state(root, "trash-document-task-id")
        let documentFile = try LibraryManagementFixture.file(documentState, "selected.pdf")
        let otherDocument = try LibraryManagementFixture.file(documentState, "other-copy.pdf")
        let download = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"),
                                    state: .saved, savedURL: documentFile, incompleteFileList: true)
        var selectedPaper = LibraryPaper(download); selectedPaper.id = UUID()
        var sameSourcePaper = selectedPaper; sameSourcePaper.id = UUID(); sameSourcePaper.file = otherDocument
        let documents = LibraryManagementFixture.model(documentState, preferences, recycle: LibraryManagementFixture.recycle)
        documents.items = [download]; documents.history = [download]; documents.papers = [selectedPaper, sameSourcePaper]
        let documentRequest = try LibraryManagementFixture.request(documents, ids: [selectedPaper.id], in: .documents)
        try expect(documentRequest.files == [documentFile] && documents.confirmFileTrash(documentRequest) && documents.downloads.isEmpty &&
                   documents.papers[0].removed && !documents.papers[1].removed && FileManager.default.fileExists(atPath: otherDocument.path),
                   "document selection follows its taskID for incomplete downloads but never hides an unconfirmed same-source copy")
        let restartedDocuments = LibraryManagementFixture.model(documentState, preferences)
        try expect(restartedDocuments.downloads.isEmpty && restartedDocuments.library.map(\.id) == [sameSourcePaper.id],
                   "document taskID cleanup and the independent same-source copy survive restart")

        let state = try LibraryManagementFixture.state(root, "externally-missing-stays-visible")
        let image = try LibraryManagementFixture.file(state, "external.png")
        let paperFile = state.deletingLastPathComponent().appendingPathComponent("external.pdf")
        try FileManager.default.copyItem(at: pdf, to: paperFile)
        let media = LibraryManagementFixture.media(image)
        let paper = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .saved, savedURL: paperFile)
        let model = LibraryManagementFixture.model(state, preferences)
        model.items = [media, paper]; model.history = model.items; model.upsertMedia(media); model.upsertPaper(paper)
        try FileManager.default.removeItem(at: image); try FileManager.default.removeItem(at: paperFile)
        try expect(model.localFile(media) == nil && model.localFile(paper) == nil && model.downloads.count == 2 &&
                   model.downloads.allSatisfy { $0.state == .missing } && !model.mediaLibrary[0].isLibraryRemoved && !model.papers[0].removed,
                   "external file loss remains visible and never inherits explicit Trash cleanup")
        model.persistWorkspace()
        let restarted = LibraryManagementFixture.model(state, preferences)
        try expect(restarted.downloads.count == 2 && !restarted.mediaLibrary[0].isLibraryRemoved && !restarted.papers[0].removed,
                   "external missing-file recovery rows stay visible after restart")
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
        model.busy = true; model.items[0].state = .downloading
        try expect(!model.canConfirmFileTrash(request) && !model.confirmFileTrash(request) && calls == 0, "related download activity invalidates a previously opened deletion confirmation")
        model.items[0].state = .saved
        let partialRequest = try LibraryManagementFixture.request(model, ids: [group.id], in: .downloads)
        try expect(!model.confirmFileTrash(partialRequest) && calls == 2 && model.items[0].state == .missing &&
                   model.mediaLibrary[0].state == .missing && !model.mediaLibrary[0].isLibraryRemoved &&
                   model.mediaLibrary[0].localURLs == group.localURLs &&
                   !FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                   "partial trash failure reports failure and retains the full group plus surviving files")
        let restarted = LibraryManagementFixture.model(state, preferences, recycle: LibraryManagementFixture.recycle)
        try expect(restarted.downloads.count == 1 && restarted.mediaLibrary[0].localURLs == group.localURLs &&
                   restarted.mediaLibrary[0].state == .missing && !restarted.mediaLibrary[0].isLibraryRemoved,
                   "partial deletion leaves visible recovery rows across restart")
        let retry = try LibraryManagementFixture.request(restarted, ids: [group.id], in: .downloads)
        try expect(restarted.confirmFileTrash(retry) && restarted.downloads.isEmpty && restarted.mediaLibrary.count == 1 &&
                   restarted.mediaLibrary[0].isLibraryRemoved && !FileManager.default.fileExists(atPath: second.path),
                   "successful retry skips missing files, clears the download record and hides the catalog entry")

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

        for blockedName in ["workspace.json", "library.json", "media-library.json"] {
            let finalState = try LibraryManagementFixture.state(root, "trash-final-save-" + blockedName)
            let folder = finalState.deletingLastPathComponent()
            let image = try LibraryManagementFixture.file(finalState, "entry.png")
            let paperFile = try LibraryManagementFixture.file(finalState, "entry.pdf")
            let media = LibraryManagementFixture.media(image)
            let paper = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .saved, savedURL: paperFile)
            let blocked = folder.appendingPathComponent(blockedName)
            var calls = 0
            let final = LibraryManagementFixture.model(finalState, preferences, recycle: { file in
                try LibraryManagementFixture.recycle(file); calls += 1
                // The backup remains readable, but committing this specific
                // store fails after any earlier stores have been written.
                if calls == 2 { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path) }
            })
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path) }
            final.items = [media, paper]; final.history = final.items; final.upsertMedia(media); final.upsertPaper(paper)
            final.changePaper(paper.id) { $0.favorite = true; $0.tags = ["keep"] }
            let finalRequest = try LibraryManagementFixture.request(final, ids: [media.id, paper.id], in: .downloads)
            try expect(!final.confirmFileTrash(finalRequest) && calls == 2 && final.downloads.count == 2 &&
                       final.downloads.allSatisfy { $0.state == .missing } && !final.papers[0].removed &&
                       !final.mediaLibrary[0].isLibraryRemoved && final.mediaLibrary[0].localURLs == [image] &&
                       (final.notice != nil || final.persistenceNotice != nil || final.libraryNotice != nil || final.mediaLibraryNotice != nil),
                       "\(blockedName) failure after file moves keeps every recovery row visible and reports failure")
            let savedWorkspace = try WorkspaceStore.read(finalState)!
            let savedPapers = try LibraryStore.read(folder.appendingPathComponent("library.json"))!
            let savedMedia = try MediaLibraryStore.read(folder.appendingPathComponent("media-library.json"))!
            try expect(Set((savedWorkspace.items + savedWorkspace.history).map(\.id)) == [media.id, paper.id] &&
                       savedPapers.count == 1 && !savedPapers[0].removed && savedMedia.count == 1 && !savedMedia[0].isLibraryRemoved,
                       "\(blockedName) failure rolls back any earlier stores instead of leaving partial cleanup on disk")
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path)
            final.persistWorkspace()
            let restarted = LibraryManagementFixture.model(finalState, preferences)
            try expect(restarted.downloads.count == 2 && restarted.downloads.allSatisfy { $0.state == .missing } &&
                       !restarted.papers[0].removed && restarted.papers[0].favorite && restarted.papers[0].tags == ["keep"] &&
                       !restarted.mediaLibrary[0].isLibraryRemoved && !FileManager.default.fileExists(atPath: image.path) &&
                       !FileManager.default.fileExists(atPath: paperFile.path),
                       "after storage repair and restart all moved-file recovery paths and organization remain available")
        }
    }
}
