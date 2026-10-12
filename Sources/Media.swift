import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

// Keep routing, canonical hosts and platform cooldowns in one place. Only
// individual-media paths are accepted; profiles and collections stay excluded.
enum MediaSite: String, CaseIterable {
    case youtube, bilibili, x, toutiao, xiaohongshu, douyin, tiktok, instagram, vimeo

    var hosts: [String] {
        switch self {
        case .youtube: return ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
        case .bilibili: return ["bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv"]
        case .x: return ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
        case .toutiao: return ["toutiao.com", "www.toutiao.com", "m.toutiao.com", "v.toutiao.com"]
        case .xiaohongshu: return ["xiaohongshu.com", "www.xiaohongshu.com", "xhslink.com"]
        case .douyin: return ["douyin.com", "www.douyin.com", "v.douyin.com"]
        case .tiktok: return ["tiktok.com", "www.tiktok.com", "vm.tiktok.com", "vt.tiktok.com"]
        case .instagram: return ["instagram.com", "www.instagram.com"]
        case .vimeo: return ["vimeo.com", "www.vimeo.com", "player.vimeo.com"]
        }
    }
    private static let byHost = Dictionary(uniqueKeysWithValues: allCases.flatMap { site in site.hosts.map { ($0, site) } })
    static func site(for host: String?) -> Self? { host.flatMap { byHost[$0.lowercased()] } }
    func canonicalHost(_ host: String) -> String {
        switch (self, host) {
        case (.toutiao, "toutiao.com"), (.toutiao, "m.toutiao.com"): return "www.toutiao.com"
        case (.xiaohongshu, "xiaohongshu.com"): return "www.xiaohongshu.com"
        case (.douyin, "douyin.com"): return "www.douyin.com"
        case (.tiktok, "tiktok.com"): return "www.tiktok.com"
        case (.instagram, "instagram.com"): return "www.instagram.com"
        default: return host
        }
    }
    func accepts(_ url: URL) -> Bool {
        let host = url.host ?? "", path = url.path
        func matches(_ expression: String) -> Bool { path.range(of: expression, options: .regularExpression) != nil }
        switch self {
        case .youtube:
            return host == "youtu.be" ? matches(#"^/[^/]+/?$"#) : path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
        case .bilibili:
            return host == "b23.tv" ? matches(#"^/[A-Za-z0-9]+/?$"#) : path.hasPrefix("/video/")
        case .x: return matches(#"^/(?:[^/]+/status|i/web/status)/[0-9]+(?:/video/[0-9]+)?/?$"#)
        case .toutiao: return host != "v.toutiao.com" && matches(#"^/video/[0-9]+/?$"#)
        case .xiaohongshu:
            return host == "xhslink.com" ? matches(#"^/(?:[am]/[A-Za-z0-9]+|[A-Za-z0-9]{2,})/?$"#) : matches(#"^/(?:explore|discovery/item)/[0-9a-f]{24}/?$"#)
        case .douyin:
            return host == "v.douyin.com" ? matches(#"^/[A-Za-z0-9_-]+/?$"#) : matches(#"^/video/[0-9]+/?$"#)
        case .tiktok:
            if host == "vm.tiktok.com" || host == "vt.tiktok.com" { return matches(#"^/[A-Za-z0-9]+/?$"#) }
            return matches(#"^/(?:t/[A-Za-z0-9]+|(?:embed|(?:share|@[A-Za-z0-9_.-]+)/video)/[0-9]+)/?$"#)
        case .instagram: return matches(#"^/(?:(?!share/)[^/]+/)?(?:p|tv|reels?)/[A-Za-z0-9_-]+/?$"#)
        case .vimeo:
            return host == "player.vimeo.com" ? matches(#"^/video/[0-9]+/?$"#) : matches(#"^/(?:[0-9]+(?:/[0-9a-f]{10})?|channels/[^/]+/[0-9]+|groups/[^/]+/videos/[0-9]+)/?$"#)
        }
    }
}

enum MediaFormat: String, Codable, CaseIterable, Sendable {
    case automatic, audio
    var label: String { self == .audio ? "仅音频" : "视频 · 自动画质" }
}

struct MediaTools: Sendable {
    let directory: URL
    static func installed() throws -> Self {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("media-tools"),
                          executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/media-tools"),
                          executable.deletingLastPathComponent().appendingPathComponent("media-tools")].compactMap { $0 }
        guard let folder = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("yt-dlp").path) }) else {
            throw DownloadError.metadata("媒体下载组件缺失，请重新安装完整应用。论文下载仍可使用。")
        }
        return Self(directory: folder)
    }
    func executable(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DownloadError.metadata("媒体下载组件不完整，请重新安装应用。")
        }
        return url
    }
}

// A separate process group lets cancellation stop the downloader AND its
// ffmpeg/JS children. Arguments never pass through a shell.
final class MediaProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var expired = false
    private var temporaryDirectoryUnused = true
    var canRemoveTemporaryDirectory: Bool { lock.lock(); defer { lock.unlock() }; return temporaryDirectoryUnused }

    func stop(timeout: Bool = false) {
        lock.lock()
        if timeout { expired = true } else { cancelled = true }
        let child = pid
        if child > 0 { kill(-child, SIGTERM) }
        lock.unlock()
        if child > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock(); defer { lock.unlock() }
                if pid == child { kill(-child, SIGKILL) }
            }
        }
    }

    func run(_ executable: URL, arguments: [String], timeout: Double = 14_400, temporaryDirectory: URL? = nil,
             line: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    continuation.resume(with: Result { try execute(executable, arguments: arguments, timeout: timeout, temporaryDirectory: temporaryDirectory, line: line) })
                }
            }
        }, onCancel: { self.stop() })
    }

    private func execute(_ executable: URL, arguments: [String], timeout: Double, temporaryDirectory: URL?,
                         line: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw DownloadError.storage("无法建立媒体进程连接。") }
        defer { close(descriptors[0]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let environment = ["PATH=/usr/bin:/bin", "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)",
                           "TMPDIR=\(temporaryDirectory?.path ?? NSTemporaryDirectory())", "LANG=en_US.UTF-8", "PYTHONUNBUFFERED=1"]
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        lock.lock()
        if cancelled { lock.unlock(); close(descriptors[1]); throw CancellationError() }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&child, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        if code == 0 { pid = child; temporaryDirectoryUnused = false }
        lock.unlock()
        close(descriptors[1])
        guard code == 0 else { throw DownloadError.metadata("媒体组件无法启动：\(String(cString: strerror(code)))") }
        let timer = DispatchWorkItem { [weak self] in self?.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        var dropping = false
        while true {
            let count = read(descriptors[0], &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            for byte in buffer.prefix(count) {
                if byte == 10 || byte == 13 {
                    if !dropping, !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
                    pending.removeAll(keepingCapacity: true); dropping = false
                } else if pending.count < 64 * 1024 && !dropping { pending.append(byte) }
                else { dropping = true; pending.removeAll(keepingCapacity: true) }
            }
        }
        if !dropping, !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
        // EOF alone does not mean the leader exited: a tool can close both
        // streams and continue working. Observe its exit without reaping it so
        // its PID remains reserved until the final group signal is sent.
        var observed = siginfo_t(), observation: Int32
        repeat { observation = waitid(P_PID, id_t(child), &observed, WEXITED | WNOWAIT) }
        while observation < 0 && errno == EINTR
        lock.lock()
        if observation == 0 { kill(-child, SIGKILL) }
        // Disarm delayed stop() signals before waitpid can release this PID.
        pid = 0
        lock.unlock()
        var status: Int32 = 0, reaped: pid_t
        repeat { reaped = waitpid(child, &status, observation == 0 ? 0 : WNOHANG) }
        while reaped < 0 && errno == EINTR
        guard observation == 0, reaped == child else {
            // No group signal after an uncertain observation, and no deletion
            // of a temporary directory that a process might still be using.
            throw DownloadError.metadata("媒体进程状态无法确认，请稍后重试。")
        }
        // Zombies cannot execute or write files, even if their parent has not
        // reaped them yet. Wait only for live group members, with a fixed bound.
        let exitDeadline = Date().addingTimeInterval(2)
        while Self.hasLiveMembers(in: child) != false, Date() < exitDeadline { usleep(10_000) }
        let groupUnused = Self.hasLiveMembers(in: child) == false
        lock.lock(); temporaryDirectoryUnused = groupUnused; let wasCancelled = cancelled, timedOut = expired; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if timedOut { throw DownloadError.metadata("媒体处理超时，可稍后重试。") }
        return status == 0 ? 0 : (status >> 8 == 0 ? 1 : status >> 8)
    }

    // nil means the kernel query failed: do not assume a directory is unused.
    // No signals are sent here, so a numeric process-group ID being reused can
    // only delay cleanup; it cannot cause an unrelated process to be killed.
    static func hasLiveMembers(in group: pid_t) -> Bool? {
        guard group > 0 else { return nil }
        if kill(-group, 0) < 0, errno == ESRCH { return false }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var byteCount = 0
            guard sysctl(&query, u_int(query.count), nil, &byteCount, nil, 0) == 0 else { return nil }
            if byteCount == 0 { return false }
            // Allow for a group growing between the size query and the read.
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: byteCount / stride + 8)
            let result = processes.withUnsafeMutableBytes { buffer in
                byteCount = buffer.count
                return sysctl(&query, u_int(query.count), buffer.baseAddress, &byteCount, nil, 0)
            }
            if result == 0 {
                guard byteCount % stride == 0 else { return nil }
                return processes.prefix(byteCount / stride).contains { Int32($0.kp_proc.p_stat) != SZOMB }
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }
}

final class MediaOutput: @unchecked Sendable {
    // The process reader owns parsing; lifecycle updates happen before it starts
    // or after run() has joined it. No raw browser output is retained as status.
    private let authentication: BrowserAuthenticationSelection?
    private(set) var authenticationState: BrowserAuthenticationReadState = .ready
    private static let cookieCount = try! NSRegularExpression(pattern: #"^(?:\[Cookies\] )?Extracted ([0-9]+) cookies?(?: from .*)?$"#)

    init(authentication: BrowserAuthenticationSelection? = nil) { self.authentication = authentication }

    func reportAuthentication(_ state: BrowserAuthenticationReadState, event: @Sendable (DownloadEvent) -> Void) {
        guard let authentication, authenticationState != state else { return }
        authenticationState = state
        event(.browserAuthentication(authentication, state))
    }

    var title: String?
    var files: [URL] = []
    var error = ""
    var text = ""
    var authenticationIssue: BrowserAuthenticationIssue?
    func receive(_ line: String, event: @Sendable (DownloadEvent) -> Void) {
        if line.hasPrefix("ERROR:") || line.hasPrefix("WARNING:"),
           let issue = BrowserAuthenticationIssue.readFailure(in: line) {
            authenticationIssue = issue
            reportAuthentication(.failed, event: event)
        }
        let range = NSRange(line.startIndex..., in: line)
        if let match = Self.cookieCount.firstMatch(in: line, range: range),
           let countRange = Range(match.range(at: 1), in: line), let count = Int(line[countRange]),
           authenticationIssue == nil {
            reportAuthentication(count > 0 ? .read : .empty, event: event)
        }
        func string(_ prefix: String) -> String? {
            guard line.hasPrefix(prefix) else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).utf8))
        }
        if let title = string("APP_TITLE:") {
            self.title = String(title.prefix(ResourceLimits.titleCharacters)); event(.document(self.title!))
        } else if let path = string("APP_FILE:"), files.count < 20 { files.append(URL(fileURLWithPath: path)) }
        else if line.hasPrefix("APP_PROGRESS:"),
                let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(13).utf8)) as? [String: Any] {
            let received = (object["downloaded_bytes"] as? NSNumber)?.int64Value ?? 0
            let total = ((object["total_bytes"] ?? object["total_bytes_estimate"]) as? NSNumber)?.int64Value ?? -1
            if received >= 0 { event(.progress(DownloadProgress(received: received, total: total))) }
        } else if line.hasPrefix("APP_PROCESS:") { event(.validating) }
        else if line.hasPrefix("ERROR:") { error = String(line.prefix(2048)) }
    }
}

