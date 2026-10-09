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
    static let localScanEntries = 10_000
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
    case coordination(String)

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "无法识别：请输入 arXiv / HF 论文链接、编号或 HTTPS PDF 直链。"
        case .metadata(let message), .limit(let message), .coordination(let message): return message
        case .http(let code, _):
            if code == 404 { return "下载站点未找到文件或指定版本（404）。" }
            if code == 429 { return "下载站点暂时限流（429），请稍后重试。" }
            return "下载站点返回 HTTP \(code)，请稍后重试。"
        case .cooldown(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= ResourceLimits.retryAfterSeconds else { return "arXiv 要求暂停请求，请稍后重试。" }
            return "arXiv 要求暂停请求，请约 \(String(format: "%.0f", max(1, ceil(seconds / 60)))) 分钟后重试。"
        case .invalidPDF: return "收到的文件不是完整、可读的 PDF，未保存。"
        case .storage(let message): return "保存失败：\(message)"
        case .unsafeResponse: return "连接或重定向不符合安全 HTTPS 要求，已停止请求。"
        }
    }
}

struct ArxivReference: Hashable, Sendable, Codable {
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

struct PaperMetadata: Sendable, Codable {
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
        return Self.filename(title: self.title, prefix: prefix, ending: ending)
    }

    static func filename(title raw: String, prefix: String = "", ending: String = ".pdf") -> String {
        var title = Self.cleanTitle(raw)
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

struct DownloadProgress: Sendable, Codable {
    let received: Int64
    let total: Int64
    var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }
}

enum DownloadEvent: Sendable {
    case coordinating
    case metadata
    case resolved(PaperMetadata)
    case document(String)
    case checkingLocal
    case progress(DownloadProgress)
    case retry(Int)
    case waiting(Date)
    case validating
}

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse)
}

struct HTTPResponseFailure: Error {
    let response: HTTPURLResponse
}

enum NetworkPolicy: Sendable {
    case arxiv, externalPDF
    static func allows(_ url: URL?) -> Bool { arxiv.allows(url) }
    func allows(_ url: URL?) -> Bool {
        if self == .externalPDF { return PublicHTTPS.allows(url) }
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(parts.host?.lowercased() ?? "")
            && parts.user == nil && parts.password == nil && (parts.port == nil || parts.port == 443)
    }
    func validate(_ url: URL?, resolver: @escaping @Sendable (String) async throws -> [String]) async throws {
        guard allows(url), let host = url?.host else { throw DownloadError.unsafeResponse }
        if self == .externalPDF {
            let addresses = try await resolver(host)
            guard !addresses.isEmpty, addresses.allSatisfy(PublicHTTPS.isPublicAddress) else { throw DownloadError.unsafeResponse }
        }
        try Task.checkCancellation()
    }
}

