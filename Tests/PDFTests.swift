import Foundation
import PDFKit

extension CoreTests {
    @MainActor static func pdfDirectoryTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-pdf-directory-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("default-root", isDirectory: true)
        let custom = root.appendingPathComponent("shared-pdfs", isDirectory: true)
        let next = root.appendingPathComponent("next-pdfs", isDirectory: true)
        preferences.set(folder.path, forKey: "downloadRootDirectory")
        preferences.set(false, forKey: "updates.automatic")
        try expect(!DownloadPreferences(preferences).usesPDFDirectory && DownloadPreferences(preferences).activePDFDirectory == nil,
            "PDF override is off by default")
        preferences.set(true, forKey: "usesPDFDownloadDirectory")
        preferences.set("relative/path", forKey: "pdfDownloadDirectory")
        try expect(DownloadPreferences(preferences).activePDFDirectory == nil, "missing or relative PDF paths cannot activate an override")
        preferences.removeObject(forKey: "usesPDFDownloadDirectory")
        preferences.removeObject(forKey: "pdfDownloadDirectory")

        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let body = try Data(contentsOf: pdf)
        for path in ["/report.pdf", "/download", "/append.pdf", "/retry.pdf", "/disabled.pdf", "/cli.pdf"] {
            FixtureProtocol.install(.init(headers: ["Content-Type": "application/pdf", "ETag": "pdf-v1"], body: body), path: path)
        }
        for path in ["/notes.txt", "/other.txt"] {
            FixtureProtocol.install(.init(headers: ["Content-Type": "text/plain"], body: Data("Notes remain in the ordinary documents directory.".utf8)), path: path)
        }
        let engine = DownloadEngine(transport: MockTransport(sourcePDF: pdf, delay: 30_000_000, latestVersion: 2),
            pdfTransport: URLSessionTransport(testConfiguration: config, policy: .externalPDF), requestInterval: 0, retryDelay: 0)
        let model = DownloadModel(engine: engine, preferences: preferences, stateURL: root.appendingPathComponent("workspace.json"))
        model.pdfDirectory = custom
        try expect(model.activePDFDirectory == nil && !FileManager.default.fileExists(atPath: custom.path),
            "remembering a folder neither enables it nor creates it")
        model.setPDFDirectoryEnabled(true)
        try expect(DownloadPreferences(preferences).activePDFDirectory?.path == custom.path, "PDF folder and enabled flag persist together")
        model.input = "2501.12345v2\nhttps://example.com/report.pdf\nhttps://example.com/download\nhttps://example.com/notes.txt"
        model.start()
        model.setPDFDirectoryEnabled(false)
        try expect(model.usesPDFDirectory, "settings cannot change while a batch is active")
        model.pdfDirectory = next // Even programmatic changes cannot redirect a running batch.
        _ = try model.submitQuickDownload("https://example.com/append.pdf")
        try await waitForQueue(model)
        try expect(model.items.count == 5 && model.items.allSatisfy { $0.state == .saved }, "mixed batch and appended quick download complete")
        for item in model.items {
            let parent = item.savedURL?.deletingLastPathComponent().path
            try expect(parent == (item.directURL?.pathExtension == "txt" ? folder.appendingPathComponent("Documents").path : custom.path),
                "actual PDFs, arxiv and quick downloads use the frozen custom directory; other documents retain categories")
        }
        try expect(!FileManager.default.fileExists(atPath: custom.appendingPathComponent("Papers").path)
            && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Papers").path)
            && !FileManager.default.fileExists(atPath: next.path), "PDFs have one copy and no extra Papers subfolder")
        let oldPaths = model.items.map(\.savedURL)
        model.persistWorkspace()
        let restored = DownloadModel(engine: engine, preferences: preferences, stateURL: root.appendingPathComponent("workspace.json"))
        try expect(restored.activePDFDirectory?.path == next.path && restored.items.map(\.savedURL) == oldPaths,
            "restart retains the new preference without rewriting existing paths")