enum FileStorage {
    struct Stream: Decodable, Equatable {
        struct Disposition: Decodable { let attached_pic: Int? }
        let codec_type: String?
        let codec_name: String?
        let disposition: Disposition?
        var isVideo: Bool { codec_type == "video" && disposition?.attached_pic != 1 }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.codec_type == rhs.codec_type && lhs.codec_name == rhs.codec_name }
    }
    private struct Probe: Decodable {
        struct Format: Decodable { let format_name: String? }
        let streams: [Stream]
        let format: Format?
    }
    static let byteLimit: Int64 = 16 * 1024 * 1024 * 1024
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "mkv"]
    static let extensions = imageExtensions.union(videoExtensions).union(["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"])

    // Response metadata is a hint; validate the downloaded content before saving.
    static func detectedExtension(_ file: URL, source: URL, response: HTTPURLResponse) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if try handle.read(upToCount: 5) == Data("%PDF-".utf8) { return "pdf" }
        if let image = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(image),
           let ext = UTType(type as String)?.preferredFilenameExtension, imageExtensions.contains(ext) { return ext }
        let types = ["application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
                     "image/heic": "heic", "image/tiff": "tiff", "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm",
                     "video/x-matroska": "mkv", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                     "audio/aac": "aac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/flac": "flac", "audio/x-flac": "flac",
                     "audio/ogg": "ogg", "application/ogg": "ogg", "audio/webm": "webm", "audio/opus": "opus"]
        if let mime = response.mimeType?.lowercased(), let ext = types[mime] { return ext }
        for name in [response.suggestedFilename, response.url?.lastPathComponent, source.lastPathComponent].compactMap({ $0 }) {
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "pdf" || extensions.contains(ext) { return ext }
        }
        if let info = try await probe(file), let format = info.format?.format_name {
            let names = Set(format.components(separatedBy: ","))
            if names.contains("mov") { return info.streams.contains(where: \.isVideo) ? "mp4" : "m4a" }
            if names.contains("matroska") { return "mkv" }
            for ext in ["mp3", "aac", "wav", "flac", "ogg"] where names.contains(ext) { return ext }
        }
        return "pdf"
    }

    private static func probe(_ file: URL) async throws -> Probe? {
        let tools = try MediaTools.installed(), output = MediaOutput()
        let status = try await MediaProcess().run(try tools.executable("ffprobe"), arguments: [
            "-v", "error", "-protocol_whitelist", "file", "-probesize", "5000000", "-analyzeduration", "5000000",
            "-show_entries", "stream=codec_type,codec_name:stream_disposition=attached_pic:format=format_name", "-of", "json", file.path
        ], timeout: 30) {
            if output.text.utf8.count < 64 * 1024 { output.text += $0 + "\n" }
        }
        return status == 0 ? try? JSONDecoder().decode(Probe.self, from: Data(output.text.utf8)) : nil
    }

    static func extractAudio(_ file: URL, streams: [Stream], to output: URL) async throws {
        guard let audio = streams.first(where: { $0.codec_type == "audio" }) else {
            throw DownloadError.metadata("视频没有可提取的音轨。")
        }
        let tools = try MediaTools.installed()
        let codec = ["aac", "alac"].contains(audio.codec_name ?? "") ? "copy" : "aac"
        let status = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-xerror", "-n", "-protocol_whitelist", "file", "-i", file.path, "-map", "0:a:0", "-vn", "-c:a", codec,
            "-movflags", "+faststart", "-f", "ipod", output.path
        ]) { _ in }
        guard status == 0 else { throw DownloadError.metadata("无法提取音频，未保存。") }
        let result = try await validate(output, extension: "m4a")
        guard result.contains(where: { $0.codec_type == "audio" }), !result.contains(where: { $0.codec_type == "video" }) else {
            throw DownloadError.metadata("无法提取音频，未保存。")
        }
    }

    @discardableResult
    static func validate(_ file: URL, extension ext: String) async throws -> [Stream] {
        var streams: [Stream] = []
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= byteLimit, extensions.contains(ext) else {
            throw DownloadError.metadata("文件为空、格式不支持或超过 16 GB，未保存。")
        }
        if imageExtensions.contains(ext) {
            guard let image = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(image) > 0,
                  CGImageSourceGetStatus(image) == .statusComplete else {
                throw DownloadError.metadata("收到的内容不是完整图片，未保存。")
            }
        } else {
            streams = try await probe(file)?.streams ?? []
            guard streams.contains(where: { ["audio", "video"].contains($0.codec_type ?? "") }) else {
                throw DownloadError.metadata("收到的内容不是有效音视频，未保存。")
            }
        }
        try Task.checkCancellation()
        return streams
    }

    static func hash(_ file: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256(), bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); bytes += Int64(data.count)
            guard bytes <= byteLimit else { throw DownloadError.limit("文件超过 16 GB，未保存。") }
            digest.update(data: data)
        }
        return digest.finalize()
    }

    static func save(_ file: URL, title: String, extension ext: String, to directory: URL) throws -> SavedDocument {
        let manager = FileManager.default
        let staged = directory.appendingPathComponent(".download-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staged) }
        let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DownloadError.storage(String(cString: strerror(errno))) }
        let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close(); try? destination.close() }
        var digest = SHA256(), bytes: Int64 = 0
        while let data = try source.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(data.count)
            guard bytes <= byteLimit else { throw DownloadError.limit("文件超过 16 GB，未保存。") }
            digest.update(data: data)
            try destination.write(contentsOf: data)
        }
        let hash = digest.finalize()
        try destination.synchronize()
        try destination.close()
        for index in 0..<1000 {
            try Task.checkCancellation()
            let suffix = index == 0 ? "" : " (\(index + 1))"
            let target = directory.appendingPathComponent(PaperMetadata.filename(title: title, ending: suffix + "." + ext))
            if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return SavedDocument(title: title, url: target, alreadyExisted: false, pages: 0)
            }
            guard errno == EEXIST else { throw DownloadError.storage(String(cString: strerror(errno))) }
            let info = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info?.isRegularFile == true, info?.isSymbolicLink != true, let existing = try? self.hash(target), existing == hash {
                return SavedDocument(title: title, url: target, alreadyExisted: true, pages: 0)
            }
        }
        throw DownloadError.storage("同名文件过多，请选择其他目录。")
    }

    static func publish(_ files: [URL], title: String?, to directory: URL, organizeByType: Bool = false) async throws -> SavedDocument {
        guard !files.isEmpty else { throw DownloadError.metadata("没有媒体输出文件。") }
        // Validate the entire result before exposing any of it in the destination.
        for file in files { try await validate(file, extension: file.pathExtension.lowercased()) }
        var saved: [SavedDocument] = []
        do {
            for file in files {
                let destination = organizeByType ? try DownloadFolder.media(extension: file.pathExtension).prepare(in: directory) : directory
                saved.append(try save(file, title: files.count == 1 ? (title ?? file.deletingPathExtension().lastPathComponent) : file.deletingPathExtension().lastPathComponent,
                                      extension: file.pathExtension.lowercased(), to: destination))
            }
        } catch {
            // Never roll back a pre-existing file reused by content hash.
            for result in saved where !result.alreadyExisted { try? FileManager.default.removeItem(at: result.url) }
            throw error
        }
        var result = saved[0]; result.additionalURLs = Array(saved.dropFirst().map(\.url))
        return result
    }
}

