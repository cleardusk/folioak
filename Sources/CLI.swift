import Foundation
import Darwin

struct CLIOptions {
    enum Action { case download, help, version }
    var action: Action = .download
    var input = ""
    var output: String?
    var naming: NamingStyle?
    var json = false
    var verbose = false
    var inputFiles: [String] = []

    static func parse(_ arguments: [String], pipedInput: Bool = false) throws -> Self {
        var options = Self()
        var inputs: [String] = []
        var index = 0
        func value(_ option: String, allowDash: Bool = false) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty, (!arguments[index].hasPrefix("-") || (allowDash && arguments[index] == "-")) else {
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
            case "--verbose": options.verbose = true
            case "-i", "--input": options.inputFiles.append(try value(argument, allowDash: true))
            case "-": options.inputFiles.append("-")
            default:
                if argument.hasPrefix("--input=") {
                    let path = String(argument.dropFirst("--input=".count))
                    guard !path.isEmpty else { throw DownloadError.limit("输入文件不能为空。") }
                    options.inputFiles.append(path)
                } else if argument.hasPrefix("--output=") {
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
        if inputs.isEmpty && options.inputFiles.isEmpty && pipedInput { options.inputFiles = ["-"] }
        guard options.inputFiles.count <= ResourceLimits.batchCount, options.inputFiles.filter({ $0 == "-" }).count <= 1 else { throw DownloadError.limit("输入文件过多或重复读取标准输入。") }
        if options.inputFiles.isEmpty { _ = try BatchInput(options.input) }
        return options
    }

    func resolvedInput() async throws -> String {
        var pieces = input.isEmpty ? [] : [input]
        var bytes = input.utf8.count
        for path in inputFiles {
            try Task.checkCancellation()
            let data: Data
            if path == "-" { data = try await Self.readStandardInput() }
            else {
                let file = try PaperStorage.boundedRegularFile(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                defer { try? file.close() }
                data = try file.read(upToCount: ResourceLimits.inputBytes + 1) ?? Data()
            }
            bytes += data.count + (pieces.isEmpty ? 0 : 1)
            guard bytes <= ResourceLimits.inputBytes else { throw DownloadError.limit("输入超过 64 KB，请分批导入。") }
            pieces.append(try PaperInput.decode(data))
        }
        return pieces.joined(separator: "\n")
    }
    static func readStandardInput(descriptor: Int32 = STDIN_FILENO) async throws -> Data {
        guard isatty(descriptor) == 0 else { throw DownloadError.limit("请通过管道或重定向提供输入。") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 0)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, pollFD.revents & Int16(POLLNVAL) == 0 else { throw DownloadError.storage("无法读取标准输入。") }
            if ready == 0 { try await Task.sleep(nanoseconds: 25_000_000); continue }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DownloadError.storage("无法读取标准输入。") }
            if count == 0 { return data }
            guard data.count + count <= ResourceLimits.inputBytes else { throw DownloadError.limit("输入超过 64 KB，请分批导入。") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func help(version: String, color: Bool = false) -> String {
        func accent(_ value: String) -> String { color ? "\u{1b}[36m\(value)\u{1b}[0m" : value }
        return """
        \(accent("arxiv-download")) \(version)
        用法  arxiv-download [LINK_OR_ID...] [选项]
        示例  arxiv-download 1706.03762 -o ~/Downloads/Papers

          \(accent("-o, --output DIR"))     保存目录，不存在时创建
          \(accent("-i, --input FILE"))     从文本文件读取，- 表示标准输入
          \(accent("--verbose"))            显示阶段与耗时
          \(accent("--naming STYLE"))       date-title / id-title / title
          \(accent("--json"))               输出 JSON
          \(accent("-h, --help"))           显示帮助
          \(accent("--version"))            显示版本

        支持 arXiv、HF 论文页、GitHub PDF 和 HTTPS PDF，最多 200 条，自动去重。
        无链接参数时自动读取管道；支持 Markdown 与混合文本。
        默认沿用 UI 的目录与命名；选项仅影响本次运行。
        重定向输出文件路径；NO_COLOR=1 关闭颜色。
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

final class CLIConsole: @unchecked Sendable {
    private let lock = NSLock()
    private let write: @Sendable (String) -> Void
    private let interactive: Bool
    private let color: Bool
    private let cursor: Bool
    private let columns: @Sendable () -> Int
    private var identifier: String
    private var lastLine = ""
    private var lastProgress = 0.0
    private var lastRetry = 0
    private var activeLine = false
    private var finished = false
    private let verbose: Bool
    private var diagnostics = TaskDiagnostics()

    init(identifier: String, interactive: Bool, color: Bool, cursor: Bool,
         columns: @escaping @Sendable () -> Int = { CLIConsole.terminalColumns() }, verbose: Bool = false, write: @escaping @Sendable (String) -> Void) {
        self.verbose = verbose
        self.identifier = identifier; self.interactive = interactive
        self.color = color && interactive; self.cursor = cursor && interactive; self.columns = columns; self.write = write
    }
    static func allowsColor(_ environment: [String: String]) -> Bool {
        environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
    }
    static func terminalColumns() -> Int {
        var size = winsize()
        return ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }
    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + cellWidth($1) }
    }
    private static func cellWidth(_ character: Character) -> Int {
        // Measure grapheme clusters so combining marks and joined emoji stay
        // intact. Wide ranges also work under the C locale used by Swift CLIs.
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }) { return 2 }
        return character.unicodeScalars.map { scalar in
            let value = scalar.value
            switch value {
            case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
                 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF01...0xFF60,
                 0xFFE0...0xFFE6, 0x1B000...0x1B2FF, 0x20000...0x3FFFD: return 2
            default:
                if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .format { return 0 }
                let measured = Int(wcwidth(Int32(value)))
                return measured >= 0 ? measured : 1
            }
        }.max() ?? 0
    }
    static func clipped(_ text: String, columns: Int) -> String {
        guard columns > 0 else { return "" }
        guard displayWidth(text) > columns else { return text }
        var result = "", used = 0
        for character in text {
            let width = cellWidth(character)
            guard used + width <= columns - 1 else { break }
            result.append(character); used += width
        }
        return result + "…"
    }
    private func styled(_ text: String, _ code: Int) -> String {
        color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
    }
    static func time(_ date: Date) -> String {
        date.formatted(date: date.timeIntervalSinceNow > 86_400 ? .abbreviated : .omitted, time: .standard)
    }
    func receive(_ event: DownloadEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let previousPhase = diagnostics.phase
        diagnostics.receive(event)
        let message: String
        switch event {
        case .coordinating: message = "等待其他下载任务"
        case .metadata: lastRetry = 0; message = "获取信息"
        case .resolved(let paper): lastRetry = 0; identifier = paper.reference.identifier; message = "准备下载"
        case .document: message = "保存完成"
        case .checkingLocal: message = "检查本地文件"
        case .validating: message = "保存中"
        case .waiting(let date): message = "等待至 \(Self.time(date))"
        case .retry(let attempt):
            guard attempt != lastRetry else { return }
            lastRetry = attempt; message = "重试 \(attempt)/3"
        case .progress(let progress):
            lastRetry = 0
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastProgress >= 0.2 else { return }
            lastProgress = now
            if let fraction = progress.fraction { message = "下载 \(Int(fraction * 100))%" }
            else { message = String(format: "下载 %.1f MB", Double(progress.received) / 1_048_576) }
        }
        if verbose && (previousPhase != diagnostics.phase || { if case .retry = event { return true }; return false }()) {
            if activeLine { write("\r\u{1b}[2K"); activeLine = false }
            write(styled(CLIRunner.terminalText(identifier), 2) + "  " + message + "\n")
        }
        let label = CLIRunner.terminalText(identifier)
        let width = max(1, columns() - 1)
        let status = Self.clipped(message, columns: max(1, width - 7))
        let compact = Self.clipped(label, columns: max(1, width - Self.displayWidth(status) - 4))
        let line = "\(compact)  \(status)"
        guard line != lastLine else { return }
        lastLine = line
        if interactive && cursor && width >= 24 {
            write("\r\u{1b}[2K" + styled("↓", 36) + " " + styled(compact, 2) + "  " + styled(status, 36))
            activeLine = true
        } else {
            if activeLine { write("\r\u{1b}[2K"); activeLine = false }
            switch event {
            case .coordinating, .waiting, .retry:
                if !verbose { write((interactive ? Self.clipped(message, columns: width) : label + "  " + message) + "\n") }
            default: break
            }
        }
    }
    func finish(_ result: CLIResult) {
        lock.lock(); defer { lock.unlock() }
        finished = true
        diagnostics.finish()
        if verbose {
            if activeLine { write("\r\u{1b}[2K"); activeLine = false }
            write("耗时 " + TaskDiagnostics.time(diagnostics.elapsed()) + " · 重试 \(diagnostics.retries) 次\n")
            let phases = TaskDiagnostics.Phase.allCases.filter { diagnostics.duration($0) >= 0.05 }
            if !phases.isEmpty { write("  " + phases.map { "\($0.label) \(TaskDiagnostics.time(diagnostics.duration($0)))" }.joined(separator: " · ") + "\n") }
        }
        guard interactive else { return }
        let symbol: String; let status: String; let tint: Int; var detail: String?
        switch result.status {
        case "saved": symbol = "✓"; status = "已保存"; tint = 32
        case "existing": symbol = "✓"; status = "已存在"; tint = 32
        case "cancelled": symbol = "–"; status = "已取消"; tint = 90
        case "paused": symbol = "◷"; status = "等待重试"; tint = 33; detail = result.retryAfter.map { "\(Self.time($0)) 后可重试" }
        default: symbol = "✕"; status = "失败"; tint = 31; detail = result.error.map(CLIRunner.terminalText)
        }
        let reference = CLIRunner.terminalText(result.identifier ?? (identifier.isEmpty ? result.input : identifier))
        let width = max(1, columns() - 1)
        let compact = Self.clipped(reference, columns: max(1, width - Self.displayWidth(status) - 4))
        let line = width >= 24 ? styled(symbol, tint) + " " + compact + "  " + styled(status, tint) : styled(symbol, tint) + " " + status
        write((activeLine ? "\r\u{1b}[2K" : "") + line + "\n")
        if width < 24 { write(reference + "\n") }
        if let detail, !detail.isEmpty { write("  " + detail + "\n") }
        activeLine = false
    }
}

enum CLIRunner {
    static func terminalText(_ text: String) -> String {
        // Retain filename joiners so displayed Unicode paths stay copyable.
        String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) && $0.value != 0x200C && $0.value != 0x200D ? " " : String($0)
        }.joined())
    }
    static func run(_ options: CLIOptions, version: String, engine: DownloadEngine, preferences: UserDefaults,
                    stdout: @escaping @Sendable (String) -> Void, stderr: @escaping @Sendable (String) -> Void,
                    interactive: Bool = false, color: Bool = false, cursor: Bool = true) async -> Int32 {
        do {
            if options.action == .help { stdout(CLIOptions.help(version: version, color: interactive && color && !options.json)); return 0 }
            if options.action == .version { stdout(version + "\n"); return 0 }
            let defaults = DownloadPreferences(preferences)
            let directory = options.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL } ?? defaults.directory
            let naming = options.naming ?? defaults.naming
            if options.verbose && options.inputFiles.contains("-") { stderr("读取标准输入\n") }
            let batch = try BatchInput(try await options.resolvedInput())
            if batch.entries.contains(where: { $0.source != nil }) {
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
            var pauses: [String: Date] = [:]
            let human = interactive && !options.json
            for entry in batch.entries {
                var result = CLIResult(input: entry.original, identifier: entry.reference?.identifier, status: "failed", error: entry.error)
                let console = CLIConsole(identifier: entry.source?.label ?? "", interactive: human, color: color, cursor: cursor, verbose: options.verbose, write: stderr)
                defer { console.finish(result) }
                guard let source = entry.source else { results.append(result); continue }
                if Task.isCancelled { result.status = "cancelled"; results.append(result); continue }
                if let pause = pauses[source.rateLimitKey] { result.status = "paused"; result.retryAfter = pause; results.append(result); continue }
                do {
                    let paper = try await engine.download(source, to: directory, naming: naming) { event in
                        console.receive(event)
                    }
                    result.identifier = paper.metadata?.reference.identifier
                    result.status = paper.alreadyExisted ? "existing" : "saved"
                    result.path = paper.url.path
                    result.pages = paper.pages
                    if !options.json && !human { stdout(terminalText(paper.url.path) + "\n") }
                } catch is CancellationError { result.status = "cancelled" }
                catch DownloadError.cooldown(let seconds) {
                    let pause = Date().addingTimeInterval(seconds)
                    pauses[source.rateLimitKey] = pause
                    result.status = "paused"; result.retryAfter = pause
                    result.error = "下载站点要求暂停请求，可在 \(pause.formatted(date: .abbreviated, time: .standard)) 后重试。"
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
            for result in results where !human && (result.status == "failed" || result.status == "paused") {
                stderr("\(terminalText(result.input))：\(terminalText(result.error ?? "等待重试"))\n")
            }
            if results.contains(where: { $0.status == "cancelled" }) { return 130 }
            return results.allSatisfy { $0.status == "saved" || $0.status == "existing" } ? 0 : 1
        } catch is CancellationError { return 130
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
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()), pipedInput: isatty(STDIN_FILENO) == 0)
            let output = TerminalOutput()
            let environment = ProcessInfo.processInfo.environment
            if options.action == .help || options.action == .version {
                output.write(options.action == .help ? CLIOptions.help(version: BuildVersion.current, color: isatty(STDOUT_FILENO) != 0 && CLIConsole.allowsColor(environment) && !options.json) : BuildVersion.current + "\n", to: .standardOutput)
                exit(output.failure ? 1 : 0)
            }
            let cancellation = SignalCancellation()
            // macOS rejects adding the current application domain as a suite.
            let preferences = DownloadPreferences.shared
            #if CLI_TESTING
            let coordinator = ProcessInfo.processInfo.environment["ARXIV_TEST_COORDINATION"].map { RequestCoordinator(directory: URL(fileURLWithPath: $0)) } ?? RequestCoordinator()
            #else
            let coordinator = RequestCoordinator()
            #endif
            let engine = DownloadEngine(cooldownPreferences: preferences, coordinator: coordinator)
            let interactive = isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0 && !options.json
            let task = Task {
                await CLIRunner.run(options, version: BuildVersion.current, engine: engine, preferences: preferences,
                    stdout: { output.write($0, to: .standardOutput) }, stderr: { output.write($0, to: .standardError) },
                    interactive: interactive, color: CLIConsole.allowsColor(environment), cursor: environment["TERM"] != "dumb")
            }
            cancellation.attach(task)
            let result = await task.value
            let code = cancellation.signal.map { 128 + $0 } ?? (output.failure ? 1 : result)
            withExtendedLifetime(cancellation) { exit(code) }
        } catch {
            let message = CLIRunner.terminalText(error.localizedDescription)
            let color = isatty(STDERR_FILENO) != 0 && CLIConsole.allowsColor(ProcessInfo.processInfo.environment)
            fputs((color ? "\u{1b}[31m✕\u{1b}[0m " : "") + message + "\n" + (message.contains("--help") ? "" : "使用 --help 查看用法。\n"), stderr)
            exit(2)
        }
    }
}
#endif
