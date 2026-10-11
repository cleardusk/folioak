import Foundation
import Darwin

enum SourceScheduler {
    static func groups<T>(_ items: [T], key: (T) -> String) -> [[T]] {
        var indices: [String: Int] = [:]; var groups: [[T]] = []
        for item in items {
            let source = key(item)
            if let index = indices[source] { groups[index].append(item) }
            else { indices[source] = groups.count; groups.append([item]) }
        }
        return groups
    }
    static func run<T: Sendable, Result: Sendable>(_ groups: [[T]], operation: @escaping @Sendable ([T]) async -> Result) async -> [Result] {
        await withTaskGroup(of: Result.self) { group in
            var next = 0; var results: [Result] = []
            func enqueue() {
                let batch = groups[next]; next += 1
                group.addTask { await operation(batch) }
            }
            for _ in 0..<min(3, groups.count) { enqueue() }
            while let result = await group.next() {
                results.append(result)
                if next < groups.count && !Task.isCancelled { enqueue() }
            }
            return results
        }
    }
}

enum DownloadFolder: String, Sendable {
    case papers = "Papers", videos = "Videos", audio = "Audio", images = "Images"

    static func media(extension ext: String) -> Self {
        if FileStorage.imageExtensions.contains(ext.lowercased()) { return .images }
        return FileStorage.videoExtensions.contains(ext.lowercased()) ? .videos : .audio
    }

    static func prepareRoot(_ root: URL) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: root.path) else { throw CocoaError(.fileWriteNoPermission) }
        } catch { throw DownloadError.storage("保存位置无法创建或不可写，请更改位置后重试。") }
    }

    func prepare(in root: URL) throws -> URL {
        let target = root.appendingPathComponent(rawValue, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  FileManager.default.isWritableFile(atPath: target.path) else { throw CocoaError(.fileWriteNoPermission) }
            return target
        } catch { throw DownloadError.storage("\(rawValue) 文件夹无法创建或不可写，请检查保存位置与权限。") }
    }
}

struct DownloadPreferences {
    // Stable storage identity across product renames; also shared with old CLIs.
    static let domain = "local.paperrepo.arxiv-downloader"
    static var shared: UserDefaults {
        // In the app this is its existing application domain; the standalone CLI
        // explicitly reads that same domain without writing command overrides.
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain)!
    }
    let directory: URL
    let naming: NamingStyle
    init(_ preferences: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let oldDefault = ["Leafpick", "Leafpeak"].map { home.appendingPathComponent("Downloads/\($0)", isDirectory: true) }.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        // Keep legacy folder preferences and existing file URLs intact. Their
        // meanings differ from the new root and cannot be safely inferred.
        directory = preferences.string(forKey: "downloadRootDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? oldDefault ?? home.appendingPathComponent("Downloads/Folioak", isDirectory: true)
        naming = NamingStyle(rawValue: preferences.string(forKey: "namingStyle") ?? "") ?? .dateTitle
    }
}

// Used at capture boundaries, so prose never becomes a queue of failed words.
// Direct entry parsing still retains invalid tokens for correction.
enum PaperInput {
    private static let markdownLabels = try! NSRegularExpression(pattern: #"\[[^\]\r\n]*\]\((?=https?://)"#, options: .caseInsensitive)
    private static let candidates = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\"“”]+|(?<![\w./])(?:\d{4}\.\d{4,5}|[A-Za-z][A-Za-z.-]*(?:\.[A-Za-z]{2})?/\d{7})(?:v\d+)?(?![\w.])"#,
        options: .caseInsensitive)
    static func captured(_ text: String) throws -> String {
        guard text.utf8.count <= ResourceLimits.inputBytes else { throw DownloadError.limit("输入超过 64 KB，请分批导入。") }
        let direct = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.contains(where: { $0.isWhitespace }), (try? DownloadSource.parse(direct)) != nil { return direct }
        // Strip link labels first: a URL used as its own Markdown label must
        // not swallow the destination or create a duplicate paper.
        let prepared = markdownLabels.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "(")
        let raw = prepared as NSString
        let matches = candidates.matches(in: prepared, range: NSRange(location: 0, length: raw.length))
        guard matches.count <= ResourceLimits.batchCount else { throw DownloadError.limit("每批最多 200 条输入，请分批下载。") }
        guard !matches.isEmpty else { return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
        return matches.map {
            var token = raw.substring(with: $0.range)
            // Remove a Markdown/prose wrapper, retaining balanced URL path parentheses.
            if $0.range.location > 0, raw.substring(with: NSRange(location: $0.range.location - 1, length: 1)) == "(", token.last == ")" { token.removeLast() }
            if !token.contains("?") { token = token.trimmingCharacters(in: CharacterSet(charactersIn: "，。；;,.!！")) }
            return token
        }.joined(separator: "\n")
    }
    static func decode(_ data: Data) throws -> String {
        guard data.count <= ResourceLimits.inputBytes else { throw DownloadError.limit("输入超过 64 KB，请分批导入。") }
        guard let text = String(data: data, encoding: .utf8) else { throw DownloadError.limit("请选择 UTF-8 编码的文本文件。") }
        return try captured(text)
    }
}

