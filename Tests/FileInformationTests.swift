import Foundation
import PDFKit
import AppKit
import SwiftUI

extension CoreTests {
    @MainActor static func fileInformationTests(root: URL, pdf: URL) async throws {
        func value(_ info: FileInformation, _ name: String) -> String? {
            info.groups.flatMap(\.fields).first { $0.name == name }?.value
        }
        let target = root.appendingPathComponent("文件信息.pdf")
        let document = PDFDocument(url: pdf)!
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Embedded title", PDFDocumentAttribute.authorAttribute: "Embedded author"]
        document.page(at: 0)!.rotation = 90
        document.insert(PDFDocument(url: pdf)!.page(at: 0)!, at: 1)
        try expect(document.write(to: target), "PDF metadata fixture")
        let original = try Data(contentsOf: target)
        let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let info = try await FileInformation.read(target, title: "Library title", author: "Library author")
        try expect(info.issue == nil && value(info, "页数") == "2" && value(info, "首页尺寸") == "141.1 × 105.8 mm", "PDF actual page count and rotated first-page dimensions")
        try expect(value(info, "标题") == "Embedded title" && value(info, "作者") == "Embedded author", "embedded PDF metadata takes precedence over library fallbacks")
        try expect(value(info, "文件名") == target.lastPathComponent && value(info, "位置") == target.path && value(info, "大小") != nil && value(info, "类型") != nil && value(info, "创建时间") != nil && value(info, "修改时间") != nil, "generic attributes come from the actual file")
        try expect(try Data(contentsOf: target) == original && target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified, "reading file information does not change file contents or modification time")
        let fallback = try await FileInformation.read(pdf, title: "Library title", author: "Library author")
        try expect(value(fallback, "标题") == "Library title" && value(fallback, "作者") == "Library author", "PDF title and author can fall back to library metadata")

        let locked = root.appendingPathComponent("locked.pdf")
        try expect(document.write(to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "secret"]), "encrypted PDF fixture")
        let encrypted = try await FileInformation.read(locked)
        try expect(encrypted.issue != nil && value(encrypted, "页数") == nil && value(encrypted, "大小") != nil, "locked PDFs retain basic file information without fabricated page metadata")
        let missing = try await FileInformation.read(root.appendingPathComponent("missing.pdf"))
        try expect(missing.issue != nil && value(missing, "位置")?.hasSuffix("missing.pdf") == true, "missing paths remain visible")
        let directory = try await FileInformation.read(root)
        try expect(directory.issue != nil && value(directory, "页数") == nil, "directories are not treated as regular files")
        let remote = try await FileInformation.read(URL(string: "https://example.invalid/video.mp4")!)
        try expect(remote.issue != nil && remote.groups.count == 1, "file information never fetches remote URLs")
        let corrupt = root.appendingPathComponent("corrupt-info.pdf")
        try Data("not a PDF".utf8).write(to: corrupt)
        let broken = try await FileInformation.read(corrupt)
        try expect(broken.issue != nil && value(broken, "大小") != nil, "corrupt PDFs retain basic information")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = root.appendingPathComponent("information.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let imageInfo = try await FileInformation.read(image)
        try expect(imageInfo.issue == nil && value(imageInfo, "尺寸") == "4 × 6 像素", "ImageIO reads image dimensions")
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        let video = try await FileInformation.read(fixture.appendingPathComponent("h264.mp4"))
        let audio = try await FileInformation.read(fixture.appendingPathComponent("tone.m4a"))
        try expect(video.issue == nil && value(video, "分辨率") != nil && value(video, "帧率") != nil && value(video, "视频比特率") != value(video, "总比特率"), "bundled ffprobe reads real video parameters and distinguishes container and stream bitrate")
        try expect(audio.issue == nil && value(audio, "采样率") != nil && value(audio, "声道") != nil && value(audio, "分辨率") == nil, "bundled ffprobe reads real audio parameters")
        let damaged = root.appendingPathComponent("damaged.mp4")
        try Data("not a video".utf8).write(to: damaged)
        let damagedInfo = try await FileInformation.read(damaged)
        try expect(damagedInfo.issue != nil && value(damagedInfo, "文件名") != nil, "media probing failures preserve generic attributes")
        let cancelled = Task { try await FileInformation.read(target) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw TestFailure.failed("cancelled metadata read completed") }
        catch is CancellationError {} catch { throw error }

        let probe = Data(#"{"format":{"duration":"3661.4","bit_rate":"55318"},"streams":[{"codec_type":"video","codec_name":"mjpeg","width":100,"height":100,"disposition":{"attached_pic":1}},{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001","side_data_list":[{"rotation":-90}],"bit_rate":"1000000"},{"codec_type":"video","codec_name":"hevc","width":640,"height":480},{"codec_type":"audio","codec_name":"opus","sample_rate":"48000","channels":2}]}"#.utf8)
        let parsed = FileInformation(url: target, groups: try FileInformation.mediaGroups(probe))
        try expect(value(parsed, "时长") == "1:01:01" && value(parsed, "分辨率") == "1080 × 1920" && value(parsed, "帧率")?.hasSuffix(" fps") == true, "rotation, rational frame rate and duration formatting")
        try expect(parsed.groups.contains { $0.title == "视频（首轨）" } && value(parsed, "音频比特率") == nil && value(parsed, "总比特率") != nil, "cover art is excluded and missing stream bitrates never inherit total bitrate")
        let tagged = FileInformation(url: target, groups: try FileInformation.mediaGroups(Data(#"{"streams":[{"codec_type":"video","width":1920,"height":1080,"tags":{"rotate":"90"}}]}"#.utf8)))
        try expect(value(tagged, "分辨率") == "1080 × 1920", "legacy rotation tags are parsed explicitly when no side data exists")
        let unknown = FileInformation(url: target, groups: try FileInformation.mediaGroups(Data(#"{"format":{"duration":"N/A","bit_rate":"0"},"streams":[{"codec_type":"video","codec_name":"h264","avg_frame_rate":"0/0","width":0,"height":0},{"codec_type":"audio","sample_rate":"N/A","channels":0,"bit_rate":"N/A"}]}"#.utf8)))
        try expect(value(unknown, "帧率") == nil && value(unknown, "分辨率") == nil && value(unknown, "时长") == nil && value(unknown, "总比特率") == nil, "unknown and zero-valued media fields are omitted")
        try rejects({ _ = try FileInformation.mediaGroups(Data("{}".utf8)) }, "empty probe output fails cleanly")
        let suite = "folioak-file-info-retry-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(engine: DownloadEngine(pdfTransport: MockTransport(sourcePDF: fixture.appendingPathComponent("tone.m4a")), requestInterval: 0, retryDelay: 0), preferences: preferences)
        model.directory = root.appendingPathComponent("info-retry")
        try FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
        let lost = DownloadItem(original: "https://example.com/tone.m4a", directURL: URL(string: "https://example.com/tone.m4a"), state: .missing, documentTitle: "Missing audio")
        model.mediaLibrary = [lost]
        let details = TaskDiagnosticView(model: model, item: lost, fromMediaLibrary: true)
        details.retry()
        try expect(model.busy && model.items.contains { $0.id == lost.id }, "details retry queues a missing media-library file after history is cleared")
        try await waitForQueue(model)
        try expect(model.items.first?.state == .saved && model.mediaLibrary.first?.savedURL != nil, "missing media retry completes through the existing download pipeline")
        print("PASS file information: read-only PDF, images, real media probes, missing/corrupt/encrypted files, cancellation and stream edge cases")
    }
}


extension CoreTests {
    @MainActor static func downloadOriginTests(root: URL, pdf: URL) async throws {
        let raw = "https://github.com/example/papers/blob/main/report.pdf?raw=1&token=OriginalSecret#page=2"
        let origin = DownloadOrigin(input: raw, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try expect(origin.browserURL?.absoluteString == raw, "opening original links keeps preview route, query and fragment")
        for wrapped in ["<" + raw + ">", "\"" + raw + "\"", "“" + raw + "”"] {
            try expect(DownloadOrigin(input: wrapped, capturedAt: nil).browserURL?.absoluteString == raw, "wrapped preview links open their original page")
        }
        for unsafe in ["file:///tmp/report.pdf", "javascript:alert(1)", "https://user:secret@example.com/a.pdf", "https://example.com/\nfile.pdf"] {
            try expect(DownloadOrigin(input: unsafe, capturedAt: nil).browserURL == nil, "source actions reject non-web, credential and control-character URLs")
        }
        try expect(DownloadOrigin(input: "1706.03762", capturedAt: nil).browserURL?.absoluteString == "https://arxiv.org/abs/1706.03762", "bare arXiv input opens its source page")
        try expect(DownloadOrigin(input: "BV1xx411c7mD", capturedAt: nil).browserURL?.host == "www.bilibili.com", "bare BV input has a source page")
        for identifier in ["arxiv:1706.03762", "arXiv:1706.03762v2", "arxiv:hep-th/9901001"] {
            let reference = try ArxivReference.parse(identifier)
            let prefixed = DownloadOrigin(input: identifier, capturedAt: nil)
            try expect(prefixed.browserURL == reference.abstractURL &&
                       DownloadOrigin.recovered(identifier, source: .arxiv(reference))?.input == identifier,
                       "arxiv-prefixed modern, versioned and legacy identifiers open without rewriting their input")
        }
        let canonical = try DownloadSource.parse(raw).directURL!
        let suite = "folioak-origin-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = .chinese }
        var opened: [URL] = [], openSucceeds = true
        let transport = MockTransport(sourcePDF: pdf, pdf: [.status(404), .status(200)])
        let model = DownloadModel(engine: DownloadEngine(transport: transport, pdfTransport: transport, requestInterval: 0, retryDelay: 0),
                                  preferences: preferences, opener: { opened.append($0); return openSucceeds })
        model.directory = root.appendingPathComponent("origin-downloads")
        try FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
        model.input = raw; model.start()
        try await waitForQueue(model)
        let first = model.items[0].origin!
        try expect(first.input == raw && first.capturedAt != nil && model.items[0].directURL == canonical && model.items[0].state == .failed,
                   "new submission captures first input before normalization, even when download fails")
        model.retry(model.items[0].id); try await waitForQueue(model)
        try expect(model.items[0].origin == first && model.items[0].state == .saved && model.papers[0].origin == first,
                   "retry success retains the original input and persists it in the document library")
        let saved = model.papers[0]
        try FileManager.default.removeItem(at: saved.file!)
        model.items = []; model.history = []
        model.retryFromLibrary(saved.downloadItem); try await waitForQueue(model)
        try expect(model.items[0].origin == first && model.items[0].original != raw && model.papers[0].origin == first,
                   "redownload after clearing history keeps provenance independently of normalized retry routing")
        var replacement = model.items[0]
        replacement.origin = DownloadOrigin(input: "https://example.com/replacement.pdf", capturedAt: Date())
        model.upsertPaper(replacement)
        try expect(model.papers[0].origin == first && model.papers[0].matches("OriginalSecret"), "document merges never replace first origin and original links remain searchable")

        var record = DownloadItem(original: canonical.absoluteString, directURL: canonical, state: .saved, savedURL: pdf, documentTitle: "A long research paper title about reliable downloads, immutable source records and readable file details", origin: origin)
        let workspaceURL = root.appendingPathComponent("origin-workspace.json"), libraryURL = root.appendingPathComponent("origin-library.json")
        try WorkspaceStore.write(WorkspaceSnapshot(input: "", items: [record], history: [], logs: []), to: workspaceURL)
        try expect(try WorkspaceStore.read(workspaceURL)?.items[0].origin == origin, "workspace provenance round trip")
        try LibraryStore.write([LibraryPaper(record)], to: libraryURL)
        try expect(try LibraryStore.read(libraryURL)?[0].downloadItem.origin == origin, "document provenance round trip and conversion")
        let audio = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media/tone.m4a")
        let mediaSource = URL(string: "https://example.com/tone.m4a")!
        var media = DownloadItem(original: mediaSource.absoluteString, directURL: mediaSource, state: .saved, savedURL: audio,
                                 finishedAt: Date(timeIntervalSince1970: 100), origin: origin)
        let mediaURL = root.appendingPathComponent("origin-media.json")
        try MediaLibraryStore.write([media], to: mediaURL)
        try expect(try MediaLibraryStore.read(mediaURL)?[0].origin == origin, "media provenance round trip")
        model.upsertMedia(media)
        media.finishedAt = Date(timeIntervalSince1970: 200); media.origin = replacement.origin
        model.upsertMedia(media)
        try expect(model.mediaLibrary[0].origin == origin, "newer media save preserves earliest origin")
        try expect(LibraryQueryCache().media(model.mediaLibrary, revision: 1, query: "OriginalSecret", removed: false).count == 1,
                   "media can be searched by the retained original link")
        let mediaTransport = MockTransport(sourcePDF: audio)
        let mediaModel = DownloadModel(engine: DownloadEngine(pdfTransport: mediaTransport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        mediaModel.directory = root.appendingPathComponent("origin-media-downloads")
        try FileManager.default.createDirectory(at: mediaModel.directory, withIntermediateDirectories: true)
        mediaModel.mediaLibrary = [model.mediaLibrary[0]]
        mediaModel.retryFromLibrary(mediaModel.mediaLibrary[0]); try await waitForQueue(mediaModel)
        try expect(mediaModel.items[0].state == .saved && mediaModel.mediaLibrary[0].origin == origin, "media redownload keeps provenance after history removal")

        func removeOrigin(_ url: URL, key: String) throws {
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var rows = json[key] as! [[String: Any]]
            rows[0].removeValue(forKey: "origin"); json[key] = rows
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        try removeOrigin(workspaceURL, key: "items"); try removeOrigin(libraryURL, key: "papers"); try removeOrigin(mediaURL, key: "items")
        let oldTask = try WorkspaceStore.read(workspaceURL)!.items[0]
        let oldPaper = try LibraryStore.read(libraryURL)![0], oldMedia = try MediaLibraryStore.read(mediaURL)![0]
        try expect(oldTask.origin?.input == canonical.absoluteString && oldTask.origin?.capturedAt == nil &&
                   oldPaper.origin == oldTask.origin && oldMedia.origin?.input == mediaSource.absoluteString && oldMedia.origin?.capturedAt == nil,
                   "old schemas recover available sources without claiming an exact first input")
        try WorkspaceStore.write(WorkspaceSnapshot(input: "", items: [oldTask], history: [], logs: []), to: workspaceURL)
        try expect(try WorkspaceStore.read(workspaceURL)?.items[0].origin == oldTask.origin, "recovered provenance is durable on subsequent saves")
        let importedURL = root.appendingPathComponent("1706.03762.pdf")
        try FileManager.default.copyItem(at: pdf, to: importedURL)
        let imported = try LibraryStore.imported(importedURL)
        try expect(imported.origin == nil && imported.downloadItem.provenance == nil, "arXiv-looking local filenames do not fabricate remote provenance")
        record.origin = DownloadOrigin(input: String(repeating: "x", count: ResourceLimits.inputBytes + 1), capturedAt: nil)
        try expect(!WorkspaceStore.validItem(record) && !LibraryStore.valid(LibraryPaper(record)), "oversized provenance is rejected by persisted record validation")
        record.origin = origin

        let details = TaskDiagnosticView(model: model, item: record)
        let bareID = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"), state: .queued)
        try expect(details.originalIsLink && !TaskDiagnosticView(model: model, item: bareID).originalIsLink,
                   "details distinguish URL labels from raw paper identifiers")
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        try expect(details.copyOriginalLink(to: pasteboard) && pasteboard.string(forType: .string) == raw, "details copy the exact original input")
        try expect(model.openOriginalSource(record) && opened.last?.absoluteString == raw, "details source opener uses first input, not download route")
        openSucceeds = false
        try expect(!model.openOriginalSource(record) && model.notice != nil, "source opening failure is reported")
        try expect(!TaskDiagnosticView(model: model, item: imported.downloadItem).copyOriginalLink(to: pasteboard) &&
                   !model.openOriginalSource(imported.downloadItem), "local imports have no source actions")
        try expect(!details.report.contains("OriginalSecret"), "diagnostic export does not leak original URL tokens")
        var libraryRecord = LibraryPaper(record); libraryRecord.tags = ["Research", "Reading"]; libraryRecord.read = true
        model.papers = [libraryRecord]
        let libraryDetails = TaskDiagnosticView(model: model, item: record, libraryPaperID: libraryRecord.id)
        try expect(libraryDetails.recordFields.contains { $0.name == "标签" } && !libraryDetails.recordFields.contains { $0.name == "结束时间" },
                   "library details include tags but do not invent completion time when task history is gone")

        let arxivTransport = MockTransport(sourcePDF: pdf, latestVersion: 2)
        let arxivModel = DownloadModel(engine: DownloadEngine(transport: arxivTransport, pdfTransport: arxivTransport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        arxivModel.directory = root.appendingPathComponent("origin-version-downloads")
        try FileManager.default.createDirectory(at: arxivModel.directory, withIntermediateDirectories: true)
        let firstVersion = try ArxivReference.parse("1706.03762v1")
        var versioned = LibraryPaper(DownloadItem(original: firstVersion.identifier, reference: firstVersion, state: .saved, savedURL: pdf,
                                                 origin: DownloadOrigin(input: "https://huggingface.co/papers/1706.03762", capturedAt: origin.capturedAt)))
        versioned.latest = try ArxivReference.parse("1706.03762v2"); arxivModel.papers = [versioned]
        arxivModel.downloadLatest(versioned); try await waitForQueue(arxivModel)
        try expect(arxivModel.items[0].origin == versioned.origin && arxivModel.items[0].metadata?.reference.version == 2,
                   "downloading a new paper version inherits the source while requesting the selected version")

        if CommandLine.arguments.contains("--snapshots") {
            for language in [AppLanguage.chinese, .english] {
                AppLocalization.shared.language = language
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(rootView: libraryDetails.environment(\.colorScheme, scheme))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host; window.orderFront(nil)
                    try await Task.sleep(nanoseconds: 180_000_000); host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure.failed("origin detail snapshot") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/detail-source-\(language.rawValue)-\(scheme == .light ? "light" : "dark").png"))
                    window.orderOut(nil)
                }
            }
        }
        print("PASS original links: first input, retry, redownload, version updates, three stores, legacy/local records, search, copy/open and redaction")
    }
}
