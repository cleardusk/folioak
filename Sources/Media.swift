import Foundation
import CryptoKit
import ImageIO
import Darwin

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
            throw DownloadError.metadata("媒体下载组件缺失，请重新安装完整的 2.3.0 应用。论文下载仍可使用。")
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

    func run(_ executable: URL, arguments: [String], timeout: Double = 14_400,
             line: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    continuation.resume(with: Result { try execute(executable, arguments: arguments, timeout: timeout, line: line) })
                }
            }
        }, onCancel: { self.stop() })
    }

    private func execute(_ executable: URL, arguments: [String], timeout: Double,
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
                           "TMPDIR=\(NSTemporaryDirectory())", "LANG=en_US.UTF-8", "PYTHONUNBUFFERED=1", "DENO_NO_UPDATE_CHECK=1"]
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        lock.lock()
        if cancelled { lock.unlock(); close(descriptors[1]); throw CancellationError() }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&child, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        if code == 0 { pid = child }
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
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        lock.lock(); pid = 0; let wasCancelled = cancelled, timedOut = expired; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if timedOut { throw DownloadError.metadata("媒体处理超时，可稍后重试。") }
        return status == 0 ? 0 : (status >> 8 == 0 ? 1 : status >> 8)
    }
}

final class MediaOutput: @unchecked Sendable {
    // Only the process reader writes; readers access after run() returns.
    var title: String?
    var files: [URL] = []
    var error = ""
    var text = ""
    func receive(_ line: String, event: @Sendable (DownloadEvent) -> Void) {
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
    static let byteLimit: Int64 = 16 * 1024 * 1024 * 1024
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "mkv"]
    static let extensions = imageExtensions.union(videoExtensions).union(["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"])

