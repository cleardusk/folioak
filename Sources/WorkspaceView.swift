import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

typealias WorkspaceViewState<Value> = SwiftUI.State<Value>

enum WorkspacePage: String, CaseIterable {
    case downloads = "下载", library = "文档库", media = "媒体库", logs = "日志"
    static let navigation: [Self] = [.downloads, .library, .media]
    var icon: String {
        switch self { case .downloads: return "arrow.down.circle"; case .library: return "books.vertical"; case .media: return "photo.on.rectangle"; case .logs: return "text.alignleft" }
    }
    var filledIcon: String {
        switch self { case .downloads: return "arrow.down.circle.fill"; case .library: return "books.vertical.fill"; case .media: return "photo.on.rectangle.fill"; case .logs: return icon }
    }
}

enum QueueFilter: String, CaseIterable {
    case all = "全部", active = "进行中", saved = "已完成", failed = "未完成"
    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return !item.state.terminal
        case .saved: return item.state == .saved || item.state == .existing
        case .failed: return item.state.terminal && item.state != .saved && item.state != .existing
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    let palette: ThemePalette
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ThemePalette.color(palette.accent).opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 10).frame(height: 32)
            .background(ThemePalette.color(palette.accent).opacity(configuration.isPressed ? 0.19 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct RoundButtonStyle: ButtonStyle {
    let palette: ThemePalette
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .foregroundStyle(ThemePalette.color(palette.text).opacity(enabled ? 1 : 0.35))
            .frame(width: 32, height: 32)
            .background(ThemePalette.color(palette.accent).opacity(configuration.isPressed ? 0.14 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DownloaderView: View {
    @ObservedObject var model: DownloadModel
    @WorkspaceViewState var page: WorkspacePage = .downloads
    var showSettings: () -> Void = {}
    @WorkspaceViewState private var collapsed = false
    @WorkspaceViewState private var navigationHovered = false
    @WorkspaceViewState private var navigationActivatedAt: Date?
    @WorkspaceViewState private var inputFocused = false
    @WorkspaceViewState private var query = ""
    @WorkspaceViewState private var filter: QueueFilter = .all
    @WorkspaceViewState private var logLevel: ActivityLevel? = nil
    @WorkspaceViewState private var dropTargeted = false
    @WorkspaceViewState private var selectedID: UUID?
    @WorkspaceViewState private var listFocus: UUID?
    @WorkspaceViewState private var focusListOnArrival = false
    @WorkspaceViewState private var libraryFilter = LibraryFilter.all
    @WorkspaceViewState private var librarySort = LibrarySort.newest
    @WorkspaceViewState private var libraryTag: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    private var accent: Color { ThemePalette.color(palette.accent) }
    private var visibleItems: [DownloadItem] {
        if page == .library { return libraryPapers.map(\.downloadItem) }
        if page == .media {
            return model.mediaLibrary.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.original.localizedCaseInsensitiveContains(query) }
                .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
        }
        return model.downloads.filter { item in
            filter.includes(item) &&
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.original.localizedCaseInsensitiveContains(query))
        }
    }
    private var libraryTags: [String] { Array(Set(model.papers.filter { !$0.removed }.flatMap(\.tags))).sorted() }
    private var libraryPapers: [LibraryPaper] {
        model.papers.filter { paper in
            paper.removed == (libraryFilter == .removed) &&
            (libraryFilter != .favorites || paper.favorite) && (libraryFilter != .unread || !paper.read) &&
            (libraryTag == nil || paper.tags.contains(libraryTag!)) && paper.matches(query)
        }.sorted { left, right in
            switch librarySort {
            case .newest: return left.addedAt > right.addedAt
            case .title: return left.title.localizedStandardCompare(right.title) == .orderedAscending
            case .year: return (left.metadata?.year ?? 0) == (right.metadata?.year ?? 0) ? left.addedAt > right.addedAt : (left.metadata?.year ?? 0) > (right.metadata?.year ?? 0)
            }
        }
    }
    private var visibleLogs: [ActivityEntry] {
        model.logs.filter { (logLevel == nil || $0.level == logLevel) && (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query) || ($0.subject?.localizedCaseInsensitiveContains(query) ?? false)) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ThemePalette.color(palette.border).opacity(0.55)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                if page == .downloads { Color.clear.frame(height: 44) }
                else { header }
                VStack(alignment: .leading, spacing: 16) {
                    if page == .downloads { composer }
                    if page == .logs { logContent } else { papers }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer.padding(.top, 12).padding(.bottom, 16)
            }.padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 540)
        .foregroundStyle(ThemePalette.color(palette.text))
        .tint(accent)
        .background(ThemePalette.color(palette.canvas))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: scheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.theme)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(model.$listRequest.dropFirst()) { _ in
            if page == .logs { focusListOnArrival = true; page = .downloads }
            else { focusList() }
        }
        .onReceive(model.$editRequest.dropFirst()) { _ in
            listFocus = nil; focusListOnArrival = false; page = .downloads; inputFocused = true
        }
        .onChange(of: page) { _ in
            query = ""; selectedID = nil; listFocus = nil
            if focusListOnArrival { focusListOnArrival = false; focusList() }
        }
        .onChange(of: visibleItems.map(\.id)) { _ in
            if let selectedID, !visibleItems.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
        .quickLookPreview($model.previewURL)
        .sheet(item: $model.diagnosticItem, onDismiss: { if selectedID != nil { listFocus = UUID() } }) { item in TaskDiagnosticView(model: model, item: item) }
        .sheet(item: $model.editingPaper, onDismiss: { if selectedID != nil { listFocus = UUID() } }) { paper in LibraryEditView(model: model, paper: paper) }
        .onChange(of: model.previewURL) { url in if url == nil && selectedID != nil { listFocus = UUID() } }
        .onReceive(model.$batchID.dropFirst()) { _ in page = .downloads; filter = .all; query = ""; selectedID = nil; listFocus = nil }
    }

    private func focusList() {
        guard !visibleItems.isEmpty else { listFocus = nil; return }
        if selectedID == nil { selectedID = visibleItems.first?.id }
        inputFocused = false; listFocus = UUID()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.25)) { collapsed.toggle() }
                } label: { SidebarToggleGlyph(expanded: !collapsed).frame(width: 50, height: 42).contentShape(Rectangle()) }
                    .buttonStyle(SidebarButtonStyle(palette: palette)).foregroundStyle(secondary)
                    .help(collapsed ? "展开侧栏" : "收起侧栏").accessibilityLabel(collapsed ? "展开侧栏" : "收起侧栏")
                Spacer(minLength: 0)
            }.padding(.top, 34).padding(.bottom, 10)
            VStack(spacing: 6) {
                ForEach(WorkspacePage.navigation, id: \.self) { destination in
                    Button { page = destination; navigationActivatedAt = Date() } label: {
                        HStack(spacing: 13) {
                            SidebarGlyph(symbol: destination.icon, filledSymbol: destination.filledIcon, selected: destination == page)
                                .font(.system(size: 19, weight: .regular)).frame(width: 24, height: 24)
                            HStack {
                                Text(destination.rawValue).font(.system(size: 14)).foregroundStyle(ThemePalette.color(palette.text)).fixedSize()
                                Spacer(minLength: 0)
                                if destination == .downloads && model.busy { Circle().fill(accent).frame(width: 5, height: 5) }
                            }.modifier(SidebarLabelFade(progress: collapsed ? 0 : 1))
                        }
                        .foregroundStyle(ThemePalette.color(palette.secondary))
                        .frame(width: 140, height: 44, alignment: .leading).padding(.horizontal, 13)
                        .frame(width: collapsed ? 50 : 166, alignment: .leading).clipped()
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(SidebarButtonStyle(palette: palette, selected: destination == page))
                    .help(destination.rawValue).accessibilityLabel(destination.rawValue)
                    .accessibilityAddTraits(destination == page ? .isSelected : [])
                }
            }
            .overlay(alignment: .topLeading) {
                SidebarSelectionIndicator(index: WorkspacePage.navigation.firstIndex(of: page) ?? 0, color: accent)
                    .opacity(page != .logs && (navigationHovered || navigationActivatedAt != nil) ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: navigationHovered || navigationActivatedAt != nil)
            }
            .onHover { navigationHovered = $0 }
            .task(id: navigationActivatedAt) {
                guard navigationActivatedAt != nil else { return }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                navigationActivatedAt = nil
            }
            Spacer()
            Button(action: showSettings) {
                HStack(spacing: 13) {
                    Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 24)
                    Text("设置").font(.system(size: 14)).foregroundStyle(ThemePalette.color(palette.text)).fixedSize()
                        .modifier(SidebarLabelFade(progress: collapsed ? 0 : 1))
                    Spacer(minLength: 0)
                }.frame(width: 140, height: 44, alignment: .leading).padding(.horizontal, 13)
                    .frame(width: collapsed ? 50 : 166, alignment: .leading).clipped().contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle(palette: palette)).foregroundStyle(secondary).help("设置（⌘,）").accessibilityLabel("设置")
        }.padding(.horizontal, 12).padding(.bottom, 16).frame(width: collapsed ? 74 : 190)
            .background(ThemePalette.color(palette.sidebar))
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page == .logs {
                Button { page = .downloads } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(RoundButtonStyle(palette: palette)).help("返回下载").accessibilityLabel("返回下载")
            }
            if page != .downloads { Text(page.rawValue).font(.system(size: 20, weight: .semibold)) }
            Spacer()
            if page == .library {
                if !model.papers.isEmpty { searchField }
                Menu {
                    Button("导入 PDF…") { libraryFilter = .all; libraryTag = nil; query = ""; model.importPDFs() }
                        .disabled(model.importingPDFs || !model.libraryWritable)
                    Picker("排序", selection: $librarySort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if !libraryTags.isEmpty {
                        Menu("标签") {
                            Button { libraryTag = nil } label: { if libraryTag == nil { Label("全部标签", systemImage: "checkmark") } else { Text("全部标签") } }
                            ForEach(libraryTags, id: \.self) { tag in
                                Button { libraryTag = tag } label: { if libraryTag == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) } }
                            }
                        }
                    }
                    Divider()
                    Button("导出文档库", action: model.exportLibrary).disabled(!model.papers.contains { !$0.removed })
                    if model.checkingVersions.isEmpty {
                        Button("检查论文新版本") { model.checkPaperVersions(libraryPapers.map(\.id)) }
                            .disabled(!libraryPapers.contains { $0.reference != nil })
                    } else { Button("停止检查版本", action: model.cancelVersionCheck) }
                    Divider()
                    Button(libraryFilter == .removed ? "返回文档库" : "已移除的文档") {
                        libraryFilter = libraryFilter == .removed ? .all : .removed; query = ""; libraryTag = nil
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32).accessibilityLabel("文档库操作")
            } else if page == .media {
                if !model.mediaLibrary.isEmpty { searchField }
            } else if page == .logs && !model.logs.isEmpty {
                searchField
                Button { model.exportLogs(visibleLogs) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(RoundButtonStyle(palette: palette))
                    .disabled(visibleLogs.isEmpty).help("导出当前筛选的日志").accessibilityLabel("导出日志")
            }
        }.frame(height: 76)
    }

    private var downloadActions: some View {
        Menu {
            Button("从文本文件导入链接…", action: model.importLinks).disabled(model.busy)
            if model.hasMediaInput {
                Toggle("视频仅下载音频", isOn: Binding(get: { model.mediaFormat == .audio }, set: { model.mediaFormat = $0 ? .audio : .automatic }))
                    .disabled(model.busy)
            }
            if model.downloads.contains(where: { $0.canRetry || $0.source == nil }) {
                Button("复制未完成链接", action: model.copyUnfinished)
            }
            Divider()
            Button("查看日志") { page = .logs }
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle()) }
            .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32)
            .help("更多下载操作").accessibilityLabel("下载操作")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("添加链接").font(.system(size: 14, weight: .medium))
                Spacer()
                if model.hasMediaInput && model.mediaFormat == .audio {
                    Button { model.mediaFormat = .automatic } label: {
                        Label("仅音频", systemImage: "waveform").font(.system(size: 12)).foregroundStyle(secondary)
                    }.help("视频链接仅保存音频，点按恢复下载视频").accessibilityLabel("仅音频模式，点按恢复视频").disabled(model.busy)
                }
                Button(action: model.paste) { Image(systemName: "doc.on.clipboard").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .help("追加剪贴板中的链接").accessibilityLabel("粘贴链接").disabled(model.busy)
                downloadActions
            }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 12)
            LinkInput(model: model, focused: $inputFocused, palette: palette)
                .frame(height: 104).padding(.horizontal, 8).padding(.top, 8)
            HStack(spacing: 12) {
                DirectoryMenu(model: model, palette: palette)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                Spacer(minLength: 8)
                if model.busy {
                    Button(action: model.cancel) {
                        if model.cancelling { ProgressView().controlSize(.small).tint(ThemePalette.color(palette.secondary)) }
                        else { Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold)) }
                    }.buttonStyle(PrimaryActionStyle(palette: palette))
                        .keyboardShortcut(.cancelAction).disabled(model.cancelling)
                        .help(model.cancelling ? "正在取消" : "取消下载（Esc）")
                        .accessibilityLabel(model.cancelling ? "正在取消" : "取消下载")
                } else {
                    Button(action: model.start) { Image(systemName: "arrow.down") }
                        .buttonStyle(PrimaryActionStyle(palette: palette))
                        .keyboardShortcut(KeyEquivalent(Character(model.shortcuts[.download].key)), modifiers: model.shortcuts[.download].swiftModifiers)
                        .disabled(model.tokenCount == 0).help("开始下载（\(model.shortcuts[.download].label)）")
                        .accessibilityLabel("开始下载")
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 18)
        }
        .background(ThemePalette.color(palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke((inputFocused || dropTargeted) && !model.busy ? accent.opacity(0.65) : ThemePalette.color(palette.border).opacity(0.6), lineWidth: 1))
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $dropTargeted, perform: model.acceptDrop)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(secondary)
            TextField("搜索", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                .accessibilityLabel(page == .logs ? "搜索日志" : (page == .library ? "搜索文档" : (page == .media ? "搜索媒体" : "搜索下载")))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(secondary).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, page == .downloads ? 10 : 13)
            .frame(width: page == .downloads ? 140 : 178, height: page == .downloads ? 28 : 36)
            .background(ThemePalette.color(palette.surface)).clipShape(Capsule())
    }

    private var papers: some View {
        let rows = visibleItems
        return VStack(spacing: 14) {
            if page == .library || (page == .downloads && !model.downloads.isEmpty) {
            HStack(spacing: 4) {
                if page == .downloads {
                    FilterTabs(options: QueueFilter.allCases, selection: $filter, title: { $0.rawValue }, palette: palette)
                    Spacer(minLength: 0)
                    if filter == .failed && query.isEmpty && model.retryCount > 1 && !model.busy {
                        Button("重试未完成") { model.retry() }.buttonStyle(.borderless).font(.system(size: 12))
                            .padding(.trailing, 8)
                    }
                    searchField
                } else {
                    if libraryFilter == .removed {
                        Button { libraryFilter = .all } label: { Label("已移除", systemImage: "chevron.left").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(secondary).help("返回文档库")
                    }
                    else { FilterTabs(options: [LibraryFilter.all, .favorites, .unread], selection: $libraryFilter, title: { $0.rawValue }, palette: palette) }
                    Spacer()
                    if let tag = libraryTag {
                        Button { libraryTag = nil } label: {
                            HStack(spacing: 6) { Text(tag).lineLimit(1); Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        }.buttonStyle(QuietButtonStyle(palette: palette)).help("清除标签筛选")
                            .accessibilityLabel("清除标签筛选：\(tag)")
                    }
                }
            }.frame(height: 36)
            }
            if rows.isEmpty {
                empty(icon: query.isEmpty && filter == .all ? "tray" : "magnifyingglass", text: emptyMessage)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: page == .library ? 8 : 0) {
                            ForEach(rows) { item in
                                if page == .library, let paper = model.papers.first(where: { $0.id == item.id }) {
                                    LibraryRow(paper: paper, model: model, selected: selectedID == item.id, select: { selectedID = item.id; inputFocused = false; listFocus = UUID() })
                                        .id(item.id)
                                } else {
                                DownloadRow(item: item, model: model, inMediaLibrary: page == .media, selected: selectedID == item.id, select: { selectedID = item.id; inputFocused = false; listFocus = UUID() })
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedID = item.id; inputFocused = false; listFocus = UUID() }
                                    .id(item.id)
                                }
                            }
                        }.padding(1)
                    }
                    .background(PaperListKeyboard(request: listFocus, detailsShortcut: model.shortcuts[.details], didFocus: { request in
                        if listFocus == request { listFocus = nil }
                    }) { action in
                        guard !rows.isEmpty else { return }
                        if action == .up || action == .down {
                            let index = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
                            let next = index.map { min(rows.count - 1, max(0, $0 + (action == .down ? 1 : -1))) } ?? 0
                            selectedID = rows[next].id
                            scroll.scrollTo(rows[next].id)
                        } else if let item = rows.first(where: { $0.id == selectedID }) {
                            if page == .library, let paper = model.papers.first(where: { $0.id == item.id }) {
                                if action == .diagnostics { model.showPaperDetails(paper) }
                                else if !paper.removed { model.openPaper(paper, preview: action == .preview) }
                            }
                            else if action == .preview { model.preview(item) }
                            else if action == .open { model.openFile(item) }
                            else if action == .diagnostics { model.diagnosticItem = item }
                        }
                    })
                }.id(page).frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "没有匹配的结果" }
        if page == .media { return "暂无媒体" }
        if page == .library {
            if libraryTag != nil { return "没有匹配的结果" }
            switch libraryFilter { case .all: return "暂无文档"; case .favorites: return "暂无收藏"; case .unread: return "暂无未读文档"; case .removed: return "暂无已移除文档" }
        }
        if !model.downloads.isEmpty { return "暂无\(filter.rawValue)任务" }
        return "粘贴链接，开始拾取"
    }

    private func empty(icon: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logContent: some View {
        LogContent(entries: visibleLogs, hasLogs: !model.logs.isEmpty, query: query, level: $logLevel, palette: palette)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.directoryNotice ?? model.notice ?? model.libraryNotice ?? model.mediaLibraryNotice ?? model.persistenceNotice {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(UIColors.error)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if page == .downloads {
                    if model.busy { ProgressView().controlSize(.mini).frame(width: 12) }
                    else if !model.summary.isEmpty { Circle().fill(accent).frame(width: 5, height: 5) }
                    Text(model.summary).lineLimit(1)
                    Spacer()
                    if !model.downloads.isEmpty { Text("\(visibleItems.count) 项").monospacedDigit() }
                } else if page == .logs {
                    Text("\(visibleLogs.count) 条").monospacedDigit()
                    Spacer()
                } else if page == .media {
                    Spacer(); Text("\(visibleItems.count) 项").monospacedDigit()
                } else {
                    if model.importingPDFs { Text("正在导入…") }
                    else if !model.checkingVersions.isEmpty { Text("正在检查版本 · 剩余 \(model.checkingVersions.count) 篇") }
                    Spacer(); Text("\(libraryPapers.count) 篇").monospacedDigit()
                }
            }.font(.system(size: 11)).foregroundStyle(secondary).frame(height: 18)
        }
    }

    static func inputRange(of token: String, in text: String) -> NSRange? {
        let raw = text as NSString
        let expression = try! NSRegularExpression(pattern: #"[^\s,;，；]+"#)
        return expression.matches(in: text, range: NSRange(location: 0, length: raw.length))
            .first(where: { raw.substring(with: $0.range) == token })?.range
    }
}

