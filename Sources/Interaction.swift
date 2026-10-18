import AppKit
import SwiftUI

// Observe double clicks without delaying single-click selection. The native
// recognizer shares the hosting view with SwiftUI and excludes actual action
// bounds, so buttons and menus keep their own event handling.
@MainActor final class FileRowClickTarget: ObservableObject {
    weak var controls: NSView?
    weak var row: FileRowClickRegion.Region?
    private(set) var active = false
    func setActive(_ value: Bool) { active = value; row?.configure() }
}

struct FileRowClickRegion: NSViewRepresentable {
    let target: FileRowClickTarget
    var controls = false
    var open: () -> Void = {}
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        view.target = target; view.open = open
        view.isControls = controls
        if controls { target.controls = view }
        else { target.row = view }
        view.configure()
    }
    final class Region: NSView, NSGestureRecognizerDelegate {
        weak var target: FileRowClickTarget?
        var open: () -> Void = {}
        var isControls = false
        private var click: NSClickGestureRecognizer?
        #if TESTING
        var clickTrace: ((String) -> Void)?
        #endif
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            if isControls || window == nil || target?.active != true {
                if let click { click.view?.removeGestureRecognizer(click); self.click = nil }
                return
            }
            guard let host = window?.contentView else { return }
            if click?.view === host { return }
            if let click { click.view?.removeGestureRecognizer(click) }
            #if TESTING
            let recognizer = TracedClickRecognizer(target: self, action: #selector(openFile))
            recognizer.trace = { [weak self] in self?.clickTrace?($0) }
            #else
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(openFile))
            #endif
            recognizer.numberOfClicksRequired = 2
            recognizer.delaysPrimaryMouseButtonEvents = false
            recognizer.delegate = self
            host.addGestureRecognizer(recognizer); click = recognizer
        }
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            #if TESTING
            let point = convert(event.locationInWindow, from: nil)
            clickTrace?("attempt type=\(event.type.rawValue) clicks=\(event.clickCount) time=\(event.timestamp) point=\(point) allowed=\(allowsClick(at: point)) window=\(event.windowNumber == window?.windowNumber)")
            #endif
            guard event.windowNumber == window?.windowNumber,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
            return allowsClick(at: convert(event.locationInWindow, from: nil))
        }
        private func allowsClick(at point: NSPoint) -> Bool {
            // The recognizer is on the hosting root. Cached offscreen rows must
            // not respond to clicks in the header or outside the scroll clip.
            guard target?.active == true, !isHiddenOrHasHiddenAncestor,
                  bounds.intersection(visibleRect).contains(point) else { return false }
            if let controls = target?.controls, controls.window === window,
               controls.bounds.intersection(controls.visibleRect).contains(controls.convert(point, from: self)) { return false }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            let point = gestureRecognizer.location(in: self)
            #if TESTING
            clickTrace?("begin point=\(point) allowed=\(allowsClick(at: point))")
            #endif
            return allowsClick(at: point)
        }
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
        #if TESTING
        // Observe AppKit's real state machine without changing its transitions.
        private final class TracedClickRecognizer: NSClickGestureRecognizer {
            var trace: ((String) -> Void)?
            private func record(_ phase: String, event: NSEvent? = nil) {
                trace?("recognizer=\(ObjectIdentifier(self)) \(phase) state=\(state.rawValue) event=\(event.map { "\($0.type.rawValue):\($0.clickCount):\($0.timestamp)" } ?? "none")")
            }
            override func mouseDown(with event: NSEvent) {
                record("before down", event: event); super.mouseDown(with: event); record("after down", event: event)
            }
            override func mouseUp(with event: NSEvent) {
                record("before up", event: event); super.mouseUp(with: event); record("after up", event: event)
            }
            override func reset() {
                record("before reset"); super.reset(); record("after reset")
            }
        }
        #endif
        @objc private func openFile() {
            #if TESTING
            clickTrace?("opened")
            #endif
            open()
        }
    }
}

