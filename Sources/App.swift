import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// Use the property wrapper; the latest SDK also exports a State macro that the
// standalone Command Line Tools compiler cannot load.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum UIColors {
    static let success = adaptive(light: (0.08, 0.43, 0.22), dark: (0.30, 0.85, 0.43))
    static let error = adaptive(light: (0.70, 0.12, 0.09), dark: (1, 0.42, 0.42))
    static let warning = adaptive(light: (0.51, 0.33, 0.06), dark: (0.94, 0.72, 0.31))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var native: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

enum ItemState: Equatable, Codable {
    case queued, coordinating, metadata, checkingLocal, downloading, validating, retrying(Int), waiting(Date), paused, saved, existing, failed, cancelled, missing
    var terminal: Bool {
        switch self { case .saved, .existing, .failed, .cancelled, .missing, .paused: return true; default: return false }
    }
    var message: DiagnosticMessage {
        switch self {
        case .queued: return DiagnosticMessage(.queued)
        case .coordinating: return DiagnosticMessage(.coordinating)
        case .metadata: return DiagnosticMessage(.fetchingMetadata)
        case .checkingLocal: return DiagnosticMessage(.checkingLocal)
        case .downloading: return DiagnosticMessage(.downloading)
        case .validating: return DiagnosticMessage(.validating)
        case .retrying(let attempt): return DiagnosticMessage(.retrying, String(attempt))
        case .waiting(let date): return DiagnosticMessage(.waiting, L10n.date(date, dateStyle: .omitted))
        case .paused: return DiagnosticMessage(.paused)
        case .saved: return DiagnosticMessage(.saved)
        case .existing: return DiagnosticMessage(.existing)
        case .failed: return DiagnosticMessage(.failed)
        case .cancelled: return DiagnosticMessage(.cancelled)
        case .missing: return DiagnosticMessage(.missing)
        }
    }
    var label: String { message.fallback }
    func color(_ palette: ThemePalette) -> Color {
        switch self {
        case .saved, .existing: return UIColors.success
        case .failed, .missing: return UIColors.error
        case .metadata, .checkingLocal, .downloading, .validating, .retrying: return ThemePalette.color(palette.accent)
        default: return ThemePalette.color(palette.secondary)
        }
    }
    var symbol: String {
        switch self {
        case .saved, .existing: return "checkmark.circle.fill"
        case .failed, .missing: return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .waiting, .paused, .coordinating: return "clock"
        default: return "circle.dotted"
        }
    }
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    let original: String
    var reference: ArxivReference?
    var directURL: URL? = nil
    var restoreReference: ArxivReference?
    var metadata: PaperMetadata?
    var state: ItemState
    var progress: DownloadProgress?
    var error: String? { didSet { errorMessage = nil } }
    var errorMessage: DiagnosticMessage? = nil
    var savedURL: URL?
    var pages: Int?
    var documentTitle: String?
    var createdAt = Date()
    var finishedAt: Date?
    var bytesPerSecond: Double?
    var transferSample: TransferSample?
    var diagnostics: TaskDiagnostics?
    var mediaFormat: MediaFormat? = nil
    var additionalURLs: [URL]? = nil
    var incompleteFileList: Bool? = nil
    // Optional so records written before library removal remain decodable.
    var libraryRemovedAt: Date? = nil
    var preservesInput: Bool? = nil
    var namingSnapshot: AssetNamingSnapshot? = nil
    var origin: DownloadOrigin? = nil
    var provenance: DownloadOrigin? { origin ?? DownloadOrigin.recovered(original, source: source) }
    var isLibraryRemoved: Bool { libraryRemovedAt != nil }
    var localURLs: [URL] { (savedURL.map { [$0] } ?? []) + (additionalURLs ?? []) }
    var source: DownloadSource? {
        if let reference { return .arxiv(reference) }
        guard let directURL else { return nil }
        let parsed = try? DownloadSource.parse(directURL.absoluteString)
        if parsed?.isMedia != true, let savedURL {
            if savedURL.pathExtension.lowercased() == "pdf" { return .pdf(directURL) }
            if FileStorage.extensions.union(GenericFileStorage.extensions).contains(savedURL.pathExtension.lowercased()) { return .file(directURL) }
        }
        return parsed
    }
    var symbol: String {
        if let savedURL {
            let ext = savedURL.pathExtension.lowercased()
            if ext == "pdf" { return "doc.text" }
            if GenericFileStorage.extensions.contains(ext) { return GenericFileStorage.symbol(ext) }
            if FileStorage.imageExtensions.contains(ext) { return "photo" }
            return FileStorage.videoExtensions.contains(ext) ? "play.rectangle" : "waveform"
        }
        return mediaFormat == .audio && source?.isMedia == true ? "waveform" : source?.symbol ?? "doc"
    }
    var title: String { documentTitle ?? metadata?.title ?? source?.label ?? original }
    var canRetry: Bool { source != nil && (state == .failed || state == .cancelled || state == .missing || state == .paused) }
    var localizedError: String? { errorMessage.map(L10n.text) ?? error.map(L) }
    mutating func setError(_ message: DiagnosticMessage) {
        error = message.fallback
        errorMessage = message
    }
}

enum LibraryCollection { case documents, media }
enum RecordCollection { case downloads, documents, media }

struct LibraryRemovalUndo {
    let collection: LibraryCollection
    let ids: Set<UUID>
    let removed: Bool
}

struct FileTrashRequest: Identifiable {
    let id = UUID()
    let collection: RecordCollection
    let ids: Set<UUID>
    let files: [URL]
    var existingFiles: [URL] { files.filter { FileManager.default.fileExists(atPath: $0.path) } }
    var confirmationMessage: String {
        collection == .downloads
            ? "成功移到废纸篓后，同时清除对应下载记录。资料库条目会保留并标记文件缺失，可从 Finder 废纸篓找回文件。"
            : "下载记录和资料库条目会保留，并更新文件状态。恢复库条目不会恢复文件，可从 Finder 废纸篓找回文件。"
    }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var input = "" {
        didSet {
            if input.utf8.count > ResourceLimits.inputBytes {
                input = oldValue
                notice = "输入超过 64 KB，请分批粘贴。"
            }
            workspaceRevision += 1
            schedulePersistence()
        }
    }
    @Published var directory: URL {
        didSet { preferences.set(directory.path, forKey: "downloadRootDirectory"); directoryNotice = nil; traceSetting(.directory) }
    }
    @Published var pdfDirectory: URL? {
        didSet {
            if let pdfDirectory { preferences.set(pdfDirectory.path, forKey: "pdfDownloadDirectory") }
            else { preferences.removeObject(forKey: "pdfDownloadDirectory") }
            directoryNotice = nil; traceSetting(.directory)
        }
    }
    @Published var usesPDFDirectory: Bool {
        didSet { preferences.set(usesPDFDirectory, forKey: "usesPDFDownloadDirectory"); directoryNotice = nil; traceSetting(.directory) }
    }
    var activePDFDirectory: URL? { usesPDFDirectory ? pdfDirectory : nil }
    var pdfDirectoryLabel: String { pdfDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "" }

