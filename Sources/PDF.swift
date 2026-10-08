import Foundation
import PDFKit
import CryptoKit
import Darwin
import dnssd

enum DownloadSource: Hashable, Sendable {
    case arxiv(ArxivReference), pdf(URL)
    var reference: ArxivReference? { if case .arxiv(let ref) = self { return ref }; return nil }
    var directURL: URL? { if case .pdf(let url) = self { return url }; return nil }
    var label: String {
        switch self {
        case .arxiv(let ref): return ref.identifier
        case .pdf(let url): return (url.host ?? "PDF") + "/" + PaperMetadata.cleanTitle(url.lastPathComponent)
        }
    }
    var rateLimitKey: String { reference != nil ? "arxiv" : directURL!.host!.lowercased() }
    var webURL: URL { reference?.abstractURL ?? directURL! }

    static func parse(_ input: String) throws -> Self {
        if let reference = try? ArxivReference.parse(input) { return .arxiv(reference) }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”"))
        guard value.utf8.count <= 2048, var parts = URLComponents(string: value), let url = parts.url,
              PublicHTTPS.allows(url), !["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(parts.host?.lowercased() ?? "") else {
            throw DownloadError.invalidLink(input)
        }
        parts.fragment = nil; parts.scheme = "https"; parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        guard let canonical = parts.url else { throw DownloadError.invalidLink(input) }
        return .pdf(canonical)
    }

    static func tokens(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.flatMap { token in
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”"))
            if let host = URLComponents(string: trimmed)?.host,
               !["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(host.lowercased()) {
                return [token] // Commas/semicolons can belong to a signed PDF URL.
            }
            return ArxivReference.tokens(in: token)
        }
    }
}

enum PublicHTTPS {
    static func allows(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, let raw = url.host else { return false }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { return isPublicAddress(host) }
        if host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) { return isPublicAddress(host) }
        guard host.count <= 253, host.contains("."), !host.hasSuffix("."),
              !["localhost", "local", "internal", "home", "lan", "test", "invalid"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    static func isPublicAddress(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let denied: [(UInt32, UInt32)] = [
                (0x00000000, 0xff000000), (0x0a000000, 0xff000000), (0x64400000, 0xffc00000),
                (0x7f000000, 0xff000000), (0xa9fe0000, 0xffff0000), (0xac100000, 0xfff00000),
                (0xc0000000, 0xffffff00), (0xc0000200, 0xffffff00), (0xc0a80000, 0xffff0000),
                (0xc6120000, 0xfffe0000), (0xc6336400, 0xffffff00), (0xcb007100, 0xffffff00),
                (0xe0000000, 0xe0000000)
            ]
            return !denied.contains { n & $0.1 == $0.0 }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { bytes in
            // Global unicast only. Reject documentation and transition ranges.
            bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x01 &&
                ((bytes[2] == 0x0d && bytes[3] == 0xb8) || bytes[2] == 0))
                && !(bytes[0] == 0x20 && bytes[1] == 0x02)
        }
    }
}

// DNS-SD runs asynchronously; cancelling or timing out deallocates both queries
// on their own serial queue, so a slow lookup cannot block subsequent downloads.
private final class DNSValidationJob: @unchecked Sendable {
    private final class Context {
        let job: DNSValidationJob
        var answered = false
        init(_ job: DNSValidationJob) { self.job = job }
    }
    static let queue = DispatchQueue(label: "local.paperrepo.pdf-dns", qos: .utility)
    private var result: Result<[String], Error>?
    private var continuation: CheckedContinuation<[String], Error>?
    private var timeout: DispatchWorkItem?
    private var services: [DNSServiceRef] = []
    private var contexts: [Context] = []
    private var addresses: [String] = []
    private func finish(_ result: Result<[String], Error>) {
        guard self.result == nil else { return }
        self.result = result
        services.forEach { DNSServiceRefDeallocate($0) }; services.removeAll(); contexts.removeAll()
        timeout?.cancel(); timeout = nil
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
    func cancel() { Self.queue.async { self.finish(.failure(CancellationError())) } }
    func begin(host: String, continuation: CheckedContinuation<[String], Error>) {
        Self.queue.async { [self] in
            if let result { continuation.resume(with: result); return }
            self.continuation = continuation
            let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            timeout = timer; Self.queue.asyncAfter(deadline: .now() + 30, execute: timer)
            for family in [kDNSServiceProtocol_IPv4, kDNSServiceProtocol_IPv6] {
                let context = Context(self); contexts.append(context)
                var service: DNSServiceRef?
                let code = DNSServiceGetAddrInfo(&service, DNSServiceFlags(kDNSServiceFlagsTimeout | kDNSServiceFlagsReturnIntermediates), 0, DNSServiceProtocol(family), host,
                    { _, flags, _, error, _, address, _, pointer in
                        guard let pointer else { return }
                        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                        context.job.receive(flags: flags, error: error, address: address, context: context)
                    }, Unmanaged.passUnretained(context).toOpaque())
                guard code == kDNSServiceErr_NoError, let service else { finish(.failure(URLError(.cannotFindHost))); return }
                services.append(service)
                guard DNSServiceSetDispatchQueue(service, Self.queue) == kDNSServiceErr_NoError else { finish(.failure(URLError(.dnsLookupFailed))); return }
            }
        }
    }
    private func receive(flags: DNSServiceFlags, error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?, context: Context) {
        guard result == nil, !context.answered else { return }
        if error == kDNSServiceErr_NoError {
            guard let address, addresses.count < 64 else { finish(.failure(DownloadError.unsafeResponse)); return }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { finish(.failure(DownloadError.unsafeResponse)); return }
            let ip = String(cString: buffer)
            guard PublicHTTPS.isPublicAddress(ip) else { finish(.failure(DownloadError.unsafeResponse)); return }
            addresses.append(ip)
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { context.answered = true }
        } else if error == kDNSServiceErr_NoSuchRecord {
            context.answered = true // Other callback parameters are undefined.
        } else {
            finish(.failure(URLError(error == kDNSServiceErr_Timeout ? .timedOut : .cannotFindHost))); return
        }
        if contexts.count == 2 && contexts.allSatisfy(\.answered) {
            finish(addresses.isEmpty ? .failure(URLError(.cannotFindHost)) : .success(addresses))
        }
    }
}

enum DNSValidation {
    static func resolve(_ host: String) async throws -> [String] {
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if PublicHTTPS.isPublicAddress(literal) { return [literal] }
        let job = DNSValidationJob()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { job.begin(host: host, continuation: $0) }
        }, onCancel: { job.cancel() })
    }
}

