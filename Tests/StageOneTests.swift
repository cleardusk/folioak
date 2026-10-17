import AppKit
import SwiftUI

extension CoreTests {
    @MainActor static func stageOneRegressionTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-stage-one-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent("recoverable.pdf")
        try FileManager.default.copyItem(at: pdf, to: file)
        let reference = try ArxivReference.parse("1706.03762v1")
        let metadata = PaperMetadata(reference: reference, title: "Original source title", year: 2017, month: 6)
        let record = DownloadItem(original: reference.identifier, reference: reference, metadata: metadata,
            state: .saved, savedURL: file, pages: 1, documentTitle: "Original source title", preservesInput: true)
        let stateURL = root.appendingPathComponent("recovery/workspace.json")
        var opened: [URL] = [], revealed: [[URL]] = []
        let model = DownloadModel(preferences: prefs, opener: { opened.append($0); return true }, stateURL: stateURL,
            revealer: { revealed.append($0) })
        model.items = [record]; model.history = [record]; model.upsertPaper(record)
        model.changePaper(record.id) { $0.title = "Edited display title" }
        let detail = TaskDiagnosticView(model: model, item: record, libraryPaperID: record.id)
        try expect(detail.current.title == "Edited display title" && detail.current.metadata?.title == metadata.title,
            "detail uses edited title while preserving original metadata")
        try FileManager.default.removeItem(at: file)
        model.openFile(record)
        try expect(opened.isEmpty && model.items[0].savedURL == file && model.history[0].savedURL == file && model.papers[0].missing,
            "opening missing download preserves paths and marks document library")
        await model.persistWorkspaceAndWait()
        let restored = DownloadModel(preferences: prefs, opener: { opened.append($0); return true }, stateURL: stateURL)
        try expect(restored.items[0].savedURL == file && restored.papers[0].file == file && restored.papers[0].missing,
            "missing paths and library state survive restart")
        try FileManager.default.copyItem(at: pdf, to: file)
        restored.openPaper(restored.papers[0])
        try expect(opened == [file] && restored.items[0].state == .saved && !restored.papers[0].missing,
            "restored file opens from the library and repairs the download state")
        model.openFile(model.items[0], reveal: true)
        try expect(revealed == [[file]] && model.items[0].state == .saved, "Finder receives the recovered path")

        // Real old-version PDF records lost their only path, while the library
        // retained it. Opening either entry must recover, never invent success.
        var oldPDF = record; oldPDF.state = .missing; oldPDF.savedURL = nil
        model.items = [oldPDF]; model.history = [oldPDF]
        try FileManager.default.removeItem(at: file)
        model.openPaper(model.papers[0])
        try expect(model.items[0].state == .missing && model.items[0].savedURL == file && model.items[0].canRetry,
            "old pathless PDF stays retryable and recovers its original path while absent")
        model.items = [oldPDF]; model.history = [oldPDF]
        try FileManager.default.copyItem(at: pdf, to: file)
        model.openPaper(model.papers[0])
        try expect(model.items[0].state == .saved && model.history[0].savedURL == file,
            "old pathless PDF recovers through document-library open")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        var aliasPaper = model.papers[0]; aliasPaper.id = UUID(); aliasPaper.taskID = nil
        aliasPaper.file = alias.appendingPathComponent(file.lastPathComponent)
        model.papers.append(aliasPaper)
        try FileManager.default.removeItem(at: file); model.openFile(record)
        try expect(model.papers.allSatisfy(\.missing), "same-file library aliases share missing state")
        try FileManager.default.copyItem(at: pdf, to: file); model.openFile(record)
        try expect(model.papers.allSatisfy { !$0.missing }, "same-file aliases recover together")
        var oldVersion = record; oldVersion.id = UUID(); oldVersion.reference = ArxivReference(baseID: reference.baseID, version: nil)
        oldVersion.state = .missing; oldVersion.savedURL = root.appendingPathComponent("absent-version.pdf")
        oldVersion.error = "原位置的文件不存在，可重新下载。"; oldVersion.errorMessage = DiagnosticMessage(.invalidInput)
        model.items = [oldVersion]; model.preview(oldVersion)
        try expect(model.items[0].restoreReference == reference && model.items[0].errorMessage == nil,
            "missing record refresh retains exact version and clears outdated structured errors")

