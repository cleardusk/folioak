import SwiftUI
import AppKit
import Combine

// Use the property wrapper; the latest SDK also exports a State macro that the
// standalone Command Line Tools compiler cannot load.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum UIColors {
    static let success = adaptive(light: (0.08, 0.43, 0.22), dark: (0.30, 0.85, 0.43))
    static let error = adaptive(light: (0.70, 0.12, 0.09), dark: (1, 0.42, 0.42))

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

enum ItemState: Equatable {
    case queued, coordinating, metadata, checkingLocal, downloading, validating, retrying(Int), waiting(Date), paused, saved, existing, failed, cancelled, missing
    var terminal: Bool {
        switch self { case .saved, .existing, .failed, .cancelled, .missing, .paused: return true; default: return false }
    }
    var label: String {
        switch self {
        case .queued: return "等待下载"
        case .coordinating: return "等待其他下载任务"
        case .metadata: return "获取论文信息"
        case .checkingLocal: return "检查本地文件"
        case .downloading: return "下载中"
        case .validating: return "校验并保存"
        case .retrying(let attempt): return "自动重试 \(attempt)/3"
        case .waiting(let date): return "等待请求 · \(date.formatted(date: .omitted, time: .standard)) 后继续"
        case .paused: return "等待重试"
        case .saved: return "已保存"
        case .existing: return "文件已存在"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        case .missing: return "文件不存在"
        }
    }
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

struct DownloadItem: Identifiable {
    let id = UUID()
    let original: String
    let reference: ArxivReference?
    var directURL: URL? = nil
    var restoreReference: ArxivReference?
    var metadata: PaperMetadata?
    var state: ItemState
    var progress: DownloadProgress?
    var error: String?
    var savedURL: URL?
    var pages: Int?
    var documentTitle: String?
    var source: DownloadSource? { reference.map(DownloadSource.arxiv) ?? directURL.map(DownloadSource.pdf) }
    var title: String { metadata?.title ?? documentTitle ?? source?.label ?? original }
    var canRetry: Bool { source != nil && (state == .failed || state == .cancelled || state == .missing || state == .paused) }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var input = "" {
        didSet {
            if input.utf8.count > ResourceLimits.inputBytes {
                input = oldValue
                notice = "输入超过 64 KB，请分批粘贴。"
            }
        }
    }
    @Published var directory: URL {
        didSet { preferences.set(directory.path, forKey: "saveDirectory"); directoryNotice = nil }
    }
    @Published var naming: NamingStyle {
        didSet { preferences.set(naming.rawValue, forKey: "namingStyle") }
    }
    @Published var appearance: AppAppearance {
        didSet { preferences.set(appearance.rawValue, forKey: "appearance"); applyAppearance() }
    }
    @Published var theme: AppTheme {
        didSet { preferences.set(theme.rawValue, forKey: "theme") }
    }
    @Published var items: [DownloadItem] = []
    @Published var batchID = UUID()
    @Published var busy = false
    @Published var cancelling = false
    @Published var notice: String?
    @Published var directoryNotice: String?
    @Published var duplicateCount = 0
    @Published var editRequest = UUID()
    private(set) var editTarget = ""
    private let engine: DownloadEngine
    private let preferences: UserDefaults
    private let opener: (URL) -> Bool
    private var worker: Task<Void, Never>?
    private var runID = UUID()

    init(engine: DownloadEngine? = nil, preferences: UserDefaults = DownloadPreferences.shared, opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.engine = engine ?? DownloadEngine(cooldownPreferences: preferences, coordinator: RequestCoordinator())
        self.preferences = preferences
        self.opener = opener
        let downloadPreferences = DownloadPreferences(preferences)
        naming = downloadPreferences.naming
        appearance = AppAppearance(rawValue: preferences.string(forKey: "appearance") ?? "") ?? .system
        theme = AppTheme(rawValue: preferences.string(forKey: "theme") ?? "") ?? .native
        directory = downloadPreferences.directory
    }

    func applyAppearance() { NSApplication.shared.appearance = appearance.native }
    var directoryLabel: String { (directory.path as NSString).abbreviatingWithTildeInPath }
    var namingExample: String {
        PaperMetadata(reference: ArxivReference(baseID: "1706.03762", version: 1), title: "Attention Is All You Need", year: 2017, month: 6).filename(style: naming)
    }