struct TaskDiagnostics: Codable {
    enum Phase: String, Codable, CaseIterable {
        case coordination, metadata, local, transfer, waiting, validation
        var label: String {
            switch self {
            case .coordination: return "任务协调"
            case .metadata: return "获取信息"
            case .local: return "检查本地"
            case .transfer: return "传输文件"
            case .waiting: return "等待与退避"
            case .validation: return "校验与保存"
            }
        }
    }
    let startedAt: Date
    private(set) var finishedAt: Date?
    private(set) var phase: Phase?
    private(set) var enteredAt: Date
    private(set) var recordedAt: Date
    private(set) var seconds: [String: Double] = [:]
    private(set) var retries = 0
    private var lastRetry: Int?
    init(now: Date = Date()) { startedAt = now; enteredAt = now; recordedAt = now }
    mutating func receive(_ event: DownloadEvent, now: Date = Date()) {
        guard finishedAt == nil else { return }
        recordedAt = now
        let next: Phase
        switch event {
        case .coordinating: next = .coordination
        case .metadata: next = .metadata; lastRetry = nil
        case .resolved: next = .transfer; lastRetry = nil
        case .checkingLocal: next = .local
        case .progress: next = .transfer; lastRetry = nil
        case .waiting: next = .waiting
        case .retry(let attempt):
            if lastRetry != attempt { retries += 1; lastRetry = attempt }
            next = .waiting
        case .validating: next = .validation
        case .document: return
        }
        guard next != phase else { return }
        accrue(now); phase = next
    }
    private mutating func accrue(_ now: Date) {
        if let phase { seconds[phase.rawValue, default: 0] += max(0, now.timeIntervalSince(enteredAt)) }
        enteredAt = now
    }
    mutating func finish(now: Date = Date()) {
        guard finishedAt == nil else { return }
        accrue(now); recordedAt = now; finishedAt = now; phase = nil
    }
    func duration(_ phase: Phase, now: Date = Date()) -> Double {
        seconds[phase.rawValue, default: 0] + (self.phase == phase ? max(0, now.timeIntervalSince(enteredAt)) : 0)
    }
    func elapsed(now: Date = Date()) -> Double { max(0, (finishedAt ?? now).timeIntervalSince(startedAt)) }
    var valid: Bool {
        seconds.count <= Phase.allCases.count && seconds.allSatisfy { Phase(rawValue: $0.key) != nil && $0.value.isFinite && $0.value >= 0 } &&
        (0...100).contains(retries) && startedAt.timeIntervalSince1970.isFinite && enteredAt.timeIntervalSince1970.isFinite && recordedAt.timeIntervalSince1970.isFinite &&
        (finishedAt?.timeIntervalSince1970.isFinite ?? true)
    }
    static func time(_ seconds: Double) -> String { seconds < 0.1 ? "<0.1 秒" : seconds < 60 ? String(format: "%.1f 秒", seconds) : String(format: "%.0f 分 %.0f 秒", floor(seconds / 60), seconds.truncatingRemainder(dividingBy: 60)) }
}

