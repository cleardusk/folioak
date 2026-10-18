import Foundation
import Darwin

// Closed enums deliberately exclude user text, URLs, paths and credentials.
struct InteractionEvent: Codable {
    enum Action: String, Codable {
        case sessionStarted, sessionEnded, recordingDisabled, eventsDropped
        case windowShown, windowHidden, quickPanelShown, quickPanelHidden
        case inputCaptured, inputRejected, pageChanged, searchCompleted, filterChanged, displayChanged, settingChanged
        case downloadSubmitted, downloadAccepted, downloadRejected, taskQueued, taskStarted, taskPhase, taskFinished, retryRequested, cancelRequested
        case previewRequested, openRequested, revealRequested, sourceOpened
        case favoriteChanged, tagsChanged, libraryRemoved, libraryRestored, assetRenamed, filesTrashed, historyCleared, libraryImported, fileRelinked
    }
    enum Context: String, Codable { case app, mainWindow, quickPanel, downloads, documents, media, logs, settings }
    enum Trigger: String, Codable { case system, keyboard, pointer, unspecified }
    enum Outcome: String, Codable { case requested, succeeded, failed, cancelled, performed }
    enum Detail: String, Codable {
        case arxiv, pdf, file, media, unknown, list, grid, empty, nonempty
        case directory, language, appearance, theme, menuBar, naming, authentication, enabled, disabled
        case all, active, saved, failed, favorites, unread, removed, newest, title, year, tag, about, general, shortcuts
    }
    let schema: Int
    let appVersion: String
    let trigger: Trigger
    let session: UUID
    let sequence: UInt64
    let time: Date
    let elapsedMS: Double
    let action: Action
    let context: Context
    let outcome: Outcome
    let item: UUID?
    let operation: UUID?
    let attempt: UUID?
    let detail: Detail?
    let count: Int?
    let diagnostic: String?
    let durationMS: Double?
}

// Only a bounded inbox and flags use the lock. Encoding, filesystem work and
// export run on utility queues. No observable state changes for individual events.
final class InteractionTrace: @unchecked Sendable {
    struct Limits {
        var batch = 64
        var pending = 512
        var delay: Double = 2
        var segment = 1_000_000
        var total = 20_000_000
        var days: Double = 7
        var segments = 64
    }
    enum Range: String, CaseIterable { case session, today, week }
    struct ExportSummary: Codable {
        var schema = 1
        let appVersion: String
        let exportedAt: Date
        let range: String
        let eventCount: Int
        let droppedEvents: Int
        let incompleteSessions: [UUID]
        let skippedLines: Int
        let writeFailure: Bool
        let note: String
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.paperrepo.interaction-trace", qos: .utility)
    private let exportQueue = DispatchQueue(label: "local.paperrepo.interaction-export", qos: .utility)
    let directory: URL?
    let session = UUID()
    private let started = DispatchTime.now().uptimeNanoseconds
    private let limits: Limits
    private let version: String
    private var enabled = false
    private var failed = false
    private var pending: [InteractionEvent] = []
    private var sequence: UInt64 = 0
    private var dropped = 0
    private var scheduled = false
    private var urgent = false
    private var timer: DispatchSourceTimer?
    private var current: URL?
    private var currentSize = 0
    private var prepared = false
    private var segmentNumber = 0
    private var lastPrune = Date.distantPast
    var failureHandler: (@Sendable () -> Void)?
    #if TESTING
    private(set) var writeBatches = 0
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func blockWriter(_ body: @escaping () -> Void) { queue.async(execute: body) }
    #endif