    var directoryLabel: String { (directory.path as NSString).abbreviatingWithTildeInPath }
    var directoryExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func prepareDefaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard directory.standardizedFileURL.path == home.appendingPathComponent("Downloads/Folioak").standardizedFileURL.path else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            directoryNotice = "无法创建默认保存位置，请选择其他文件夹。"
        }
    }

    @Published var documentDisplayMode: LibraryDisplayMode {
        didSet { preferences.set(documentDisplayMode.rawValue, forKey: "documentDisplayMode"); trace.user(.displayChanged, context: .documents, detail: documentDisplayMode == .grid ? .grid : .list) }
    }
    @Published var mediaDisplayMode: LibraryDisplayMode {
        didSet { preferences.set(mediaDisplayMode.rawValue, forKey: "mediaDisplayMode"); trace.user(.displayChanged, context: .media, detail: mediaDisplayMode == .grid ? .grid : .list) }
    }
    @Published var namingRules: AssetNamingRules {
        didSet { if namingRules.valid, let data = try? JSONEncoder().encode(namingRules) { preferences.set(data, forKey: AssetNamingRules.preferenceKey); traceSetting(.naming) } }
    }
    @Published var naming: NamingStyle {
        didSet { preferences.set(naming.rawValue, forKey: "namingStyle"); traceSetting(.naming) }
    }
    @Published var appearance: AppAppearance {
        didSet { preferences.set(appearance.rawValue, forKey: "appearance"); applyAppearance(); traceSetting(.appearance) }
    }
    @Published var theme: AppTheme {
        didSet { preferences.set(theme.rawValue, forKey: "theme"); traceSetting(.theme) }
    }
    @Published var language: AppLanguage {
        didSet { preferences.set(language.rawValue, forKey: "language"); AppLocalization.shared.language = language; traceSetting(.language) }
    }
    @Published var showsMenuBarIcon: Bool {
        didSet { preferences.set(showsMenuBarIcon, forKey: "showsMenuBarIcon"); traceSetting(.menuBar) }
    }
    @Published private(set) var libraryUndo: LibraryRemovalUndo?
    @Published private(set) var recordAnimation = UUID()
    @Published var pendingFileTrash: FileTrashRequest?
    @Published var renamingAsset: AssetRenameRequest?
    @Published var assetRenameError: String?
    @Published private(set) var assetRenameInProgress = false
    @Published var items: [DownloadItem] = [] { didSet { workspaceRevision += 1 } }
    @Published var mediaFormat: MediaFormat = .automatic
    @Published var history: [DownloadItem] = [] { didSet { workspaceRevision += 1 } }
    @Published var mediaLibrary: [DownloadItem] = [] { didSet { mediaLibraryRevision += 1; mediaLibraryDirty = true; schedulePersistence() } }
    @Published var mediaLibraryNotice: String?
    private(set) var mediaLibraryWritable = true
    private var mediaLibraryDirty = false
    @Published var papers: [LibraryPaper] = [] { didSet { libraryRevision += 1; libraryDirty = true; schedulePersistence() } }
    @Published var libraryNotice: String?
    @Published var importingPDFs = false
    @Published var checkingVersions = Set<UUID>()
    var versionWorker: Task<Void, Never>?
    @Published var logs: [ActivityEntry] = [] { didSet { workspaceRevision += 1 } }
    @Published var persistenceNotice: String?
    @Published var batchID = UUID()
    @Published var busy = false
    @Published var cancelling = false
    @Published var notice: String?
    @Published var directoryNotice: String?
    @Published var duplicateCount = 0
    @Published var editRequest = UUID()
    @Published var listRequest = UUID()
    @Published var searchRequest = UUID()
    @Published private(set) var fileRefreshRevision = 0
    #if TESTING
    private(set) var fileRefreshPathResolutions = 0
    #endif
    @Published var previewURL: URL?
    @Published var diagnosticItem: DownloadItem?
    let shortcuts: ShortcutSettings
    let browserAuthentication: BrowserAuthenticationSettings
    let updates: UpdateChecker
    let traceSettings: InteractionTraceSettings
    private var traceAttempts: [UUID: (id: UUID, start: UInt64)] = [:]
    @Published var settingsTab = "通用"
    @Published var navigation = WorkspaceNavigation()
    var preferencesPage: WorkspacePreferencesPage? {
        get { navigation.current.preferences }
        set { navigation.visit(WorkspaceRoute(page: navigation.current.page, preferences: newValue)) }
    }
    private(set) var editTarget = ""
    let engine: DownloadEngine
    private let preferences: UserDefaults
    let opener: (URL) -> Bool
    private let revealer: ([URL]) -> Void
    private let recycleFile: (URL) throws -> Void
    private var worker: Task<Void, Never>?
    private var runID = UUID()
    private var sourceCooldowns: [String: Date] = [:]
    private var runSuccesses = 0
    private var runFailures = 0
    private let persistence: WorkspacePersistence?
    private var stateURL: URL? { persistence?.stateURL }
    private var saveWork: DispatchWorkItem?
    private var workspaceRevision = 0
    private(set) var libraryRevision = 0
    let libraryQueries = LibraryQueryCache()
    private(set) var mediaLibraryRevision = 0
    private var persistenceSequence = 0
    private var appliedPersistenceSequence = 0
    private var savingWorkspace = false
    private var pendingWorkspaceSave = false
    private var persistenceReady = false
    private var activePanel: NSOpenPanel?
    @Published private(set) var libraryMutationInProgress = false
    private var libraryMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var libraryDirty = false
    private(set) var libraryWritable = true
    private var shortcutChanges: AnyCancellable?
    private var libraryURL: URL? { persistence?.libraryURL }

    init(engine: DownloadEngine? = nil, preferences: UserDefaults = DownloadPreferences.shared, opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, stateURL: URL? = nil, recycleFile: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }, updates: UpdateChecker? = nil, revealer: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }) {
        let authenticationSettings = BrowserAuthenticationSettings(preferences)
        browserAuthentication = authenticationSettings
        self.updates = updates ?? UpdateChecker(preferences: preferences)
        self.engine = engine ?? DownloadEngine(cooldownPreferences: preferences, coordinator: RequestCoordinator(),
            mediaAuthentication: { try await authenticationSettings.activeSelection() })
        self.preferences = preferences
        shortcuts = ShortcutSettings(preferences)
        self.opener = opener
        self.revealer = revealer
        self.recycleFile = recycleFile
        persistence = stateURL.map(WorkspacePersistence.init)
        traceSettings = InteractionTraceSettings(preferences: preferences, recorder: InteractionTrace(directory: stateURL.map { $0.deletingLastPathComponent().appendingPathComponent("interaction-traces") }))
        let downloadPreferences = DownloadPreferences(preferences)
        documentDisplayMode = LibraryDisplayMode(rawValue: preferences.string(forKey: "documentDisplayMode") ?? "") ?? .list
        mediaDisplayMode = LibraryDisplayMode(rawValue: preferences.string(forKey: "mediaDisplayMode") ?? "") ?? .list
        namingRules = downloadPreferences.namingRules
        naming = downloadPreferences.naming
        appearance = AppAppearance(rawValue: preferences.string(forKey: "appearance") ?? "") ?? .system
        theme = AppTheme(rawValue: preferences.string(forKey: "theme") ?? "graphite") ?? .native
        language = AppLanguage(rawValue: preferences.string(forKey: "language") ?? "") ?? .system
        showsMenuBarIcon = preferences.object(forKey: "showsMenuBarIcon") as? Bool ?? true
        directory = downloadPreferences.directory
        pdfDirectory = downloadPreferences.pdfDirectory
        usesPDFDirectory = downloadPreferences.usesPDFDirectory
        if preferences.string(forKey: "downloadRootDirectory") == nil {
            preferences.set(directory.path, forKey: "downloadRootDirectory")
        }
        restoreWorkspace()
        restoreLibrary()
        restoreMediaLibrary()
        persistenceReady = true
        persistLibrary()
        persistMediaLibrary()
        shortcutChanges = shortcuts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var library: [DownloadItem] { papers.filter { !$0.removed }.sorted { $0.addedAt > $1.addedAt }.map(\.downloadItem) }
    var downloads: [DownloadItem] {
        let current = Set(items.map(\.id))
        return items + history.filter { !current.contains($0.id) }
    }
    var canClearDownloadRecords: Bool { !busy && !libraryMutationInProgress && (!items.isEmpty || !history.isEmpty) }

    func clearDownloadRecords() {
        guard canClearDownloadRecords, replaceDownloadRecords(items: [], history: []) else { return }
        trace.record(.historyCleared, context: .downloads, outcome: .succeeded)
        recordAnimation = UUID()
        duplicateCount = 0; batchID = UUID()
    }

    func clearDownloadRecord(_ id: UUID) {
        guard !busy, !libraryMutationInProgress, downloads.contains(where: { $0.id == id }) else { return }
        if replaceDownloadRecords(items: items.filter { $0.id != id }, history: history.filter { $0.id != id }) {
            recordAnimation = UUID()
            trace.record(.historyCleared, context: .downloads, outcome: .succeeded, item: id, count: 1)
            if diagnosticItem?.id == id { diagnosticItem = nil }
        }
    }

    func canManageLibrary(_ collection: LibraryCollection) -> Bool {
        !busy && !libraryMutationInProgress && (collection == .documents ? libraryWritable && !importingPDFs : mediaLibraryWritable)
    }

    func canRenameAsset(_ id: UUID, in collection: LibraryCollection) -> Bool {
        guard canManageLibrary(collection), !importingPDFs, checkingVersions.isEmpty, versionWorker == nil else { return false }
        let files: [URL]
        switch collection {
        case .documents:
            guard let paper = papers.first(where: { $0.id == id }), !paper.removed, !paper.missing,
                  let file = paper.file else { return false }
            files = [file]
        case .media:
            guard let item = mediaLibrary.first(where: { $0.id == id }), !item.isLibraryRemoved,
                  item.state != .missing, item.incompleteFileList != true else { return false }
            files = item.localURLs
        }
        guard !files.isEmpty, files.allSatisfy(AssetRename.writableFile) else { return false }
        // A shared file can be referenced from either catalog; neither may be read-only.
        if !libraryWritable || !mediaLibraryWritable {
            let matches = files.map(AssetRenamePaths.init)
            if !libraryWritable, papers.contains(where: { $0.file.map { file in matches.contains { $0.contains(file) } } == true }) { return false }
            if !mediaLibraryWritable, mediaLibrary.contains(where: { $0.localURLs.contains { file in matches.contains { $0.contains(file) } } }) { return false }
        }
        return true
    }

    func requestAssetRename(_ id: UUID, in collection: LibraryCollection) {
        guard canRenameAsset(id, in: collection) else { return }
        let files = collection == .documents ? papers.first(where: { $0.id == id })?.file.map { [$0] } ?? [] : mediaLibrary.first(where: { $0.id == id })?.localURLs ?? []
        assetRenameError = nil
        renamingAsset = AssetRenameRequest(id: id, collection: collection, files: files)
    }

    @discardableResult
    func renameAsset(_ request: AssetRenameRequest, file: URL, to basename: String) async -> Bool {
        let operation = trace.isEnabled ? UUID() : nil
        var succeeded = false
        trace.user(.assetRenamed, outcome: .requested, item: request.id, operation: operation)
        defer { trace.record(.assetRenamed, outcome: succeeded ? .succeeded : .failed, item: request.id, operation: operation) }
        guard canRenameAsset(request.id, in: request.collection) else {
            assetRenameError = "当前无法重命名，请确认文件存在且资料库可写。"; return false
        }
        let currentFiles = request.collection == .documents ? papers.first(where: { $0.id == request.id })?.file.map { [$0] } ?? [] : mediaLibrary.first(where: { $0.id == request.id })?.localURLs ?? []
        guard request.files.contains(file), currentFiles.contains(file) else { assetRenameError = "文件位置已改变，请重新打开重命名。"; return false }
        libraryMutationInProgress = true; assetRenameInProgress = true
        saveWork?.cancel(); saveWork = nil
        defer {
            libraryMutationInProgress = false; assetRenameInProgress = false
            let waiters = libraryMutationWaiters; libraryMutationWaiters.removeAll(); waiters.forEach { $0.resume() }
            saveWorkspace()
        }
        do {
            let destination = try AssetRename.destination(for: file, basename: basename)
            let paths = AssetRenamePaths(file)
            let renamedItems = items.map { AssetRename.replacing($0, paths: paths, new: destination) }
            let renamedHistory = history.map { AssetRename.replacing($0, paths: paths, new: destination) }
            let renamedPapers = papers.map { AssetRename.replacing($0, paths: paths, new: destination) }
            let renamedMedia = mediaLibrary.map { AssetRename.replacing($0, paths: paths, new: destination) }
            if let persistence {
                try persistence.prepareForSaving()
                let snapshot = WorkspaceSnapshot(input: input, items: renamedItems, history: renamedHistory, logs: logs)
                try await persistence.commitAssetRename(from: file, to: destination, snapshot: snapshot,
                    papers: libraryWritable ? renamedPapers : nil, media: mediaLibraryWritable ? renamedMedia : nil)
                // Invalidate completions from saves queued before this transaction.
                persistenceSequence += 1; appliedPersistenceSequence = persistenceSequence
            } else {
                if file.standardizedFileURL != destination.standardizedFileURL { try AssetRename.move(file, to: destination) }
            }
            // Merge paths into the latest values so unrelated input, logs and metadata survive the await.
            items = items.map { AssetRename.replacing($0, paths: paths, new: destination) }
            history = history.map { AssetRename.replacing($0, paths: paths, new: destination) }
            papers = papers.map { AssetRename.replacing($0, paths: paths, new: destination) }
            mediaLibrary = mediaLibrary.map { AssetRename.replacing($0, paths: paths, new: destination) }
            if previewURL.map(paths.contains) == true { previewURL = destination }
            if let diagnosticItem { self.diagnosticItem = AssetRename.replacing(diagnosticItem, paths: paths, new: destination) }
            assetRenameError = nil; notice = nil; fileRefreshRevision += 1
            renamingAsset = nil
            succeeded = true
            return true
        } catch {
            assetRenameError = "重命名未完成：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setLibraryRemoved(_ ids: Set<UUID>, in collection: LibraryCollection, removed: Bool) async -> Bool {
        await changeLibraryRemoval(ids, in: collection, removed: removed, registerUndo: true)
    }

    private func changeLibraryRemoval(_ ids: Set<UUID>, in collection: LibraryCollection, removed: Bool, registerUndo: Bool) async -> Bool {
        let operation = trace.isEnabled ? UUID() : nil
        var succeeded = false
        let context: InteractionEvent.Context = collection == .documents ? .documents : .media
        trace.user(removed ? .libraryRemoved : .libraryRestored, context: context, outcome: .requested, operation: operation, count: ids.count)
        defer { trace.record(removed ? .libraryRemoved : .libraryRestored, context: context, outcome: succeeded ? .succeeded : .failed, operation: operation, count: ids.count) }
        guard canManageLibrary(collection) else {
            notice = busy ? "下载结束后可整理资料库。" : "资料库当前无法修改，原记录已保留。"
            return false
        }
        libraryMutationInProgress = true
        saveWork?.cancel(); saveWork = nil
        defer {
            libraryMutationInProgress = false
            let waiters = libraryMutationWaiters; libraryMutationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            saveWorkspace()
        }
        do {
            let changed: Set<UUID>
            switch collection {
            case .documents:
                let revision = libraryRevision
                var updated = papers
                changed = Set(updated.filter { ids.contains($0.id) && $0.removed != removed }.map(\.id))
                guard !changed.isEmpty else { return false }
                for i in updated.indices where changed.contains(updated[i].id) {
                    updated[i].removed = removed
                }
                let before = Dictionary(papers.filter { changed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                if !removed {
                    let snapshot = updated
                    updated = await Task.detached(priority: .userInitiated) {
                        var checked = snapshot
                        for i in checked.indices where changed.contains(checked[i].id) {
                            checked[i].missing = checked[i].file.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
                        }
                        return checked
                    }.value
                }
                // The serial writer drains older saves before this commit. Publish
                // only after it succeeds; revision checks reject late completions.
                try await persistence?.commitLibrary(updated)
                let unchanged = revision == libraryRevision
                if unchanged { papers = updated; libraryDirty = false }
                else {
                    // Preserve newer metadata/relinks while merging the fields
                    // this transaction checked. Unrelated edits must not discard
                    // a successful missing-file recovery.
                    let checked = Dictionary(updated.filter { changed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    var merged = papers
                    for i in merged.indices where changed.contains(merged[i].id) {
                        merged[i].removed = removed
                        if !removed, let original = before[merged[i].id], let saved = checked[merged[i].id],
                           merged[i].file == original.file, merged[i].missing == original.missing {
                            merged[i].missing = saved.missing
                        }
                    }
                    papers = merged
                }
                libraryNotice = nil
            case .media:
                let revision = mediaLibraryRevision
                var updated = mediaLibrary
                changed = Set(updated.filter { ids.contains($0.id) && $0.isLibraryRemoved != removed }.map(\.id))
                guard !changed.isEmpty else { return false }
                let date = removed ? Date() : nil
                let before = Dictionary(mediaLibrary.filter { changed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                for i in updated.indices where changed.contains(updated[i].id) { updated[i].libraryRemovedAt = date }
                if !removed {
                    let snapshot = updated
                    updated = await Task.detached(priority: .userInitiated) {
                        var checked = snapshot
                        for i in checked.indices where changed.contains(checked[i].id) {
                            let complete = checked[i].incompleteFileList != true && !checked[i].localURLs.isEmpty &&
                                checked[i].localURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                            if !complete {
                                checked[i].state = .missing; checked[i].error = "部分或全部文件已不在原位置，可重新下载。"
                            } else if checked[i].state == .missing {
                                checked[i].state = .saved; checked[i].error = nil
                            }
                        }
                        return checked
                    }.value
                }
                try await persistence?.commitMediaLibrary(updated)
                if revision == mediaLibraryRevision { mediaLibrary = updated; mediaLibraryDirty = false }
                else {
                    let checked = Dictionary(updated.filter { changed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    var merged = mediaLibrary
                    for i in merged.indices where changed.contains(merged[i].id) {
                        merged[i].libraryRemovedAt = date
                        if !removed, let original = before[merged[i].id], let saved = checked[merged[i].id],
                           merged[i].localURLs == original.localURLs, merged[i].state == original.state,
                           merged[i].incompleteFileList == original.incompleteFileList {
                            merged[i].state = saved.state; merged[i].error = saved.error
                        }
                    }
                    mediaLibrary = merged
                }
                mediaLibraryNotice = nil
            }
            recordAnimation = UUID()
            if registerUndo { libraryUndo = LibraryRemovalUndo(collection: collection, ids: changed, removed: removed) }
            succeeded = true
            notice = nil
            return true
        } catch {
            notice = "资料库修改未能保存，原记录已保留：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func undoLibraryRemoval() async -> Bool {
        guard let undo = libraryUndo,
              await changeLibraryRemoval(undo.ids, in: undo.collection, removed: !undo.removed, registerUndo: false) else { return false }
        libraryUndo = nil
        return true
    }

    func waitForLibraryMutation() async {
        if libraryMutationInProgress {
            await withCheckedContinuation { libraryMutationWaiters.append($0) }
        }
    }

    private func sameMediaSave(_ lhs: DownloadItem, _ rhs: DownloadItem) -> Bool {
        lhs.finishedAt != nil && lhs.original == rhs.original && lhs.createdAt == rhs.createdAt &&
            lhs.finishedAt == rhs.finishedAt && lhs.mediaFormat == rhs.mediaFormat
    }

    private func filesForRecords(_ ids: Set<UUID>, in collection: RecordCollection) -> Set<URL> {
        switch collection {
        case .documents:
            return Set(papers.filter { ids.contains($0.id) }.compactMap(\.file).map(fileLocation))
        case .media:
            return Set(mediaLibrary.filter { ids.contains($0.id) }.flatMap(\.localURLs).map(fileLocation))
        case .downloads:
            let records = downloads.filter { ids.contains($0.id) }
            var retained = mediaLibrary.filter { ids.contains($0.id) }
            for record in records {
                let copies = mediaLibrary.filter { $0.incompleteFileList != true && sameMediaSave(record, $0) }
                if copies.count == 1 { retained += copies }
            }
            return Set((records + retained).flatMap(\.localURLs).map(fileLocation))
        }
    }

    func canTrashFiles(_ ids: Set<UUID>, in collection: RecordCollection) -> Bool {
        !busy && !libraryMutationInProgress && (stateURL == nil || (libraryWritable && mediaLibraryWritable)) &&
            filesForRecords(ids, in: collection).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func requestFileTrash(_ ids: Set<UUID>, in collection: RecordCollection) {
        guard !busy else { return }
        let files = filesForRecords(ids, in: collection).sorted { $0.path < $1.path }
        guard files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            notice = "没有可移到废纸篓的文件。"; return
        }
        pendingFileTrash = FileTrashRequest(collection: collection, ids: ids, files: files)
    }

    @discardableResult
    func confirmFileTrash(_ request: FileTrashRequest) -> Bool {
        let operation = trace.isEnabled ? UUID() : nil
        var succeeded = false
        trace.user(.filesTrashed, outcome: .requested, operation: operation, count: request.files.count)
        defer { trace.record(.filesTrashed, outcome: succeeded ? .succeeded : .failed, operation: operation, count: request.files.count) }
        guard !busy, !libraryMutationInProgress, pendingFileTrash?.id == request.id else { return false }
        defer { if pendingFileTrash?.id == request.id { pendingFileTrash = nil } }
        let files = Set(request.files)
        guard files == filesForRecords(request.ids, in: request.collection), !files.isEmpty else {
            notice = "文件位置已变化，请重新选择。"; return false
        }
        // Keep all recovery records durable before moving any file.
        persistWorkspace()
        guard stateURL == nil || (libraryWritable && mediaLibraryWritable && !libraryDirty && !mediaLibraryDirty && persistenceNotice == nil) else {
            notice = "资料库或下载记录尚未保存，文件和记录均保留。"; return false
        }
        do {
            let existing = try request.files.filter { url in
                guard url.isFileURL else { throw DownloadError.storage("只可移除普通下载文件。") }
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
                catch {
                    if !FileManager.default.fileExists(atPath: url.path) { return false }
                    throw error
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw DownloadError.storage("只可移除普通下载文件。")
                }
                return true
            }
            for file in existing { try recycleFile(file) }
            refreshMissingFiles(files)
            if request.collection == .downloads {
                let clearedIDs = Set(downloads.filter { request.ids.contains($0.id) }.map(\.id))
                // Save updated libraries before atomically replacing download
                // records; a failed save keeps the recovery rows visible.
                guard replaceDownloadRecords(items: items.filter { !clearedIDs.contains($0.id) },
                                             history: history.filter { !clearedIDs.contains($0.id) }) else { return false }
                recordAnimation = UUID()
                if let diagnosticItem, clearedIDs.contains(diagnosticItem.id) { self.diagnosticItem = nil }
                for id in clearedIDs {
                    trace.record(.historyCleared, context: .downloads, outcome: .succeeded, item: id, operation: operation, count: 1)
                }
                succeeded = true
                return true
            }
            persistWorkspace()
            if persistenceNotice == nil && libraryNotice == nil && mediaLibraryNotice == nil { notice = nil }
            succeeded = persistenceNotice == nil && libraryNotice == nil && mediaLibraryNotice == nil
            return succeeded
        } catch {
            refreshMissingFiles(files)
            persistWorkspace()
            notice = "未能移除全部文件，记录已保留：\(error.localizedDescription)"
            return false
        }
    }

    private func fileLocation(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        // Resolve only the parent: the key stays stable after moving the file,
        // and a final-component symlink remains visible to the safety check.
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }

    private func refreshMissingFiles(_ files: Set<URL>) {
        fileRefreshRevision += 1
        #if TESTING
        fileRefreshPathResolutions = 0
        #endif
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard !missing.isEmpty else { return }
        let names = Set(missing.map(\.lastPathComponent))
        var parents: [URL: URL] = [:]
        func affected(_ url: URL) -> Bool {
            // Most records cannot share a removed file. Avoid a filesystem walk
            // for every library row, and resolve each matching parent just once.
            guard url.isFileURL, names.contains(url.lastPathComponent) else { return false }
            let parent = url.deletingLastPathComponent()
            let resolved: URL
            if let cached = parents[parent] { resolved = cached }
            else {
                resolved = parent.resolvingSymlinksInPath(); parents[parent] = resolved
                #if TESTING
                fileRefreshPathResolutions += 1
                #endif
            }
            return missing.contains(resolved.appendingPathComponent(url.lastPathComponent))
        }
        func affected(_ item: DownloadItem) -> Bool { item.localURLs.contains(where: affected) }
        func mark(_ item: inout DownloadItem) {
            if item.state != .missing && item.incompleteFileList == nil { item.incompleteFileList = false }
            item.state = .missing
            item.restoreReference = item.metadata?.reference
            item.error = item.localURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
                ? "部分文件已不在原位置，仍可打开其余文件，或重新下载。" : "原位置的文件不存在，可重新下载。"
        }
        func refreshed(_ records: [DownloadItem]) -> [DownloadItem]? {
            var result = records, changed = false
            for i in records.indices where affected(records[i]) { mark(&result[i]); changed = true }
            return changed ? result : nil
        }
        if let updated = refreshed(items) { items = updated }
        if let updated = refreshed(history) { history = updated }
        if let updated = refreshed(mediaLibrary) { mediaLibrary = updated }
        var updatedPapers = papers, papersChanged = false
        for i in papers.indices where !papers[i].missing && papers[i].file.map(affected) == true {
            updatedPapers[i].missing = true; papersChanged = true
        }
        if papersChanged { papers = updatedPapers }
        if let previewURL, affected(previewURL) { self.previewURL = nil }
    }

    @discardableResult
    private func replaceDownloadRecords(items remainingItems: [DownloadItem], history remainingHistory: [DownloadItem]) -> Bool {
        saveWork?.cancel(); saveWork = nil
        pendingWorkspaceSave = false
        persistenceSequence += 1; appliedPersistenceSequence = persistenceSequence
        // Save independently retained libraries before discarding recovery records.
        persistLibrary(); persistMediaLibrary()
        guard stateURL == nil || (!libraryDirty && !mediaLibraryDirty) else {
            notice = libraryNotice ?? mediaLibraryNotice ?? "资料库尚未保存，下载记录未清空。"
            return false
        }
        do {
            var retainedHistory = remainingHistory
            if let persistence {
                let snapshot = WorkspaceSnapshot(input: input, items: remainingItems, history: remainingHistory, logs: logs)
                let retained = try persistence.replaceWorkspace(snapshot)
                logs = retained.logs; retainedHistory = retained.history
            }
            saveWork?.cancel(); saveWork = nil
            items = remainingItems; history = retainedHistory
            notice = nil; persistenceNotice = nil
            return true
        } catch {
            persistenceNotice = "下载记录未能清空：\(error.localizedDescription)"
            return false
        }
    }

    private var mediaLibraryURL: URL? { persistence?.mediaURL }
    private func restoreMediaLibrary() {
        do {
            if let mediaLibraryURL, let saved = try MediaLibraryStore.read(mediaLibraryURL) {
                mediaLibrary = saved; mediaLibraryDirty = false
            }
            // Merge retained history once on upgrade, and recover a library write
            // that was interrupted after the workspace had already saved.
            for var item in (history + items).reversed() {
                // Older history may have discarded missing attachment paths.
                // Only a successful re-download can complete that collection.
                if item.state == .missing && item.incompleteFileList == nil { item.incompleteFileList = true }
                upsertMedia(item)
            }
        } catch { mediaLibraryWritable = false; mediaLibraryNotice = "媒体库无法读取，原文件已保留：\(error.localizedDescription)" }
    }
    private func persistMediaLibrary() {
        guard mediaLibraryDirty, mediaLibraryWritable, let persistence else { return }
        do { try persistence.writeMediaLibrary(mediaLibrary); mediaLibraryDirty = false; mediaLibraryNotice = nil }
        catch { mediaLibraryNotice = "媒体库未能保存：\(error.localizedDescription)" }
    }
    func upsertMedia(_ item: DownloadItem) {
        guard mediaLibraryWritable, MediaLibraryStore.valid(item) else { return }
        let exact = mediaLibrary.firstIndex { $0.id == item.id } ??
            mediaLibrary.firstIndex { Set($0.localURLs) == Set(item.localURLs) }
        let copies = mediaLibrary.indices.filter { sameMediaSave(item, mediaLibrary[$0]) }
        if let index = exact ?? (copies.count == 1 ? copies[0] : nil) {
            // Replaying older history must not roll back a newer save or
            // replace a complete file collection with a pruned history entry.
            let old = mediaLibrary[index]
            if (item.finishedAt ?? item.createdAt) <= (old.finishedAt ?? old.createdAt) { return }
            var saved = item; saved.id = mediaLibrary[index].id
            saved.libraryRemovedAt = old.libraryRemovedAt
            saved.origin = old.provenance ?? item.provenance
            mediaLibrary[index] = saved
        } else {
            guard mediaLibrary.count < LibraryStore.countLimit else { mediaLibraryNotice = "媒体库已满，下载文件仍已保存。"; return }
            var saved = item; saved.origin = item.provenance
            mediaLibrary.append(saved)
        }
    }

    private func restoreLibrary() {
        do {
            if let libraryURL, let saved = try LibraryStore.read(libraryURL) { papers = saved; libraryDirty = false; return }
            for item in (history + items).reversed() { upsertPaper(item) }
        } catch { libraryWritable = false; libraryNotice = "文档库无法读取，原文件已保留：\(error.localizedDescription)" }
    }
    private func persistLibrary() {
        guard libraryDirty, libraryWritable, let persistence else { return }
        do { try persistence.writeLibrary(papers); libraryDirty = false; libraryNotice = nil }
        catch { libraryNotice = "文档库未能保存：\(error.localizedDescription)" }
    }

    func appendInput(_ capturedText: String) {
        guard !busy else { return }
        let text: String
        do { text = try PaperInput.captured(capturedText) } catch { notice = error.localizedDescription; return }
        let joined = input.isEmpty ? text : input + (input.hasSuffix("\n") ? "" : "\n") + text
        guard joined.utf8.count <= ResourceLimits.inputBytes else { notice = "输入超过 64 KB，请分批导入。"; return }
        input = joined
        notice = nil
    }

    func importLinks() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("导入链接"); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = try PaperStorage.read(url, limit: ResourceLimits.inputBytes, tooLarge: "文件超过 64 KB，请分批导入。")
                guard let text = String(data: data, encoding: .utf8) else { throw DownloadError.limit("请选择 UTF-8 编码的文本文件。") }
                self.appendInput(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
            } catch { self.notice = error.localizedDescription }
        }
    }

    func copyUnfinished() {
        let text = downloads.filter { $0.canRetry || $0.source == nil }.map(\.original).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    func exportLogs(_ entries: [ActivityEntry]) {
        exportData(Data(entries.map(\.line).joined(separator: "\n").utf8), name: "folioak-log.txt")
    }

    func exportLibrary() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do { exportData(try encoder.encode(papers.filter { !$0.removed }), name: "arxiv-library.json") }
        catch { notice = "导出失败：\(error.localizedDescription)" }
    }

    private func exportData(_ data: Data, name: String) {
        let panel = NSOpenPanel()
        panel.title = name.hasSuffix(".txt") ? L("导出日志") : L("导出文档库")
        panel.prompt = L("导出")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        present(panel) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                let url = try WorkspaceStore.export(data, named: name, to: folder)
                self?.notice = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self?.notice = "导出失败：\(error.localizedDescription)" }
        }
    }

    func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        activePanel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            completion(response)
            activePanel = nil
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    func retryFromLibrary(_ item: DownloadItem) {
        trace.user(.retryRequested, context: .documents, outcome: .requested, item: item.id)
        guard !busy, !libraryMutationInProgress, let source = item.source else { return }
        // Restore the exact version, even when the original request used “latest”.
        let original = item.metadata?.reference.identifier ?? source.webURL.absoluteString
        archiveResults()
        guard let restored = try? DownloadSource.parse(original) else { return }
        let snapshot = item.namingSnapshot ?? AssetNamingSnapshot(rules: namingRules, paperStyle: naming, now: item.createdAt)
        items = [DownloadItem(id: item.id, original: original, reference: restored.reference, directURL: restored.directURL, state: .queued, mediaFormat: item.mediaFormat, namingSnapshot: item.localURLs.isEmpty ? snapshot : snapshot.saving(item.localURLs), origin: item.provenance)]
        duplicateCount = 0; batchID = UUID()
        record(.info, DiagnosticMessage(.redownload), item: items[0])
        saveWorkspace()
        execute(items.map(\.id))
    }

    func record(_ level: ActivityLevel, _ message: DiagnosticMessage, item: DownloadItem? = nil) {
        record(level, message.fallback, item: item, diagnostic: message)
    }

    func record(_ level: ActivityLevel, _ message: String, item: DownloadItem? = nil, diagnostic: DiagnosticMessage? = nil) {
        logs.append(ActivityEntry(level: level, message: ActivityEntry.redacted(message), subject: item.map { ActivityEntry.redacted($0.title) }, itemID: item?.id, diagnostic: diagnostic?.redacted))
        if logs.count > WorkspaceStore.logLimit { logs.removeFirst(logs.count - WorkspaceStore.logLimit) }
    }

    private func archiveResults() { history = historyByArchivingResults() }

    private func historyByArchivingResults() -> [DownloadItem] {
        var archived = history
        for item in items where item.state.terminal {
            archived.removeAll { old in
                old.id == item.id || (item.savedURL != nil && old.savedURL == item.savedURL && old.source == item.source)
                    || (old.state == .missing && item.savedURL != nil && old.metadata?.reference == item.metadata?.reference && old.source == item.source)
            }
            archived.insert(item, at: 0)
        }
        return Array(archived.prefix(WorkspaceStore.historyLimit))
    }

    private func schedulePersistence() {
        guard persistenceReady, stateURL != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveWorkspace() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func persistenceRequest() -> WorkspacePersistence.Request? {
        guard persistenceReady, let persistence else { return nil }
        do { try persistence.prepareForSaving() }
        catch { persistenceNotice = "历史记录未能保存：\(error.localizedDescription)"; return nil }
        persistenceSequence += 1
        return WorkspacePersistence.Request(sequence: persistenceSequence, revision: workspaceRevision,
            libraryRevision: libraryRevision, mediaRevision: mediaLibraryRevision,
            snapshot: WorkspaceSnapshot(input: input, items: items, history: history, logs: logs),
            stateURL: persistence.stateURL, libraryURL: libraryURL, mediaURL: mediaLibraryURL,
            papers: libraryDirty && libraryWritable ? papers : nil,
            media: mediaLibraryDirty && mediaLibraryWritable ? mediaLibrary : nil)
    }

    private func applyPersistence(_ result: WorkspacePersistence.WriteResult, request: WorkspacePersistence.Request) {
        // A delayed completion cannot roll back an explicit flush or a newer edit.
        guard request.sequence > appliedPersistenceSequence else { return }
        appliedPersistenceSequence = request.sequence
        if request.papers != nil, request.libraryRevision == libraryRevision {
            libraryDirty = result.libraryError != nil; libraryNotice = result.libraryError
        }
        if request.media != nil, request.mediaRevision == mediaLibraryRevision {
            mediaLibraryDirty = result.mediaError != nil; mediaLibraryNotice = result.mediaError
        }
        switch result.workspace {
        case .success(let retained):
            if request.revision == workspaceRevision {
                if retained.history.count != history.count { history = retained.history }
                if retained.logs.count != logs.count { logs = retained.logs }
            }
            persistenceNotice = nil
        case .failure(let error): persistenceNotice = "历史记录未能保存：\(error.localizedDescription)"
        }
    }

    // Coalesce automatic saves while encoding and disk writes run off the UI.
    func saveWorkspace() {
        saveWork?.cancel(); saveWork = nil
        if libraryMutationInProgress || savingWorkspace { pendingWorkspaceSave = true; return }
        guard let persistence, let request = persistenceRequest() else { return }
        savingWorkspace = true
        persistence.save(request) { [weak self] result in
            guard let self else { return }
            self.applyPersistence(result, request: request)
            self.savingWorkspace = false
            if self.pendingWorkspaceSave {
                self.pendingWorkspaceSave = false
                self.saveWorkspace()
            }
        }
    }

    // Explicit saves and termination drain earlier writes before returning.
    func persistWorkspace() {
        guard !libraryMutationInProgress else { pendingWorkspaceSave = true; return }
        saveWork?.cancel(); saveWork = nil
        pendingWorkspaceSave = false
        guard let persistence, let request = persistenceRequest() else { return }
        let result = persistence.flush(request)
        applyPersistence(result, request: request)
    }

    func persistWorkspaceAndWait() async {
        await waitForLibraryMutation()
        saveWork?.cancel(); saveWork = nil
        pendingWorkspaceSave = false
        guard let persistence, let request = persistenceRequest() else { return }
        let result = await persistence.flushAndWait(request)
        applyPersistence(result, request: request)
    }

    private func restoreWorkspace() {
        guard let persistence else { return }
        do {
            guard let snapshot = try persistence.readWorkspace() else { return }
            input = snapshot.input; items = snapshot.items; history = snapshot.history; logs = snapshot.logs
            var interrupted = 0
            for i in items.indices {
                if !items[i].state.terminal {
                    let lastEvent = items[i].diagnostics?.recordedAt ?? items[i].createdAt
                    items[i].diagnostics?.finish(now: lastEvent)
                    items[i].finishedAt = lastEvent
                    items[i].state = .cancelled
                    items[i].setError(DiagnosticMessage(.interrupted))
                    interrupted += 1
                }
                items[i].progress = nil; items[i].transferSample = nil; items[i].bytesPerSecond = nil
            }
            if interrupted > 0 { record(.warning, DiagnosticMessage(.restored, String(interrupted))) }
        } catch {
            persistenceNotice = "历史记录无法读取，原文件将在下次保存时备份。"
        }
    }

    func applyAppearance() { NSApplication.shared.appearance = appearance.native }
    var namingExample: String {
        PaperMetadata(reference: ArxivReference(baseID: "1706.03762", version: 1), title: "Attention Is All You Need", year: 2017, month: 6).filename(style: naming)
    }

    var tokenCount: Int { DownloadSource.tokens(in: input).count }
    var hasMediaInput: Bool { DownloadSource.tokens(in: input).contains { (try? DownloadSource.parse($0))?.supportsAudioExtraction == true } }
    var retryCount: Int { downloads.filter(\.canRetry).count }
    var canRetry: Bool { downloads.contains(where: \.canRetry) }
    var completed: Int { items.filter { $0.state.terminal }.count }
    var successes: Int { items.filter { $0.state == .saved || $0.state == .existing }.count }
    var failures: Int { items.filter { $0.state == .failed || $0.state == .missing }.count }
    var summary: String {
        if items.isEmpty { return "" }
        if cancelling { return "正在取消…" }
        if busy { return "已处理 \(completed) / \(items.count) 项" }
        var parts: [String] = []
        if failures > 0 { parts.append("\(failures) 项失败") }
        let cancelled = items.filter { $0.state == .cancelled }.count
        if cancelled > 0 { parts.append("\(cancelled) 项取消") }
        let paused = items.filter { $0.state == .paused }.count
        if paused > 0 { parts.append("\(paused) 项待重试") }
        if duplicateCount > 0 { parts.append("已去重 \(duplicateCount) 条") }
        return parts.joined(separator: " · ")
    }

    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        appendInput(text)
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, !providers.isEmpty, providers.count <= ResourceLimits.batchCount else { return false }
        Task { [weak self] in
            var texts: [String] = []
            var bytes = 0
            for provider in providers {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
                let text: String? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                        let text: String?
                        if let url = item as? URL { text = url.isFileURL ? nil : url.absoluteString }
                        else if let value = item as? String { text = value }
                        else if let data = item as? Data, data.count <= ResourceLimits.inputBytes { text = String(data: data, encoding: .utf8) }
                        else { text = nil }
                        continuation.resume(returning: text)
                    }
                }
                guard let text else { self?.notice = "请拖入链接或文本。"; return }
                bytes += text.utf8.count + 1
                guard bytes <= ResourceLimits.inputBytes else { self?.notice = "输入超过 64 KB，请分批导入。"; return }
                texts.append(text)
            }
            self?.appendInput(texts.joined(separator: "\n"))
        }
        return true
    }

    func chooseDirectory() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择保存位置")
        panel.prompt = L("选择")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        present(panel) { [self] response in
            if response == .OK, !busy, let url = panel.url {
                directory = url
            }
        }
    }

    func setPDFDirectoryEnabled(_ enabled: Bool) {
        guard !busy else { return }
        if enabled && pdfDirectory == nil { choosePDFDirectory() }
        else { usesPDFDirectory = enabled }
    }

    func choosePDFDirectory() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择 PDF 保存目录")
        panel.prompt = L("选择")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = pdfDirectory ?? directory
        present(panel) { [self] response in
            guard response == .OK, !busy, let url = panel.url else { return }
            pdfDirectory = url; usesPDFDirectory = true
        }
    }

    func start() {
        guard !busy else { return }
        do { _ = try submitDownload(input, quick: false) }
        catch { notice = error.localizedDescription }
    }

    // Both entry points commit before execution. Quick entry never edits the
    // main-window draft or changes its page/focus, including while it is hidden.
    @discardableResult
    func submitQuickDownload(_ text: String) throws -> Int {
        try submitDownload(text, quick: true)
    }

    private func submitDownload(_ text: String, quick: Bool) throws -> Int {
        let operation = trace.isEnabled ? UUID() : nil
        let context: InteractionEvent.Context = quick ? .quickPanel : .mainWindow
        trace.user(.downloadSubmitted, context: context, outcome: .requested, operation: operation)
        do {
            let count = try performSubmitDownload(text, quick: quick, operation: operation)
            trace.record(.downloadAccepted, context: context, outcome: .succeeded, operation: operation, count: count)
            return count
        } catch {
            trace.record(.downloadRejected, context: context, outcome: .failed, operation: operation,
                diagnostic: DiagnosticMessage.ID(rawValue: DiagnosticMessage.downloadFailure(error).id))
            throw error
        }
    }

    private func performSubmitDownload(_ text: String, quick: Bool, operation: UUID?) throws -> Int {
        guard !libraryMutationInProgress else { throw DownloadError.limit("正在保存资料库，请稍后添加任务。") }
        guard !cancelling, quick || !busy else { throw DownloadError.limit("正在停止，请稍后添加任务。") }
        let batch = try BatchInput(text)
        if quick, let invalid = batch.entries.first(where: { $0.source == nil }) {
            throw DownloadError.invalidLink(invalid.original)
        }
        let active = Set(items.filter { !$0.state.terminal }.compactMap(\.source))
        let entries = batch.entries.filter { !quick || $0.source.map { !active.contains($0) } ?? true }
        guard !entries.isEmpty else { throw DownloadError.limit("这些链接已在下载队列中。") }
        let retainedItems = busy ? items.filter { !$0.state.terminal } : []
        guard retainedItems.count + entries.count <= ResourceLimits.batchCount else {
            throw DownloadError.limit("队列最多保留 200 项，请等待部分任务完成。")
        }
        let namingSnapshot = AssetNamingSnapshot(rules: namingRules, paperStyle: naming)
        let added = entries.map { entry in
            DownloadItem(original: entry.original, reference: entry.reference, directURL: entry.source?.directURL,
                state: entry.source == nil ? .failed : .queued, error: entry.error, errorMessage: entry.diagnostic,
                mediaFormat: entry.source?.supportsAudioExtraction == true ? mediaFormat : nil, preservesInput: quick ? true : nil, namingSnapshot: namingSnapshot,
                origin: entry.source.map { _ in DownloadOrigin(input: entry.original, capturedAt: Date()) })
        }
        let updatedItems = retainedItems + added
        var updatedHistory = historyByArchivingResults()
        // Drain older writes and publish only a durable submission. A failed
        // commit leaves both the active worker and the user's drafts unchanged.
        if let persistence {
            let saved = try persistence.replaceWorkspace(WorkspaceSnapshot(input: input, items: updatedItems,
                history: updatedHistory, logs: logs))
            updatedHistory = saved.history
            persistenceSequence += 1; appliedPersistenceSequence = persistenceSequence
        }
        items = updatedItems; history = updatedHistory
        if trace.isEnabled {
            for item in added {
                let detail: InteractionEvent.Detail
                switch item.source { case .arxiv?: detail = .arxiv; case .pdf?: detail = .pdf; case .file?: detail = .file; case .media?: detail = .media; case nil: detail = .unknown }
                trace.record(.taskQueued, context: quick ? .quickPanel : .mainWindow,
                    outcome: item.source == nil ? .failed : .succeeded, item: item.id, operation: operation, detail: detail,
                    diagnostic: item.errorMessage.flatMap { DiagnosticMessage.ID(rawValue: $0.id) })
            }
        }
        duplicateCount = batch.duplicates + batch.entries.count - entries.count
        notice = nil; persistenceNotice = nil
        if !quick { batchID = UUID() }
        record(.info, duplicateCount > 0
            ? DiagnosticMessage(.startDeduplicated, String(added.count), String(duplicateCount))
            : DiagnosticMessage(.start, String(added.count)))
        for item in added where item.source == nil { record(.error, item.errorMessage ?? DiagnosticMessage(.invalidInput), item: item) }
        saveWorkspace()
        if !busy { execute(added.filter { $0.source != nil }.map(\.id)) }
        return added.count
    }

    func retry(_ single: UUID? = nil, context: InteractionEvent.Context = .downloads) {
        guard !busy, !libraryMutationInProgress else { return }
        if single == nil, history.contains(where: { old in old.canRetry && !items.contains(where: { $0.id == old.id }) }) {
            let candidates = Array(downloads.filter(\.canRetry).prefix(ResourceLimits.batchCount))
            archiveResults(); items = candidates; duplicateCount = 0; batchID = UUID()
        }
        if let single, !items.contains(where: { $0.id == single }), let previous = history.first(where: { $0.id == single }), previous.canRetry {
            archiveResults()
            // A new retry batch leaves the draft and earlier completed files intact.
            items = [previous]
            batchID = UUID()
        }
        let ids = items.filter { $0.canRetry && (single == nil || $0.id == single) }.map(\.id)
        guard !ids.isEmpty else { return }
        trace.user(.retryRequested, context: context, item: single, count: ids.count)
        record(.info, DiagnosticMessage(.retry, String(ids.count)))
        for id in ids { update(id) { $0.state = .queued; $0.error = nil; $0.progress = nil; $0.finishedAt = nil; $0.diagnostics = nil; $0.bytesPerSecond = nil; $0.transferSample = nil } }
        execute(ids)
    }

    func cancel() {
        guard busy else { return }
        cancelling = true
        trace.user(.cancelRequested, context: .downloads, outcome: .requested)
        record(.warning, DiagnosticMessage(.cancelling))
        worker?.cancel()
    }

    func cancelAndWait() async {
        let task = worker
        cancel()
        await task?.value
        await persistWorkspaceAndWait()
    }

    func focusInput() { editTarget = ""; editRequest = UUID() }

    func edit(_ item: DownloadItem) {
        if !DownloadSource.tokens(in: input).contains(item.original) { appendInput(item.original) }
        editTarget = item.original
        editRequest = UUID()
    }

    func openDirectory() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            directoryNotice = "保存位置不存在，请重新选择。"; return
        }
        if !opener(directory) { directoryNotice = "无法打开保存目录，请检查 Finder 或目录权限。" }
        else { directoryNotice = nil }
    }

    func localFile(_ item: DownloadItem) -> URL? {
        guard !assetRenameInProgress else { return nil }
        fileRefreshRevision += 1
        // Older history can contain a pruned collection. Prefer the retained
        // library's complete paths; absence never destroys recovery information.
        let copies = mediaLibrary.filter { $0.incompleteFileList != true && sameMediaSave(item, $0) }
        let retained = mediaLibrary.first { $0.id == item.id && $0.incompleteFileList != true } ?? (copies.count == 1 ? copies[0] : nil)
        let document = papers.first { ($0.id == item.id || $0.taskID == item.id) && $0.file != nil }
        let documentIDs = Set([document?.id, document?.taskID].compactMap { $0 })
        let files = retained?.localURLs ?? (item.localURLs.isEmpty ? document?.file.map { [$0] } ?? [] : item.localURLs)
        guard !files.isEmpty else { return nil }
        let names = Set(files.map(\.lastPathComponent))
        var parents: [URL: URL] = [:]
        func location(_ url: URL) -> URL {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            let resolved = parents[parent] ?? parent.resolvingSymlinksInPath()
            parents[parent] = resolved
            return resolved.appendingPathComponent(url.lastPathComponent)
        }
        let locations = Set(files.map(location))
        func belongs(_ url: URL) -> Bool {
            names.contains(url.lastPathComponent) && locations.contains(location(url))
        }
        var existence: [URL: Bool] = [:]
        func exists(_ url: URL) -> Bool {
            if let cached = existence[url] { return cached }
            let result = FileManager.default.fileExists(atPath: url.path)
            existence[url] = result
            return result
        }
        let available = files.filter(exists)
        let missing = available.count != files.count || retained?.incompleteFileList == true
        let message = available.isEmpty ? "原位置的文件不存在，可重新下载。" : "部分文件已不在原位置，仍可打开其余文件，或重新下载。"
        func refresh(_ value: inout DownloadItem) {
            if let retained, value.id == retained.id || (copies.count == 1 && sameMediaSave(value, retained)) {
                value.savedURL = retained.savedURL; value.additionalURLs = retained.additionalURLs
                value.incompleteFileList = false
            }
            if value.localURLs.isEmpty, documentIDs.contains(value.id), let file = document?.file {
                value.savedURL = file; value.incompleteFileList = false
            }
            let absent = value.localURLs.isEmpty || value.localURLs.contains { !exists($0) }
            if value.state != .missing && value.incompleteFileList == nil { value.incompleteFileList = false }
            if absent || value.incompleteFileList == true {
                value.state = .missing; value.restoreReference = value.metadata?.reference
                value.error = message; value.errorMessage = nil
            } else if value.state == .missing {
                value.state = .saved; value.error = nil; value.errorMessage = nil
            }
        }
        func matches(_ value: DownloadItem) -> Bool {
            value.id == item.id || documentIDs.contains(value.id) || (copies.count == 1 && sameMediaSave(value, copies[0])) || value.localURLs.contains(where: belongs)
        }
        func refreshed(_ records: [DownloadItem]) -> [DownloadItem]? {
            var updated = records, changed = false
            for i in records.indices where matches(records[i]) {
                var value = records[i]; refresh(&value)
                if value.state != records[i].state || value.localURLs != records[i].localURLs ||
                   value.error != records[i].error || value.incompleteFileList != records[i].incompleteFileList ||
                   value.restoreReference != records[i].restoreReference || value.errorMessage != records[i].errorMessage {
                    updated[i] = value; changed = true
                }
            }
            return changed ? updated : nil
        }
        if let updated = refreshed(items) { items = updated }
        if let updated = refreshed(history) { history = updated }
        if let updated = refreshed(mediaLibrary) { mediaLibrary = updated }
        for i in papers.indices where papers[i].file.map(belongs) == true {
            let absent = !exists(papers[i].file!)
            if papers[i].missing != absent { papers[i].missing = absent }
        }
        notice = missing ? message : nil
        if missing { record(.warning, DiagnosticMessage(.localMissing), item: item) }
        saveWorkspace()
        return available.first
    }

    func preview(_ item: DownloadItem) {
        let operation = trace.isEnabled ? UUID() : nil
        var succeeded = false
        trace.user(.previewRequested, outcome: .requested, item: item.id, operation: operation)
        defer { trace.record(.previewRequested, outcome: succeeded ? .succeeded : .failed, item: item.id, operation: operation) }
        guard !assetRenameInProgress else { return }
        previewURL = localFile(item)
        if let file = previewURL { markRead(file); succeeded = true }
    }

    func openFile(_ item: DownloadItem, reveal: Bool = false) {
        let operation = trace.isEnabled ? UUID() : nil
        var succeeded = false
        trace.user(reveal ? .revealRequested : .openRequested, outcome: .requested, item: item.id, operation: operation)
        defer { trace.record(reveal ? .revealRequested : .openRequested, outcome: succeeded ? .succeeded : .failed, item: item.id, operation: operation) }
        guard !assetRenameInProgress else { return }
        guard let url = localFile(item) else { return }
        if reveal {
            let current = downloads.first { $0.id == item.id } ?? mediaLibrary.first { $0.id == item.id } ?? item
            revealer(current.localURLs.filter { FileManager.default.fileExists(atPath: $0.path) })
            succeeded = true
        }
        else if !opener(url) { notice = "无法打开文件，请检查默认应用。文件仍保存在原位置。" }
        else { notice = nil; markRead(url); succeeded = true }
    }

    private func markRead(_ file: URL) {
        for index in papers.indices where papers[index].file == file && (!papers[index].read || papers[index].missing) {
            var paper = papers[index]; paper.read = true; paper.missing = false
            papers[index] = paper
        }
    }

    func openSource(_ item: DownloadItem) {
        if let source = item.source {
            let opened = opener(source.webURL)
            trace.user(.sourceOpened, outcome: opened ? .succeeded : .failed, item: item.id)
            notice = opened ? nil : "无法打开来源页面，请检查默认浏览器。"
        }
    }

    @discardableResult func openOriginalSource(_ item: DownloadItem) -> Bool {
        guard let url = item.provenance?.browserURL else { return false }
        let opened = opener(url)
        trace.record(.sourceOpened, outcome: opened ? .succeeded : .failed, item: item.id)
        notice = opened ? nil : "无法打开来源页面，请检查默认浏览器。"
        return opened
    }

    func openAuthenticationSource(_ item: DownloadItem) {
        guard case .media(let url)? = item.source else { return }
        Task {
            await browserAuthentication.openBrowser(url: url)
            notice = browserAuthentication.browserOpenError ? "浏览器未安装，或无法打开。请确认安装后重试。" : nil
        }
    }

    private func update(_ id: UUID, _ transform: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[index].state
        transform(&items[index])
        let attempt = traceAttempts[id]
        if items[index].state.terminal { traceAttempts.removeValue(forKey: id) }
        guard trace.isEnabled, before != items[index].state else { return }
        let value = items[index]
        let outcome: InteractionEvent.Outcome = value.state == .cancelled ? .cancelled :
            value.state == .failed || value.state == .paused ? .failed : value.state.terminal ? .succeeded : .performed
        trace.record(value.state.terminal ? .taskFinished : .taskPhase, context: .downloads, outcome: outcome,
            item: id, attempt: attempt?.id,
            diagnostic: DiagnosticMessage.ID(rawValue: (value.errorMessage ?? value.state.message).id),
            durationMS: value.state.terminal ? attempt.map { Double(DispatchTime.now().uptimeNanoseconds - $0.start) / 1_000_000 } : nil)
    }

    private func receive(_ event: DownloadEvent, for id: UUID, run: UUID) {
        guard run == runID else { return }
        guard let before = items.first(where: { $0.id == id }), !before.state.terminal else { return }
        if case .diagnostic(let message) = event {
            record(.info, message, item: before); schedulePersistence()
            return
        }
        if case .browserAuthentication(let selection, let state) = event {
            browserAuthentication.receive(state, for: selection, host: before.source?.webURL.host)
            if state != .ready {
                let level: ActivityLevel = state == .failed || state == .rejected || state == .empty ? .warning : .info
                let message = state.message(for: selection.browser)
                let startedAt = before.diagnostics?.startedAt ?? before.createdAt
                let alreadyRecorded = logs.contains { $0.itemID == id && $0.date >= startedAt && $0.diagnostic == message }
                if !alreadyRecorded { record(level, message, item: before); schedulePersistence() }
            }
            return
        }
        if case .anonymousFallback(let reason, let state) = event {
            // Completion carries the reason as well, preserving a useful log even
            // when a burst of progress displaced the initial bounded-stream event.
            let startedAt = before.diagnostics?.startedAt ?? before.createdAt
            for message in [reason.message, AnonymousFallbackState.started.message, state.message] {
                if !logs.contains(where: { $0.itemID == id && $0.date >= startedAt && $0.diagnostic == message }) {
                    record(state == .succeeded && message == state.message ? .success : .warning, message, item: before)
                }
            }
            if state == .started {
                update(id) { $0.progress = nil; $0.transferSample = nil; $0.bytesPerSecond = nil; $0.state = .metadata }
            }
            schedulePersistence()
            return
        }
        update(id) { item in
            item.diagnostics?.receive(event)
            switch event {
            case .coordinating: item.state = .coordinating
            case .metadata: item.state = .metadata
            case .resolved(let metadata): item.metadata = metadata
            case .document(let title): item.documentTitle = title
            case .browserAuthentication, .anonymousFallback, .diagnostic: break
            case .checkingLocal: item.state = .checkingLocal
            case .progress(let progress):
                let now = Date()
                if let sample = item.transferSample, now.timeIntervalSince(sample.date) >= 0.4 {
                    let speed = Double(max(0, progress.received - sample.bytes)) / now.timeIntervalSince(sample.date)
                    item.bytesPerSecond = speed
                    item.transferSample = TransferSample(date: now, bytes: progress.received)
                } else if item.transferSample == nil {
                    item.transferSample = TransferSample(date: now, bytes: progress.received)
                }
                item.progress = progress; item.state = .downloading
            case .retry(let attempt): item.state = .retrying(attempt); item.progress = nil; item.transferSample = nil; item.bytesPerSecond = nil
            case .waiting(let date): item.state = .waiting(date); item.progress = nil
            case .validating: item.state = .validating
            }
        }
        if let item = items.first(where: { $0.id == id }), item.state != before.state {
            let level: ActivityLevel
            switch item.state { case .retrying, .waiting: level = .warning; default: level = .info }
            record(level, item.state.message, item: item)
            schedulePersistence()
        }
    }

    private func executeSource(_ ids: [UUID], target: URL, pdfTarget: URL?, namingStyle: NamingStyle, run: UUID) async {
        for id in ids {
            if Task.isCancelled { break }
            guard let item = items.first(where: { $0.id == id }),
                  let source = item.restoreReference.map(DownloadSource.arxiv) ?? item.source else { continue }
            if let until = sourceCooldowns[source.rateLimitKey], until > Date() {
                update(id) { $0.state = .paused; $0.setError(DiagnosticMessage(.siteCooldown, until.formatted(date: .abbreviated, time: .standard))) }
                if let paused = items.first(where: { $0.id == id }) { record(.warning, paused.errorMessage ?? DiagnosticMessage(.metadata, paused.error ?? "站点限流"), item: paused) }
                saveWorkspace()
                continue
            }
            if trace.isEnabled {
                let attempt = UUID()
                traceAttempts[id] = (attempt, DispatchTime.now().uptimeNanoseconds)
                trace.record(.taskStarted, context: .downloads, item: id, attempt: attempt)
            }
            let baseSnapshot = item.namingSnapshot ?? AssetNamingSnapshot(rules: namingRules, paperStyle: namingStyle, now: item.createdAt)
            let snapshot = item.localURLs.isEmpty ? baseSnapshot : baseSnapshot.saving(item.localURLs)
            update(id) { $0.namingSnapshot = snapshot; $0.state = source.reference == nil ? .checkingLocal : .metadata; $0.diagnostics = TaskDiagnostics() }
            record(.info, DiagnosticMessage(source.reference == nil ? .preparing : .paperMetadata), item: item)
            var continuation: AsyncStream<DownloadEvent>.Continuation!
            let events = AsyncStream<DownloadEvent>(bufferingPolicy: .bufferingNewest(128)) { continuation = $0 }
            let sink = continuation!
            let listener = Task { [weak self] in
                for await event in events { self?.receive(event, for: id, run: run) }
            }
            do {
                let saved = try await engine.download(source, to: target, naming: snapshot.paperStyle, namingSnapshot: snapshot, mediaFormat: item.mediaFormat ?? .automatic, organizeByType: true, pdfDirectory: pdfTarget) { event in sink.yield(event) }
                sink.finish()
                await listener.value
                update(id) {
                    $0.namingSnapshot = snapshot.saving([saved.url] + saved.additionalURLs)
                    $0.metadata = saved.metadata
                    $0.documentTitle = saved.title
                    $0.savedURL = saved.url
                    $0.pages = saved.pages > 0 ? saved.pages : nil
                    $0.additionalURLs = saved.additionalURLs.isEmpty ? nil : saved.additionalURLs
                    $0.incompleteFileList = nil
                    $0.state = saved.alreadyExisted ? .existing : .saved
                    $0.progress = nil
                    $0.finishedAt = Date(); $0.diagnostics?.finish()
                }
                runSuccesses += 1
                if let result = items.first(where: { $0.id == id }) { record(.success, result.state.message, item: result); upsertPaper(result); upsertMedia(result) }
                if item.preservesInput != true {
                    input = DownloadSource.tokens(in: input)
                        .filter { (try? DownloadSource.parse($0)) != source }
                        .joined(separator: "\n")
                }
            } catch is CancellationError {
                sink.finish()
                await listener.value
                record(.warning, DiagnosticMessage(.cancelled), item: item)
                update(id) { $0.state = .cancelled; $0.progress = nil; $0.finishedAt = Date(); $0.diagnostics?.finish() }
                break
            } catch {
                sink.finish()
                await listener.value
                let cooldown: Date?
                if case DownloadError.cooldown(let seconds) = error {
                    cooldown = Date().addingTimeInterval(seconds)
                } else { cooldown = nil }
                update(id) {
                    $0.finishedAt = Date(); $0.diagnostics?.finish()
                    $0.state = cooldown == nil ? .failed : .paused
                    $0.progress = nil
                    if let cooldown {
                        $0.setError(DiagnosticMessage(.siteCooldown, cooldown.formatted(date: .abbreviated, time: .standard)))
                    } else { $0.setError(DiagnosticMessage.downloadFailure(error)) }
                }
                if cooldown == nil { runFailures += 1 }
                if let failed = items.first(where: { $0.id == id }) { record(cooldown == nil ? .error : .warning, failed.errorMessage ?? DiagnosticMessage(.failed), item: failed) }
                if let cooldown { sourceCooldowns[source.rateLimitKey] = cooldown }
            }
            archiveResults()
            saveWorkspace()
        }
    }

    private func execute(_ ids: [UUID]) {
        notice = nil
        directoryNotice = nil
        guard !ids.isEmpty else { return }
        let target = directory
        let pdfTarget = activePDFDirectory
        busy = true
        cancelling = false
        let namingStyle = naming
        let run = UUID()
        runID = run
        sourceCooldowns = [:]; runSuccesses = 0; runFailures = items.filter { $0.source == nil }.count
        worker = Task { [self] in
            var pending = ids
            repeat {
                if !Task.isCancelled {
                    let groups = SourceScheduler.groups(pending) { id in
                        items.first(where: { $0.id == id })?.source?.rateLimitKey ?? "invalid"
                    }
                    _ = await SourceScheduler.run(groups) { [self] group in
                        await executeSource(group, target: target, pdfTarget: pdfTarget, namingStyle: namingStyle, run: run)
                    }
                }
                if Task.isCancelled {
                    for id in items.filter({ !$0.state.terminal }).map(\.id) {
                        update(id) { $0.state = .cancelled; $0.progress = nil; $0.finishedAt = Date(); $0.diagnostics?.finish() }
                    }
                }
                archiveResults()
                await persistWorkspaceAndWait()
                // Recheck after the flush as well: submissions may arrive while
                // it suspends. No suspension separates the final check/idle state.
                pending = items.filter { $0.state == .queued && $0.source != nil }.map(\.id)
            } while !pending.isEmpty && !Task.isCancelled
            // Cancellation may arrive during the flush after an appended task
            // was accepted. Close every nonterminal task before publishing idle.
            if Task.isCancelled {
                for id in items.filter({ !$0.state.terminal }).map(\.id) {
                    update(id) { $0.state = .cancelled; $0.progress = nil; $0.finishedAt = Date(); $0.diagnostics?.finish() }
                }
                archiveResults()
            }
            record(.info, DiagnosticMessage(.finished, String(runSuccesses), String(runFailures)))
            // This short final commit has no suspension/acceptance gap and makes
            // the completion log durable for immediate quit or relaunch.
            persistWorkspace()
            busy = false
            cancelling = false
            worker = nil
        }
    }
}

