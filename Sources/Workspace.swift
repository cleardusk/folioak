import Foundation

struct TransferSample: Codable {
    let date: Date
    let bytes: Int64
}

enum ActivityLevel: String, Codable, CaseIterable {
    case info, success, warning, error
    var label: String {
        switch self { case .info: return "信息"; case .success: return "成功"; case .warning: return "注意"; case .error: return "错误" }
    }
    var symbol: String {
        switch self { case .info: return "circle"; case .success: return "checkmark.circle"; case .warning: return "clock"; case .error: return "exclamationmark.circle" }
    }
}

struct ActivityEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    let level: ActivityLevel
    let message: String
    let subject: String?
    let itemID: UUID?

    private static let urlExpression = try! NSRegularExpression(pattern: #"https?://[^\s<>\"]+"#, options: .caseInsensitive)

    // Signed PDF query strings must not leak into exported diagnostic logs.
    static func redacted(_ value: String) -> String {
        let text = value as NSString
        var result = value
        for match in urlExpression.matches(in: value, range: NSRange(location: 0, length: text.length)).reversed() {
            let raw = text.substring(with: match.range)
            guard let range = Range(match.range, in: result) else { continue }
            guard var components = URLComponents(string: raw) else {
                result.replaceSubrange(range, with: "[链接]")
                continue
            }
            components.query = nil; components.fragment = nil; components.user = nil; components.password = nil
            result.replaceSubrange(range, with: components.string ?? "[链接]")
        }
        return String(result.prefix(2048))
    }

    var line: String {
        "\(L10n.date(date, dateStyle: .numeric)) [\(L(level.label))] \(subject.map { "\($0) · " } ?? "")\(L(message))"
    }
}

struct WorkspaceSnapshot: Codable {
    var schema = 1
    let input: String
    var items: [DownloadItem]
    var history: [DownloadItem]
    let logs: [ActivityEntry]
}

