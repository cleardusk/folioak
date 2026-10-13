import Foundation
import AppKit
import SwiftUI
import Darwin

private final class ProcessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value += text }
}

extension CoreTests {
    @MainActor static func mediaTests(root: URL) async throws {
        try browserAuthenticationTests(root: root)
        try await browserAuthenticationProcessTests(root: root)
        try mediaRetryPolicyTests(root: root)
        let bv = try DownloadSource.parse("BV1MaHp6KENU")
        let bvURL = try DownloadSource.parse("https://www.bilibili.com/video/BV1MaHp6KENU/")
        try expect(bv == bvURL && bv.isMedia && bv.rateLimitKey == "media:bilibili", "complete bare BV identifier routes to the existing Bilibili pipeline")
        try expect(try DownloadSource.parse("  BV1MaHp6KENU\n") == bv, "BV parsing preserves identifier case and trims surrounding whitespace")
        for invalid in ["BV1", "BV1MaHp6KEN", "BV1MaHp6KENUx", "bv1MaHp6KENU", "BV1MaHp6KEN0", "BV1MaHp6KENI", "BV1MaHp6KENl", "prefixBV1MaHp6KENU", "BV1MaHp6KENU.txt"] {
            try rejects({ _ = try DownloadSource.parse(invalid) }, "ambiguous or malformed BV input keeps its existing rejection: \(invalid)")
        }
        try expect(try DownloadSource.tokens(in: "BV1MaHp6KENU\n1706.03762").map(DownloadSource.parse).map(\.isMedia) == [true, false], "BV identifiers coexist with paper inputs in a batch")
        for url in ["https://youtu.be/BaW_jenozKc", "https://www.youtube.com/watch?v=BaW_jenozKc", "https://www.bilibili.com/video/BV1xx411c7mD", "https://x.com/user/status/123/video/2"] {
            try expect(try DownloadSource.parse(url).isMedia, "media source routing")
        }
        for url in ["https://x.com/user", "https://www.youtube.com/playlist?list=123", "https://youtube.com.evil.invalid/watch?v=1"] {
            try rejects({ _ = try DownloadSource.parse(url) }, "unsupported media path rejected")
        }
        let toutiao = try DownloadSource.parse("https://toutiao.com/video/7505382061495176511/?from=share")
        try expect(toutiao.isMedia && toutiao.directURL?.host == "www.toutiao.com", "Toutiao video normalizes to bundled extractor host")
        for url in ["https://www.toutiao.com/", "https://www.toutiao.com/article/7505382061495176511/", "https://v.toutiao.com/abc/", "https://www.toutiao.com/video/not-a-number/"] {
            try rejects({ _ = try DownloadSource.parse(url) }, "Toutiao non-video pages never route to PDF")
        }
        let sharedNote = try DownloadSource.parse("https://xiaohongshu.com/discovery/item/674051740000000007027a15?xsec_token=a%2Bb%3D&xsec_source=app_share#ignored")
        try expect(sharedNote.isMedia && sharedNote.directURL?.host == "www.xiaohongshu.com" && sharedNote.directURL?.query == "xsec_token=a%2Bb%3D&xsec_source=app_share" && sharedNote.directURL?.fragment == nil,
                   "Xiaohongshu canonicalization preserves the access token and drops only the fragment")
        for link in ["http://xhslink.com/a/abc123", "https://xhslink.com/m/abc123", "https://xhslink.com/abc123",
                     "https://v.douyin.com/abc123/", "https://www.douyin.com/video/6961737553342991651",
                     "https://www.tiktok.com/@demo/video/1234567890", "https://vm.tiktok.com/ZTR45GpSF/", "https://vt.tiktok.com/ZSe4FqkKd", "https://tiktok.com/t/ZTRC5xgJp",
                     "https://instagram.com/reel/ABC_123-/", "https://www.instagram.com/demo/p/ABC123/",
                     "https://vimeo.com/76979871", "https://vimeo.com/76979871/abcdef1234", "https://player.vimeo.com/video/76979871?h=abcdef1234", "https://vimeo.com/channels/staffpicks/76979871"] {
            let media = try DownloadSource.parse(link)
            try expect(media.isMedia && media.directURL?.scheme == "https" && MediaDownloader.accepts(media.webURL), "mainstream individual media and shared links route to the media engine: \(link)")
        }
        for link in ["https://www.xiaohongshu.com/user/profile/abc", "https://www.xiaohongshu.com/explore/not-a-note",
                     "https://xhslink.com/a/", "https://www.douyin.com/user/123", "https://www.douyin.com/note/123",
                     "https://www.tiktok.com/@demo", "https://www.tiktok.com/@demo/collection/name-123", "https://www.tiktok.com/music/demo-123",
                     "https://www.instagram.com/demo/", "https://www.instagram.com/stories/demo/123", "https://www.instagram.com/reels/audio/123/", "https://www.instagram.com/share/reel/abc123/",
                     "https://vimeo.com/showcase/123", "https://vimeo.com/channels/staffpicks", "https://player.vimeo.com/123",
                     "http://example.com/file.mp4", "https://user:pass@www.xiaohongshu.com/explore/674051740000000007027a15"] {
            try rejects({ _ = try DownloadSource.parse(link) }, "profiles, collections, malformed media and unsafe URLs are rejected: \(link)")
        }
        try expect(!(try DownloadSource.parse("https://xiaohongshu.com.example.org/file.pdf")).isMedia, "lookalike domains never gain media routing")
        try expect(MediaDownloader.failure("ERROR: No video formats found", url: sharedNote.webURL).localizedDescription.contains("完整分享链接"), "Xiaohongshu missing formats explain access parameters without asserting the post is an image")
        try expect(MediaDownloader.failure("ERROR: Unsupported URL: https://www.xiaohongshu.com/login", url: sharedNote.webURL).localizedDescription.contains("登录"), "short-link redirects to login retain authentication guidance")
        for ext in ["png", "mp3", "mp4"] {
            try expect(try DownloadSource.parse("https://example.com/file." + ext).isPaper == false, "all native media types use media destination")
        }
        let source = try DownloadSource.parse("https://example.com/photo.png?token=abc")
        try expect(!source.isPaper && !source.isMedia && source.directURL?.query == "token=abc", "signed image URL stays intact")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = root.appendingPathComponent("photo.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        try await browserAuthenticationProviderTests(root: root, image: image)
        try await anonymousFallbackTests(root: root, image: image)
        try await authenticationInterfaceTests()
        try await githubFileTests(root: root, image: image)
        try await directMediaRegressionTests(root: root, image: image)
        let folder = root.appendingPathComponent("media-output")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parentWithoutSlash = URL(fileURLWithPath: folder.path, isDirectory: false)
        let output = MediaOutput()
        let childPath = folder.appendingPathComponent("中文 视频 [1].mkv").path
        let encoded = String(data: try JSONEncoder().encode(childPath), encoding: .utf8)!
        output.receive("APP_FILE:" + encoded) { _ in }
        try expect(try MediaDownloader.validatedOutputs(output.files, in: parentWithoutSlash).first?.path == childPath, "media output directory comparison ignores URL trailing slash")
        try rejects({ _ = try MediaDownloader.validatedOutputs([root.appendingPathComponent("outside.mkv")], in: folder) }, "media output outside staging directory rejected")
        let engine = DownloadEngine(pdfTransport: MockTransport(sourcePDF: image, pdf: [.status(503), .status(200)]), requestInterval: 0, retryDelay: 0)
        let first = try await engine.download(source, to: folder)
        try expect(first.pages == 0 && first.url.pathExtension == "png" && FileManager.default.fileExists(atPath: first.url.path), "native image download and retry")
        let again = try await engine.download(source, to: folder)
        try expect(again.alreadyExisted && first.url == again.url, "same content is reused")
        let corrupt = root.appendingPathComponent("broken.png")
        try Data("<html>login required</html>".utf8).write(to: corrupt)
        do { _ = try await FileStorage.publish([image, corrupt], title: nil, to: folder); throw TestFailure.failed("invalid group published") }
        catch let e as TestFailure { throw e } catch {}
        try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1, "failed group leaves no new files")

        // Force a second-file publication failure after the first was published.
        let duplicateNames = root.appendingPathComponent("collision")
        try FileManager.default.createDirectory(at: duplicateNames, withIntermediateDirectories: true)
        let second = root.appendingPathComponent("second.png")
        try FileManager.default.copyItem(at: image, to: second)
        for i in 0..<1000 { try Data("occupied".utf8).write(to: duplicateNames.appendingPathComponent("second" + (i == 0 ? "" : " (\(i + 1))") + ".png")) }
        do { _ = try await FileStorage.publish([image, second], title: nil, to: duplicateNames); throw TestFailure.failed("collision exhaustion succeeded") }
        catch let e as TestFailure { throw e } catch {}
        try expect(!FileManager.default.fileExists(atPath: duplicateNames.appendingPathComponent("photo.png").path), "group failure rolls back newly created file")
        try expect(try FileManager.default.contentsOfDirectory(atPath: duplicateNames.path).count == 1000, "rollback preserves pre-existing files")

        let result = ProcessProbe()
        let status = try await MediaProcess().run(URL(fileURLWithPath: "/bin/echo"), arguments: ["$(touch should-not-exist)", ";", "hello world"]) { result.append($0) }
        try expect(status == 0 && result.text == "$(touch should-not-exist) ; hello world", "subprocess arguments never pass through shell")
        let processTemporary = root.appendingPathComponent("mock-authentication-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: processTemporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let temporaryProbe = ProcessProbe()
        let temporaryStatus = try await MediaProcess().run(URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["TMPDIR"],
                                                          temporaryDirectory: processTemporary) { temporaryProbe.append($0) }
        try expect(temporaryStatus == 0 && temporaryProbe.text == processTemporary.path,
                   "authentication subprocesses can isolate temporary database copies without reading credentials")
        let process = MediaProcess(), child = ProcessProbe()
        let task = Task { try await process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo $!; wait"]) { child.append($0) } }
        for _ in 0..<100 where child.text.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!child.text.isEmpty, "child process started")
        let cancelledAt = Date(); task.cancel()
        do { _ = try await task.value; throw TestFailure.failed("cancelled process succeeded") } catch is CancellationError {}
        try expect(Date().timeIntervalSince(cancelledAt) < 4, "cancellation stops inherited output pipes and children promptly")

        let suite = "folioak-media-tests-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = root.appendingPathComponent("media-workspace.json")
        let item = DownloadItem(original: source.webURL.absoluteString, directURL: source.directURL, state: .saved, savedURL: first.url, documentTitle: "Photo", mediaFormat: .audio, additionalURLs: [first.url])
        let oldInvalid = DownloadItem(original: "https://x.com/old-profile", directURL: URL(string: "https://x.com/old-profile"), state: .failed)
        try WorkspaceStore.write(WorkspaceSnapshot(input: "draft", items: [item, oldInvalid], history: [], logs: []), to: state)
        let restored = DownloadModel(preferences: preferences, stateURL: state)
        try expect(restored.input == "draft" && restored.items.count == 2 && restored.items[0].mediaFormat == .audio, "media options and legacy failed URLs restore with draft")
        try expect(restored.papers.isEmpty, "media never enters paper library")
        restored.items = []; restored.history = [item]
        try expect(restored.downloads.count == 1, "completed media remains findable across batches")
        let missingGroup = DownloadItem(original: source.webURL.absoluteString, directURL: source.directURL, state: .saved,
                                       savedURL: root.appendingPathComponent("gone.png"), documentTitle: "Group", additionalURLs: [first.url])
        restored.items = [missingGroup]
        restored.preview(missingGroup)
        try expect(restored.previewURL == first.url && restored.items[0].savedURL == first.url && restored.items[0].canRetry,
                   "missing first file retains preview and retry access to remaining group files")
        let retryModel = DownloadModel(engine: engine, preferences: preferences, stateURL: root.appendingPathComponent("audio-retry.json"))
        retryModel.directory = folder
        var audioItem = item; audioItem.state = .missing; audioItem.savedURL = nil
        retryModel.retryFromLibrary(audioItem)
        try expect(retryModel.items.first?.mediaFormat == .audio, "detail/library retry preserves media format")
        try await waitForQueue(retryModel)
        audioItem.state = .failed; audioItem.error = "temporary failure"
        retryModel.items = [audioItem]; retryModel.history = []
        retryModel.input = source.webURL.absoluteString
        retryModel.start()
        try await waitForQueue(retryModel)
        try expect(retryModel.history.contains { $0.id == audioItem.id && $0.mediaFormat == .audio && $0.canRetry }, "failed audio task remains retryable after starting another batch")
        try expect(try CLIOptions.parse([source.webURL.absoluteString, "--audio"]).mediaFormat == .audio, "CLI audio option")
        try await categoryDestinationTests(root: root, image: image)
        try await mediaLibraryTests(root: root, image: image)
        try await mediaContainerTests(root: root)
        print("PASS media: routing, native transfer, reuse, invalid response, atomic group rollback, safe process arguments, child cancellation, restoration and paper isolation")
    }

    @MainActor static func directMediaRegressionTests(root: URL, image: URL) async throws {
        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let engine = DownloadEngine(pdfTransport: URLSessionTransport(testConfiguration: config, policy: .externalPDF), requestInterval: 0, retryDelay: 0)
        FixtureProtocol.install(.init(headers: ["Content-Type": "image/png"], body: try Data(contentsOf: image)), path: "/image/png")
        let suite = "folioak-direct-regression-\(UUID().uuidString)", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let state = root.appendingPathComponent("direct-regression.json")
        let model = DownloadModel(engine: engine, preferences: prefs, stateURL: state)
        model.directory = root.appendingPathComponent("direct-regression")
        model.input = "https://example.org/image/png?token=preserved"
        model.start(); try await waitForQueue(model)
        let saved = model.items[0]
        try expect(saved.state == .saved && saved.savedURL?.pathExtension == "png" && saved.savedURL?.deletingLastPathComponent().lastPathComponent == "Images", "extensionless PNG is detected and organized by actual content")
        try expect(FixtureProtocol.count("/image/png") == 1 && FixtureProtocol.lastRequest("/image/png")?.url?.query == "token=preserved", "valid image needs one attempt and preserves access parameters")
        try expect(model.papers.isEmpty && model.mediaLibrary.count == 1 && MediaLibraryStore.valid(saved) && saved.symbol == "photo", "extensionless media enters media library and uses its actual file icon")
        model.persistWorkspace()
        let restored = DownloadModel(engine: engine, preferences: prefs, stateURL: state)
        try expect(restored.mediaLibrary.count == 1 && restored.history.count + restored.items.count > 0, "extensionless media remains available after restart")

        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        let movie = root.appendingPathComponent("with-audio.mp4"), tools = try MediaTools.installed()
        let status = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-i", fixtures.appendingPathComponent("video.mp4").path,
            "-i", fixtures.appendingPathComponent("tone.m4a").path, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-shortest", movie.path
        ]) { _ in }
        try expect(status == 0, "small video/audio fixture mux")
        let covered = root.appendingPathComponent("covered.m4a")
        let coverImage = root.appendingPathComponent("cover.jpg")
        let cover = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try cover.representation(using: .jpeg, properties: [:])!.write(to: coverImage)
        let coverStatus = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-i", fixtures.appendingPathComponent("tone.m4a").path,
            "-i", coverImage.path, "-map", "0:a:0", "-map", "1:v:0", "-c", "copy", "-disposition:v:0", "attached_pic", covered.path
        ]) { _ in }
        try expect(coverStatus == 0, "small covered audio fixture mux")
        FixtureProtocol.install(.init(headers: ["Content-Type": "video/mp4"], body: try Data(contentsOf: movie)), path: "/flower.mp4")
        let destination = root.appendingPathComponent("direct-audio-exact")
        let options = try CLIOptions.parse(["--audio", "--json", "https://example.org/flower.mp4", "-o", destination.path])
        let console = CapturedConsole()
        let code = await CLIRunner.run(options, version: "test", engine: engine, preferences: prefs, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let report = try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any]
        let rows = report["results"] as! [[String: Any]], audio = URL(fileURLWithPath: rows[0]["path"] as! String)
        let streams = try await FileStorage.validate(audio, extension: "m4a")
        try expect(code == 0 && audio.pathExtension == "m4a" && audio.deletingLastPathComponent().path == destination.path && streams.allSatisfy { $0.codec_type == "audio" }, "CLI --audio on MP4 direct link saves only audio in the exact output directory")
        let again = try await engine.download(DownloadSource.parse("https://example.org/flower.mp4"), to: destination, mediaFormat: .audio)
        try expect(again.alreadyExisted && again.url == audio, "repeated audio extraction reuses content without publishing a video")
        FixtureProtocol.install(.init(headers: ["Content-Type": "video/mp4"], body: try Data(contentsOf: movie)), path: "/video/download")
        let organized = try await engine.download(DownloadSource.parse("https://example.org/video/download"), to: model.directory, mediaFormat: .audio, organizeByType: true)
        try expect(organized.url.pathExtension == "m4a" && organized.url.deletingLastPathComponent().lastPathComponent == "Audio", "extensionless video in audio mode uses Audio folder")
        for (path, file, ext, category) in [("/binary/video", movie, "mp4", "Videos"),
                                             ("/binary/audio", fixtures.appendingPathComponent("tone.m4a"), "m4a", "Audio"),
                                             ("/binary/covered", covered, "m4a", "Audio")] {
            FixtureProtocol.install(.init(headers: ["Content-Type": "application/octet-stream"], body: try Data(contentsOf: file)), path: path)
            let url = URL(string: "https://example.org" + path)!
            let result = try await engine.download(DownloadSource.parse(url.absoluteString), to: model.directory, organizeByType: true)
            let item = DownloadItem(original: url.absoluteString, directURL: url, state: .saved, savedURL: result.url, documentTitle: result.title)
            try expect(result.url.pathExtension == ext && result.url.deletingLastPathComponent().lastPathComponent == category && MediaLibraryStore.valid(item), "octet-stream without a filename is classified from its container and remains valid library media")
        }
        let pdf = root.appendingPathComponent("reverse.pdf"); try createPDF(at: pdf)
        FixtureProtocol.install(.init(headers: ["Content-Type": "application/pdf"], body: try Data(contentsOf: pdf)), path: "/actually-pdf.mp4")
        model.input = "https://example.org/actually-pdf.mp4"
        model.start(); try await waitForQueue(model)
        try expect(model.items[0].source?.isPaper == true && model.items[0].savedURL?.pathExtension == "pdf" && model.papers.count == 1 && model.mediaLibrary.count == 1, "PDF returned from a media-suffixed URL enters documents")
        model.clearDownloadRecords()
        try expect(model.items.isEmpty && model.history.isEmpty && model.papers.count == 1 && model.mediaLibrary.count == 1, "actual content classification keeps both libraries after clearing download history")
        model.persistWorkspace()
        try expect(DownloadModel(engine: engine, preferences: prefs, stateURL: state).papers.count == 1, "reverse classification remains in documents after restart")
        FixtureProtocol.install(.init(headers: ["Content-Type": "video/mp4"], body: try Data(contentsOf: fixtures.appendingPathComponent("video.mp4"))), path: "/silent.mp4")
        do {
            _ = try await engine.download(DownloadSource.parse("https://example.org/silent.mp4"), to: destination, mediaFormat: .audio)
            throw TestFailure.failed("silent video reported successful audio extraction")
        } catch let e as TestFailure { throw e }
        catch { try expect(error.localizedDescription.contains("音轨"), "silent video explains missing audio without saving video") }
        try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [audio.lastPathComponent], "audio mode publishes no source video or partial output")
        print("PASS direct media regressions: extensionless content, retained library, audio-only MP4 extraction, exact/category destinations, reuse and missing-track failure")
    }

    @MainActor static func mediaRetryPolicyTests(root: URL) throws {
        let platformLinks = [
            ["youtube.com/watch?v=one", "www.youtube.com/watch?v=two", "m.youtube.com/shorts/three", "youtu.be/four"],
            ["bilibili.com/video/BV1one", "www.bilibili.com/video/BV1two", "m.bilibili.com/video/BV1three", "b23.tv/four"],
            ["x.com/user/status/1", "www.x.com/user/status/2", "twitter.com/user/status/3", "www.twitter.com/user/status/4", "mobile.twitter.com/user/status/5"],
            ["toutiao.com/video/1/", "www.toutiao.com/video/2/", "m.toutiao.com/video/3/"],
            ["xiaohongshu.com/explore/674051740000000007027a15", "www.xiaohongshu.com/explore/674051740000000007027a15", "xhslink.com/a/abc123"],
            ["douyin.com/video/1", "www.douyin.com/video/2", "v.douyin.com/abc123/"],
            ["tiktok.com/@demo/video/1", "www.tiktok.com/@demo/video/2", "vm.tiktok.com/abc123", "vt.tiktok.com/abc123"],
            ["instagram.com/reel/abc123/", "www.instagram.com/p/abc123/"],
            ["vimeo.com/1", "www.vimeo.com/2", "player.vimeo.com/video/3"]
        ]
        var sources: [DownloadSource] = []
        for links in platformLinks {
            let aliases = try links.map { try DownloadSource.parse("https://" + $0) }
            try expect(aliases.allSatisfy(\.isMedia) && Set(aliases.map(\.rateLimitKey)).count == 1,
                       "all supported aliases of a media platform share one rate-limit group")
            sources += aliases
        }
        let groups = SourceScheduler.groups(sources, key: \.rateLimitKey)
        try expect(groups.map(\.count) == platformLinks.map(\.count), "platform aliases are serialized while other media sites retain independent groups")
        for link in platformLinks.flatMap({ $0 }) + ["youtube.com.example.org/file.pdf"] {
            let url = URL(string: "https://" + link)!
            for source in [DownloadSource.pdf(url), .file(url)] {
                try expect(source.rateLimitKey == url.host, "native PDF and direct-file rate limits retain the original host")
                try expect(!sources.contains { $0.rateLimitKey == source.rateLimitKey }, "native origins never inherit a media platform cooldown")
            }
        }
        let tools = try MediaTools.installed()
        for format in MediaFormat.allCases {
            let arguments = try MediaDownloader.arguments(url: URL(string: "https://youtu.be/BaW_jenozKc")!, format: format, tools: tools, folder: root)
            func values(_ option: String) -> [String] {
                zip(arguments, arguments.dropFirst()).compactMap { $0.0 == option ? $0.1 : nil }
            }
            try expect(values("--retries") == ["3"] && values("--fragment-retries") == ["3"], "media retries remain bounded in both output modes")
            try expect(values("--retry-sleep") == ["http:exp=1:8", "fragment:exp=1:8"], "HTTP and fragment retries use capped exponential delays")
            try expect(arguments.contains("--continue") && arguments.contains("--abort-on-unavailable-fragments"), "backoff preserves resume and missing-fragment failure")
        }
        for message in ["ERROR: HTTP Error 429: Too Many Requests", "ERROR: HTTP status code: 429", "ERROR: HTTP 429; try cookies",
                        "ERROR: Too many requests", "ERROR: Rate limit exceeded", "ERROR: Rate-limit reached"] {
            guard case .cooldown(let seconds) = MediaDownloader.failure(message) else {
                throw TestFailure.failed("media rate limit must pause the existing same-site queue: \(message)")
            }
            try expect(seconds == 60, "media rate limit uses the native default one-minute cooldown")
        }
        for (message, detail) in [
            ("ERROR: [youtube] clip429id: Requested format is not available", "下载格式"),
            ("ERROR: https://example.com/429: Connection timed out", "媒体下载未完成"),
            ("ERROR: HTTP Error 4290", "媒体下载未完成"),
            ("ERROR: Video is unavailable", "不可访问"),
            ("ERROR: No space left on device", "磁盘空间不足"),
            ("", "媒体下载未完成")
        ] {
            guard case .metadata(let description) = MediaDownloader.failure(message) else {
                throw TestFailure.failed("non-rate-limit failure must not pause other downloads: \(message)")
            }
            try expect(description.contains(detail), "existing media failure guidance remains specific")
        }
        print("PASS media retry policy: bounded HTTP/fragment backoff, typed rate-limit pause and non-rate-limit isolation")
    }

    @MainActor static func mediaContainerTests(root: URL) async throws {
        let tools = try MediaTools.installed()
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        let folder = root.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("中文视频.mkv")
        let status = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-v", "error", "-i", fixtures.appendingPathComponent("h264.mp4").path,
            "-i", fixtures.appendingPathComponent("tone.m4a").path, "-map", "0:v", "-map", "1:a", "-c", "copy", original.path
        ]) { _ in }
        try expect(status == 0, "H.264/AAC MKV fixture")
        let originalStreams = try await FileStorage.validate(original, extension: "mkv")
        try expect(originalStreams.map(\.codec_name) == ["h264", "aac"], "fixture matches X H.264/AAC streams")
        let originalBytes = try Data(contentsOf: original)
        let preferred = try await MediaDownloader.preferMP4(original, tools: tools, scratch: folder.appendingPathComponent("preferred"))
        try expect(preferred.lastPathComponent == "中文视频.mp4", "compatible video prefers MP4 without changing its name")
        func packets(_ file: URL) async throws -> [String] {
            let output = ProcessProbe()
            let status = try await MediaProcess().run(try tools.executable("ffprobe"), arguments: [
                "-v", "error", "-show_packets", "-show_entries", "packet=stream_index,data_hash", "-show_data_hash", "sha256", "-of", "json", file.path
            ]) { output.append($0) }
            try expect(status == 0, "packet hashes readable")
            let data = try JSONSerialization.jsonObject(with: Data(output.text.utf8)) as! [String: Any]
            return (data["packets"] as! [[String: Any]]).map { "\($0["stream_index"]!):\($0["data_hash"]!)" }.sorted()
        }
        let before = try await packets(original), after = try await packets(preferred)
        try expect(!before.isEmpty && before == after, "MP4 retains every original video/audio packet without re-encoding")
        try expect(try Data(contentsOf: original) == originalBytes, "remux leaves original intact until publication")
        let blockedScratch = folder.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blockedScratch)
        try expect(try await MediaDownloader.preferMP4(original, tools: tools, scratch: blockedScratch) == original,
                   "optional remux filesystem failure preserves a usable original")
        try expect(try Data(contentsOf: original) == originalBytes, "fallback leaves original bytes intact")
        try expect(try await MediaDownloader.preferMP4(preferred, tools: tools, scratch: folder.appendingPathComponent("unchanged")) == preferred, "existing MP4 is untouched")
        let other = try await MediaDownloader.preferMP4(original, tools: tools, scratch: folder.appendingPathComponent("other-input"))
        try expect(other != preferred && other.lastPathComponent == preferred.lastPathComponent, "same basename inputs have independent remux outputs")
        let audio = fixtures.appendingPathComponent("tone.m4a")
        try expect(try await MediaDownloader.preferMP4(audio, tools: tools, scratch: folder.appendingPathComponent("audio")) == audio, "audio remains in its original container")

        let attachment = folder.appendingPathComponent("note.txt")
        try Data("Keep all tracks and attachments".utf8).write(to: attachment)
        let incompatible = folder.appendingPathComponent("with-attachment.mkv")
        let attached = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-v", "error", "-i", original.path, "-map", "0", "-c", "copy", "-attach", attachment.path,
            "-metadata:s:t", "mimetype=text/plain", incompatible.path
        ]) { _ in }
        try expect(attached == 0, "container with a non-MP4 attachment")
        let fallback = folder.appendingPathComponent("fallback")
        try expect(try await MediaDownloader.preferMP4(incompatible, tools: tools, scratch: fallback) == incompatible, "unsupported MP4 streams preserve the full original container")
        try expect(try FileManager.default.contentsOfDirectory(atPath: fallback.path).isEmpty, "failed remux removes its partial output")

        let slowTools = folder.appendingPathComponent("slow-tools")
        try FileManager.default.createDirectory(at: slowTools, withIntermediateDirectories: true)
        let shim = slowTools.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nfor last do :; done\nprintf partial > \"$last\"\nsleep 30\n".utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let cancelFolder = folder.appendingPathComponent("cancel"), partial = cancelFolder.appendingPathComponent("中文视频.mp4")
        let task = Task { try await MediaDownloader.preferMP4(original, tools: MediaTools(directory: slowTools), scratch: cancelFolder) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: partial.path) { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(FileManager.default.fileExists(atPath: partial.path), "remux process began writing output")
        let cancelledAt = Date(); task.cancel()
        do { _ = try await task.value; throw TestFailure.failed("cancelled remux completed") } catch is CancellationError {}
        try expect(Date().timeIntervalSince(cancelledAt) < 4 && !FileManager.default.fileExists(atPath: partial.path), "remux cancellation stops the process and removes partial MP4")
        try expect(try Data(contentsOf: original) == originalBytes, "cancelled remux preserves the original")
        print("PASS MP4: packet-identical remux, multi-input isolation, original/audio preservation, unsupported-track fallback and cancellable partial cleanup")
    }

    @MainActor static func categoryDestinationTests(root: URL, image: URL) async throws {
        let suite = "folioak-destinations-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let legacyFolder = root.appendingPathComponent("legacy-papers")
        preferences.set(legacyFolder.path, forKey: "saveDirectory")
        preferences.set(root.appendingPathComponent("legacy-media").path, forKey: "mediaSaveDirectory")
        let home = root.appendingPathComponent("test-home", isDirectory: true)
        let defaults = DownloadPreferences(preferences, home: home)
        try expect(defaults.directory.path.hasSuffix("/Downloads/Folioak") && preferences.string(forKey: "saveDirectory") == legacyFolder.path,
                   "one new default root does not reinterpret or overwrite legacy paths")
        let oldDefault = home.appendingPathComponent("Downloads/Leafpick", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDefault, withIntermediateDirectories: true)
        try expect(DownloadPreferences(preferences, home: home).directory == oldDefault,
                   "an existing old default without a preference survives renaming")
        let newerDefault = home.appendingPathComponent("Downloads/Folioak", isDirectory: true)
        let previousDefault = home.appendingPathComponent("Downloads/Leafpeak", isDirectory: true)
        try FileManager.default.createDirectory(at: newerDefault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousDefault, withIntermediateDirectories: true)
        try expect(DownloadPreferences(preferences, home: home).directory == oldDefault,
                   "installing a new default folder does not divert an existing old folder")
        try FileManager.default.removeItem(at: oldDefault)
        try expect(DownloadPreferences(preferences, home: home).directory == previousDefault,
                   "the most recent legacy brand folder is retained when it exists alone")
        preferences.set(legacyFolder.path, forKey: "downloadRootDirectory")
        try expect(DownloadPreferences(preferences, home: home).directory.path == legacyFolder.path,
                   "an explicit root takes precedence over the old default")
        preferences.removeObject(forKey: "downloadRootDirectory")
        let folder = root.appendingPathComponent("organized", isDirectory: true), next = root.appendingPathComponent("next-organized", isDirectory: true)
        let pdf = root.appendingPathComponent("category.pdf"); try createPDF(at: pdf)
        let engine = DownloadEngine(transport: MockTransport(sourcePDF: pdf), pdfTransport: MockTransport(sourcePDF: image), requestInterval: 0, retryDelay: 0)
        let model = DownloadModel(engine: engine, preferences: preferences, stateURL: root.appendingPathComponent("category-workspace.json"))
        try expect(preferences.string(forKey: "downloadRootDirectory") == model.directory.path,
                   "app freezes its initial root instead of changing defaults on later launches")
        model.directory = folder
        try expect(!FileManager.default.fileExists(atPath: folder.path), "choosing root does not eagerly create folders")
        model.input = "bad-link"; model.start()
        try expect(!FileManager.default.fileExists(atPath: folder.path), "invalid input creates no root")
        model.input = "2501.12345v2\nhttps://example.com/photo.png"
        model.start(); model.directory = next
        try await waitForQueue(model)
        try expect(model.items.count == 2 && model.items.allSatisfy { $0.state == .saved }, "mixed paper/media batch succeeds")
        try expect(model.items[0].savedURL?.deletingLastPathComponent() == folder.appendingPathComponent("Papers", isDirectory: true)
                   && model.items[1].savedURL?.deletingLastPathComponent() == folder.appendingPathComponent("Images", isDirectory: true), "batch freezes root and creates type subfolders")
        try expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["Papers", "Images"], "only used folders are created")
        let oldURL = model.items[1].savedURL
        model.persistWorkspace()
        let restored = DownloadModel(preferences: preferences, stateURL: root.appendingPathComponent("category-workspace.json"))
        try expect(restored.directory == next && restored.items[1].savedURL == oldURL, "new root persists without changing previous saved paths")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: next.appendingPathComponent("Papers"))
        model.input = "2501.12345v2\nhttps://example.com/second.png"
        model.start(); try await waitForQueue(model)
        try expect(model.items[0].state == .failed && model.items[0].error?.contains("Papers") == true && model.items[1].state == .saved, "blocked Papers does not block Images")
        model.directory = folder
        model.retry(model.items[0].id); try await waitForQueue(model)
        try expect(model.items[0].savedURL?.deletingLastPathComponent() == folder.appendingPathComponent("Papers", isDirectory: true) && model.items[0].state == .existing, "retry uses current root and reuses existing file")
        model.mediaFormat = .audio; model.input = "https://example.com/third.PNG?download=1"
        model.start(); try await waitForQueue(model)
        try expect(model.items[0].savedURL?.deletingLastPathComponent().lastPathComponent == "Images", "audio mode cannot reclassify image direct links")
        let console = CapturedConsole()
        let options = try CLIOptions.parse(["2501.12345v2", "https://example.com/cli.png", "--json"])
        let code = await CLIRunner.run(options, version: "test", engine: engine, preferences: preferences, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let rows = (try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any])["results"] as! [[String: Any]]
        try expect(code == 0 && URL(fileURLWithPath: rows[0]["path"] as! String).deletingLastPathComponent().lastPathComponent == "Papers"
                   && URL(fileURLWithPath: rows[1]["path"] as! String).deletingLastPathComponent().lastPathComponent == "Images", "CLI follows automatic folders")
        let explicit = root.appendingPathComponent("exact-output")
        let explicitOptions = try CLIOptions.parse(["https://example.com/cli.png", "-o", explicit.path, "--json"])
        let explicitConsole = CapturedConsole()
        let explicitCode = await CLIRunner.run(explicitOptions, version: "test", engine: engine, preferences: preferences, stdout: { explicitConsole.stdout($0) }, stderr: { explicitConsole.stderr($0) })
        let explicitRows = (try JSONSerialization.jsonObject(with: Data(explicitConsole.output.utf8)) as! [String: Any])["results"] as! [[String: Any]]
        try expect(explicitCode == 0 && URL(fileURLWithPath: explicitRows[0]["path"] as! String).deletingLastPathComponent().path == explicit.path
                   && DownloadPreferences(preferences).directory == folder, "CLI -o remains exact and does not change root preference")
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        let audio = root.appendingPathComponent("sample.wav"), video = root.appendingPathComponent("sample.mp4")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("tone.wav"), to: audio)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("video.mp4"), to: video)
        let published = try await FileStorage.publish([image, audio, video], title: nil, to: folder, organizeByType: true)
        try expect(([published.url] + published.additionalURLs).map { $0.deletingLastPathComponent().lastPathComponent } == ["Images", "Audio", "Videos"], "actual media outputs route by final type including mixed groups")
        let blocked = root.appendingPathComponent("blocked-group")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blocked.appendingPathComponent("Audio"))
        do { _ = try await FileStorage.publish([image, audio], title: nil, to: blocked, organizeByType: true); throw TestFailure.failed("blocked audio folder was accepted") }
        catch let error as TestFailure { throw error } catch {}
        try expect(try FileManager.default.contentsOfDirectory(atPath: blocked.appendingPathComponent("Images").path).isEmpty, "cross-folder group failure rolls back newly saved outputs")
        print("PASS destinations: single root, lazy folders, mixed routing, frozen root, isolated failures, retry, restart, CLI override and cross-folder rollback")
    }

    @MainActor static func mediaLibraryTests(root: URL, image: URL) async throws {
        let suite = "folioak-library-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = root.appendingPathComponent("saved-media.json")
        let source = URL(string: "https://example.com/photo.png")!
        let file = root.appendingPathComponent("library-photo.png")
        try FileManager.default.copyItem(at: image, to: file)
        let media = DownloadItem(original: source.absoluteString, directURL: source, state: .saved, savedURL: file, documentTitle: "Forest")
        try WorkspaceStore.write(WorkspaceSnapshot(input: "draft", items: [media], history: [media], logs: []), to: state)
        let engine = DownloadEngine(pdfTransport: MockTransport(sourcePDF: image), requestInterval: 0, retryDelay: 0)
        let model = DownloadModel(engine: engine, preferences: preferences, stateURL: state)
        try expect(model.mediaLibrary.count == 1 && model.papers.isEmpty, "media migration deduplicates current and history without polluting paper library")
        model.items = []; model.history = []; model.persistWorkspace()
        let restored = DownloadModel(preferences: preferences, stateURL: state)
        try expect(restored.mediaLibrary.count == 1 && restored.downloads.isEmpty && restored.input == "draft", "media library survives history removal and restart")
        var alternate = media; alternate.id = UUID(); alternate.mediaFormat = .audio
        alternate.savedURL = root.appendingPathComponent("audio.m4a")
        model.upsertMedia(alternate)
        model.upsertMedia(alternate)
        try expect(model.mediaLibrary.count == 2, "same source with separate audio output is preserved and repeated insertion deduplicates")
        let other = root.appendingPathComponent("second-library-photo.png")
        try FileManager.default.copyItem(at: image, to: other)
        var group = media; group.id = UUID(); group.additionalURLs = [other]
        model.upsertMedia(group)
        try FileManager.default.removeItem(at: file)
        model.preview(group)
        let missingGroup = model.mediaLibrary.first { $0.id == group.id }!
        try expect(model.previewURL == other && missingGroup.state == .missing && missingGroup.localURLs.count == 2,
                   "library partial loss preserves complete file collection and opens remaining file without history")
        var pruned = missingGroup; pruned.savedURL = other; pruned.additionalURLs = nil
        model.preview(pruned)
        try expect(model.mediaLibrary.first { $0.id == group.id }?.state == .missing, "opening pruned history does not hide missing library attachments")
        try FileManager.default.copyItem(at: image, to: file)
        model.preview(missingGroup)
        try expect(model.mediaLibrary.first { $0.id == group.id }?.state == .saved, "restored local files recover library state on open")
        let target = root.appendingPathComponent("library-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        model.directory = target
        try FileManager.default.removeItem(at: file)
        model.preview(media)
        let missing = model.mediaLibrary.first { $0.id == media.id }!
        model.retryFromLibrary(missing); try await waitForQueue(model)
        try expect(model.mediaLibrary.first { $0.id == media.id }?.savedURL?.deletingLastPathComponent() == target.appendingPathComponent("Images", isDirectory: true) && model.input == "draft",
                   "library-only retry uses current media destination without replacing draft")
        let failed = DownloadModel(engine: DownloadEngine(pdfTransport: MockTransport(sourcePDF: image, pdf: [.failure(.metadata("test failure"))]), requestInterval: 0, retryDelay: 0), preferences: preferences)
        failed.upsertMedia(media)
        failed.retryFromLibrary(media); try await waitForQueue(failed)
        try expect(failed.items.first?.state == .failed && failed.mediaLibrary.first?.savedURL == media.savedURL && failed.mediaLibrary.first?.state == .saved,
                   "failed retry never overwrites prior library record")
        let replayState = root.appendingPathComponent("media-replay.json")
        var older = media; older.finishedAt = Date(timeIntervalSince1970: 100)
        var newer = older; newer.savedURL = other; newer.finishedAt = Date(timeIntervalSince1970: 200)
        try WorkspaceStore.write(WorkspaceSnapshot(input: "", items: [older], history: [], logs: []), to: replayState)
        try MediaLibraryStore.write([newer], to: root.appendingPathComponent("media-media-replay.json.library.json"))
        let replayed = DownloadModel(preferences: preferences, stateURL: replayState)
        try expect(replayed.mediaLibrary.first?.savedURL == other, "old workspace cannot roll back newer media-library path after interruption")
        let partialState = root.appendingPathComponent("partial-migration.json")
        var partial = group; partial.state = .missing; partial.savedURL = other; partial.additionalURLs = nil
        try WorkspaceStore.write(WorkspaceSnapshot(input: "", items: [partial], history: [], logs: []), to: partialState)
        let migrated = DownloadModel(preferences: preferences, stateURL: partialState)
        try expect(migrated.mediaLibrary.count == 1 && migrated.mediaLibrary[0].state == .missing, "older partial-media records migrate with surviving files")
        migrated.preview(migrated.mediaLibrary[0])
        try expect(migrated.mediaLibrary[0].state == .missing && migrated.mediaLibrary[0].canRetry && migrated.previewURL == other,
                   "legacy incomplete attachment list remains retryable after opening surviving file")
        var retained = (0..<501).map { index -> DownloadItem in
            var copy = media; copy.id = UUID(); copy.savedURL = root.appendingPathComponent("retained-\(index).png"); return copy
        }
        let store = root.appendingPathComponent("retained-media.json")
        try MediaLibraryStore.write(retained, to: store)
        try expect(try MediaLibraryStore.read(store)?.count == 501, "media library exceeds download-history retention")
        retained[0].savedURL = root.appendingPathComponent("not-media.pdf")
        try rejects({ try MediaLibraryStore.write(retained, to: store) }, "paper file cannot be stored in media library")
        let badState = root.appendingPathComponent("damaged-media-workspace.json")
        let badLibrary = root.appendingPathComponent("media-damaged-media-workspace.json.library.json")
        let damaged = Data("{\"schema\":99,\"items\":[]}".utf8)
        try damaged.write(to: badLibrary)
        let protected = DownloadModel(preferences: preferences, stateURL: badState)
        protected.upsertMedia(media); protected.persistWorkspace()
        try expect(!protected.mediaLibraryWritable && protected.mediaLibraryNotice != nil && (try Data(contentsOf: badLibrary)) == damaged,
                   "future media library is preserved read-only")
        print("PASS media library: migration, retention, deduplication, audio variants, partial loss, recovery, standalone retry and damaged-state protection")
    }

    @MainActor static func renderMediaSnapshots() throws {
        let suite = "folioak-preview-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Folioak")
        let video = URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc")!
        model.input = video.absoluteString
        model.items = [
            DownloadItem(original: video.absoluteString, directURL: video, state: .downloading, progress: DownloadProgress(received: 12_800_000, total: 32_000_000), documentTitle: "Designing something worth keeping", bytesPerSecond: 2_300_000),
            DownloadItem(original: "1706.03762v7", reference: try ArxivReference.parse("1706.03762v7"), state: .saved, savedURL: URL(fileURLWithPath: "/tmp/Attention Is All You Need.pdf"), pages: 15, documentTitle: "Attention Is All You Need"),
            DownloadItem(original: "https://example.com/forest.jpg", directURL: URL(string: "https://example.com/forest.jpg"), state: .saved, savedURL: URL(fileURLWithPath: "/tmp/forest.jpg"), documentTitle: "Forest — morning light"),
            DownloadItem(original: "https://x.com/demo/status/123", directURL: URL(string: "https://x.com/demo/status/123"), state: .failed, error: "此内容需要登录或站点验证。请换一个公开链接。", documentTitle: "X 视频")
        ]
        var savedVideo = model.items[0]
        savedVideo.state = .saved; savedVideo.progress = nil; savedVideo.savedURL = URL(fileURLWithPath: "/tmp/Designing.mp4")
        let activeVideo = model.items[0]
        var savedAudio = savedVideo; savedAudio.id = UUID(); savedAudio.mediaFormat = .audio
        savedAudio.savedURL = URL(fileURLWithPath: "/tmp/Designing.m4a")
        model.mediaLibrary = [savedVideo, savedAudio, model.items[2]]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa-231")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        for scheme in [ColorScheme.light, .dark] {
            for width in [780, 1000] {
                for scene in ["active", "idle", "audio", "media", "long-path"] {
                    let page: WorkspacePage = scene == "media" ? .media : .downloads
                    model.busy = scene == "active"
                    model.items[0] = model.busy ? activeVideo : savedVideo
                    model.input = scene == "idle" || scene == "long-path" ? "" : video.absoluteString
                    model.mediaFormat = scene == "audio" ? .audio : .automatic
                    model.directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/" + (scene == "long-path" ? String(repeating: "Long Download Folder ", count: 6) : "Folioak"))
                    app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                    let view = NSHostingView(rootView: DownloaderView(model: model, page: page).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width == 780 ? 540 : 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                    let chrome = WindowChrome(window: window, model: model, title: "Folioak", workspace: true)
                    window.contentView = view
                    let rendered = view.superview ?? view
                    rendered.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)); window.displayIfNeeded()
                    let bitmap = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds)!
                    rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(scene)-\(scheme == .light ? "light" : "dark")-\(width).png"))
                    window.orderOut(nil); withExtendedLifetime(chrome) {}
                }
            }
        }
        print("Folioak previews: \(output.path)")
    }
}