// Placeholder glyphs use the same TextKit layout and origin as editable text.
// SwiftUI Text over TextEditor has a different first-line baseline on macOS.
final class LinkTextView: NSTextView {
    static var example: String { L("粘贴论文或媒体链接") }
    var placeholderColor = NSColor.secondaryLabelColor { didSet { if placeholderColor != oldValue { needsDisplay = true } } }
    var focusChanged: ((Bool) -> Void)?
    private var styledInput: String?
    private var styledTextColor: NSColor?
    private var styledAccentColor: NSColor?
    private var styledUnderline = false
    private let placeholderStorage = NSTextStorage()
    private let placeholderLayout = NSLayoutManager()
    private let placeholderContainer = NSTextContainer()

    private struct InputColors: Equatable {
        let text: NSColor
        let accent: NSColor
        let placeholder: NSColor
    }
    private final class ColorTransition: NSAnimation {
        var apply: ((CGFloat) -> Void)?
        override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common, .eventTracking] }
        override var currentProgress: NSAnimation.Progress {
            didSet { apply?(CGFloat(currentValue)) }
        }
    }
    private var colorTransition: ColorTransition?
    private var colorTarget: InputColors?
    private var currentColors: InputColors?
    private var underlineLinks = false

    func updateColors(text: NSColor, accent: NSColor, placeholder: NSColor, underline: Bool, animated: Bool) {
        let target = InputColors(text: text, accent: accent, placeholder: placeholder)
        underlineLinks = underline
        guard colorTarget != target else {
            if !animated { colorTransition?.stop(); colorTransition = nil; renderColors(target) }
            else if let currentColors { renderColors(currentColors) }
            return
        }
        let start = currentColors
        colorTransition?.stop(); colorTransition = nil
        colorTarget = target
        guard animated, let start else { renderColors(target); return }
        let transition = ColorTransition(duration: 0.24, animationCurve: .easeInOut)
        transition.animationBlockingMode = .nonblocking
        transition.frameRate = 60
        transition.apply = { [weak self] progress in
            func blend(_ a: NSColor, _ b: NSColor) -> NSColor { a.blended(withFraction: progress, of: b) ?? b }
            self?.renderColors(InputColors(text: blend(start.text, target.text), accent: blend(start.accent, target.accent), placeholder: blend(start.placeholder, target.placeholder)))
        }
        colorTransition = transition
        transition.start()
    }
    private func renderColors(_ colors: InputColors) {
        currentColors = colors
        placeholderColor = colors.placeholder
        insertionPointColor = colors.accent
        styleReferences(textColor: colors.text, accentColor: colors.accent, underlineRecognized: underlineLinks)
    }
    deinit { colorTransition?.stop() }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.string, .URL])
        placeholderStorage.addLayoutManager(placeholderLayout)
        placeholderLayout.addTextContainer(placeholderContainer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func paste(_ sender: Any?) {
        guard isEditable, let text = NSPasteboard.general.string(forType: .string) else { return }
        do { insertText(try PaperInput.captured(text), replacementRange: selectedRange()); captureTrace?(true) }
        catch { captureTrace?(false); captureFailure?(error.localizedDescription) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, sender.draggingPasteboard.availableType(from: [.string, .URL]) != nil else { return [] }
        if let value = sender.draggingPasteboard.string(forType: .URL), URL(string: value)?.isFileURL == true { return [] }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .copy, let text = sender.draggingPasteboard.string(forType: .URL) ?? sender.draggingPasteboard.string(forType: .string) else { return false }
        do {
            let captured = try PaperInput.captured(text)
            let prefix = string.isEmpty || string.hasSuffix("\n") ? "" : "\n"
            insertText(prefix + captured, replacementRange: NSRange(location: (string as NSString).length, length: 0))
            captureTrace?(true)
            return true
        } catch { captureTrace?(false); captureFailure?(error.localizedDescription); return false }
    }
    var captureTrace: ((Bool) -> Void)?
    var captureFailure: ((String) -> Void)?

    func styleReferences(textColor: NSColor, accentColor: NSColor, underlineRecognized: Bool) {
        guard styledInput != string || styledTextColor != textColor || styledAccentColor != accentColor || styledUnderline != underlineRecognized,
              let storage = textStorage else { return }
        styledInput = string
        styledTextColor = textColor
        styledAccentColor = accentColor
        styledUnderline = underlineRecognized
        let text = string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: textColor, range: fullRange)
        storage.removeAttribute(.underlineStyle, range: fullRange)
        var search = NSRange(location: 0, length: text.length)
        for token in DownloadSource.tokens(in: string).prefix(ResourceLimits.batchCount) {
            let range = text.range(of: token, options: [], range: search)
            guard range.location != NSNotFound else { continue }
            search = NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))
            if (try? DownloadSource.parse(token)) != nil {
                storage.addAttribute(.foregroundColor, value: accentColor, range: range)
                if underlineRecognized {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
        }
        storage.endEditing()
        var attributes = typingAttributes
        attributes[.foregroundColor] = textColor
        attributes[.underlineStyle] = nil
        typingAttributes = attributes
    }

    func layoutPlaceholder() {
        guard let font, let textContainer else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        let text = NSMutableAttributedString(string: Self.example + "\n", attributes: [.font: font, .foregroundColor: placeholderColor, .paragraphStyle: paragraph])
        text.append(NSAttributedString(string: L("支持多条链接，每行一个"), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: placeholderColor]))
        placeholderStorage.setAttributedString(text)
        placeholderContainer.containerSize = textContainer.containerSize
        placeholderContainer.lineFragmentPadding = textContainer.lineFragmentPadding
        placeholderLayout.usesFontLeading = layoutManager?.usesFontLeading ?? true
        placeholderLayout.ensureLayout(for: placeholderContainer)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        layoutPlaceholder()
        placeholderLayout.drawGlyphs(forGlyphRange: placeholderLayout.glyphRange(for: placeholderContainer), at: textContainerOrigin)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }

    var placeholderFirstGlyphOrigin: NSPoint {
        layoutPlaceholder()
        return placeholderLayout.location(forGlyphAt: 0)
    }
}

