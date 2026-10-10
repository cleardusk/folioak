import AppKit
import SwiftUI
import PDFKit
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

    init(_ item: DownloadItem) {
        id = item.id; title = PaperMetadata.cleanTitle(item.title)
        authors = String((item.metadata?.authors?.joined(separator: ", ") ?? "").prefix(16_384))
        original = item.original; metadata = item.metadata
        reference = item.metadata?.reference ?? item.reference; directURL = item.directURL
        file = item.savedURL; pages = item.pages; addedAt = item.finishedAt ?? item.createdAt
        missing = item.state == .missing; taskID = item.id
    }
    var source: DownloadSource? { reference.map(DownloadSource.arxiv) ?? directURL.map(DownloadSource.pdf) }
    var identity: String { source?.webURL.absoluteString ?? file?.standardizedFileURL.path ?? id.uuidString }
    var hasUpdate: Bool {
        guard let reference, let version = reference.version, let latest, latest.baseID == reference.baseID else { return false }
        return (latest.version ?? 0) > version
    }
    var downloadItem: DownloadItem {
        DownloadItem(id: id, original: original, reference: reference, directURL: directURL, metadata: metadata,
                     state: missing ? .missing : .saved, savedURL: missing ? nil : file, pages: pages,
                     documentTitle: title, createdAt: addedAt, finishedAt: addedAt)
    }
    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let fields = [title, authors, original, reference?.identifier ?? "", directURL?.host ?? "", tags.joined(separator: " ")]
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
        let data = try PaperStorage.read(url, limit: byteLimit, tooLarge: "资料库超过 32 MB。")
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schema == 1, snapshot.papers.count <= countLimit,
              Set(snapshot.papers.map(\.id)).count == snapshot.papers.count,
              snapshot.papers.allSatisfy(valid) else { throw DownloadError.storage("资料库格式无效。") }
        return snapshot.papers
    }
    static func valid(_ paper: LibraryPaper) -> Bool {
        paper.title.count <= ResourceLimits.titleCharacters && paper.authors.count <= 16_384 && paper.original.utf8.count <= ResourceLimits.inputBytes &&
        paper.tags.count <= 20 && paper.tags.allSatisfy { $0.count <= 40 } &&
        [paper.reference, paper.latest, paper.metadata?.reference].compactMap { $0 }.allSatisfy { (try? ArxivReference.parse($0.identifier)) == $0 } &&
        (paper.file.map { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" } ?? true) &&
        (paper.directURL.map { (try? DownloadSource.parse($0.absoluteString))?.directURL == $0 } ?? true) &&
        !(paper.reference != nil && paper.directURL != nil) &&
        (paper.latest.map { $0.baseID == paper.reference?.baseID } ?? true)
    }
    static func write(_ papers: [LibraryPaper], to url: URL) throws {
        guard papers.count <= countLimit else { throw DownloadError.limit("资料库最多保存 20,000 篇，已有论文不会被自动移除。") }
        guard Set(papers.map(\.id)).count == papers.count, papers.allSatisfy(valid) else { throw DownloadError.storage("资料库格式无效，已有文件保持不变。") }
        let data = try JSONEncoder().encode(Snapshot(papers: papers))
        guard data.count <= byteLimit else { throw DownloadError.limit("资料库超过 32 MB，已有文件保持不变。") }
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
        if !libraryWritable { notice = "资料库只读，无法保存新增或修改；原文件已保留。" }
        return libraryWritable
    }
    func upsertPaper(_ item: DownloadItem) {
        guard item.source?.isPaper != false, item.savedURL.map({ $0.pathExtension.lowercased() == "pdf" }) ?? true else { return }
        guard item.savedURL != nil || item.state == .missing else { return }
        guard canChangeLibrary() else { return }
        let incoming = LibraryPaper(item)
        if let index = papers.firstIndex(where: { $0.identity == incoming.identity || ($0.file != nil && $0.file == incoming.file && ($0.source == nil || incoming.source == nil)) }) {
            var updated = incoming
            let old = papers[index]
            updated.id = old.id; updated.addedAt = old.addedAt; updated.tags = old.tags; updated.favorite = old.favorite; updated.read = old.read
            updated.title = old.title
            updated.latest = old.latest; updated.checkedAt = old.checkedAt
            papers[index] = updated
        } else {
            guard papers.count < LibraryStore.countLimit else { libraryNotice = "资料库已满，下载文件仍已保存。"; return }
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
        let panel = NSOpenPanel(); panel.title = "导入 PDF"; panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
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
                guard self.papers.count < LibraryStore.countLimit else { self.notice = "资料库已满，原 PDF 保持不变。"; break }
                self.papers.append(paper)
            }
            self.importingPDFs = false
            if result.1 > 0 { self.notice = "\(result.1) 个文件无法读取。" }
            self.persistWorkspace()
        }
    }
    func relinkPaper(_ id: UUID) {
        guard canChangeLibrary() else { return }
        let panel = NSOpenPanel(); panel.title = "重新关联 PDF"; panel.allowedContentTypes = [.pdf]
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let imported = try await Task.detached(priority: .userInitiated) { try LibraryStore.imported(url) }.value
                    self.changePaper(id) { $0.file = imported.file; $0.pages = imported.pages; $0.missing = false }
                    self.notice = nil
                    self.persistWorkspace()
                } catch { self.notice = error.localizedDescription }
            }
        }
    }
    func checkPaperVersions(_ ids: [UUID]) {
        guard versionWorker == nil, canChangeLibrary() else { return }
        let wanted = Set(ids)
        let selected = papers.filter { wanted.contains($0.id) && !$0.removed && $0.reference != nil }
        guard !selected.isEmpty else { return }
        guard selected.count <= ResourceLimits.batchCount else { notice = "每次最多检查 200 篇，请先筛选资料库。"; return }
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
            self?.checkingVersions = []; self?.versionWorker = nil; self?.persistWorkspace()
        }
    }
    func cancelVersionCheck() { versionWorker?.cancel() }
    func downloadLatest(_ paper: LibraryPaper) {
        guard !busy, let reference = paper.latest, paper.hasUpdate else { return }
        retryFromLibrary(DownloadItem(original: reference.identifier, reference: reference, state: .queued))
    }
    func showPaperDetails(_ paper: LibraryPaper) {
        guard let taskID = paper.taskID else { return }
        var fallback = paper.downloadItem; fallback.id = taskID
        diagnosticItem = items.first { $0.id == taskID } ?? history.first { $0.id == taskID } ?? fallback
    }
    func openPaper(_ paper: LibraryPaper, preview: Bool = false) {
        guard let file = paper.file, FileManager.default.isReadableFile(atPath: file.path) else {
            changePaper(paper.id) { $0.missing = true }; notice = "PDF 已移动或不可读，请重新关联。"; return
        }
        if preview { previewURL = file }
        else if !opener(file) { notice = "无法打开 PDF，请检查默认阅读器。"; return }
        changePaper(paper.id) { $0.read = true; $0.missing = false }
        if libraryWritable { notice = nil }
    }
}

