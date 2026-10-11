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
    enum Action { case up, down, preview, open, diagnostics }
    let request: UUID?
    var detailsShortcut = AppShortcut(key: "i")
    let didFocus: (UUID) -> Void
    let action: (Action) -> Void
    func makeNSView(context: Context) -> KeyView { KeyView(request: request, didFocus: didFocus, action: action) }
    func updateNSView(_ view: KeyView, context: Context) {
        view.action = action
        view.detailsShortcut = detailsShortcut
        view.didFocus = didFocus
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
        init(request: UUID?, didFocus: @escaping (UUID) -> Void, action: @escaping (Action) -> Void) {
            self.request = request; self.didFocus = didFocus; self.action = action
            super.init(frame: .zero)
            setAccessibilityLabel("文件列表，方向键选择，空格预览，Return 打开，Command I 查看详情")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfRequested() }
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
    @ObservedObject var model: DownloadModel
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var current: DownloadItem { model.items.first { $0.id == item.id } ?? model.history.first { $0.id == item.id } ?? item }
    private var entries: [ActivityEntry] { model.logs.filter { $0.itemID == item.id } }
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("任务详情").font(.system(size: 18, weight: .medium))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundButtonStyle(palette: palette)).keyboardShortcut(.cancelAction).accessibilityLabel("关闭任务详情")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(current.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                        Text(current.state.label).font(.system(size: 12)).foregroundStyle(current.state.color(palette))
                        if let file = current.savedURL {
                            Text(file.path).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text([current.pages.map { "\($0) 页" }, current.metadata?.reference.identifier ?? current.source?.label].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).textSelection(.enabled)
                        }
                    }
                    if let trace = current.diagnostics, trace.finishedAt != nil {
                        timings(trace, now: trace.finishedAt!)
                    } else if let trace = current.diagnostics {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            timings(trace, now: trace.finishedAt ?? context.date)
                        }.transaction { $0.animation = nil }
                    }
                    if let error = current.error {
                        Text(ActivityEntry.redacted(error)).font(.system(size: 12)).foregroundStyle(UIColors.error).textSelection(.enabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty { Text("暂无记录").foregroundStyle(ThemePalette.color(palette.secondary)) }
                        ForEach(entries.suffix(80)) { LogRow(entry: $0, palette: palette, horizontalInset: 0) }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("复制诊断") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }.buttonStyle(QuietButtonStyle(palette: palette))
                Spacer()
                if current.canRetry && !model.busy {
                    Button("重试") {
                        if model.items.contains(where: { $0.id == item.id }) || model.history.contains(where: { $0.id == item.id }) { model.retry(item.id) }
                        else { model.retryFromLibrary(current); dismiss() }
                    }.buttonStyle(QuietButtonStyle(palette: palette))
                }
            }
        }.padding(24).frame(width: 460, height: 480)
            .foregroundStyle(ThemePalette.color(palette.text))
            .background(ThemePalette.color(palette.canvas))
    }
    private func timings(_ trace: TaskDiagnostics, now: Date) -> some View {
        VStack(spacing: 9) {
            HStack {
                Text("本次耗时")
                Spacer()
                Text(TaskDiagnostics.time(trace.elapsed(now: now))).monospacedDigit()
                if trace.retries > 0 { Text("· 重试 \(trace.retries) 次") }
            }.foregroundStyle(ThemePalette.color(palette.text))
            ForEach(TaskDiagnostics.Phase.allCases, id: \.self) { phase in
                if trace.duration(phase, now: now) >= 0.05 || trace.phase == phase {
                    HStack {
                        Text(phase.label)
                        Spacer()
                        Text(TaskDiagnostics.time(trace.duration(phase, now: now))).monospacedDigit()
                    }
                }
            }
        }.font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary))
    }
    private var report: String {
        var lines = [current.title, current.state.label]
        if let source = current.source { lines.append(ActivityEntry.redacted(source.webURL.absoluteString)) }
        if let trace = current.diagnostics {
            lines.append("本次耗时 \(TaskDiagnostics.time(trace.elapsed())) · 重试 \(trace.retries) 次")
            for phase in TaskDiagnostics.Phase.allCases where trace.duration(phase) > 0 {
                lines.append("\(phase.label) \(TaskDiagnostics.time(trace.duration(phase)))")
            }
        }
        if let error = current.error { lines.append(ActivityEntry.redacted(error)) }
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
