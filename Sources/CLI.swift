import Foundation
import Darwin

struct CLIOptions {
    enum Action { case download, help, version }
    var action: Action = .download
    var input = ""
    var output: String?
    var naming: NamingStyle?
    var json = false

    static func parse(_ arguments: [String]) throws -> Self {
        var options = Self()
        var inputs: [String] = []
        var index = 0
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else {
                throw DownloadError.limit("\(option) 缺少参数。")
            }
            return arguments[index]
        }
        func naming(_ value: String) throws -> NamingStyle {
            switch value {
            case "date-title": return .dateTitle
            case "id-title": return .identifierTitle
            case "title": return .titleOnly
            default: throw DownloadError.limit("命名方式应为 date-title、id-title 或 title。")
            }
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h": options.action = .help; return options
            case "--version": options.action = .version; return options
            case "--": inputs.append(contentsOf: arguments.dropFirst(index + 1)); index = arguments.count; continue
            case "-o", "--output":
                guard options.output == nil else { throw DownloadError.limit("保存目录只能指定一次。") }
                options.output = try value(argument)
            case "--naming":
                guard options.naming == nil else { throw DownloadError.limit("命名方式只能指定一次。") }
                options.naming = try naming(value(argument))
            case "--json": options.json = true
            default:
                if argument.hasPrefix("--output=") {
                    guard options.output == nil, argument.count > "--output=".count else { throw DownloadError.limit("保存目录为空或重复。") }
                    options.output = String(argument.dropFirst("--output=".count))
                } else if argument.hasPrefix("--naming=") {
                    guard options.naming == nil else { throw DownloadError.limit("命名方式只能指定一次。") }
                    options.naming = try naming(String(argument.dropFirst("--naming=".count)))
                } else if argument.hasPrefix("-") { throw DownloadError.limit("未知选项：\(argument)。使用 --help 查看用法。") }
                else { inputs.append(argument) }
            }
            index += 1
        }
        guard inputs.reduce(0, { $0 + $1.utf8.count + 1 }) <= ResourceLimits.inputBytes else { throw DownloadError.limit("输入超过 64 KB，请分批下载。") }
        options.input = inputs.joined(separator: "\n")
        _ = try BatchInput(options.input)
        return options
    }

    static func help(version: String) -> String {
        """
        arxiv-download \(version)
        用法：arxiv-download LINK_OR_ID... [选项]

          -o, --output DIR        保存目录；不存在时创建
          --naming STYLE          date-title / id-title / title
          --json                  将批次结果作为 JSON 输出
          -h, --help              显示用法
          --version               显示版本

        默认读取 UI 的保存目录和命名方式；命令参数仅影响本次执行。
        支持摘要、PDF、HTML 链接及编号，每批最多 200 条，自动去重。
        下载进度写入 stderr；普通模式的 stdout 仅输出已保存文件路径。
        退出码：0 成功；1 有失败或暂停；2 参数/目录错误；130 SIGINT；143 SIGTERM。
        """ + "\n"
    }
}

struct CLIResult: Encodable {
    let input: String
    var identifier: String?
    var status: String
    var path: String?
    var pages: Int?
    var error: String?
    var retryAfter: Date?
}
struct CLIReport: Encodable {
    let schema = 1
    let version: String
    let deduplicated: Int
    let results: [CLIResult]
}

