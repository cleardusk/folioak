import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
private typealias LibraryViewState<Value> = SwiftUI.State<Value>

struct LibraryPaper: Identifiable, Codable, Sendable {
    var id = UUID()
    var title: String
    var authors: String
    var original: String
    var metadata: PaperMetadata?
    var reference: ArxivReference?
    var directURL: URL?
    var file: URL?
    var pages: Int?
    var addedAt = Date()
    var tags: [String] = []
    var favorite = false
    var read = false
    var missing = false
    var removed = false
    var latest: ArxivReference?
    var checkedAt: Date?
    var taskID: UUID?
    var namingSnapshot: AssetNamingSnapshot?

    init(_ item: DownloadItem) {
        id = item.id; title = PaperMetadata.cleanTitle(item.title)
        authors = String((item.metadata?.authors?.joined(separator: ", ") ?? "").prefix(16_384))
        original = item.original; metadata = item.metadata
        reference = item.metadata?.reference ?? item.reference; directURL = item.directURL
        file = item.savedURL; pages = item.pages; addedAt = item.finishedAt ?? item.createdAt
        missing = item.state == .missing; taskID = item.id; namingSnapshot = item.namingSnapshot
    }
    var source: DownloadSource? {
        if let reference { return .arxiv(reference) }
        guard let directURL else { return nil }
        return GenericFileStorage.extensions.contains(file?.pathExtension.lowercased() ?? directURL.pathExtension.lowercased()) ? .file(directURL) : .pdf(directURL)
    }
    var identity: String { source?.webURL.absoluteString ?? file?.standardizedFileURL.path ?? id.uuidString }
    var hasUpdate: Bool {
        guard let reference, let version = reference.version, let latest, latest.baseID == reference.baseID else { return false }
        return (latest.version ?? 0) > version
    }
    var downloadItem: DownloadItem {
        DownloadItem(id: id, original: original, reference: reference, directURL: directURL, metadata: metadata,
                     state: missing ? .missing : .saved, savedURL: file, pages: pages,
                     documentTitle: title, createdAt: addedAt, finishedAt: addedAt, namingSnapshot: namingSnapshot)
    }
    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let fields = [title, authors, original, reference?.identifier ?? "", directURL?.host ?? "", tags.joined(separator: " "), file?.lastPathComponent ?? ""]
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
    static func cleanTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(20).map { $0 }
    }
}

enum LibraryFilter: String, CaseIterable { case all = "全部", favorites = "收藏", unread = "未读", removed = "已移除" }
enum LibrarySort: String, CaseIterable { case newest = "最近添加", title = "标题", year = "发表年份" }