// Core Animation keeps running while NSMenu owns the event-tracking run loop.
struct MenuChevron: NSViewRepresentable {
    let menuTitle: String
    let color: NSColor
    let animated: Bool
    func makeNSView(context: Context) -> ChevronView { ChevronView() }
    func updateNSView(_ view: ChevronView, context: Context) {
        view.configure(menuTitle: menuTitle, color: color, animated: animated)
    }
    final class ChevronView: NSView {
        let mark = CAShapeLayer()
        private var expanded: Bool?
        private var menuTitle = ""
        private var color = NSColor.secondaryLabelColor
        private var animated = true
        private weak var trackedMenu: NSMenu?
        private var observers: [NSObjectProtocol] = []
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            mark.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
            mark.path = Self.path(expanded: false); mark.fillColor = nil; mark.lineWidth = 1.4
            mark.lineCap = .round; mark.lineJoin = .round
            layer?.addSublayer(mark)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            trackedMenu = nil
            guard window != nil else { update(expanded: false, color: color, animated: false); return }
            // SwiftUI defers representable updates during tracking. The directory's
            // existing full-path heading identifies this menu without replacing it.
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] event in
                guard let self, let menu = event.object as? NSMenu,
                      menu.items.first?.title == self.menuTitle else { return }
                self.trackedMenu = menu
                self.update(expanded: true, color: self.color, animated: self.animated)
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] event in
                guard let self, let menu = event.object as? NSMenu, menu === self.trackedMenu else { return }
                self.trackedMenu = nil
                self.update(expanded: false, color: self.color, animated: self.animated)
            })
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        func configure(menuTitle: String, color: NSColor, animated: Bool) {
            self.menuTitle = menuTitle; self.color = color; self.animated = animated
            update(expanded: trackedMenu != nil, color: color, animated: animated)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
            mark.contentsScale = window?.backingScaleFactor ?? 2
            CATransaction.commit()
        }
        private static func path(expanded: Bool) -> CGPath {
            let path = CGMutablePath()
            let wing: CGFloat = expanded ? 3.5 : 6.5
            let tip: CGFloat = expanded ? 6.5 : 3.5
            path.move(to: CGPoint(x: 1.5, y: wing))
            path.addLine(to: CGPoint(x: 5, y: tip))
            path.addLine(to: CGPoint(x: 8.5, y: wing))
            return path
        }
        func update(expanded: Bool, color: NSColor, animated: Bool) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mark.strokeColor = color.cgColor
            CATransaction.commit()
            guard self.expanded != expanded || !animated else { return }
            let previous = self.expanded
            let start = mark.presentation()?.path ?? mark.path
            let target = Self.path(expanded: expanded)
            self.expanded = expanded
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mark.path = target
            if animated, previous != nil, window != nil {
                let fold = CABasicAnimation(keyPath: "path")
                fold.fromValue = start; fold.toValue = target
                fold.duration = 0.12
                fold.timingFunction = CAMediaTimingFunction(name: .easeOut)
                mark.add(fold, forKey: "fold")
            } else { mark.removeAnimation(forKey: "fold") }
            CATransaction.commit()
        }
    }
}

struct FileListSelection {
    var primary: UUID?
    var ids: Set<UUID> = []
    var anchor: UUID?

    mutating func clear() { primary = nil; ids = []; anchor = nil }

    mutating func retainVisible(_ visible: [UUID]) {
        ids.formIntersection(visible)
        if let primary, !visible.contains(primary) { self.primary = visible.first { ids.contains($0) } }
        if let anchor, !visible.contains(anchor) { self.anchor = primary }
    }