    var tokenCount: Int { DownloadSource.tokens(in: input).count }
    var retryCount: Int { items.filter(\.canRetry).count }
    var canRetry: Bool { items.contains(where: \.canRetry) }
    var completed: Int { items.filter { $0.state.terminal }.count }
    var successes: Int { items.filter { $0.state == .saved || $0.state == .existing }.count }
    var failures: Int { items.filter { $0.state == .failed || $0.state == .missing }.count }
    var summary: String {
        if items.isEmpty { return "" }
        if cancelling { return "正在取消…" }
        if busy { return "已处理 \(completed) / \(items.count) 篇" }
        var parts: [String] = []
        if failures > 0 { parts.append("\(failures) 篇失败") }
        let cancelled = items.filter { $0.state == .cancelled }.count
        if cancelled > 0 { parts.append("\(cancelled) 篇取消") }
        let paused = items.filter { $0.state == .paused }.count
        if paused > 0 { parts.append("\(paused) 篇待重试") }
        if duplicateCount > 0 { parts.append("已去重 \(duplicateCount) 条") }
        return parts.joined(separator: " · ")
    }

    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard input.utf8.count + text.utf8.count + 1 <= ResourceLimits.inputBytes else { notice = "输入超过 64 KB，请分批粘贴。"; return }
        if !input.isEmpty && !input.hasSuffix("\n") { input += "\n" }
        input += text
    }