enum LibraryStore {
    static let byteLimit = 32 * 1024 * 1024
    static let countLimit = 20_000
    struct Snapshot: Codable { var schema = 1; var papers: [LibraryPaper] }
    static func read(_ url: URL) throws -> [LibraryPaper]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try PaperStorage.read(url, limit: byteLimit, tooLarge: "文档库超过 32 MB。")
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schema == 1, snapshot.papers.count <= countLimit,
              Set(snapshot.papers.map(\.id)).count == snapshot.papers.count else { throw DownloadError.storage("文档库格式无效。") }
        // Older downloads can have a media-looking preview URL but contain a PDF.
        // Keep their library records readable when a new preview route is added.
        snapshot.papers = snapshot.papers.map { paper in
            guard paper.reference == nil, let url = paper.directURL,
                  let normalized = (try? DownloadSource.parse(url.absoluteString))?.directURL else { return paper }
            var result = paper
            result.directURL = normalized
            return result
        }
        guard snapshot.papers.allSatisfy(valid) else { throw DownloadError.storage("文档库格式无效。") }
        return snapshot.papers
    }
    static func valid(_ paper: LibraryPaper) -> Bool {
        (paper.namingSnapshot?.valid ?? true) && paper.title.count <= ResourceLimits.titleCharacters && paper.authors.count <= 16_384 && paper.original.utf8.count <= ResourceLimits.inputBytes &&
        paper.tags.count <= 20 && paper.tags.allSatisfy { $0.count <= 40 } &&
        [paper.reference, paper.latest, paper.metadata?.reference].compactMap { $0 }.allSatisfy { (try? ArxivReference.parse($0.identifier)) == $0 } &&
        (paper.file.map { $0.isFileURL && ($0.pathExtension.lowercased() == "pdf" || GenericFileStorage.extensions.contains($0.pathExtension.lowercased())) } ?? true) &&
        (paper.directURL.map { (try? DownloadSource.parse($0.absoluteString))?.directURL == $0 } ?? true) &&
        !(paper.reference != nil && paper.directURL != nil) &&
        (paper.latest.map { $0.baseID == paper.reference?.baseID } ?? true)
    }
    static func write(_ papers: [LibraryPaper], to url: URL) throws {
        guard papers.count <= countLimit else { throw DownloadError.limit("文档库最多保存 20,000 项，已有文档不会被自动移除。") }
        guard Set(papers.map(\.id)).count == papers.count, papers.allSatisfy(valid) else { throw DownloadError.storage("文档库格式无效，已有文件保持不变。") }
        let data = try JSONEncoder().encode(Snapshot(papers: papers))
        guard data.count <= byteLimit else { throw DownloadError.limit("文档库超过 32 MB，已有文件保持不变。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func imported(_ url: URL) throws -> LibraryPaper {
        let pages = try PaperStorage.validatePDF(at: url)
        guard let pdf = PDFDocument(url: url) else { throw DownloadError.invalidPDF }
        let rawTitle = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = PaperMetadata.cleanTitle(rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawTitle! : url.deletingPathExtension().lastPathComponent)
        var paper = LibraryPaper(DownloadItem(original: url.lastPathComponent, state: .saved, savedURL: url.standardizedFileURL, pages: pages, documentTitle: title))
        paper.authors = String((pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? "").prefix(16_384))
        paper.taskID = nil
        return paper
    }
}

extension DownloadModel {
    private func canChangeLibrary() -> Bool {
        if !libraryWritable { notice = "文档库只读，无法保存新增或修改；原文件已保留。" }
        return libraryWritable
    }
    func upsertPaper(_ item: DownloadItem) {
        guard item.savedURL.map({ $0.pathExtension.lowercased() == "pdf" || GenericFileStorage.extensions.contains($0.pathExtension.lowercased()) }) ?? (item.source?.isPaper != false) else { return }
        guard item.savedURL != nil || item.state == .missing else { return }
        guard canChangeLibrary() else { return }
        let incoming = LibraryPaper(item)
        if let index = papers.firstIndex(where: { $0.identity == incoming.identity || ($0.file != nil && $0.file == incoming.file && ($0.source == nil || incoming.source == nil)) }) {
            var updated = incoming
            let old = papers[index]
            updated.id = old.id; updated.addedAt = old.addedAt; updated.tags = old.tags; updated.favorite = old.favorite; updated.read = old.read
            updated.title = old.title
            updated.latest = old.latest; updated.checkedAt = old.checkedAt
            updated.removed = old.removed
            papers[index] = updated
        } else {
            guard papers.count < LibraryStore.countLimit else { libraryNotice = "文档库已满，下载文件仍已保存。"; return }
            var added = incoming
            if let base = incoming.reference?.baseID, let old = papers.first(where: { !$0.removed && $0.reference?.baseID == base }) {
                added.tags = old.tags; added.favorite = old.favorite
            }
            papers.append(added)
        }
    }
    func changePaper(_ id: UUID, _ change: (inout LibraryPaper) -> Void) {
        guard canChangeLibrary() else { return }
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        change(&papers[index])
    }
    func importPDFs() {
        guard !importingPDFs, canChangeLibrary() else { return }
        let panel = NSOpenPanel(); panel.title = L("导入 PDF"); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        present(panel) { [weak self] response in
            guard response == .OK, let self else { return }
            self.importPDFs(panel.urls)
        }
    }
    func importPDFs(_ urls: [URL]) {
        guard !importingPDFs, canChangeLibrary() else { return }
        notice = nil
        guard urls.count <= ResourceLimits.batchCount else { notice = "每次最多导入 200 篇。"; return }
        importingPDFs = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([LibraryPaper], Int) in
                var imported: [LibraryPaper] = []; var failed = 0
                for url in urls { do { imported.append(try LibraryStore.imported(url)) } catch { failed += 1 } }
                return (imported, failed)
            }.value
            guard let self else { return }
            for paper in result.0 where !self.papers.contains(where: { $0.file == paper.file }) {
                guard self.papers.count < LibraryStore.countLimit else { self.notice = "文档库已满，原 PDF 保持不变。"; break }
                self.papers.append(paper)
            }
            self.importingPDFs = false
            if result.1 > 0 { self.notice = "\(result.1) 个文件无法读取。" }
            self.saveWorkspace()
        }
    }
    func relinkPaper(_ id: UUID) {
        guard canChangeLibrary() else { return }
        guard let paper = papers.first(where: { $0.id == id }) else { return }
        let ext = paper.file?.pathExtension.lowercased() ?? "pdf"
        let panel = NSOpenPanel(); panel.title = L("重新关联文件")
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    try await self.relinkPaper(id, to: url)
                } catch { self.notice = error.localizedDescription }
            }
        }
    }
    func relinkPaper(_ id: UUID, to url: URL) async throws {
        guard canChangeLibrary(), let paper = papers.first(where: { $0.id == id }) else { return }
        let ext = paper.file?.pathExtension.lowercased() ?? "pdf"
        let imported = try await Task.detached(priority: .userInitiated) { () -> LibraryPaper in
            if ext == "pdf" { return try LibraryStore.imported(url) }
            guard url.pathExtension.lowercased() == ext else { throw DownloadError.metadata("请选择相同格式的文件。") }
            try await GenericFileStorage.validate(url, extension: ext)
            return LibraryPaper(DownloadItem(original: url.lastPathComponent, state: .saved, savedURL: url.standardizedFileURL))
        }.value
        changePaper(id) { $0.file = imported.file; $0.pages = imported.pages; $0.missing = false }
        let related = Set([paper.id, paper.taskID].compactMap { $0 })
        func relinked(_ item: DownloadItem) -> DownloadItem {
            guard related.contains(item.id), item.state.terminal else { return item }
            var updated = item
            updated.savedURL = imported.file; updated.pages = imported.pages
            updated.state = .saved; updated.incompleteFileList = false
            updated.error = nil; updated.errorMessage = nil
            return updated
        }
        items = items.map(relinked); history = history.map(relinked)
        if let previous = paper.file, previewURL == previous { previewURL = imported.file }
        if let current = papers.first(where: { $0.id == id }) { _ = localFile(current.downloadItem) }
        notice = nil
        saveWorkspace()
    }
    func checkPaperVersions(_ ids: [UUID]) {
        guard versionWorker == nil, canChangeLibrary() else { return }
        let wanted = Set(ids)
        let selected = papers.filter { wanted.contains($0.id) && !$0.removed && $0.reference != nil }
        guard !selected.isEmpty else { return }
        guard selected.count <= ResourceLimits.batchCount else { notice = "每次最多检查 200 篇，请先筛选文档库。"; return }
        checkingVersions = Set(selected.map(\.id))
        notice = nil
        versionWorker = Task { [weak self, engine] in
            var checked: [String: ArxivReference] = [:]
            var failures = 0
            checking: for paper in selected {
                if Task.isCancelled { break }
                do {
                    let base = paper.reference!.baseID
                    let latest: ArxivReference
                    if let cached = checked[base] { latest = cached }
                    else { latest = try await engine.latestReference(base); checked[base] = latest }
                    self?.changePaper(paper.id) { $0.latest = latest; $0.checkedAt = Date() }
                } catch is CancellationError { break }
                catch {
                    switch error {
                    case DownloadError.metadata, DownloadError.http(404, _): failures += 1
                    default: self?.notice = "版本检查已停止：\(error.localizedDescription)"; break checking
                    }
                }
                self?.checkingVersions.remove(paper.id)
            }
            if failures > 0, self?.notice == nil { self?.notice = "\(failures) 篇未能检查，其余已完成。" }
            self?.checkingVersions = []; self?.versionWorker = nil; self?.saveWorkspace()
        }
    }
    func cancelVersionCheck() { versionWorker?.cancel() }
    func downloadLatest(_ paper: LibraryPaper) {
        guard !busy, let reference = paper.latest, paper.hasUpdate else { return }
        retryFromLibrary(DownloadItem(original: reference.identifier, reference: reference, state: .queued))
    }
    func showPaperDetails(_ paper: LibraryPaper) {
        diagnosticItem = paper.downloadItem
    }
    func openPaper(_ paper: LibraryPaper, preview: Bool = false) {
        guard let file = localFile(paper.downloadItem), FileManager.default.isReadableFile(atPath: file.path) else {
            changePaper(paper.id) { $0.missing = true }; notice = "文件已移动或不可读，请重新关联。"; return
        }
        if preview { previewURL = file }
        else if !opener(file) { notice = "无法打开文件，请检查默认应用。"; return }
        if let current = papers.first(where: { $0.id == paper.id }), !current.read || current.missing {
            changePaper(paper.id) { $0.read = true; $0.missing = false }
        }
        if libraryWritable { notice = nil }
    }
}

