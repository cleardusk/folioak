import Foundation
import Darwin

struct DownloadPreferences {
    static let domain = "local.paperrepo.arxiv-downloader"
    static var shared: UserDefaults {
        // In the app this is its existing application domain; the standalone CLI
        // explicitly reads that same domain without writing command overrides.
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain)!
    }
    let directory: URL
    let naming: NamingStyle
    init(_ preferences: UserDefaults) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferred = home.appendingPathComponent("Desktop/PhD/PapersRepo", isDirectory: true)
        directory = preferences.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (FileManager.default.fileExists(atPath: preferred.path) ? preferred : home.appendingPathComponent("Downloads", isDirectory: true))
        naming = NamingStyle(rawValue: preferences.string(forKey: "namingStyle") ?? "") ?? .dateTitle
    }
}

struct BatchInput {
    struct Entry {
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
