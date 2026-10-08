import Foundation

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func finish() { lock.lock(); value = true; lock.unlock() }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// A deterministic server at the URL Loading System boundary. Test builds alone
// install this protocol; production keeps its normal TLS and domain checks.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError.Code?
        var sendHeaders = true
        var finish = true
    }
    private static let lock = NSLock()
    private static var replies: [String: [Reply]] = [:]
    private static var requests: [String] = []
    private static var stoppedCount = 0
    private let instanceLock = NSLock()
    private var stopped = false
    static func install(_ reply: Reply, path: String) { install([reply], path: path) }
    static func install(_ sequence: [Reply], path: String) {
        lock.lock(); defer { lock.unlock() }; replies[path] = sequence
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }; replies = [:]; requests = []; stoppedCount = 0
    }
    static func count(_ path: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        return path.map { path in requests.filter { $0 == path }.count } ?? requests.count
    }
    static var stops: Int { lock.lock(); defer { lock.unlock() }; return stoppedCount }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        let reply = Self.replies[path]?.first
        if let count = Self.replies[path]?.count, count > 1 { Self.replies[path]?.removeFirst() }
        Self.requests.append(path)
        Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        if reply.sendHeaders {
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        for offset in stride(from: 0, to: reply.body.count, by: 4096) {
            instanceLock.lock(); let cancelled = stopped; instanceLock.unlock()
            if cancelled { return }
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<min(offset + 4096, reply.body.count)))
        }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)) }
        else if reply.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        instanceLock.lock(); stopped = true; instanceLock.unlock()
        Self.lock.lock(); Self.stoppedCount += 1; Self.lock.unlock()
    }
}