struct LinkInput: NSViewRepresentable {
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: DownloadModel
    @Binding var focused: Bool
    let palette: ThemePalette

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = LinkScrollView()
        scroll.drawsBackground = false
        scroll.focusRingType = .none
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let editor = LinkTextView(frame: NSRect(x: 0, y: 0, width: 300, height: WorkspaceMetrics.inputHeight), textContainer: container)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: WorkspaceMetrics.inputHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.enabledTextCheckingTypes = 0
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.setAccessibilityLabel(L("下载链接，每行一个"))
        editor.delegate = context.coordinator
        editor.captureFailure = { [weak model] in model?.notice = $0 }
        editor.captureTrace = { [weak model] accepted in
            model?.trace.user(accepted ? .inputCaptured : .inputRejected, context: .mainWindow, outcome: accepted ? .succeeded : .failed)
        }
        editor.focusChanged = { [weak editor, weak coordinator = context.coordinator] value in
            guard let coordinator else { return }
            let editRequest = coordinator.parent.model.editRequest, listRequest = coordinator.parent.model.listRequest
            let searchRequest = coordinator.parent.model.searchRequest
            DispatchQueue.main.async { [weak coordinator] in
                guard let editor, let window = editor.window, let coordinator,
                      coordinator.parent.model.editRequest == editRequest, coordinator.parent.model.listRequest == listRequest,
                      coordinator.parent.model.searchRequest == searchRequest,
                      (window.firstResponder === editor) == value else { return }
                coordinator.parent.focused = value
            }
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? LinkTextView else { return }
        editor.setAccessibilityLabel(L("下载链接，每行一个"))
        editor.needsDisplay = true
        editor.isEditable = !model.busy
        let textColor = ThemePalette.nativeColor(palette.text)
        let accentColor = ThemePalette.nativeColor(palette.accent)
        let placeholderColor = ThemePalette.nativeColor(palette.secondary).blended(withFraction: scheme == .dark ? 0.34 : 0.12, of: ThemePalette.nativeColor(palette.surface)) ?? ThemePalette.nativeColor(palette.secondary)
        if editor.string != model.input {
            editor.string = model.input
            editor.undoManager?.removeAllActions()
            editor.sizeToFit()
            editor.needsDisplay = true
        }
        editor.updateColors(text: textColor, accent: accentColor, placeholder: placeholderColor, underline: model.theme == .graphite,
                            animated: !reduceMotion && editor.window?.isVisible == true)
        let selectToken = context.coordinator.selectionRequest != model.editRequest
        context.coordinator.selectionRequest = model.editRequest
        if !model.busy && (selectToken || (focused && editor.window?.firstResponder !== editor)) {
            let editRequest = model.editRequest, listRequest = model.listRequest
            let searchRequest = model.searchRequest
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                guard let editor, let coordinator, coordinator.parent.focused, !coordinator.parent.model.busy,
                      coordinator.parent.model.editRequest == editRequest, coordinator.parent.model.listRequest == listRequest,
                      coordinator.parent.model.searchRequest == searchRequest,
                      let window = editor.window else { return }
                window.makeFirstResponder(editor)
                if selectToken, let range = DownloaderView.inputRange(of: coordinator.parent.model.editTarget, in: editor.string) {
                    editor.setSelectedRange(range)
                    editor.scrollRangeToVisible(range)
                }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LinkInput
        var selectionRequest: UUID
        init(_ parent: LinkInput) { self.parent = parent; selectionRequest = parent.model.editRequest }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            guard replacementString.utf8.count <= ResourceLimits.inputBytes else {
                parent.model.notice = L("输入超过 64 KB，请分批粘贴。")
                return false
            }
            let proposed = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
            guard proposed.utf8.count <= ResourceLimits.inputBytes else {
                parent.model.notice = L("输入超过 64 KB，请分批粘贴。")
                return false
            }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? LinkTextView else { return }
            parent.model.input = editor.string
            if editor.string != parent.model.input {
                editor.string = parent.model.input
                editor.undoManager?.removeAllActions()
            }
            editor.needsDisplay = true
        }
    }
}

