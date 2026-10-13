import Foundation

private actor DouyinTransport: HTTPTransport {
    struct Reply { let data: Data; var status = 200; var url: URL?; var retryAfter: String? }
    var replies: [Reply]
    var requests: [URLRequest] = []
    let delay: UInt64
    init(_ replies: [Reply], delay: UInt64 = 0) { self.replies = replies; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        guard !replies.isEmpty else { throw TestFailure.failed("unexpected Douyin request") }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                          headerFields: reply.retryAfter.map { ["Retry-After": $0] })!)
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        throw TestFailure.failed("resolver must not transfer files")
    }
}

private actor DouyinEngineProbe {
    var authenticationCalls = 0
    var attempts: [Bool] = []
    func authentication(valid: Bool) throws -> BrowserAuthenticationSelection? {
        authenticationCalls += 1
        if !valid { throw DownloadError.browserAuthentication(.invalidSelection) }
        return try BrowserAuthenticationSelection(browser: .chrome)
    }
    func attempt(_ selection: BrowserAuthenticationSelection?) { attempts.append(selection != nil) }
}

private final class DouyinEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var authenticationEvents = 0
    func receive(_ event: DownloadEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event { case .browserAuthentication, .anonymousFallback: authenticationEvents += 1; default: break }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return authenticationEvents }
}

