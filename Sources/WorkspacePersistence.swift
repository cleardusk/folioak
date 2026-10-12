import Foundation

// Owns disk access and its ordering. The model owns snapshots and revision checks.
@MainActor final class WorkspacePersistence {
    struct Request {
        let sequence: Int, revision: Int, libraryRevision: Int, mediaRevision: Int
        let snapshot: WorkspaceSnapshot
        let stateURL: URL, libraryURL: URL?, mediaURL: URL?
        let papers: [LibraryPaper]?, media: [DownloadItem]?
    }
    struct WriteResult {
        let workspace: Result<WorkspaceSnapshot, Error>
        let libraryError: String?, mediaError: String?
    }

    let stateURL: URL
    let libraryURL: URL
    let mediaURL: URL
    private let queue = DispatchQueue(label: "local.paperrepo.workspace-save", qos: .utility)
    private var damagedState = false

    init(_ stateURL: URL) {
        self.stateURL = stateURL
        let name = stateURL.deletingPathExtension().lastPathComponent == "workspace"
            ? "library.json" : stateURL.lastPathComponent + ".library.json"
        libraryURL = stateURL.deletingLastPathComponent().appendingPathComponent(name)
        mediaURL = libraryURL.deletingLastPathComponent().appendingPathComponent("media-" + name)
    }

    func readWorkspace() throws -> WorkspaceSnapshot? {
        do { return try queue.sync { try WorkspaceStore.read(stateURL) } }
        catch { damagedState = true; throw error }
    }

    func prepareForSaving() throws {
        guard damagedState, FileManager.default.fileExists(atPath: stateURL.path) else { return }
        // Preserve unreadable / future-schema files instead of overwriting them.
        try queue.sync {
            try FileManager.default.moveItem(at: stateURL, to: stateURL.appendingPathExtension("backup-\(UUID().uuidString)"))
        }
        damagedState = false
    }

    func replaceWorkspace(_ snapshot: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
        try prepareForSaving()
        return try queue.sync { try WorkspaceStore.write(snapshot, to: stateURL) }
    }

    func writeLibrary(_ papers: [LibraryPaper]) throws {
        try queue.sync { try LibraryStore.write(papers, to: libraryURL) }
    }

    func writeMediaLibrary(_ items: [DownloadItem]) throws {
        try queue.sync { try MediaLibraryStore.write(items, to: mediaURL) }
    }

    func save(_ request: Request, completion: @escaping @MainActor (WriteResult) -> Void) {
        queue.async {
            let result = Self.write(request)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func flush(_ request: Request) -> WriteResult {
        queue.sync { Self.write(request) }
    }

    func flushAndWait(_ request: Request) async -> WriteResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.write(request)) }
        }
    }

    private nonisolated static func write(_ request: Request) -> WriteResult {
        var libraryError: String?, mediaError: String?
        if let papers = request.papers, let url = request.libraryURL {
            do { try LibraryStore.write(papers, to: url) }
            catch { libraryError = "文档库未能保存：\(error.localizedDescription)" }
        }
        if let media = request.media, let url = request.mediaURL {
            do { try MediaLibraryStore.write(media, to: url) }
            catch { mediaError = "媒体库未能保存：\(error.localizedDescription)" }
        }
        return WriteResult(workspace: Result { try WorkspaceStore.write(request.snapshot, to: request.stateURL) },
                           libraryError: libraryError, mediaError: mediaError)
    }
}