struct BatchInput: Sendable {
    struct Entry: Sendable {
        let original: String
        let source: DownloadSource?
        var reference: ArxivReference? { source?.reference }
        let error: String?
    }
    let entries: [Entry]
    let duplicates: Int
    init(_ text: String) throws {
        guard text.utf8.count <= ResourceLimits.inputBytes else { throw DownloadError.limit("输入超过 64 KB，请分批下载。") }
        let tokens = DownloadSource.tokens(in: text)
        guard !tokens.isEmpty else { throw DownloadError.limit("请提供至少一个链接或 arXiv 编号。") }
        guard tokens.count <= ResourceLimits.batchCount else { throw DownloadError.limit("每批最多 200 条输入，请分批下载。") }
        var seen = Set<DownloadSource>()
        var entries: [Entry] = []
        var duplicates = 0
        for token in tokens {
            do {
                let source = try DownloadSource.parse(token)
                if !seen.insert(source).inserted { duplicates += 1; continue }
                entries.append(Entry(original: token, source: source, error: nil))
            } catch { entries.append(Entry(original: token, source: nil, error: error.localizedDescription)) }
        }
        self.entries = entries; self.duplicates = duplicates
    }
}

struct RequestState: Codable {
    var schema = 1
    var lastRequest: Date?
    var cooldown: Date?
    var strikes = 0
}

struct RequestCoordinator: Sendable {
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/arXivDownloader", isDirectory: true)) {
        self.directory = directory
    }
    func prepareDirectory() throws -> Int32 {
        do { try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw DownloadError.coordination("无法创建共享下载状态目录：\(error.localizedDescription)") }
        // mkdir is atomic when both entry points start for the first time.
        guard Darwin.mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
            throw DownloadError.coordination("无法创建共享下载状态目录。")
        }
        let folder = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw DownloadError.coordination("无法安全打开共享下载状态目录。") }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(folder)
            throw DownloadError.coordination("共享下载状态目录必须由当前用户独占访问。")
        }
        return folder
    }
    func acquire(waiting: @escaping @Sendable () -> Void = {}) async throws -> RequestLease {
        try Task.checkCancellation()
        let folder = try prepareDirectory()
        var handedOff = false
        var descriptor: Int32 = -1
        defer { if !handedOff { if descriptor >= 0 { Darwin.close(descriptor) }; Darwin.close(folder) } }
        var info = stat()
        for _ in 0..<4 {
            descriptor = openat(folder, "request.lock", O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 { break }
            guard errno == ENOENT || errno == EINTR else { break }
            descriptor = openat(folder, "request.lock", O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor >= 0 { break }
            guard errno == EEXIST || errno == ENOENT || errno == EINTR else { break }
        }
        guard descriptor >= 0, fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw DownloadError.coordination("共享下载锁不是安全的普通文件。")
        }
        var announced = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR else { throw DownloadError.coordination("无法获取共享下载锁。") }
            if !announced { waiting(); announced = true }
            try await Task.sleep(nanoseconds: 200_000_000)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        handedOff = true
        return RequestLease(folder: folder, lock: descriptor)
    }
}

// Keep the lock inode in place permanently. Removing it would let a second
// process lock a different inode. Descriptor ownership releases locks on exit.
final class RequestLease: @unchecked Sendable {
    private let folder: Int32
    private let descriptor: Int32
    fileprivate init(folder: Int32, lock: Int32) { self.folder = folder; descriptor = lock }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor); Darwin.close(folder) }

    func load() throws -> RequestState {
        let file = openat(folder, "request-state.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return RequestState() }
            throw DownloadError.coordination("无法读取共享下载状态。")
        }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, (0...4096).contains(info.st_size) else {
            throw DownloadError.coordination("共享下载状态文件不符合安全或大小要求。")
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DownloadError.coordination("共享下载状态读取失败。") }
                offset += count
            }
        }
        guard let state = try? JSONDecoder().decode(RequestState.self, from: data), state.schema == 1,
              (0...4).contains(state.strikes),
              state.lastRequest?.timeIntervalSince1970.isFinite != false,
              state.cooldown.map({ $0.timeIntervalSinceNow.isFinite && $0.timeIntervalSinceNow <= ResourceLimits.retryAfterSeconds }) != false else {
            throw DownloadError.coordination("共享下载状态损坏，已停止请求。")
        }
        return state
    }

    func store(_ state: RequestState) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 4096 else { throw DownloadError.coordination("共享下载状态超过大小限制。") }
        let name = ".request-\(UUID().uuidString).tmp"
        let file = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DownloadError.coordination("无法保存共享下载状态。") }
        defer { Darwin.close(file); unlinkat(folder, name, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DownloadError.coordination("共享下载状态写入失败。") }
                offset += count
            }
        }
        guard fsync(file) == 0, renameat(folder, name, folder, "request-state.json") == 0 else {
            throw DownloadError.coordination("共享下载状态无法完整保存，已停止请求。")
        }
    }
}
