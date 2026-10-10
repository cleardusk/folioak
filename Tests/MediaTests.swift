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
        for ext in ["png", "mp3", "mp4"] {
            try expect(try DownloadSource.parse("https://example.com/file." + ext).isPaper == false, "all native media types use media destination")
        }
        let source = try DownloadSource.parse("https://example.com/photo.png?token=abc")
        try expect(!source.isPaper && !source.isMedia && source.directURL?.query == "token=abc", "signed image URL stays intact")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = root.appendingPathComponent("photo.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
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
        let process = MediaProcess(), child = ProcessProbe()
        let task = Task { try await process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo $!; wait"]) { child.append($0) } }
        for _ in 0..<100 where child.text.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!child.text.isEmpty, "child process started")
        let cancelledAt = Date(); task.cancel()
        do { _ = try await task.value; throw TestFailure.failed("cancelled process succeeded") } catch is CancellationError {}
        try expect(Date().timeIntervalSince(cancelledAt) < 4, "cancellation stops inherited output pipes and children promptly")

        let suite = "leafpick-media-tests-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
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
        let suite = "leafpick-destinations-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let legacyFolder = root.appendingPathComponent("legacy-papers")
        preferences.set(legacyFolder.path, forKey: "saveDirectory")
        preferences.set(root.appendingPathComponent("legacy-media").path, forKey: "mediaSaveDirectory")
        let defaults = DownloadPreferences(preferences)
        try expect(defaults.directory.path.hasSuffix("/Downloads/Leafpick") && preferences.string(forKey: "saveDirectory") == legacyFolder.path,
                   "one new default root does not reinterpret or overwrite legacy paths")
        let folder = root.appendingPathComponent("organized", isDirectory: true), next = root.appendingPathComponent("next-organized", isDirectory: true)
        let pdf = root.appendingPathComponent("category.pdf"); try createPDF(at: pdf)
        let engine = DownloadEngine(transport: MockTransport(sourcePDF: pdf), pdfTransport: MockTransport(sourcePDF: image), requestInterval: 0, retryDelay: 0)
        let model = DownloadModel(engine: engine, preferences: preferences, stateURL: root.appendingPathComponent("category-workspace.json"))
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
        let suite = "leafpick-library-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
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
        let suite = "leafpick-preview-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Leafpick")
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
                    model.directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/" + (scene == "long-path" ? String(repeating: "Long Download Folder ", count: 6) : "Leafpick"))
                    app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                    let view = NSHostingView(rootView: DownloaderView(model: model, page: page).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width == 780 ? 540 : 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                    let chrome = WindowChrome(window: window, model: model, title: "拾取 · Leafpick", workspace: true)
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
        print("Leafpick previews: \(output.path)")
    }
}
