import Foundation
import PDFKit
import AppKit

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
        let suite = "leafpeak-file-info-retry-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
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