enum WorkspaceStore {
    static let byteLimit = 8 * 1024 * 1024
    static let historyLimit = 500
    static let logLimit = 1500
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DownloadPreferences.domain, isDirectory: true).appendingPathComponent("workspace.json")
    }
    static func read(_ url: URL) throws -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try PaperStorage.read(url, limit: byteLimit, tooLarge: "历史记录过大")
        var snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        guard snapshot.schema == 1, snapshot.input.utf8.count <= ResourceLimits.inputBytes,
              snapshot.items.count <= ResourceLimits.batchCount, snapshot.history.count <= historyLimit,
              snapshot.logs.count <= logLimit,
              Set(snapshot.items.map(\.id)).count == snapshot.items.count,
              Set(snapshot.history.map(\.id)).count == snapshot.history.count,
              Set(snapshot.logs.map(\.id)).count == snapshot.logs.count else { throw DownloadError.storage("历史记录格式无效") }
        // Normalize newly supported preview links before validation so older
        // queues stay readable and retry through the current download route.
        snapshot.items = snapshot.items.map(normalizedSource)
        snapshot.history = snapshot.history.map(normalizedSource)
        guard (snapshot.items + snapshot.history).allSatisfy(validItem) else { throw DownloadError.storage("历史记录格式无效") }
        return snapshot
    }
    private static func normalizedSource(_ item: DownloadItem) -> DownloadItem {
        guard item.reference == nil, let url = item.directURL,
              let source = try? DownloadSource.parse(url.absoluteString) else { return item }
        var result = item
        result.reference = source.reference
        result.directURL = source.directURL
        return result
    }
    static func validItem(_ item: DownloadItem) -> Bool {
        let references = [item.reference, item.restoreReference, item.metadata?.reference].compactMap { $0 }
        guard references.allSatisfy({ (try? ArxivReference.parse($0.identifier)) == $0 }),
              item.original.utf8.count <= ResourceLimits.inputBytes,
              item.diagnostics?.valid ?? true,
              item.metadata.map({ $0.title.count <= ResourceLimits.titleCharacters && (1...12).contains($0.month) && (1900...2199).contains($0.year) }) ?? true,
              item.documentTitle.map({ $0.count <= ResourceLimits.titleCharacters }) ?? true,
              item.savedURL.map(validFile) ?? true,
              item.additionalURLs.map({ $0.count <= 19 && $0.allSatisfy(validFile) }) ?? true,
              item.directURL.map(PublicHTTPS.allows) ?? true,
              !(item.reference != nil && item.directURL != nil) else { return false }
        return true
    }
    private static func validFile(_ url: URL) -> Bool {
        url.isFileURL && (url.pathExtension.lowercased() == "pdf" || FileStorage.extensions.contains(url.pathExtension.lowercased()))
    }

    static func export(_ data: Data, named name: String, to directory: URL) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for suffix in 0..<1000 {
            let filename = base + (suffix == 0 ? "" : "-\(suffix + 1)") + "." + ext
            let url = directory.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw DownloadError.storage("导出文件过多，请选择其他目录。")
    }

    // Keep the current queue and draft. Under byte pressure, retain the newest
    // history and log entries within a shared budget instead of losing all saves.
    @discardableResult
    static func write(_ snapshot: WorkspaceSnapshot, to url: URL) throws -> WorkspaceSnapshot {
        let encoder = JSONEncoder()
        var retained = snapshot
        // Avoid first materializing a huge JSON blob for known-oversized states.
        var textBytes = snapshot.input.utf8.count
        for item in snapshot.items + snapshot.history {
            textBytes += item.original.utf8.count
            textBytes += item.metadata?.title.utf8.count ?? 0
            textBytes += item.documentTitle?.utf8.count ?? 0
            textBytes += item.error?.utf8.count ?? 0
        }
        for entry in snapshot.logs {
            textBytes += entry.message.utf8.count
            textBytes += entry.subject?.utf8.count ?? 0
        }
        var data: Data? = textBytes <= byteLimit ? try encoder.encode(retained) : nil
        if data.map({ $0.count > byteLimit }) ?? true {
            let base = WorkspaceSnapshot(input: snapshot.input, items: snapshot.items, history: [], logs: [])
            let baseBytes = try encoder.encode(base).count
            guard baseBytes <= byteLimit else { throw DownloadError.limit("当前任务过大，历史记录未能保存。") }
            // Leave headroom so the next event does not repeat the trimming pass.
            let available = max(0, byteLimit * 3 / 4 - baseBytes)
            // Count one comma per entry; this slightly overestimates the JSON size.
            let historySizes = try snapshot.history.map { try encoder.encode($0).count + 1 }
            let logSizes = try snapshot.logs.map { try encoder.encode($0).count + 1 }
            let logBudget = min(logSizes.reduce(0, +), available / 2)
            let historyBudget = min(historySizes.reduce(0, +), available - logBudget)
            func countFitting(_ sizes: [Int], budget: Int) -> Int {
                var total = 0, count = 0
                for size in sizes {
                    guard total + size <= budget else { break }
                    total += size; count += 1
                }
                return count
            }
            let historyCount = countFitting(historySizes, budget: historyBudget)
            let usedByHistory = historySizes.prefix(historyCount).reduce(0, +)
            let logCount = countFitting(Array(logSizes.reversed()), budget: available - usedByHistory)
            retained = WorkspaceSnapshot(input: snapshot.input, items: snapshot.items,
                                         history: Array(snapshot.history.prefix(historyCount)), logs: Array(snapshot.logs.suffix(logCount)))
            data = try encoder.encode(retained)
        }
        guard let data, data.count <= byteLimit else { throw DownloadError.limit("历史记录过大") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return retained
    }
}

// Saved media has its own retention, independent of the download history.
enum MediaLibraryStore {
    struct Snapshot: Codable { var schema = 1; var items: [DownloadItem] }
    static func valid(_ item: DownloadItem) -> Bool {
        WorkspaceStore.validItem(item) && item.reference == nil && item.metadata == nil && item.source?.isPaper != true &&
        [.saved, .existing, .missing].contains(item.state) &&
        !item.localURLs.isEmpty && item.localURLs.allSatisfy { FileStorage.extensions.contains($0.pathExtension.lowercased()) }
    }
    static func read(_ url: URL) throws -> [DownloadItem]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try PaperStorage.read(url, limit: LibraryStore.byteLimit, tooLarge: "媒体库超过 32 MB。")
        let saved = try JSONDecoder().decode(Snapshot.self, from: data)
        guard saved.schema == 1, saved.items.count <= LibraryStore.countLimit,
              Set(saved.items.map(\.id)).count == saved.items.count, saved.items.allSatisfy(valid) else {
            throw DownloadError.storage("媒体库格式无效。")
        }
        return saved.items
    }
    static func write(_ items: [DownloadItem], to url: URL) throws {
        guard items.count <= LibraryStore.countLimit, Set(items.map(\.id)).count == items.count, items.allSatisfy(valid) else {
            throw DownloadError.storage("媒体库格式无效或已满，已有文件保持不变。")
        }
        let data = try JSONEncoder().encode(Snapshot(items: items))
        guard data.count <= LibraryStore.byteLimit else { throw DownloadError.limit("媒体库超过 32 MB，已有文件保持不变。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
