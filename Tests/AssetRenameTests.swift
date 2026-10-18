import AppKit
import Foundation

private struct RenameTestTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw TestFailure.failed("unexpected metadata request") }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rename-fixture-" + UUID().uuidString)
        try Data("offline notes".utf8).write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}

extension CoreTests {
    @MainActor static func assetRenameTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-rename-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("asset-renames")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = folder.appendingPathComponent("workspace.json")
        let file = folder.appendingPathComponent("paper.pdf")
        try FileManager.default.copyItem(at: pdf, to: file)
        let reference = try ArxivReference.parse("1706.03762v1")
        let origin = DownloadOrigin(input: "https://arxiv.org/abs/1706.03762v1?context=original", capturedAt: Date(timeIntervalSince1970: 123))
        let item = DownloadItem(original: reference.identifier, reference: reference,
            metadata: PaperMetadata(reference: reference, title: "Source title", year: 2017, month: 6), state: .saved,
            savedURL: file, documentTitle: "Original", namingSnapshot: AssetNamingSnapshot(), origin: origin)
        let model = DownloadModel(preferences: preferences, opener: { _ in true }, stateURL: state)
        model.items = [item]; model.history = [item]; model.upsertPaper(item)
        model.changePaper(item.id) { $0.tags = ["retained"]; $0.favorite = true; $0.read = true }
        model.previewURL = file; model.diagnosticItem = item; model.persistWorkspace()
        model.requestAssetRename(item.id, in: .documents)
        guard let request = model.renamingAsset else { throw TestFailure.failed("rename request unavailable") }
        let bytes = try Data(contentsOf: file)
        try expect(await model.renameAsset(request, file: file, to: "Renamed 文档"), "document file rename succeeds")
        let renamed = folder.appendingPathComponent("Renamed 文档.pdf")
        try expect(!FileManager.default.fileExists(atPath: file.path) && (try Data(contentsOf: renamed)) == bytes,
            "rename moves the actual file without changing contents")
        try expect(model.papers[0].file == renamed && model.items[0].savedURL == renamed && model.history[0].savedURL == renamed &&
            model.previewURL == renamed && model.diagnosticItem?.savedURL == renamed && model.papers[0].title == "Renamed 文档" &&
            model.items[0].documentTitle == "Renamed 文档", "document, download, history, preview and detail all follow renamed file and title")
        try expect(model.papers[0].tags == ["retained"] && model.papers[0].favorite && model.papers[0].read &&
            model.items[0].original == item.original && model.items[0].origin == origin && model.papers[0].provenance == origin &&
            model.items[0].metadata?.title == "Source title" && model.items[0].reference == reference,
            "rename retains IDs, source metadata, origin and personal organization")
        try expect(model.items[0].namingSnapshot?.savedNames == [renamed.lastPathComponent] &&
            model.papers[0].namingSnapshot?.savedNames == [renamed.lastPathComponent] &&
            model.items[0].namingSnapshot?.paperFilename(item.metadata!) == renamed.lastPathComponent,
            "retry naming snapshots retain the renamed filename")
        await model.persistWorkspaceAndWait()
        let restored = DownloadModel(preferences: preferences, stateURL: state)
        try expect(restored.items[0].savedURL == renamed && restored.history[0].savedURL == renamed && restored.papers[0].file == renamed,
            "all renamed references survive restart")