extension CoreTests {
    @MainActor static func douyinTests(root: URL) async throws {
        let id = "7692018523757285605", url = URL(string: "https://www.douyin.com/video/7692018523757285605")!
        let shared = URL(string: "https://v.douyin.com/fixture/")!
        let share = URL(string: "https://www.iesdouyin.com/share/video/7692018523757285605/?from_ssr=1")!
        func payload(id: String = "7692018523757285605", urls: [String] = ["https://cdn.example.org/video.mp4"], images: Bool = false) throws -> Data {
            var item: [String: Any] = ["aweme_id": id, "desc": "匿名视频 🌍 \"100%\"", "video": [
                "play_addr": ["url_list": urls, "width": 576, "height": 1024, "data_size": 3000],
                "is_h265": 0, "duration": 25867,
                "bit_rate": [["play_addr": ["url_list": ["https://cdn.example.org/high.mp4"], "width": 720, "height": 1280],
                              "is_h265": 1, "bit_rate": 737020]]],
                // These downloader controls must never enter the trusted manifest.
                "_filename": "/tmp/untrusted", "__postprocessors": [["key": "Exec", "exec_cmd": "untrusted"]]]
            if images { item["images"] = [["url_list": ["https://cdn.example.org/photo.jpg"]]] }
            return try JSONSerialization.data(withJSONObject: ["status_code": 0, "aweme_details": [item]])
        }
        let data = try payload(), direct = DouyinTransport([.init(data: data)])
        let info = try await DouyinResolver(transport: direct).resolve(url)
        try expect(info.id == id && info.title == "匿名视频 🌍 \"100%\"" && info.duration == 25.867 && info.formats.count == 2,
                   "anonymous metadata retains exact video identity, Unicode, duration and available quality")
        try expect(info.formats[0].vcodec == "h264" && info.formats[1].vcodec == "hevc" && info.formats[1].height == 1280,
                   "format dimensions and codecs describe the actual stream")
        let requests = await direct.requests
        let request = requests[0], query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(requests.count == 1 && request.url!.host == "www.iesdouyin.com" && query == [URLQueryItem(name: "aweme_ids", value: "[\(id)]")],
                   "video metadata uses the official anonymous endpoint without the image-only request_source parameter")
        try expect(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "User-Agent") == DouyinResolver.userAgent,
                   "native metadata access carries no browser/session credentials")
        let encoded = try JSONEncoder().encode(info), object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try expect(object["_filename"] == nil && object["__postprocessors"] == nil && object["extractor"] as? String == "FolioakDouyin",
                   "only whitelisted metadata reaches yt-dlp")
        let redirect = DouyinTransport([.init(data: Data(), url: share), .init(data: data)])
        let redirected = try await DouyinResolver(transport: redirect).resolve(shared)
        let redirectRequests = await redirect.requests
        try expect(redirected.id == id && redirectRequests.count == 2,
                   "mobile share redirects resolve to the same video before metadata access")
        for target in ["https://evil.example.org/share/video/123", "https://www.iesdouyin.com/share/note/123/", "https://www.douyin.com/login", "http://www.douyin.com/video/123"] {
            let mock = DouyinTransport([.init(data: Data(), url: URL(string: target)!)])
            do { _ = try await DouyinResolver(transport: mock).resolve(shared); throw TestFailure.failed("unsafe redirect accepted") }
            catch DownloadError.unsafeResponse {}
            try expect(await mock.requests.count == 1, "unexpected redirects never make a metadata request")
        }
        for bad in [Data(), Data("<html>verification</html>".utf8), Data("{}".utf8),
                    Data(#"{"status_code":1,"aweme_details":[]}"#.utf8), Data(#"{"status_code":0,"aweme_details":null,"filter_list":[{"reason":8}]}"#.utf8),
                    try payload(id: "123"), try payload(images: true)] {
            do { _ = try DouyinResolver.information(bad, videoID: id); throw TestFailure.failed("invalid/unavailable Douyin metadata accepted") }
            catch DownloadError.metadata {}
        }
        let unsafe = try JSONSerialization.data(withJSONObject: ["status_code": 0, "aweme_details": [["aweme_id": id, "video": [
            "play_addr": ["url_list": ["file:///etc/passwd", "https://127.0.0.1/x", "https://user:pass@cdn.example.org/x", "http://cdn.example.org/x"]]]]]])
        do { _ = try DouyinResolver.information(unsafe, videoID: id); throw TestFailure.failed("unsafe media URLs accepted") }
        catch DownloadError.metadata {}
        do { _ = try DouyinResolver.information(Data(repeating: 32, count: ResourceLimits.metadataBytes + 1), videoID: id); throw TestFailure.failed("oversized metadata accepted") }
        catch DownloadError.limit {}
        for code in [403, 429] {
            let mock = DouyinTransport([.init(data: Data(), status: code, retryAfter: "180")])
            do { _ = try await DouyinResolver(transport: mock).resolve(url); throw TestFailure.failed("HTTP error ignored") }
            catch DownloadError.cooldown(let delay) { try expect(code == 429 && delay == 180, "rate limit keeps server cooldown") }
            catch DownloadError.http(let status, _) { try expect(status == 403, "403 does not infer a login requirement") }
            try expect(await mock.requests.count == 1, "terminal failures do not loop through backend fallbacks")
        }
        for raw in ["ERROR: HTTP Error 403: Forbidden", "ERROR: Login required", "ERROR: Fresh cookies are needed"] {
            let failure = MediaDownloader.failure(raw, url: url)
            try expect(!BrowserAuthenticationIssue.matches(failure.message), "anonymous playback rejection does not offer browser login recovery")
        }
        guard case .cooldown(60) = MediaDownloader.failure("ERROR: HTTP 429; try cookies", url: url) else {
            throw TestFailure.failed("Douyin cookie-style diagnostics masked rate limiting")
        }
        // Exercise the engine boundary, where the global authentication provider
        // used to inject bogus failures and retry the anonymous backend twice.
        for validSelection in [true, false] {
            for scenario in ["success", "rejected", "limited", "cancelled"] {
                let probe = DouyinEngineProbe(), events = DouyinEvents()
                let engine = DownloadEngine(mediaAuthentication: { try await probe.authentication(valid: validSelection) }, mediaDownload: { _, _, _, _, auth, _ in
                    await probe.attempt(auth)
                    switch scenario {
                    case "rejected": throw MediaDownloader.failure("ERROR: HTTP Error 403: Forbidden", url: url)
                    case "limited": throw DownloadError.cooldown(180)
                    case "cancelled": throw CancellationError()
                    default: return SavedDocument(title: "Anonymous fixture", url: root.appendingPathComponent("fixture.mp4"), alreadyExisted: false, pages: 0)
                    }
                })
                do {
                    _ = try await engine.download(.media(url), to: root, event: { events.receive($0) })
                    try expect(scenario == "success", "anonymous engine cannot report a rejected transfer as saved")
                } catch DownloadError.metadata { try expect(scenario == "rejected", "anonymous rejection remains the terminal cause") }
                catch DownloadError.cooldown(let delay) { try expect(scenario == "limited" && delay == 180, "engine preserves the server cooldown") }
                catch is CancellationError { try expect(scenario == "cancelled", "engine preserves cancellation") }
                let authCalls = await probe.authenticationCalls, attempts = await probe.attempts
                try expect(authCalls == 0 && attempts == [false] && events.count == 0,
                           "Douyin bypasses browser selection and authentication fallback for every outcome")
            }
        }
        let slow = DouyinTransport([.init(data: data)], delay: 30_000_000_000)
        let cancelled = Task { try await DouyinResolver(transport: slow).resolve(url) }
        for _ in 0..<100 {
            if await !slow.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw TestFailure.failed("metadata ignored cancellation") } catch is CancellationError {}

        let tools = try MediaTools.installed(), folder = root.appendingPathComponent("douyin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("video.json")
        let selected = try BrowserAuthenticationSelection(browser: .chrome)
        let args = try MediaDownloader.arguments(url: url, format: .automatic, tools: tools, folder: folder, authentication: selected, informationFile: manifest)
        try expect(args.suffix(2) == ["--load-info-json", manifest.path] && !args.contains(url.absoluteString) &&
                   args.contains("--no-cookies-from-browser") && !args.contains("--cookies-from-browser") && args.contains("--no-plugin-dirs"),
                   "resolved Douyin skips the broken extractor and cookie reader without enabling plugins")

        let mockTools = folder.appendingPathComponent("mock tools"), staging = mockTools.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mockTools.appendingPathComponent("qjs"), withDestinationURL: tools.executable("qjs"))
        let shim = mockTools.appendingPathComponent("yt-dlp")
        try Data(#"""
        #!/bin/sh
        mock_dir=${0%/*}
        next=
        for argument do
            if [ "$next" = info ]; then
                printf '%s' "$argument" > "$mock_dir/observed-path"
                /bin/cp "$argument" "$mock_dir/observed.json"
            fi
            next=
            if [ "$argument" = '--load-info-json' ]; then next=info; fi
            if [ "$argument" = '--cookies-from-browser' ]; then exit 9; fi
        done
        mode=$(/bin/cat "$mock_dir/mode")
        if [ "$mode" = cancel ]; then /bin/sleep 30; fi
        if [ "$mode" = fail ]; then printf 'ERROR: fixture transfer failed\n'; exit 1; fi
        printf 'APP_FILE:"%s/staging/fixture.mp4"\n' "$mock_dir"
        """#.utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        for mode in ["success", "fail", "cancel"] {
            try Data(mode.utf8).write(to: mockTools.appendingPathComponent("mode"))
            try? FileManager.default.removeItem(at: mockTools.appendingPathComponent("observed-path"))
            let resolver = DouyinResolver(transport: DouyinTransport([.init(data: data)]))
            let job = Task { try await MediaDownloader.runDownloader(url, format: .automatic, tools: MediaTools(directory: mockTools), folder: staging,
                                                                    authentication: selected, douyinResolver: resolver) }
            if mode == "cancel" {
                let observed = mockTools.appendingPathComponent("observed-path")
                for _ in 0..<200 where !FileManager.default.fileExists(atPath: observed.path) { try await Task.sleep(nanoseconds: 10_000_000) }
                try expect(FileManager.default.fileExists(atPath: observed.path), "cancel test reached the actual downloader process")
                let path = try String(contentsOf: observed, encoding: .utf8)
                let permissions = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
                try expect(permissions.intValue == 0o700, "signed media metadata stays in a private temporary directory")
                job.cancel()
            }
            do {
                _ = try await job.value
                try expect(mode == "success", "failing/cancelled process cannot report success")
            } catch is CancellationError { try expect(mode == "cancel", "cancellation propagates") }
            catch DownloadError.metadata { try expect(mode == "fail", "transfer failure propagates") }
            let observed = try JSONSerialization.jsonObject(with: Data(contentsOf: mockTools.appendingPathComponent("observed.json"))) as! [String: Any]
            try expect(observed["id"] as? String == id && (try FileManager.default.contentsOfDirectory(atPath: staging.path)).allSatisfy { !$0.hasPrefix(".douyin-") },
                       "resolved information is used once and removed after success, failure or joined cancellation")
        }

        // Run the actual bundled downloader and audio postprocessor on a native
        // resolver manifest, replacing only the CDN with a local media fixture.
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        let movie = folder.appendingPathComponent("source.mp4")
        let mux = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-i", fixtures.appendingPathComponent("h264.mp4").path,
            "-i", fixtures.appendingPathComponent("tone.m4a").path, "-map", "0:v", "-map", "1:a", "-c", "copy", movie.path
        ]) { _ in }
        try expect(mux == 0, "Douyin integration fixture mux")
        var local = object
        local["formats"] = [["url": movie.absoluteString, "ext": "mp4", "format_id": "fixture", "vcodec": "h264", "acodec": "aac"]]
        try JSONSerialization.data(withJSONObject: local).write(to: manifest)
        for format in MediaFormat.allCases {
            let destination = folder.appendingPathComponent(format.rawValue)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let arguments = try MediaDownloader.arguments(url: url, format: format, tools: tools, folder: destination, informationFile: manifest)
            let output = MediaOutput()
            let status = try await MediaProcess().run(try tools.executable("yt-dlp"), arguments: arguments + ["--enable-file-urls"]) { output.receive($0, event: { _ in }) }
            try expect(status == 0 && output.files.count == 1 && output.title == info.title, "resolved manifest transfers once through the real downloader")
            let files = try MediaDownloader.validatedOutputs(output.files, in: destination)
            let published = try await FileStorage.publish(files, title: output.title, to: destination)
            let streams = try await FileStorage.validate(published.url, extension: published.url.pathExtension)
            try expect(streams.contains { $0.codec_type == "audio" } && (format == .audio ? streams.allSatisfy { $0.codec_type == "audio" } : streams.contains { $0.isVideo }),
                       "real video/audio output is validated before publication")
        }
        print("PASS Douyin: anonymous official API, redirects, identity and format validation, no cookie access, malformed/unavailable content, unsafe URLs, rate limits, cancellation and real bundled video/audio transfer")
    }
}
