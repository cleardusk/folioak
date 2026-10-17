import AppKit
import SwiftUI
import PDFKit

private struct NamingTransport: HTTPTransport {
    let body: Data
    var status = 200
    var delay: UInt64 = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw TestFailure.failed("unexpected metadata request") }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["ETag": "fixture-v1"])!)
    }
}

extension CoreTests {
    @MainActor static func namingTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-naming-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("identifierTitle", forKey: "namingStyle")
        try expect(DownloadPreferences(preferences).naming == .identifierTitle && DownloadPreferences(preferences).namingRules.templates.isEmpty, "legacy preferences keep arXiv style and original other filenames")
        var rules = AssetNamingRules()
        for kind in AssetNamingKind.allCases { rules[kind] = "{date} - {source} - {title} - {id}" }
        let date = ISO8601DateFormatter().date(from: "2026-10-16T23:59:00Z")!
        let snapshot = AssetNamingSnapshot(rules: rules, paperStyle: .identifierTitle, now: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        let source = URL(string: "https://example.com/files/a.pdf?token=secret")!
        for invalid in ["../{title}", "{unknown}", "{title", "title}", "{{title}}", "{date}", "{title}\n", "{title}:x", String(repeating: "中", count: 200) + "{title}"] {
            try expect(!AssetNamingRules.validTemplate(invalid), "reject unsafe or ambiguous naming template: \(invalid)")
        }
        try expect(rules.valid && snapshot.valid, "valid naming snapshot")
        let rendered = snapshot.title("Literal {source} / 标题", kind: .documents, source: source)!
        try expect(rendered.contains("Literal {source}") && !rendered.contains("secret") && rendered.hasPrefix("2026-10-16 - example.com"), "one-pass rendering and no query leakage")
        let longName = PaperMetadata.filename(title: snapshot.title(String(repeating: "长标题", count: 200), kind: .images, source: source)!, ending: " - 20 (2).jpg")
        try expect(longName.utf8.count <= 250 && longName.hasSuffix(" - 20 (2).jpg"), "UTF-8 truncation retains attachment index, collision number and extension")
        try expect(AssetNamingKind.output("m4a") == .audio && AssetNamingKind.output("PPTX") == .documents && AssetNamingKind.output("zip") == .archives, "rules use final output format")
        let directory = root.appendingPathComponent("naming"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let direct = DownloadSource.pdf(source)
        let engine = DownloadEngine(pdfTransport: NamingTransport(body: try Data(contentsOf: pdf)), requestInterval: 0)
        let saved = try await engine.download(direct, to: directory, namingSnapshot: snapshot)
        try expect(saved.url.lastPathComponent.hasPrefix("2026-10-16 - example.com") && !saved.title.hasPrefix("2026-10-16"), "PDF filename separate from display title")
        var changed = rules; changed[.documents] = "changed-{title}"
        let newer = AssetNamingSnapshot(rules: changed)
        let cached = try await DownloadEngine(pdfTransport: NamingTransport(body: Data(), status: 304), requestInterval: 0).download(direct, to: directory, namingSnapshot: newer)
        try expect(cached.url == saved.url && cached.title == saved.title && cached.alreadyExisted, "304 keeps original path and title after rule change")
        let metadata = PaperMetadata(reference: try ArxivReference.parse("2501.12345v2"), title: "Original title", year: 2025, month: 1)
        let paper = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: directory, namingSnapshot: snapshot)
        let existing = try PaperStorage.existing(metadata: metadata, directory: directory, naming: .titleOnly)
        try expect(existing?.url == paper.url && existing?.alreadyExisted == true, "arXiv cached files survive different naming styles")
        let text = root.appendingPathComponent("fixture.txt"); try Data("first".utf8).write(to: text)
        let first = try FileStorage.save(text, title: "Display", extension: "txt", to: directory, filenameTitle: "Named")
        try Data("second".utf8).write(to: text)
        let second = try FileStorage.save(text, title: "Display", extension: "txt", to: directory, filenameTitle: "Named")
        try expect(first.url != second.url && second.url.lastPathComponent == "Named (2).txt" && (try Data(contentsOf: first.url)) == Data("first".utf8), "collision preserves existing content")
        let txtSource = try DownloadSource.parse("https://example.com/notes.txt")
        let txtEngine = DownloadEngine(pdfTransport: NamingTransport(body: Data("notes".utf8), delay: 100_000_000), requestInterval: 0)
        preferences.set(directory.path, forKey: "downloadRootDirectory")
        preferences.set(try JSONEncoder().encode(rules), forKey: AssetNamingRules.preferenceKey)
        let state = root.appendingPathComponent("naming-state/workspace.json")
        let model = DownloadModel(engine: txtEngine, preferences: preferences, stateURL: state)
        _ = try model.submitQuickDownload(txtSource.webURL.absoluteString)
        let initial = model.items[0].namingSnapshot!
        model.namingRules = changed
        _ = try model.submitQuickDownload("https://example.com/second.txt")
        try expect(model.items[0].namingSnapshot == initial && model.items[1].namingSnapshot?.rules == changed, "busy append freezes rules independently per submission")
        for _ in 0..<1000 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!model.busy && model.items.allSatisfy { $0.state == .saved }, "both named submissions finish")
        let old = model.items[0]
        try expect(old.savedURL!.lastPathComponent.hasPrefix(initial.date) && model.items[1].savedURL!.lastPathComponent.hasPrefix("changed-"), "queued jobs keep their submission rules")
        model.clearDownloadRecords(); await model.persistWorkspaceAndWait()
        let restored = DownloadModel(engine: txtEngine, preferences: preferences, stateURL: state)
        let library = restored.papers.first { $0.id == old.id }!
        try expect(library.namingSnapshot?.rules == initial.rules && library.downloadItem.namingSnapshot?.savedNames == [old.savedURL!.lastPathComponent], "snapshot survives library-only restart")
        let libraryQuery = restored.libraryQueries.documents(restored.papers, revision: restored.libraryRevision, query: old.savedURL!.lastPathComponent, filter: .all, sort: .newest, tag: nil)
        try expect(libraryQuery.ids == [old.id], "document library finds the allocated filename separately from its title")
        var missingNamedPaper = library; missingNamedPaper.missing = true
        try expect(missingNamedPaper.matches(old.savedURL!.lastPathComponent), "missing document remains searchable by filename")
        try FileManager.default.removeItem(at: old.savedURL!)
        restored.retryFromLibrary(library.downloadItem)
        for _ in 0..<1000 { if !restored.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(restored.items.first?.savedURL == old.savedURL && restored.items.first?.namingSnapshot == old.namingSnapshot, "retry restores the same frozen path")
        let legacy = DownloadItem(original: "2501.12345", reference: try ArxivReference.parse("2501.12345"), state: .queued)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(legacy))
        try expect(decoded.namingSnapshot == nil && WorkspaceStore.validItem(decoded), "old records without snapshots still load")
        let cli = CapturedConsole()
        let options = try CLIOptions.parse(["--json", txtSource.webURL.absoluteString, "-o", directory.path])
        let code = await CLIRunner.run(options, version: "test", engine: txtEngine, preferences: preferences, stdout: { cli.stdout($0) }, stderr: { cli.stderr($0) })
        try expect(code == 0 && cli.output.contains("changed-"), "CLI shares GUI rules")
        let arxivConsole = CapturedConsole()
        let arxivOptions = try CLIOptions.parse(["--json", "--naming", "title", "2501.12345v2", "-o", directory.appendingPathComponent("cli-override").path])
        let arxivCode = await CLIRunner.run(arxivOptions, version: "test", engine: DownloadEngine(transport: MockTransport(sourcePDF: pdf), requestInterval: 0), preferences: preferences, stdout: { arxivConsole.stdout($0) }, stderr: { arxivConsole.stderr($0) })
        let expectedArxiv = try AtomParser.metadata(atom(), requested: ArxivReference.parse("2501.12345v2")).filename(style: .titleOnly)
        try expect(arxivCode == 0 && arxivConsole.output.contains(expectedArxiv), "explicit CLI arXiv style overrides its custom template without changing preferences")
        // Assigned collision names remain stable after the earlier occupant disappears.
        let allocated = newer.saving([second.url])
        try FileManager.default.removeItem(at: first.url); try FileManager.default.removeItem(at: second.url)
        let retryNamed = try await DownloadEngine(pdfTransport: NamingTransport(body: Data("second".utf8)), requestInterval: 0)
            .download(txtSource, to: directory, namingSnapshot: allocated)
        try expect(retryNamed.url == second.url, "retry retains allocated collision basename after occupant disappears")
        let longPDF = root.appendingPathComponent("long-title.pdf")
        let document = PDFDocument(url: pdf)!
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: String(repeating: "中文标题", count: 700)]
        try expect(document.write(to: longPDF), "long title PDF fixture")
        let longSource = DownloadSource.pdf(URL(string: "https://example.com/long-title.pdf")!)
        let longSaved = try await DownloadEngine(pdfTransport: NamingTransport(body: try Data(contentsOf: longPDF)), requestInterval: 0).download(longSource, to: directory, namingSnapshot: snapshot)
        let longCached = try await DownloadEngine(pdfTransport: NamingTransport(body: Data(), status: 304), requestInterval: 0).download(longSource, to: directory, namingSnapshot: newer)
        try expect(longCached.alreadyExisted && longCached.url == longSaved.url && longCached.title == longSaved.title, "long Unicode title does not discard source validators")
        let imageA = root.appendingPathComponent("naming-a.png"), imageB = root.appendingPathComponent("naming-b.png")
        try ThumbnailTestMatrix.writeImage(imageA, color: .red); try ThumbnailTestMatrix.writeImage(imageB, color: .blue)
        var mediaRules = AssetNamingRules(); mediaRules[.images] = "image-{title}"; mediaRules[.audio] = "audio-{title}"; mediaRules[.videos] = "video-{title}"; mediaRules[.archives] = "archive-{title}"
        let mediaSnapshot = AssetNamingSnapshot(rules: mediaRules)
        let group = try await FileStorage.publish([imageA, imageB], title: String(repeating: "长标题", count: 100), to: directory, namingSnapshot: mediaSnapshot, source: source)
        try expect(group.url.lastPathComponent.hasSuffix(" - 01.png") && group.additionalURLs[0].lastPathComponent.hasSuffix(" - 02.png") && group.url.lastPathComponent.utf8.count <= 250, "media group retains attachment numbers after long-name truncation")
        var namedMedia = DownloadItem(original: source.absoluteString, state: .saved, savedURL: group.url,
            documentTitle: "Readable media title", additionalURLs: group.additionalURLs)
        let mediaQuery = LibraryQueryCache()
        try expect(mediaQuery.media([namedMedia], revision: 0, query: group.url.lastPathComponent, removed: false).count == 1,
            "media library finds the custom primary filename")
        namedMedia.state = .missing
        try expect(mediaQuery.media([namedMedia], revision: 1, query: group.additionalURLs[0].lastPathComponent, removed: false).count == 1,
            "missing media remains searchable by attachment filename")
        let savedGroup = mediaSnapshot.saving([group.url] + group.additionalURLs)
        try FileManager.default.removeItem(at: group.additionalURLs[0])
        let repeatedGroup = try await FileStorage.publish([imageA, imageB], title: "Changed upstream title", to: directory, namingSnapshot: savedGroup, source: source)
        try expect(repeatedGroup.url == group.url && repeatedGroup.additionalURLs == group.additionalURLs, "partial media retry retains file names despite upstream title changes")
        let video = root.appendingPathComponent("naming-with-audio.mp4")
        let mediaTools = try MediaTools.installed()
        let muxStatus = try await MediaProcess().run(try mediaTools.executable("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-i", "Tests/Fixtures/Media/h264.mp4",
            "-i", "Tests/Fixtures/Media/tone.m4a", "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-shortest", video.path
        ]) { _ in }
        try expect(muxStatus == 0, "naming fixture contains video and audio tracks")
        let audio = try await DownloadEngine(pdfTransport: NamingTransport(body: try Data(contentsOf: video)), requestInterval: 0)
            .download(try DownloadSource.parse("https://example.com/clip.mp4"), to: directory, namingSnapshot: mediaSnapshot, mediaFormat: .audio)
        try expect(audio.url.lastPathComponent.hasPrefix("audio-") && audio.url.pathExtension == "m4a", "actual extracted audio uses audio template")
        let zip = try genericZip(root: root, entries: ["note.txt": "archive"])
        let archive = try await DownloadEngine(pdfTransport: NamingTransport(body: zip), requestInterval: 0)
            .download(try DownloadSource.parse("https://example.com/bundle.zip"), to: directory, namingSnapshot: mediaSnapshot)
        try expect(archive.url.lastPathComponent == "archive-bundle.zip", "archive save applies archive template")
        let rollback = root.appendingPathComponent("naming-rollback")
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let images = try DownloadFolder.images.prepare(in: rollback)
        let reused = try FileStorage.save(imageA, title: "Group", extension: "png", to: images, filenameTitle: "image-Group", attachmentSuffix: " - 01")
        try Data("blocked directory".utf8).write(to: rollback.appendingPathComponent("Videos"))
        do {
            _ = try await FileStorage.publish([imageA, video], title: "Group", to: rollback, organizeByType: true, namingSnapshot: mediaSnapshot, source: source)
            throw TestFailure.failed("media publication should fail with blocked destination")
        } catch let error as TestFailure { throw error } catch {}
        try expect(FileManager.default.fileExists(atPath: reused.url.path), "media rollback never deletes reused group member")
        let start = ContinuousClock.now
        for index in 0..<20_000 { _ = snapshot.title("Document \(index)", kind: .documents, source: source) }
        print("PERF naming 20000 renders \(start.duration(to: .now))")
        print("PASS modality naming, frozen submissions, cache, restart, retry and CLI")
    }
}