final class LinkScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let editor = documentView as? LinkTextView else { return }
        let width = contentSize.width
        guard width > 0 else { return }
        if editor.frame.width != width {
            editor.setFrameSize(NSSize(width: width, height: max(editor.frame.height, contentSize.height)))
        }
        // Overlay scrollers do not reduce contentSize; wrap URLs before their track.
        // Legacy scrollers already reserve their own width.
        let gutter: CGFloat = scrollerStyle == .overlay ? 16 : 0
        editor.textContainer?.containerSize = NSSize(width: max(1, width - 2 * editor.textContainerInset.width - gutter),
                                                    height: .greatestFiniteMagnitude)
    }
}

struct SlidingSegments<Selection: Hashable>: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding var selection: Selection
    let options: [Selection]
    let title: (Selection) -> String
    var segmentWidth: CGFloat = 80
    var accessibilityName = L("设置分类")
    let palette: ThemePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTab: Selection?

    private var selectionShape: some View {
        RoundedRectangle(cornerRadius: 7).frame(width: segmentWidth, height: 24)
            .offset(x: 2 + CGFloat(options.firstIndex(of: selection) ?? 0) * segmentWidth)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.08), value: selection)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            selectionShape.foregroundStyle(ThemePalette.color(palette.action)).allowsHitTesting(false)
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { tab in
                    Button { selection = tab } label: {
                        Text(title(tab)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ThemePalette.color(palette.secondary))
                            .frame(width: segmentWidth, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).focused($focusedTab, equals: tab)
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }.padding(.horizontal, 2)
            // Keep text contrast tied to the moving thumb, including interrupted reversals.
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { tab in
                    Text(title(tab)).font(.system(size: 12, weight: .medium)).frame(width: segmentWidth, height: 28)
                }
            }.padding(.horizontal, 2).foregroundStyle(ThemePalette.color(palette.onAction))
                .mask(alignment: .leading) { selectionShape }
                .allowsHitTesting(false).accessibilityHidden(true)
        }.frame(width: segmentWidth * CGFloat(options.count) + 4, height: 28)
            .background(ThemePalette.color(palette.surface), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain).accessibilityLabel(accessibilityName)
            .onMoveCommand { direction in
                let index = options.firstIndex(of: selection) ?? 0
                if direction == .left { selection = options[max(0, index - 1)]; focusedTab = selection }
                if direction == .right { selection = options[min(options.count - 1, index + 1)]; focusedTab = selection }
            }
    }
}