        let first = root.appendingPathComponent("attachment-a.png"), second = root.appendingPathComponent("attachment-b.png")
        try Data("a".utf8).write(to: first); try Data("b".utf8).write(to: second)
        let group = DownloadItem(original: "https://x.com/demo/status/1", directURL: URL(string: "https://x.com/demo/status/1"),
            state: .saved, savedURL: first, documentTitle: "Group", finishedAt: Date(), additionalURLs: [second], preservesInput: true)
        model.mediaLibrary = [group]
        var legacy = group; legacy.id = UUID(); legacy.savedURL = second; legacy.additionalURLs = nil
        legacy.state = .missing; legacy.incompleteFileList = true
        model.items = [legacy]; model.history = [legacy]
        try FileManager.default.removeItem(at: first)
        model.preview(legacy)
        try expect(model.previewURL == second && model.items[0].state == .missing && model.items[0].localURLs == [first, second] &&
            model.history[0].state == .missing && model.mediaLibrary[0].state == .missing,
            "unique retained media group repairs old pruned history across IDs without hiding missing attachments")
        await model.persistWorkspaceAndWait()
        try Data("restored a".utf8).write(to: first)
        let recovered = DownloadModel(preferences: prefs, stateURL: stateURL)
        recovered.preview(recovered.items[0])
        try expect(recovered.items[0].state == .saved && recovered.mediaLibrary[0].state == .saved && recovered.items[0].localURLs.count == 2,
            "complete media paths survive restart and recover together")
        let quick = QuickDownloadState(model: model)
        try expect(quick.recentItems.map(\.id) == [legacy.id], "quick results deduplicate active/history and include only quick downloads")
        quick.open(model.items[0], reveal: true)
        try expect(revealed.last == [first, second] && quick.resultError == nil, "quick Finder action reveals every recovered attachment")
        var removedMedia = group; removedMedia.state = .missing; removedMedia.libraryRemovedAt = Date()
        model.mediaLibrary = [removedMedia]
        let mediaRestore = Task { await model.setLibraryRemoved([group.id], in: .media, removed: false) }
        while !model.libraryMutationInProgress { await Task.yield() }
        model.mediaLibrary[0].documentTitle = "Edited during restore"
        try expect(await mediaRestore.value, "media restores asynchronously")
        await model.persistWorkspaceAndWait()
        try expect(model.mediaLibrary[0].state == .saved && !model.mediaLibrary[0].isLibraryRemoved &&
            model.mediaLibrary[0].title == "Edited during restore", "media restore retains concurrent metadata and merges recovered file state")
        // A completely pruned historical record also recovers from its unique saved group.
        var pathless = legacy; pathless.savedURL = nil; pathless.additionalURLs = nil; pathless.incompleteFileList = true
        model.items = [pathless]; model.history = [pathless]; model.preview(model.mediaLibrary[0])
        try expect(model.items[0].state == .saved && model.items[0].localURLs == [first, second] && model.history[0].localURLs == [first, second],
            "old history with every path pruned recovers from retained media")
        print("PASS stage one: edited detail title, missing/recovered PDF, media collection recovery across IDs/restart and quick result actions")
    }

    @MainActor static func largeLibraryRegressionTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-large-library-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let state = root.appendingPathComponent("large-library/workspace.json")
        let model = DownloadModel(preferences: prefs, stateURL: state)
        model.papers = (0..<20_000).map { n in
            var paper = LibraryPaper(DownloadItem(original: "paper-\(n)", state: .saved, savedURL: pdf,
                documentTitle: "Paper \((n * 7919) % 20000)", createdAt: Date(timeIntervalSince1970: Double(n))))
            paper.tags = n.isMultiple(of: 2) ? ["even"] : []; paper.favorite = n.isMultiple(of: 3)
            return paper
        }
        await model.persistWorkspaceAndWait()
        let cache = model.libraryQueries
        func query(_ text: String = "paper", sort: LibrarySort = .title, filter: LibraryFilter = .all, tag: String? = nil) -> LibraryQueryCache.Documents {
            cache.documents(model.papers, revision: model.libraryRevision, query: text, filter: filter, sort: sort, tag: tag)
        }
        var start = Date(); let initial = query(); let cold = Date().timeIntervalSince(start) * 1000
        try expect(initial.papers.count == 20_000 && initial.papers.first?.title == "Paper 0", "large natural-title query is complete and sorted")
        let builds = cache.documentBuilds
        start = Date()
        for n in 0..<1000 {
            model.items = [DownloadItem(original: "progress-\(n)", state: .downloading)]
            try expect(query().items.count == 20_000, "progress keeps cached results")
        }
        let cached = Date().timeIntervalSince(start) * 1000 / 1000
        try expect(cache.documentBuilds == builds, "1000 progress updates never rebuild the document projection")
        try expect(query("paper", filter: .favorites, tag: "even").papers.count == 3334, "filters and tags invalidate the query")
        let target = model.papers[0].id
        model.changePaper(target) { $0.title = "Unique edited document" }
        try expect(query("unique").ids == [target] && query("unique").items.first?.title == "Unique edited document", "title edits invalidate search, row mapping and details")
        model.items = []
        var gaps: [Double] = []
        let pulse = Task { @MainActor in
            var previous = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
                let now = Date(); gaps.append(now.timeIntervalSince(previous) * 1000); previous = now
            }
        }
        let mutation = Task { await model.setLibraryRemoved([target], in: .documents, removed: true) }
        while !model.libraryMutationInProgress { await Task.yield() }
        model.changePaper(target) { $0.tags = ["edited during commit"] }
        try expect(!(await model.setLibraryRemoved([target], in: .documents, removed: false)), "in-flight transaction rejects duplicate library actions")
        start = Date(); let success = await mutation.value; let duration = Date().timeIntervalSince(start) * 1000
        pulse.cancel(); await pulse.value
        await model.persistWorkspaceAndWait()
        try expect(success && gaps.count > 1, "20k commit yields the main actor for UI work")
        let disk = try LibraryStore.read(state.deletingLastPathComponent().appendingPathComponent("library.json"))!
        try expect(disk.first?.removed == true && disk.first?.tags == ["edited during commit"] && model.papers[0].tags == disk[0].tags,
            "async commit merges newer edits and durably preserves both changes")
        try expect(query("unique").ids.isEmpty && query("unique", filter: .removed).ids == [target], "removal invalidates both active and removed projections")
        model.papers[0].missing = true
        let restore = Task { await model.undoLibraryRemoval() }
        while !model.libraryMutationInProgress { await Task.yield() }
        model.changePaper(model.papers[1].id) { $0.read = true }
        try expect(await restore.value, "20k asynchronous undo succeeds")
        await model.persistWorkspaceAndWait()
        try expect(query("unique").ids == [target] && !model.papers[0].missing && model.papers[1].read,
            "restore merges checked file availability despite an unrelated concurrent edit")
        let recoveredDisk = try LibraryStore.read(state.deletingLastPathComponent().appendingPathComponent("library.json"))!
        try expect(!recoveredDisk[0].missing && recoveredDisk[1].read, "merged recovery is persisted")
        print(String(format: "BENCH 20k library: cold title query %.2f ms; cached progress/query %.4f ms; async remove %.2f ms; UI pulses %d; longest pulse %.2f ms", cold, cached, duration, gaps.count, gaps.max() ?? 0))
    }
}
