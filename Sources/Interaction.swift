import AppKit
import SwiftUI

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
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    init() {}
    init(scroll: NSScrollView) {
        let visible = scroll.contentView.bounds
        let content = scroll.documentView?.bounds ?? .zero
        contentHeight = content.height
        viewportHeight = visible.height
        canScroll = content.height > visible.height + 2
        atTop = visible.minY <= content.minY + 2
        atBottom = visible.maxY >= content.maxY - 2
    }
}

// Observe actual clip bounds; programmatic animation must not be mistaken for
// the user leaving the tail. No timers or global event monitors are installed.
struct LogScrollObserver: NSViewRepresentable {
    let changed: (LogScrollPosition) -> Void
    let userScrolled: (LogScrollPosition) -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.changed = changed; view.userScrolled = userScrolled; view.connect()
    }
    final class Observer: NSView {
        var changed: ((LogScrollPosition) -> Void)?
        var userScrolled: ((LogScrollPosition) -> Void)?
        weak var scroll: NSScrollView?
        private var observing: [NSObjectProtocol] = []
        private var queued = false
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
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observing.append(NotificationCenter.default.addObserver(forName: name, object: enclosingScrollView, queue: .main) { [weak self] _ in
                    guard let self, let scroll = self.scroll else { return }
                    self.userScrolled?(LogScrollPosition(scroll: scroll)); self.report()
                })
            }
            report()
        }
        private func report() {
            guard !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.queued = false
                if let scroll = self.scroll { self.changed?(LogScrollPosition(scroll: scroll)) }
            }
        }
        deinit { observing.forEach(NotificationCenter.default.removeObserver) }
    }
}
