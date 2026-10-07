import Foundation
import PDFKit
import CryptoKit
import Darwin

enum ResourceLimits {
    static let inputBytes = 64 * 1024
    static let batchCount = 200
    static let metadataBytes = 1024 * 1024
    static let pdfBytes: Int64 = 256 * 1024 * 1024
    static let titleCharacters = 4096
    static let retryAfterSeconds: Double = 365 * 24 * 60 * 60
}

enum DownloadError: LocalizedError {
    case invalidLink(String)
    case metadata(String)
    case http(Int, retryAfter: Double?)
    case cooldown(Double)
    case invalidPDF
    case storage(String)
    case limit(String)
    case unsafeResponse

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "无法识别：请输入 arXiv 摘要页、PDF 链接或论文编号。"
        case .metadata(let message): return message
        case .http(let code, _):
            if code == 404 { return "arXiv 未找到这篇论文或指定版本（404）。" }
            if code == 429 { return "arXiv 请求过多，请稍后重试（429）。" }
            return "arXiv 返回 HTTP \(code)，请稍后重试。"
        case .cooldown(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= ResourceLimits.retryAfterSeconds else { return "arXiv 要求暂停请求，请稍后重试。" }
            return "arXiv 要求暂停请求，请约 \(String(format: "%.0f", max(1, ceil(seconds / 60)))) 分钟后重试。"
        case .invalidPDF: return "收到的文件不是完整、可读的 PDF，未保存。"
        case .storage(let message): return "保存失败：\(message)"
        case .limit(let message): return message
        case .unsafeResponse: return "连接或重定向超出允许的 arXiv HTTPS 地址，已停止请求。"
        }
    }
}

struct ArxivReference: Hashable, Sendable {
    private static let expression = try! NSRegularExpression(pattern: #"^((?:[0-9]{2}(?:0[1-9]|1[0-2])\.[0-9]{4,5})|(?:[A-Za-z][A-Za-z.\-]*/[0-9]{2}(?:0[1-9]|1[0-2])[0-9]{3}))(?:v([1-9][0-9]*))?$"#)
    let baseID: String
    let version: Int?
    var identifier: String { baseID + (version.map { "v\($0)" } ?? "") }
    var abstractURL: URL { URL(string: "https://arxiv.org/abs/\(identifier)")! }
    var pdfURL: URL { URL(string: "https://arxiv.org/pdf/\(identifier)")! }

    static func parse(_ input: String) throws -> Self {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048 else { throw DownloadError.invalidLink(input) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”"))
        if value.lowercased().hasPrefix("arxiv:") { value = String(value.dropFirst(6)) }
        if value.lowercased().hasPrefix("arxiv.org/") || value.lowercased().hasPrefix("www.arxiv.org/") {
            value = "https://" + value
        }
        if value.contains("://") {
            guard let url = URLComponents(string: value),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.port == nil else {
                throw DownloadError.invalidLink(input)
            }
            let path = url.path
            guard let prefix = ["/abs/", "/pdf/", "/html/"].first(where: { path.hasPrefix($0) }) else {
                throw DownloadError.invalidLink(input)
            }
            value = String(path.dropFirst(prefix.count))
        }
        if value.lowercased().hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        guard value.utf8.count <= 128 else { throw DownloadError.invalidLink(input) }
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let baseRange = Range(match.range(at: 1), in: value) else {
            throw DownloadError.invalidLink(input)
        }
        var version: Int?
        if let range = Range(match.range(at: 2), in: value) {
            guard let number = Int(value[range]) else { throw DownloadError.invalidLink(input) }
            version = number
        }
        return Self(baseID: String(value[baseRange]), version: version)
    }

    static func tokens(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；")))
            .filter { !$0.isEmpty }
    }
}

enum NamingStyle: String, CaseIterable, Sendable {
    case dateTitle, identifierTitle, titleOnly
    var label: String {
        switch self {
        case .dateTitle: return "年月 + 标题"
        case .identifierTitle: return "编号 + 标题"
        case .titleOnly: return "仅标题"
        }
    }
}

struct PaperMetadata: Sendable {
    let reference: ArxivReference
    let title: String
    let year: Int
    let month: Int

    var filename: String { filename(suffix: "") }
    func filename(style: NamingStyle = .dateTitle, suffix: String = "") -> String {
        let prefix: String
        switch style {
        case .dateTitle: prefix = "[arXiv\(year).\(month)]["
        case .identifierTitle: prefix = "[\(reference.identifier.replacingOccurrences(of: "/", with: "-"))]["
        case .titleOnly: prefix = ""
        }
        let ending = (style == .titleOnly ? "" : "]") + suffix + ".pdf"
        var title = Self.cleanTitle(self.title)
        if (prefix + title + ending).utf8.count > 250 {
            let budget = max(0, 250 - prefix.utf8.count - ending.utf8.count - "…".utf8.count)
            var clipped = ""
            var bytes = 0
            for character in title {
                let part = String(character)
                guard bytes + part.utf8.count <= budget else { break }
                clipped += part
                bytes += part.utf8.count
            }
            title = clipped + "…"
        }
        return prefix + title + ending
    }

    static func cleanTitle(_ raw: String) -> String {
        var result = raw.precomposedStringWithCanonicalMapping
        for character in [":", "/", "\\", "?", "*", "\"", "<", ">", "|"] {
            result = result.replacingOccurrences(of: character, with: "-")
        }
        // Joiners are needed for compound emoji and some writing systems.
        // Other control characters, including bidi overrides and NUL, are removed.
        result = String(result.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) && $0.value != 0x200C && $0.value != 0x200D ? " " : String($0)
        }.joined())
        result = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return result.isEmpty ? "Untitled" : result
    }
}