extension CoreTests {
    @MainActor static func githubFileTests(root: URL, image: URL) async throws {
        let example = "https://github.com/bytedance/Lance/blob/main/assets/logo/lance-logo.webp"
        let rawExample = "https://raw.githubusercontent.com/bytedance/Lance/main/assets/logo/lance-logo.webp"
        for suffix in ["", "?raw=true", "?raw=1&utm_source=a,b;c#preview"] {
            try expect(try DownloadSource.parse(example + suffix) == .file(URL(string: rawExample)!), "GitHub WebP preview parameters share the raw file identity")
        }
        for ext in FileStorage.extensions {
            let input = "https://WWW.GITHUB.COM:443/Org/Repo/blob/feature%2Fmedia/a%20b%23c%25." + ext.uppercased()
            let expected = "https://raw.githubusercontent.com/Org/Repo/feature%2Fmedia/a%20b%23c%25." + ext.uppercased()
            let source = try DownloadSource.parse(input)
            try expect(source == .file(URL(string: expected)!) && (try DownloadSource.parse(expected)) == source, "GitHub supported file normalization is encoded, case-preserving and idempotent")
        }
        for input in [example.replacingOccurrences(of: "github.com", with: "github.com.evil.example"), example.replacingOccurrences(of: "/blob/", with: "/tree/"), example + "/", example + ".exe"] {
            try expect(try DownloadSource.parse(input).directURL?.host != "raw.githubusercontent.com", "only supported GitHub blob files convert to raw")
        }
        for input in [example.replacingOccurrences(of: "https:", with: "http:"), example.replacingOccurrences(of: "github.com", with: "user@github.com"), example.replacingOccurrences(of: "github.com", with: "github.com:444")] {
            try rejects({ _ = try DownloadSource.parse(input) }, "media GitHub conversion retains HTTPS safety checks")
        }
        let batch = try BatchInput(example + "\n" + example + "?raw=true\n" + rawExample)
        try expect(batch.entries.count == 1 && batch.duplicates == 2, "GitHub preview, raw query and raw host deduplicate")
        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let engine = DownloadEngine(pdfTransport: URLSessionTransport(testConfiguration: config, policy: .externalPDF), requestInterval: 0, retryDelay: 0)
        let path = "/Org/Repo/main/photo.png", link = "https://github.com/Org/Repo/blob/main/photo.png"
        FixtureProtocol.install(.init(headers: ["Content-Type": "image/png"], body: try Data(contentsOf: image)), path: path)
        let suite = "folioak-github-files-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent(suite)
        preferences.set(folder.path, forKey: "downloadRootDirectory")
        let model = DownloadModel(engine: engine, preferences: preferences)
        model.input = link + "\n" + link + "?raw=true"
        model.start(); try await waitForQueue(model)
        try expect(model.successes == 1 && model.duplicateCount == 1 && model.input.isEmpty && model.mediaLibrary.count == 1, "UI downloads one GitHub image and keeps it in the media library")
        try expect(FixtureProtocol.lastRequest(path)?.url?.host == "raw.githubusercontent.com" && FixtureProtocol.count("/Org/Repo/blob/main/photo.png") == 0, "GitHub media goes directly to the raw file")
        let console = CapturedConsole()
        let code = await CLIRunner.run(try CLIOptions.parse([link, "--json"]), version: "test", engine: engine, preferences: preferences, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let report = try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any]
        let rows = report["results"] as! [[String: Any]]
        try expect(code == 0 && rows.first?["status"] as? String == "existing" && rows.first?["input"] as? String == link, "CLI reuses the UI raw-file download and preserves user input")
        let state = root.appendingPathComponent("github-media-legacy.json")
        let legacy = DownloadItem(original: link, directURL: URL(string: link), state: .failed)
        try WorkspaceStore.write(WorkspaceSnapshot(input: link, items: [legacy], history: [legacy], logs: []), to: state)
        let restored = DownloadModel(engine: engine, preferences: preferences, stateURL: state)
        try expect(restored.persistenceNotice == nil && restored.items.first?.id == legacy.id && restored.items.first?.directURL?.host == "raw.githubusercontent.com", "old GitHub media records normalize without losing their identity")
        restored.retry(legacy.id); try await waitForQueue(restored)
        try expect(restored.items.first?.state == .existing && restored.input.isEmpty && FixtureProtocol.count("/Org/Repo/blob/main/photo.png") == 0, "old GitHub media retry keeps the raw route and avoids duplicate saved files")
        print("PASS GitHub files: user WebP case, all supported types, encoded refs, safety, deduplication, shared UI/CLI raw routing and legacy retry")
    }
}