// A decorative toolbar label lets mouse events reach the native title bar.
final class WindowTitleField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// AppKit owns window controls, dragging and full-screen layout. Only the
// toolbar's content and colors are customized, using public macOS 13 APIs.
@MainActor
final class WindowChrome: NSObject, NSToolbarDelegate {
    private static let titleID = NSToolbarItem.Identifier("window-title")
    private weak var window: NSWindow?
    private let titleField: NSTextField
    private var themeObservation: AnyCancellable?

    init(window: NSWindow, model: DownloadModel, title: String, workspace: Bool = false) {
        self.window = window
        self.titleField = WindowTitleField(labelWithString: title)
        super.init()
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.alignment = .center
        titleField.setAccessibilityLabel(title)
        let toolbar = NSToolbar(identifier: "\(title)-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleID]
        window.toolbar = workspace ? nil : toolbar
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !window.styleMask.contains(.miniaturizable)
        window.standardWindowButton(.zoomButton)?.isHidden = !window.styleMask.contains(.resizable)
        if workspace { window.isMovableByWindowBackground = true }
        themeObservation = model.$theme.sink { [weak self] theme in self?.applyTheme(theme) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.titleID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.titleID, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.titleID else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = titleField.stringValue
        titleField.frame.size = NSSize(width: 140, height: 18)
        item.view = titleField
        return item
    }

    private func applyTheme(_ theme: AppTheme) {
        func color(_ keyPath: KeyPath<ThemePalette, UInt32>) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return ThemePalette.nativeColor(theme.palette(dark: dark)[keyPath: keyPath])
            }
        }
        window?.backgroundColor = color(\.canvas)
        titleField.textColor = color(\.text)
    }
}