// Atom is XML, so titles and entities are decoded by the parser instead of scraped from HTML.
final class AtomParser: NSObject, XMLParserDelegate {
    private static let encodings = try! NSRegularExpression(pattern: #"<\?xml\s[^?]*?\bencoding\s*=\s*(['\"])([^'\"]+)\1"#, options: .caseInsensitive)
    private var path: [String] = []
    private var entries: [[String: String]] = []
    private var fields: [String: String] = [:]

    static func metadata(_ data: Data, requested: ArxivReference) throws -> PaperMetadata {
        guard data.count <= ResourceLimits.metadataBytes else { throw DownloadError.limit("论文元数据超过 1 MB，已停止处理。") }
        guard let xml = String(data: data, encoding: .utf8),
              !xml.contains("\0"),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
            throw DownloadError.metadata("元数据编码或 XML 结构不符合要求，未下载。")
        }
        for match in encodings.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let range = Range(match.range(at: 2), in: xml),
                  ["utf-8", "utf8"].contains(xml[range].lowercased()) else {
                throw DownloadError.metadata("元数据必须使用 UTF-8 编码，未下载。")
            }
        }
        let delegate = AtomParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw DownloadError.metadata("arXiv 元数据无法解析，请稍后重试。") }
        for entry in delegate.entries {
            guard let id = entry["id"], let reference = try? ArxivReference.parse(id),
                  reference.baseID == requested.baseID else { continue }
            if let wanted = requested.version, reference.version != wanted {
                throw DownloadError.metadata("arXiv 返回的版本与请求版本不一致，已停止下载。")
            }
            guard reference.version != nil,
                  let title = entry["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count <= ResourceLimits.titleCharacters,
                  let date = entry["published"],
                  let year = Int(date.prefix(4)),
                  date.count >= 10, let month = Int(date.dropFirst(5).prefix(2)),
                  (1...12).contains(month), (1900...2199).contains(year) else {
                throw DownloadError.metadata("arXiv 元数据缺少标题、首次提交日期或版本号，未下载。")
            }
            return PaperMetadata(reference: reference, title: title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), year: year, month: month)
        }
        throw DownloadError.metadata("arXiv 未返回这篇论文或指定版本的元数据。")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(elementName)
        if elementName == "entry" { fields = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path.count >= 2, path[path.count - 2] == "entry", let field = path.last,
           ["id", "title", "published"].contains(field) { fields[field, default: ""] += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "entry" { entries.append(fields.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
        if !path.isEmpty { path.removeLast() }
    }
}

struct DownloadProgress: Sendable {
    let received: Int64
    let total: Int64
    var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }
}

enum DownloadEvent: Sendable {
    case metadata
    case resolved(PaperMetadata)
    case progress(DownloadProgress)
    case retry(Int)
    case validating
}

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse)
}

enum NetworkPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(parts.host?.lowercased() ?? "")
            && parts.user == nil && parts.password == nil && (parts.port == nil || parts.port == 443)
    }
}