    func chooseDirectory() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择论文保存目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { self.directory = url }
            }
        } else if panel.runModal() == .OK, let url = panel.url { directory = url }
    }

    func start() {
        guard !busy else { return }
        let batch: BatchInput
        do { batch = try BatchInput(input) }
        catch { notice = error.localizedDescription; return }
        duplicateCount = batch.duplicates
        batchID = UUID()
        items = batch.entries.map { entry in
            DownloadItem(original: entry.original, reference: entry.reference, directURL: entry.source?.directURL, state: entry.source == nil ? .failed : .queued, error: entry.error)
        }
        guard !items.isEmpty else { notice = "请先粘贴至少一个链接。"; return }
        execute(items.filter { $0.source != nil }.map(\.id))
    }

    func retry(_ single: UUID? = nil) {
        guard !busy else { return }
        let ids = items.filter { $0.canRetry && (single == nil || $0.id == single) }.map(\.id)
        for id in ids { update(id) { $0.state = .queued; $0.error = nil; $0.progress = nil } }
        execute(ids)
    }

    func cancel() {
        guard busy else { return }
        cancelling = true
        worker?.cancel()
    }

    func cancelAndWait() async {
        let task = worker
        cancel()
        await task?.value
    }

    func edit(_ item: DownloadItem) {
        editTarget = item.original
        editRequest = UUID()
    }

    func openDirectory() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            directoryNotice = "保存目录不存在，请重新选择。"; return
        }
        if !opener(directory) { directoryNotice = "无法打开保存目录，请检查 Finder 或目录权限。" }
        else { directoryNotice = nil }
    }

    func openFile(_ item: DownloadItem, reveal: Bool = false) {
        guard let url = item.savedURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            update(item.id) {
                $0.state = .missing; $0.savedURL = nil
                $0.restoreReference = $0.metadata?.reference
                $0.error = "原位置的 PDF 不存在，可重新下载。"
            }
            return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if !opener(url) { notice = "无法打开 PDF，请检查默认 PDF 阅读器。文件仍保存在原位置。" }
        else { notice = nil }
    }

    func openSource(_ item: DownloadItem) {
        if let source = item.source {
            notice = opener(source.webURL) ? nil : "无法打开来源页面，请检查默认浏览器。"
        }
    }

    func fileInfo(_ item: DownloadItem) {
        guard let url = item.savedURL else { return }
        let alert = NSAlert()
        alert.messageText = "文件信息"
        alert.informativeText = "\(url.lastPathComponent)\n\n\(url.deletingLastPathComponent().path)\n\n\(item.pages.map { "\($0) 页 · " } ?? "")\(item.metadata?.reference.identifier ?? item.source?.label ?? "")"
        alert.addButton(withTitle: "完成")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
    }

    private func update(_ id: UUID, _ transform: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[index])
    }

    private func receive(_ event: DownloadEvent, for id: UUID, run: UUID) {
        guard run == runID else { return }
        update(id) { item in
            guard !item.state.terminal else { return }
            switch event {
            case .coordinating: item.state = .coordinating
            case .metadata: item.state = .metadata
            case .resolved(let metadata): item.metadata = metadata; item.state = .downloading
            case .document(let title): item.documentTitle = title
            case .checkingLocal: item.state = .checkingLocal
            case .progress(let progress): item.progress = progress; item.state = .downloading
            case .retry(let attempt): item.state = .retrying(attempt); item.progress = nil
            case .waiting(let date): item.state = .waiting(date); item.progress = nil
            case .validating: item.state = .validating
            }
        }
    }

    private func execute(_ ids: [UUID]) {
        notice = nil
        directoryNotice = nil
        guard !ids.isEmpty else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: directory.path) else {
            directoryNotice = "保存目录不存在或不可写，请重新选择后重试。"
            for id in ids { update(id) { $0.state = .failed; $0.error = nil } }
            return
        }
        busy = true
        cancelling = false
        let target = directory
        let namingStyle = naming
        let run = UUID()
        runID = run
        worker = Task { [self] in
            var pausedSources: [String: Date] = [:]
            for id in ids {
                if Task.isCancelled { break }
                guard let item = items.first(where: { $0.id == id }),
                      let source = item.restoreReference.map(DownloadSource.arxiv) ?? item.source else { continue }
                if let until = pausedSources[source.rateLimitKey] {
                    update(id) { $0.state = .paused; $0.error = "下载站点要求暂停请求，可在 \(until.formatted(date: .abbreviated, time: .standard)) 后重试。" }
                    continue
                }
                update(id) { $0.state = .metadata }
                do {
                    let saved = try await engine.download(source, to: target, naming: namingStyle) { [weak self] event in
                        Task { @MainActor in self?.receive(event, for: id, run: run) }
                    }
                    update(id) {
                        $0.metadata = saved.metadata
                        $0.documentTitle = saved.title
                        $0.savedURL = saved.url
                        $0.pages = saved.pages
                        $0.state = saved.alreadyExisted ? .existing : .saved
                        $0.progress = nil
                    }
                    input = DownloadSource.tokens(in: input)
                        .filter { (try? DownloadSource.parse($0)) != source }
                        .joined(separator: "\n")
                } catch is CancellationError {
                    update(id) { $0.state = .cancelled; $0.progress = nil }
                    break
                } catch {
                    let cooldown: Date?
                    if case DownloadError.cooldown(let seconds) = error {
                        cooldown = Date().addingTimeInterval(seconds)
                    } else { cooldown = nil }
                    update(id) {
                        $0.state = cooldown == nil ? .failed : .paused
                        $0.progress = nil
                        if let cooldown {
                            $0.error = "下载站点要求暂停请求，可在 \(cooldown.formatted(date: .abbreviated, time: .standard)) 后重试。"
                        } else if let network = error as? URLError {
                            if [.cannotCreateFile, .cannotOpenFile, .cannotWriteToFile].contains(network.code) {
                                $0.error = "临时文件无法写入，请检查磁盘空间和权限。"
                            } else {
                                $0.error = network.code == .timedOut ? "连接超时，自动重试后仍未成功。请检查网络后重试。" : "网络连接失败：\(network.localizedDescription)"
                            }
                        } else { $0.error = error.localizedDescription }
                    }
                    if let cooldown { pausedSources[source.rateLimitKey] = cooldown }
                }
            }
            for id in ids {
                update(id) { if !$0.state.terminal { $0.state = .cancelled; $0.progress = nil } }
            }
            busy = false
            cancelling = false
            worker = nil
        }
    }
}

