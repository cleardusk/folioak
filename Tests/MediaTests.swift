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
        print("PASS media: routing, native transfer, reuse, invalid response, atomic group rollback, safe process arguments, child cancellation, restoration and paper isolation")
    }

    @MainActor static func renderMediaSnapshots() throws {
        let suite = "leafpick-preview-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        model.directory = URL(fileURLWithPath: "/Users/you/Downloads")
        let video = URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc")!
        model.input = video.absoluteString
        model.items = [
            DownloadItem(original: video.absoluteString, directURL: video, state: .downloading, progress: DownloadProgress(received: 12_800_000, total: 32_000_000), documentTitle: "Designing something worth keeping", bytesPerSecond: 2_300_000),
            DownloadItem(original: "1706.03762v7", reference: try ArxivReference.parse("1706.03762v7"), state: .saved, savedURL: URL(fileURLWithPath: "/tmp/Attention Is All You Need.pdf"), pages: 15, documentTitle: "Attention Is All You Need"),
            DownloadItem(original: "https://example.com/forest.jpg", directURL: URL(string: "https://example.com/forest.jpg"), state: .saved, savedURL: URL(fileURLWithPath: "/tmp/forest.jpg"), documentTitle: "Forest — morning light"),
            DownloadItem(original: "https://x.com/demo/status/123", directURL: URL(string: "https://x.com/demo/status/123"), state: .failed, error: "此内容需要登录或站点验证。请换一个公开链接。", documentTitle: "X 视频")
        ]
        model.busy = true
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa-230")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        for scheme in [ColorScheme.light, .dark] {
            for width in [780, 1000] {
                app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let view = NSHostingView(rootView: DownloaderView(model: model).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width == 780 ? 540 : 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                let chrome = WindowChrome(window: window, model: model, title: "拾取 · Leafpick", workspace: true)
                window.contentView = view
                let rendered = view.superview ?? view
                rendered.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)); window.displayIfNeeded()
                let bitmap = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds)!
                rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("mixed-\(scheme == .light ? "light" : "dark")-\(width).png"))
                window.orderOut(nil); withExtendedLifetime(chrome) {}
            }
        }
        print("Leafpick previews: \(output.path)")
    }
}
