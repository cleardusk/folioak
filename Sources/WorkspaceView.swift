import SwiftUI
import AppKit

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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    private var accent: Color { ThemePalette.color(palette.accent) }
    private var visibleItems: [DownloadItem] {
        let source = page == .library ? model.library : model.items
        return source.filter { item in
            (page == .library || filter.includes(item)) &&
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.original.localizedCaseInsensitiveContains(query))
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
        .onReceive(model.$editRequest.dropFirst()) { _ in page = .downloads; inputFocused = true }
        .onChange(of: page) { _ in query = "" }
        .onReceive(model.$batchID.dropFirst()) { _ in page = .downloads; filter = .all }
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
            if page != .downloads && !(page == .logs ? model.logs.isEmpty : model.history.isEmpty) {
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
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.tokenCount == 0).frame(width: 128).help("开始下载（⌘ Return）")
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 18)
        }
        .background(ThemePalette.color(palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(inputFocused && !model.busy ? accent.opacity(0.65) : ThemePalette.color(palette.border).opacity(0.6), lineWidth: 1))
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
                    Text("最近下载").font(.system(size: 13)).foregroundStyle(secondary)
                    Spacer()
                    Text("\(rows.count) 篇").font(.system(size: 12)).monospacedDigit().foregroundStyle(secondary)
                }
            }.frame(height: 36)
            }
            if rows.isEmpty {
                empty(icon: query.isEmpty && filter == .all ? "tray" : "magnifyingglass", text: emptyMessage)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { item in
                            DownloadRow(item: item, model: model, inLibrary: page == .library)
                        }
                    }.padding(.bottom, 2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "没有匹配的结果" }
        if page == .library { return "暂无论文" }
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
                                LogRow(entry: entry, palette: palette).id(entry.id)
                                if entry.id != entries.last?.id { Rectangle().fill(ThemePalette.color(palette.border).opacity(0.45)).frame(height: 1).padding(.horizontal, 20) }
                            }
                        }.background(ThemePalette.color(palette.surface)).clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .task(id: LogScrollTarget(lastID: entries.last?.id, count: entries.count, following: followLogs)) {
                        // Let the lazy rows register their scroll targets on first entry.
                        await Task.yield()
                        if !Task.isCancelled, followLogs, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.directoryNotice ?? model.notice ?? model.persistenceNotice {
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
                } else { Spacer() }
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

struct LogRow: View {
    let entry: ActivityEntry
    let palette: ThemePalette
    private var color: Color {
        switch entry.level { case .error: return UIColors.error; case .success: return UIColors.success; case .warning: return ThemePalette.color(palette.accent); default: return ThemePalette.color(palette.secondary) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: entry.level.symbol).font(.system(size: 14)).foregroundStyle(color).frame(width: 18, height: 18)
                .accessibilityLabel(entry.level.label)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.message).font(.system(size: 13)).foregroundStyle(entry.level == .error ? color : ThemePalette.color(palette.text))
                    .fixedSize(horizontal: false, vertical: true)
                if let subject = entry.subject { Text(subject).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).lineLimit(1).help(subject) }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ThemePalette.color(palette.secondary)).padding(.top, 2)
                .help(entry.date.formatted(date: .complete, time: .standard))
        }.padding(.vertical, 16).padding(.horizontal, 20)
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

    init(item: DownloadItem, model: DownloadModel, inLibrary: Bool = false) {
        self.item = item; self.model = model; self.inLibrary = inLibrary
        busy = model.busy; theme = model.theme
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
                    .lineLimit(2).textSelection(.enabled).help(item.title)
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
                if item.source != nil || item.savedURL != nil {
                Menu {
                    if item.savedURL != nil {
                        Button("在 Finder 中显示") { model.openFile(item, reveal: true) }
                        Button("文件信息…") { model.fileInfo(item) }
                        Divider()
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
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                    .accessibilityLabel("\(item.title)的更多操作")
                }
            }.padding(.top, 5)
        }.padding(20).background(ThemePalette.color(palette.surface))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ThemePalette.color(palette.border).opacity(0.4), lineWidth: 1))
            .accessibilityElement(children: .contain)
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