// Placeholder glyphs use the same TextKit layout and origin as editable text.
// SwiftUI Text over TextEditor has a different first-line baseline on macOS.
final class LinkTextView: NSTextView {
    static let example = "https://arxiv.org/abs/2609.22978"
    var placeholderColor = NSColor.secondaryLabelColor { didSet { if placeholderColor != oldValue { needsDisplay = true } } }
    var focusChanged: ((Bool) -> Void)?
    private var styledInput: String?
    private var styledTextColor: NSColor?
    private var styledAccentColor: NSColor?
    private var styledUnderline = false
    private let placeholderStorage = NSTextStorage()
    private let placeholderLayout = NSLayoutManager()
    private let placeholderContainer = NSTextContainer()

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        placeholderStorage.addLayoutManager(placeholderLayout)
        placeholderLayout.addTextContainer(placeholderContainer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

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
        text.append(NSAttributedString(string: "arXiv 或 PDF 链接，每行一个", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: placeholderColor]))
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
        let editor = LinkTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 104), textContainer: container)
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
        editor.minSize = NSSize(width: 0, height: 104)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.enabledTextCheckingTypes = 0
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.setAccessibilityLabel("arXiv 链接，每行一个")
        editor.delegate = context.coordinator
        editor.focusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused = value }
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? LinkTextView else { return }
        editor.isEditable = !model.busy
        let textColor = ThemePalette.nativeColor(palette.text)
        let accentColor = ThemePalette.nativeColor(palette.accent)
        if editor.insertionPointColor != accentColor { editor.insertionPointColor = accentColor }
        editor.placeholderColor = ThemePalette.nativeColor(palette.secondary)
        if editor.string != model.input {
            editor.string = model.input
            editor.undoManager?.removeAllActions()
            editor.sizeToFit()
            editor.needsDisplay = true
        }
        editor.styleReferences(textColor: textColor, accentColor: accentColor, underlineRecognized: model.theme == .graphite)
        let selectToken = context.coordinator.selectionRequest != model.editRequest
        context.coordinator.selectionRequest = model.editRequest
        if !model.busy && (selectToken || (focused && editor.window?.firstResponder !== editor)) {
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                guard let editor, let coordinator, !coordinator.parent.model.busy, let window = editor.window else { return }
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
                parent.model.notice = "输入超过 64 KB，请分批粘贴。"
                return false
            }
            let proposed = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
            guard proposed.utf8.count <= ResourceLimits.inputBytes else {
                parent.model.notice = "输入超过 64 KB，请分批粘贴。"
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
        if width > 0 && editor.frame.width != width {
            editor.setFrameSize(NSSize(width: width, height: max(editor.frame.height, contentSize.height)))
        }
    }
}

