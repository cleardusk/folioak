import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

struct FileInformation: Equatable, Sendable {
    struct Field: Equatable, Sendable { let name: String; let value: String }
    struct Group: Equatable, Sendable { let title: String; var fields: [Field] }
    let url: URL
    var groups: [Group] = []
    var issue: String?

    // Reading metadata never changes the file, download record or library.
    // PDFKit/ImageIO work stays off the main actor; the sheet owns cancellation.
    static func read(_ url: URL, title: String? = nil, author: String? = nil) async throws -> Self {
        let native = Task.detached(priority: .userInitiated) { try basic(url, title: title, author: author) }
        var result = try await withTaskCancellationHandler(operation: { try await native.value }, onCancel: { native.cancel() })
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard result.issue == nil, FileStorage.extensions.contains(ext), !FileStorage.imageExtensions.contains(ext) else { return result }
        do {
            let output = MediaOutput(), process = MediaProcess()
            let tools = try MediaTools.installed()
            let status = try await process.run(try tools.executable("ffprobe"), arguments: [
                "-v", "quiet", "-protocol_whitelist", "file", "-probesize", "5000000", "-analyzeduration", "5000000",
                "-show_entries", "format=duration,bit_rate:stream=codec_type,codec_name,width,height,avg_frame_rate,bit_rate,sample_rate,channels:stream_disposition=attached_pic:stream_side_data=rotation:stream_tags=rotate",
                "-of", "json", url.path
            ], timeout: 10) { line in
                if output.text.utf8.count + line.utf8.count < 256 * 1024 { output.text += line + "\n" }
                else { process.stop() }
            }
            try Task.checkCancellation()
            guard status == 0 else { result.issue = "未能读取音视频参数。"; return result }
            result.groups += try mediaGroups(Data(output.text.utf8))
        } catch is CancellationError {
            try Task.checkCancellation()
            result.issue = "未能读取音视频参数。"
        } catch { result.issue = "未能读取音视频参数。" }
        return result
    }

