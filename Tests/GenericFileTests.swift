import AppKit

private struct GenericFixtureTransport: HTTPTransport {
    var body: Data
    var headers: [String: String] = [:]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw TestFailure.failed("generic file must not request metadata") }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        progress(DownloadProgress(received: Int64(body.count), total: Int64(body.count)))
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

extension CoreTests {
    // Real ZIP directory records, generated with the system utility. No package
    // dependencies, network access, archive extraction or document execution.
    static func genericZip(root: URL, entries: [String: String]) throws -> Data {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in entries {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let archive = root.appendingPathComponent(UUID().uuidString + ".zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory; process.arguments = ["-q", "-r", archive.path, "."]
        try process.run(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "ZIP fixture created")
        return try Data(contentsOf: archive)
    }
    @MainActor static func genericFileTests(root: URL, pdf: URL) async throws {
        let types = ["pptx": "ppt/presentation.xml", "docx": "word/document.xml", "xlsx": "xl/workbook.xml"]
        for ext in GenericFileStorage.extensions {
            try expect(try DownloadSource.parse("https://example.com/file." + ext).supportsAudioExtraction == false, "all common file types exclude audio extraction")
        }
        var fixtures: [String: Data] = [:]
        for (ext, entry) in types {
            fixtures[ext] = try genericZip(root: root, entries: ["[Content_Types].xml": "<Types/>", entry: "<document/>"])
        }
        fixtures["epub"] = try genericZip(root: root, entries: ["mimetype": "application/epub+zip", "META-INF/container.xml": "<container/>"])
        fixtures["odt"] = try genericZip(root: root, entries: ["mimetype": "application/vnd.oasis.opendocument.text", "content.xml": "<document/>"])
        fixtures["zip"] = try genericZip(root: root, entries: ["mimetype": "", "hello.html": "<html><body>hello</body></html>"])
        fixtures["md"] = Data("Use <body> for the document body.".utf8)
        fixtures["log"] = Data("ID3 tags and Rar! headers describe file formats.".utf8)
        fixtures["yaml"] = Data(("RIFF example: " + String(repeating: "中文", count: 2000)).utf8)
        fixtures["csv"] = Data([0xff, 0xfe]) + "标题,测试\n1,2".data(using: .utf16LittleEndian)!
        fixtures["xml"] = Data([0xfe, 0xff]) + "<document>中文</document>".data(using: .utf16BigEndian)!
        fixtures["txt"] = Data("Hello 中文\n".utf8); fixtures["json"] = Data("{\"hello\": true}".utf8)
        fixtures["ppt"] = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) + Data(repeating: 0, count: 504)
        let destination = root.appendingPathComponent("generic-downloads")
        for (ext, data) in fixtures {
            let source = try DownloadSource.parse("https://example.com/sample." + ext)
            try expect(!source.isPaper && !source.isMedia && !source.supportsAudioExtraction, "generic source capability: " + ext)
            let engine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: data), requestInterval: 0, retryDelay: 0)
            let saved = try await engine.download(source, to: destination, mediaFormat: .audio, organizeByType: true)
            try expect(saved.pages == 0 && saved.url.pathExtension == ext, "generic format preserved even in audio mode: " + ext)
            try expect(saved.url.deletingLastPathComponent().lastPathComponent == (ext == "zip" ? "Archives" : "Documents"), "generic categorized destination")
            try expect(try Data(contentsOf: saved.url) == data, "generic bytes preserved")
            let again = try await engine.download(source, to: destination, organizeByType: true)
            try expect(again.alreadyExisted && again.url == saved.url, "generic same-content reuse")
            let raw = try DownloadSource.parse("https://github.com/org/repo/blob/main/sample." + ext)
            try expect(raw.webURL.host == "raw.githubusercontent.com", "GitHub generic direct links")
        }
        let emptyZip = Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)
        let emptyEngine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: emptyZip), requestInterval: 0)
        _ = try await emptyEngine.download(DownloadSource.parse("https://example.com/empty.zip"), to: destination)
        let noExtension = try DownloadSource.parse("https://example.com/download?id=123")
        for headers in [[String: String](), ["Content-Type": "text/plain"], ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=slides.zip"], ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"slides.pptx\""], ["Content-Type": "application/vnd.openxmlformats-officedocument.presentationml.presentation"]] {
            let engine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: fixtures["pptx"]!, headers: headers), requestInterval: 0)
            let saved = try await engine.download(noExtension, to: destination)
            try expect(saved.url.pathExtension == "pptx" && saved.url.deletingLastPathComponent().path == destination.path, "extensionless content/header detection and exact -o destination")
        }
        let odfEngine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: fixtures["odt"]!), requestInterval: 0)
        try expect(try await odfEngine.download(noExtension, to: destination).url.pathExtension == "odt", "unnamed ODF is recognized by container MIME")
        // Actual PDF bytes take precedence over a misleading download filename.
        let disguised = DownloadEngine(pdfTransport: GenericFixtureTransport(body: try Data(contentsOf: pdf), headers: ["Content-Type": "application/vnd.ms-powerpoint"]), requestInterval: 0)
        let actualPDF = try await disguised.download(try DownloadSource.parse("https://example.com/fake.ppt"), to: destination)
        try expect(actualPDF.url.pathExtension == "pdf", "PDF signature takes precedence")
        for (ext, data) in [("pptx", Data("<html>login</html>".utf8)), ("txt", Data("\u{feff}<!-- note -->\n<html>login</html>".utf8)), ("epub", fixtures["zip"]!), ("pptx", Data([0x50, 0x4b, 3, 4])), ("txt", Data([1, 0, 2]))] {
            let engine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: data), requestInterval: 0, retryDelay: 0)
            do {
                _ = try await engine.download(try DownloadSource.parse("https://example.com/invalid." + ext), to: destination)
                throw TestFailure.failed("invalid generic content accepted: " + ext)
            } catch let error as TestFailure { throw error } catch {}
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasSuffix(".partial") }, "failed downloads leave no partial files")
        let suite = "folioak-generic-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(destination.path, forKey: "downloadRootDirectory")
        let cliFolder = root.appendingPathComponent("generic-cli-exact")
        let options = try CLIOptions.parse(["--json", "--audio", "https://example.com/slides.pptx", "-o", cliFolder.path])
        let console = CapturedConsole()
        let cliEngine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: fixtures["pptx"]!), requestInterval: 0)
        let code = await CLIRunner.run(options, version: "test", engine: cliEngine, preferences: preferences, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let report = try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any]
        let rows = report["results"] as! [[String: Any]], cliFile = URL(fileURLWithPath: rows[0]["path"] as! String)
        try expect(code == 0 && cliFile.pathExtension == "pptx" && cliFile.deletingLastPathComponent().path == cliFolder.path, "CLI common file JSON path, exact -o and audio preference")
        let stateURL = root.appendingPathComponent("generic-state/workspace.json")
        let engine = DownloadEngine(pdfTransport: GenericFixtureTransport(body: fixtures["epub"]!), requestInterval: 0)
        var opened: [URL] = []
        let model = DownloadModel(engine: engine, preferences: preferences, opener: { opened.append($0); return true }, stateURL: stateURL)
        _ = try model.submitQuickDownload("https://example.com/book.epub")
        for _ in 0..<1000 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!model.busy && model.items.first?.state == .saved && model.papers.count == 1 && model.mediaLibrary.isEmpty, "generic GUI download enters only document library")
        let paper = model.papers[0], file = paper.file!
        try expect(paper.pages == nil && paper.source?.isPaper == false && paper.downloadItem.symbol == "book.closed", "generic library metadata and icon")
        model.openPaper(paper); model.openPaper(paper, preview: true)
        try expect(opened == [file] && model.previewURL == file, "generic default-open and Quick Look URL")
        model.clearDownloadRecords(); await model.persistWorkspaceAndWait()
        let restored = DownloadModel(engine: engine, preferences: preferences, opener: { opened.append($0); return true }, stateURL: stateURL)
        try expect(restored.papers.count == 1 && restored.history.isEmpty && restored.items.isEmpty && restored.mediaLibrary.isEmpty, "generic library survives clear-history and restart")
        try FileManager.default.removeItem(at: file)
        restored.openPaper(restored.papers[0])
        try expect(restored.papers[0].missing && restored.papers[0].file == file, "generic missing path preserved")
        restored.retryFromLibrary(restored.papers[0].downloadItem)
        for _ in 0..<1000 { if !restored.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!restored.papers[0].missing && restored.papers.count == 1 && FileManager.default.fileExists(atPath: file.path), "generic missing retry repairs existing library entry")
        try expect(await restored.setLibraryRemoved([paper.id], in: .documents, removed: true), "generic library remove")
        try expect(await restored.undoLibraryRemoval(), "generic library undo")
        await restored.persistWorkspaceAndWait()
        let final = DownloadModel(preferences: preferences, stateURL: stateURL)
        try expect(final.papers.count == 1 && !final.papers[0].removed && final.items.first?.savedURL == file, "generic records remain schema1 restart-compatible")
        let replacement = root.appendingPathComponent("relinked.epub")
        try fixtures["epub"]!.write(to: replacement)
        final.previewURL = file
        try await final.relinkPaper(paper.id, to: replacement)
        try expect(final.papers[0].file == replacement && !final.papers[0].missing && final.items.first?.savedURL == replacement && final.previewURL == replacement, "generic relink validates and updates the existing library entry")
        let corrupt = root.appendingPathComponent("corrupt.epub")
        try Data("<html>not a book</html>".utf8).write(to: corrupt)
        do { try await final.relinkPaper(paper.id, to: corrupt); throw TestFailure.failed("corrupt relink accepted") }
        catch let error as TestFailure { throw error } catch {}
        try expect(final.papers[0].file == replacement, "invalid relink preserves previous valid path")
        final.previewURL = nil
        final.changePaper(paper.id) { $0.file = nil; $0.missing = true }
        try await final.relinkPaper(paper.id, to: pdf)
        try expect(final.previewURL == nil, "pathless legacy relink does not start Quick Look")
        print("PASS generic files: formats, content validation, direct endpoints, classification, persistence, preview, retry and undo")
    }
}