    mutating func select(_ id: UUID, visible: [UUID], modifiers: NSEvent.ModifierFlags = [], multiple: Bool = true) {
        guard visible.contains(id) else { return }
        if multiple && modifiers.contains(.shift), let anchor = anchor ?? primary,
           let start = visible.firstIndex(of: anchor), let end = visible.firstIndex(of: id) {
            let range = Set(visible[min(start, end)...max(start, end)])
            ids = modifiers.contains(.command) ? ids.union(range) : range
            self.anchor = anchor
        } else if multiple && modifiers.contains(.command) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]; anchor = id
        }
        primary = ids.contains(id) ? id : visible.first { ids.contains($0) }
    }

    mutating func selectAll(_ visible: [UUID]) {
        ids = Set(visible)
        if primary == nil || !ids.contains(primary!) { primary = visible.first }
        anchor = primary
    }

    mutating func move(_ offset: Int, visible: [UUID], extend: Bool) -> UUID? {
        guard !visible.isEmpty else { return nil }
        let index = primary.flatMap { visible.firstIndex(of: $0) }
        let next = index.map { min(visible.count - 1, max(0, $0 + offset)) } ?? 0
        select(visible[next], visible: visible, modifiers: extend ? .shift : [])
        return primary
    }
}

struct PaperListKeyboard: NSViewRepresentable {
    @ObservedObject private var localization = AppLocalization.shared
    enum Action {
        case up, down, left, right, extendUp, extendDown, extendLeft, extendRight, selectAll, preview, open, diagnostics
        var extendsSelection: Bool { [.extendUp, .extendDown, .extendLeft, .extendRight].contains(self) }
    }
    let request: UUID?
    var detailsShortcut = AppShortcut(key: "i")
    var allowsHorizontalNavigation = false
    var allowsMultipleSelection = false
    var focusChanged: (Bool) -> Void = { _ in }
    let didFocus: (UUID) -> Void
    let action: (Action) -> Void
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(request: request, didFocus: didFocus, action: action)
        view.focusChanged = focusChanged
        view.allowsHorizontalNavigation = allowsHorizontalNavigation
        view.allowsMultipleSelection = allowsMultipleSelection
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) {
        view.setAccessibilityLabel(L(allowsMultipleSelection ?
            "文件列表，方向键选择，Shift 方向键连续选择，Command A 全选，空格预览，Return 打开，Command I 查看详情" :
            "文件列表，方向键选择，空格预览，Return 打开，Command I 查看详情"))
        view.action = action
        view.detailsShortcut = detailsShortcut
        view.allowsHorizontalNavigation = allowsHorizontalNavigation
        view.allowsMultipleSelection = allowsMultipleSelection
        view.didFocus = didFocus
        view.focusChanged = focusChanged
        guard view.request != request else { return }
        view.request = request
        view.focusIfRequested()
    }
    final class KeyView: NSView {
        var request: UUID?
        var detailsShortcut = AppShortcut(key: "i")
        var allowsHorizontalNavigation = false
    var allowsMultipleSelection = false
        private var fulfilledRequest: UUID?
        var didFocus: (UUID) -> Void
        var action: (Action) -> Void
        var focusChanged: (Bool) -> Void = { _ in }
        private var focusRevision = 0
        private var windowObservers: [NSObjectProtocol] = []
        init(request: UUID?, didFocus: @escaping (UUID) -> Void, action: @escaping (Action) -> Void) {
            self.request = request; self.didFocus = didFocus; self.action = action
            super.init(frame: .zero)
            setAccessibilityLabel(L("文件列表，方向键选择，空格预览，Return 打开，Command I 查看详情"))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in self?.publishFocus() })
                }
            }
            publishFocus(); focusIfRequested()
        }
        private func publishFocus() {
            focusRevision += 1
            let revision = focusRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRevision == revision else { return }
                self.focusChanged(self.window?.isKeyWindow == true && self.window?.firstResponder === self)
            }
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { publishFocus() }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { publishFocus() }
            return accepted
        }
        func focusIfRequested() {
            guard let request, request != fulfilledRequest else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == request, self.fulfilledRequest != request,
                      let window = self.window, window.makeFirstResponder(self) else { return }
                self.fulfilledRequest = request
                self.didFocus(request)
            }
        }
        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if detailsShortcut.matches(event) { action(.diagnostics); return }
            if allowsMultipleSelection {
                if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "a" {
                    action(.selectAll); return
                }
                if allowsHorizontalNavigation && modifiers == .shift && (event.keyCode == 123 || event.keyCode == 124) {
                    action(event.keyCode == 123 ? .extendLeft : .extendRight); return
                }
                if modifiers == .shift && (event.keyCode == 126 || event.keyCode == 125) {
                    action(event.keyCode == 126 ? .extendUp : .extendDown); return
                }
            }
            guard modifiers.isEmpty else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 123 where allowsHorizontalNavigation: action(.left)
            case 124 where allowsHorizontalNavigation: action(.right)
            case 126: action(.up)
            case 125: action(.down)
            case 49: action(.preview)
            case 36, 76: action(.open)
            default: super.keyDown(with: event)
            }
        }
    }
}