final class ProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var error: DownloadError?
    private var rejectedResponse: HTTPURLResponse?
    private var lastProgress: ContinuousClock.Instant?
    private let limit: Int64
    private let policy: NetworkPolicy
    private let resolver: @Sendable (String) async throws -> [String]
    private var allowNotModified: Bool
    private var redirects = 0
    private var redirectTask: Task<Void, Never>?
    private var stopped = false
    init(limit: Int64 = ResourceLimits.pdfBytes, policy: NetworkPolicy = .arxiv, allowNotModified: Bool = false,
         resolver: @escaping @Sendable (String) async throws -> [String] = { try await DNSValidation.resolve($0) },
         _ progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) {
        self.limit = limit; self.progress = progress; self.policy = policy
        self.allowNotModified = allowNotModified; self.resolver = resolver
    }
    var failure: DownloadError? { lock.lock(); defer { lock.unlock() }; return error }
    var httpFailure: HTTPURLResponse? { lock.lock(); defer { lock.unlock() }; return rejectedResponse }
    var acceptsNotModified: Bool { lock.lock(); defer { lock.unlock() }; return allowNotModified }
    private func reject(_ failure: DownloadError) { lock.lock(); defer { lock.unlock() }; if error == nil { error = failure } }
    func stop() {
        lock.lock(); stopped = true; let task = redirectTask; redirectTask = nil; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let allowed = redirects <= 5 && !stopped
        if policy == .externalPDF { allowNotModified = false }
        lock.unlock()
        guard allowed, policy.allows(request.url) else { reject(.unsafeResponse); completionHandler(nil); return }
        var redirected = request
        if policy == .externalPDF {
            redirected.setValue(nil, forHTTPHeaderField: "If-None-Match")
            redirected.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        }
        let task = Task {
            do { try await policy.validate(redirected.url, resolver: resolver); try Task.checkCancellation(); completionHandler(redirected) }
            catch { if !(error is CancellationError) { reject(.unsafeResponse) }; completionHandler(nil) }
        }
        lock.lock(); let cancel = stopped; if !cancel { redirectTask = task }; lock.unlock()
        if cancel { task.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode), !(acceptsNotModified && response.statusCode == 304) {
            lock.lock(); rejectedResponse = response; lock.unlock()
            downloadTask.cancel(); return
        }
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
    private let policy: NetworkPolicy
    private let resolver: @Sendable (String) async throws -> [String]
    #if TESTING
    init(testConfiguration: URLSessionConfiguration, policy: NetworkPolicy = .arxiv,
         resolver: @escaping @Sendable (String) async throws -> [String] = { _ in ["93.184.216.34"] }) {
        self.policy = policy; self.resolver = resolver
        session = URLSession(configuration: testConfiguration)
    }
    #endif
    init(policy: NetworkPolicy = .arxiv) {
        self.policy = policy; resolver = { try await DNSValidation.resolve($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "ArxivPaperDownloader/1.0 (macOS personal-use client)"]
        if policy == .externalPDF {
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
        }
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await perform(request) { observer in
            let (bytes, response) = try await session.bytes(for: request, delegate: observer)
            defer { bytes.task.cancel() }
            if let failure = observer.failure { throw failure }
            guard let http = response as? HTTPURLResponse, policy.allows(response.url) else { throw DownloadError.unsafeResponse }
            // HTTP status and Retry-After matter before the size or contents of
            // an error page; do not wait for its body to finish streaming.
            guard (200..<300).contains(http.statusCode) else { return (Data(), http) }
            guard response.expectedContentLength <= ResourceLimits.metadataBytes else { throw DownloadError.limit("论文元数据超过 1 MB，已停止下载。") }
            var body = Data()
            for try await byte in bytes {
                guard body.count < ResourceLimits.metadataBytes else { throw DownloadError.limit("论文元数据超过 1 MB，已停止下载。") }
                if body.count % 4096 == 0 { try Task.checkCancellation() }
                body.append(byte)
            }
            try Task.checkCancellation()
            return (body, http)
        }
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        let conditional = policy == .externalPDF && (request.value(forHTTPHeaderField: "If-None-Match") != nil || request.value(forHTTPHeaderField: "If-Modified-Since") != nil)
        return try await perform(request, conditional: conditional, progress: progress) { observer in
            let (url, response) = try await session.download(for: request, delegate: observer)
            do {
                if let failure = observer.failure { throw failure }
                if let response = observer.httpFailure { throw HTTPResponseFailure(response: response) }
                guard let http = response as? HTTPURLResponse, policy.allows(response.url) else { throw DownloadError.unsafeResponse }
                if http.statusCode == 304 && !observer.acceptsNotModified { throw HTTPResponseFailure(response: http) }
                return (url, http)
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }
    private func perform<T>(_ request: URLRequest, conditional: Bool = false,
                            progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in },
                            operation: (ProgressObserver) async throws -> T) async throws -> T {
        try await policy.validate(request.url, resolver: resolver)
        let observer = ProgressObserver(policy: policy, allowNotModified: conditional, resolver: resolver, progress)
        defer { observer.stop() }
        do { return try await operation(observer) }
        catch {
            if let failure = observer.failure { throw failure }
            if let response = observer.httpFailure { throw HTTPResponseFailure(response: response) }
            throw error
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
    private static let sourceAttribute = "local.paperrepo.arxiv-downloader.source"
    private struct SourceRecord: Codable {
        let schema: Int
        let identifier: String
        let sha256: String
    }

    static func readRecord<T: Decodable>(_ type: T.Type, at url: URL, attribute: String, limit: Int) -> T? {
        guard let handle = try? boundedRegularFile(at: url) else { return nil }
        defer { try? handle.close() }
        let size = fgetxattr(handle.fileDescriptor, attribute, nil, 0, 0, 0)
        guard size > 0, size <= limit else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { fgetxattr(handle.fileDescriptor, attribute, $0.baseAddress, size, 0, 0) }
        return read == size ? try? JSONDecoder().decode(type, from: data) : nil
    }

    // Unsupported or read-only extended attributes only disable the fast path.
    static func writeRecord<T: Encodable>(_ record: T, at url: URL, attribute: String, limit: Int = .max) {
        guard let handle = try? boundedRegularFile(at: url) else { return }
        defer { try? handle.close() }
        guard let data = try? JSONEncoder().encode(record), data.count <= limit else { return }
        _ = data.withUnsafeBytes { fsetxattr(handle.fileDescriptor, attribute, $0.baseAddress, data.count, 0, 0) }
    }

    static func existing(metadata: PaperMetadata, directory: URL, naming: NamingStyle) throws -> SavedPaper? {
        guard metadata.reference.version != nil else { return nil }
        let primary = directory.appendingPathComponent(metadata.filename(style: naming))
        if let saved = try trustedExisting(at: primary, metadata: metadata) { return saved }
        let tag = metadata.reference.identifier.replacingOccurrences(of: "/", with: "-")
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, _ in false }) else { return nil }
        var visited = 0
        for case let url as URL in entries {
            try Task.checkCancellation()
            visited += 1
            guard visited <= ResourceLimits.localScanEntries else { return nil }
            let name = url.lastPathComponent
            guard name.hasSuffix(".pdf"), let start = name.lastIndex(of: "[") else { continue }
            let suffix = String(name[start...])
            let numberedPrefix = "[\(tag)-"
            let collision = suffix.hasPrefix(numberedPrefix) && suffix.hasSuffix("].pdf")
                && Int(suffix.dropFirst(numberedPrefix.count).dropLast(5)).map { (2..<1000).contains($0) } == true
            guard suffix == "[\(tag)].pdf" || collision else { continue }
            if let saved = try trustedExisting(at: url, metadata: metadata) { return saved }
        }
        return nil
    }

    private static func trustedExisting(at url: URL, metadata: PaperMetadata) throws -> SavedPaper? {
        try Task.checkCancellation()
        let record = readRecord(SourceRecord.self, at: url, attribute: sourceAttribute, limit: 1024)
        guard record?.schema == 1, record?.identifier == metadata.reference.identifier else { return nil }
        do {
            let digest = try hash(at: url).map { String(format: "%02x", $0) }.joined()
            guard record?.sha256 == digest else { return nil }
            let pages = try validatePDF(at: url)
            return SavedPaper(metadata: metadata, url: url.resolvingSymlinksInPath(), alreadyExisted: true, pages: pages)
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    static func boundedRegularFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DownloadError.storage(String(cString: strerror(errno))) }
        var handedOff = false
        defer { if !handedOff { Darwin.close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw DownloadError.storage(String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DownloadError.invalidPDF }
        guard info.st_size >= 0, info.st_size <= ResourceLimits.pdfBytes else {
            throw DownloadError.limit("PDF 超过 256 MB，未处理。")
        }
        handedOff = true
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
        let tag = metadata.reference.identifier.replacingOccurrences(of: "/", with: "-")
        let saved = try publish(downloaded: downloaded, directory: directory, tag: tag,
            filename: { metadata.filename(style: naming, suffix: $0) },
            record: { file, hash in
                guard metadata.reference.version != nil else { return }
                writeRecord(SourceRecord(schema: 1, identifier: metadata.reference.identifier, sha256: hash.map { String(format: "%02x", $0) }.joined()), at: file, attribute: sourceAttribute)
            })
        return SavedPaper(metadata: metadata, url: saved.url, alreadyExisted: saved.existing, pages: saved.pages)
    }

    static func publish(downloaded: URL, directory: URL, tag: String, filename: (String) -> String,
                        record: (URL, SHA256.Digest) -> Void) throws -> (url: URL, existing: Bool, pages: Int) {
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
        do { try manager.copyItem(at: downloaded, to: staged) }
        catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw DownloadError.storage("磁盘空间不足，请释放空间或选择其他目录。")
        }
        record(staged, hash)
        for index in 0..<1000 {
            try Task.checkCancellation()
            let suffix = index == 0 ? "" : (index == 1 ? "[\(tag)]" : "[\(tag)-\(index)]")
            let target = directory.appendingPathComponent(filename(suffix))
            // Both paths are on the destination volume. Exclusive rename publishes
            // a complete file atomically without overwriting a concurrent writer.
            let code = staged.path.withCString { source in target.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            } }
            if code == 0 { return (target, false, pages) }
            let failure = errno
            guard failure == EEXIST else { throw DownloadError.storage(String(cString: strerror(failure))) }
            // Equal SHA-256 content has already passed validation at downloaded.
            if let oldHash = try? self.hash(at: target), oldHash == hash {
                record(target, hash)
                return (target.resolvingSymlinksInPath(), true, pages)
            }
        }
        throw DownloadError.storage("同名文件过多，请换一个目录。")
    }
}

actor DownloadEngine {
    private let transport: HTTPTransport
    private var pdfTransport: HTTPTransport?
    private let requestInterval: Double
    private let retryDelay: Double
    private let rateLimitDelay: Double
    private let cooldownPreferences: UserDefaults?
    private let coordinator: RequestCoordinator?
    private var lease: RequestLease?
    private var lastRequest: ContinuousClock.Instant?
    private var cooldownUntil: ContinuousClock.Instant?
    private var rateLimitStrikes = 0
    private static let cooldownKey = "requestCooldownUntil"

    init(transport: HTTPTransport = URLSessionTransport(), pdfTransport: HTTPTransport? = nil, requestInterval: Double = 15.1, retryDelay: Double = 3, rateLimitDelay: Double = 60, cooldownPreferences: UserDefaults? = nil, coordinator: RequestCoordinator? = nil) {
        self.transport = transport
        self.pdfTransport = pdfTransport
        self.requestInterval = requestInterval
        self.retryDelay = retryDelay
        self.rateLimitDelay = rateLimitDelay
        self.cooldownPreferences = cooldownPreferences
        self.coordinator = coordinator
        if let date = cooldownPreferences?.object(forKey: Self.cooldownKey) as? Date {
            let remaining = date.timeIntervalSinceNow
            if remaining.isFinite, remaining > 0, remaining <= ResourceLimits.retryAfterSeconds {
                cooldownUntil = ContinuousClock().now.advanced(by: .seconds(remaining))
            } else { cooldownPreferences?.removeObject(forKey: Self.cooldownKey) }
        }
    }

    private func pace(event: @escaping @Sendable (DownloadEvent) -> Void) async throws {
        try Task.checkCancellation()
        if let deadline = cooldownUntil {
            let remaining = Self.seconds(ContinuousClock().now.duration(to: deadline))
            if remaining > 60 { throw DownloadError.cooldown(remaining) }
            if remaining > 0 {
                event(.waiting(Date().addingTimeInterval(remaining)))
                try await ContinuousClock().sleep(until: deadline)
            }
            cooldownUntil = nil
            cooldownPreferences?.removeObject(forKey: Self.cooldownKey)
        }
        if let previous = lastRequest {
            let deadline = previous.advanced(by: .seconds(requestInterval))
            let remaining = Self.seconds(ContinuousClock().now.duration(to: deadline))
            if remaining > 0.5 { event(.waiting(Date().addingTimeInterval(remaining))) }
            try await ContinuousClock().sleep(until: deadline)
        }
        try Task.checkCancellation()
        lastRequest = ContinuousClock().now
        try persistRequestState()
    }

    private func persistRequestState() throws {
        guard let lease else { return }
        let now = ContinuousClock().now
        let previous = lastRequest.map { Date().addingTimeInterval(Self.seconds(now.duration(to: $0))) }
        let deadline = cooldownUntil.map { Date().addingTimeInterval(Self.seconds(now.duration(to: $0))) }
        try lease.store(RequestState(lastRequest: previous, cooldown: deadline, strikes: rateLimitStrikes))
    }

    private func check(_ response: HTTPURLResponse) throws {
        // Coordinated requests wait from the completed response. A slow state
        // flush or network transfer must not shorten the next process's gap.
        if lease != nil { lastRequest = ContinuousClock().now }
        guard (200..<300).contains(response.statusCode) else {
            var after = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            if response.statusCode == 429 {
                rateLimitStrikes = min(4, rateLimitStrikes + 1)
                // A missing/invalid Retry-After still requires a shared backoff.
                after = max(after ?? 0, rateLimitDelay * pow(2, Double(rateLimitStrikes - 1)))
            }
            if let after, after > 0 {
                let deadline = ContinuousClock().now.advanced(by: .seconds(after))
                cooldownUntil = max(cooldownUntil ?? deadline, deadline)
                let remaining = Self.seconds(ContinuousClock().now.duration(to: cooldownUntil!))
                cooldownPreferences?.set(Date().addingTimeInterval(remaining), forKey: Self.cooldownKey)
            }
            try persistRequestState()
            throw DownloadError.http(response.statusCode, retryAfter: after)
        }
        rateLimitStrikes = 0
        try persistRequestState()
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
            var started = false
            do {
                try await pace(event: event)
                started = true
                return try await operation()
            } catch {
                if started, lease != nil { lastRequest = ContinuousClock().now }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    if started { try? persistRequestState() }
                    throw CancellationError()
                }
                if started { try persistRequestState() }
                var error = error
                if let failure = error as? HTTPResponseFailure {
                    do { try check(failure.response) }
                    catch let checked { error = checked }
                }
                var retry = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains($0.code)
                } ?? false
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
                guard retry, attempt < 3 else {
                    if case DownloadError.http(429, let after) = error { throw DownloadError.cooldown(after ?? rateLimitDelay) }
                    throw error
                }
                event(.retry(attempt + 1))
                if delay > 0 {
                    if case DownloadError.http(429, _) = error { event(.waiting(Date().addingTimeInterval(delay))) }
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    event(.retry(attempt + 1))
                }
            }
        }
        fatalError("Unreachable retry state")
    }

    private func acquire(event: @escaping @Sendable (DownloadEvent) -> Void) async throws {
        if let coordinator {
            let acquired = try await coordinator.acquire { event(.coordinating) }
            let state = try acquired.load()
            let now = ContinuousClock().now
            if let previous = state.lastRequest {
                let age = max(0, min(requestInterval, -previous.timeIntervalSinceNow))
                let instant = now.advanced(by: .seconds(-age))
                lastRequest = max(lastRequest ?? instant, instant)
            }
            if let deadline = state.cooldown, deadline.timeIntervalSinceNow > 0 {
                let instant = now.advanced(by: .seconds(deadline.timeIntervalSinceNow))
                cooldownUntil = max(cooldownUntil ?? instant, instant)
            }
            rateLimitStrikes = state.strikes
            lease = acquired
            // Migrate any longer cooldown left by an older UI before pace can
            // report a paused batch without making a request.
            if cooldownUntil != nil { try persistRequestState() }
        }
    }

    func download(_ reference: ArxivReference, to directory: URL, naming: NamingStyle = .dateTitle, event: @escaping @Sendable (DownloadEvent) -> Void = { _ in }) async throws -> SavedPaper {
        defer { lease = nil }
        try await acquire(event: event)
        event(.metadata)
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: reference.identifier), URLQueryItem(name: "max_results", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        let metadata: PaperMetadata = try await retried(event: event) {
            event(.metadata)
            let (data, response) = try await self.transport.data(for: request)
            try self.check(response)
            return try AtomParser.metadata(data, requested: reference)
        }
        event(.resolved(metadata))
        event(.checkingLocal)
        if let existing = try PaperStorage.existing(metadata: metadata, directory: directory, naming: naming) { return existing }
        let local: URL = try await retried(event: event) {
            event(.resolved(metadata))
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

    func download(_ source: DownloadSource, to directory: URL, naming: NamingStyle = .dateTitle, event: @escaping @Sendable (DownloadEvent) -> Void = { _ in }) async throws -> SavedDocument {
        switch source {
        case .arxiv(let reference):
            let paper = try await download(reference, to: directory, naming: naming, event: event)
            return SavedDocument(title: paper.metadata.title, metadata: paper.metadata, url: paper.url, alreadyExisted: paper.alreadyExisted, pages: paper.pages)
        case .pdf(let url):
            guard PublicHTTPS.allows(url) else { throw DownloadError.unsafeResponse }
            var shared: RequestCoordinator?
            if let coordinator {
                // Establish a private parent before creating per-origin state.
                let parent = try coordinator.prepareDirectory()
                Darwin.close(parent)
                shared = RequestCoordinator(directory: coordinator.directory.appendingPathComponent("pdf-" + PDFStorage.key(url.host!.lowercased())))
            }
            if pdfTransport == nil { pdfTransport = URLSessionTransport(policy: .externalPDF) }
            let client = DownloadEngine(transport: pdfTransport!, requestInterval: coordinator == nil ? min(1, requestInterval) : 1,
                retryDelay: retryDelay, rateLimitDelay: rateLimitDelay, coordinator: shared)
            return try await client.downloadPDF(url, to: directory, event: event)
        }
    }

    private func downloadPDF(_ url: URL, to directory: URL, event: @escaping @Sendable (DownloadEvent) -> Void) async throws -> SavedDocument {
        defer { lease = nil }
        try await acquire(event: event)
        event(.checkingLocal)
        var cached = try PDFStorage.existing(source: url, directory: directory)
        return try await retried(event: event) {
            var request = URLRequest(url: url)
            request.setValue("application/pdf, application/octet-stream;q=0.9", forHTTPHeaderField: "Accept")
            if let cached {
                request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
                if cached.etag == nil { request.setValue(cached.modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            let (file, response) = try await transport.download(for: request) { event(.progress($0)) }
            defer { try? FileManager.default.removeItem(at: file) }
            if response.statusCode == 304 {
                guard response.url == url, let previous = cached, (previous.etag != nil || previous.modified != nil),
                      let verified = try PDFStorage.existing(source: url, directory: directory), verified.hash == previous.hash else {
                    cached = nil; throw DownloadError.invalidPDF
                }
                try check(HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
                event(.document(verified.saved.title))
                return verified.saved
            }
            try check(response)
            guard response.statusCode == 200 else { throw DownloadError.http(response.statusCode, retryAfter: nil) }
            try Task.checkCancellation()
            event(.validating)
            let saved = try PDFStorage.save(downloaded: file, source: url, response: response, directory: directory)
            event(.document(saved.title))
            return saved
        }
    }
}