        let source = try DownloadSource.parse("https://example.com/report.pdf")
        FixtureProtocol.install(.init(status: 304), path: "/report.pdf")
        let cached = try await engine.download(source, to: folder, organizeByType: true, pdfDirectory: custom)
        try expect(cached.alreadyExisted && FixtureProtocol.lastRequest("/report.pdf")?.value(forHTTPHeaderField: "If-None-Match") == "pdf-v1",
            "custom PDF directory keeps conditional caching")
        try createPDF(at: cached.url, shade: 0.2)
        let annotated = try Data(contentsOf: cached.url)
        FixtureProtocol.install(.init(headers: ["Content-Type": "application/pdf"], body: body), path: "/report.pdf")
        let collision = try await engine.download(source, to: folder, organizeByType: true, pdfDirectory: custom)
        try expect(collision.url != cached.url && (try Data(contentsOf: cached.url)) == annotated, "same-name download preserves locally changed PDF")

        let blocked = root.appendingPathComponent("blocked-pdf-folder")
        try Data("not a directory".utf8).write(to: blocked)
        model.pdfDirectory = blocked
        model.input = "https://example.com/retry.pdf\nhttps://example.com/other.txt"
        model.start(); try await waitForQueue(model)
        try expect(model.items[0].state == .failed && model.items[0].error?.contains("PDF 保存目录") == true && model.items[1].state == .saved,
            "unavailable PDF folder reports an error without fallback or blocking other document types")
        model.pdfDirectory = next
        model.retry(model.items[0].id); try await waitForQueue(model)
        try expect(model.items[0].savedURL?.deletingLastPathComponent().path == next.path, "retry uses the current PDF directory")
        _ = try await engine.download(DownloadSource.parse("https://example.com/download"), to: blocked, organizeByType: true, pdfDirectory: custom)
        try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Papers").path), "unused main root does not block a custom PDF download")
        model.setPDFDirectoryEnabled(false)
        model.input = "https://example.com/disabled.pdf"; model.start(); try await waitForQueue(model)
        try expect(model.items[0].savedURL?.deletingLastPathComponent().path == folder.appendingPathComponent("Papers").path
            && DownloadPreferences(preferences).pdfDirectory?.path == next.path && DownloadPreferences(preferences).activePDFDirectory == nil,
            "disabling restores Papers while remembering the optional directory")

        model.setPDFDirectoryEnabled(true)
        for override in [false, true] {
            let explicit = root.appendingPathComponent("cli-explicit", isDirectory: true)
            let arguments = ["https://example.com/cli.pdf"] + (override ? ["--output", explicit.path] : [])
            let console = CapturedConsole()
            let code = await CLIRunner.run(try CLIOptions.parse(arguments), version: "test", engine: engine, preferences: preferences,
                stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
            let output = URL(fileURLWithPath: console.output.trimmingCharacters(in: .whitespacesAndNewlines))
            try expect(code == 0 && output.deletingLastPathComponent().path == (override ? explicit.path : next.path)
                && DownloadPreferences(preferences).activePDFDirectory?.path == next.path,
                "CLI follows PDF preference unless explicit output overrides it without changing settings")
        }
        print("PASS PDF directory: opt-in persistence, content routing, batch snapshot, quick download, existing paths, cache, collision safety, failures, retry and CLI override")
    }