struct DownloaderView: View {
    @ObservedObject var model: DownloadModel
    @ViewState private var inputFocused = false
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("论文链接").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(action: model.paste) { Label("粘贴", systemImage: "doc.on.clipboard") }
                        .buttonStyle(.borderless).controlSize(.small).disabled(model.busy)
                        .help("追加剪贴板中的链接；每行一个，也支持空格分隔")
                        .frame(height: 28)
                }
                LinkInput(model: model, focused: $inputFocused, palette: palette)
                .frame(height: 104)
                .background(ThemePalette.color(palette.surface))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ThemePalette.color(inputFocused && !model.busy ? palette.accent : palette.border), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button(action: model.chooseDirectory) {
                        HStack(spacing: 7) {
                            Image(systemName: "folder").foregroundStyle(ThemePalette.color(palette.secondary))
                            Text(model.directoryLabel).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(ThemePalette.color(palette.secondary))
                        }
                        .font(.system(size: 12)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.busy)
                    .help("\(model.directory.path)\n点击更改保存目录")
                    .accessibilityLabel("保存目录：\(model.directory.path)，点击更改")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("打开", action: model.openDirectory)
                        .font(.system(size: 12)).frame(width: 40, height: 28)
                        .buttonStyle(.borderless).foregroundStyle(ThemePalette.color(palette.secondary))
                        .help("在 Finder 中打开保存目录").accessibilityLabel("打开保存目录")
                    if model.busy {
                        Button(model.cancelling ? "正在取消…" : "取消下载", action: model.cancel)
                            .buttonStyle(PrimaryActionStyle(palette: palette, prominent: false))
                            .keyboardShortcut(.cancelAction).disabled(model.cancelling)
                            .frame(width: 108)
                    } else {
                        Button("开始下载", action: model.start)
                            .buttonStyle(PrimaryActionStyle(palette: palette))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.tokenCount == 0).frame(width: 108)
                            .help("开始下载（⌘ Return）")
                    }
                }.controlSize(.large)
                if let error = model.directoryNotice {
                    Text(error).font(.system(size: 11)).foregroundStyle(UIColors.error)
                }
            }
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "tray").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text("还没有下载任务").font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            DownloadRow(item: item, model: model)
                            if item.id != model.items.last?.id { Divider().padding(.leading, 29) }
                        }
                    }
                }.id(model.batchID).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(UIColors.error).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini).frame(width: 12) }
                Text(model.summary).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                Spacer()
                if model.retryCount > 1 && !model.busy {
                    Button("重试未完成项") { model.retry() }.controlSize(.small)
                }
            }.frame(height: 22)
        }
        .padding(22).frame(minWidth: 560, minHeight: 450)
        .foregroundStyle(ThemePalette.color(palette.text))
        .tint(ThemePalette.color(palette.accent))
        .background(ThemePalette.color(palette.canvas).ignoresSafeArea())
        .onAppear { inputFocused = true }
        .onReceive(model.$editRequest.dropFirst()) { _ in inputFocused = true }
    }

    static func inputRange(of token: String, in text: String) -> NSRange? {
        let raw = text as NSString
        let expression = try! NSRegularExpression(pattern: #"[^\s,;，；]+"#)
        return expression.matches(in: text, range: NSRange(location: 0, length: raw.length))
            .first(where: { raw.substring(with: $0.range) == token })?.range
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var model: DownloadModel
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.state.symbol).font(.system(size: 16))
                .foregroundStyle(item.state.color(palette)).frame(width: 19)
                .accessibilityLabel(item.state.label)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                    .lineLimit(3).textSelection(.enabled).help(item.title)
                HStack(spacing: 8) {
                    if let metadata = item.metadata {
                        Text(metadata.reference.identifier).font(.system(size: 11, design: .monospaced))
                    } else if let host = item.directURL?.host {
                        Text(host).lineLimit(1).truncationMode(.middle)
                    }
                    Text(item.state.label).foregroundStyle(item.state.color(palette))
                }.font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                if let url = item.savedURL {
                    Text(url.lastPathComponent).font(.system(size: 10))
                        .foregroundStyle(ThemePalette.color(palette.secondary))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(url.path)
                }
                if let progress = item.progress, item.state == .downloading {
                    HStack(spacing: 8) {
                        if let fraction = progress.fraction { ProgressView(value: fraction).tint(ThemePalette.color(palette.accent)) }
                        Text(progressText(progress)).font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(ThemePalette.color(palette.secondary)).fixedSize()
                    }.frame(maxWidth: 340)
                }
                if let error = item.error {
                    Text(error).font(.system(size: 11))
                        .foregroundStyle(item.state == .paused ? ThemePalette.color(palette.secondary) : UIColors.error)
                        .textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let url = item.savedURL {
                    Button("打开") { model.openFile(item) }.controlSize(.small).frame(width: 44).help(url.path)
                    Menu {
                        Button("在 Finder 中显示") { model.openFile(item, reveal: true) }
                        Button("文件信息…") { model.fileInfo(item) }
                        Button("复制文件名") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
                        }
                        Divider()
                        Button(item.directURL == nil ? "查看 arXiv 页面" : "查看来源链接") { model.openSource(item) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                    .help("\(url.path)\(item.pages.map { "\n\($0) 页" } ?? "")")
                    .accessibilityLabel("\(item.title)的更多操作")
                } else if item.canRetry {
                    Button("重试") { model.retry(item.id) }.controlSize(.small).frame(width: 44).disabled(model.busy)
                } else if item.source == nil {
                    Button("修改") { model.edit(item) }.controlSize(.small).frame(width: 44).disabled(model.busy)
                }
            }.frame(width: 72, alignment: .leading)
        }
        .padding(.vertical, 12).accessibilityElement(children: .contain)
    }

    private func progressText(_ progress: DownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        if let fraction = progress.fraction { return "\(Int(fraction * 100))% · \(received)" }
        return received
    }
}

