import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

typealias WorkspaceViewState<Value> = SwiftUI.State<Value>

enum WorkspacePreferencesPage: String, CaseIterable {
    case settings = "设置", about = "关于"
    var icon: String { self == .settings ? "gearshape" : "info.circle" }
}

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

// Routine file actions stay discoverable to keyboard and VoiceOver users;
// only recovery actions receive a filled treatment.
struct RowActionStyle: ButtonStyle {
    let palette: ThemePalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WorkspaceMetrics.TypeScale.body)
            .foregroundStyle(ThemePalette.color(configuration.isPressed ? palette.accent : palette.secondary))
            .padding(.horizontal, WorkspaceMetrics.Space.compact)
            .frame(height: WorkspaceMetrics.controlHeight)
            .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control))
            .modifier(ControlFeedback(palette: palette, pressed: configuration.isPressed))
    }
}

struct RoundButtonStyle: ButtonStyle {
    let palette: ThemePalette
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .foregroundStyle(ThemePalette.color(palette.text).opacity(enabled ? 1 : 0.35))
            .frame(width: 32, height: 32)
            .modifier(ControlFeedback(palette: palette, pressed: configuration.isPressed))
    }
}

// Shared, quiet hover/press feedback for text actions and icon controls.
struct ControlFeedback: ViewModifier {
    let palette: ThemePalette
    let pressed: Bool
    @WorkspaceViewState private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .background(ThemePalette.color(palette.text).opacity(enabled ? (pressed ? 0.09 : hovered ? 0.05 : 0) : 0))
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control, style: .continuous))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct DownloaderView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    @WorkspaceViewState var page: WorkspacePage = .downloads
    @WorkspaceViewState var logItem: DownloadItem?
    @WorkspaceViewState private var pendingDetailLogs: DownloadItem?
    var showSettings: () -> Void = {}
    var endTextEditing: () -> Void = {}
    @WorkspaceViewState private var collapsed = false
    @WorkspaceViewState private var hasOpenedSettings = false
    @WorkspaceViewState private var previousPreferencesPage: WorkspacePreferencesPage?
    @WorkspaceViewState private var restoreListFocus = false
    private var workspaceActive: Bool { model.preferencesPage == nil }
    private var traceContext: InteractionEvent.Context {
        switch page { case .downloads: return .downloads; case .library: return .documents; case .media: return .media; case .logs: return .logs }
    }
    @WorkspaceViewState private var inputFocused = false
    @WorkspaceViewState private var query = ""
    @WorkspaceViewState private var traceSearchTask: Task<Void, Never>?
    @WorkspaceViewState private var searchExpanded = false
    @WorkspaceViewState private var searchFocusRequest: (id: UUID, edit: UUID, list: UUID, page: WorkspacePage)?
    @FocusState private var searchFocused: Bool
    @WorkspaceViewState private var filter: QueueFilter = .all
    @WorkspaceViewState private var logLevel: ActivityLevel? = nil
    @WorkspaceViewState private var dropTargeted = false
    @WorkspaceViewState private var selection = FileListSelection()
    @WorkspaceViewState private var mediaRemoved = false
    @WorkspaceViewState private var confirmingLibraryRemoval: LibraryRemovalUndo?
    @WorkspaceViewState private var listFocus: UUID?
    @WorkspaceViewState private var listFocused = false
    @WorkspaceViewState private var focusListOnArrival = false
    @WorkspaceViewState private var confirmingClearDownloads = false
    @WorkspaceViewState private var libraryFilter = LibraryFilter.all
    @WorkspaceViewState private var librarySort = LibrarySort.newest
    @WorkspaceViewState private var libraryTag: String?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    private var accent: Color { ThemePalette.color(palette.accent) }
    private var recordTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.10)))
    }
    private var listSelectionActive: Bool { listFocused && !inputFocused && !searchFocused }
    private var selectedID: UUID? { selection.primary }
    private var displayMode: LibraryDisplayMode { page == .library ? model.documentDisplayMode : page == .media ? model.mediaDisplayMode : .list }
    private var displayBinding: Binding<LibraryDisplayMode> {
        Binding(get: { displayMode }, set: { if page == .library { model.documentDisplayMode = $0 } else { model.mediaDisplayMode = $0 } })
    }
    private var libraryCollection: LibraryCollection? { page == .library ? .documents : page == .media ? .media : nil }
    private var showingRemoved: Bool { page == .library ? libraryFilter == .removed : mediaRemoved }
    private var selectedLibraryIDs: Set<UUID> { selection.ids.intersection(visibleItems.map(\.id)) }
    private var libraryResult: LibraryQueryCache.Documents {
        model.libraryQueries.documents(model.papers, revision: model.libraryRevision, query: query,
            filter: libraryFilter, sort: librarySort, tag: libraryTag)
    }
    private var visibleItems: [DownloadItem] {
        if page == .library { return libraryResult.items }
        if page == .media {
            return model.libraryQueries.media(model.mediaLibrary, revision: model.mediaLibraryRevision, query: query, removed: mediaRemoved)
        }
        return model.downloads.filter { item in
            filter.includes(item) &&
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.original.localizedCaseInsensitiveContains(query))
        }
    }
    private var libraryTags: [String] { _ = libraryResult; return model.libraryQueries.tags }
    private var libraryPapers: [LibraryPaper] { libraryResult.papers }
    var visibleLogs: [ActivityEntry] {
        model.logs.filter { (logItem == nil || $0.itemID == logItem?.id) && (logLevel == nil || $0.level == logLevel) && (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query) || $0.localizedMessage.localizedCaseInsensitiveContains(query) || ($0.subject?.localizedCaseInsensitiveContains(query) ?? false)) }
    }

    var body: some View {
        tracedLayout
        .onReceive(model.$listRequest.dropFirst()) { _ in
            model.preferencesPage = nil
            if page == .logs { focusListOnArrival = true; page = .downloads }
            else { focusList() }
        }
        .onReceive(model.$editRequest.dropFirst()) { _ in
            model.preferencesPage = nil
            listFocus = nil; focusListOnArrival = false; page = .downloads; inputFocused = true
        }
        .onReceive(model.$searchRequest.dropFirst()) { openSearch($0) }
        .onAppear { if model.preferencesPage == .settings { hasOpenedSettings = true } }
        .onChange(of: model.preferencesPage) { destination in
            traceSearchTask?.cancel()
            model.trace.user(.pageChanged, context: destination == nil ? traceContext : .settings,
                detail: destination == .about ? .about : destination == .settings ? .general : nil)
            if destination == .settings { hasOpenedSettings = true }
            if destination != nil {
                if previousPreferencesPage == nil { restoreListFocus = listFocused || selectedID != nil }
                searchFocusRequest = nil; searchFocused = false; inputFocused = false; listFocus = nil
                endTextEditing()
            } else if restoreListFocus {
                restoreListFocus = false
                listFocus = UUID()
            }
            previousPreferencesPage = destination
        }
        .onChange(of: searchFocused) { focused in
            if !focused && query.isEmpty { searchExpanded = false }
        }
        .onChange(of: page) { _ in
            traceSearchTask?.cancel()
            model.trace.user(.pageChanged, context: traceContext)
            query = ""; searchExpanded = false; searchFocused = false; selection.clear(); listFocus = nil
            if page != .logs { logItem = nil }
            if page != .downloads { inputFocused = false; endTextEditing() }
            if focusListOnArrival { focusListOnArrival = false; focusList() }
        }
        .onChange(of: page == .library ? libraryResult.ids : visibleItems.map(\.id)) { selection.retainVisible($0) }
        .onChange(of: libraryFilter) { _ in selection.clear(); listFocus = nil }
        .onChange(of: mediaRemoved) { _ in selection.clear(); listFocus = nil }
        .quickLookPreview($model.previewURL)
        .alert(L("清空所有下载记录？"), isPresented: $confirmingClearDownloads) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空记录"), role: .destructive, action: model.clearDownloadRecords)
                .disabled(!model.canClearDownloadRecords)
        } message: {
            Text(L("将移除全部下载记录，包括失败和取消的任务。\n已下载文件、文档库和媒体库都会保留。"))
        }
        .alert(L("移出当前结果？"), isPresented: Binding(get: { confirmingLibraryRemoval != nil }, set: { if !$0 { confirmingLibraryRemoval = nil } })) {
            Button(L("取消"), role: .cancel) { confirmingLibraryRemoval = nil }
            Button(L("移出"), role: .destructive) {
                if let request = confirmingLibraryRemoval {
                    Task { _ = await model.setLibraryRemoved(request.ids, in: request.collection, removed: true) }
                }
                confirmingLibraryRemoval = nil
            }.disabled(model.busy)
        } message: {
            Text(L("将移出 \(confirmingLibraryRemoval?.ids.count ?? 0) 项。文件和下载记录都会保留，可从「已移除」中恢复。"))
        }
        .alert(L("将文件移到废纸篓？"), isPresented: Binding(get: { model.pendingFileTrash != nil }, set: { if !$0 { model.pendingFileTrash = nil } })) {
            Button(L("取消"), role: .cancel) { model.pendingFileTrash = nil }
            Button(L("移到废纸篓"), role: .destructive) {
                if let request = model.pendingFileTrash { _ = model.confirmFileTrash(request) }
            }.disabled(model.busy)
        } message: {
            if let request = model.pendingFileTrash {
                let files = request.existingFiles
                let names = files.prefix(3).map { file in
                    let name = file.lastPathComponent
                    return name.count > 100 ? String(name.prefix(70)) + "…" + String(name.suffix(25)) : name
                }
                Text(L("\(files.count) 个文件") + "\n" + names.joined(separator: "\n") +
                     (files.count > 3 ? "\n…" : "") + "\n\n" +
                     L("下载记录和资料库条目会保留，并更新文件状态。恢复库条目不会恢复文件，可从 Finder 废纸篓找回文件。"))
            }
        }
        .sheet(item: $model.diagnosticItem, onDismiss: {
            if let requested = pendingDetailLogs {
                pendingDetailLogs = nil; logItem = requested; logLevel = nil; query = ""; page = .logs
            } else if selectedID != nil { listFocus = UUID() }
        }) { item in
            TaskDiagnosticView(model: model, item: item, libraryPaperID: page == .library ? item.id : nil, fromMediaLibrary: page == .media,
                               showTaskLogs: { pendingDetailLogs = $0 })
        }
        .sheet(item: $model.renamingAsset, onDismiss: { if selectedID != nil { listFocus = UUID() } }) { request in
            AssetRenameView(model: model, request: request)
        }
        .onChange(of: model.previewURL) { url in if url == nil && selectedID != nil { listFocus = UUID() } }
        .onReceive(model.$batchID.dropFirst()) { _ in model.preferencesPage = nil; page = .downloads; filter = .all; query = ""; searchExpanded = false; searchFocused = false; selection.clear(); listFocus = nil }
    }

    // Split the view expression at existing modifier boundaries so adding
    // observers does not inflate SwiftUI's type-checking work or add UI layers.
    private var tracedLayout: some View {
        workspaceLayout
            .onChange(of: query, perform: traceSearchChanged)
            .onDisappear { traceSearchTask?.cancel() }
            .onChange(of: libraryFilter, perform: traceLibraryFilterChanged)
            .onChange(of: librarySort, perform: traceLibrarySortChanged)
            .onChange(of: libraryTag) { _ in model.trace.user(.filterChanged, context: .documents, detail: .tag) }
            .onChange(of: filter, perform: traceQueueFilterChanged)
            .onChange(of: mediaRemoved) { value in
                let detail: InteractionEvent.Detail = value ? .removed : .all
                model.trace.user(.filterChanged, context: .media, detail: detail)
            }
    }

    private func traceSearchChanged(_ value: String) {
        traceSearchTask?.cancel()
        guard workspaceActive, model.trace.isEnabled else { return }
        let targetPage = page
        traceSearchTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard !Task.isCancelled, workspaceActive, page == targetPage else { return }
            let count: Int
            switch page {
            case .library: count = libraryResult.items.count
            case .logs: count = visibleLogs.count
            default: count = visibleItems.count
            }
            model.trace.record(.searchCompleted, context: traceContext, detail: value.isEmpty ? .empty : .nonempty, count: count)
        }
    }

    private func traceLibraryFilterChanged(_ value: LibraryFilter) {
        let detail: InteractionEvent.Detail
        switch value { case .all: detail = .all; case .favorites: detail = .favorites; case .unread: detail = .unread; case .removed: detail = .removed }
        model.trace.user(.filterChanged, context: .documents, detail: detail)
    }

    private func traceLibrarySortChanged(_ value: LibrarySort) {
        let detail: InteractionEvent.Detail
        switch value { case .newest: detail = .newest; case .title: detail = .title; case .year: detail = .year }
        model.trace.user(.filterChanged, context: .documents, detail: detail)
    }

    private func traceQueueFilterChanged(_ value: QueueFilter) {
        let detail: InteractionEvent.Detail
        switch value { case .all: detail = .all; case .active: detail = .active; case .saved: detail = .saved; case .failed: detail = .failed }
        model.trace.user(.filterChanged, context: .downloads, detail: detail)
    }

    private var workspaceLayout: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ThemePalette.color(palette.border).opacity(0.55)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let destination = model.preferencesPage {
                        HStack {
                            Text(L(destination.rawValue)).font(WorkspaceMetrics.TypeScale.page)
                            Spacer()
                        }.frame(height: WorkspaceMetrics.headerHeight)
                    } else { header }
                }
                ZStack(alignment: .topLeading) {
                    workspaceContent
                        .opacity(workspaceActive ? 1 : 0)
                        .disabled(!workspaceActive)
                        .allowsHitTesting(workspaceActive)
                        .accessibilityHidden(!workspaceActive)
                    if hasOpenedSettings || model.preferencesPage == .settings {
                        WorkspaceSettingsView(model: model)
                            .opacity(model.preferencesPage == .settings ? 1 : 0)
                            .disabled(model.preferencesPage != .settings)
                            .allowsHitTesting(model.preferencesPage == .settings)
                            .accessibilityHidden(model.preferencesPage != .settings)
                    }
                    if model.preferencesPage == .about { WorkspaceAboutView(model: model) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(nil, value: model.preferencesPage)
            }.padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 540)
        .environment(\.locale, L10n.locale)
        .foregroundStyle(ThemePalette.color(palette.text))
        .tint(accent)
        .background(ThemePalette.color(palette.canvas).contentShape(Rectangle()).onTapGesture(perform: dismissEditing))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: scheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.theme)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var workspaceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if page == .downloads { composer }
                if page == .logs { logContent } else {
                    papers.animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.recordAnimation)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.padding(.top, 12).padding(.bottom, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func focusList() {
        guard !visibleItems.isEmpty else { listFocus = nil; return }
        if selectedID == nil, let first = visibleItems.first { selection.select(first.id, visible: visibleItems.map(\.id)) }
        inputFocused = false; listFocus = UUID()
    }

    private func selectItem(_ id: UUID) {
        selection.select(id, visible: visibleItems.map(\.id), modifiers: NSApp.currentEvent?.modifierFlags ?? [],
                         multiple: libraryCollection != nil)
        inputFocused = false; listFocus = UUID()
    }

    private func selectAllVisible() {
        selection.selectAll(visibleItems.map(\.id))
        inputFocused = false; searchFocused = false; listFocus = UUID()
    }

    private func toggleRemoved() {
        if page == .library { libraryFilter = showingRemoved ? .all : .removed; libraryTag = nil }
        else { mediaRemoved.toggle() }
        query = ""; selection.clear(); listFocus = nil
    }

    private func dismissEditing() {
        inputFocused = false
        searchFocused = false
        searchExpanded = false
        endTextEditing()
    }

    private func openSearch(_ request: UUID) {
        guard workspaceActive, hasSearchContent else { return }
        listFocus = nil; focusListOnArrival = false; inputFocused = false
        searchFocusRequest = (request, model.editRequest, model.listRequest, page)
        searchExpanded = true
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: collapsed ? 0 : 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.25)) { collapsed.toggle() }
                } label: { SidebarToggleGlyph(expanded: !collapsed).frame(width: 50, height: 42).contentShape(Rectangle()) }
                    .buttonStyle(SidebarButtonStyle(palette: palette)).foregroundStyle(secondary)
                    .help(collapsed ? L("展开侧栏") : L("收起侧栏")).accessibilityLabel(collapsed ? L("展开侧栏") : L("收起侧栏"))
                Text("Folioak").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ThemePalette.color(palette.text)).fixedSize()
                    .modifier(SidebarLabelFade(progress: collapsed ? 0 : 1))
                    .frame(width: collapsed ? 0 : nil, alignment: .leading).clipped()
                Spacer(minLength: 0)
            }.padding(.top, 34).padding(.bottom, 10)
            VStack(spacing: 6) {
                ForEach(WorkspacePage.navigation, id: \.self) { destination in
                    Button { model.preferencesPage = nil; page = destination } label: {
                        HStack(spacing: 13) {
                            SidebarGlyph(symbol: destination.icon, filledSymbol: destination.filledIcon, selected: workspaceActive && destination == page)
                                .font(.system(size: 17, weight: .regular)).frame(width: 24, height: 24)
                            HStack {
                                Text(L(destination.rawValue)).font(WorkspaceMetrics.TypeScale.body).foregroundStyle(ThemePalette.color(palette.text)).fixedSize()
                                Spacer(minLength: 0)
                                if destination == .downloads && model.busy { Circle().fill(accent).frame(width: 5, height: 5) }
                            }.modifier(SidebarLabelFade(progress: collapsed ? 0 : 1))
                        }
                        .foregroundStyle(ThemePalette.color(palette.secondary))
                        .frame(width: 140, height: 44, alignment: .leading).padding(.horizontal, 13)
                        .frame(width: collapsed ? 50 : 166, alignment: .leading).clipped()
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(SidebarButtonStyle(palette: palette, selected: workspaceActive && destination == page))
                    .help(L(destination.rawValue)).accessibilityLabel(L(destination.rawValue))
                    .accessibilityAddTraits(workspaceActive && destination == page ? .isSelected : [])
                }
            }
            .overlay(alignment: .topLeading) {
                if workspaceActive, let index = WorkspacePage.navigation.firstIndex(of: page) {
                    SidebarSelectionIndicator(index: index, color: accent)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
            Button { model.preferencesPage = nil; logItem = nil; page = .logs } label: {
                HStack(spacing: WorkspaceMetrics.Space.regular) {
                    Image(systemName: WorkspacePage.logs.icon).font(.system(size: 17)).frame(width: 24)
                    Text(L("日志")).font(WorkspaceMetrics.TypeScale.body).foregroundStyle(ThemePalette.color(palette.text)).fixedSize()
                        .modifier(SidebarLabelFade(progress: collapsed ? 0 : 1))
                    Spacer(minLength: 0)
                }.frame(width: 140, height: 44, alignment: .leading).padding(.horizontal, 13)
                    .frame(width: collapsed ? 50 : 166, alignment: .leading).clipped().contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle(palette: palette, selected: workspaceActive && page == .logs))
                .foregroundStyle(secondary).help(L("查看日志")).accessibilityLabel(L("日志"))
                .accessibilityAddTraits(workspaceActive && page == .logs ? .isSelected : [])
            ForEach(WorkspacePreferencesPage.allCases, id: \.self) { destination in
                Button {
                    model.preferencesPage = destination
                    if destination == .settings { showSettings() }
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: destination.icon).font(.system(size: 17)).frame(width: 24)
                        Text(L(destination.rawValue)).font(WorkspaceMetrics.TypeScale.body)
                            .foregroundStyle(ThemePalette.color(palette.text)).fixedSize()
                            .modifier(SidebarLabelFade(progress: collapsed ? 0 : 1))
                        Spacer(minLength: 0)
                    }.frame(width: 140, height: 44, alignment: .leading).padding(.horizontal, 13)
                        .frame(width: collapsed ? 50 : 166, alignment: .leading).clipped().contentShape(Rectangle())
                }.buttonStyle(SidebarButtonStyle(palette: palette, selected: model.preferencesPage == destination))
                    .foregroundStyle(secondary)
                    .help(L(destination == .settings ? "设置（⌘,）" : "关于 Folioak"))
                    .accessibilityLabel(L(destination.rawValue))
                    .accessibilityAddTraits(model.preferencesPage == destination ? .isSelected : [])
            }
            }.overlay(alignment: .topLeading) {
                if model.preferencesPage != nil || page == .logs {
                    SidebarSelectionIndicator(index: model.preferencesPage == .about ? 2 : model.preferencesPage == .settings ? 1 : 0, color: accent)
                }
            }
        }.padding(.horizontal, 12).padding(.bottom, 16).frame(width: collapsed ? 74 : 190)
            .background(ThemePalette.color(palette.sidebar))
            .contentShape(Rectangle()).onTapGesture(perform: dismissEditing)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page == .logs {
                Button { page = .downloads } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(RoundButtonStyle(palette: palette)).help(L("返回下载")).accessibilityLabel(L("返回下载"))
            }
            Text(L(page.rawValue)).font(WorkspaceMetrics.TypeScale.page)
            Spacer()
            if page == .library {
                if !model.papers.isEmpty {
                    Text(selectedLibraryIDs.isEmpty ? L("\(libraryPapers.count) 项") : L("已选 \(selectedLibraryIDs.count) 项"))
                        .font(.callout).monospacedDigit().foregroundStyle(secondary)
                    searchField
                }
                Menu {
                    Button(L("导入 PDF…"), action: importPDFs)
                        .disabled(model.importingPDFs || !model.libraryWritable)
                    Picker(L("排序"), selection: $librarySort) { ForEach(LibrarySort.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }.id(localization.language)
                    if !libraryTags.isEmpty {
                        Menu(L("标签")) {
                            Button { libraryTag = nil } label: { if libraryTag == nil { Label(L("全部标签"), systemImage: "checkmark") } else { Text(L("全部标签")) } }
                            ForEach(libraryTags, id: \.self) { tag in
                                Button { libraryTag = tag } label: { if libraryTag == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) } }
                            }
                        }
                    }
                    Divider()
                    Button(L("导出文档库"), action: model.exportLibrary).disabled(!model.papers.contains { !$0.removed })
                    if model.checkingVersions.isEmpty {
                        Button(L("检查论文新版本")) { model.checkPaperVersions(libraryPapers.map(\.id)) }
                            .disabled(!libraryPapers.contains { $0.reference != nil })
                    } else { Button(L("停止检查版本"), action: model.cancelVersionCheck) }
                    Divider()
                    libraryBatchActions
                    Divider()
                    Button(libraryFilter == .removed ? L("返回文档库") : L("已移除的文档")) {
                        toggleRemoved()
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32).accessibilityLabel(L("文档库操作"))
            } else if page == .media {
                if !model.mediaLibrary.isEmpty {
                    Text(selectedLibraryIDs.isEmpty ? L("\(visibleItems.count) 项") : L("已选 \(selectedLibraryIDs.count) 项"))
                        .font(.callout).monospacedDigit().foregroundStyle(secondary)
                    searchField
                }
                Menu {
                    libraryBatchActions
                    Divider()
                    Button(mediaRemoved ? L("返回媒体库") : L("已移除的媒体"), action: toggleRemoved)
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32)
                    .accessibilityLabel(L("媒体库操作"))
            } else if page == .logs && !model.logs.isEmpty {
                searchField
                Button { model.exportLogs(visibleLogs) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(RoundButtonStyle(palette: palette))
                    .disabled(visibleLogs.isEmpty).help(L("导出当前筛选的日志")).accessibilityLabel(L("导出日志"))
            }
        }.frame(height: WorkspaceMetrics.headerHeight)
    }

    @ViewBuilder private var libraryBatchActions: some View {
        if let collection = libraryCollection {
            Button(L("全选当前结果"), action: selectAllVisible).disabled(visibleItems.isEmpty)
            Button(L("取消选择")) { selection.clear() }.disabled(selection.ids.isEmpty)
            Divider()
            Button(L(showingRemoved ? "恢复所选 \(selectedLibraryIDs.count) 项" : "移出所选 \(selectedLibraryIDs.count) 项")) {
                Task { _ = await model.setLibraryRemoved(selectedLibraryIDs, in: collection, removed: !showingRemoved) }
            }.disabled(selectedLibraryIDs.isEmpty || !model.canManageLibrary(collection))
            Button(L(showingRemoved ? "恢复当前结果 \(visibleItems.count) 项" : "移出当前结果 \(visibleItems.count) 项…")) {
                let ids = Set(visibleItems.map(\.id))
                if showingRemoved { Task { _ = await model.setLibraryRemoved(ids, in: collection, removed: false) } }
                else { confirmingLibraryRemoval = LibraryRemovalUndo(collection: collection, ids: ids, removed: true) }
            }.disabled(visibleItems.isEmpty || !model.canManageLibrary(collection))
            Divider()
            Button(L("将所选文件移到废纸篓…"), role: .destructive) {
                model.requestFileTrash(selectedLibraryIDs, in: collection == .documents ? .documents : .media)
            }.disabled(!model.canTrashFiles(selectedLibraryIDs, in: collection == .documents ? .documents : .media))
        }
    }

    private var downloadActions: some View {
        Menu {
            Button(L("从文本文件导入链接…"), action: model.importLinks).disabled(model.busy)
            if model.hasMediaInput {
                Toggle(L("视频仅下载音频"), isOn: Binding(get: { model.mediaFormat == .audio }, set: { model.mediaFormat = $0 ? .audio : .automatic }))
                    .disabled(model.busy)
            }
            if model.downloads.contains(where: { $0.canRetry || $0.source == nil }) {
                Button(L("复制未完成链接"), action: model.copyUnfinished)
            }
            Divider()
            Button(L("查看日志")) { logItem = nil; page = .logs }
            Divider()
            Button(L("清空下载记录…"), role: .destructive) { confirmingClearDownloads = true }
                .disabled(!model.canClearDownloadRecords)
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle()) }
            .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32)
            .help(L("更多下载操作")).accessibilityLabel(L("下载操作"))
    }

    private var pasteButton: some View {
        Button(action: model.paste) { Image(systemName: "doc.on.clipboard").frame(width: 32, height: 32).contentShape(Rectangle()) }
            .buttonStyle(RoundButtonStyle(palette: palette))
            .help(L("追加剪贴板中的链接")).accessibilityLabel(L("粘贴链接")).disabled(model.busy)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WorkspaceMetrics.Space.compact) {
                Text(L("添加链接")).font(WorkspaceMetrics.TypeScale.title)
                Spacer()
                if model.hasMediaInput && model.mediaFormat == .audio {
                    Button { model.mediaFormat = .automatic } label: {
                        Label(L("仅音频"), systemImage: "waveform").font(.callout).foregroundStyle(secondary)
                    }.help(L("视频链接仅保存音频，点按恢复下载视频")).accessibilityLabel(L("仅音频模式，点按恢复视频")).disabled(model.busy)
                }
                pasteButton
                downloadActions
            }.buttonStyle(.plain)
                .padding(.leading, WorkspaceMetrics.Space.inset).padding(.trailing, WorkspaceMetrics.Space.page)
                .frame(height: WorkspaceMetrics.controlHeight)
                .padding(.top, WorkspaceMetrics.Space.regular)
            LinkInput(model: model, focused: $inputFocused, palette: palette)
                .frame(height: WorkspaceMetrics.inputHeight)
                .padding(.horizontal, WorkspaceMetrics.Space.compact).padding(.top, WorkspaceMetrics.Space.compact)
            HStack(spacing: WorkspaceMetrics.Space.regular) {
                DirectoryMenu(model: model, palette: palette)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                Spacer(minLength: WorkspaceMetrics.Space.compact)
                primaryAction
            }.padding(.horizontal, WorkspaceMetrics.Space.inset)
                .padding(.top, WorkspaceMetrics.Space.regular)
                .padding(.bottom, WorkspaceMetrics.Space.section)
        }
        .background(ThemePalette.color(palette.surface).contentShape(Rectangle()).onTapGesture {
            if model.busy { dismissEditing() } else { model.focusInput() }
        })
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.panel).stroke((inputFocused || dropTargeted) && !model.busy ? accent.opacity(0.65) : ThemePalette.color(palette.border).opacity(0.6), lineWidth: (inputFocused || dropTargeted) ? 1 : 1 / displayScale))
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $dropTargeted, perform: model.acceptDrop)
    }

    @ViewBuilder private var primaryAction: some View {
        if model.busy {
            Button(action: model.cancel) {
                if model.cancelling { ProgressView().controlSize(.small).tint(ThemePalette.color(palette.onAction)) }
                else { Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold)) }
            }.buttonStyle(PrimaryActionStyle(palette: palette))
                .keyboardShortcut(searchFocused ? nil : .cancelAction).disabled(model.cancelling)
                .help(model.cancelling ? L("正在取消") : L("取消下载（Esc）"))
                .accessibilityLabel(model.cancelling ? L("正在取消") : L("取消下载"))
        } else {
            Button(action: model.start) { Image(systemName: "arrow.down") }
                .buttonStyle(PrimaryActionStyle(palette: palette))
                .keyboardShortcut(KeyEquivalent(Character(model.shortcuts[.download].key)), modifiers: model.shortcuts[.download].swiftModifiers)
                .disabled(model.tokenCount == 0).help(L("开始下载（\(model.shortcuts[.download].label)）"))
                .accessibilityLabel(L("开始下载"))
        }
    }

    private var hasSearchContent: Bool {
        switch page {
        case .downloads: return !model.downloads.isEmpty
        case .library: return !model.papers.isEmpty
        case .media: return !model.mediaLibrary.isEmpty
        case .logs: return !model.logs.isEmpty
        }
    }

    private var searchLabel: String {
        switch page {
        case .downloads: return L("搜索下载")
        case .library: return L("搜索文档")
        case .media: return L("搜索媒体")
        case .logs: return L("搜索日志")
        }
    }

    @ViewBuilder private var searchField: some View {
        if searchExpanded || !query.isEmpty {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(secondary)
            TextField(searchLabel, text: $query).textFieldStyle(.plain).font(.system(size: 13))
                .accessibilityLabel(searchLabel).focused($searchFocused)
                .task(id: model.searchRequest) {
                    guard let request = searchFocusRequest else { return }
                    await Task.yield()
                    guard !Task.isCancelled, searchExpanded,
                          model.searchRequest == request.id, model.editRequest == request.edit,
                          model.listRequest == request.list, page == request.page else { return }
                    searchFocused = true
                }
                .onExitCommand {
                    if query.isEmpty { searchFocused = false; searchExpanded = false }
                    else { query = "" }
                }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(secondary).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(L("清除搜索"))
            }
        }.padding(.horizontal, 10)
            .frame(width: 178, height: 32)
            .background(ThemePalette.color(palette.surface)).clipShape(Capsule())
        } else {
            Button { model.searchRequest = UUID() } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(RoundButtonStyle(palette: palette)).foregroundStyle(secondary)
                .help("\(searchLabel)（⌘F）").accessibilityLabel(searchLabel)
        }
    }

    private var papers: some View {
        let listPage = page
        let rows = visibleItems
        return VStack(spacing: 14) {
            if page == .library || page == .media || (page == .downloads && !model.downloads.isEmpty) {
            HStack(spacing: 4) {
                if page == .downloads {
                    Menu {
                        Text(L("下载状态"))
                        ForEach(QueueFilter.allCases, id: \.self) { option in
                            Button { filter = option } label: {
                                if option == filter { Label(L(option.rawValue), systemImage: "checkmark") }
                                else { Text(L(option.rawValue)) }
                            }
                        }
                    } label: {
                        Text("\(L(filter.rawValue)) · \(L("\(rows.count) 项"))").font(WorkspaceMetrics.TypeScale.body).foregroundStyle(secondary)
                    }
                    .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette, menuTitle: L("下载状态")))
                    .menuIndicator(.hidden).fixedSize()
                    .help(L("筛选下载状态")).accessibilityLabel(L("下载状态：\(filter.rawValue)"))
                    Spacer(minLength: 0)
                    if filter == .failed && query.isEmpty && model.retryCount > 1 && !model.busy {
                        Button(L("批量重试")) { model.retry() }.buttonStyle(.borderless).font(.system(size: 12))
                            .padding(.trailing, 8)
                    }
                    searchField
                } else {
                    if showingRemoved {
                        Button(action: toggleRemoved) { Label(L("已移除"), systemImage: "chevron.left").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(secondary).help(page == .library ? L("返回文档库") : L("返回媒体库"))
                    }
                    else if page == .library { FilterTabs(options: [LibraryFilter.all, .favorites, .unread], selection: $libraryFilter, title: { L($0.rawValue) }, palette: palette) }
                    Spacer()
                    if page == .library, let tag = libraryTag {
                        Button { libraryTag = nil } label: {
                            HStack(spacing: 6) { Text(tag).lineLimit(1); Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        }.buttonStyle(QuietButtonStyle(palette: palette)).help(L("清除标签筛选"))
                            .accessibilityLabel(L("清除标签筛选：\(tag)"))
                    }
                    LibraryDisplayPicker(selection: displayBinding, palette: palette)
                }
            }.frame(height: 36)
            }
            if rows.isEmpty {
                empty(icon: query.isEmpty && filter == .all ? "tray" : "magnifyingglass", text: emptyMessage).transition(recordTransition)
                    .contentShape(Rectangle()).onTapGesture(perform: dismissEditing)
            } else {
                ScrollViewReader { scroll in
                    GeometryReader { viewport in
                    ScrollView {
                        Group {
                            if displayMode == .grid {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LibraryGridLayout.spacing), count: LibraryGridLayout.columns(width: viewport.size.width)), spacing: LibraryGridLayout.spacing) {
                                    libraryRows(rows)
                                }
                            } else {
                                LazyVStack(spacing: 0) { libraryRows(rows) }
                            }
                        }.padding(1).padding(.trailing, 16).padding(.horizontal, 24)
                            // Keep rows inset while the scroll canvas spans the
                            // content column, including its outer margins and gaps.
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                            .background(ThemePalette.color(palette.canvas).contentShape(Rectangle()).onTapGesture {
                                selection.clear(); listFocus = nil
                                dismissEditing()
                            })
                    }
                    .padding(.horizontal, -24)
                    .onChange(of: displayMode) { _ in
                        if let id = selectedID { scroll.scrollTo(id, anchor: .center) }
                    }
                    .background(PaperListKeyboard(request: listFocus, detailsShortcut: model.shortcuts[.details], allowsHorizontalNavigation: displayMode == .grid, allowsMultipleSelection: libraryCollection != nil, focusChanged: { if page == listPage { listFocused = $0 } }, didFocus: { request in
                        if listFocus == request { listFocus = nil }
                    }) { action in
                        guard workspaceActive, !rows.isEmpty else { return }
                        if action == .selectAll {
                            selection.selectAll(rows.map(\.id))
                        } else if let offset = LibraryGridLayout.offset(action, columns: displayMode == .grid ? LibraryGridLayout.columns(width: viewport.size.width) : 1) {
                            let visible = rows.map(\.id)
                            let index = selectedID.flatMap { visible.firstIndex(of: $0) }
                            let movement = displayMode == .grid && index != nil
                                ? LibraryGridLayout.destination(index: index!, count: rows.count, columns: LibraryGridLayout.columns(width: viewport.size.width), action: action) - index! : offset
                            if movement == 0 { return }
                            if let id = selection.move(movement, visible: visible, extend: action.extendsSelection) {
                                scroll.scrollTo(id)
                            }
                        } else if let item = rows.first(where: { $0.id == selectedID }) {
                            if page == .library, let paper = model.libraryQueries.papersByID[item.id] {
                                if action == .diagnostics { model.showPaperDetails(paper) }
                                else if !paper.removed { model.openPaper(paper, preview: action == .preview) }
                            }
                            else if page == .media && item.isLibraryRemoved {
                                if action == .diagnostics { model.diagnosticItem = item }
                            }
                            else if action == .preview { model.preview(item) }
                            else if action == .open { model.openFile(item) }
                            else if action == .diagnostics { model.diagnosticItem = item }
                        }
                    })
                    }
                }.id(page).transition(recordTransition).frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func libraryRows(_ rows: [DownloadItem]) -> some View {

        ForEach(rows) { item in
            if page == .library, let paper = model.libraryQueries.papersByID[item.id] {
                LibraryRow(paper: paper, model: model, selected: selection.ids.contains(item.id), selectionActive: listSelectionActive, grid: displayMode == .grid, select: { selectItem(item.id) })
                    .id(item.id).transition(recordTransition)
            } else {
            DownloadRow(item: item, model: model, inMediaLibrary: page == .media, grid: displayMode == .grid, selected: selection.ids.contains(item.id), selectionActive: listSelectionActive, authenticate: { model.settingsTab = "浏览器认证"; model.preferencesPage = .settings; showSettings() }, showLogs: { logItem = item; logLevel = nil; query = ""; page = .logs }, select: { selectItem(item.id) })
                .contentShape(Rectangle())
                .onTapGesture { selectItem(item.id) }
                .id(item.id).transition(recordTransition)
            }
        }

    }

    private var emptyMessage: String {
        if !query.isEmpty { return L("没有匹配的结果") }
        if page == .media { return mediaRemoved ? L("暂无已移除媒体") : L("暂无媒体") }
        if page == .library {
            if libraryTag != nil { return L("没有匹配的结果") }
            switch libraryFilter { case .all: return L("暂无文档"); case .favorites: return L("暂无收藏"); case .unread: return L("暂无未读文档"); case .removed: return L("暂无已移除文档") }
        }
        if !model.downloads.isEmpty { return L("暂无\(filter.rawValue)任务") }
        return L("粘贴链接，开始下载")
    }

    private func empty(icon: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(secondary)
            Text(text).font(WorkspaceMetrics.TypeScale.body).foregroundStyle(secondary)
            if page == .library && model.papers.isEmpty && query.isEmpty {
                Button(L("导入 PDF…"), action: importPDFs).buttonStyle(QuietButtonStyle(palette: palette))
                    .disabled(model.importingPDFs || !model.libraryWritable)
            } else if page == .media && model.mediaLibrary.isEmpty && query.isEmpty && !mediaRemoved {
                Text(L("下载的媒体会显示在这里。")).font(WorkspaceMetrics.TypeScale.supporting).foregroundStyle(secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importPDFs() {
        libraryFilter = .all; libraryTag = nil; query = ""
        model.importPDFs()
    }

    private var logContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let logItem {
                HStack(spacing: 8) {
                    Text(L("任务日志")).font(.caption.weight(.medium))
                    Text(logItem.title).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(secondary)
                    Spacer(minLength: 0)
                    Button(L("全部日志")) { self.logItem = nil }.controlSize(.small)
                        .accessibilityIdentifier("clear-task-log-filter")
                }
            }
            LogContent(entries: visibleLogs, hasLogs: !model.logs.isEmpty, query: query, level: $logLevel, palette: palette, dismissEditing: dismissEditing)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.directoryNotice ?? model.notice ?? model.libraryNotice ?? model.mediaLibraryNotice ?? model.persistenceNotice {
                Label(L(error), systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(UIColors.error)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let collection = libraryCollection, let undo = model.libraryUndo, undo.collection == collection {
                    Text(L(undo.removed ? "已移出 \(undo.ids.count) 项" : "已恢复 \(undo.ids.count) 项")).lineLimit(1)
                    Spacer()
                    Button(L(undo.removed ? "撤销移出" : "撤销恢复")) { Task { _ = await model.undoLibraryRemoval() } }
                        .buttonStyle(.plain).foregroundStyle(accent).disabled(!model.canManageLibrary(collection))
                } else if page == .downloads {
                    if model.busy { ProgressView().controlSize(.mini).frame(width: 12) }
                    else if !model.summary.isEmpty { Circle().fill(accent).frame(width: 5, height: 5) }
                    Text(L(model.summary)).lineLimit(1)
                    Spacer()

                } else if page == .logs {
                    Text(L("\(visibleLogs.count) 条")).monospacedDigit()
                    Spacer()
                } else if page == .media {
                    Spacer()
                } else {
                    if model.importingPDFs { Text(L("正在导入…")) }
                    else if !model.checkingVersions.isEmpty { Text(L("正在检查版本 · 剩余 \(model.checkingVersions.count) 篇")) }
                    Spacer()
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
    @ObservedObject private var localization = AppLocalization.shared
    static let messageInset: CGFloat = 64 + 12 + 16 + 12
    let entry: ActivityEntry
    let palette: ThemePalette
    var horizontalInset: CGFloat = 20
    private var color: Color {
        switch entry.level { case .error: return UIColors.error; case .success: return UIColors.success; case .warning: return UIColors.warning; default: return ThemePalette.color(palette.secondary) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.logTime(entry.date))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(ThemePalette.color(palette.secondary))
                .frame(width: 64, height: 16, alignment: .leading)
                .help(L10n.date(entry.date, dateStyle: .complete))
            Image(systemName: entry.level.symbol).font(.system(size: 12)).foregroundStyle(color).frame(width: 16, height: 16)
                .accessibilityLabel(L(entry.level.label))
            Text(entry.localizedMessage).font(.system(size: 12)).foregroundStyle(entry.level == .info ? ThemePalette.color(palette.text) : color)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading).textSelection(.enabled)
        }.padding(.vertical, 8).padding(.horizontal, horizontalInset)
            .contentShape(Rectangle()).help(entry.subject ?? entry.localizedMessage)
            .accessibilityElement(children: .ignore).accessibilityLabel(entry.line)
            .contextMenu {
                Button(L("复制日志")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.line, forType: .string) }
            }
    }
}

struct DownloadRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    let item: DownloadItem
    let model: DownloadModel
    let busy: Bool
    let theme: AppTheme
    let inMediaLibrary: Bool
    let grid: Bool
    let selected: Bool
    let selectionActive: Bool
    let authenticate: () -> Void
    let showLogs: () -> Void
    let select: () -> Void

    init(item: DownloadItem, model: DownloadModel, inMediaLibrary: Bool = false, grid: Bool = false, selected: Bool = false, selectionActive: Bool = true, authenticate: @escaping () -> Void = {}, showLogs: @escaping () -> Void = {}, select: @escaping () -> Void = {}) {
        self.authenticate = authenticate
        self.showLogs = showLogs
        self.grid = grid; self.item = item; self.model = model; self.inMediaLibrary = inMediaLibrary
        busy = model.busy; theme = model.theme; self.selected = selected; self.selectionActive = selectionActive; self.select = select
    }
    @StateObject private var clickTarget = FileRowClickTarget()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette { theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    private var hasAuthenticationIssue: Bool {
        guard case .media? = item.source else { return false }
        return BrowserAuthenticationIssue.matches(item.errorMessage)
    }

    var body: some View {
        Group {
            if grid {
                AssetGridCard(title: item.title, subtitle: item.state == .missing ? L("文件缺失") : item.directURL?.host ?? L("本地文件"),
                    file: item.state == .missing ? nil : item.savedURL, symbol: item.symbol,
                    badge: (item.additionalURLs?.isEmpty == false ? L("\(item.localURLs.count) 个文件") : item.savedURL?.pathExtension.uppercased() ?? ""),
                    palette: palette, revision: "\(model.fileRefreshRevision)|\(item.state)", preview: .media, subtitleIsError: item.state == .missing) { controls }
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
                let current = (inMediaLibrary ? model.mediaLibrary : model.downloads).first { $0.id == item.id }
                guard let current, !current.isLibraryRemoved, current.savedURL != nil else { return }
                model.openFile(current)
            })
            .onAppear { clickTarget.setActive(true) }
            .onDisappear { clickTarget.setActive(false) }
            .contextMenu { actions }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityElement(children: .contain)
            .accessibilityValue(L10n.text(item.state.message))
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if inMediaLibrary || item.savedURL != nil {
                    FileThumbnail(url: item.savedURL, fallbackSymbol: item.symbol, palette: palette, revision: "\(model.fileRefreshRevision)|\(item.finishedAt?.timeIntervalSinceReferenceDate ?? 0)|\(item.state)")
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 22, weight: .light)).foregroundStyle(secondary)
                        .frame(width: WorkspaceMetrics.rowIconSize, height: WorkspaceMetrics.rowIconSize)
                        .background(ThemePalette.color(palette.surface), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control))
                }
            }.accessibilityLabel(L10n.text(item.state.message))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(WorkspaceMetrics.TypeScale.rowTitle).lineSpacing(3)
                    .lineLimit(2).help(item.title)
                HStack(spacing: 10) {
                    if let metadata = item.metadata { Text(metadata.reference.identifier).font(.system(size: 11, design: .monospaced)) }
                    else if let host = item.directURL?.host, item.documentTitle != nil { Text(host).lineLimit(1) }
                    if item.state != .saved && item.state != .existing {
                    HStack(spacing: 4) {
                        Image(systemName: item.state.symbol).font(.system(size: 10)).accessibilityHidden(true)
                        Text(L10n.text(item.state.message))
                    }.foregroundStyle(item.state.color(palette)).lineLimit(1)
                    }
                    if let files = item.additionalURLs, !files.isEmpty { Text(L("\(files.count + 1) 个文件")) }
                }.font(.system(size: 11)).foregroundStyle(secondary)
                if item.state == .downloading {
                    DownloadTransferProgress(progress: item.progress, bytesPerSecond: item.bytesPerSecond, palette: palette)
                        .frame(maxWidth: 320, alignment: .leading)
                }
                if case .waiting = item.state, item.reference != nil {
                    Text(L("遵守 arXiv 请求间隔，稍后自动继续。"))
                        .font(.system(size: 11)).foregroundStyle(secondary)
                }
                if let error = item.localizedError {
                    Text(error).font(.system(size: 11)).lineSpacing(3)
                        .foregroundStyle(item.state == .paused || item.state == .cancelled ? secondary : UIColors.error)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                .contentShape(Rectangle())
            controls
        }
    }
    private var controls: some View {
            VStack(alignment: .trailing, spacing: WorkspaceMetrics.Space.small) {
                HStack(spacing: WorkspaceMetrics.Space.small) {
                    if inMediaLibrary && item.isLibraryRemoved {
                        Button(L("恢复")) { Task { _ = await model.setLibraryRemoved([item.id], in: .media, removed: false) } }
                            .buttonStyle(QuietButtonStyle(palette: palette)).disabled(!model.canManageLibrary(.media))
                    } else if let url = item.savedURL, !inMediaLibrary || item.state != .missing || item.localURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        Button(L("打开")) { model.openFile(item) }.buttonStyle(RowActionStyle(palette: palette)).help(url.path)
                    }
                    if item.canRetry && !item.isLibraryRemoved {
                        Button(L("重试"), action: retry)
                            .buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy)
                    } else if item.source == nil && !(inMediaLibrary && item.isLibraryRemoved) {
                        Button(L("修改")) { model.edit(item) }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy)
                    }
                    Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                        .menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette)).menuIndicator(.hidden).frame(width: 32)
                        .accessibilityLabel(L("\(item.title)的更多操作"))
                }
                if hasAuthenticationIssue && !(inMediaLibrary && item.isLibraryRemoved) {
                    Button(L("浏览器认证…"), action: authenticate)
                        .buttonStyle(RowActionStyle(palette: palette))
                        .accessibilityIdentifier("browser-authentication-action")
                }
            }.padding(.top, 1).background(FileRowClickRegion(target: clickTarget, controls: true))
    }
    @ViewBuilder private var actions: some View {
        if inMediaLibrary {
            if item.isLibraryRemoved {
                Button(L("恢复到媒体库")) { Task { _ = await model.setLibraryRemoved([item.id], in: .media, removed: false) } }
                    .disabled(!model.canManageLibrary(.media))
            } else {
                Button(L("快速预览")) { select(); model.preview(item) }.disabled(item.localURLs.isEmpty)
                Button(L("重命名…")) { select(); model.requestAssetRename(item.id, in: .media) }
                    .disabled(!model.canRenameAsset(item.id, in: .media))
                Button(L("在 Finder 中显示")) { model.openFile(item, reveal: true) }.disabled(item.localURLs.isEmpty)
                Divider()
                Button(L("详情…")) { select(); model.diagnosticItem = item }
                if item.canRetry { Button(L("重新下载缺失文件"), action: retry).disabled(busy) }
                Divider()
                Button(L("从媒体库移除")) { Task { _ = await model.setLibraryRemoved([item.id], in: .media, removed: true) } }
                    .help(L("保留文件，可从已移除的媒体中恢复")).disabled(!model.canManageLibrary(.media))
            }
            Button(L("移到废纸篓…"), role: .destructive) { model.requestFileTrash([item.id], in: .media) }
                .disabled(!model.canTrashFiles([item.id], in: .media))
        } else {
            downloadActions
        }
    }
    @ViewBuilder private var downloadActions: some View {
        if !item.localURLs.isEmpty {
            Button(L("快速预览")) { select(); model.preview(item) }.help(L("选中文件后按空格"))
            Button(L("在 Finder 中显示")) { model.openFile(item, reveal: true) }
            Divider()
        }
        Button(L("详情…")) { select(); model.diagnosticItem = item }.help(L("选中文件后按 \(model.shortcuts[.details].label)"))
        Button(L("查看任务日志"), action: showLogs)
        if hasAuthenticationIssue && model.browserAuthentication.selection != nil {
            Button(L("在认证浏览器中打开")) { model.openAuthenticationSource(item) }
                .help(L("多账号时，请确认打开的是所选配置。"))
        }
        if item.canRetry && item.savedURL != nil {
            Button(L("重新下载缺失文件"), action: retry).disabled(busy)
        }
        if let source = item.provenance {
            if source.browserURL != nil { Button(L("打开来源页面")) { model.openOriginalSource(item) } }
            Button(L("复制来源链接")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.input, forType: .string)
            }
        }
        if let url = item.savedURL {
            Button(L("复制文件名")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.lastPathComponent, forType: .string) }
        }
        Divider()
        Button(L("将文件移到废纸篓…"), role: .destructive) {
            model.requestFileTrash([item.id], in: .downloads)
        }.disabled(!model.canTrashFiles([item.id], in: .downloads))
        Divider()
        Button(L("清除这条记录"), role: .destructive) { model.clearDownloadRecord(item.id) }.disabled(busy)
    }

    private func retry() {
        if inMediaLibrary { model.retryFromLibrary(item) } else { model.retry(item.id) }
    }


}