final class ProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var error: DownloadError?
    private var lastProgress: ContinuousClock.Instant?
    private let limit: Int64
    init(limit: Int64 = ResourceLimits.pdfBytes, _ progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) {
        self.limit = limit; self.progress = progress
    }
    var failure: DownloadError? { lock.lock(); defer { lock.unlock() }; return error }
    private func reject(_ failure: DownloadError) { lock.lock(); defer { lock.unlock() }; if error == nil { error = failure } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if NetworkPolicy.allows(request.url) { completionHandler(request) }
        else { reject(.unsafeResponse); completionHandler(nil) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            reject(.limit("PDF 超过 256 MB，已停止下载。")); downloadTask.cancel(); return
        }
        let now = ContinuousClock().now
        lock.lock()
        let publish = lastProgress == nil || now >= lastProgress!.advanced(by: .milliseconds(100)) || totalBytesWritten == totalBytesExpectedToWrite
        if publish { lastProgress = now }
        lock.unlock()
        guard publish else { return }
        progress(DownloadProgress(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }
}

final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "ArxivPaperDownloader/1.0 (macOS personal-use client)"]
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard NetworkPolicy.allows(request.url) else { throw DownloadError.unsafeResponse }
        let observer = ProgressObserver()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: observer)
            defer { bytes.task.cancel() }
            if let failure = observer.failure { throw failure }
            guard let http = response as? HTTPURLResponse, NetworkPolicy.allows(response.url) else { throw DownloadError.unsafeResponse }
            guard response.expectedContentLength <= ResourceLimits.metadataBytes else { throw DownloadError.limit("论文元数据超过 1 MB，已停止下载。") }
            var body = Data()
            for try await byte in bytes {
                guard body.count < ResourceLimits.metadataBytes else { throw DownloadError.limit("论文元数据超过 1 MB，已停止下载。") }
                if body.count % 4096 == 0 { try Task.checkCancellation() }
                body.append(byte)
            }
            try Task.checkCancellation()
            return (body, http)
        } catch { throw observer.failure ?? error }
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        guard NetworkPolicy.allows(request.url) else { throw DownloadError.unsafeResponse }
        let observer = ProgressObserver(progress)
        do {
            let (url, response) = try await session.download(for: request, delegate: observer)
            do {
                if let failure = observer.failure { throw failure }
                guard let http = response as? HTTPURLResponse, NetworkPolicy.allows(response.url) else { throw DownloadError.unsafeResponse }
                return (url, http)
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        } catch {
            throw observer.failure ?? error
        }
    }
}

struct SavedPaper: Sendable {
    let metadata: PaperMetadata
    let url: URL
    let alreadyExisted: Bool
    let pages: Int
}