struct SettingsView: View {
    @ObservedObject var model: DownloadModel
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                settingLabel("保存目录")
                HStack(spacing: 12) {
                    Text(model.directoryLabel).font(.system(size: 12)).lineLimit(1)
                        .truncationMode(.middle).help(model.directory.path).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("更改…", action: model.chooseDirectory).controlSize(.small).disabled(model.busy)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 28)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    settingLabel("文件命名")
                    Picker("文件命名", selection: $model.naming) {
                        ForEach(NamingStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.namingExample).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ThemePalette.color(palette.secondary)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(model.naming == .dateTitle ? "arXiv 年月取首次提交日期；通用 PDF 使用标题或原文件名。" : "arXiv 使用所选命名；通用 PDF 使用标题或原文件名。")
                        .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).fixedSize(horizontal: false, vertical: true)
                }.padding(.leading, 80).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 16) {
                settingLabel("外观")
                Picker("外观", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack(alignment: .top, spacing: 16) {
                settingLabel("主题").frame(height: ThemeChoice.previewHeight)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        ThemeChoice(theme: theme, selected: model.theme == theme) { model.theme = theme }
                    }
                }.frame(maxWidth: .infinity)
            }
            Text(model.busy ? "下载结束后可更改目录和命名。" : "")
                .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).frame(height: 14).padding(.leading, 80)
        }
        .padding(24).frame(width: 470)
        .foregroundStyle(ThemePalette.color(palette.text))
        .tint(ThemePalette.color(palette.accent))
        .background(ThemePalette.color(palette.canvas).ignoresSafeArea())
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).frame(width: 64, alignment: .trailing)
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
    private static let settingsID = NSToolbarItem.Identifier("window-settings")
    private weak var window: NSWindow?
    private let titleField: NSTextField
    private let settingsAction: (() -> Void)?
    private var settingsButton: NSButton?
    private var themeObservation: AnyCancellable?

    init(window: NSWindow, model: DownloadModel, title: String, settingsAction: (() -> Void)? = nil) {
        self.window = window
        self.titleField = WindowTitleField(labelWithString: title)
        self.settingsAction = settingsAction
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
        window.toolbar = toolbar
        themeObservation = model.$theme.sink { [weak self] theme in self?.applyTheme(theme) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.titleID, Self.settingsID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.flexibleSpace, Self.titleID, .flexibleSpace]
        if settingsAction != nil { items.append(Self.settingsID) }
        return items
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.titleID {
            item.label = titleField.stringValue
            titleField.frame.size = NSSize(width: 140, height: 18)
            item.view = titleField
            return item
        }
        if identifier == Self.settingsID, settingsAction != nil {
            let button = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!, target: self, action: #selector(openSettings))
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.frame.size = NSSize(width: 28, height: 28)
            button.toolTip = "设置（⌘,）"
            button.setAccessibilityLabel("设置")
            settingsButton = button
            item.label = "设置"
            item.toolTip = "设置（⌘,）"
            item.view = button
            return item
        }
        return nil
    }

    @objc private func openSettings() { settingsAction?() }

    private func applyTheme(_ theme: AppTheme) {
        func color(_ keyPath: KeyPath<ThemePalette, UInt32>) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return ThemePalette.nativeColor(theme.palette(dark: dark)[keyPath: keyPath])
            }
        }
        window?.backgroundColor = color(\.canvas)
        titleField.textColor = color(\.text)
        settingsButton?.contentTintColor = color(\.secondary)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var windowChrome: WindowChrome?
    private var settingsChrome: WindowChrome?
    private let model = DownloadModel()
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.applyAppearance()
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "arXiv下载器"
        window.setFrameAutosaveName("ArxivDownloaderCompactWindow")
        windowChrome = WindowChrome(window: window, model: model, title: "arXiv下载器", settingsAction: { [weak self] in self?.showSettings() })
        window.contentView = NSHostingView(rootView: DownloaderView(model: model))
        window.minSize = NSSize(width: 584, height: 512)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仍有论文正在下载"
        alert.informativeText = "已保存的论文会保留。退出将停止当前下载和等待中的任务。"
        alert.addButton(withTitle: "继续下载")
        alert.addButton(withTitle: "停止并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        terminationPending = true
        Task { [self] in
            await model.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { NSApp.terminate(sender); return false }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = NSHostingView(rootView: SettingsView(model: model))
            let contentSize = view.fittingSize
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "arXiv下载器设置"
            settingsChrome = WindowChrome(window: panel, model: model, title: "设置")
            panel.contentView = view
            panel.setContentSize(NSSize(width: contentSize.width, height: contentSize.height + panel.frame.height - panel.contentLayoutRect.height))
            panel.isReleasedWhenClosed = false
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 arXiv下载器", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 arXiv下载器", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 arXiv下载器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        menu.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
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
