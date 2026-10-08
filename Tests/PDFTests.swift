import Foundation
import PDFKit

extension CoreTests {
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
        preferences.set(folder.path, forKey: "saveDirectory")
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