struct LibraryEditView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    let paper: LibraryPaper
    @LibraryViewState private var title = ""
    @LibraryViewState private var tags = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("整理文档")).font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 8) { Text(L("标题")); TextField(L("标题"), text: $title) }
            VStack(alignment: .leading, spacing: 8) { Text(L("标签")); TextField(L("用逗号分隔"), text: $tags) }
            HStack { Spacer(); Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("完成")) {
                    model.changePaper(paper.id) { $0.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ResourceLimits.titleCharacters)); $0.tags = LibraryPaper.cleanTags(tags) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 12)).padding(24).frame(width: 440)
            .onAppear { title = paper.title; tags = paper.tags.joined(separator: ", ") }
    }
}

struct LibraryRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    let paper: LibraryPaper
    @ObservedObject var model: DownloadModel
    let selected: Bool
    var selectionActive = true
    var grid = false
    let select: () -> Void
    @StateObject private var clickTarget = FileRowClickTarget()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    var body: some View {
        Group {
            if grid {
                AssetGridCard(title: paper.title, subtitle: paper.missing ? L("文件缺失") : paper.reference?.identifier ?? paper.directURL?.host ?? L("本地文件"),
                    file: paper.missing ? nil : paper.file, symbol: paper.downloadItem.symbol,
                    badge: paper.file?.pathExtension.uppercased() ?? "PDF",
                    palette: palette, revision: "\(model.fileRefreshRevision)", subtitleIsError: paper.missing, favorite: paper.favorite, unread: !paper.read) { controls }
            } else { rowContent }
        }.padding(.horizontal, grid ? 6 : 10).padding(.vertical, grid ? 6 : WorkspaceMetrics.Space.regular)
            .background(selected && selectionActive ? ThemePalette.color(palette.accent).opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control, style: .continuous))
            .overlay(alignment: .bottom) {
                if !grid { Rectangle().fill(ThemePalette.color(palette.border).opacity(0.6)).frame(height: 1 / displayScale)
                    .padding(.leading, 10 + WorkspaceMetrics.rowIconSize + WorkspaceMetrics.Space.regular).padding(.trailing, 10) }
            }
            .overlay { if grid && selected && selectionActive { RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control).stroke(ThemePalette.color(palette.accent).opacity(0.6), lineWidth: 1) } }
            .contentShape(Rectangle())
            .background(FileRowClickRegion(target: clickTarget) {
                if let current = model.papers.first(where: { $0.id == paper.id }), !current.removed { model.openPaper(current) }
            })
            .onAppear { clickTarget.setActive(true) }
            .onDisappear { clickTarget.setActive(false) }
            .onTapGesture(perform: select).contextMenu { actions }
            .accessibilityElement(children: .contain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var rowContent: some View {
        HStack(alignment: .top, spacing: WorkspaceMetrics.Space.regular) {
            FileThumbnail(url: paper.missing ? nil : paper.file, fallbackSymbol: paper.downloadItem.symbol, palette: palette, revision: "\(model.fileRefreshRevision)")
                .accessibilityHidden(false)
                .accessibilityLabel(L("文档"))
                .overlay(alignment: .topTrailing) {
                    if !paper.read {
                        Circle().fill(ThemePalette.color(palette.accent)).frame(width: 5, height: 5)
                            .padding(6).accessibilityLabel(L("未读"))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if paper.favorite {
                        Image(systemName: "star.fill").font(.system(size: 9))
                            .foregroundStyle(ThemePalette.color(palette.accent))
                            .frame(width: 14, height: 14)
                            .background(ThemePalette.color(palette.canvas), in: Circle())
                            .accessibilityLabel(L("已收藏"))
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(paper.title).font(WorkspaceMetrics.TypeScale.rowTitle).lineLimit(2).lineSpacing(3).help(paper.title)
                HStack(spacing: 10) {
                    if let ref = paper.reference { Text(ref.identifier).font(.system(size: 11, design: .monospaced)) }
                    else { Text(paper.directURL?.host ?? L("本地文件")).lineLimit(1) }
                    if let ext = paper.file?.pathExtension.lowercased(), GenericFileStorage.extensions.contains(ext) { Text(ext.uppercased()) }
                    if let pages = paper.pages { Text(L("\(pages) 页")) }
                    if paper.hasUpdate { Text(L("有 v\(paper.latest!.version!)")).foregroundStyle(ThemePalette.color(palette.accent)) }
                    if paper.missing { Text(L("文件缺失")).foregroundStyle(UIColors.error) }
                }.font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                if !paper.tags.isEmpty { Text(paper.tags.joined(separator: " · ")).font(.system(size: 11)).lineLimit(1).foregroundStyle(ThemePalette.color(palette.secondary)) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
               .contentShape(Rectangle())
            controls
        }
    }
    private var controls: some View {
            HStack(spacing: WorkspaceMetrics.Space.small) {
                if paper.removed { Button(L("恢复")) { Task { _ = await model.setLibraryRemoved([paper.id], in: .documents, removed: false) } }
                    .buttonStyle(QuietButtonStyle(palette: palette)).disabled(!model.canManageLibrary(.documents)) }
                else if paper.missing { Button(L("关联")) { model.relinkPaper(paper.id) }.buttonStyle(QuietButtonStyle(palette: palette)) }
                else { Button(L("打开")) { model.openPaper(paper) }.buttonStyle(RowActionStyle(palette: palette)) }
                Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                        .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32).accessibilityLabel(L("\(paper.title)的更多操作"))
            }.padding(.top, 1).background(FileRowClickRegion(target: clickTarget, controls: true))
    }
    @ViewBuilder private var actions: some View {
        if !paper.removed {
            Button(L("快速预览")) { select(); model.openPaper(paper, preview: true) }.disabled(paper.missing)
            Button(paper.favorite ? L("取消收藏") : L("收藏")) { model.changePaper(paper.id) { $0.favorite.toggle() } }
            Button(paper.read ? L("标为未读") : L("标为已读")) { model.changePaper(paper.id) { $0.read.toggle() } }
            Button(L("整理文档…")) { select(); model.editingPaper = paper }
            Divider()
            if paper.reference != nil {
                Button(L("检查新版本")) { model.checkPaperVersions([paper.id]) }.disabled(!model.checkingVersions.isEmpty)
                if paper.hasUpdate { Button(L("下载 v\(paper.latest!.version!)")) { model.downloadLatest(paper) }.disabled(model.busy) }
                if let date = paper.checkedAt { Text(L("上次检查：\(L10n.date(date, time: .shortened))")) }
            }
            if let source = paper.source {
                Button(L("打开来源页面")) { model.openSource(paper.downloadItem) }
                Button(L("复制来源链接")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.webURL.absoluteString, forType: .string) }
                if paper.missing { Button(L("重新下载")) { model.retryFromLibrary(paper.downloadItem) }.disabled(model.busy) }
            }
            if let file = paper.file { Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            Button(L("重新关联文件…")) { model.relinkPaper(paper.id) }
            Button(L("详情…")) { select(); model.showPaperDetails(paper) }
            Divider()
            Button(L("移出文档库")) { Task { _ = await model.setLibraryRemoved([paper.id], in: .documents, removed: true) } }
                .help(L("保留文件，可从已移除的文档中恢复")).disabled(!model.canManageLibrary(.documents))
        } else {
            Button(L("恢复到文档库")) { Task { _ = await model.setLibraryRemoved([paper.id], in: .documents, removed: false) } }
                .disabled(!model.canManageLibrary(.documents))
        }
        Divider()
        Button(L("将文件移到废纸篓…"), role: .destructive) { model.requestFileTrash([paper.id], in: .documents) }
            .disabled(!model.canTrashFiles([paper.id], in: .documents))
    }
}

// Derived library data is independent of queue progress. Keep one query result
// and a bounded set of sort orders per revision, instead of redoing a 20k-row
// filter/sort for the header, selection and every body evaluation.
@MainActor final class LibraryQueryCache {
    struct Documents {
        let papers: [LibraryPaper]
        let items: [DownloadItem]
        let ids: [UUID]
    }
    private struct Query: Equatable {
        let revision: Int, text: String, filter: LibraryFilter, sort: LibrarySort, tag: String?
    }
    private var revision = -1
    private var query: Query?
    private var result = Documents(papers: [], items: [], ids: [])
    private var ordered: [LibrarySort: [LibraryPaper]] = [:]
    private(set) var papersByID: [UUID: LibraryPaper] = [:]
    private(set) var tags: [String] = []
    private(set) var documentBuilds = 0
    private var mediaRevision = -1
    private var mediaQuery = ""
    private var mediaRemoved = false
    private var mediaResult: [DownloadItem] = []
    private(set) var mediaBuilds = 0

    func documents(_ papers: [LibraryPaper], revision: Int, query text: String, filter: LibraryFilter,
                   sort: LibrarySort, tag: String?) -> Documents {
        let key = Query(revision: revision, text: text, filter: filter, sort: sort, tag: tag)
        if query == key { return result }
        if self.revision != revision {
            self.revision = revision
            ordered.removeAll(keepingCapacity: true)
            papersByID = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            tags = Array(Set(papers.filter { !$0.removed }.flatMap(\.tags))).sorted()
        }
        if ordered[sort] == nil {
            ordered[sort] = papers.sorted { left, right in
                switch sort {
                case .newest: return left.addedAt > right.addedAt
                case .title: return left.title.localizedStandardCompare(right.title) == .orderedAscending
                case .year: return (left.metadata?.year ?? 0) == (right.metadata?.year ?? 0)
                    ? left.addedAt > right.addedAt : (left.metadata?.year ?? 0) > (right.metadata?.year ?? 0)
                }
            }
        }
        let filtered = ordered[sort]!.filter { paper in
            paper.removed == (filter == .removed) && (filter != .favorites || paper.favorite) &&
            (filter != .unread || !paper.read) && (tag == nil || paper.tags.contains(tag!)) && paper.matches(text)
        }
        result = Documents(papers: filtered, items: filtered.map(\.downloadItem), ids: filtered.map(\.id))
        query = key; documentBuilds += 1
        return result
    }

    func media(_ items: [DownloadItem], revision: Int, query: String, removed: Bool) -> [DownloadItem] {
        if mediaRevision == revision && mediaQuery == query && mediaRemoved == removed { return mediaResult }
        mediaResult = items.filter { item in
            item.isLibraryRemoved == removed && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) ||
                item.original.localizedCaseInsensitiveContains(query) || item.localURLs.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(query) })
        }.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
        mediaRevision = revision; mediaQuery = query; mediaRemoved = removed; mediaBuilds += 1
        return mediaResult
    }
}