struct LogHeading {
    let date: Date?
    var subject: String?

    // Keep rows flat and store only headings, not a second copy of every event.
    static func headings(_ entries: [ActivityEntry], calendar: Calendar = .current) -> [UUID: LogHeading] {
        var result: [UUID: LogHeading] = [:]
        var previous: ActivityEntry?, groupID: UUID?
        for entry in entries {
            let sameDay = previous.map { calendar.isDate($0.date, inSameDayAs: entry.date) } ?? false
            if !sameDay || entry.itemID == nil || entry.itemID != previous?.itemID {
                groupID = entry.id
                result[entry.id] = LogHeading(date: sameDay ? nil : entry.date)
            }
            if let groupID, let subject = entry.subject, !subject.isEmpty { result[groupID]?.subject = subject }
            previous = entry
        }
        return result
    }
}

struct LogRow: View {
    static let messageInset: CGFloat = 64 + 12 + 16 + 12
    let entry: ActivityEntry
    let palette: ThemePalette
    var horizontalInset: CGFloat = 20
    private var color: Color {
        switch entry.level { case .error: return UIColors.error; case .success: return UIColors.success; case .warning: return ThemePalette.color(palette.accent); default: return ThemePalette.color(palette.secondary) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(ThemePalette.color(palette.secondary))
                .frame(width: 64, height: 16, alignment: .leading)
                .help(entry.date.formatted(date: .complete, time: .standard))
            Image(systemName: entry.level.symbol).font(.system(size: 12)).foregroundStyle(color).frame(width: 16, height: 16)
                .opacity(entry.level == .info ? 0 : 1)
                .accessibilityLabel(entry.level.label)
            Text(entry.message).font(.system(size: 12)).foregroundStyle(entry.level == .error ? color : ThemePalette.color(palette.text))
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading).textSelection(.enabled)
        }.padding(.vertical, 8).padding(.horizontal, horizontalInset)
            .contentShape(Rectangle()).help(entry.subject ?? entry.message)
            .accessibilityElement(children: .ignore).accessibilityLabel(entry.line)
            .contextMenu {
                Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.line, forType: .string) }
            }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let model: DownloadModel
    let busy: Bool
    let theme: AppTheme
    let inMediaLibrary: Bool
    let selected: Bool
    let select: () -> Void

    init(item: DownloadItem, model: DownloadModel, inMediaLibrary: Bool = false, selected: Bool = false, select: @escaping () -> Void = {}) {
        self.item = item; self.model = model; self.inMediaLibrary = inMediaLibrary
        busy = model.busy; theme = model.theme; self.selected = selected; self.select = select
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    private var palette: ThemePalette { theme.palette(dark: scheme == .dark) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.mediaFormat == .audio ? "waveform" : item.source?.symbol ?? "doc")
                .font(.system(size: 22, weight: .light)).foregroundStyle(secondary)
                .frame(width: 28, height: 34)
                .accessibilityLabel(item.state.label)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineSpacing(3)
                    .lineLimit(2).help(item.title)
                HStack(spacing: 10) {
                    if let metadata = item.metadata { Text(metadata.reference.identifier).font(.system(size: 11, design: .monospaced)) }
                    else if let host = item.directURL?.host, item.documentTitle != nil { Text(host).lineLimit(1) }
                    if !inMediaLibrary || item.state == .missing {
                    HStack(spacing: 4) {
                        Image(systemName: item.state.symbol).font(.system(size: 10))
                        Text(item.state.label)
                    }.foregroundStyle(item.state.color(palette)).lineLimit(1)
                    }
                    if let files = item.additionalURLs, !files.isEmpty { Text("\(files.count + 1) 个文件") }
                }.font(.system(size: 11)).foregroundStyle(secondary)
                if let progress = item.progress, item.state == .downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fraction = progress.fraction { ProgressView(value: fraction).tint(ThemePalette.color(palette.accent)).progressViewStyle(.linear) }
                        Text(progressText(progress)).font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
                    }.frame(maxWidth: 320)
                }
                if let error = item.error {
                    Text(error).font(.system(size: 11)).lineSpacing(3)
                        .foregroundStyle(item.state == .paused || item.state == .cancelled ? secondary : UIColors.error)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            HStack(spacing: 6) {
                if let url = item.savedURL, !inMediaLibrary || item.state != .missing || item.localURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    Button("打开") { model.openFile(item) }.buttonStyle(QuietButtonStyle(palette: palette)).help(url.path)
                } else if item.canRetry {
                    Button("重试", action: retry)
                        .buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy)
                } else if item.source == nil {
                    Button("修改") { model.edit(item) }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy)
                }
                Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32)
                    .accessibilityLabel("\(item.title)的更多操作")
            }.padding(.top, 1)
        }.padding(.horizontal, 10).padding(.vertical, 13)
            .background(selected ? ThemePalette.color(palette.accent).opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                Rectangle().fill(ThemePalette.color(palette.border).opacity(0.6)).frame(height: 1 / displayScale)
                    .padding(.leading, 50).padding(.trailing, 10)
            }
            .contextMenu { actions }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        if !item.localURLs.isEmpty {
            Button("快速预览") { select(); model.preview(item) }.help("选中文件后按空格")
            Button("在 Finder 中显示") { model.openFile(item, reveal: true) }
            Divider()
        }
        Button("任务详情…") { select(); model.diagnosticItem = item }.help("选中文件后按 \(model.shortcuts[.details].label)")
        if item.canRetry && item.savedURL != nil {
            Button("重新下载缺失文件", action: retry).disabled(busy)
        }
        if let source = item.source {
            Button("打开来源页面") { model.openSource(item) }
            Button("复制来源链接") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.webURL.absoluteString, forType: .string)
            }
        }
        if let url = item.savedURL {
            Button("复制文件名") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.lastPathComponent, forType: .string) }
        }
    }

    private func retry() {
        if inMediaLibrary { model.retryFromLibrary(item) } else { model.retry(item.id) }
    }

    private func progressText(_ progress: DownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        var parts = [progress.fraction.map { "\(Int($0 * 100))% · \(received)" } ?? received]
        if let speed = item.bytesPerSecond, speed >= 1, speed.isFinite, speed < Double(Int64.max) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
        }
        return parts.joined(separator: " · ")
    }
}

