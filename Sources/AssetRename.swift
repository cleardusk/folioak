import SwiftUI
import Foundation
import Darwin

private typealias RenameViewState<Value> = SwiftUI.State<Value>

struct AssetRenameRequest: Identifiable {
    let id: UUID
    let collection: LibraryCollection
    let files: [URL]
}

// Canonicalize each parent at most once, and only for filenames that can match.
// Large catalogs normally share a directory; unrelated filenames require no disk access.
final class AssetRenamePaths {
    private let original: URL
    private let canonical: URL
    private var parents: [URL: URL] = [:]
    init(_ file: URL) {
        original = file.standardizedFileURL
        canonical = original.resolvingSymlinksInPath()
    }
    func contains(_ file: URL) -> Bool {
        let url = file.standardizedFileURL
        if url == original || url == canonical { return true }
        guard url.lastPathComponent == original.lastPathComponent else { return false }
        let parent = url.deletingLastPathComponent()
        let resolved = parents[parent] ?? parent.resolvingSymlinksInPath()
        parents[parent] = resolved
        return resolved.appendingPathComponent(url.lastPathComponent) == canonical
    }
}

enum AssetRename {
    static func location(_ url: URL) -> URL { url.standardizedFileURL }
    static func move(_ old: URL, to new: URL) throws {
        guard old.standardizedFileURL != new.standardizedFileURL else { return }
        guard renamex_np(old.path, new.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw DownloadError.storage("同名文件已存在，请使用其他名称。") }
            throw DownloadError.storage(String(cString: strerror(errno)))
        }
    }

    static func destination(for file: URL, basename: String) throws -> URL {
        let name = basename.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains(where: { "?*\"<>|".contains($0) }), PaperMetadata.cleanTitle(name) == name,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DownloadError.storage("请输入有效的文件名，不能包含 /、\\、冒号或控制字符。")
        }
        let filename = name + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)
        guard filename.utf8.count <= 250 else { throw DownloadError.storage("文件名过长，请缩短至 250 字节以内（含扩展名）。") }
        return file.deletingLastPathComponent().appendingPathComponent(filename)
    }

    static func writableFile(_ file: URL) -> Bool {
        let manager = FileManager.default
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              manager.isReadableFile(atPath: file.path), manager.isWritableFile(atPath: file.path),
              manager.isWritableFile(atPath: file.deletingLastPathComponent().path) else { return false }
        return true
    }

    static func replacing(_ item: DownloadItem, paths: AssetRenamePaths, new: URL) -> DownloadItem {
        guard item.localURLs.contains(where: paths.contains) else { return item }
        var updated = item
        if item.savedURL.map(paths.contains) == true {
            updated.savedURL = new
            updated.documentTitle = new.deletingPathExtension().lastPathComponent
        }
        updated.additionalURLs = item.additionalURLs?.map { paths.contains($0) ? new : $0 }
        updated.namingSnapshot = (item.namingSnapshot ?? AssetNamingSnapshot(now: item.createdAt)).saving(updated.localURLs)
        return updated
    }

    static func replacing(_ paper: LibraryPaper, paths: AssetRenamePaths, new: URL) -> LibraryPaper {
        guard paper.file.map(paths.contains) == true else { return paper }
        var updated = paper
        updated.file = new; updated.title = new.deletingPathExtension().lastPathComponent
        updated.namingSnapshot = (paper.namingSnapshot ?? AssetNamingSnapshot(now: paper.addedAt)).saving([new])
        return updated
    }
}

struct AssetRenameView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject private var localization = AppLocalization.shared
    let request: AssetRenameRequest
    @RenameViewState private var selected = 0
    @RenameViewState private var basename = ""
    @RenameViewState private var submitting = false
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    private var file: URL { request.files[selected] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("重命名")).font(.system(size: 18, weight: .medium))
            if request.files.count > 1 {
                Picker(L("文件"), selection: $selected) {
                    ForEach(request.files.indices, id: \.self) { index in Text(request.files[index].lastPathComponent).tag(index) }
                }.disabled(submitting).onChange(of: selected) { _ in resetName() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("文件名"))
                HStack(spacing: 8) {
                    TextField(L("文件名"), text: $basename).textFieldStyle(.roundedBorder).focused($nameFocused).disabled(submitting)
                    Text("." + file.pathExtension).foregroundStyle(ThemePalette.color(palette.secondary))
                }
            }
            if let error = model.assetRenameError { Text(L(error)).foregroundStyle(UIColors.error).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                    .buttonStyle(QuietButtonStyle(palette: palette))
                Button(L("重命名")) {
                    submitting = true
                    Task { if await model.renameAsset(request, file: file, to: basename) { dismiss() }; submitting = false }
                }.keyboardShortcut(.defaultAction).buttonStyle(QuietButtonStyle(palette: palette))
                    .disabled(submitting || basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.text)).padding(24).frame(width: 460)
            .background(ThemePalette.color(palette.canvas)).onAppear { resetName(); nameFocused = true }.interactiveDismissDisabled(submitting)
    }
    private func resetName() { basename = file.deletingPathExtension().lastPathComponent; model.assetRenameError = nil }
}