    init(directory: URL?, limits: Limits = Limits(), version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") {
        self.directory = directory; self.limits = limits; self.version = version
    }
    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled && !failed }
    var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    func setEnabled(_ value: Bool) {
        if !value { record(.recordingDisabled) }
        lock.lock()
        let changed = enabled != value
        enabled = value
        if value { failed = false }
        lock.unlock()
        if value && changed { record(.sessionStarted) }
        if !value && changed { queue.async { self.drain() } }
    }
    func record(_ action: InteractionEvent.Action, context: InteractionEvent.Context = .app,
                outcome: InteractionEvent.Outcome = .performed, item: UUID? = nil, operation: UUID? = nil,
                attempt: UUID? = nil, detail: InteractionEvent.Detail? = nil, count: Int? = nil,
                diagnostic: DiagnosticMessage.ID? = nil, durationMS: Double? = nil, trigger: InteractionEvent.Trigger = .system) {
        lock.lock()
        guard enabled && !failed else { lock.unlock(); return }
        if pending.count >= limits.pending {
            if action == .taskFinished || outcome == .failed,
               let index = pending.firstIndex(where: { $0.action == .taskPhase || $0.action == .searchCompleted }) {
                pending.remove(at: index)
            } else { dropped += 1; lock.unlock(); return }
            dropped += 1
        }
        sequence += 1
        pending.append(InteractionEvent(schema: 1, appVersion: version, trigger: trigger, session: session, sequence: sequence, time: Date(),
            elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            action: action, context: context, outcome: outcome, item: item, operation: operation, attempt: attempt,
            detail: detail, count: count.map { max(0, min($0, 1_000_000)) }, diagnostic: diagnostic?.rawValue,
            durationMS: durationMS.flatMap { $0.isFinite ? max(0, $0) : nil }))
        let arm = !scheduled
        if arm { scheduled = true }
        let flush = pending.count >= limits.batch && !urgent
        if flush { urgent = true }
        lock.unlock()
        if flush { queue.async { self.drain() } }
        else if arm { queue.async { self.armTimer() } }
    }
    private func armTimer() {
        lock.lock(); let needed = scheduled && !pending.isEmpty; lock.unlock()
        guard needed, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + limits.delay)
        source.setEventHandler { [weak self] in self?.drain() }
        timer = source; source.resume()
    }
    private func takePending() -> [InteractionEvent] {
        lock.lock(); defer { lock.unlock() }
        var batch = pending
        pending = []; scheduled = false; urgent = false
        if dropped > 0 {
            sequence += 1
            batch.append(InteractionEvent(schema: 1, appVersion: version, trigger: .system, session: session, sequence: sequence, time: Date(),
                elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                action: .eventsDropped, context: .app, outcome: .performed, item: nil, operation: nil,
                attempt: nil, detail: nil, count: dropped, diagnostic: nil, durationMS: nil))
            dropped = 0
        }
        return batch
    }
    private func drain() {
        timer?.cancel(); timer = nil
        let batch = takePending()
        guard !batch.isEmpty, !hasFailed else { return }
        do {
            try prepare()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for event in batch {
                var line = try encoder.encode(event); line.append(10)
                guard line.count <= 2048 else { throw CocoaError(.fileWriteUnknown) }
                if !data.isEmpty && data.count + line.count > limits.segment {
                    try append(data); data.removeAll(keepingCapacity: true)
                }
                data.append(line)
            }
            if !data.isEmpty { try append(data) }
            if Date().timeIntervalSince(lastPrune) > 3600 { try prune() }
            #if TESTING
            writeBatches += 1
            #endif
        } catch {
            // A failed write can leave a partial segment or a removed directory.
            // Re-prepare and recount actual bytes when the user retries recording.
            current = nil; currentSize = 0; prepared = false
            lock.lock(); failed = true; lock.unlock()
            failureHandler?()
        }
    }
    private func append(_ data: Data) throws {
        if current == nil || currentSize + data.count > limits.segment {
            current = nil; currentSize = 0
            try prune(reserving: max(limits.segment, data.count))
            segmentNumber += 1
            current = directory!.appendingPathComponent("trace-\(session.uuidString)-\(segmentNumber).jsonl")
        }
        let fd = open(current!.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        currentSize += data.count
    }
    private func prepare() throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        if !prepared {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            prepared = true
            try prune()
        }
    }
    private func files() throws -> [(url: URL, size: Int, date: Date)] {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileReadNoPermission) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("trace-") && $0.pathExtension == "jsonl" }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
    }
    private func prune(reserving: Int = 0) throws {
        let entries = try files()
        var bytes = entries.reduce(0) { $0 + $1.size }
        var remaining = entries.count
        let cutoff = Date().addingTimeInterval(-limits.days * 86400)
        for entry in entries where entry.date < cutoff || bytes + reserving > limits.total || remaining + (reserving > 0 ? 1 : 0) > limits.segments {
            try FileManager.default.removeItem(at: entry.url); bytes -= entry.size; remaining -= 1
            if current == entry.url { current = nil; currentSize = 0 }
        }
        lastPrune = Date()
    }
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { self.drain(); continuation.resume() } }
    }
    private final class ExitWait: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func complete() {
            lock.lock(); let value = continuation; continuation = nil; lock.unlock()
            value?.resume()
        }
    }
    func flushBeforeExit() async {
        await withCheckedContinuation { continuation in
            let wait = ExitWait(continuation)
            queue.async { self.drain(); wait.complete() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { wait.complete() }
        }
    }
    func finish() async {
        record(.sessionEnded)
        await flush()
    }
    func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.timer?.cancel(); self.timer = nil
                _ = self.takePending()
                do {
                    for entry in try self.files() { try FileManager.default.removeItem(at: entry.url) }
                    self.current = nil; self.currentSize = 0
                    self.lock.lock(); self.failed = false; self.lock.unlock()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // Open immutable segments on the writer, then stream on a separate queue.
    // Open descriptors pin deleted files until export ends. No temporary copies
    // or crash leftovers, and at most 64 descriptors per export.
    func export(to parent: URL, range: Range) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.drain()
                var inputs: [FileHandle] = []
                do {
                    try self.prune()
                    self.current = nil; self.currentSize = 0
                    for entry in try self.files() {
                        let fd = open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
                        inputs.append(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
                    }
                    let handles = inputs
                    let failure = self.hasFailed
                    self.exportQueue.async {
                        defer { handles.forEach { try? $0.close() } }
                        do { continuation.resume(returning: try self.writeExport(inputs: handles, parent: parent, range: range, failure: failure)) }
                        catch { continuation.resume(throwing: error) }
                    }
                } catch {
                    inputs.forEach { try? $0.close() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func writeExport(inputs: [FileHandle], parent: URL, range: Range, failure: Bool) throws -> URL {
        let output = parent.appendingPathComponent("Folioak-Trace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        func writer(_ name: String) throws -> FileHandle {
            let fd = open(output.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let events = try writer("events.jsonl"), timeline = try writer("timeline.txt")
        defer { try? events.close(); try? timeline.close() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let cutoff = range == .today ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-7 * 86400)
        var count = 0, dropped = 0, skipped = 0
        var seen = Set<UUID>(), ended = Set<UUID>()
        for input in inputs {
            var buffer = Data()
            while let chunk = try input.read(upToCount: 8192), !chunk.isEmpty {
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard line.count <= 2048, let event = try? decoder.decode(InteractionEvent.self, from: line), event.schema == 1 else { skipped += 1; continue }
                    guard event.time >= cutoff, range != .session || event.session == session else { continue }
                    // Re-encode only known fields; future or tampered text is not copied.
                    guard event.appVersion.count <= 32, event.appVersion.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }), event.diagnostic == nil || DiagnosticMessage.ID(rawValue: event.diagnostic!) != nil else { skipped += 1; continue }
                    var data = try encoder.encode(event); data.append(10)
                    try events.write(contentsOf: data)
                    let text = "\(formatter.string(from: event.time)) [\(event.session.uuidString.prefix(8)) #\(event.sequence)] \(event.context.rawValue) \(event.action.rawValue) \(event.outcome.rawValue)\(event.detail.map { " " + $0.rawValue } ?? "")\(event.item.map { " item=" + $0.uuidString } ?? "")\(event.count.map { " count=" + String($0) } ?? "")\(event.diagnostic.map { " " + $0 } ?? "")\(event.durationMS.map { " duration_ms=" + String(format: "%.1f", $0) } ?? "")\n"
                    try timeline.write(contentsOf: Data(text.utf8))
                    count += 1; seen.insert(event.session)
                    if event.action == .sessionEnded || event.action == .recordingDisabled { ended.insert(event.session) }
                    if event.action == .sessionStarted { ended.remove(event.session) }
                    if event.action == .eventsDropped { dropped += event.count ?? 0 }
                }
                if buffer.count > 2048 { skipped += 1; buffer.removeAll() }
            }
            if !buffer.isEmpty { skipped += 1 }
        }
        let summary = ExportSummary(appVersion: version, exportedAt: now, range: range.rawValue, eventCount: count,
            droppedEvents: dropped, incompleteSessions: Array(seen.subtracting(ended)), skippedLines: skipped, writeFailure: failure,
            note: "Local semantic events only. Retention may omit session boundaries. An open session or missing end marker does not establish a crash. Forced termination can lose buffered events.")
        let metadata = try writer("metadata.json"); defer { try? metadata.close() }
        try metadata.write(contentsOf: encoder.encode(summary))
        complete = true
        return output
    }
}