enum MediaDownloader {
    // Site manifests can omit codec names, causing a conservative MKV choice.
    // Let the MP4 muxer decide using the downloaded streams, without re-encoding
    // or dropping tracks. The original stays available until publication succeeds.
    static func preferMP4(_ file: URL, tools: MediaTools, scratch: URL) async throws -> URL {
        try Task.checkCancellation()
        guard ["mkv", "webm", "mov"].contains(file.pathExtension.lowercased()) else { return file }
        let originalStreams = try await FileStorage.validate(file, extension: file.pathExtension.lowercased())
        guard originalStreams.contains(where: { $0.codec_type == "video" }) else { return file }
        let candidate = scratch.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".mp4")
        var keepCandidate = false
        defer { if !keepCandidate { try? FileManager.default.removeItem(at: candidate) } }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let status = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
                "-nostdin", "-v", "error", "-xerror", "-n", "-i", file.path, "-map", "0", "-c", "copy",
                "-movflags", "+faststart", "-f", "mp4", candidate.path
            ]) { _ in }
            if status == 0 {
                let convertedStreams = try await FileStorage.validate(candidate, extension: "mp4")
                if convertedStreams == originalStreams {
                    keepCandidate = true
                    return candidate
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { /* A usable original is preferable to a failed optional remux. */ }
        try Task.checkCancellation()
        return file
    }

    static func validatedOutputs(_ files: [URL], in folder: URL) throws -> [URL] {
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return try files.map { file in
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.deletingLastPathComponent().path == expected else {
                throw DownloadError.storage("媒体输出位置不正确，未保存。")
            }
            return resolved
        }
    }

    static let hosts = Set(MediaSite.allCases.flatMap(\.hosts))
    static func accepts(_ url: URL) -> Bool {
        guard PublicHTTPS.allows(url), let site = MediaSite.site(for: url.host) else { return false }
        return site.accepts(url)
    }

    static func arguments(url: URL, format: MediaFormat, tools: MediaTools, folder: URL,
                          authentication: BrowserAuthenticationSelection? = nil) throws -> [String] {
        var args = ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-update", "--no-cache-dir",
                    "--no-playlist", "--max-downloads", "20", "--no-overwrites", "--continue", "--newline", "--no-colors",
                    "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3", "--abort-on-unavailable-fragments", "--max-filesize", "16G",
                    "--retry-sleep", "http:exp=1:8", "--retry-sleep", "fragment:exp=1:8",
                    "--ffmpeg-location", tools.directory.path, "--no-js-runtimes", "--js-runtimes", "quickjs:" + (try tools.executable("qjs")).path,
                    "--windows-filenames", "--trim-filenames", "180", "--paths", folder.path,
                    "--output", "%(title).140B [%(id)s].%(ext)s",
                    "--print", "before_dl:APP_TITLE:%(title)j", "--print", "after_move:APP_FILE:%(filepath)j",
                    "--progress", "--progress-delta", "0.3", "--progress-template", "download:APP_PROGRESS:%(progress)j",
                    "--progress-template", "postprocess:APP_PROCESS:%(progress.status)s", "--no-simulate"]
        // Never ask yt-dlp to persist the cookie jar. No browser is read unless
        // the caller explicitly supplies a validated selection for a supported URL.
        args += ["--no-cookies"]
        if let authentication {
            guard accepts(url) else { throw DownloadError.invalidLink(url.absoluteString) }
            // --print otherwise suppresses the cookie reader's normal status.
            // Keep it observable without enabling verbose or retaining raw output.
            args += ["--no-quiet", "--cookies-from-browser", authentication.argument]
        } else { args += ["--no-cookies-from-browser"] }
        if format == .audio { args += ["--extract-audio", "--audio-format", "m4a"] }
        else { args += ["--format", "bv*+ba/b", "--merge-output-format", "mp4/mkv"] }
        return args + ["--", url.absoluteString]
    }

    static func download(_ url: URL, to directory: URL, format: MediaFormat, organizeByType: Bool = false,
                         authentication: BrowserAuthenticationSelection? = nil,
                         event: @escaping @Sendable (DownloadEvent) -> Void) async throws -> SavedDocument {
        guard accepts(url) else { throw DownloadError.invalidLink(url.absoluteString) }
        let tools = try MediaTools.installed()
        for name in ["yt-dlp", "ffmpeg", "ffprobe", "qjs"] { _ = try tools.executable(name) }
        let identity = url.absoluteString + "|" + format.rawValue + "|" + directory.standardizedFileURL.path
        // Preserve anonymous resume keys; isolate opt-in profiles from old partials.
        let key = PDFStorage.key(identity + (authentication.map { "|browser-auth|" + $0.argument } ?? ""))
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DownloadPreferences.domain).appendingPathComponent("MediaDownloads")
        let coordinator = RequestCoordinator(directory: root)
        let parent = try coordinator.prepareDirectory(); close(parent)
        let folder = root.appendingPathComponent(key)
        let lease = try await RequestCoordinator(directory: folder).acquire { event(.coordinating) }
        defer { withExtendedLifetime(lease) {} }
        event(.metadata)
        let output = try await runDownloader(url, format: format, tools: tools, folder: folder,
                                             authentication: authentication, event: event)
        event(.validating)
        var files = try validatedOutputs(output.files, in: folder)
        let scratch = folder.appendingPathComponent(".mp4-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        if format == .automatic {
            for index in files.indices {
                files[index] = try await preferMP4(files[index], tools: tools, scratch: scratch.appendingPathComponent(String(index)))
            }
        }
        let result = try await FileStorage.publish(files, title: output.title, to: directory, organizeByType: organizeByType)
        // Keep the coordination inode; remove only our completed media files.
        for file in output.files { try? FileManager.default.removeItem(at: file) }
        return result
    }

    static func runDownloader(_ url: URL, format: MediaFormat, tools: MediaTools, folder: URL,
                              authentication: BrowserAuthenticationSelection? = nil,
                              event: @escaping @Sendable (DownloadEvent) -> Void = { _ in }) async throws -> MediaOutput {
        guard accepts(url) else { throw DownloadError.invalidLink(url.absoluteString) }
        let output = MediaOutput(authentication: authentication)
        output.reportAuthentication(.reading, event: event)
        defer {
            if output.authenticationState == .reading {
                output.reportAuthentication(.ready, event: event)
            } else if let authentication {
                // Re-send the final result after progress so bounded event streams
                // cannot leave the UI reading if an earlier status was dropped.
                event(.browserAuthentication(authentication, output.authenticationState))
            }
        }
        // yt-dlp makes a temporary SQLite copy while reading browser cookies.
        // Own its TMPDIR so cancellation also removes copies that its process
        // may not have had time to clean up. The directory contains no export.
        let authenticationTemporary = authentication.map { _ in folder.appendingPathComponent(".browser-auth-" + UUID().uuidString, isDirectory: true) }
        if let authenticationTemporary {
            do {
                try FileManager.default.createDirectory(at: authenticationTemporary, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                output.reportAuthentication(.failed, event: event)
                throw DownloadError.browserAuthentication(.readFailed)
            }
        }
        let process = MediaProcess()
        defer {
            if let authenticationTemporary, process.canRemoveTemporaryDirectory {
                try? FileManager.default.removeItem(at: authenticationTemporary)
            }
        }
        let status = try await process.run(try tools.executable("yt-dlp"),
                                                 arguments: arguments(url: url, format: format, tools: tools, folder: folder, authentication: authentication),
                                                 temporaryDirectory: authenticationTemporary) {
            output.receive($0, event: event)
        }
        guard status == 0, !output.files.isEmpty else {
            if authentication != nil, let issue = output.authenticationIssue {
                throw DownloadError.browserAuthentication(issue)
            }
            let error = failure(output.error, url: url, authentication: authentication)
            if case .browserAuthentication(let issue) = error {
                switch issue {
                case .readFailed, .invalidSelection: output.reportAuthentication(.failed, event: event)
                case .sessionRejected, .loginRequired: output.reportAuthentication(.rejected, event: event)
                }
            }
            throw error
        }
        return output
    }

    static func failure(_ raw: String, url: URL? = nil,
                        authentication: BrowserAuthenticationSelection? = nil) -> DownloadError {
        let lower = raw.lowercased()
        if authentication != nil, let issue = BrowserAuthenticationIssue.readFailure(in: raw) {
            return .browserAuthentication(issue)
        }
        // Match an HTTP status rather than digits in a video ID. yt-dlp does not
        // expose Retry-After here; use the native engine's default one-minute pause.
        if lower.range(of: #"\bhttp(?: error)?(?: status(?: code)?)?[:\s]+429\b"#, options: .regularExpression) != nil ||
            lower.contains("too many requests") || lower.contains("rate limit") || lower.contains("rate-limit") {
            return .cooldown(60)
        }
        if lower.contains("suspended") { return .metadata("来源账号已被停用，当前无法获取此内容。") }
        if lower.contains("video is unavailable") || lower.contains("tweet is unavailable") || lower.contains("deleted") {
            return .metadata("此内容当前不可访问，可能已被删除或设为非公开。")
        }
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") || lower.contains("403") || lower.contains("authentication") {
            return .browserAuthentication(authentication == nil ? .loginRequired : .sessionRejected)
        }
        if MediaSite.site(for: url?.host) == .xiaohongshu && lower.contains("no video formats") {
            return .metadata("小红书未返回可下载的视频。请复制完整分享链接并保留访问参数；图文笔记或需要登录、验证的内容当前无法直接下载。")
        }
        if lower.contains("no video") || lower.contains("does not contain") { return .metadata("链接中没有可下载的视频。若是图片，请使用图片文件的直链。") }
        if lower.contains("unsupported url") { return .metadata("该链接暂不支持，请使用单个视频或帖子链接。") }
        if lower.contains("requested format") { return .metadata("当前视频没有可用的下载格式，请稍后重试。") }
        if lower.contains("space left") { return .metadata("磁盘空间不足，请释放空间后重试。") }
        return .metadata("媒体下载未完成，请检查链接和网络后重试。若站点已变更，请更新应用。")
    }
}