// Keep the native disclosure semantics, but make the entire heading a button.
struct RecordDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isExpanded)
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(L(configuration.isExpanded ? "已展开" : "已折叠"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct TaskDiagnosticView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    let item: DownloadItem
    var libraryPaperID: UUID? = nil
    var fromMediaLibrary = false
    var showTaskLogs: ((DownloadItem) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @WorkspaceViewState private var files: [FileInformation] = []
    @WorkspaceViewState private var loading = false
    @WorkspaceViewState var showingDiagnostics = false
    @WorkspaceViewState private var copiedSource = false
    @WorkspaceViewState private var sourceActionError: String?
    @WorkspaceViewState private var editingMetadata = false
    @WorkspaceViewState private var titleDraft = ""
    @WorkspaceViewState private var tagsDraft = ""
    @WorkspaceViewState private var copiedFilename: URL?
    @WorkspaceViewState private var attemptedMaintenance = false
    private var paper: LibraryPaper? { libraryPaperID.flatMap { id in model.papers.first { $0.id == id } } }
    var current: DownloadItem {
        if let paper {
            var record = paper.downloadItem
            record.savedURL = paper.file // Keep missing paths visible, too.
            return record
        }
        if fromMediaLibrary { return model.mediaLibrary.first { $0.id == item.id } ?? item }
        return model.items.first { $0.id == item.id } ?? model.history.first { $0.id == item.id } ?? item
    }
    var diagnosticTask: DownloadItem? {
        let id = libraryPaperID == nil ? item.id : paper?.taskID
        guard let id else { return nil }
        return model.items.first { $0.id == id } ?? model.history.first { $0.id == id } ?? (libraryPaperID == nil ? current : nil)
    }
    func retry() {
        let id = diagnosticTask?.id
        if let task = (model.items + model.history).first(where: { $0.id == id && $0.canRetry }) { model.retry(task.id) }
        else { model.retryFromLibrary(current); dismiss() }
    }
    private var entries: [ActivityEntry] { model.logs.filter { $0.itemID == (paper?.taskID ?? item.id) } }
    private var hasDiagnostics: Bool { diagnosticTask?.diagnostics != nil || diagnosticTask?.localizedError != nil || !entries.isEmpty }
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L("详情")).font(.system(size: 18, weight: .medium))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundButtonStyle(palette: palette)).keyboardShortcut(.cancelAction).accessibilityLabel(L("关闭详情"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(current.title).font(.system(size: 16, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Label(L10n.text(current.state.message), systemImage: current.state.symbol)
                            .font(.system(size: 12)).foregroundStyle(current.state.color(palette))
                    }
                    Divider()
                    sourceContent
                    Divider()
                    recordContent
                    if let paper, paper.reference != nil, !paper.removed { paperVersionContent(paper) }
                    ForEach(Array(files.enumerated()), id: \.offset) { index, information in
                        Divider()
                        if files.count > 1 {
                            Text(information.url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        ForEach(Array(information.groups.enumerated()), id: \.offset) { _, group in
                            informationGroup(group.title, fields: group.fields)
                        }
                        Button(L(copiedFilename == information.url ? "已复制" : "复制文件名")) {
                            let board = NSPasteboard.general
                            board.clearContents()
                            if board.setString(information.url.lastPathComponent, forType: .string) { copiedFilename = information.url }
                        }.buttonStyle(QuietButtonStyle(palette: palette))
                        if let issue = information.issue {
                            Text(L(issue)).font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary))
                        }
                    }
                    if let paper, !paper.removed {
                        Button(L("重新关联文件…")) { attemptedMaintenance = true; model.notice = nil; model.relinkPaper(paper.id) }
                            .buttonStyle(QuietButtonStyle(palette: palette)).disabled(!model.canManageLibrary(.documents))
                    }
                    if attemptedMaintenance, let notice = model.notice {
                        Text(L(notice)).font(.system(size: 12)).foregroundStyle(UIColors.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在读取文件信息…")).font(.system(size: 12)) }
                            .foregroundStyle(ThemePalette.color(palette.secondary))
                    }
                    if hasDiagnostics || taskLogItem != nil {
                        if current.localURLs.isEmpty { diagnosticContent }
                        else {
                            Divider()
                            DisclosureGroup(L("下载记录"), isExpanded: $showingDiagnostics) { diagnosticContent.padding(.top, 12) }
                                .font(.system(size: 12)).disclosureGroupStyle(RecordDisclosureStyle())
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasDiagnostics || (current.canRetry && !model.busy) {
                HStack {
                    if hasDiagnostics {
                        Button(L("复制诊断")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }.buttonStyle(QuietButtonStyle(palette: palette))
                    }
                    Spacer()
                    if current.canRetry && !model.busy {
                        Button(L("重试"), action: retry).buttonStyle(QuietButtonStyle(palette: palette))
                    }
                }
            }
        }.padding(24).frame(width: 560, height: 620)
            .foregroundStyle(ThemePalette.color(palette.text))
            .background(ThemePalette.color(palette.canvas))
            .task(id: current.localURLs.map(\.absoluteString).joined(separator: "\n") + current.title + (paper?.authors ?? "") + L10n.locale.identifier) {
                files = []; loading = !current.localURLs.isEmpty
                let record = current, author = paper?.authors ?? current.metadata?.authors?.joined(separator: ", ")
                do {
                    for url in record.localURLs {
                        let information = try await FileInformation.read(url, title: record.title, author: author)
                        try Task.checkCancellation()
                        files.append(information)
                    }
                    loading = false
                } catch { /* Dismissal or a new file selection cancels the old read. */ }
            }
    }
    @discardableResult func copyOriginalLink(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let source = current.provenance else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(source.input, forType: .string)
    }
    var originalIsLink: Bool { current.provenance?.input.contains("://") == true }
    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(originalIsLink ? "原始下载链接" : "原始输入")).font(.system(size: 12, weight: .medium))
            if let source = current.provenance {
                Text(source.input).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if source.capturedAt == nil {
                    Text(L("来自历史记录，无法确认是否为首次输入。"))
                        .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                }
                HStack(spacing: 12) {
                    Button(L(copiedSource ? "已复制" : (originalIsLink ? "复制链接" : "复制内容"))) {
                        copiedSource = copyOriginalLink()
                        sourceActionError = copiedSource ? nil : "未能复制链接，请重试。"
                    }.buttonStyle(QuietButtonStyle(palette: palette))
                    if source.browserURL != nil {
                        Button(L("打开来源页面")) {
                            sourceActionError = model.openOriginalSource(current) ? nil : "无法打开来源页面，请检查默认浏览器。"
                        }.buttonStyle(QuietButtonStyle(palette: palette))
                    }
                }
                if let sourceActionError {
                    Text(L(sourceActionError)).font(.system(size: 12)).foregroundStyle(UIColors.error)
                }
            } else {
                Text(L(current.source == nil && !current.localURLs.isEmpty ? "本地导入，未记录下载来源。" : "未记录下载来源。"))
                    .font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary))
            }
        }
    }
    var recordFields: [FileInformation.Field] {
        var fields = [FileInformation.Field(name: "添加时间", value: L10n.date(paper?.addedAt ?? current.createdAt))]
        if let captured = current.provenance?.capturedAt {
            fields.append(.init(name: "首次记录", value: L10n.date(captured)))
        }
        if let completed = diagnosticTask?.finishedAt {
            fields.append(.init(name: "结束时间", value: L10n.date(completed)))
        }
        if let reference = current.metadata?.reference ?? current.reference {
            fields.append(.init(name: "arXiv", value: reference.identifier))
        }
        if let paper {
            fields.append(.init(name: "阅读状态", value: L(paper.read ? "已读" : "未读")))
            if !paper.tags.isEmpty { fields.append(.init(name: "标签", value: paper.tags.joined(separator: " · "))) }
        }
        return fields
    }
    private func informationGroup(_ title: String, fields: [FileInformation.Field]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(title)).font(.system(size: 12, weight: .medium))
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .top, spacing: 12) {
                    Text(L(field.name)).foregroundStyle(ThemePalette.color(palette.secondary))
                        .frame(width: L10n.language.code() == "en" ? 104 : 72, alignment: .leading)
                    Text(field.name == "尺寸" ? L(field.value) : field.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.font(.system(size: 12))
            }
        }
    }
    var taskLogItem: DownloadItem? {
        guard showTaskLogs != nil else { return nil }
        var record = current
        if libraryPaperID != nil {
            guard let taskID = paper?.taskID else { return nil }
            record.id = taskID
        }
        return record
    }
    private var recordContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editingMetadata, let paper {
                Text(L("编辑文档信息")).font(.system(size: 12, weight: .medium))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("显示标题")).foregroundStyle(ThemePalette.color(palette.secondary))
                    TextField(L("显示标题"), text: $titleDraft).textFieldStyle(.roundedBorder)
                    Text(L("显示标题不会修改文件名。")).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("标签")).foregroundStyle(ThemePalette.color(palette.secondary))
                    TextField(L("用逗号分隔"), text: $tagsDraft).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button(L("取消")) { editingMetadata = false }.buttonStyle(QuietButtonStyle(palette: palette))
                    Button(L("保存")) {
                        model.changePaper(paper.id) {
                            $0.title = String(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ResourceLimits.titleCharacters))
                            $0.tags = LibraryPaper.cleanTags(tagsDraft)
                        }
                        model.saveWorkspace(); editingMetadata = false
                    }.buttonStyle(QuietButtonStyle(palette: palette))
                        .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canManageLibrary(.documents))
                }
            } else {
                informationGroup("记录信息", fields: recordFields)
                if let paper, !paper.removed {
                    Button(L("编辑文档信息…")) {
                        titleDraft = paper.title; tagsDraft = paper.tags.joined(separator: ", "); editingMetadata = true
                    }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(!model.canManageLibrary(.documents))
                }
            }
        }.font(.system(size: 12))
    }
    private func paperVersionContent(_ paper: LibraryPaper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L(model.checkingVersions.contains(paper.id) ? "正在检查…" : "检查论文更新")) { attemptedMaintenance = true; model.checkPaperVersions([paper.id]) }
                    .buttonStyle(QuietButtonStyle(palette: palette))
                    .disabled(!model.checkingVersions.isEmpty || !model.canManageLibrary(.documents))
                if paper.hasUpdate {
                    Button(L("下载 v\(paper.latest!.version!)")) { model.downloadLatest(paper); dismiss() }
                        .buttonStyle(QuietButtonStyle(palette: palette)).disabled(model.busy)
                }
            }
            if let date = paper.checkedAt {
                Text(L("上次检查：\(L10n.date(date, time: .shortened))"))
                    .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
            }
        }
    }
    private var diagnosticContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let trace = diagnosticTask?.diagnostics, trace.finishedAt != nil {
                timings(trace, now: trace.finishedAt!)
            } else if let trace = diagnosticTask?.diagnostics {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timings(trace, now: trace.finishedAt ?? context.date)
                }.transaction { $0.animation = nil }
            }
            if let error = diagnosticTask?.localizedError {
                Text(ActivityEntry.redacted(error)).font(.system(size: 12)).foregroundStyle(UIColors.error).textSelection(.enabled)
            }
            HStack {
                if let task = taskLogItem {
                    Button(L("查看任务日志")) { showTaskLogs?(task); dismiss() }.buttonStyle(QuietButtonStyle(palette: palette))
                }
                if BrowserAuthenticationIssue.matches(current.errorMessage) && model.browserAuthentication.selection != nil {
                    Button(L("在认证浏览器中打开")) { model.openAuthenticationSource(current) }
                        .buttonStyle(QuietButtonStyle(palette: palette))
                }
            }
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.suffix(80)) { LogRow(entry: $0, palette: palette, horizontalInset: 0) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
    }
    private func timings(_ trace: TaskDiagnostics, now: Date) -> some View {
        VStack(spacing: 9) {
            HStack {
                Text(L("本次耗时"))
                Spacer()
                Text(L(TaskDiagnostics.time(trace.elapsed(now: now)))).monospacedDigit()
                if trace.retries > 0 { Text(L("· 重试 \(trace.retries) 次")) }
            }.foregroundStyle(ThemePalette.color(palette.text))
            ForEach(TaskDiagnostics.Phase.allCases, id: \.self) { phase in
                if trace.duration(phase, now: now) >= 0.05 || trace.phase == phase {
                    HStack {
                        Text(L(phase.label))
                        Spacer()
                        Text(L(TaskDiagnostics.time(trace.duration(phase, now: now)))).monospacedDigit()
                    }
                }
            }
        }.font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary))
    }
    var report: String {
        var lines = [current.title, L10n.text(current.state.message)]
        if let source = current.source { lines.append(ActivityEntry.redacted(source.webURL.absoluteString)) }
        if let trace = diagnosticTask?.diagnostics {
            lines.append(L("本次耗时 \(TaskDiagnostics.time(trace.elapsed())) · 重试 \(trace.retries) 次"))
            for phase in TaskDiagnostics.Phase.allCases where trace.duration(phase) > 0 {
                lines.append("\(L(phase.label)) \(L(TaskDiagnostics.time(trace.duration(phase))))")
            }
        }
        if let error = diagnosticTask?.localizedError { lines.append(ActivityEntry.redacted(error)) }
        lines.append(contentsOf: entries.map(\.line))
        return lines.map(ActivityEntry.redacted).joined(separator: "\n")
    }
}