        let first = folder.appendingPathComponent("first.png"), second = folder.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let media = DownloadItem(original: "https://example.com/group.png?original=1", directURL: URL(string: "https://example.com/group.png"),
            state: .saved, savedURL: first, documentTitle: "Group title", additionalURLs: [second],
            namingSnapshot: AssetNamingSnapshot(), origin: DownloadOrigin(input: "https://example.com/group.png?original=1", capturedAt: Date()))
        model.mediaLibrary = [media]; model.items = [media]; model.history = [media]; model.persistWorkspace()
        model.requestAssetRename(media.id, in: .media)
        guard let mediaRequest = model.renamingAsset else { throw TestFailure.failed("media request unavailable") }
        try expect(mediaRequest.files == [first, second], "multi-attachment rename offers each exact file")
        try expect(await model.renameAsset(mediaRequest, file: second, to: "Second renamed"), "secondary attachment rename succeeds")
        let secondRenamed = folder.appendingPathComponent("Second renamed.png")
        try expect(model.mediaLibrary[0].savedURL == first && model.mediaLibrary[0].additionalURLs == [secondRenamed] &&
            model.mediaLibrary[0].title == "Group title" && model.items[0].additionalURLs == [secondRenamed] &&
            model.history[0].additionalURLs == [secondRenamed] && model.mediaLibrary[0].namingSnapshot?.savedNames == ["first.png", "Second renamed.png"],
            "secondary rename updates every attachment reference while retaining group title and order")
        model.requestAssetRename(media.id, in: .media)
        let primaryRequest = model.renamingAsset!
        try expect(await model.renameAsset(primaryRequest, file: first, to: "Main renamed"), "primary media rename succeeds")
        let mainRenamed = folder.appendingPathComponent("Main renamed.png")
        try expect(model.mediaLibrary[0].title == "Main renamed" && model.items[0].title == "Main renamed" &&
            model.mediaLibrary[0].origin == media.origin && model.mediaLibrary[0].additionalURLs == [secondRenamed],
            "primary media rename synchronizes title and preserves origin and attachments")
        await model.persistWorkspaceAndWait()
        let mediaRestart = DownloadModel(preferences: preferences, stateURL: state)
        try expect(mediaRestart.mediaLibrary[0].localURLs == [mainRenamed, secondRenamed] &&
            mediaRestart.items[0].namingSnapshot?.savedNames == ["Main renamed.png", "Second renamed.png"],
            "media attachment paths and retry filenames survive restart")
        model.requestAssetRename(media.id, in: .media)
        let invalidRequest = model.renamingAsset!
        for name in ["", "  ", ".", "..", "../escape", "bad/name", "bad\\name", "bad:name", "bad?name", "bad\nname", String(repeating: "长", count: 100)] {
            try expect(!(await model.renameAsset(invalidRequest, file: mainRenamed, to: name)), "invalid name rejected: " + name)
        }
        let collision = folder.appendingPathComponent("taken.png")
        try Data("do not replace".utf8).write(to: collision)
        try expect(!(await model.renameAsset(invalidRequest, file: mainRenamed, to: "taken")) &&
            (try Data(contentsOf: collision)) == Data("do not replace".utf8) && FileManager.default.fileExists(atPath: mainRenamed.path),
            "collision never overwrites either file")
        model.busy = true; try expect(!model.canRenameAsset(media.id, in: .media), "busy rename disabled"); model.busy = false
        model.importingPDFs = true; try expect(!model.canRenameAsset(media.id, in: .media), "importing rename disabled"); model.importingPDFs = false
        model.checkingVersions = [UUID()]; try expect(!model.canRenameAsset(media.id, in: .media), "version mutation rename disabled"); model.checkingVersions = []
        model.mediaLibrary[0].libraryRemovedAt = Date(); try expect(!model.canRenameAsset(media.id, in: .media), "removed rename disabled")
        model.mediaLibrary[0].libraryRemovedAt = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mainRenamed.path)
        try expect(!model.canRenameAsset(media.id, in: .media), "read-only file rename disabled")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mainRenamed.path)
        try FileManager.default.removeItem(at: secondRenamed)
        try expect(!model.canRenameAsset(media.id, in: .media), "missing attachment disables rename")
        try Data("second".utf8).write(to: secondRenamed)
        await model.persistWorkspaceAndWait()
        let libraryURL = state.deletingLastPathComponent().appendingPathComponent("library.json")
        let libraryBefore = try LibraryStore.read(libraryURL)?.map(\.file)
        // An oversized unrelated workspace record fails after the catalogs have written.
        var invalid = media; invalid.id = UUID(); invalid.documentTitle = String(repeating: "x", count: WorkspaceStore.byteLimit + 1)
        model.items.append(invalid)
        model.requestAssetRename(media.id, in: .media)
        try expect(!(await model.renameAsset(model.renamingAsset!, file: mainRenamed, to: "Must rollback")), "workspace save failure rejects rename")
        try expect(FileManager.default.fileExists(atPath: mainRenamed.path) && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Must rollback.png").path) &&
            model.mediaLibrary[0].savedURL == mainRenamed && (try LibraryStore.read(libraryURL)?.map(\.file)) == libraryBefore,
            "save failure rolls back file, catalogs and in-memory references")
        model.items.removeLast(); await model.persistWorkspaceAndWait()
        let afterFailure = DownloadModel(preferences: preferences, stateURL: state)
        try expect(afterFailure.mediaLibrary[0].savedURL == mainRenamed && afterFailure.mediaLibrary[0].additionalURLs == [secondRenamed],
            "failed rename does not leave broken persisted paths")
        // Leave the main actor during the serial commit, then change unrelated metadata.
        model.requestAssetRename(media.id, in: .media)
        let concurrentRequest = model.renamingAsset!
        let concurrent = Task { await model.renameAsset(concurrentRequest, file: mainRenamed, to: "Concurrent renamed") }
        while !model.assetRenameInProgress { await Task.yield() }
        let revision = model.fileRefreshRevision
        model.openFile(model.mediaLibrary[0]); model.preview(model.mediaLibrary[0]); model.openPaper(model.papers[0])
        try expect(model.fileRefreshRevision == revision, "file actions during rename cannot misclassify the temporarily moved file as missing")
        model.input = "keep concurrent draft"
        model.changePaper(item.id) { $0.tags = ["changed during rename"]; $0.favorite = false }
        try expect(await concurrent.value, "rename finishes with concurrent unrelated metadata updates")
        try expect(model.input == "keep concurrent draft" && model.papers[0].tags == ["changed during rename"] && !model.papers[0].favorite,
            "rename merges paths without losing concurrent input or document organization")
        await model.persistWorkspaceAndWait()
        let concurrentRestart = DownloadModel(preferences: preferences, stateURL: state)
        try expect(concurrentRestart.input == "keep concurrent draft" && concurrentRestart.papers[0].tags == ["changed during rename"] &&
            concurrentRestart.mediaLibrary[0].savedURL?.lastPathComponent == "Concurrent renamed.png",
            "concurrent metadata and renamed paths persist together")

        // Exercise a complete library retry using an in-memory HTTP fixture, never the network.
        let retryRoot = folder.appendingPathComponent("retry")
        try FileManager.default.createDirectory(at: retryRoot, withIntermediateDirectories: true)
        preferences.set(retryRoot.path, forKey: "downloadRootDirectory")
        let retryState = retryRoot.appendingPathComponent("workspace.json")
        let retryEngine = DownloadEngine(pdfTransport: RenameTestTransport(), requestInterval: 0)
        let retryModel = DownloadModel(engine: retryEngine, preferences: preferences, stateURL: retryState)
        _ = try retryModel.submitQuickDownload("https://example.com/original.txt")
        for _ in 0..<500 { if !retryModel.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard let retryPaper = retryModel.papers.first, let retryFile = retryPaper.file else { throw TestFailure.failed("offline retry fixture did not save") }
        retryModel.requestAssetRename(retryPaper.id, in: .documents)
        try expect(await retryModel.renameAsset(retryModel.renamingAsset!, file: retryFile, to: "Retry renamed"), "offline retry fixture rename succeeds")
        let retryRenamed = retryFile.deletingLastPathComponent().appendingPathComponent("Retry renamed.txt")
        await retryModel.persistWorkspaceAndWait()
        let retryRestart = DownloadModel(engine: retryEngine, preferences: preferences, stateURL: retryState)
        try FileManager.default.removeItem(at: retryRenamed)
        retryRestart.retryFromLibrary(retryRestart.papers[0].downloadItem)
        for _ in 0..<500 { if !retryRestart.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!retryRestart.busy && retryRestart.items[0].savedURL == retryRenamed &&
            retryRestart.items[0].namingSnapshot?.savedNames == ["Retry renamed.txt"] &&
            FileManager.default.fileExists(atPath: retryRenamed.path) && !FileManager.default.fileExists(atPath: retryFile.path),
            "retry after restart recreates renamed filename and never restores original name")
        print("PASS asset rename: documents, media attachments, source preservation, retry snapshots, restart, invalid/collision/missing/read-only/busy guards and save rollback")
    }
}