struct DownloadTransferProgress: View {
    let progress: DownloadProgress?
    let bytesPerSecond: Double?
    let palette: ThemePalette
    var status: String {
        guard let progress, progress.received > 0 else { return L("连接下载…") }
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        var parts = [progress.fraction.map { "\(Int($0 * 100))% · \(received)" } ?? received]
        if let speed = bytesPerSecond, speed >= 1, speed.isFinite, speed < Double(Int64.max) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
        }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(ThemePalette.color(palette.accent))
                    .accessibilityLabel(L("下载进度"))
            }
            HStack(spacing: 6) {
                if progress?.fraction == nil { ProgressView().controlSize(.mini).accessibilityLabel(L("正在下载")) }
                Text(status).font(.system(size: 11)).monospacedDigit().foregroundStyle(ThemePalette.color(palette.secondary))
            }
        }.accessibilityElement(children: .combine).accessibilityValue(status)
    }
}

struct LogDaySeparator: View {
    @ObservedObject private var localization = AppLocalization.shared
    let date: Date
    let palette: ThemePalette
    var body: some View {
        HStack(spacing: 10) {
            line
            Text(L10n.date(date, time: .omitted)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(ThemePalette.color(palette.secondary))
            line
        }.frame(maxWidth: .infinity).padding(.vertical, 4)
    }
    private var line: some View {
        Rectangle().fill(ThemePalette.color(palette.border).opacity(0.65))
            .frame(width: 32, height: 1).accessibilityHidden(true)
    }
}

struct LogContent: View {
    @ObservedObject private var localization = AppLocalization.shared
    let entries: [ActivityEntry]
    let hasLogs: Bool
    let query: String
    @Binding var level: ActivityLevel?
    let palette: ThemePalette
    var dismissEditing: () -> Void = {}
    @WorkspaceViewState private var position = LogScrollPosition()
    @WorkspaceViewState private var followingLatest = true
    @WorkspaceViewState private var requestedBottom: Bool?
    @WorkspaceViewState private var scrollRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    // Keep the arrow pointing toward the active destination until arrival.
    // Repeated clicks during the jump must not reverse its direction.
    private var pointsUp: Bool { requestedBottom.map { !$0 } ?? position.atBottom }