struct LibraryEditView: View {
    @ObservedObject var model: DownloadModel
    let paper: LibraryPaper
    @LibraryViewState private var title = ""
    @LibraryViewState private var tags = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("整理论文").font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 8) { Text("标题"); TextField("标题", text: $title) }
            VStack(alignment: .leading, spacing: 8) { Text("标签"); TextField("用逗号分隔", text: $tags) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("完成") {
                    model.changePaper(paper.id) { $0.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ResourceLimits.titleCharacters)); $0.tags = LibraryPaper.cleanTags(tags) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 12)).padding(24).frame(width: 440)
            .onAppear { title = paper.title; tags = paper.tags.joined(separator: ", ") }
    }
}

struct LibraryRow: View {
    let paper: LibraryPaper
    @ObservedObject var model: DownloadModel
    let selected: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: paper.favorite ? "star.fill" : "doc.text")
                .font(.system(size: 21, weight: .light)).foregroundStyle(ThemePalette.color(palette.accent))
                .frame(width: 44, height: 44).background(ThemePalette.color(palette.accent).opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel(paper.favorite ? "已收藏" : "论文")
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if !paper.read { Circle().fill(ThemePalette.color(palette.accent)).frame(width: 5, height: 5).accessibilityLabel("未读") }
                    Text(paper.title).font(.system(size: 14, weight: .medium)).lineLimit(2).lineSpacing(3).help(paper.title)
                }
                HStack(spacing: 10) {
                    if let ref = paper.reference { Text(ref.identifier).font(.system(size: 11, design: .monospaced)) }
                    else { Text(paper.directURL?.host ?? "本地 PDF").lineLimit(1) }
                    if let pages = paper.pages { Text("\(pages) 页") }
                    if paper.hasUpdate { Text("有 v\(paper.latest!.version!)").foregroundStyle(ThemePalette.color(palette.accent)) }
                    if paper.missing { Text("文件缺失").foregroundStyle(UIColors.error) }
                }.font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                if !paper.tags.isEmpty { Text(paper.tags.joined(separator: " · ")).font(.system(size: 11)).lineLimit(1).foregroundStyle(ThemePalette.color(palette.secondary)) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            HStack(spacing: 6) {
                if paper.removed { Button("恢复") { model.changePaper(paper.id) { $0.removed = false } }.buttonStyle(QuietButtonStyle(palette: palette)) }
                else if paper.missing { Button("关联") { model.relinkPaper(paper.id) }.buttonStyle(QuietButtonStyle(palette: palette)) }
                else { Button("打开") { model.openPaper(paper) }.buttonStyle(QuietButtonStyle(palette: palette)) }
                if !paper.removed {
                    Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 20, height: 32) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("\(paper.title)的更多操作")
                }
            }.padding(.top, 5)
        }.padding(20).background(ThemePalette.color(palette.surface)).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? ThemePalette.color(palette.accent).opacity(0.65) : ThemePalette.color(palette.border).opacity(0.4), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20)).onTapGesture(perform: select).contextMenu { actions }
            .accessibilityElement(children: .contain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var actions: some View {
        if !paper.removed {
            Button("快速预览") { select(); model.openPaper(paper, preview: true) }.disabled(paper.missing)
            Button(paper.favorite ? "取消收藏" : "收藏") { model.changePaper(paper.id) { $0.favorite.toggle() } }
            Button(paper.read ? "标为未读" : "标为已读") { model.changePaper(paper.id) { $0.read.toggle() } }
            Button("整理论文…") { select(); model.editingPaper = paper }
            Divider()
            if paper.reference != nil {
                Button("检查新版本") { model.checkPaperVersions([paper.id]) }.disabled(!model.checkingVersions.isEmpty)
                if paper.hasUpdate { Button("下载 v\(paper.latest!.version!)") { model.downloadLatest(paper) }.disabled(model.busy) }
                if let date = paper.checkedAt { Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))") }
            }
            if let source = paper.source {
                Button("打开来源页面") { model.openSource(paper.downloadItem) }
                Button("复制来源链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.webURL.absoluteString, forType: .string) }
                if paper.missing { Button("重新下载") { model.retryFromLibrary(paper.downloadItem) }.disabled(model.busy) }
            }
            if let file = paper.file { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            Button("重新关联 PDF…") { model.relinkPaper(paper.id) }
            if paper.taskID != nil {
                Button("下载详情…") { select(); model.showPaperDetails(paper) }
            }
            Divider()
            Button("移出资料库") { model.changePaper(paper.id) { $0.removed = true } }.help("保留 PDF，可从已移除的论文中恢复")
        } else { Button("恢复到资料库") { model.changePaper(paper.id) { $0.removed = false } } }
    }
}