enum PaperStorage {
    private static func boundedRegularFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DownloadError.storage(String(cString: strerror(errno))) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw DownloadError.storage(String(cString: strerror(failure)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw DownloadError.invalidPDF
        }
        guard info.st_size >= 0, info.st_size <= ResourceLimits.pdfBytes else {
            Darwin.close(descriptor)
            throw DownloadError.limit("PDF 超过 256 MB，未处理。")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func validatePDF(at url: URL) throws -> Int {
        let handle = try boundedRegularFile(at: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= ResourceLimits.pdfBytes else { throw DownloadError.limit("PDF 超过 256 MB，未保存。") }
        guard size > 20 else { throw DownloadError.invalidPDF }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 5) ?? Data()
        try handle.seek(toOffset: size > 2048 ? size - 2048 : 0)
        let tail = try handle.read(upToCount: 2048) ?? Data()
        guard header == Data("%PDF-".utf8), tail.range(of: Data("%%EOF".utf8)) != nil,
              let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
              document.page(at: 0) != nil, document.page(at: document.pageCount - 1) != nil else {
            throw DownloadError.invalidPDF
        }
        return document.pageCount
    }

    static func hash(at url: URL) throws -> SHA256.Digest {
        let handle = try boundedRegularFile(at: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(chunk.count)
            guard bytes <= ResourceLimits.pdfBytes else { throw DownloadError.limit("文件超过 256 MB，未处理。") }
            hash.update(data: chunk)
        }
        return hash.finalize()
    }

    static func save(downloaded: URL, metadata: PaperMetadata, directory: URL, naming: NamingStyle = .dateTitle) throws -> SavedPaper {
        try Task.checkCancellation()
        let pages = try validatePDF(at: downloaded)
        let hash = try hash(at: downloaded)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DownloadError.storage("所选目录不存在，请重新选择。")
        }
        let staged = directory.appendingPathComponent(".arxiv-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: downloaded, to: staged)
        let tag = metadata.reference.identifier.replacingOccurrences(of: "/", with: "-")
        for index in 0..<1000 {
            try Task.checkCancellation()
            let suffix = index == 0 ? "" : (index == 1 ? "[\(tag)]" : "[\(tag)-\(index)]")
            let target = directory.appendingPathComponent(metadata.filename(style: naming, suffix: suffix))
            // Both paths are on the destination volume. Exclusive rename publishes
            // a complete file atomically without overwriting a concurrent writer.
            let code = staged.path.withCString { source in target.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            } }
            if code == 0 { return SavedPaper(metadata: metadata, url: target, alreadyExisted: false, pages: pages) }
            let failure = errno
            guard failure == EEXIST else { throw DownloadError.storage(String(cString: strerror(failure))) }
            // Equal SHA-256 content has already passed validation at downloaded.
            if let oldHash = try? self.hash(at: target), oldHash == hash {
                return SavedPaper(metadata: metadata, url: target.resolvingSymlinksInPath(), alreadyExisted: true, pages: pages)
            }
        }
        throw DownloadError.storage("同名文件过多，请换一个目录。")
    }
}

actor DownloadEngine {
    private let transport: HTTPTransport
    private let requestInterval: Double
    private let retryDelay: Double
    private var lastRequest: ContinuousClock.Instant?
    private var cooldownUntil: ContinuousClock.Instant?

    init(transport: HTTPTransport = URLSessionTransport(), requestInterval: Double = 3.1, retryDelay: Double = 3) {
        self.transport = transport
        self.requestInterval = requestInterval
        self.retryDelay = retryDelay
    }

    private func pace() async throws {
        try Task.checkCancellation()
        if let deadline = cooldownUntil {
            let remaining = Self.seconds(ContinuousClock().now.duration(to: deadline))
            if remaining > 60 { throw DownloadError.cooldown(remaining) }
            if remaining > 0 { try await ContinuousClock().sleep(until: deadline) }
            cooldownUntil = nil
        }
        if let previous = lastRequest {
            try await ContinuousClock().sleep(until: previous.advanced(by: .seconds(requestInterval)))
        }
        try Task.checkCancellation()
        lastRequest = ContinuousClock().now
    }

    private func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let after = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            if let after, after > 0 {
                let deadline = ContinuousClock().now.advanced(by: .seconds(after))
                cooldownUntil = max(cooldownUntil ?? deadline, deadline)
            }
            throw DownloadError.http(response.statusCode, retryAfter: after)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func retryAfter(_ raw: String?) -> Double? {
        guard let raw, raw.utf8.count <= 128 else { return nil }
        if !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = Double(raw), seconds.isFinite, seconds <= ResourceLimits.retryAfterSeconds else { return nil }
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        let seconds = max(0, date.timeIntervalSinceNow)
        return seconds <= ResourceLimits.retryAfterSeconds ? seconds : nil
    }

    private func retried<T>(event: @escaping @Sendable (DownloadEvent) -> Void, operation: () async throws -> T) async throws -> T {
        for attempt in 1...3 {
            do {
                try await pace()
                return try await operation()
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                var retry = error is URLError
                var delay = retryDelay * Double(attempt)
                if case DownloadError.http(let code, let after) = error {
                    retry = code == 408 || code == 429 || (500...599).contains(code)
                    // Report long server-requested waits rather than retry early.
                    if let after {
                        if after > 60 { throw DownloadError.cooldown(after) }
                        delay = max(delay, after)
                    }
                }
                if case DownloadError.invalidPDF = error { retry = true }
                guard retry, attempt < 3 else { throw error }
                event(.retry(attempt + 1))
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
        fatalError("Unreachable retry state")
    }

    func download(_ reference: ArxivReference, to directory: URL, naming: NamingStyle = .dateTitle, event: @escaping @Sendable (DownloadEvent) -> Void = { _ in }) async throws -> SavedPaper {
        event(.metadata)
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: reference.identifier), URLQueryItem(name: "max_results", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        let metadata: PaperMetadata = try await retried(event: event) {
            let (data, response) = try await self.transport.data(for: request)
            try self.check(response)
            return try AtomParser.metadata(data, requested: reference)
        }
        event(.resolved(metadata))
        let local: URL = try await retried(event: event) {
            let request = URLRequest(url: metadata.reference.pdfURL)
            let (file, response) = try await self.transport.download(for: request) { event(.progress($0)) }
            do {
                try self.check(response)
                _ = try PaperStorage.validatePDF(at: file)
                return file
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
        defer { try? FileManager.default.removeItem(at: local) }
        try Task.checkCancellation()
        event(.validating)
        return try PaperStorage.save(downloaded: local, metadata: metadata, directory: directory, naming: naming)
    }
}