struct LogContent: View {
    let entries: [ActivityEntry]
    let hasLogs: Bool
    let query: String
    @Binding var level: ActivityLevel?
    let palette: ThemePalette
    @WorkspaceViewState private var position = LogScrollPosition()
    @WorkspaceViewState private var followingLatest = true
    @WorkspaceViewState private var requestedBottom: Bool?
    @WorkspaceViewState private var scrollRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    private var pointsUp: Bool { requestedBottom ?? position.atBottom }

    var body: some View {
        let headers = LogHeading.headings(entries)
        VStack(spacing: 16) {
            if hasLogs {
                HStack(spacing: 4) {
                    FilterTabs(options: [nil] + ActivityLevel.allCases.map(Optional.some), selection: $level, title: { $0?.label ?? "全部" }, palette: palette)
                    Spacer()
                    if position.canScroll && !entries.isEmpty {
                        Button { jump(toBottom: !pointsUp) } label: {
                            Image(systemName: "arrow.down.to.line")
                                .rotationEffect(.degrees(pointsUp ? 180 : 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pointsUp)
                        }.buttonStyle(RoundButtonStyle(palette: palette))
                            .help(pointsUp ? "回到最早日志" : "前往最新日志")
                            .accessibilityLabel(pointsUp ? "回到最早日志" : "前往最新日志")
                    }
                }.frame(height: 36)
            }
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft").font(.system(size: 28, weight: .light))
                    Text(query.isEmpty && level == nil ? "暂无日志" : "没有匹配的日志").font(.system(size: 13))
                }.foregroundStyle(secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 0) {
                                if let group = headers[entry.id], group.subject != nil || group.date != nil {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let date = group.date {
                                            Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(secondary)
                                        }
                                        if let subject = group.subject {
                                            Text(subject).font(.system(size: 12, weight: .medium)).lineLimit(1).help(subject).textSelection(.enabled)
                                                .padding(.leading, LogRow.messageInset)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
                                }
                                LogRow(entry: entry, palette: palette)
                            }.id(entry.id)
                        }
                    }.background(LogScrollObserver(followingLatest: followingLatest, request: scrollRequest,
                                                   destination: requestedBottom, animated: !reduceMotion, changed: { metrics in
                        position = metrics
                        if requestedBottom == true && metrics.atBottom || requestedBottom == false && metrics.atTop { requestedBottom = nil }
                    }, userScrolled: { metrics in
                        requestedBottom = nil
                        followingLatest = metrics.atBottom
                    }))
                }

            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: query) { _ in reset() }
            .onChange(of: level) { _ in reset() }
    }
    private func reset() {
        followingLatest = true; requestedBottom = nil; position = LogScrollPosition()
        scrollRequest += 1
    }
    private func jump(toBottom: Bool) {
        followingLatest = toBottom; requestedBottom = toBottom
        scrollRequest += 1
    }
}