    private static func basic(_ url: URL, title: String?, author: String?) throws -> Self {
        var result = Self(url: url)
        var fields = [Field(name: "文件名", value: url.lastPathComponent), Field(name: "位置", value: url.path)]
        result.groups = [Group(title: "文件信息", fields: fields)]
        guard url.isFileURL else { result.issue = "无法读取此文件。"; return result }
        do {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
            guard values.isRegularFile == true else { result.issue = "此路径不是普通文件。"; return result }
            if let size = values.fileSize { fields.append(Field(name: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
            if let type = values.contentType?.localizedDescription { fields.append(Field(name: "类型", value: type)) }
            if let date = values.creationDate { fields.append(Field(name: "创建时间", value: date.formatted(date: .abbreviated, time: .standard))) }
            if let date = values.contentModificationDate { fields.append(Field(name: "修改时间", value: date.formatted(date: .abbreviated, time: .standard))) }
            result.groups = [Group(title: "文件信息", fields: fields)]
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let size = values.fileSize, size <= ResourceLimits.pdfBytes else { result.issue = "PDF 较大，未读取内容信息。"; return result }
                guard let document = PDFDocument(url: url) else { result.issue = "无法读取 PDF 信息。"; return result }
                if document.isLocked { result.issue = "PDF 已加密，需要密码才能读取内容信息。"; return result }
                var pdf = [Field(name: "页数", value: String(document.pageCount))]
                if let page = document.page(at: 0) {
                    let size = page.bounds(for: .mediaBox).size
                    let rotated = abs(page.rotation % 180) == 90
                    let width = (rotated ? size.height : size.width) * 25.4 / 72
                    let height = (rotated ? size.width : size.height) * 25.4 / 72
                    if width.isFinite, height.isFinite, width > 0, height > 0 {
                        pdf.append(Field(name: "首页尺寸", value: String(format: "%.1f × %.1f mm", width, height)))
                    }
                }
                if let value = clean(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? clean(title) { pdf.append(Field(name: "标题", value: value)) }
                if let value = clean(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) ?? clean(author) { pdf.append(Field(name: "作者", value: value)) }
                result.groups.append(Group(title: "PDF", fields: pdf))
            } else if FileStorage.imageExtensions.contains(ext) {
                guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { result.issue = "无法读取图片信息。"; return result }
                result.groups.append(Group(title: "图片", fields: [Field(name: "尺寸", value: "\(width) × \(height) 像素")]))
            }
            try Task.checkCancellation()
        } catch is CancellationError { throw CancellationError() }
        catch { result.issue = "文件不存在或无法访问。" }
        return result
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(4096))
    }
    private struct Probe: Decodable {
        struct Format: Decodable { let duration: String?; let bit_rate: String? }
        struct Stream: Decodable {
            struct Disposition: Decodable { let attached_pic: Int? }
            struct SideData: Decodable { let rotation: Double? }
            struct Tags: Decodable { let rotate: String? }
            let codec_type: String?, codec_name: String?, avg_frame_rate: String?, bit_rate: String?, sample_rate: String?
            let width: Int?, height: Int?, channels: Int?
            let disposition: Disposition?
            let side_data_list: [SideData]?
            let tags: Tags?
        }
        let streams: [Stream]?
        let format: Format?
    }
    private static func positive(_ text: String?) -> Double? {
        guard let text, let number = Double(text), number.isFinite, number > 0 else { return nil }
        return number
    }
    private static func bitrate(_ text: String?) -> String? {
        positive(text).map { $0 >= 1_000_000 ? String(format: "%.2f Mb/s", $0 / 1_000_000) : String(format: "%.0f kb/s", $0 / 1000) }
    }
    static func mediaGroups(_ data: Data) throws -> [Group] {
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        var groups: [Group] = [], common: [Field] = []
        if let seconds = positive(probe.format?.duration), seconds < Double(Int32.max) {
            let time = Int(seconds.rounded())
            common.append(Field(name: "时长", value: time >= 3600 ? String(format: "%d:%02d:%02d", time / 3600, time / 60 % 60, time % 60) : String(format: "%d:%02d", time / 60, time % 60)))
        }
        if let value = bitrate(probe.format?.bit_rate) { common.append(Field(name: "总比特率", value: value)) }
        if !common.isEmpty { groups.append(Group(title: "媒体", fields: common)) }
        let videos = (probe.streams ?? []).filter { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }
        if let video = videos.first {
            var fields: [Field] = []
            if let width = video.width, let height = video.height, width > 0, height > 0 {
                let sideRotation: Double? = video.side_data_list?.compactMap { $0.rotation }.first
                let tagRotation: Double? = video.tags.flatMap { $0.rotate }.flatMap { Double($0) }
                let rotation: Double = sideRotation ?? tagRotation ?? 0
                let rotated = rotation.isFinite && abs(rotation.truncatingRemainder(dividingBy: 180)) == 90
                fields.append(Field(name: "分辨率", value: rotated ? "\(height) × \(width)" : "\(width) × \(height)"))
            }
            if let rate = video.avg_frame_rate {
                let parts = rate.split(separator: "/", omittingEmptySubsequences: false)
                let fps: Double? = parts.count == 2 ? positive(String(parts[0])).flatMap { n in positive(String(parts[1])).map { n / $0 } } : positive(rate)
                if let fps, fps.isFinite, fps > 0, fps <= 1000 { fields.append(Field(name: "帧率", value: fps.formatted(.number.precision(.fractionLength(0...2))) + " fps")) }
            }
            if let value = clean(video.codec_name) { fields.append(Field(name: "编码", value: value.uppercased())) }
            if let value = bitrate(video.bit_rate) { fields.append(Field(name: "视频比特率", value: value)) }
            if !fields.isEmpty { groups.append(Group(title: videos.count > 1 ? "视频（首轨）" : "视频", fields: fields)) }
        }
        let audios = (probe.streams ?? []).filter { $0.codec_type == "audio" }
        if let audio = audios.first {
            var fields: [Field] = []
            if let value = clean(audio.codec_name) { fields.append(Field(name: "编码", value: value.uppercased())) }
            if let value = bitrate(audio.bit_rate) { fields.append(Field(name: "音频比特率", value: value)) }
            if let value = positive(audio.sample_rate), value <= 10_000_000 { fields.append(Field(name: "采样率", value: (value / 1000).formatted(.number.precision(.fractionLength(0...2))) + " kHz")) }
            if let channels = audio.channels, channels > 0 { fields.append(Field(name: "声道", value: String(channels))) }
            if !fields.isEmpty { groups.append(Group(title: audios.count > 1 ? "音频（首轨）" : "音频", fields: fields)) }
        }
        guard !groups.isEmpty else { throw DownloadError.metadata("无法读取媒体参数") }
        return groups
    }
}