    @MainActor static func githubPDFTests(root: URL, pdf: URL) async throws {
        let link = "https://github.com/openai/math/blob/main/overview.pdf"
        let raw = "https://raw.githubusercontent.com/openai/math/main/overview.pdf"
        for (input, expected) in [
            (link, raw),
            ("<HTTPS://WWW.GITHUB.COM:443/openai/math/blob/main/overview.pdf?raw=true&utm_source=a,b;c#page=2>", raw),
            ("https://github.com/Org/Repo/blob/v1.0/docs/Report.PDF", "https://raw.githubusercontent.com/Org/Repo/v1.0/docs/Report.PDF"),
            ("https://github.com/org/repo/blob/abc123/docs/a%20b%23c%25.pdf", "https://raw.githubusercontent.com/org/repo/abc123/docs/a%20b%23c%25.pdf"),
            ("https://github.com/org/repo/blob/feature%2Fpapers/report.pdf", "https://raw.githubusercontent.com/org/repo/feature%2Fpapers/report.pdf"),
            (raw + "?token=a%2Fb", raw + "?token=a%2Fb")
        ] {
            let source = try DownloadSource.parse(input)
            try expect(source.directURL?.absoluteString == expected && source.reference == nil, "GitHub PDF canonicalization preserves encoded paths: \(input)")
            try expect(try DownloadSource.parse(source.directURL!.absoluteString) == source, "GitHub normalization is idempotent")
        }
        for input in ["https://github.com.evil.example/openai/math/blob/main/overview.pdf",
                      "https://example.com/openai/math/blob/main/overview.pdf", "https://github.com/openai/math/tree/main/overview.pdf",
                      "https://github.com/openai/math/blob/overview.pdf",
                      "https://github.com/openai/math/blob//overview.pdf", "https://github.com/openai/math/blob/main/overview.pdf/", "https://github.com/openai/math/blob/main/overview.pdf.exe"] {
            try expect(try DownloadSource.parse(input).directURL?.absoluteString == input, "unrelated or malformed preview routes stay unchanged")
        }
        for input in ["http://github.com/openai/math/blob/main/overview.pdf", "https://user@github.com/openai/math/blob/main/overview.pdf", "https://github.com:444/openai/math/blob/main/overview.pdf"] {
            try rejects({ _ = try DownloadSource.parse(input) }, "GitHub conversion retains URL safety checks")
        }
        let shared = link + "?raw=true&utm_source=a,b;c#page=2"
        let batch = try BatchInput(shared + "\n" + raw + "\n" + link)
        try expect(batch.entries.count == 1 && batch.duplicates == 2, "GitHub preview and raw links share one download identity")

        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let engine = DownloadEngine(pdfTransport: URLSessionTransport(testConfiguration: config, policy: .externalPDF), requestInterval: 0, retryDelay: 0)
        let folder = root.appendingPathComponent("github-pdfs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "arxiv-github-tests-\(UUID().uuidString)"; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(folder.path, forKey: "downloadRootDirectory")
        let path = "/openai/math/main/overview.pdf"
        FixtureProtocol.install(.init(headers: ["Content-Type": "application/octet-stream", "ETag": "\"github-1\""], body: try Data(contentsOf: pdf)), path: path)
        let model = DownloadModel(engine: engine, preferences: prefs)
        model.input = shared + "\n" + raw
        model.start(); try await waitForQueue(model)
        try expect(model.successes == 1 && model.duplicateCount == 1 && model.input.isEmpty, "UI downloads GitHub PDF and clears equivalent inputs")
        try expect(FixtureProtocol.count() == 1 && FixtureProtocol.lastRequest(path)?.url?.absoluteString == raw, "UI requests raw PDF without fetching the preview")

        FixtureProtocol.install(.init(status: 304), path: path)
        let console = CapturedConsole()
        let options = try CLIOptions.parse([link, raw, "--json"])
        let code = await CLIRunner.run(options, version: "test", engine: engine, preferences: prefs, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let report = try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any]
        let rows = report["results"] as! [[String: Any]]
        try expect(code == 0 && rows.count == 1 && rows[0]["input"] as? String == link && rows[0]["status"] as? String == "existing", "CLI preserves original link and reuses the UI download")
        try expect(FixtureProtocol.lastRequest(path)?.value(forHTTPHeaderField: "If-None-Match") == "\"github-1\"", "GitHub conversion retains conditional PDF caching")

        let state = root.appendingPathComponent("github-legacy.json")
        let legacy = DownloadItem(original: shared, reference: nil, directURL: URL(string: link + "?raw=true"), state: .failed)
        let log = ActivityEntry(level: .error, message: "旧下载失败", subject: nil, itemID: legacy.id)
        try WorkspaceStore.write(WorkspaceSnapshot(input: shared, items: [legacy], history: [legacy], logs: [log]), to: state)
        let restored = DownloadModel(engine: engine, preferences: prefs, stateURL: state)
        try expect(restored.persistenceNotice == nil && restored.items.first?.id == legacy.id && restored.history.first?.directURL?.absoluteString == raw && restored.logs.first?.id == log.id, "old GitHub sources migrate without losing queue, history or logs")
        restored.retry(legacy.id); try await waitForQueue(restored)
        try expect(restored.items[0].state == .existing && restored.input.isEmpty && FixtureProtocol.count("/openai/math/blob/main/overview.pdf") == 0, "legacy GitHub retry uses raw PDF cache")
        print("PASS GitHub PDF: encoded paths, strict host matching, shared deduplication, UI/CLI raw routing, cache reuse and legacy retry")
    }

    @MainActor static func huggingFaceTests(root: URL, pdf: URL) async throws {
        let link = "https://huggingface.co/papers/2608.15763"
        for (url, id) in [
            (link, "2608.15763"),
            ("<HTTPS://HUGGINGFACE.CO:443/papers/2608.15763/?utm_source=a,b;c#discussion>", "2608.15763"),
            ("https://www.huggingface.co/papers/2608.15763v2", "2608.15763v2"),
            ("https://hf.co/papers/2608.15763", "2608.15763"),
            ("https://huggingface.co/papers/hep-th/9901001v1", "hep-th/9901001v1")
        ] {
            let source = try DownloadSource.parse(url)
            try expect(source.reference?.identifier == id && source.directURL == nil && source.rateLimitKey == "arxiv", "HF paper uses arxiv metadata, PDF and pacing: \(url)")
        }
        for url in ["https://huggingface.co/papers", link + "/discussion", link + ".pdf", link + "v0",
                    "https://huggingface.co/papers/2613.15763", "https://huggingface.co/papers/https://arxiv.org/abs/2608.15763",
                    "https://huggingface.co.evil.example/papers/2608.15763", "https://example.com/papers/2608.15763",
                    "https://huggingface.co/org/model/resolve/main/report.pdf?key=a,b;c"] {
            try expect(try DownloadSource.parse(url).reference == nil, "only exact HF paper routes are normalized")
        }
        for url in ["http://huggingface.co/papers/2608.15763", "https://user@huggingface.co/papers/2608.15763", "https://huggingface.co:444/papers/2608.15763"] {
            try rejects({ _ = try DownloadSource.parse(url) }, "HF URLs retain HTTPS, credential and port checks")
        }
        let shared = link + "?utm_source=a,b;c#discussion"
        let batch = try BatchInput(shared + "\n2608.15763 https://arxiv.org/abs/2608.15763\n" + link + "v2")
        try expect(batch.entries.count == 2 && batch.duplicates == 2 && batch.entries[1].reference?.version == 2, "HF shares deduplication with arxiv while preserving requested versions and query punctuation")

        let suite = "arxiv-hf-test-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("hf-papers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prefs.set(folder.path, forKey: "downloadRootDirectory")
        let transport = MockTransport(sourcePDF: pdf, latestVersion: 1)
        let generic = MockTransport(sourcePDF: pdf, pdf: [.failure(.invalidPDF)])
        let engine = DownloadEngine(transport: transport, pdfTransport: generic, requestInterval: 0, retryDelay: 0)
        let model = DownloadModel(engine: engine, preferences: prefs)
        model.input = shared + "\n2608.15763\nbad-link"
        model.start()
        try await waitForQueue(model)
        try expect(model.successes == 1 && model.duplicateCount == 1 && model.input == "bad-link", "UI downloads HF and clears equivalent completed inputs")
        try expect(model.items[0].metadata?.reference.identifier == "2608.15763v1" && model.items[0].directURL == nil, "HF UI task retains arxiv metadata")
        try expect(await transport.pdfURLs == [URL(string: "https://arxiv.org/pdf/2608.15763v1")!], "HF download requests the arxiv PDF directly")
        try expect(await generic.pdfCalls == 0, "HF page is never fetched as a generic PDF")

        let state = root.appendingPathComponent("hf-legacy.json")
        let legacy = DownloadItem(original: link, reference: nil, directURL: URL(string: link), state: .failed)
        let other = DownloadItem(original: link + "/discussion", reference: nil, directURL: URL(string: link + "/discussion"), state: .failed)
        try WorkspaceStore.write(WorkspaceSnapshot(input: link, items: [legacy, other], history: [legacy], logs: []), to: state)
        let restored = DownloadModel(engine: engine, preferences: prefs, stateURL: state)
        try expect(restored.persistenceNotice == nil && restored.items.count == 2 && restored.items[0].id == legacy.id, "old HF failures do not invalidate the workspace")
        try expect(restored.items[0].reference?.identifier == "2608.15763" && restored.items[0].directURL == nil && restored.history[0].reference != nil, "old queue and history HF sources migrate to arxiv")
        try expect(restored.items[1].directURL == other.directURL, "unrecognized older HF pages remain readable")
        restored.retry(legacy.id)
        try await waitForQueue(restored)
        try expect(restored.items[0].state == .existing && restored.input.isEmpty, "old HF retry reuses the trusted arxiv PDF and clears its input")
        let calls = await (transport.pdfCalls, generic.pdfCalls)
        try expect(calls == (1, 0), "old HF retry does not duplicate the PDF transfer")
        print("PASS HF papers: canonicalization, aliases, shared deduplication, UI arxiv routing, input clearing and legacy retry")
    }

    @MainActor static func genericPDFTests(root: URL, pdf: URL) async throws {
        let source = try DownloadSource.parse("https://MIRROS.ai:443/report/agent-garten.pdf#page=2")
        try expect(source.directURL?.absoluteString == "https://mirros.ai/report/agent-garten.pdf", "generic canonical URL and fragment removal")
        for bad in ["http://example.com/a.pdf", "file:///tmp/a.pdf", "https://u:p@example.com/a.pdf", "https://example.com:444/a.pdf", "https://localhost/a.pdf", "https://printer.local/a.pdf", "https://127.0.0.1/a.pdf", "https://127.1/a.pdf", "https://10.0.0.1/a.pdf", "https://169.254.169.254/a.pdf", "https://100.64.0.1/a.pdf", "https://[::1]/a.pdf", "https://[::ffff:127.0.0.1]/a.pdf", "https://[fe80::1]/a.pdf", "https://arxiv.org/invalid.pdf"] {
            try rejects({ _ = try DownloadSource.parse(bad) }, "unsafe generic input accepted: \(bad)")
        }
        try expect(PublicHTTPS.isPublicAddress("8.8.8.8") && PublicHTTPS.isPublicAddress("2606:4700::1111"), "public IPv4/IPv6 accepted")
        try expect(try DownloadSource.parse("https://例子.测试/p.pdf").directURL?.host == "xn--fsqu00a.xn--0zwm56d", "IDNA hostname uses canonical public hostname")
        for ip in ["0.0.0.0", "172.31.2.3", "192.168.1.1", "192.0.2.1", "198.18.1.1", "224.0.0.1", "255.255.255.255", "2001:db8::1", "2002:7f00:1::"] {
            try expect(!PublicHTTPS.isPublicAddress(ip), "reserved address accepted")
        }
        let signed = "https://example.com/download?key=a,b;c&token=x%2Fy"
        let batch = try BatchInput("2501.12345；2501.12345 https://example.com/p.pdf#page=1\nhttps://example.com/p.pdf#page=2 \(signed)")
        try expect(batch.entries.count == 3 && batch.duplicates == 2 && batch.entries.last?.source?.directURL?.absoluteString == signed, "mixed dedup and signed URL punctuation preserved")
        try expect(!NetworkPolicy.allows(source.directURL), "arxiv allowlist remains strict")
        let injected = try DownloadSource.parse("https://example.com/%1B%5D52%3Bc%3Bc29tZQ%3D%3D%07.pdf")
        let safeConsole = CapturedConsole()
        let safeProgress = CLIConsole(identifier: injected.label, interactive: true, color: true, cursor: true, write: { safeConsole.stderr($0) })
        safeProgress.receive(.checkingLocal)
        try expect(!safeConsole.errors.contains("\u{1b}]52") && !safeConsole.errors.contains("\u{7}"), "encoded PDF path cannot inject terminal OSC")

        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let generic = URLSessionTransport(testConfiguration: config, policy: .externalPDF)
        let arxiv = URLSessionTransport(testConfiguration: config)
        let engine = DownloadEngine(transport: arxiv, pdfTransport: generic, requestInterval: 0, retryDelay: 0)
        let folder = root.appendingPathComponent("generic-pdfs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ref = try DownloadSource.parse("https://example.com/report.pdf")
        let body = try Data(contentsOf: pdf)
        let changed = root.appendingPathComponent("changed.pdf"); try createPDF(at: changed, shade: 0.2)
        let changedBody = try Data(contentsOf: changed)
        let headers = ["Content-Type": "application/pdf", "ETag": "\"e1\"", "Content-Disposition": "attachment; filename=original.pdf"]
        FixtureProtocol.install(.init(headers: headers, body: body), path: "/report.pdf")
        let first = try await engine.download(ref, to: folder)
        try expect(first.metadata == nil && first.url.lastPathComponent == "original.pdf" && first.pages == 1, "generic filename without fabricated arxiv metadata")
        let mtime = try FileManager.default.attributesOfItem(atPath: first.url.path)[.modificationDate] as! Date
        FixtureProtocol.install(.init(status: 304), path: "/report.pdf")
        let reused = try await engine.download(ref, to: folder)
        try expect(reused.alreadyExisted && reused.url == first.url && FixtureProtocol.lastRequest("/report.pdf")?.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"", "conditional GET and 304 reuse")
        try expect(try FileManager.default.attributesOfItem(atPath: first.url.path)[.modificationDate] as? Date == mtime, "reuse leaves original unchanged")

        let newHeaders = ["ETag": "\"e2\"", "Content-Disposition": "attachment; filename=updated.pdf"]
        FixtureProtocol.install(.init(headers: newHeaders, body: changedBody), path: "/report.pdf")
        let updated = try await engine.download(ref, to: folder)
        try expect(updated.url != first.url && !updated.alreadyExisted && FileManager.default.fileExists(atPath: first.url.path), "remote update preserves prior file")
        FixtureProtocol.install(.init(status: 304), path: "/report.pdf")
        let latest = try await engine.download(ref, to: folder)
        try expect(latest.url == updated.url && FixtureProtocol.lastRequest("/report.pdf")?.value(forHTTPHeaderField: "If-None-Match") == "\"e2\"", "newest cache chosen after a title/filename update")
        try body.write(to: updated.url)
        FixtureProtocol.install(.init(headers: newHeaders, body: changedBody), path: "/report.pdf")
        _ = try await engine.download(ref, to: folder)
        // The modified newest file may fall back to a verified older resource,
        // but may never send the modified file's e2 validator.
        try expect(FixtureProtocol.lastRequest("/report.pdf")?.value(forHTTPHeaderField: "If-None-Match") != "\"e2\"", "local edits invalidate cache fingerprint")

        let redirectSource = try DownloadSource.parse("https://example.com/redirect.pdf")
        FixtureProtocol.install(.init(headers: ["ETag": "\"1\""], body: body, finalURL: URL(string: "https://cdn.example.com/old.pdf")), path: "/redirect.pdf")
        _ = try await engine.download(redirectSource, to: folder)
        FixtureProtocol.install(.init(headers: ["ETag": "\"1\""], body: changedBody, finalURL: URL(string: "https://cdn.example.com/new.pdf")), path: "/redirect.pdf")
        _ = try await engine.download(redirectSource, to: folder)
        try expect(FixtureProtocol.lastRequest("/redirect.pdf")?.value(forHTTPHeaderField: "If-None-Match") == nil, "redirect targets never reuse another resource's ETag")
        FixtureProtocol.install([.init(status: 304, finalURL: URL(string: "https://cdn.example.com/other.pdf")), .init(body: body)], path: "/report.pdf")
        let mismatched = try await engine.download(ref, to: folder)
        try expect(try Data(contentsOf: mismatched.url) == body && FixtureProtocol.lastRequest("/report.pdf")?.value(forHTTPHeaderField: "If-None-Match") == nil, "mismatched 304 falls back to unconditional download")

        let redirectConditional = try DownloadSource.parse("https://example.com/conditional-redirect.pdf")
        FixtureProtocol.install(.init(headers: ["ETag": "redirect-v1"], body: body), path: "/conditional-redirect.pdf")
        _ = try await engine.download(redirectConditional, to: folder)
        FixtureProtocol.install([.init(redirect: URL(string: "https://cdn.example.com/redirected-304.pdf")), .init(body: body)], path: "/conditional-redirect.pdf")
        FixtureProtocol.install(.init(status: 304), path: "/redirected-304.pdf")
        let redirectedRecovery = try await engine.download(redirectConditional, to: folder)
        try expect(try Data(contentsOf: redirectedRecovery.url) == body && FixtureProtocol.lastRequest("/conditional-redirect.pdf")?.value(forHTTPHeaderField: "If-None-Match") == nil, "actual redirect 304 clears cached validator before unconditional retry")

        let invalidFolder = root.appendingPathComponent("generic-invalid"); try FileManager.default.createDirectory(at: invalidFolder, withIntermediateDirectories: true)
        for (path, reply) in [("/partial.pdf", FixtureProtocol.Reply(status: 206, body: body)), ("/web.pdf", .init(body: Data("<html>not a pdf</html>".utf8))), ("/unsolicited.pdf", .init(status: 304))] {
            FixtureProtocol.install(reply, path: path)
            do { _ = try await engine.download(DownloadSource.parse("https://example.com" + path), to: invalidFolder); throw TestFailure.failed("generic invalid response saved") }
            catch DownloadError.http(206, _) where path == "/partial.pdf" { }
            catch DownloadError.invalidPDF where path == "/web.pdf" { }
            catch DownloadError.http(304, _) where path == "/unsolicited.pdf" { }
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: invalidFolder.path).isEmpty, "rejected responses leave no files")
        let blocked = URLSessionTransport(testConfiguration: config, policy: .externalPDF, resolver: { _ in ["8.8.8.8", "10.0.0.1"] })
        let before = FixtureProtocol.count()
        do { _ = try await blocked.download(for: URLRequest(url: URL(string: "https://example.com/secret.pdf")!), progress: { _ in }); throw TestFailure.failed("private DNS requested") }
        catch DownloadError.unsafeResponse { }
        try expect(FixtureProtocol.count() == before, "private DNS answer rejected before HTTP")
        let slowDNS = URLSessionTransport(testConfiguration: config, policy: .externalPDF, resolver: { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return ["8.8.8.8"] })
        let dnsTask = Task { try await slowDNS.download(for: URLRequest(url: URL(string: "https://example.com/dns.pdf")!), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 20_000_000); dnsTask.cancel()
        do { _ = try await dnsTask.value; throw TestFailure.failed("DNS cancellation ignored") } catch is CancellationError { }

        let delegate = ProgressObserver(policy: .externalPDF, allowNotModified: true, resolver: { _ in ["8.8.8.8"] })
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: ref.directURL!)
        var redirected = URLRequest(url: URL(string: "https://cdn.example.com/new.pdf")!)
        redirected.setValue("\"1\"", forHTTPHeaderField: "If-None-Match")
        redirected.setValue("yesterday", forHTTPHeaderField: "If-Modified-Since")
        let response = HTTPURLResponse(url: ref.directURL!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        let followed: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { continuation.resume(returning: $0) }
        }
        try expect(followed != nil && followed?.value(forHTTPHeaderField: "If-None-Match") == nil && followed?.value(forHTTPHeaderField: "If-Modified-Since") == nil && !delegate.acceptsNotModified, "redirect strips resource-specific validators")
        delegate.stop()
        let rejected = ProgressObserver(policy: .externalPDF, resolver: { _ in ["127.0.0.1"] })
        let unsafe: URLRequest? = await withCheckedContinuation { continuation in
            rejected.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { continuation.resume(returning: $0) }
        }
        try expect(unsafe == nil && rejected.failure != nil, "redirect private DNS blocked")
        rejected.stop()
        let cancelling = ProgressObserver(policy: .externalPDF, resolver: { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return ["8.8.8.8"] })
        let redirectWait = Task { await withCheckedContinuation { continuation in
            cancelling.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { continuation.resume(returning: $0) }
        } }
        try await Task.sleep(nanoseconds: 20_000_000); cancelling.stop()
        try expect(await redirectWait.value == nil, "redirect DNS cancellation never resumes with a request")

        // Generic requests use their own lock; an arxiv download cannot block them.
        let coordination = RequestCoordinator(directory: root.appendingPathComponent("generic-coordination"))
        let held = try await coordination.acquire()
        FixtureProtocol.install(.init(body: body), path: "/independent.pdf")
        let independent = DownloadEngine(pdfTransport: generic, requestInterval: 0, coordinator: coordination)
        let started = ContinuousClock().now
        _ = try await independent.download(DownloadSource.parse("https://example.com/independent.pdf"), to: folder)
        try expect(started.duration(to: ContinuousClock().now) < .seconds(2), "generic transfer remains independent from arxiv lock")
        withExtendedLifetime(held) { }

        let suite = "arxiv-generic-tests-\(UUID().uuidString)"; let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(folder.path, forKey: "downloadRootDirectory")
        FixtureProtocol.install(.init(status: 429, headers: ["Retry-After": "600"]), path: "/limited.pdf")
        FixtureProtocol.install(.init(body: body), path: "/ok.pdf")
        FixtureProtocol.install(.init(body: atom()), path: "/api/query")
        FixtureProtocol.install(.init(body: body), path: "/pdf/2501.12345v2")
        let console = CapturedConsole()
        let args = try CLIOptions.parse(["https://limited.example.com/limited.pdf", "https://limited.example.com/skipped.pdf", "https://other.example.com/ok.pdf", "2501.12345", "--json"])
        let code = await CLIRunner.run(args, version: "test", engine: engine, preferences: preferences, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let report = try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any]
        let rows = report["results"] as! [[String: Any]]
        try expect(code == 1 && rows.map { $0["status"] as! String } == ["paused", "paused", "saved", "saved"], "CLI mixed batch pauses only limited origin")

        FixtureProtocol.install(.init(body: body), path: "/ui.pdf")
        let model = DownloadModel(engine: engine, preferences: preferences, opener: { _ in true })
        let link = "https://example.com/ui.pdf?x=a,b;c"
        model.input = link + "\n" + link + "#page=1\nbad-link"
        model.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while model.busy { try await Task.sleep(nanoseconds: 10_000_000); if ContinuousClock().now > deadline { throw TestFailure.failed("generic UI queue stalled") } }
        try expect(model.successes == 1 && model.duplicateCount == 1 && model.input == "bad-link" && model.items[0].directURL != nil, "UI generic dedup and per-file input clearing")
        try expect(model.items[0].canRetry == false && model.items[0].title == model.items[0].savedURL!.deletingPathExtension().lastPathComponent, "UI generic title matches saved filename")
        model.openSource(model.items[0]); try expect(model.notice == nil, "UI generic source menu")
        FixtureProtocol.install(.init(body: body), path: "/release.pdf")
        for _ in 0..<20 {
            weak var released: URLSessionTransport?
            do {
                let current = URLSessionTransport(testConfiguration: config, policy: .externalPDF)
                released = current
                _ = try await DownloadEngine(pdfTransport: current, requestInterval: 0, retryDelay: 0).download(DownloadSource.parse("https://example.com/release.pdf"), to: folder)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            try expect(released == nil, "generic transfer releases transport/delegates")
        }
        print("PASS generic PDF: parsing, mixed batches, ETag/304, cache updates/edits, redirects, private DNS, cancellation, filenames, arxiv lock isolation and UI input cleanup")
    }
}
