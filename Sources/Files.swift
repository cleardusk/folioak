import Foundation

// Common document/archive types stay separate from media: they never enter
// ffprobe or audio conversion, and remain in the independent document library.
enum GenericFileStorage {
    static let officeExtensions: Set<String> = ["ppt", "pptx", "doc", "docx", "xls", "xlsx", "odt", "ods", "odp", "epub"]
    static let textExtensions: Set<String> = ["txt", "md", "csv", "tsv", "json", "xml", "rtf", "yaml", "yml", "log"]
    static let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz"]
    static let extensions = officeExtensions.union(textExtensions).union(archiveExtensions)
    static let mimeTypes: [String: String] = [
        "application/vnd.ms-powerpoint": "ppt", "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/msword": "doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/epub+zip": "epub", "application/vnd.oasis.opendocument.text": "odt",
        "application/vnd.oasis.opendocument.spreadsheet": "ods", "application/vnd.oasis.opendocument.presentation": "odp",
        "text/plain": "txt", "text/markdown": "md", "text/csv": "csv", "text/tab-separated-values": "tsv",
        "application/json": "json", "application/xml": "xml", "text/xml": "xml", "application/rtf": "rtf", "text/rtf": "rtf",
        "application/yaml": "yaml", "text/yaml": "yaml", "application/zip": "zip", "application/x-zip-compressed": "zip",
        "application/x-7z-compressed": "7z", "application/vnd.rar": "rar", "application/x-rar-compressed": "rar",
        "application/x-tar": "tar", "application/gzip": "gz", "application/x-gzip": "gz",
        "application/x-bzip2": "bz2", "application/x-xz": "xz"
    ]
    static func symbol(_ ext: String) -> String {
        if archiveExtensions.contains(ext) { return "archivebox" }
        if ["ppt", "pptx", "odp"].contains(ext) { return "rectangle.on.rectangle" }
        if ["xls", "xlsx", "ods", "csv", "tsv"].contains(ext) { return "tablecells" }
        return ext == "epub" ? "book.closed" : "doc.text"
    }
    static func prefix(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 8192) ?? Data()
    }
    private static func isZip(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0x50, 0x4b, 0x05, 0x06])
    }
    static func detectedExtension(_ file: URL, source: URL, response: HTTPURLResponse) async throws -> String? {
        let names = [response.suggestedFilename, response.url?.lastPathComponent, source.lastPathComponent].compactMap { $0 }
        let hint = names.map { ($0 as NSString).pathExtension.lowercased() }.first { extensions.contains($0) }
            ?? response.mimeType.flatMap { mimeTypes[$0.lowercased()] }
        let data = try prefix(file)
        if isZip(data) {
            let entries = try await zipEntries(file)
            if entries.contains("[Content_Types].xml") {
                if entries.contains("ppt/presentation.xml") { return "pptx" }
                if entries.contains("word/document.xml") { return "docx" }
                if entries.contains("xl/workbook.xml") { return "xlsx" }
            }
            if entries.contains("mimetype"), entries.contains("META-INF/container.xml") || entries.contains("content.xml") {
                let type = (try? await containerMIME(file)) ?? ""
                try Task.checkCancellation()
                if type == "application/epub+zip", entries.contains("META-INF/container.xml") { return "epub" }
                if let ext = mimeTypes[type], ["odt", "ods", "odp"].contains(ext), entries.contains("content.xml") { return ext }
            }
            // Declared container types still have to pass validation below.
            if let hint, officeExtensions.contains(hint) { return hint }
            return "zip"
        }
        if data.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { return "7z" }
        if data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]) || data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]) { return "rar" }
        if data.starts(with: [0x1f, 0x8b, 0x08]) { return hint == "tgz" ? "tgz" : "gz" }
        if data.starts(with: Data("BZh".utf8)) { return "bz2" }
        if data.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return "xz" }
        if data.dropFirst(257).starts(with: Data("ustar".utf8)) { return "tar" }
        // A mislabeled media response must still reach the existing stream probe.
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return hint }
        if mediaHeader(data) { return nil }
        return hint
    }
    private static func mediaHeader(_ data: Data) -> Bool {
        // Require the binary header structure, not just words that can begin
        // a perfectly ordinary text document (for example “ID3 tags…”).
        if data.count >= 10, data.starts(with: Data("ID3".utf8)), (2...4).contains(data[3]),
           data[4] != 0xff, data[6..<10].allSatisfy({ $0 < 0x80 }) { return true }
        if data.count >= 5, data.starts(with: Data("OggS".utf8)), data[4] == 0 { return true }
        if data.count >= 5, data.starts(with: Data("fLaC".utf8)), data[4] & 0x7f <= 6 { return true }
        if data.starts(with: Data("RIFF".utf8)), ["WAVE", "AVI "].contains(where: { data.dropFirst(8).starts(with: Data($0.utf8)) }) { return true }
        if data.dropFirst(4).starts(with: Data("ftyp".utf8)) || data.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return true }
        let bytes = Array(data.prefix(2))
        return bytes.count == 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0
    }
    private final class DirectoryOutput: @unchecked Sendable {
        // Only the process reader mutates this; read after run() has joined it.
        var entries = Set<String>()
        var bytes = 0
        var overflow = false
    }
    private static func zipEntries(_ file: URL) async throws -> Set<String> {
        let head = try prefix(file)
        // Info-ZIP returns status 1 for an empty ZIP. Accept only a complete
        // single-volume, zero-entry EOCD (including its optional comment).
        if head.starts(with: [0x50, 0x4b, 0x05, 0x06]), head.count >= 22,
           head[4..<20].allSatisfy({ $0 == 0 }) {
            let length = 22 + Int(head[20]) + (Int(head[21]) << 8)
            if try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == length { return [] }
        }
        let output = DirectoryOutput(), process = MediaProcess()
        let status: Int32
        do {
            status = try await process.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", file.path], timeout: 15) { line in
                output.bytes += line.utf8.count + 1
                if output.bytes < 2 * 1024 * 1024 && output.entries.count < 50_000 { output.entries.insert(line) }
                else { output.overflow = true; process.stop() }
            }
        } catch {
            try Task.checkCancellation()
            throw DownloadError.invalidFileDirectory
        }
        guard status == 0, !output.overflow else { throw DownloadError.invalidFileDirectory }
        return output.entries
    }
    private static func containerMIME(_ file: URL) async throws -> String {
        let output = MediaOutput(), process = MediaProcess()
        let status: Int32
        do {
            status = try await process.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", file.path, "mimetype"], timeout: 2) { line in
                if output.text.utf8.count + line.utf8.count <= 256 { output.text += line }
                else { output.error = "limit"; process.stop() }
            }
        } catch {
            try Task.checkCancellation()
            throw DownloadError.invalidFileDirectory
        }
        guard status == 0, output.error.isEmpty, !output.text.isEmpty else { throw DownloadError.invalidFileDirectory }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func validate(_ file: URL, extension ext: String) async throws {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= FileStorage.byteLimit, extensions.contains(ext) else {
            throw DownloadError.metadata("文件为空、格式不支持或超过 16 GB，未保存。")
        }
        let data = try prefix(file)
        let text = (data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])) ? (String(data: data, encoding: .utf16) ?? "") : String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !textExtensions.contains(ext) || trimmed.range(of: #"(?s)^\uFEFF?\s*(?:(?:<!--.*?-->|<\?xml.*?\?>)\s*)*<(?:!doctype\s+html|html|head|body)(?:\s|>)"#, options: .regularExpression) == nil else {
            throw DownloadError.webPage
        }
        var valid = false
        switch ext {
        case "pptx", "docx", "xlsx", "epub", "odt", "ods", "odp", "zip":
            if isZip(data) {
                let entries = try await zipEntries(file)
                switch ext {
                case "pptx": valid = entries.contains("[Content_Types].xml") && entries.contains("ppt/presentation.xml")
                case "docx": valid = entries.contains("[Content_Types].xml") && entries.contains("word/document.xml")
                case "xlsx": valid = entries.contains("[Content_Types].xml") && entries.contains("xl/workbook.xml")
                case "epub":
                    if entries.contains("mimetype"), entries.contains("META-INF/container.xml") { valid = try await containerMIME(file) == "application/epub+zip" }
                case "odt", "ods", "odp":
                    if entries.contains("mimetype"), entries.contains("content.xml") { valid = try await mimeTypes[containerMIME(file)] == ext }
                default: valid = true
                }
            }
        case "ppt", "doc", "xls": valid = size >= 512 && data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        case "7z": valid = size >= 32 && data.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])
        case "rar": valid = size >= 8 && (data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]) || data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]))
        case "gz", "tgz": valid = size >= 18 && data.starts(with: [0x1f, 0x8b, 0x08])
        case "bz2": valid = size >= 14 && data.starts(with: Data("BZh".utf8))
        case "xz": valid = size >= 32 && data.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
        case "tar": valid = size >= 512 && (data.dropFirst(257).starts(with: Data("ustar".utf8)) || data.prefix(512).allSatisfy { $0 == 0 })
        case "rtf": valid = trimmed.hasPrefix("{\\rtf")
        default:
            // Text need not be UTF-8 (UTF-16 and legacy encodings are common).
            // Reject binary NULs unless a UTF-16 BOM explicitly identifies it.
            valid = !data.contains(0) || data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        }
        guard valid else { throw DownloadError.invalidFile }
        try Task.checkCancellation()
    }
}
