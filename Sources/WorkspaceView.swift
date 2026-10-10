import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

typealias WorkspaceViewState<Value> = SwiftUI.State<Value>

enum WorkspacePage: String, CaseIterable {
    case downloads = "下载", library = "资料库", logs = "日志"
    var icon: String {
        switch self { case .downloads: return "arrow.down.circle"; case .library: return "books.vertical"; case .logs: return "text.alignleft" }
    }
    var filledIcon: String {
        switch self { case .downloads: return "arrow.down.circle.fill"; case .library: return "books.vertical.fill"; case .logs: return icon }
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
            .padding(.horizontal, 14).frame(height: 34)
            .background(ThemePalette.color(palette.accent).opacity(configuration.isPressed ? 0.19 : 0.10))
            .clipShape(Capsule())
    }
}

struct RoundButtonStyle: ButtonStyle {
    let palette: ThemePalette
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .foregroundStyle(ThemePalette.color(palette.text).opacity(enabled ? 1 : 0.35))
            .frame(width: 36, height: 36)
            .background(ThemePalette.color(palette.accent).opacity(configuration.isPressed ? 0.20 : 0.09))
            .clipShape(Circle())
    }
}

struct DownloaderView: View {
    private struct LogScrollTarget: Hashable {
        let lastID: UUID?
        let count: Int
        let following: Bool
        let query: String
        let level: ActivityLevel?
    }
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
    @WorkspaceViewState private var followLogs = true
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
        let source = model.items
        return source.filter { item in
            (page == .library || filter.includes(item)) &&
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.original.localizedCaseInsensitiveContains(query))
        }
    }
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
                header
                VStack(alignment: .leading, spacing: 20) {
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
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(model.$listRequest.dropFirst()) { _ in
            if page == .logs { focusListOnArrival = true; page = .library }
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
        .onReceive(model.$batchID.dropFirst()) { _ in page = .downloads; filter = .all }
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
                ForEach(WorkspacePage.allCases, id: \.self) { destination in
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
                SidebarSelectionIndicator(index: WorkspacePage.allCases.firstIndex(of: page) ?? 0, color: accent)
                    .opacity(navigationHovered || navigationActivatedAt != nil ? 1 : 0)
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
            Text(page.rawValue).font(.system(size: 23, weight: .medium))
            Spacer()
            if page == .library {
                if !model.papers.isEmpty { searchField }
                Button { libraryFilter = .all; libraryTag = nil; query = ""; model.importPDFs() } label: { Image(systemName: "plus") }
                    .buttonStyle(RoundButtonStyle(palette: palette)).help("导入本地 PDF").accessibilityLabel("导入 PDF").disabled(model.importingPDFs || !model.libraryWritable)
                Menu {
                    Button("导出资料库", action: model.exportLibrary).disabled(!model.papers.contains { !$0.removed })
                    if model.checkingVersions.isEmpty {
                        Button("检查论文新版本") { model.checkPaperVersions(libraryPapers.map(\.id)) }
                            .disabled(!libraryPapers.contains { $0.reference != nil })
                    } else { Button("停止检查版本", action: model.cancelVersionCheck) }
                    Divider()
                    Button(libraryFilter == .removed ? "返回资料库" : "已移除的论文") {
                        libraryFilter = libraryFilter == .removed ? .all : .removed; query = ""; libraryTag = nil
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).accessibilityLabel("资料库操作")
            } else if page == .logs && !model.logs.isEmpty {
                searchField
                Button {
                    if page == .logs { model.exportLogs(visibleLogs) } else { model.exportLibrary() }
                } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(RoundButtonStyle(palette: palette))
                    .disabled(page == .logs ? visibleLogs.isEmpty : model.history.isEmpty)
                    .help(page == .logs ? "导出当前筛选的日志" : "导出资料库索引")
                    .accessibilityLabel(page == .logs ? "导出日志" : "导出资料库")
            } else if page == .downloads {
                Button(action: model.openDirectory) { Image(systemName: "folder") }
                    .buttonStyle(RoundButtonStyle(palette: palette)).help("打开保存目录").accessibilityLabel("打开保存目录")
            }
        }.frame(height: 76)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "link").font(.system(size: 15, weight: .medium))
                Text("添加论文").font(.system(size: 14, weight: .medium))
                Spacer()
                Button(action: model.importLinks) { Image(systemName: "square.and.arrow.down").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .help("从文本文件导入链接").accessibilityLabel("导入链接")
                Button(action: model.paste) { Image(systemName: "doc.on.clipboard").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .help("追加剪贴板中的链接").accessibilityLabel("粘贴链接")
            }.buttonStyle(.plain).disabled(model.busy).padding(.horizontal, 20).padding(.top, 12)
            LinkInput(model: model, focused: $inputFocused, palette: palette)
                .frame(height: 104).padding(.horizontal, 8).padding(.top, 8)
            HStack(spacing: 12) {
                Button(action: model.chooseDirectory) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 14))
                        Text(model.directoryLabel).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                    }.font(.system(size: 12)).foregroundStyle(secondary).frame(height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.busy).help(model.directory.path).accessibilityLabel("更改保存目录")
                Spacer(minLength: 8)
                if model.busy {
                    Button(action: model.cancel) { Label(model.cancelling ? "正在取消" : "取消下载", systemImage: "stop.fill") }
                        .buttonStyle(PrimaryActionStyle(palette: palette, prominent: false))
                        .keyboardShortcut(.cancelAction).disabled(model.cancelling).frame(width: 128)
                } else {
                    Button(action: model.start) { Label("开始下载", systemImage: "arrow.down") }
                        .buttonStyle(PrimaryActionStyle(palette: palette))
                        .keyboardShortcut(KeyEquivalent(Character(model.shortcuts[.download].key)), modifiers: model.shortcuts[.download].swiftModifiers)
                        .disabled(model.tokenCount == 0).frame(width: 128).help("开始下载（\(model.shortcuts[.download].label)）")
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
                .accessibilityLabel(page == .logs ? "搜索日志" : "搜索论文")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(secondary).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, 13).frame(width: 178, height: 36)
            .background(ThemePalette.color(palette.surface)).clipShape(Capsule())
    }

    private var papers: some View {
        let rows = visibleItems
        return VStack(spacing: 14) {
            if page == .library || !model.items.isEmpty {
            HStack(spacing: 4) {
                if page == .downloads {
                    FilterTabs(options: QueueFilter.allCases, selection: $filter, title: { $0.rawValue }, palette: palette)
                    Spacer(minLength: 0)
                    if model.canRetry && !model.busy {
                        Button("重试未完成") { model.retry() }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                    if model.items.contains(where: { $0.canRetry || $0.source == nil }) {
                        Menu {
                            Button("复制未完成链接", action: model.copyUnfinished)
                        } label: { Image(systemName: "ellipsis").frame(width: 22, height: 30) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).accessibilityLabel("任务操作")
                    }
                } else {
                    if libraryFilter == .removed {
                        Button { libraryFilter = .all } label: { Label("已移除", systemImage: "chevron.left").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(secondary).help("返回资料库")
                    }
                    else { FilterTabs(options: [LibraryFilter.all, .favorites, .unread], selection: $libraryFilter, title: { $0.rawValue }, palette: palette) }
                    Spacer()
                    Menu {
                        Picker("排序", selection: $librarySort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Divider()
                        Button("全部标签") { libraryTag = nil }
                        ForEach(Array(Set(model.papers.filter { !$0.removed }.flatMap(\.tags))).sorted(), id: \.self) { tag in
                            Button { libraryTag = tag } label: { if libraryTag == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) } }
                        }
                    } label: { Label(libraryTag ?? librarySort.rawValue, systemImage: "line.3.horizontal.decrease").font(.system(size: 12)).lineLimit(1) }
                        .menuStyle(.borderlessButton).frame(maxWidth: 155).accessibilityLabel("筛选与排序")
                }
            }.frame(height: 36)
            }
            if rows.isEmpty {
                empty(icon: query.isEmpty && filter == .all ? "tray" : "magnifyingglass", text: emptyMessage)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(rows) { item in
                                if page == .library, let paper = model.papers.first(where: { $0.id == item.id }) {
                                    LibraryRow(paper: paper, model: model, selected: selectedID == item.id, select: { selectedID = item.id; inputFocused = false; listFocus = UUID() })
                                        .id(item.id)
                                } else {
                                DownloadRow(item: item, model: model, inLibrary: page == .library, selected: selectedID == item.id, select: { selectedID = item.id; inputFocused = false; listFocus = UUID() })
                                    .contentShape(RoundedRectangle(cornerRadius: 20))
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
        if page == .library {
            if libraryTag != nil { return "没有匹配的结果" }
            switch libraryFilter { case .all: return "暂无论文"; case .favorites: return "暂无收藏"; case .unread: return "暂无未读论文"; case .removed: return "暂无已移除论文" }
        }
        if !model.items.isEmpty { return "暂无\(filter.rawValue)任务" }
        return "暂无下载"
    }

    private func empty(icon: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                .frame(width: 68, height: 68).background(accent.opacity(0.08)).clipShape(Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logContent: some View {
        let entries = visibleLogs
        let headers = Dictionary(uniqueKeysWithValues: LogGroup.grouped(entries).map { ($0.id, $0) })
        return VStack(spacing: 16) {
            if !model.logs.isEmpty {
            HStack(spacing: 4) {
                FilterTabs(options: [nil] + ActivityLevel.allCases.map(Optional.some), selection: $logLevel, title: { $0?.label ?? "全部" }, palette: palette)
                Spacer()
                Button { followLogs.toggle() } label: { Image(systemName: "arrow.down.to.line").foregroundStyle(followLogs ? accent : secondary) }
                    .buttonStyle(RoundButtonStyle(palette: palette)).help(followLogs ? "停止跟随最新日志" : "跟随最新日志")
                    .accessibilityLabel("跟随最新日志").accessibilityValue(followLogs ? "开启" : "关闭")
            }.frame(height: 36)
            }
            if entries.isEmpty { empty(icon: "text.alignleft", text: query.isEmpty && logLevel == nil ? "暂无日志" : "没有匹配的日志") }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 0) {
                                    if let group = headers[entry.id], group.subject != nil || group.showsDate {
                                        VStack(alignment: .leading, spacing: 8) {
                                            if group.showsDate {
                                                Text(group.date.formatted(date: .abbreviated, time: .omitted))
                                                    .font(.system(size: 11)).foregroundStyle(secondary)
                                            }
                                            if let subject = group.subject {
                                                Text(subject).font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1).help(subject).textSelection(.enabled)
                                                    .padding(.leading, LogRow.messageInset)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 8)
                                    }
                                    LogRow(entry: entry, palette: palette)
                                }.id(entry.id)
                            }
                            Color.clear.frame(height: 1).id("log-end")
                        }
                    }
                    .task(id: LogScrollTarget(lastID: entries.last?.id, count: entries.count, following: followLogs, query: query, level: logLevel)) {
                        // Let the lazy rows register their scroll targets on first entry.
                        await Task.yield()
                        if !Task.isCancelled, followLogs { proxy.scrollTo("log-end", anchor: .bottom) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.directoryNotice ?? model.notice ?? model.libraryNotice ?? model.persistenceNotice {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(UIColors.error)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if page == .downloads {
                    if model.busy { ProgressView().controlSize(.mini).frame(width: 12) }
                    else if !model.summary.isEmpty { Circle().fill(accent).frame(width: 5, height: 5) }
                    Text(model.summary).lineLimit(1)
                    Spacer()
                    if !model.items.isEmpty { Text("\(model.items.count) 项").monospacedDigit() }
                } else if page == .logs {
                    Text("\(visibleLogs.count) 条").monospacedDigit()
                    Spacer()
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

struct LogGroup: Identifiable {
    var entries: [ActivityEntry]
    let showsDate: Bool
    var id: UUID { entries[0].id }
    var date: Date { entries[0].date }
    var subject: String? { entries.last(where: { $0.subject?.isEmpty == false })?.subject }

    // Group only adjacent events for a known task, after filtering; never reorder the timeline.
    static func grouped(_ entries: [ActivityEntry], calendar: Calendar = .current) -> [LogGroup] {
        var groups: [LogGroup] = []
        for entry in entries {
            let sameDay = groups.last.map { calendar.isDate($0.date, inSameDayAs: entry.date) } ?? false
            if sameDay, let itemID = entry.itemID, groups.last?.entries.first?.itemID == itemID {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(LogGroup(entries: [entry], showsDate: !sameDay))
            }
        }
        return groups
    }
}

struct LogRow: View {
    static let messageInset: CGFloat = 64 + 12 + 16 + 12
    let entry: ActivityEntry
    let palette: ThemePalette
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
                .accessibilityLabel(entry.level.label)
            Text(entry.message).font(.system(size: 12)).foregroundStyle(entry.level == .error ? color : ThemePalette.color(palette.text))
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading).textSelection(.enabled)
        }.padding(.vertical, 8).padding(.horizontal, 20)
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
    let inLibrary: Bool
    let busy: Bool
    let theme: AppTheme
    let selected: Bool
    let select: () -> Void

    init(item: DownloadItem, model: DownloadModel, inLibrary: Bool = false, selected: Bool = false, select: @escaping () -> Void = {}) {
        self.item = item; self.model = model; self.inLibrary = inLibrary
        busy = model.busy; theme = model.theme; self.selected = selected; self.select = select
    }
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { theme.palette(dark: scheme == .dark) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 21, weight: .light)).foregroundStyle(ThemePalette.color(palette.accent))
                .frame(width: 44, height: 44).background(ThemePalette.color(palette.accent).opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel(item.state.label)
            VStack(alignment: .leading, spacing: 9) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineSpacing(3)
                    .lineLimit(2).help(item.title)
                HStack(spacing: 10) {
                    if let metadata = item.metadata { Text(metadata.reference.identifier).font(.system(size: 11, design: .monospaced)) }
                    else if let host = item.directURL?.host, item.documentTitle != nil { Text(host).lineLimit(1) }
                    HStack(spacing: 4) {
                        Image(systemName: item.state.symbol).font(.system(size: 10))
                        Text(item.state.label)
                    }.foregroundStyle(item.state.color(palette)).lineLimit(1)
                    if let pages = item.pages { Text("\(pages) 页") }
                    if inLibrary, let date = item.finishedAt { Text(date.formatted(date: .abbreviated, time: .omitted)) }
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
                if let url = item.savedURL {
                    Button("打开") { model.openFile(item) }.buttonStyle(QuietButtonStyle(palette: palette)).help(url.path)
                } else if item.canRetry {
                    Button("重试") { if inLibrary { model.retryFromLibrary(item) } else { model.retry(item.id) } }
                        .buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy)
                } else if item.source == nil {
                    Button("修改") { model.edit(item) }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy)
                }
                Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 20, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                    .accessibilityLabel("\(item.title)的更多操作")
            }.padding(.top, 5)
        }.padding(20).background(ThemePalette.color(palette.surface))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? ThemePalette.color(palette.accent).opacity(0.65) : ThemePalette.color(palette.border).opacity(0.4), lineWidth: 1))
            .contextMenu { actions }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        if item.savedURL != nil {
            Button("快速预览") { select(); model.preview(item) }.help("选中论文后按空格")
            Button("在 Finder 中显示") { model.openFile(item, reveal: true) }
            Button("文件信息…") { model.fileInfo(item) }
            Divider()
        }
        Button("任务详情…") { select(); model.diagnosticItem = item }.help("选中论文后按 \(model.shortcuts[.details].label)")
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

    private func progressText(_ progress: DownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        var parts = [progress.fraction.map { "\(Int($0 * 100))% · \(received)" } ?? received]
        if let speed = item.bytesPerSecond, speed >= 1, speed.isFinite, speed < Double(Int64.max) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
        }
        return parts.joined(separator: " · ")
    }
}