@MainActor
enum AboutInformation {
    static let repository = URL(string: "https://github.com/cleardusk/folioak")!
    struct Component {
        let name: String
        let version: String
        let license: String
        let url: URL
    }
    static func components(in tools: MediaTools) -> [Component] {
        // Read the prepared bundle, so updating a pinned component cannot leave
        // an independently hardcoded version behind in the About panel.
        let data = try? Data(contentsOf: tools.directory.appendingPathComponent("versions.json"))
        let manifest = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let versions = manifest?["versions"] as? [String: Any] ?? [:]
        let definitions = [("yt-dlp", "yt-dlp", "Unlicense / GPLv3+", "https://github.com/yt-dlp/yt-dlp/releases/tag/"),
                           ("ffmpeg", "FFmpeg / ffprobe", "LGPL", "https://github.com/FFmpeg/FFmpeg/tree/n"),
                           ("quickjs", "QuickJS-NG", "MIT", "https://github.com/quickjs-ng/quickjs/releases/tag/v")]
        var components = definitions.compactMap { key, name, license, base -> Component? in
            guard let version = versions[key] as? String, let url = URL(string: base + version) else { return nil }
            return Component(name: name, version: version, license: license, url: url)
        }
        let python = tools.directory.appendingPathComponent("_internal/Python.framework/Resources/Info.plist")
        if let data = try? Data(contentsOf: python),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = values["CFBundleShortVersionString"] as? String,
           let url = URL(string: "https://www.python.org/downloads/release/python-" + version.replacingOccurrences(of: ".", with: "") + "/") {
            components.append(Component(name: "CPython", version: version, license: "PSF", url: url))
        }
        return components
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var windowChrome: WindowChrome?
    private let model: DownloadModel
    private var menuBar: MenuBarController?
    private var terminationPending = false
    private var shortcutObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var updateObservation: AnyCancellable?
    private var automaticUpdateObservation: AnyCancellable?
    private var updateTimer: Timer?
    private var presentingUpdate = false

    init(model: DownloadModel? = nil, menuBar: MenuBarController? = nil) {
        self.model = model ?? DownloadModel(stateURL: WorkspaceStore.defaultURL)
        self.menuBar = menuBar
        super.init()
        AppLocalization.shared.language = self.model.language
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.prepareDefaultDirectory()
        NSApp.setActivationPolicy(.regular)
        model.applyAppearance()
        makeMenu()
        shortcutObservation = model.shortcuts.$bindings.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.makeMenu() } }
        languageObservation = model.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.makeMenu()
            }
        }
        createMainWindow()
        menuBar = MenuBarController(model: model, openWindow: { [weak self] in self?.showMainWindow() },
                                    openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) }, disabled: { [weak self] in
            if self?.window?.isVisible == false { self?.showMainWindow() }
        })
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        model.trace.record(.windowShown, context: .mainWindow)
        NSApp.activate(ignoringOtherApps: true)
        updateObservation = model.updates.$notice.sink { [weak self] _ in
            DispatchQueue.main.async { self?.presentUpdateIfPossible() }
        }
        automaticUpdateObservation = model.updates.$automaticallyChecks.dropFirst().sink { [weak self] enabled in
            if enabled { DispatchQueue.main.async { self?.checkUpdatesAutomatically() } }
        }
        updateTimer = Timer.scheduledTimer(timeInterval: 15 * 60, target: self,
                                          selector: #selector(checkUpdatesAutomatically), userInfo: nil, repeats: true)
        checkUpdatesAutomatically()
    }

    private func createMainWindow(restoresFrame: Bool = true) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Folioak"
        if restoresFrame { window.setFrameAutosaveName("ArxivDownloaderWorkspaceWindow") }
        windowChrome = WindowChrome(window: window, model: model, title: "Folioak", workspace: true)
        window.contentView = NSHostingView(rootView: DownloaderView(model: model, showSettings: { [weak self] in self?.showSettings() }, endTextEditing: { [weak window] in
            // End editing only in this workspace, leaving list navigation intact.
            if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        }))
        window.minSize = NSSize(width: 820, height: 600)
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var frame = window.frame
            frame.size = NSSize(width: max(frame.width, window.minSize.width), height: max(frame.height, window.minSize.height))
            window.setFrame(frame, display: false)
        }
        window.delegate = self
    }

    #if TESTING
    func prepareWorkspaceForTesting() -> NSWindow {
        createMainWindow(restoresFrame: false)
        window.animationBehavior = .none
        return window
    }
    #endif

    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        checkUpdatesAutomatically()
        presentUpdateIfPossible()
    }

    func applicationWillTerminate(_ notification: Notification) { updateTimer?.invalidate() }

    func windowDidEndSheet(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.presentUpdateIfPossible() }
    }

    func windowDidBecomeKey(_ notification: Notification) { presentUpdateIfPossible() }

    @objc private func checkUpdatesAutomatically() {
        Task { [weak self] in await self?.model.updates.check() }
        presentUpdateIfPossible()
    }

    @objc func checkForUpdates() {
        guard !presentingUpdate else { return }
        model.updates.dismiss()
        showMainWindow()
        Task { [weak self] in await self?.model.updates.check(manual: true) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(navigateBack) || menuItem.action == #selector(navigateForward) {
            guard let window, NSApp.keyWindow === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
            return menuItem.action == #selector(navigateBack) ? !model.navigation.back.isEmpty : !model.navigation.forward.isEmpty
        }
        return menuItem.action != #selector(checkForUpdates) || (!model.updates.isChecking && !presentingUpdate)
    }

    private func presentUpdateIfPossible() {
        guard !presentingUpdate, NSApp.isActive, NSApp.modalWindow == nil,
              let notice = model.updates.notice, let window = window,
              window.attachedSheet == nil else { return }
        // Background results wait until Folioak is active; they never bring it to the front.
        let parent = window
        guard parent.isVisible else { return }
        presentingUpdate = true
        let alert = UpdatePresentation.alert(for: notice, currentVersion: model.updates.currentVersion)
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self else { return }
            self.presentingUpdate = false
            if let failure = UpdatePresentation.respond(to: notice, response: response, checker: self.model.updates, open: self.model.opener) {
                failure.beginSheetModal(for: parent)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.showsMenuBarIcon }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard model.busy else {
            model.cancelVersionCheck()
            terminationPending = true
            Task { [self] in
                await model.persistWorkspaceAndWait()
                await model.finishTrace()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = L("仍有文件正在下载")
        alert.informativeText = L("已保存的文件会保留。退出将停止当前下载和等待中的任务。")
        alert.addButton(withTitle: L("继续下载"))
        alert.addButton(withTitle: L("停止并退出"))
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        terminationPending = true
        Task { [self] in
            await model.cancelAndWait()
            await model.finishTrace()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            if model.showsMenuBarIcon { sender.orderOut(nil); model.trace.record(.windowHidden, context: .mainWindow); model.saveWorkspace() }
            else { NSApp.terminate(sender) }
            return false
        }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    private func showMainWindow() {
        model.trace.record(.windowShown, context: .mainWindow)
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func focusInput() {
        if menuBar?.focusInputIfShown() == true { return }
        guard window.attachedSheet == nil, !model.busy else { return }
        window.makeKeyAndOrderFront(nil)
        model.focusInput()
    }
    @objc private func focusList() {
        guard window.attachedSheet == nil else { return }
        window.makeKeyAndOrderFront(nil); model.listRequest = UUID()
    }
    @objc private func focusSearch() {
        guard NSApp.keyWindow === window, window.attachedSheet == nil else { return }
        model.searchRequest = UUID()
    }
    @objc private func startDownload() {
        guard model.preferencesPage == nil, NSApp.keyWindow === window, window.attachedSheet == nil, !model.busy else { return }
        model.start()
    }

    func showPreferences(_ destination: WorkspacePreferencesPage) {
        guard let window else { return }
        if window.attachedSheet == nil { model.preferencesPage = destination }
        showMainWindow()
    }
    @objc private func showAbout() { showPreferences(.about) }
    @objc private func showSettings() { showPreferences(.settings) }

    @objc private func navigateBack() {
        guard let window, NSApp.keyWindow === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        model.navigation.goBack()
    }
    @objc private func navigateForward() {
        guard let window, NSApp.keyWindow === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        model.navigation.goForward()
    }

    func makeMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ items: [(String, Selector?, String)]) -> NSMenu {
            let submenu = NSMenu(title: title)
            for (name, action, key) in items {
                submenu.addItem(name.isEmpty ? .separator() : NSMenuItem(title: name, action: action, keyEquivalent: key))
            }
            let parent = title.isEmpty ? NSMenuItem() : NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = submenu; menu.addItem(parent)
            return submenu
        }
        let app = add("", [
            (L("关于 Folioak"), #selector(showAbout), ""),
            (L("检查更新…"), #selector(checkForUpdates), ""), ("", nil, ""),
            (L("设置…"), #selector(showSettings), ","), ("", nil, ""),
            (L("隐藏 Folioak"), #selector(NSApplication.hide(_:)), "h"), ("", nil, ""),
            (L("退出 Folioak"), #selector(NSApplication.terminate(_:)), "q")
        ])
        app.item(withTitle: L("关于 Folioak"))?.target = self
        app.item(withTitle: L("检查更新…"))?.target = self
        app.item(withTitle: L("设置…"))?.target = self
        for (title, symbol) in [(L("关于 Folioak"), "info.circle"), (L("检查更新…"), "arrow.triangle.2.circlepath"), (L("设置…"), "gearshape")] {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            image?.size = NSSize(width: 16, height: 16)
            image?.isTemplate = true
            app.item(withTitle: title)?.image = image
        }
        let edit = add(L("编辑"), [
            (L("撤销"), Selector(("undo:")), "z"), (L("重做"), Selector(("redo:")), "z"), ("", nil, ""),
            (L("剪切"), #selector(NSText.cut(_:)), "x"), (L("复制"), #selector(NSText.copy(_:)), "c"),
            (L("粘贴"), #selector(NSText.paste(_:)), "v"), (L("全选"), #selector(NSText.selectAll(_:)), "a")
        ])
        edit.item(withTitle: L("重做"))?.keyEquivalentModifierMask = [.command, .shift]
        let find = NSMenuItem(title: L("搜索"), action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self; edit.addItem(.separator()); edit.addItem(find)
        let navigation = add(L("前往"), [(L("添加链接"), #selector(focusInput), "l"), (L("文件列表"), #selector(focusList), "j")])
        navigation.items.forEach { $0.target = self }
        let start = NSMenuItem(title: L("开始下载"), action: #selector(startDownload), keyEquivalent: "\r"); start.target = self; navigation.addItem(start)
        for (action, item) in [(ShortcutAction.input, navigation.items[0]), (.list, navigation.items[1]), (.download, start)] {
            item.keyEquivalent = model.shortcuts[action].key; item.keyEquivalentModifierMask = model.shortcuts[action].flags
        }
        navigation.addItem(.separator())
        for (title, action, key) in [(L("后退"), #selector(navigateBack), "["), (L("前进"), #selector(navigateForward), "]")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; navigation.addItem(item)
        }
        NSApp.windowsMenu = add(L("窗口"), [(L("关闭窗口"), #selector(NSWindow.performClose(_:)), "w"), (L("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = menu
    }
}

#if !TESTING
@main
struct ArxivDownloaderApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
