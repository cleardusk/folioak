import AppKit
import SwiftUI

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

struct PaperListKeyboard: NSViewRepresentable {
    @ObservedObject private var localization = AppLocalization.shared
    enum Action { case up, down, preview, open, diagnostics }
    let request: UUID?
    var detailsShortcut = AppShortcut(key: "i")
    var focusChanged: (Bool) -> Void = { _ in }
    let didFocus: (UUID) -> Void
    let action: (Action) -> Void
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(request: request, didFocus: didFocus, action: action)
        view.focusChanged = focusChanged
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) {
        view.setAccessibilityLabel(L("文件列表，方向键选择，空格预览，Return 打开，Command I 查看详情"))
        view.action = action
        view.detailsShortcut = detailsShortcut
        view.didFocus = didFocus
        view.focusChanged = focusChanged
        guard view.request != request else { return }
        view.request = request
        view.focusIfRequested()
    }
    final class KeyView: NSView {
        var request: UUID?
        var detailsShortcut = AppShortcut(key: "i")
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
            guard modifiers.isEmpty else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 126: action(.up)
            case 125: action(.down)
            case 49: action(.preview)
            case 36, 76: action(.open)
            default: super.keyDown(with: event)
            }
        }
    }
}

struct TaskDiagnosticView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    let item: DownloadItem
    var libraryPaperID: UUID? = nil
    var fromMediaLibrary = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @WorkspaceViewState private var files: [FileInformation] = []
    @WorkspaceViewState private var loading = false
    @WorkspaceViewState private var showingDiagnostics = false
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
    private var hasDiagnostics: Bool { diagnosticTask?.diagnostics != nil || diagnosticTask?.error != nil || !entries.isEmpty }
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
                    VStack(alignment: .leading, spacing: 7) {
                        Text(current.title).font(.system(size: 14, weight: .medium)).lineLimit(3).textSelection(.enabled)
                        Text(L(current.state.label)).font(.system(size: 12)).foregroundStyle(current.state.color(palette))
                    }
                    ForEach(Array(files.enumerated()), id: \.offset) { index, information in
                        if index > 0 { Divider() }
                        ForEach(Array(information.groups.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L(group.title)).font(.system(size: 12, weight: .medium))
                                ForEach(Array(group.fields.enumerated()), id: \.offset) { _, field in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(L(field.name)).foregroundStyle(ThemePalette.color(palette.secondary)).frame(width: L10n.language.code() == "en" ? 104 : 72, alignment: .leading)
                                        Text(field.name == "尺寸" ? L(field.value) : field.value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }.font(.system(size: 12))
                                }
                            }
                        }
                        if let issue = information.issue {
                            Text(L(issue)).font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary))
                        }
                    }
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在读取文件信息…")).font(.system(size: 12)) }
                            .foregroundStyle(ThemePalette.color(palette.secondary))
                    }
                    if hasDiagnostics {
                        if current.localURLs.isEmpty { diagnosticContent }
                        else {
                            Divider()
                            DisclosureGroup(L("下载记录"), isExpanded: $showingDiagnostics) { diagnosticContent.padding(.top, 12) }
                                .font(.system(size: 12))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
        }.padding(24).frame(width: 500, height: 540)
            .foregroundStyle(ThemePalette.color(palette.text))
            .background(ThemePalette.color(palette.canvas))
            .task(id: current.localURLs.map(\.absoluteString).joined(separator: "\n") + L10n.locale.identifier) {
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
    private var diagnosticContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let trace = diagnosticTask?.diagnostics, trace.finishedAt != nil {
                timings(trace, now: trace.finishedAt!)
            } else if let trace = diagnosticTask?.diagnostics {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timings(trace, now: trace.finishedAt ?? context.date)
                }.transaction { $0.animation = nil }
            }
            if let error = diagnosticTask?.error {
                Text(L(ActivityEntry.redacted(error))).font(.system(size: 12)).foregroundStyle(UIColors.error).textSelection(.enabled)
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
    private var report: String {
        var lines = [current.title, L(current.state.label)]
        if let source = current.source { lines.append(ActivityEntry.redacted(source.webURL.absoluteString)) }
        if let trace = diagnosticTask?.diagnostics {
            lines.append(L("本次耗时 \(TaskDiagnostics.time(trace.elapsed())) · 重试 \(trace.retries) 次"))
            for phase in TaskDiagnostics.Phase.allCases where trace.duration(phase) > 0 {
                lines.append("\(L(phase.label)) \(L(TaskDiagnostics.time(trace.duration(phase))))")
            }
        }
        if let error = diagnosticTask?.error { lines.append(L(ActivityEntry.redacted(error))) }
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