extension CoreTests {
    static func transportTests(root: URL, pdf: URL) async throws {
        FixtureProtocol.reset()
        defer { FixtureProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let transport = URLSessionTransport(testConfiguration: configuration)
        func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://export.arxiv.org\(path)")!) }
        let pdfData = try Data(contentsOf: pdf)

        FixtureProtocol.install(.init(body: atom()), path: "/metadata")
        let (data, response) = try await transport.data(for: request("/metadata"))
        try expect(data == atom() && response.statusCode == 200, "URLSession metadata bytes")
        FixtureProtocol.install(.init(body: pdfData), path: "/pdf")
        let (file, pdfResponse) = try await transport.download(for: request("/pdf"), progress: { _ in })
        try expect(pdfResponse.statusCode == 200 && (try PaperStorage.validatePDF(at: file)) == 1, "URLSession download produces a valid temporary PDF")
        try FileManager.default.removeItem(at: file)

        // Error pages must not mask HTTP status with a size error, or wait for EOF.
        FixtureProtocol.install(.init(status: 429, headers: ["Retry-After": "600", "Content-Length": "2000000"], body: Data(repeating: 120, count: 4096), finish: false), path: "/throttled")
        let started = ContinuousClock().now
        let completion = CompletionFlag()
        let limited = Task { defer { completion.finish() }; return try await transport.data(for: request("/throttled")) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let completedBeforeCancellation = completion.finished
        limited.cancel() // watchdog: the corrected path has already completed.
        let (errorBody, limitedResponse) = try await limited.value
        try expect(completedBeforeCancellation, "429 completes before watchdog cancellation")
        try expect(limitedResponse.statusCode == 429 && errorBody.isEmpty, "429 headers preserved before oversized/stalled error body")
        try expect(started.duration(to: ContinuousClock().now) < .seconds(1), "429 delivered promptly")

        for beforeHeaders in [true, false] {
            FixtureProtocol.install(.init(body: beforeHeaders ? Data() : Data("partial".utf8), sendHeaders: !beforeHeaders, finish: false), path: "/cancel-metadata")
            let stops = FixtureProtocol.stops
            let job = Task { try await transport.data(for: request("/cancel-metadata")) }
            try await Task.sleep(nanoseconds: 30_000_000)
            job.cancel()
            do { _ = try await job.value; throw TestFailure.failed("URLSession metadata ignored cancellation") }
            catch { try expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "URLSession cancellation type") }
            try await Task.sleep(nanoseconds: 30_000_000)
            try expect(FixtureProtocol.stops > stops, "URLSession cancellation stops the protocol")
        }
        FixtureProtocol.install(.init(body: Data(pdfData.prefix(128)), finish: false), path: "/cancel-pdf")
        let pdfJob = Task { try await transport.download(for: request("/cancel-pdf"), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 30_000_000)
        pdfJob.cancel()
        do { _ = try await pdfJob.value; throw TestFailure.failed("URLSession PDF ignored cancellation") }
        catch { try expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "URLSession PDF cancellation type") }

        let calls = FixtureProtocol.count()
        do { _ = try await transport.data(for: URLRequest(url: URL(string: "https://example.com/metadata")!)); throw TestFailure.failed("unsafe host requested") }
        catch DownloadError.unsafeResponse { }
        try expect(FixtureProtocol.count() == calls, "unsafe host rejected before URL loading")

        FixtureProtocol.install(.init(body: Data(repeating: 32, count: ResourceLimits.metadataBytes + 4096)), path: "/oversized")
        do { _ = try await transport.data(for: request("/oversized")); throw TestFailure.failed("oversized metadata accepted") }
        catch DownloadError.limit { }

        let ref = try ArxivReference.parse("2501.12345v2")
        let pdfPath = ref.pdfURL.path
        let folder = root.appendingPathComponent("urlsession", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for mode in ["disconnected", "503", "corrupt", "429"] {
            FixtureProtocol.install(.init(body: atom()), path: "/api/query")
            let previous = FixtureProtocol.count(pdfPath)
            switch mode {
            case "disconnected": FixtureProtocol.install([.init(body: Data(pdfData.prefix(128)), error: .networkConnectionLost), .init(body: pdfData)], path: pdfPath)
            case "503": FixtureProtocol.install([.init(status: 503, body: Data(repeating: 120, count: 4096)), .init(body: pdfData)], path: pdfPath)
            case "corrupt": FixtureProtocol.install(.init(body: Data("<html>not PDF</html>".utf8)), path: pdfPath)
            default: FixtureProtocol.install(.init(status: 429, headers: ["Retry-After": "600"], body: Data(repeating: 120, count: 4096)), path: pdfPath)
            }
            let target = folder.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let engine = DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0)
            do {
                let saved = try await engine.download(ref, to: target)
                try expect(mode == "disconnected" || mode == "503", "unexpected URLSession error-path success")
                try expect(saved.pages == 1, "URLSession retry saves validated PDF")
            } catch DownloadError.invalidPDF where mode == "corrupt" { }
            catch DownloadError.cooldown(let seconds) where mode == "429" { try expect(seconds > 590, "PDF HTTP cancellation retains Retry-After") }
            let expected = mode == "corrupt" ? 3 : mode == "429" ? 1 : 2
            try expect(FixtureProtocol.count(pdfPath) - previous == expected, "URLSession bounded retries for \(mode)")
            let files = try FileManager.default.contentsOfDirectory(atPath: target.path)
            try expect(!files.contains(where: { $0.hasSuffix(".partial") }), "URLSession error/cancel leaves no destination partial")
            if mode == "429" {
                do { _ = try await engine.download(ref, to: target); throw TestFailure.failed("PDF cooldown bypassed") }
                catch DownloadError.cooldown { }
                try expect(FixtureProtocol.count(pdfPath) - previous == 1, "PDF cooldown blocks subsequent requests")
            }
        }
        for code in [URLError.Code.timedOut, .cannotWriteToFile] {
            FixtureProtocol.install(.init(body: atom()), path: "/api/query")
            FixtureProtocol.install(.init(error: code, sendHeaders: false), path: pdfPath)
            let previous = FixtureProtocol.count(pdfPath)
            do { _ = try await DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0).download(ref, to: folder); throw TestFailure.failed("URLSession failure ignored") }
            catch let error as URLError { try expect(error.code == code, "URLSession preserves timeout/disk error") }
            try expect(FixtureProtocol.count(pdfPath) - previous == (code == .timedOut ? 3 : 1), "timeout retries bounded; disk failure not retried")
        }
        FixtureProtocol.install(.init(body: atom()), path: "/api/query")
        FixtureProtocol.install(.init(body: pdfData), path: pdfPath)
        for _ in 0..<30 {
            weak var released: URLSessionTransport?
            do {
                let current = URLSessionTransport(testConfiguration: configuration)
                released = current
                _ = try await DownloadEngine(transport: current, requestInterval: 0, retryDelay: 0).download(ref, to: folder)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            try expect(released == nil, "completed URLSession transport releases")
        }
        print("PASS URLSession: metadata/PDF, stalled 429, cancellation, domain/size bounds, retries, timeout/disk errors, corrupt PDF, cooldown and 30 released sessions")
    }
}
