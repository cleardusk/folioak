import Foundation
import PDFKit
import CoreGraphics
import SwiftUI
import AppKit

enum TestFailure: Error { case failed(String) }
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.failed(message) }
}
func rejects(_ action: () throws -> Void, _ message: String) throws {
    do { try action() } catch { return }
    throw TestFailure.failed(message)
}

func atom(id: String = "2501.12345v2", title: String = "Test &amp; Example: A Paper", published: String = "2025-01-03T12:00:00Z") -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><title>Query title, not paper title</title><entry>
    <id>http://arxiv.org/abs/\(id)</id><title>\(title)</title>
    <published>\(published)</published><updated>2026-02-01T12:00:00Z</updated>
    </entry></feed>
    """.utf8)
}

func createPDF(at url: URL, shade: CGFloat = 0.5) throws {
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw TestFailure.failed("PDF context creation") }
    context.beginPDFPage(nil)
    context.setFillColor(gray: shade, alpha: 1)
    context.fill(CGRect(x: 30, y: 30, width: 100, height: 100))
    context.endPDFPage()
    context.closePDF()
}

enum MockReply {
    case status(Int, String? = nil), network(URLError.Code), corrupt, failure(DownloadError)
}

private final class ResponseDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    let fixture: HTTPURLResponse
    private(set) var cancelled = false
    init(_ fixture: HTTPURLResponse) { self.fixture = fixture; super.init() }
    override var response: URLResponse? { fixture }
    override func cancel() { cancelled = true }
}

actor MockTransport: HTTPTransport {
    private var metadataReplies: [MockReply]
    private var pdfReplies: [MockReply]
    private let sourcePDF: URL
    private let delay: UInt64
    private let latestVersion: Int?
    private(set) var metadataCalls = 0
    private(set) var pdfCalls = 0
    private(set) var times: [Date] = []
    private(set) var pdfURLs: [URL] = []
    private(set) var tempFiles: [URL] = []

    init(sourcePDF: URL, metadata: [MockReply] = [.status(200)], pdf: [MockReply] = [.status(200)], delay: UInt64 = 0, latestVersion: Int? = nil) {
        self.sourcePDF = sourcePDF; metadataReplies = metadata; pdfReplies = pdf; self.delay = delay; self.latestVersion = latestVersion
    }
    private func response(_ reply: MockReply, url: URL) throws -> HTTPURLResponse {
        switch reply {
        case .failure(let error): throw error
        case .network(let code): throw URLError(code)
        case .status(let code, let after):
            return HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: after.map { ["Retry-After": $0] })!
        case .corrupt: return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        times.append(Date()); metadataCalls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let reply = metadataReplies.count > 1 ? metadataReplies.removeFirst() : metadataReplies[0]
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id_list" }?.value
        let requested = id.flatMap { try? ArxivReference.parse($0) }
        let data = latestVersion.map { latest in atom(id: "\(requested?.baseID ?? "2501.12345")v\(requested?.version ?? latest)") } ?? atom()
        return (data, try response(reply, url: request.url!))
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        times.append(Date()); pdfCalls += 1; pdfURLs.append(request.url!)
        let reply = pdfReplies.count > 1 ? pdfReplies.removeFirst() : pdfReplies[0]
        let response = try response(reply, url: request.url!)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("arxiv-test-\(UUID().uuidString).pdf")
        if case .corrupt = reply { try Data("<html>Not a PDF</html>".utf8).write(to: temp) }
        else { try FileManager.default.copyItem(at: sourcePDF, to: temp) }
        tempFiles.append(temp)
        progress(DownloadProgress(received: 512, total: 1024))
        return (temp, response)
    }
}

@main
struct CoreTests {
    @MainActor static func main() {
        // Native sheets can stop a run-loop iteration. Swift's async-main drain
        // then exits with status 0, so keep the host alive until the suite returns.
        var completed = false
        Task { @MainActor in
            await runTests()
            completed = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        while !completed { CFRunLoopRun() }
    }

    @MainActor static func runTests() async {
        defer { print("PASS core test suite completed") }
        AppLocalization.shared.language = .chinese
        do {
            if CommandLine.arguments.contains("--row-clicks-only") {
                try await fileRowDoubleClickTests()
                return
            }
            if CommandLine.arguments.contains("--quick-only") {
                try await quickDownloadTests()
                try await quickDownloadUITests()
                return
            }
            if CommandLine.arguments.contains("--library-management-only") {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-library-management-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let pdf = root.appendingPathComponent("fixture.pdf")
                try createPDF(at: pdf)
                try await libraryManagementTests(root: root, pdf: pdf)
                try fileListSelectionTests()
                try await librarySelectionUITests()
                return
            }
            if CommandLine.arguments.contains("--updates-live") { try await liveUpdateTest(); return }
            try await updateTests()
            try await updateIntegrationTests()
            if CommandLine.arguments.contains("--updates-only") {
                if CommandLine.arguments.contains("--snapshots") { try renderUpdateSnapshots() }
                return
            }
            if CommandLine.arguments.contains("--about-only") { try await aboutAndMenuBarTests(); return }
            try messageTests()
            try await localizationTests()
            if CommandLine.arguments.contains("--preview-230") { try renderMediaSnapshots(); return }
            if CommandLine.arguments.contains("--ui-only") {
                try initialDirectoryTests()
                try await sidebarLayoutTests()
                try menuChevronTests()
                try sidebarMotionTests()
                try themeTests()
                try inputLayoutTests()
                try await inputFocusRaceTests()
                try windowChromeTests()
                try filterRenderingTests()
                try logGroupingTests()
                try await settingsLayoutTests()
                try await aboutAndMenuBarTests()
                try await detailInteractionTests()
                try await inputScrollGutterTests()
                try await logScrollTests()
                try await inputColorTransitionTests()
                try await listFocusTests()
                try await selectionFocusTests()
                try await blankCanvasFocusTests()
                try fileListSelectionTests()
                try await librarySelectionUITests()
                try await thumbnailTests()
                if CommandLine.arguments.contains("--snapshots") { try renderSnapshots() }
                return
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("arxiv-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let pdf = root.appendingPathComponent("sample.pdf")
            try createPDF(at: pdf)
            try await mediaTests(root: root)
            try await fileInformationTests(root: root, pdf: pdf)
            try await thumbnailTests()
            if CommandLine.arguments.contains("--media-only") { return }
            try parseTests()
            try await huggingFaceTests(root: root, pdf: pdf)
            try await githubPDFTests(root: root, pdf: pdf)
            try metadataTests()
            try securityTests(root: root)
            try storageTests(root: root, pdf: pdf)
            try filenameStorageTests(root: root, pdf: pdf)
            try await cliTests(root: root, pdf: pdf)
            try await featureTests(root: root, pdf: pdf)
            try await libraryTests(root: root, pdf: pdf)
            try await libraryManagementTests(root: root, pdf: pdf)
            try await sourceSchedulingTests()
            try await coordinatorTests(root: root, pdf: pdf)
            try await processTests(root: root, pdf: pdf)
            try await networkTests(root: root, pdf: pdf)
            try await transportTests(root: root, pdf: pdf)
            try await genericPDFTests(root: root, pdf: pdf)
            try await existingFileTests(root: root, pdf: pdf)
            try await queueTests(root: root, pdf: pdf)
            try await completedInputTests(root: root, pdf: pdf)
            try await restoreVersionTests(root: root, pdf: pdf)
            try await workspaceTests(root: root, pdf: pdf)
            try await quickDownloadTests()
            try await quickDownloadUITests()
            try await backgroundPersistenceTests(root: root, pdf: pdf)
            try await messagePersistenceTests(root: root, pdf: pdf)
            try await clearDownloadRecordsTests(root: root, pdf: pdf)
            try await clearSingleDownloadRecordTests(root: root, pdf: pdf)
            try fileListSelectionTests()
            try await librarySelectionUITests()
            try menuChevronTests()
            try initialDirectoryTests()
            try await sidebarLayoutTests()
            try sidebarMotionTests()
            try themeTests()
            try inputLayoutTests()
            try await inputFocusRaceTests()
            try windowChromeTests()
            try filterRenderingTests()
            try logGroupingTests()
            try await settingsLayoutTests()
            try await aboutAndMenuBarTests()
            try await detailInteractionTests()
            try await inputScrollGutterTests()
            try await logScrollTests()
            try await inputColorTransitionTests()
            try await listFocusTests()
            try await selectionFocusTests()
            try await blankCanvasFocusTests()
            print("PASS: links, metadata, naming, PDF validation, collisions, retries, pacing, cancellation and queue state")
            if CommandLine.arguments.contains("--stress") {
                try await resourceTests(root: root, pdf: pdf)
                try workspaceBenchmark(root: root)
            }
            if CommandLine.arguments.contains("--snapshots") { try renderSnapshots() }
            if CommandLine.arguments.contains("--live") { try await liveTests() }
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func parseTests() throws {
        let examples: [(String, String)] = [
            ("https://arxiv.org/abs/2501.12345", "2501.12345"),
            ("https://arxiv.org/pdf/2501.12345v2.pdf?download=1#page=2", "2501.12345v2"),
            ("https://arxiv.org/html/2501.12345v2", "2501.12345v2"),
            ("arXiv:2501.12345v2", "2501.12345v2"),
            ("arxiv.org/abs/2501.12345", "2501.12345"),
            ("http://export.arxiv.org/abs/hep-th/9901001v1", "hep-th/9901001v1"),
            ("https://arxiv.org/pdf/math.GT/0301001.pdf", "math.GT/0301001"),
            ("<https://arxiv.org/abs/2501.12345>", "2501.12345")
        ]
        for (input, id) in examples { try expect(try ArxivReference.parse(input).identifier == id, "parse \(input)") }
        for bad in ["https://arxiv.org.evil/abs/2501.12345", "file:///etc/passwd", "https://user@arxiv.org/abs/2501.12345", "https://arxiv.org:9000/abs/2501.12345", "2513.12345", "2500.12345", "2501.12345v0", "2501.12345/../../file", "https://example.com/pdf/2501.12345", "random"] {
            try rejects({ _ = try ArxivReference.parse(bad) }, "accepted invalid link \(bad)")
        }
        let tokens = ArxivReference.tokens(in: "2501.12345\n2501.12345v2；2501.12345, 2501.12345")
        try expect(tokens.count == 4, "batch splitting")
        try expect(Set(try tokens.map(ArxivReference.parse)).count == 2, "input duplicate normalization")
        let editText = "prefix-bad-link\nhttps://example.com/bad-link；bad-link"
        let range = DownloaderView.inputRange(of: "bad-link", in: editText)
        try expect(range?.location == (editText as NSString).length - 8, "edit selects whole input token")
        try expect(DownloaderView.inputRange(of: "missing", in: editText) == nil, "stale edit target not selected")
    }

    static func metadataTests() throws {
        let ref = try ArxivReference.parse("2501.12345")
        let paper = try AtomParser.metadata(atom(), requested: ref)
        try expect(paper.title == "Test & Example: A Paper", "XML entity decoding")
        try expect(paper.reference.identifier == "2501.12345v2", "latest version pinned")
        try expect(paper.filename == "[arXiv2025.1][Test & Example- A Paper].pdf", "first submission date and naming")
        try expect(paper.filename(style: .identifierTitle) == "[2501.12345v2][Test & Example- A Paper].pdf", "identifier naming includes exact version")
        try expect(paper.filename(style: .titleOnly) == "Test & Example- A Paper.pdf", "title-only naming")
        try rejects({ _ = try AtomParser.metadata(atom(), requested: ArxivReference.parse("2501.12345v1")) }, "wrong version accepted")
        try rejects({ _ = try AtomParser.metadata(atom(id: "2501.99999v2"), requested: ref) }, "wrong paper accepted")
        try rejects({ _ = try AtomParser.metadata(atom(published: "bad"), requested: ref) }, "bad date accepted")
        try rejects({ _ = try AtomParser.metadata(Data("<feed>".utf8), requested: ref) }, "malformed XML accepted")
        let long = PaperMetadata(reference: paper.reference, title: String(repeating: "论文🙂", count: 200), year: 2025, month: 1)
        try expect(long.filename.utf8.count <= 250 && long.filename.hasSuffix("].pdf"), "UTF-8 filename bound")
        try expect(long.filename(suffix: "[2501.12345v2-12]").utf8.count <= 250, "suffix filename bound")
        for style in NamingStyle.allCases {
            try expect(long.filename(style: style, suffix: "[2501.12345v2-12]").utf8.count <= 250, "all styles bound long UTF-8 names")
        }
        try expect(!PaperMetadata.cleanTitle("../A/B:C\\D\nE").contains("/"), "path characters")
        try expect(DownloadEngine.retryAfter("3") == 3, "Retry-After seconds")
        try expect(DownloadEngine.retryAfter("Thu, 01 Jan 1970 00:00:00 GMT") == 0, "Retry-After HTTP date")
        try expect(DownloadEngine.retryAfter("NaN") == nil, "nonfinite Retry-After")
    }

    static func securityTests(root: URL) throws {
        for value in ["1e100", "NaN", "Inf", "-1", "1.5", String(repeating: "9", count: 200), "31536001"] {
            try expect(DownloadEngine.retryAfter(value) == nil, "unsafe Retry-After rejected: \(value.prefix(20))")
        }
        try expect(DownloadError.cooldown(1e100).localizedDescription.contains("暂停"), "cooldown description cannot overflow")
        let ref = try ArxivReference.parse("2501.12345")
        let dtd = Data("<!DOCTYPE feed [<!ENTITY x 'expanded'>]><feed/>".utf8)
        try rejects({ _ = try AtomParser.metadata(dtd, requested: ref) }, "DOCTYPE accepted")
        try rejects({ _ = try AtomParser.metadata("<!DOCTYPE feed><feed/>".data(using: .utf16)!, requested: ref) }, "UTF16 XML accepted")
        let nonUTF8 = "<!DOCTYPE feed>" + String(data: atom(), encoding: .utf8)!.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            try rejects({ _ = try AtomParser.metadata(nonUTF8.data(using: encoding)!, requested: ref) }, "UTF16 without BOM accepted")
        }
        let shiftedBody = "<!DOCTYPE feed [<!ENTITY x 'expanded'>]><feed xmlns='http://www.w3.org/2005/Atom'><entry><id>http://arxiv.org/abs/2501.12345v1</id><title>Literal &x;</title><published>2025-01-01T00:00:00Z</published></entry></feed>"
        let shifted = "+" + shiftedBody.data(using: .utf16BigEndian)!.base64EncodedString().replacingOccurrences(of: "=", with: "") + "-"
        let utf7 = "<?xml version='1.0' encoding='UTF-7'?>" + shifted
        try rejects({ _ = try AtomParser.metadata(Data(utf7.utf8), requested: ref) }, "UTF7 declared XML accepted")
        let latin = String(data: atom(), encoding: .utf8)!.replacingOccurrences(of: "UTF-8", with: "ISO-8859-1")
        try rejects({ _ = try AtomParser.metadata(Data(latin.utf8), requested: ref) }, "non UTF8 declaration accepted")
        try rejects({ _ = try AtomParser.metadata(Data(repeating: 32, count: ResourceLimits.metadataBytes + 1), requested: ref) }, "oversized metadata accepted")
        try rejects({ _ = try AtomParser.metadata(atom(title: String(repeating: "A", count: ResourceLimits.titleCharacters + 1)), requested: ref) }, "oversized title accepted")
        try rejects({ _ = try ArxivReference.parse(String(repeating: "a", count: 150) + "/9901001") }, "unbounded identifier accepted")
        for url in ["http://arxiv.org/pdf/2501.12345", "https://evil.arxiv.org/pdf/a", "https://arxiv.org.evil/pdf/a", "https://127.0.0.1/a", "file:///tmp/a", "https://user@arxiv.org/a", "https://arxiv.org:444/a"] {
            try expect(!NetworkPolicy.allows(URL(string: url)), "unsafe download destination accepted")
        }
        try expect(NetworkPolicy.allows(URL(string: "https://export.arxiv.org/api/query")), "official HTTPS destination rejected")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://arxiv.org/pdf/2501.12345")!)
        let observer = ProgressObserver(limit: 1024)
        observer.urlSession(session, downloadTask: task, didWriteData: 1025, totalBytesWritten: 1025, totalBytesExpectedToWrite: -1)
        if case .limit? = observer.failure { } else { throw TestFailure.failed("streaming limit did not report clear error") }
        for (path, mime, limited) in [("/download", "application/pdf", true), ("/download", "application/octet-stream", true),
                                      ("/download", "video/mp4", false), ("/download", "image/png", false),
                                      ("/video.mp4", "application/octet-stream", false), ("/video.mp4", "application/pdf", true)] {
            let response = HTTPURLResponse(url: URL(string: "https://example.org" + path)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!
            let task = ResponseDownloadTask(response)
            let observer = ProgressObserver(limit: FileStorage.byteLimit, policy: .externalPDF)
            observer.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: ResourceLimits.pdfBytes + 1, totalBytesExpectedToWrite: -1)
            try expect((observer.failure != nil) == limited, "production streaming policy keeps PDF/unknown at 256 MB and recognizes declared media: \(path) \(mime)")
            try expect(task.cancelled == limited, "streaming limit cancels only rejected responses")
            observer.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: FileStorage.byteLimit + 1, totalBytesExpectedToWrite: -1)
            try expect(observer.failure != nil && task.cancelled, "all media retains the 16 GB streaming maximum")
        }
        let redirect = ProgressObserver()
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var allowed = true
        redirect.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { allowed = $0 != nil }
        try expect(!allowed, "cross-domain redirect followed")
        if case .unsafeResponse? = redirect.failure { } else { throw TestFailure.failed("redirect rejection lost") }
        let sparse = root.appendingPathComponent("oversized.pdf")
        _ = FileManager.default.createFile(atPath: sparse.path, contents: Data("%PDF-".utf8))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(ResourceLimits.pdfBytes + 1))
        try handle.close()
        do { _ = try PaperStorage.validatePDF(at: sparse); throw TestFailure.failed("oversized PDF accepted") }
        catch DownloadError.limit { }
        try rejects({ _ = try PaperStorage.hash(at: sparse) }, "oversized existing file hashed")
        let fifo = root.appendingPathComponent("blocked.pdf")
        try expect(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture creation")
        try rejects({ _ = try PaperStorage.hash(at: fifo) }, "FIFO blocked file comparison")
        try rejects({ _ = try PaperStorage.validatePDF(at: fifo) }, "FIFO accepted as PDF")
        let link = root.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sparse)
        try rejects({ _ = try PaperStorage.hash(at: link) }, "symlink followed for comparison")
    }

    static func storageTests(root: URL, pdf: URL) throws {
        let output = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let metadata = try AtomParser.metadata(atom(), requested: ArxivReference.parse("2501.12345"))
        try expect(try PaperStorage.validatePDF(at: pdf) == 1, "PDFKit page validation")
        let first = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: output)
        try expect(!first.alreadyExisted, "first save")
        let second = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: output)
        try expect(second.alreadyExisted && second.url == first.url, "same content not duplicated")
        let caseFolder = root.appendingPathComponent("case-reuse", isDirectory: true)
        try FileManager.default.createDirectory(at: caseFolder, withIntermediateDirectories: true)
        let originalCase = caseFolder.appendingPathComponent(metadata.filename.replacingOccurrences(of: "arXiv", with: "ArXiv"))
        try FileManager.default.copyItem(at: pdf, to: originalCase)
        if FileManager.default.fileExists(atPath: caseFolder.appendingPathComponent(metadata.filename).path) {
            let caseReuse = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: caseFolder)
            try expect(caseReuse.alreadyExisted && caseReuse.url.lastPathComponent == originalCase.lastPathComponent, "existing filename keeps actual letter case")
        }
        let other = root.appendingPathComponent("other.pdf")
        try createPDF(at: other, shade: 0.1)
        let originalHash = try PaperStorage.hash(at: first.url)
        let collision = try PaperStorage.save(downloaded: other, metadata: metadata, directory: output)
        try expect(collision.url != first.url && collision.url.lastPathComponent.contains("2501.12345v2"), "different content preserved separately")
        try expect(try PaperStorage.hash(at: first.url) == originalHash, "original file not overwritten")
        let titleOnly = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: output, naming: .titleOnly)
        let titleCollision = try PaperStorage.save(downloaded: other, metadata: metadata, directory: output, naming: .titleOnly)
        try expect(titleOnly.url.lastPathComponent == "Test & Example- A Paper.pdf" && titleCollision.url.lastPathComponent.contains("2501.12345v2"), "title-only collisions retain both files")
        let html = root.appendingPathComponent("error.pdf")
        try Data("<html>Error page</html>".utf8).write(to: html)
        try rejects({ _ = try PaperStorage.save(downloaded: html, metadata: metadata, directory: output) }, "HTML file saved")
        let truncated = root.appendingPathComponent("truncated.pdf")
        try Data(contentsOf: pdf).prefix(100).write(to: truncated)
        try rejects({ _ = try PaperStorage.validatePDF(at: truncated) }, "truncated PDF accepted")
        try rejects({ _ = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: root.appendingPathComponent("missing")) }, "missing folder accepted")
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(files.count == 4 && !files.contains(where: { $0.hasSuffix(".partial") }), "staged file cleanup")
    }

    static func filenameStorageTests(root: URL, pdf: URL) throws {
        let output = root.appendingPathComponent("filename-boundaries", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ref = try ArxivReference.parse("2501.12345v2")
        let titles = [
            "../A/B:C\\D?E*F\"G<H>I|J", "\0\n\t\r", "...   ",
            "  中文标题：保留标点与 α / β  ", "Cafe\u{301}", "Café",
            "研究 👩‍💻 👨‍👩‍👧‍👦 🏳️‍🌈", "safe\u{202E}fdp\u{2066}name\u{2069}",
            String(repeating: "中文é🙂", count: 300),
            String(repeating: "e\u{301}", count: 500),
            "a" + String(repeating: "\u{301}", count: 500),
            String(repeating: "👨‍👩‍👧‍👦", count: 100),
            "trailing...   ", "100% # & + [paper].pdf", "a\u{200C}b"
        ]
        try expect(PaperMetadata.cleanTitle("\0 . \n\t") == "Untitled", "empty sanitized title fallback")
        try expect(PaperMetadata.cleanTitle("Cafe\u{301}") == "Café", "canonical Unicode normalization")
        try expect(PaperMetadata.cleanTitle("研究 👩‍💻 👨‍👩‍👧‍👦 🏳️‍🌈") == "研究 👩‍💻 👨‍👩‍👧‍👦 🏳️‍🌈", "compound emoji preserved")
        for title in titles {
            let metadata = PaperMetadata(reference: ref, title: title, year: 2025, month: 1)
            for style in NamingStyle.allCases {
                for suffix in ["", "[2501.12345v2-999]"] {
                    let filename = metadata.filename(style: style, suffix: suffix)
                    try expect(filename.utf8.count <= 250 && filename.hasSuffix(".pdf"), "bounded filename keeps PDF extension")
                    try expect(!filename.contains("/") && !filename.contains("\\") && !filename.contains("\0") && !filename.contains("\u{202E}"), "unsafe filename characters removed")
                }
                let saved = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: output, naming: style)
                try expect(saved.url.deletingLastPathComponent().standardizedFileURL == output.standardizedFileURL, "filename cannot escape selected folder")
                try expect(try PaperStorage.validatePDF(at: saved.url) == 1, "Unicode filename actually saves a readable PDF")
            }
        }
        let denied = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        if !FileManager.default.isWritableFile(atPath: denied.path) {
            let metadata = PaperMetadata(reference: ref, title: "Denied", year: 2025, month: 1)
            try rejects({ _ = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: denied) }, "read-only destination must fail safely")
            try expect(try FileManager.default.contentsOfDirectory(atPath: denied.path).isEmpty, "failed save leaves no partial file")
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasSuffix(".partial") }, "boundary saves leave no partial files")
        print("PASS filename storage: actual saves in 3 naming styles, punctuation, controls, Unicode, compound emoji, length and permissions")
    }

    static func networkTests(root: URL, pdf: URL) async throws {
        let output = root.appendingPathComponent("network", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ref = try ArxivReference.parse("2501.12345")
        let transient = MockTransport(sourcePDF: pdf, metadata: [.status(503), .status(200)], pdf: [.corrupt, .status(200)])
        let engine = DownloadEngine(transport: transient, requestInterval: 0.03, retryDelay: 0)
        _ = try await engine.download(ref, to: output)
        let counts = await (transient.metadataCalls, transient.pdfCalls)
        try expect(counts.0 == 2 && counts.1 == 2, "metadata and corrupt PDF retries")
        let urls = await transient.pdfURLs
        try expect(urls.allSatisfy { $0.absoluteString == "https://arxiv.org/pdf/2501.12345v2" }, "version-specific PDF requests")
        let times = await transient.times
        try expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 0.025 }, "request pacing")
        let temporary = await transient.tempFiles
        try expect(temporary.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "temporary downloads cleaned")

        let permanent = MockTransport(sourcePDF: pdf, metadata: [.status(404)])
        do { _ = try await DownloadEngine(transport: permanent, requestInterval: 0, retryDelay: 0).download(ref, to: output); throw TestFailure.failed("404 succeeded") }
        catch is DownloadError { }
        try expect(await permanent.metadataCalls == 1, "permanent error retried")
        try expect(await permanent.pdfCalls == 0, "404 downloaded PDF")

        let limited = MockTransport(sourcePDF: pdf, metadata: [.status(429, "0"), .status(200)])
        _ = try await DownloadEngine(transport: limited, requestInterval: 0, retryDelay: 0, rateLimitDelay: 0).download(ref, to: output)
        try expect(await limited.metadataCalls == 2, "429 retry")

        let longPause = MockTransport(sourcePDF: pdf, metadata: [.status(429, "600")])
        let longPauseEngine = DownloadEngine(transport: longPause, requestInterval: 0, retryDelay: 0)
        for _ in 0..<3 {
            do { _ = try await longPauseEngine.download(ref, to: output); throw TestFailure.failed("long pause ignored") }
            catch DownloadError.cooldown(let remaining) { try expect(remaining > 590, "cooldown lost") }
        }
        try expect(await longPause.metadataCalls == 1, "long Retry-After must not be shortened")
        let shortPause = MockTransport(sourcePDF: pdf, metadata: [.status(429, "1"), .status(200)])
        _ = try await DownloadEngine(transport: shortPause, requestInterval: 0, retryDelay: 0, rateLimitDelay: 0).download(ref, to: output)
        let shortTimes = await shortPause.times
        try expect(shortTimes[1].timeIntervalSince(shortTimes[0]) >= 0.95, "short Retry-After observed")

        let fallback = MockTransport(sourcePDF: pdf, metadata: [.status(429), .status(429, "broken"), .status(200)])
        _ = try await DownloadEngine(transport: fallback, requestInterval: 0, retryDelay: 0, rateLimitDelay: 0.03).download(ref, to: output)
        let fallbackTimes = await fallback.times
        try expect(fallbackTimes[1].timeIntervalSince(fallbackTimes[0]) >= 0.025 && fallbackTimes[2].timeIntervalSince(fallbackTimes[1]) >= 0.055, "missing/invalid Retry-After uses increasing backoff")

        let zeroWait = MockTransport(sourcePDF: pdf, metadata: [.status(429, "0"), .status(429, "0"), .status(200)])
        _ = try await DownloadEngine(transport: zeroWait, requestInterval: 0, retryDelay: 0, rateLimitDelay: 0.03).download(ref, to: output)
        let zeroTimes = await zeroWait.times
        try expect(zeroTimes[2].timeIntervalSince(zeroTimes[1]) >= 0.055, "repeated short Retry-After cannot flatten backoff")

        let noHeader = MockTransport(sourcePDF: pdf, metadata: [.status(429)])
        let noHeaderEngine = DownloadEngine(transport: noHeader, requestInterval: 0, retryDelay: 0)
        let waitingJob = Task { try await noHeaderEngine.download(ref, to: output) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(await noHeader.metadataCalls == 1, "default 429 without header does not immediately retry")
        waitingJob.cancel()
        do { _ = try await waitingJob.value; throw TestFailure.failed("rate-limit wait ignored cancellation") }
        catch is CancellationError { }
        let manualRetry = Task { try await noHeaderEngine.download(ref, to: output) }
        try await Task.sleep(nanoseconds: 30_000_000)
        manualRetry.cancel()
        do { _ = try await manualRetry.value; throw TestFailure.failed("manual retry ignored shared cooldown") }
        catch is CancellationError { }
        try expect(await noHeader.metadataCalls == 1, "manual retry cannot bypass cooldown")

        let cooldownSuite = "arxiv-cooldown-test-\(UUID().uuidString)"
        let cooldownPrefs = UserDefaults(suiteName: cooldownSuite)!
        defer { cooldownPrefs.removePersistentDomain(forName: cooldownSuite) }
        let persisted = MockTransport(sourcePDF: pdf, metadata: [.status(429, "600")])
        let persistedEngine = DownloadEngine(transport: persisted, requestInterval: 0, retryDelay: 0, cooldownPreferences: cooldownPrefs)
        do { _ = try await persistedEngine.download(ref, to: output); throw TestFailure.failed("persistent cooldown ignored") }
        catch DownloadError.cooldown { }
        let restarted = DownloadEngine(transport: persisted, requestInterval: 0, retryDelay: 0, cooldownPreferences: cooldownPrefs)
        do { _ = try await restarted.download(ref, to: output); throw TestFailure.failed("restart lost cooldown") }
        catch DownloadError.cooldown(let remaining) { try expect(remaining > 590, "restored cooldown shortened") }
        try expect(await persisted.metadataCalls == 1, "restart does not request during persisted cooldown")

        let exhausted = MockTransport(sourcePDF: pdf, metadata: [.network(.timedOut)])
        do { _ = try await DownloadEngine(transport: exhausted, requestInterval: 0, retryDelay: 0).download(ref, to: output); throw TestFailure.failed("network failure succeeded") }
        catch is URLError { }
        try expect(await exhausted.metadataCalls == 3, "bounded retries")
        let rejected = MockTransport(sourcePDF: pdf, metadata: [.failure(.limit("limit")), .status(200)])
        let rejectedEngine = DownloadEngine(transport: rejected, requestInterval: 0, retryDelay: 0)
        do { _ = try await rejectedEngine.download(ref, to: output); throw TestFailure.failed("limit accepted") }
        catch DownloadError.limit { }
        _ = try await rejectedEngine.download(ref, to: output)
        try expect(await rejected.metadataCalls == 2, "limit does not retry or cancel later jobs")

        let cancelled = MockTransport(sourcePDF: pdf, delay: 5_000_000_000)
        let job = Task { try await DownloadEngine(transport: cancelled, requestInterval: 0, retryDelay: 0).download(ref, to: output) }
        try await Task.sleep(nanoseconds: 30_000_000)
        job.cancel()
        do { _ = try await job.value; throw TestFailure.failed("cancel succeeded") }
        catch is CancellationError { }
        try expect(await cancelled.pdfCalls == 0, "cancelled job downloaded PDF")
    }

    @MainActor static func queueTests(root: URL, pdf: URL) async throws {
        let suiteName = "arxiv-test-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let output = root.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let transport = MockTransport(sourcePDF: pdf, metadata: [.status(404), .status(200)])
        let model = DownloadModel(engine: DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        model.directory = output
        model.input = "kept"
        model.input = String(repeating: "x", count: ResourceLimits.inputBytes + 1)
        try expect(model.input == "kept" && model.notice != nil, "oversized input rejected")
        model.input = Array(repeating: "bad", count: ResourceLimits.batchCount + 1).joined(separator: "\n")
        model.start()
        try expect(model.items.isEmpty && !model.busy && model.notice != nil, "oversized batch rejected without rows")
        model.input = "2501.12345\nhttps://arxiv.org/pdf/2501.12345\nbad-link\n2501.12345v2"
        model.start()
        try expect(model.items.count == 3 && model.duplicateCount == 1, "queue duplicate normalization")
        try expect(model.busy, "queue running")
        model.start()
        try expect(model.items.count == 3, "double start changed active queue")
        try await waitForQueue(model)
        try expect(model.successes == 1 && model.failures == 2 && model.canRetry, "permanent failure prevented later success")
        try expect(ArxivReference.tokens(in: model.input) == ["2501.12345", "https://arxiv.org/pdf/2501.12345", "bad-link"], "failed and invalid inputs retained; only saved version removed")
        model.retry()
        try await waitForQueue(model)
        try expect(model.successes == 2 && model.failures == 1, "retry did not preserve successful or invalid items")
        try expect(model.input == "bad-link", "successful retry clears all equivalent input links")
        try expect(model.items[0].savedURL == model.items[2].savedURL, "queue duplicate file reused")
        try expect(preferences.string(forKey: "downloadRootDirectory") == output.path, "directory preference")
        model.naming = .identifierTitle
        model.appearance = .dark
        model.theme = .iris
        let restored = DownloadModel(preferences: preferences)
        try expect(restored.directory == output && restored.naming == .identifierTitle && restored.appearance == .dark && restored.theme == .iris, "settings restored")
        try expect(restored.namingExample.contains("1706.03762v1"), "live naming example")
        model.appearance = .system
        let opening = DownloadModel(preferences: preferences, opener: { _ in false })
        opening.items = [model.items[0]]
        opening.openFile(opening.items[0])
        try expect(opening.notice != nil && opening.items[0].state == model.items[0].state, "opener failure feedback preserves file")
        opening.items[0].savedURL = root.appendingPathComponent("deleted.pdf")
        opening.openFile(opening.items[0])
        try expect(opening.items[0].state == .missing && opening.items[0].savedURL == nil && opening.items[0].canRetry, "deleted file feedback and retry")
        opening.directory = root.appendingPathComponent("deleted-directory")
        opening.openDirectory()
        try expect(opening.directoryNotice != nil, "deleted directory feedback")
        let successfulOpen = DownloadModel(preferences: preferences, opener: { _ in true })
        successfulOpen.directory = output
        successfulOpen.directoryNotice = "old folder error"
        successfulOpen.openDirectory()
        successfulOpen.notice = "old source error"
        successfulOpen.openSource(model.items[0])
        try expect(successfulOpen.directoryNotice == nil && successfulOpen.notice == nil, "successful opens clear obsolete errors")

        let slow = MockTransport(sourcePDF: pdf, delay: 5_000_000_000)
        let cancellation = DownloadModel(engine: DownloadEngine(transport: slow, requestInterval: 0, retryDelay: 0), preferences: preferences)
        cancellation.directory = output
        cancellation.input = "2501.12345\n2501.12345v2"
        cancellation.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        cancellation.cancel()
        try expect(cancellation.cancelling, "immediate cancellation feedback")
        await cancellation.cancelAndWait()
        try expect(!cancellation.busy && !cancellation.cancelling, "cleanup awaited before exit")
        try expect(cancellation.items.allSatisfy { $0.state == .cancelled } && cancellation.canRetry, "queued cancellation states")
        try expect(cancellation.input == "2501.12345\n2501.12345v2", "cancelled and queued inputs retained")

        let frozenTransport = MockTransport(sourcePDF: pdf, delay: 50_000_000)
        let frozen = DownloadModel(engine: DownloadEngine(transport: frozenTransport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        frozen.directory = output
        frozen.naming = .identifierTitle
        frozen.input = "2501.12345v2"
        frozen.start()
        let runningItem = frozen.items[0].id
        frozen.theme = .midnight
        try expect(frozen.busy && frozen.items[0].id == runningItem && frozen.theme == .midnight, "changing theme preserves running queue")
        frozen.naming = .titleOnly
        frozen.directory = root.appendingPathComponent("another-folder")
        try await waitForQueue(frozen)
        try expect(frozen.items[0].savedURL?.deletingLastPathComponent() == output.appendingPathComponent("Papers", isDirectory: true) && frozen.items[0].savedURL?.lastPathComponent.hasPrefix("[2501.12345v2]") == true, "active batch freezes directory and naming")
        try expect(frozen.input.isEmpty, "all successful inputs cleared")
        let completedItem = frozen.items[0].id
        frozen.start()
        try expect(frozen.items.count == 1 && frozen.items[0].id == completedItem && frozen.successes == 1, "empty start preserves completed results")

        model.directory = root.appendingPathComponent("blocked-folder", isDirectory: true)
        try Data("blocked".utf8).write(to: model.directory)
        model.input = "2501.12345"
        model.start()
        try await waitForQueue(model)
        try expect(!model.busy && model.items.first?.state == .failed && model.items.first?.error?.contains("Papers") == true, "blocked root identifies affected folder")
        try expect(model.input == "2501.12345", "unwritable destination preserves input")

        let throttled = MockTransport(sourcePDF: pdf, metadata: [.status(429, "600"), .status(200)])
        let paused = DownloadModel(engine: DownloadEngine(transport: throttled, requestInterval: 0, retryDelay: 0), preferences: preferences)
        paused.directory = output
        paused.input = "2501.12345\n2501.12345v2"
        paused.start()
        try await waitForQueue(paused)
        try expect(paused.items.map(\.state) == [.paused, .paused] && paused.retryCount == 2, "rate-limit exhaustion pauses the entire queue")
        try expect(paused.input == "2501.12345\n2501.12345v2" && paused.summary.contains("2 项待重试") && paused.items[0].error?.contains("后重试") == true, "paused queue preserves inputs and gives a resume time")
        paused.retry()
        try await waitForQueue(paused)
        let pausedCalls = await (throttled.metadataCalls, throttled.pdfCalls)
        try expect(pausedCalls.0 == 1 && pausedCalls.1 == 0, "batch retry cannot bypass cooldown")
        try expect(paused.items.allSatisfy { $0.state == .paused } && paused.failures == 0, "retry during cooldown does not turn paused items into failures")

        let waitTransport = MockTransport(sourcePDF: pdf, metadata: [.status(429, "0")])
        let waiting = DownloadModel(engine: DownloadEngine(transport: waitTransport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        waiting.directory = output
        waiting.input = "2501.12345"
        waiting.start()
        for _ in 0..<100 {
            if case .waiting = waiting.items.first?.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .waiting(let deadline) = waiting.items.first?.state else { throw TestFailure.failed("rate-limit wait not visible in UI") }
        try expect(deadline.timeIntervalSinceNow > 58 && waiting.busy && waiting.items[0].state.label.contains("后继续"), "Retry-After zero still uses the safe default wait")
        await waiting.cancelAndWait()
        try expect(waiting.input == "2501.12345" && waiting.items[0].state == .cancelled && !waiting.busy, "visible rate-limit waiting remains cancellable")
    }

    static func existingFileTests(root: URL, pdf: URL) async throws {
        let output = root.appendingPathComponent("existing-fast-path", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ref = try ArxivReference.parse("2501.12345")
        let metadata = try AtomParser.metadata(atom(), requested: ref)
        let transport = MockTransport(sourcePDF: pdf)
        let engine = DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0)
        let first = try await engine.download(ref, to: output)
        let second = try await engine.download(ref, to: output)
        try expect(!first.alreadyExisted && second.alreadyExisted && first.url == second.url, "trusted local PDF reused")
        let calls = await (transport.metadataCalls, transport.pdfCalls)
        try expect(calls.0 == 2 && calls.1 == 1, "reuse resolves current metadata without downloading PDF again")
        let older = PaperMetadata(reference: try ArxivReference.parse("2501.12345v1"), title: metadata.title, year: metadata.year, month: metadata.month)
        try expect(try PaperStorage.existing(metadata: older, directory: output, naming: .dateTitle) == nil, "different source version is not reused")

        let attribute = "local.paperrepo.arxiv-downloader.source"
        _ = removexattr(first.url.path, attribute, 0)
        try expect(try PaperStorage.existing(metadata: metadata, directory: output, naming: .dateTitle) == nil, "untracked local file not trusted by filename")
        _ = try await engine.download(ref, to: output)
        _ = try await engine.download(ref, to: output)
        try expect(await transport.pdfCalls == 2, "legacy file verified once then reused")

        for data in [Data("not-json".utf8), Data(repeating: 65, count: 2048), try JSONSerialization.data(withJSONObject: ["schema": 999, "identifier": metadata.reference.identifier, "sha256": "bad"])] {
            let result = data.withUnsafeBytes { setxattr(first.url.path, attribute, $0.baseAddress, data.count, 0, 0) }
            try expect(result == 0, "source attribute fixture written")
            try expect(try PaperStorage.existing(metadata: metadata, directory: output, naming: .dateTitle) == nil, "malformed or unsupported source record falls back")
        }
        _ = try await engine.download(ref, to: output)
        try createPDF(at: first.url, shade: 0.2)
        try expect(try PaperStorage.existing(metadata: metadata, directory: output, naming: .dateTitle) == nil, "modified PDF invalidates content fingerprint")
        let restored = try await engine.download(ref, to: output)
        try expect(restored.url != first.url && !restored.alreadyExisted, "modified original preserved beside new verified file")
        _ = try await engine.download(ref, to: output)
        try expect(await transport.pdfCalls == 4, "collision suffix PDF reused without another download")
        let gap = root.appendingPathComponent("existing-collision-gap", isDirectory: true)
        try FileManager.default.createDirectory(at: gap, withIntermediateDirectories: true)
        for suffix in ["", "[2501.12345v2]"] {
            try Data("unrelated original".utf8).write(to: gap.appendingPathComponent(metadata.filename(suffix: suffix)))
        }
        let afterCollision = try PaperStorage.save(downloaded: pdf, metadata: metadata, directory: gap)
        try FileManager.default.removeItem(at: gap.appendingPathComponent(metadata.filename(suffix: "[2501.12345v2]")))
        try expect(try PaperStorage.existing(metadata: metadata, directory: gap, naming: .dateTitle)?.url == afterCollision.url, "deleted earlier collision does not hide a later trusted PDF")

        let linked = root.appendingPathComponent("existing-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(metadata.filename), withDestinationURL: restored.url)
        try expect(try PaperStorage.existing(metadata: metadata, directory: linked, naming: .dateTitle) == nil, "source lookup rejects symbolic links")
        let disk = MockTransport(sourcePDF: pdf, pdf: [.network(.cannotWriteToFile)])
        do { _ = try await DownloadEngine(transport: disk, requestInterval: 0, retryDelay: 0).download(ref, to: linked); throw TestFailure.failed("disk failure succeeded") }
        catch let error as URLError { try expect(error.code == .cannotWriteToFile, "disk write failure retained") }
        try expect(await disk.pdfCalls == 1, "disk write failure does not trigger repeated downloads")
        print("PASS existing files: no PDF re-download, exact version, legacy verification, malformed records, modified files, collision suffixes, symlinks and disk errors")
    }

    @MainActor static func completedInputTests(root: URL, pdf: URL) async throws {
        let suiteName = "arxiv-completed-input-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let output = root.appendingPathComponent("completed-input", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let transport = MockTransport(sourcePDF: pdf, delay: 150_000_000)
        let model = DownloadModel(engine: DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0), preferences: preferences)
        model.directory = output
        model.input = "https://arxiv.org/abs/2501.12345; https://arxiv.org/html/2501.12345\n2501.12345v2，bad-link"
        model.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while model.successes == 0 {
            if ContinuousClock().now > deadline { throw TestFailure.failed("first completed input timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(model.busy && ArxivReference.tokens(in: model.input) == ["2501.12345v2", "bad-link"], "clear per paper while running; preserve distinct requested versions")
        try await waitForQueue(model)
        try expect(model.input == "bad-link" && model.successes == 2 && model.failures == 1, "retain result rows and invalid input")
        try expect(model.items[1].state == .existing, "validated existing file also clears input")

        let corruptFolder = root.appendingPathComponent("completed-input-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corrupt = MockTransport(sourcePDF: pdf, pdf: [.corrupt])
        let rejected = DownloadModel(engine: DownloadEngine(transport: corrupt, requestInterval: 0, retryDelay: 0), preferences: preferences)
        rejected.directory = corruptFolder
        rejected.input = "https://arxiv.org/html/2501.12345v2"
        rejected.start()
        try await waitForQueue(rejected)
        try expect(rejected.failures == 1 && rejected.input == "https://arxiv.org/html/2501.12345v2", "PDF validation failure must not clear input")
        print("PASS completed input: incremental clearing, duplicate links, requested versions, existing files, retries, failure and cancellation")
    }

    @MainActor static func restoreVersionTests(root: URL, pdf: URL) async throws {
        let suite = "arxiv-restore-test-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let transport = MockTransport(sourcePDF: pdf, latestVersion: 3)
        let model = DownloadModel(engine: DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0), preferences: prefs)
        let folder = root.appendingPathComponent("restore-version", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.directory = folder
        let original = try ArxivReference.parse("2501.12345")
        let metadata = try AtomParser.metadata(atom(), requested: original)
        model.items = [DownloadItem(original: original.identifier, reference: original, metadata: metadata, state: .saved, savedURL: folder.appendingPathComponent("moved.pdf"))]
        model.openFile(model.items[0])
        model.input = "2501.12345\n2502.00001"
        model.retry(model.items[0].id)
        try await waitForQueue(model)
        try expect(model.items[0].state == .saved && model.items[0].metadata?.reference.identifier == "2501.12345v2", "missing-file restore pins saved v2 even when latest is v3")
        try expect(await transport.pdfURLs.first?.lastPathComponent == "2501.12345v2", "restore requests exact PDF version")
        try expect(model.input == "2501.12345\n2502.00001", "restoring an old version preserves new pending latest-version inputs")

        let retryTransport = MockTransport(sourcePDF: pdf, metadata: [.status(404), .status(200)])
        let retryModel = DownloadModel(engine: DownloadEngine(transport: retryTransport, requestInterval: 0, retryDelay: 0), preferences: prefs)
        retryModel.directory = folder
        retryModel.input = "2501.12345"
        retryModel.start()
        try await waitForQueue(retryModel)
        retryModel.input = "2502.00001"
        retryModel.retry()
        try await waitForQueue(retryModel)
        try expect(retryModel.successes == 1 && retryModel.input == "2502.00001", "retrying an old failure preserves edited pending inputs")
        print("PASS restore: exact version after missing file, edited input preserved during old-item retry")
    }

    @MainActor static func waitForQueue(_ model: DownloadModel) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while model.busy {
            if ContinuousClock().now > deadline { throw TestFailure.failed("queue test timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor static func resourceTests(root: URL, pdf: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suiteName = "arxiv-stress-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let folder = root.appendingPathComponent("stress", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transport = MockTransport(sourcePDF: pdf)
        let engine = DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0)
        for round in 0..<200 {
            var model: DownloadModel? = DownloadModel(engine: engine, preferences: preferences)
            weak var released: DownloadModel?
            released = model
            model!.directory = folder
            model!.input = "2501.12345v2"
            model!.start()
            try await waitForQueue(model!)
            try expect(model!.successes == 1, "stress download failed")
            model = nil
            await Task.yield()
            try expect(released == nil, "completed model retained")
            if (round + 1) % 50 == 0 {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("STRESS \(round + 1)/200: peak RSS \(usage.ru_maxrss / 1024 / 1024) MiB, models released")
            }
        }
        let partials = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
        try expect(partials.isEmpty, "stress left partial files")
        print("PASS stress: 200 completed queues; no retained models or partial files")
    }

    @MainActor static func inputLayoutTests() throws {
        let suiteName = "arxiv-input-layout-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = DownloadModel(preferences: preferences)
        let view = NSHostingView(rootView: DownloaderView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func settle() {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
        func findEditor(_ root: NSView) -> LinkTextView? {
            if let editor = root as? LinkTextView { return editor }
            return root.subviews.lazy.compactMap { findEditor($0) }.first
        }
        settle()
        guard let editor = findEditor(view), let layout = editor.layoutManager, let container = editor.textContainer else { throw TestFailure.failed("native input text layout missing") }
        try expect(editor.frame.width > 500 && editor.frame.height >= (editor.enclosingScrollView?.contentSize.height ?? 62), "input document must fill scroll area")
        let placeholder = editor.placeholderFirstGlyphOrigin
        model.input = LinkTextView.example
        settle()
        try expect(editor.string == model.input, "model-to-editor input sync")
        layout.ensureLayout(for: container)
        let typed = layout.location(forGlyphAt: 0)
        try expect(abs(placeholder.x - typed.x) < 0.1 && abs(placeholder.y - typed.y) < 0.1, "placeholder and typed text must share first glyph baseline and leading inset")
        try expect(editor.textContainerOrigin == NSPoint(x: 7, y: 7), "input content inset")
        guard let delegate = editor.delegate as? LinkInput.Coordinator else { throw TestFailure.failed("input delegate") }
        let accepted = delegate.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: (editor.string as NSString).length), replacementString: String(repeating: "文", count: 30_000))
        try expect(!accepted && model.input == LinkTextView.example && model.notice != nil, "oversized native paste rejected before editing")
        editor.string = "2609.22978\ninvalid-token"
        delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        try expect(model.input == editor.string, "editor-to-model multiline sync")
        model.input = String(repeating: "https://arxiv.org/abs/2609.22978\n", count: 100)
        settle()
        try expect(editor.frame.height > 104 && editor.enclosingScrollView?.contentSize.height == 104, "long input scrolls within the fixed input box")
        model.input = ""
        settle()
        try expect(editor.frame.height == 104, "clearing input restores document height")
        model.busy = true
        settle()
        try expect(!editor.isEditable, "busy input is read-only")
        model.busy = false
        settle()
        try expect(editor.isEditable && editor.allowsUndo && !editor.isAutomaticDashSubstitutionEnabled, "input restores editing and preserves URL punctuation")
        window.makeFirstResponder(editor)
        editor.insertText("2501.12345v2", replacementRange: NSRange(location: 0, length: 0))
        settle()
        try expect(model.input == "2501.12345v2" && editor.undoManager?.canUndo == true, "user edits have native undo")
        model.busy = true
        model.input = ""
        settle()
        try expect(editor.string.isEmpty && editor.undoManager?.canUndo == false, "automatic input cleanup discards undo actions for old text")
        model.busy = false
        settle()
        model.input = "https://arxiv.org/html/2501.12345v2\n2501.12345\nhttps://example.com/paper\nbad-link"
        settle()
        for theme in AppTheme.allCases {
            model.theme = theme
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                editor.styleReferences(textColor: ThemePalette.nativeColor(palette.text), accentColor: ThemePalette.nativeColor(palette.accent), underlineRecognized: theme == .graphite)
                let storage = editor.textStorage!
                for (token, valid) in [("https://arxiv.org/html/2501.12345v2", true), ("2501.12345", true), ("https://example.com/paper", true), ("bad-link", false)] {
                    let range = DownloaderView.inputRange(of: token, in: editor.string)!
                    let attributes = storage.attributes(at: range.location, effectiveRange: nil)
                    try expect((attributes[.foregroundColor] as? NSColor) == ThemePalette.nativeColor(valid ? palette.accent : palette.text), "recognized input uses semantic theme color")
                    try expect((attributes[.underlineStyle] as? Int) == (valid && theme == .graphite ? NSUnderlineStyle.single.rawValue : nil), "graphite recognition consistent in light and dark")
                    try expect(attributes[.link] == nil, "recognized input stays editable text instead of a clickable rich-text link")
                }
            }
        }
        model.input = ""
        settle()
        window.orderOut(nil)
        print("PASS native input: placeholder/typed baseline, document bounds, multiline binding, paste limit and busy state")
    }

    @MainActor static func windowChromeTests() throws {
        let suite = "arxiv-window-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        var chrome: WindowChrome? = WindowChrome(window: window, model: model, title: "arXiv下载器")
        weak var released: WindowChrome?
        released = chrome
        let content = NSHostingView(rootView: DownloaderView(model: model))
        window.contentView = content
        defer { window.orderOut(nil) }
        for width in [820, 960] {
            window.setContentSize(NSSize(width: width, height: 570))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            guard let close = window.standardWindowButton(.closeButton),
                  let title = window.toolbar?.items.compactMap(\.view).first(where: { $0 is NSTextField }) else {
                throw TestFailure.failed("native window controls or toolbar content missing")
            }
            let closeRect = close.convert(close.bounds, to: nil)
            let titleRect = title.convert(title.bounds, to: nil)
            try expect(abs(closeRect.midY - titleRect.midY) <= 4, "window header controls aligned")
            try expect(closeRect.maxX < titleRect.minX, "header items do not overlap at minimum width")
            try expect(window.toolbar?.items.compactMap(\.view).contains(where: { $0 is NSButton }) == false, "toolbar has no redundant settings button")
            try expect(window.styleMask.contains(.titled) && window.styleMask.contains(.fullSizeContentView), "native window behavior retained")
            try expect(window.titleVisibility == .hidden && window.titlebarAppearsTransparent, "system title and separate background removed")
        }
        for theme in AppTheme.allCases {
            model.theme = theme
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                window.appearance = appearance
                var components: [CGFloat] = []
                appearance.performAsCurrentDrawingAppearance {
                    if let color = window.backgroundColor.usingColorSpace(.sRGB) { components = [color.redComponent, color.greenComponent, color.blueComponent] }
                }
                let expected = ThemePalette.nativeColor(theme.palette(dark: dark).canvas)
                try expect(components.count == 3 && abs(components[0] - expected.redComponent) < 0.001 && abs(components[1] - expected.greenComponent) < 0.001 && abs(components[2] - expected.blueComponent) < 0.001, "window background follows theme and appearance")
            }
        }
        chrome = nil
        try expect(released == nil, "theme observation must not retain window chrome")
        let workspaceChrome = WindowChrome(window: window, model: model, title: "arXiv下载器", workspace: true)
        try expect(window.toolbar == nil && window.standardWindowButton(.closeButton) != nil && window.isMovableByWindowBackground, "integrated workspace keeps native controls and window dragging without duplicate title")
        try expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false && window.standardWindowButton(.zoomButton)?.isHidden == false, "main window keeps working minimize and zoom controls")
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let settingsChrome = WindowChrome(window: settings, model: model, title: "设置")
        try expect(settings.standardWindowButton(.closeButton)?.isHidden == false, "settings keeps its close control")
        try expect(settings.standardWindowButton(.miniaturizeButton)?.isHidden != false && settings.standardWindowButton(.zoomButton)?.isHidden != false, "settings hides unavailable minimize and zoom controls")
        withExtendedLifetime(settingsChrome) {}
        withExtendedLifetime(workspaceChrome) {}
        print("PASS window chrome: minimum width, header alignment, 12 theme backgrounds and released observer")
    }

    @MainActor static func renderSnapshots() throws {
        let suiteName = "arxiv-ui-test-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture<V: View>(_ content: V, width: Int, height: Int? = nil, name: String, title: String = "arXiv下载器") throws {
            let view = NSHostingView(rootView: content.environment(\.controlActiveState, .key))
            let size = NSSize(width: CGFloat(width), height: height.map { CGFloat($0) } ?? view.fittingSize.height)
            let style: NSWindow.StyleMask = title == "设置" ? [.titled, .closable] : [.titled, .closable, .miniaturizable, .resizable]
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            let chrome = WindowChrome(window: window, model: model, title: title, workspace: true)
            let headerHeight = window.frame.height - window.contentLayoutRect.height
            window.setContentSize(NSSize(width: size.width, height: size.height + (height == nil ? headerHeight : 0)))
            window.contentView = view
            let rendered = view.superview ?? view
            rendered.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            rendered.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds) else { throw TestFailure.failed("UI bitmap creation") }
            rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure.failed("UI PNG encoding") }
            try data.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
            withExtendedLifetime(chrome) {}
        }
        let model = DownloadModel(preferences: preferences)
        let input = "https://arxiv.org/abs/2609.22978\nhttps://arxiv.org/pdf/1706.03762v1"
        let paper = PaperMetadata(reference: try ArxivReference.parse("2609.22978v1"), title: "DeepSeek Elastic Compute (DSec): A Sandbox Infrastructure for Effective Agentic Training at Scale", year: 2026, month: 9)
        let completedItems = [
            DownloadItem(original: "2609.22978", reference: paper.reference, metadata: paper, state: .saved, savedURL: model.directory.appendingPathComponent(paper.filename), pages: 31),
            DownloadItem(original: "1706.03762v1", reference: try ArxivReference.parse("1706.03762v1"), state: .failed, error: "连接超时，自动重试后仍未成功。请检查网络后重试。")
        ]
        for theme in AppTheme.allCases {
            model.theme = theme
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(theme.rawValue)-\(scheme == .light ? "light" : "dark")"
                app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                for width in [820, 960] {
                    model.input = input
                    model.items = completedItems
                    try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "\(suffix)-\(width)")
                    if width == 960 || theme == .native || theme == .midnight {
                        model.input = ""
                        model.items = []
                        try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "empty-\(suffix)-\(width)")
                    }
                    if theme == .native || theme == .midnight {
                        model.input = input
                        model.busy = true
                        model.items = [
                            DownloadItem(original: "2609.22978", reference: paper.reference, metadata: paper, state: .downloading, progress: DownloadProgress(received: 4_500_000, total: 10_000_000)),
                            DownloadItem(original: "1706.03762v1", reference: try ArxivReference.parse("1706.03762v1"), state: .queued)
                        ]
                        try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "busy-\(suffix)-\(width)")
                        if theme == .midnight && width == 820 {
                            model.cancelling = true
                            try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "cancelling-\(suffix)-\(width)")
                            model.cancelling = false
                        }
                        model.busy = false
                        model.items[0].state = .waiting(Date().addingTimeInterval(60))
                        model.items[0].progress = nil
                        model.busy = true
                        try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "rate-wait-\(suffix)-\(width)")
                        model.items[0].state = .coordinating
                        try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "shared-wait-\(suffix)-\(width)")
                        model.busy = false
                        model.items[0].state = .paused
                        model.items[0].error = "arXiv 要求暂停请求，可在 \(Date().addingTimeInterval(120).formatted(date: .abbreviated, time: .standard)) 后重试。"
                        model.items[1].state = .paused
                        try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: width, height: 700, name: "rate-paused-\(suffix)-\(width)")
                    }
                }
                model.settingsTab = "通用"
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "settings-\(suffix)", title: "设置")
                model.settingsTab = "快捷键"
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "shortcuts-\(suffix)", title: "设置")
                model.settingsTab = "浏览器认证"
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "browser-authentication-\(suffix)", title: "设置")
                model.settingsTab = "通用"
            }
        }
        model.theme = .midnight
        let directory = model.directory
        model.directory = URL(fileURLWithPath: "/Users/Example/Documents/Research/" + String(repeating: "Long directory ", count: 12) + "/Papers")
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for naming in NamingStyle.allCases {
                model.naming = naming
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "settings-long-\(naming.rawValue)-\(scheme == .light ? "light" : "dark")", title: "设置")
            }
            model.busy = true
            try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "settings-busy-\(scheme == .light ? "light" : "dark")", title: "设置")
            model.busy = false
        }
        model.directory = directory
        model.input = "https://arxiv.org/html/2609.22978\n1706.03762v1\nhttps://example.com/paper\ninvalid-link"
        model.items = completedItems
        for theme in [AppTheme.graphite, .lagoon] {
            model.theme = theme
            for scheme in [ColorScheme.light, .dark] {
                app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: 820, height: 600, name: "recognized-\(theme.rawValue)-\(scheme == .light ? "light" : "dark")", title: "arXiv下载器")
            }
        }
        model.input = "https://mirros.ai/report/agent-garten.pdf\nhttps://example.com/download?key=a,b;c\n1706.03762v1"
        model.items = [
            DownloadItem(original: "https://mirros.ai/report/agent-garten.pdf", reference: nil, directURL: URL(string: "https://mirros.ai/report/agent-garten.pdf"), state: .saved, savedURL: model.directory.appendingPathComponent("Agent Garten.pdf"), pages: 32, documentTitle: "Agent Garten"),
            DownloadItem(original: "1706.03762v1", reference: try ArxivReference.parse("1706.03762v1"), state: .queued)
        ]
        model.theme = .lagoon
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: 820, height: 600, name: "generic-pdf-\(scheme == .light ? "light" : "dark")")
            try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "generic-settings-\(scheme == .light ? "light" : "dark")", title: "设置")
        }
        let savedLanguage = model.language
        for language in [AppLanguage.chinese, .english] {
            model.language = language
            for scheme in [ColorScheme.light, .dark] {
                app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                model.busy = true
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "settings-records-\(language.rawValue)-\(scheme == .light ? "light" : "dark")", title: "设置")
                model.busy = false
                model.settingsTab = "浏览器认证"
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "authentication-anonymous-\(language.rawValue)-\(scheme == .light ? "light" : "dark")", title: "设置")
                model.browserAuthentication.select(.chrome)
                model.browserAuthentication.setEnabled(true)
                try capture(SettingsView(model: model).environment(\.colorScheme, scheme), width: 470, name: "authentication-enabled-\(language.rawValue)-\(scheme == .light ? "light" : "dark")", title: "设置")
                model.browserAuthentication.clear()
                model.settingsTab = "通用"
            }
        }
        model.language = savedLanguage
        model.history = completedItems.filter { $0.savedURL != nil }
        model.history.forEach { model.upsertPaper($0) }
        model.record(.info, "开始下载 · 2 项")
        model.record(.warning, "自动重试 1/3", item: completedItems[1])
        model.record(.success, "已保存", item: completedItems[0])
        model.record(.error, "连接超时，自动重试后仍未成功。请检查网络后重试。", item: completedItems[1])
        let mediaFixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        model.mediaLibrary = [
            DownloadItem(original: "https://example.com/video.mp4", directURL: URL(string: "https://example.com/video.mp4"), state: .saved, savedURL: mediaFixtures.appendingPathComponent("video.mp4"), documentTitle: "A quiet afternoon — a longer video title to check line wrapping and action alignment", finishedAt: Date(), mediaFormat: .automatic),
            DownloadItem(original: "https://example.com/audio.m4a", directURL: URL(string: "https://example.com/audio.m4a"), state: .saved, savedURL: mediaFixtures.appendingPathComponent("tone.m4a"), documentTitle: "声音片段", finishedAt: Date().addingTimeInterval(-1), mediaFormat: .audio)
        ]
        for scheme in [ColorScheme.light, .dark] {
            model.theme = .native
            app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for page in [WorkspacePage.library, .media, .logs] {
                try capture(DownloaderView(model: model, page: page).environment(\.colorScheme, scheme), width: 960, height: 700, name: "workspace-\(page)-\(scheme == .light ? "light" : "dark")")
            }
            let palette = model.theme.palette(dark: scheme == .dark)
            try capture(VStack(spacing: 0) {
                DownloadRow(item: model.mediaLibrary[0], model: model)
                DownloadRow(item: completedItems[0], model: model, selected: true)
                DownloadRow(item: model.mediaLibrary[1], model: model)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(ThemePalette.color(palette.canvas)).environment(\.colorScheme, scheme),
                width: 580, height: 380, name: "row-alignment-\(scheme == .light ? "light" : "dark")")
            try capture(TaskDiagnosticView(model: model, item: completedItems[1]).environment(\.colorScheme, scheme),
                        width: 620, height: 600, name: "task-details-\(scheme == .light ? "light" : "dark")")
            model.items = completedItems
            try capture(DownloaderView(model: model).environment(\.colorScheme, scheme), width: 820, height: 600, name: "workspace-minimum-\(scheme == .light ? "light" : "dark")")
        }
        let logStart = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-30)
        model.logs = (0..<12).map { index -> ActivityEntry in
            let date = logStart.addingTimeInterval(Double(index * 15))
            let level: ActivityLevel = index == 10 ? .error : .info
            return ActivityEntry(date: date, level: level,
                          message: index == 10 ? String(repeating: "连接超时，请检查网络后重试。", count: 12) : "校验并保存",
                          subject: index < 4 ? "同名论文" : paper.title, itemID: completedItems[index < 4 ? 1 : 0].id)
        }
        model.theme = .graphite
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for width in [820, 960] {
                try capture(DownloaderView(model: model, page: .logs).environment(\.colorScheme, scheme), width: width, height: 600,
                            name: "logs-compact-\(scheme == .light ? "light" : "dark")-\(width)")
            }
        }
        print("UI snapshots: \(output.path)")
    }

    @MainActor static func themeTests() throws {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)].map { component -> Double in
                let value = component / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        func contrast(_ foreground: UInt32, _ background: UInt32) -> Double {
            let a = luminance(foreground), b = luminance(background)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                for surface in [palette.canvas, palette.surface] {
                    for text in [palette.text, palette.secondary, palette.accent, dark ? 0xFF6B6B : 0xB21F17, dark ? 0x4CD96E : 0x146E38, dark ? 0xF0B84F : 0x82540F] {
                        try expect(contrast(text, surface) >= 4.5, "\(theme.rawValue) text contrast in \(dark ? "dark" : "light")")
                    }
                }
                try expect(contrast(palette.onAction, palette.action) >= 4.5, "\(theme.rawValue) action contrast")
            }
        }
        let suite = "arxiv-theme-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        try expect(DownloadModel(preferences: preferences).theme == .graphite, "new installs use neutral graphite")
        preferences.set("unknown-future-theme", forKey: "theme")
        try expect(DownloadModel(preferences: preferences).theme == .native, "invalid theme fallback")
        print("PASS themes: 12 palettes contrast, migration and persistent selection")
    }

    static func liveTests() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = DownloadEngine()
        for id in ["2609.22978v1", "2605.18678"] {
            fputs("Live network: \(id)\n", stderr)
            let paper = try await engine.download(ArxivReference.parse(id), to: folder)
            if id == "2609.22978v1" {
                try expect(paper.metadata.title.hasPrefix("DeepSeek Elastic Compute") && paper.pages == 31, "fixed-version live DSec fixture")
            } else { try expect(paper.metadata.title.hasPrefix("Lance:") && paper.pages > 0, "live Lance metadata and PDF") }
            let duplicate = try await engine.download(ArxivReference.parse(paper.metadata.reference.pdfURL.absoluteString + ".pdf"), to: folder)
            try expect(duplicate.alreadyExisted && duplicate.url == paper.url, "live exact-version duplicate handling")
            print("PASS live: \(paper.metadata.reference.identifier), \(paper.pages) pages, duplicate reused")
            print("Verified file: \(paper.url.path)")
        }
    }
}