struct DirectoryMenu: View {
    @ObservedObject var model: DownloadModel
    let palette: ThemePalette
    var body: some View {
        Menu {
            Text(model.directoryLabel)
            Text("自动归入 Papers、Videos、Audio、Images")
            if !model.directoryExists { Text("首次下载时创建文件夹") }
            Divider()
            Button("更改保存位置…", action: model.chooseDirectory).disabled(model.busy)
            Button("在访达中打开", action: model.openDirectory).disabled(!model.directoryExists)
        } label: {
            Label(model.directory.lastPathComponent.isEmpty ? "/" : model.directory.lastPathComponent, systemImage: "folder")
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(ThemePalette.color(palette.secondary))
        }.menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette, showsChevron: true)).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.leading, -12)
            .help("\(model.directoryLabel)\n自动归入 Papers、Videos、Audio、Images")
            .accessibilityLabel("保存位置：\(model.directoryLabel)，自动按类型归档")
    }
}

struct MenuTriggerStyle: ButtonStyle {
    let palette: ThemePalette
    var showsChevron = false
    @WorkspaceViewState private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ThemePalette.color(palette.secondary))
                    .rotationEffect(.degrees(configuration.isPressed ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isPressed)
                    .accessibilityHidden(true)
            }
        }.padding(.horizontal, showsChevron ? 12 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(RoundedRectangle(cornerRadius: showsChevron ? 16 : 8, style: .continuous))
            .background(ThemePalette.color(palette.accent).opacity(enabled ? (configuration.isPressed ? 0.18 : hovered ? 0.09 : 0) : 0), in: RoundedRectangle(cornerRadius: showsChevron ? 16 : 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}