    static func validate(_ file: URL, extension ext: String) async throws {
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
            let tools = try MediaTools.installed(), output = MediaOutput()
            let status = try await MediaProcess().run(try tools.executable("ffprobe"), arguments: ["-v", "error", "-show_entries", "stream=codec_type", "-of", "json", file.path], timeout: 30) {
                if output.text.utf8.count < 64 * 1024 { output.text += $0 + "\n" }
            }
            let object = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any]
            let streams = object?["streams"] as? [[String: Any]] ?? []
            guard status == 0, streams.contains(where: { ["audio", "video"].contains($0["codec_type"] as? String ?? "") }) else {
                throw DownloadError.metadata("收到的内容不是有效音视频，未保存。")
            }
        }
        try Task.checkCancellation()
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
        let hash = try hash(file), manager = FileManager.default
        let staged = directory.appendingPathComponent(".download-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staged) }
        let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DownloadError.storage(String(cString: strerror(errno))) }
        let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close(); try? destination.close() }
        while let data = try source.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try destination.write(contentsOf: data)
        }
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

    static func publish(_ files: [URL], title: String?, to directory: URL) async throws -> SavedDocument {
        guard !files.isEmpty else { throw DownloadError.metadata("没有媒体输出文件。") }
        // Validate the entire result before exposing any of it in the destination.
        for file in files { try await validate(file, extension: file.pathExtension.lowercased()) }
        var saved: [SavedDocument] = []
        do {
            for file in files {
                saved.append(try save(file, title: files.count == 1 ? (title ?? file.deletingPathExtension().lastPathComponent) : file.deletingPathExtension().lastPathComponent,
                                      extension: file.pathExtension.lowercased(), to: directory))
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

    static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv", "x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
    static func accepts(_ url: URL) -> Bool {
        guard PublicHTTPS.allows(url), let host = url.host, hosts.contains(host) else { return false }
        if host == "youtu.be" || host == "b23.tv" { return url.path.count > 1 }
        if host.contains("youtube.com") { return url.path == "/watch" || url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/live/") }
        if host.contains("bilibili.com") { return url.path.hasPrefix("/video/") }
        return url.path.range(of: #"^/(?:[^/]+/status|i/web/status)/[0-9]+(?:/video/[0-9]+)?/?$"#, options: .regularExpression) != nil
    }

    static func arguments(url: URL, format: MediaFormat, tools: MediaTools, folder: URL) throws -> [String] {
        var args = ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-update", "--no-cache-dir",
                    "--no-playlist", "--max-downloads", "20", "--no-overwrites", "--continue", "--newline", "--no-colors",
                    "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3", "--abort-on-unavailable-fragments", "--max-filesize", "16G",
                    "--ffmpeg-location", tools.directory.path, "--no-js-runtimes", "--js-runtimes", "deno:" + (try tools.executable("deno")).path,
                    "--windows-filenames", "--trim-filenames", "180", "--paths", folder.path,
                    "--output", "%(title).140B [%(id)s].%(ext)s",
                    "--print", "before_dl:APP_TITLE:%(title)j", "--print", "after_move:APP_FILE:%(filepath)j",
                    "--progress", "--progress-delta", "0.3", "--progress-template", "download:APP_PROGRESS:%(progress)j",
                    "--progress-template", "postprocess:APP_PROCESS:%(progress.status)s", "--no-simulate"]
        if format == .audio { args += ["--extract-audio", "--audio-format", "m4a"] }
        else { args += ["--format", "bv*+ba/b", "--merge-output-format", "mp4/mkv"] }
        return args + ["--", url.absoluteString]
    }

    static func download(_ url: URL, to directory: URL, format: MediaFormat,
                         event: @escaping @Sendable (DownloadEvent) -> Void) async throws -> SavedDocument {
        guard accepts(url) else { throw DownloadError.invalidLink(url.absoluteString) }
        let tools = try MediaTools.installed()
        for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"] { _ = try tools.executable(name) }
        let key = PDFStorage.key(url.absoluteString + "|" + format.rawValue + "|" + directory.standardizedFileURL.path)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DownloadPreferences.domain).appendingPathComponent("MediaDownloads")
        let coordinator = RequestCoordinator(directory: root)
        let parent = try coordinator.prepareDirectory(); close(parent)
        let folder = root.appendingPathComponent(key)
        let lease = try await RequestCoordinator(directory: folder).acquire { event(.coordinating) }
        defer { withExtendedLifetime(lease) {} }
        event(.metadata)
        let output = MediaOutput()
        let status = try await MediaProcess().run(try tools.executable("yt-dlp"), arguments: arguments(url: url, format: format, tools: tools, folder: folder)) {
            output.receive($0, event: event)
        }
        guard status == 0, !output.files.isEmpty else { throw DownloadError.metadata(failure(output.error)) }
        event(.validating)
        let files = try validatedOutputs(output.files, in: folder)
        let result = try await FileStorage.publish(files, title: output.title, to: directory)
        // Keep the coordination inode; remove only our completed media files.
        for file in output.files { try? FileManager.default.removeItem(at: file) }
        return result
    }

    static func failure(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("suspended") { return "来源账号已被停用，当前无法获取此内容。" }
        if lower.contains("video is unavailable") || lower.contains("tweet is unavailable") || lower.contains("deleted") {
            return "此内容当前不可访问，可能已被删除或设为非公开。"
        }
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") || lower.contains("403") || lower.contains("authentication") {
            return "此内容需要登录或站点验证。当前支持公开可访问的视频，请换一个链接后重试。"
        }
        if lower.contains("429") || lower.contains("rate limit") { return "视频站点暂时限流，请稍后重试。" }
        if lower.contains("no video") || lower.contains("does not contain") { return "链接中没有可下载的视频；X 图片帖子暂不支持。" }
        if lower.contains("unsupported url") { return "该链接暂不支持，请使用单个视频或帖子链接。" }
        if lower.contains("requested format") { return "当前视频没有可用的下载格式，请稍后重试。" }
        if lower.contains("space left") { return "磁盘空间不足，请释放空间后重试。" }
        return "媒体下载未完成，请检查链接和网络后重试。若站点已变更，请更新应用。"
    }
}