struct LogScrollPosition: Equatable {
    var atTop = true
    var atBottom = false
    var canScroll = false
    init() {}
    init(scroll: NSScrollView) {
        let visible = scroll.contentView.bounds
        let content = scroll.documentView?.bounds ?? .zero
        canScroll = content.height > visible.height + 2
        atTop = visible.minY <= content.minY + 2
        atBottom = visible.maxY >= content.maxY - 2
    }
}

// A single native owner avoids LazyVStack's estimated scrollTo anchors on macOS 15.
// Programmatic animation must not be mistaken for the user leaving the tail.
struct LogScrollObserver: NSViewRepresentable {
    let followingLatest: Bool
    let request: Int
    let destination: Bool?
    let animated: Bool
    let changed: (LogScrollPosition) -> Void
    let userScrolled: (LogScrollPosition) -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.changed = changed; view.userScrolled = userScrolled
        view.followingLatest = followingLatest
        view.connect()
        if view.request != request {
            view.request = request
            view.jump(toBottom: destination ?? true, animated: animated && destination != nil)
        } else if !animated {
            view.finishTransition(toBottom: destination ?? followingLatest)
        }
    }
    final class Observer: NSView {
        var changed: ((LogScrollPosition) -> Void)?
        var userScrolled: ((LogScrollPosition) -> Void)?
        weak var scroll: NSScrollView?
        var followingLatest = true
        var request: Int?
        private var observing: [NSObjectProtocol] = []
        private var queued = false
        private var transition: ScrollTransition?
        private var generation = 0
        private final class ScrollTransition: NSAnimation {
            var apply: ((CGFloat) -> Void)?
            override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common, .eventTracking] }
            override var currentProgress: NSAnimation.Progress {
                didSet { apply?(CGFloat(currentValue)) }
            }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        func connect() {
            guard let enclosingScrollView, scroll !== enclosingScrollView else { return }
            observing.forEach(NotificationCenter.default.removeObserver); observing = []
            scroll = enclosingScrollView
            let clip = enclosingScrollView.contentView
            clip.postsBoundsChangedNotifications = true
            enclosingScrollView.documentView?.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, clip as NSView), (NSView.frameDidChangeNotification, enclosingScrollView.documentView ?? clip)] {
                observing.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.report() })
            }
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observing.append(NotificationCenter.default.addObserver(forName: name, object: enclosingScrollView, queue: .main) { [weak self] _ in
                    guard let self, let scroll = self.scroll else { return }
                    self.stopTransition()
                    let metrics = LogScrollPosition(scroll: scroll)
                    self.followingLatest = metrics.atBottom
                    self.userScrolled?(metrics); self.report()
                })
            }
            report()
        }
        private func endpoint(_ toBottom: Bool, in scroll: NSScrollView) -> CGFloat {
            let bounds = scroll.documentView?.bounds ?? .zero
            return toBottom ? max(bounds.minY, bounds.maxY - scroll.contentView.bounds.height) : bounds.minY
        }
        private func move(to y: CGFloat, in scroll: NSScrollView) {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        private func stopTransition() {
            generation += 1
            transition?.stop(); transition = nil
        }
        func finishTransition(toBottom: Bool) {
            guard transition != nil else { return }
            jump(toBottom: toBottom, animated: false)
        }
        func jump(toBottom: Bool, animated: Bool) {
            stopTransition()
            followingLatest = toBottom
            guard let scroll else { return }
            let start = scroll.contentView.bounds.minY
            guard animated, abs(endpoint(toBottom, in: scroll) - start) > 2 else {
                move(to: endpoint(toBottom, in: scroll), in: scroll); report(); return
            }
            let token = generation
            let motion = ScrollTransition(duration: 0.28, animationCurve: .easeInOut)
            motion.animationBlockingMode = .nonblocking
            motion.apply = { [weak self] progress in
                guard let self, self.generation == token, let scroll = self.scroll else { return }
                // Resolve the destination each frame as lazy rows refine their height.
                self.move(to: start + (self.endpoint(toBottom, in: scroll) - start) * progress, in: scroll)
                if progress >= 1 { self.transition = nil; self.report() }
            }
            transition = motion
            motion.start()
        }
        private func report() {
            guard !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.queued = false
                if let scroll = self.scroll {
                    if self.followingLatest && self.transition == nil && !LogScrollPosition(scroll: scroll).atBottom {
                        self.move(to: self.endpoint(true, in: scroll), in: scroll)
                    }
                    self.changed?(LogScrollPosition(scroll: scroll))
                }
            }
        }
        deinit { transition?.stop(); observing.forEach(NotificationCenter.default.removeObserver) }
    }
}