enum CLIRunner {
    static func terminalText(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
    }
    static func run(_ options: CLIOptions, version: String, engine: DownloadEngine, preferences: UserDefaults,
                    stdout: @escaping @Sendable (String) -> Void, stderr: @escaping @Sendable (String) -> Void,
                    interactive: Bool = false) async -> Int32 {
        do {
            if options.action == .help { stdout(CLIOptions.help(version: version)); return 0 }
            if options.action == .version { stdout(version + "\n"); return 0 }
            let defaults = DownloadPreferences(preferences)
            let directory = options.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL } ?? defaults.directory
            let naming = options.naming ?? defaults.naming
            let batch = try BatchInput(options.input)
            if batch.entries.contains(where: { $0.reference != nil }) {
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), options.output != nil {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    isDirectory = true
                }
                guard isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory.path) else {
                    throw DownloadError.storage("保存目录不存在、不是文件夹或不可写，请检查权限或使用 -o 指定目录。")
                }
            }
            var results: [CLIResult] = []
            var pause: Date?
            for entry in batch.entries {
                var result = CLIResult(input: entry.original, identifier: entry.reference?.identifier, status: "failed", error: entry.error)
                guard let reference = entry.reference else { results.append(result); continue }
                if Task.isCancelled { result.status = "cancelled"; results.append(result); continue }
                if let pause { result.status = "paused"; result.retryAfter = pause; results.append(result); continue }
                do {
                    if interactive { stderr("下载：\(reference.identifier)\n") }
                    let paper = try await engine.download(reference, to: directory, naming: naming) { event in
                        switch event {
                        case .coordinating: stderr("等待其他下载任务；可用 Ctrl+C 取消。\n")
                        case .waiting(let date): stderr("等待请求至 \(date.formatted(date: .abbreviated, time: .standard))。\n")
                        case .retry(let attempt): stderr("自动重试 \(attempt)/3。\n")
                        default: break
                        }
                    }
                    result.identifier = paper.metadata.reference.identifier
                    result.status = paper.alreadyExisted ? "existing" : "saved"
                    result.path = paper.url.path
                    result.pages = paper.pages
                    if !options.json { stdout(terminalText(paper.url.path) + "\n") }
                } catch is CancellationError { result.status = "cancelled" }
                catch DownloadError.cooldown(let seconds) {
                    pause = Date().addingTimeInterval(seconds)
                    result.status = "paused"; result.retryAfter = pause
                    result.error = "arXiv 要求暂停请求，可在 \(pause!.formatted(date: .abbreviated, time: .standard)) 后重试。"
                } catch { result.error = error.localizedDescription }
                results.append(result)
            }
            if options.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(CLIReport(version: version, deduplicated: batch.duplicates, results: results))
                stdout(String(decoding: data, as: UTF8.self) + "\n")
            }
            for result in results where result.status == "failed" || result.status == "paused" {
                stderr("\(terminalText(result.input))：\(terminalText(result.error ?? "等待重试"))\n")
            }
            if results.contains(where: { $0.status == "cancelled" }) { return 130 }
            return results.allSatisfy { $0.status == "saved" || $0.status == "existing" } ? 0 : 1
        } catch {
            stderr(terminalText(error.localizedDescription) + "\n")
            return 2
        }
    }
}

private final class SignalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int32, Never>?
    private var captured: Int32?
    private var sources: [DispatchSourceSignal] = []
    // SIG_DFL is a null function pointer, which is a valid previous handler.
    private var previous: [(Int32, sig_t?)] = []
    init() {
        for number in [SIGINT, SIGTERM] {
            previous.append((number, Darwin.signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.captured = self.captured ?? number
                let task = self.task
                self.lock.unlock()
                task?.cancel()
            }
            sources.append(source); source.activate()
        }
    }
    func attach(_ task: Task<Int32, Never>) {
        lock.lock(); self.task = task; let cancelled = captured != nil; lock.unlock()
        if cancelled { task.cancel() }
    }
    var signal: Int32? { lock.lock(); defer { lock.unlock() }; return captured }
    deinit { sources.forEach { $0.cancel() }; previous.forEach { _ = Darwin.signal($0.0, $0.1) } }
}

private final class TerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func write(_ text: String, to file: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        do { try file.write(contentsOf: Data(text.utf8)) } catch { failed = true }
    }
    var failure: Bool { lock.lock(); defer { lock.unlock() }; return failed }
}

#if !TESTING
@main struct ArxivCLI {
    static func main() async {
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let output = TerminalOutput()
            if options.action == .help || options.action == .version {
                output.write(options.action == .help ? CLIOptions.help(version: BuildVersion.current) : BuildVersion.current + "\n", to: .standardOutput)
                exit(output.failure ? 1 : 0)
            }
            let cancellation = SignalCancellation()
            let preferences = DownloadPreferences.shared
            #if CLI_TESTING
            let coordinator = ProcessInfo.processInfo.environment["ARXIV_TEST_COORDINATION"].map { RequestCoordinator(directory: URL(fileURLWithPath: $0)) } ?? RequestCoordinator()
            #else
            let coordinator = RequestCoordinator()
            #endif
            let engine = DownloadEngine(cooldownPreferences: preferences, coordinator: coordinator)
            let task = Task {
                await CLIRunner.run(options, version: BuildVersion.current, engine: engine, preferences: preferences,
                    stdout: { output.write($0, to: .standardOutput) }, stderr: { output.write($0, to: .standardError) }, interactive: isatty(STDERR_FILENO) != 0)
            }
            cancellation.attach(task)
            let result = await task.value
            let code = cancellation.signal.map { 128 + $0 } ?? (output.failure ? 1 : result)
            withExtendedLifetime(cancellation) { exit(code) }
        } catch {
            fputs(CLIRunner.terminalText(error.localizedDescription) + "\n使用 --help 查看用法。\n", stderr)
            exit(2)
        }
    }
}
#endif