    var body: some View {
        let headers = LogHeading.headings(entries)
        VStack(spacing: 16) {
            if hasLogs {
                HStack(spacing: 4) {
                    FilterTabs(options: [nil] + ActivityLevel.allCases.map(Optional.some), selection: $level, title: { L($0?.label ?? "全部") }, palette: palette)
                    Spacer()
                    if position.canScroll && !entries.isEmpty {
                        Button { jump(toBottom: !pointsUp) } label: {
                            Image(systemName: pointsUp ? "arrow.up.to.line" : "arrow.down.to.line")
                                .animation(nil, value: pointsUp)
                        }.buttonStyle(RoundButtonStyle(palette: palette))
                            .help(pointsUp ? L("回到最早日志") : L("前往最新日志"))
                            .accessibilityLabel(pointsUp ? L("回到最早日志") : L("前往最新日志"))
                    }
                }.frame(height: 36)
            }
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft").font(.system(size: 28, weight: .light))
                    Text(query.isEmpty && level == nil ? L("暂无日志") : L("没有匹配的日志")).font(.system(size: 13))
                }.foregroundStyle(secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle()).onTapGesture(perform: dismissEditing)
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 0) {
                                    if let group = headers[entry.id], group.subject != nil || group.date != nil {
                                        VStack(alignment: .leading, spacing: 8) {
                                            if let date = group.date {
                                                LogDaySeparator(date: date, palette: palette)
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
                        }.frame(minHeight: viewport.size.height, alignment: .top)
                            .background(ThemePalette.color(palette.canvas).contentShape(Rectangle()).onTapGesture(perform: dismissEditing))
                            .background(LogScrollObserver(followingLatest: followingLatest, request: scrollRequest,
                                                       destination: requestedBottom, animated: !reduceMotion, changed: { metrics in
                            position = metrics
                            if requestedBottom == true && metrics.atBottom || requestedBottom == false && metrics.atTop { requestedBottom = nil }
                        }, userScrolled: { metrics in
                            requestedBottom = nil
                            followingLatest = metrics.atBottom
                        }))
                    }
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
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    let palette: ThemePalette
    var body: some View {
        Menu {
            Text(model.directoryLabel)
            Text(L("按文件类型自动归档"))
            if !model.directoryExists { Text(L("首次下载时创建文件夹")) }
            Divider()
            Button(L("更改保存位置…"), action: model.chooseDirectory).disabled(model.busy)
            Button(L("在访达中打开"), action: model.openDirectory).disabled(!model.directoryExists)
        } label: {
            Label(model.directory.lastPathComponent.isEmpty ? "/" : model.directory.lastPathComponent, systemImage: "folder")
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(ThemePalette.color(palette.secondary))
        }.menuStyle(.button).buttonStyle(MenuTriggerStyle(palette: palette, menuTitle: model.directoryLabel)).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.leading, -12)
            .help(L("\(model.directoryLabel)\n按文件类型自动归档"))
            .accessibilityLabel(L("保存位置：\(model.directoryLabel)，自动按类型归档"))
    }
}

struct MenuTriggerStyle: ButtonStyle {
    let palette: ThemePalette
    var menuTitle: String?
    private var showsChevron: Bool { menuTitle != nil }
    @WorkspaceViewState private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            if let menuTitle {
                MenuChevron(menuTitle: menuTitle, color: ThemePalette.nativeColor(palette.secondary), animated: !reduceMotion)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
        }.padding(.horizontal, showsChevron ? 12 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(RoundedRectangle(cornerRadius: showsChevron ? 16 : 8, style: .continuous))
            .background(ThemePalette.color(palette.accent).opacity(enabled ? (configuration.isPressed ? 0.18 : hovered ? 0.09 : 0) : 0), in: RoundedRectangle(cornerRadius: showsChevron ? 16 : 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}