struct SavedDocument: Sendable {
    let title: String
    var metadata: PaperMetadata? = nil
    let url: URL
    let alreadyExisted: Bool
    let pages: Int
}

enum PDFStorage {
    private static let attribute = "local.paperrepo.arxiv-downloader.pdf-source"
    private struct Record: Codable {
        let schema: Int
        let source: String
        let hash: String
        let etag: String?
        let modified: String?
        let updated: Date
    }
    struct Cached {
        let saved: SavedDocument
        let hash: String
        let etag: String?
        let modified: String?
    }
    static func key(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func fingerprint(_ file: URL) throws -> String { try PaperStorage.hash(at: file).map { String(format: "%02x", $0) }.joined() }
    private static func header(_ value: String?, limit: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit, value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return value
    }
    static func existing(source: URL, directory: URL) throws -> Cached? {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        let sourceKey = key(source.absoluteString)
        var visited = 0
        var candidates: [(URL, Record)] = []
        for case let file as URL in entries {
            try Task.checkCancellation(); visited += 1
            guard visited <= ResourceLimits.localScanEntries else { break }
            guard file.pathExtension.lowercased() == "pdf", let handle = try? PaperStorage.boundedRegularFile(at: file) else { continue }
            let record: Record? = {
                defer { try? handle.close() }
                let size = fgetxattr(handle.fileDescriptor, attribute, nil, 0, 0, 0)
                guard size > 0, size <= 2048 else { return nil }
                var data = Data(count: size)
                let read = data.withUnsafeMutableBytes { fgetxattr(handle.fileDescriptor, attribute, $0.baseAddress, size, 0, 0) }
                return read == size ? try? JSONDecoder().decode(Record.self, from: data) : nil
            }()
            guard let record, record.schema == 1, record.source == sourceKey, record.hash.utf8.count == 64,
                  record.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), record.updated.timeIntervalSince1970.isFinite,
                  record.updated.timeIntervalSinceNow <= 60 else { continue }
            candidates.append((file, record))
        }
        for (file, record) in candidates.sorted(by: { $0.1.updated > $1.1.updated }) {
            do {
                guard try fingerprint(file) == record.hash else { continue }
                let pages = try PaperStorage.validatePDF(at: file)
                let saved = SavedDocument(title: file.deletingPathExtension().lastPathComponent, url: file.resolvingSymlinksInPath().standardizedFileURL, alreadyExisted: true, pages: pages)
                return Cached(saved: saved, hash: record.hash, etag: header(record.etag, limit: 1024), modified: header(record.modified, limit: 128))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return nil
    }
    static func save(downloaded: URL, source: URL, response: HTTPURLResponse, directory: URL) throws -> SavedDocument {
        _ = try PaperStorage.validatePDF(at: downloaded)
        let suggested = response.suggestedFilename
        let fallback = suggested.flatMap { $0.utf8.count <= ResourceLimits.titleCharacters ? $0 : nil } ?? source.lastPathComponent
        let filename = (fallback as NSString).lastPathComponent
        let basename = filename.lowercased().hasSuffix(".pdf") ? String(filename.dropLast(4)) : filename
        let raw = (PDFDocument(url: downloaded)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = PaperMetadata.cleanTitle(raw.flatMap { !$0.isEmpty && $0.count <= ResourceLimits.titleCharacters && !["untitled", "unknown"].contains($0.lowercased()) ? $0 : nil } ?? (basename.isEmpty || basename == "Unknown" ? (source.host ?? "PDF") + " document" : basename))
        let sourceKey = key(source.absoluteString)
        let saved = try PaperStorage.publish(downloaded: downloaded, directory: directory, tag: String(sourceKey.prefix(10)),
            filename: { PaperMetadata.filename(title: title, ending: $0 + ".pdf") }, record: { file, hash in
                guard let handle = try? PaperStorage.boundedRegularFile(at: file) else { return }
                defer { try? handle.close() }
                // Validators identify this exact resource, not a redirect target.
                let direct = response.url == source
                let record = Record(schema: 1, source: sourceKey, hash: hash.map { String(format: "%02x", $0) }.joined(),
                    etag: direct ? header(response.value(forHTTPHeaderField: "ETag"), limit: 1024) : nil,
                    modified: direct ? header(response.value(forHTTPHeaderField: "Last-Modified"), limit: 128) : nil, updated: Date())
                guard let data = try? JSONEncoder().encode(record), data.count <= 2048 else { return }
                _ = data.withUnsafeBytes { fsetxattr(handle.fileDescriptor, attribute, $0.baseAddress, data.count, 0, 0) }
            })
        return SavedDocument(title: saved.url.deletingPathExtension().lastPathComponent, url: saved.url.resolvingSymlinksInPath().standardizedFileURL, alreadyExisted: saved.existing, pages: saved.pages)
    }
}
