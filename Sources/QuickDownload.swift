import AppKit
import SwiftUI
import Combine

@MainActor final class QuickDownloadState: ObservableObject {
    @Published var draft = "" { didSet { message = nil; failed = false; smart.inputChanged(draft) } }
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published var focusRequest = UUID()
    @Published private(set) var resultError: String?
    let model: DownloadModel
    let smart: SmartDownloadState
    private var smartChanges: AnyCancellable?

    init(model: DownloadModel) {
        self.model = model
        smart = SmartDownloadState(model: model, quick: true)
        smartChanges = smart.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var recentItems: [DownloadItem] {
        Array(model.downloads.filter { $0.preservesInput == true }
            .sorted { $0.createdAt > $1.createdAt }.prefix(3))
    }
    var status: String {
        if model.busy { return model.summary }
        if smart.resolving || smart.resolution != nil { return smart.progress?.label ?? "就绪" }
        return recentItems.first?.state.label ?? "就绪"
    }
    var saveDirectory: URL {
        smart.selectsOnlyPDFs ? (model.activePDFDirectory ?? model.directory) : model.directory
    }
    func open(_ item: DownloadItem, reveal: Bool = false) {
        model.openFile(item, reveal: reveal)
        resultError = model.notice
    }
    func openDirectory() {
        model.openDirectory(saveDirectory)
        resultError = model.directoryNotice
    }

    func inputTooLarge() {
        model.trace.user(.inputRejected, context: .quickPanel, outcome: .failed)
        message = "输入超过 64 KB，请分批粘贴。"
        failed = true
    }

    func submit() {
        if smart.resolving || smart.needsSetup { return }
        if smart.resolution != nil {
            smart.acceptSelection()
            return
        }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SmartInput.isDirect(draft) {
            message = nil; failed = false; resultError = nil
            let original = draft
            smart.submit(original) { [weak self] fullyResolved in
                guard fullyResolved, self?.draft == original else { return }
                self?.draft = ""
            }
            return
        }
        smart.cancel()
        do {
            let count = try model.submitQuickDownload(draft)
            resultError = nil
            draft = ""
            message = "已加入 \(count) 项"
            failed = false
        } catch {
            message = error.localizedDescription
            failed = true
        }
    }
}

struct QuickDownloadView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var state: QuickDownloadState
    @ObservedObject var model: DownloadModel
    var openWindow: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    var close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    private var reviewing: Bool { state.smart.resolution != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Folioak").font(.system(size: 15, weight: .semibold))
                Spacer()
                Menu {
                    Button(L("设置…"), action: openSettings)
                    Divider()
                    Button(L("退出 Folioak"), action: quit)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(MenuTriggerStyle(palette: palette))
                    .accessibilityLabel(L("更多操作"))
            }
            ZStack(alignment: .topLeading) {
                QuickLinkEditor(text: $state.draft, focusRequest: state.focusRequest, submit: state.submit, close: cancelOrClose, rejected: state.inputTooLarge, captureTrace: { accepted in model.trace.user(accepted ? .inputCaptured : .inputRejected, context: .quickPanel, outcome: accepted ? .succeeded : .failed) }, captureInput: model.captureInput)
                    .opacity(reviewing ? 0 : 1).disabled(reviewing).accessibilityHidden(reviewing)
                if reviewing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("核对下载")).font(.system(size: 13, weight: .medium))
                        Text(state.draft).font(.system(size: 12))
                            .foregroundStyle(ThemePalette.color(palette.secondary)).lineLimit(1)
                            .help(state.draft)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else if state.draft.isEmpty {
                    Text(L("粘贴链接，或描述想保存的资料"))
                        .font(.system(size: 13)).foregroundStyle(ThemePalette.color(palette.secondary))
                        .padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .frame(height: reviewing ? 42 : 112)
            .background(reviewing ? Color.clear : ThemePalette.color(palette.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(reviewing ? Color.clear : ThemePalette.color(palette.border), lineWidth: 1))
            if state.smart.resolving || reviewing || state.smart.message != nil {
                SmartInputStatusView(state: state.smart, palette: palette, compact: true,
                                     showsReviewActions: false, onEdit: returnToEditing)
            }
            HStack(spacing: 12) {
                Button(action: state.openDirectory) {
                    Label(state.saveDirectory.lastPathComponent, systemImage: "folder")
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(ThemePalette.color(palette.secondary))
                    .help(state.saveDirectory.path).accessibilityLabel(L("打开保存位置"))
                if reviewing {
                    SmartInputReviewActionsView(state: state.smart, palette: palette, onEdit: returnToEditing)
                } else if !state.smart.resolving {
                    Button(L(!SmartInput.isDirect(state.draft) && !state.draft.isEmpty
                             ? "查找资源" : model.busy ? "加入队列" : "开始下载"), action: state.submit)
                        .buttonStyle(QuietButtonStyle(palette: palette))
                        .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.cancelling || state.smart.resolving)
                        .help(L("⌘ Return 下载"))
                        .accessibilityIdentifier("quick-download-submit")
                }
            }
            if let message = state.message, state.failed || state.recentItems.contains(where: { !$0.state.terminal }) {
                Label(L(message), systemImage: state.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(state.failed ? UIColors.error : UIColors.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quick-download-feedback")
            }
            if !state.recentItems.isEmpty && state.smart.resolution == nil {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("最近下载")).font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                    ForEach(state.recentItems) { item in
                        HStack(spacing: 8) {
                            QuickDownloadFileLabel(item: item, state: state, palette: palette)
                            if !item.localURLs.isEmpty {
                                Button { state.open(item, reveal: true) } label: { Image(systemName: "folder") }
                                    .buttonStyle(RoundButtonStyle(palette: palette)).help(L("在 Finder 中显示"))
                                    .accessibilityLabel(L("在 Finder 中显示"))
                                    .accessibilityIdentifier("quick-reveal-" + item.id.uuidString)
                            }
                            if item.canRetry {
                                Button(L("重试")) { model.retry(item.id, context: .quickPanel) }
                                    .buttonStyle(.plain).font(.system(size: 12)).disabled(model.busy || model.libraryMutationInProgress)
                            }
                        }
                    }
                }.accessibilityIdentifier("quick-download-results")
            }
            if let error = state.resultError {
                Text(L(error)).font(.system(size: 11)).foregroundStyle(UIColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini) }
                Text(L(state.status))
                    .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).lineLimit(1)
                if model.busy {
                    Button(L("停止"), action: model.cancel).buttonStyle(.plain)
                        .font(.system(size: 11)).disabled(model.cancelling)
                }
                Spacer(minLength: 4)
                Button(L("打开 Folioak"), action: openWindow).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.accent))
            }
        }
        .padding(18).frame(width: 380)
        .foregroundStyle(ThemePalette.color(palette.text))
        .background(ThemePalette.color(palette.canvas))
        .environment(\.locale, L10n.locale)
        .sheet(isPresented: Binding(get: { state.smart.needsSetup }, set: { if !$0 && state.smart.needsSetup { state.smart.cancel() } })) {
            SmartConnectionForm(settings: model.smartSettings, palette: palette, continuesRequest: true,
                                requiresNewKey: state.smart.requiresNewKey,
                                connectionOwner: state.smart.setupConnectionOwner,
                                onConnected: state.smart.resumeAfterSetup, onCancel: state.smart.cancel)
                .padding(20).frame(width: 340)
                .background(ThemePalette.color(palette.canvas))
        }
    }

    private func returnToEditing() {
        state.smart.cancel()
        state.focusRequest = UUID()
    }

    private func cancelOrClose() {
        if state.smart.resolving || reviewing { returnToEditing() }
        else { close() }
    }
}

// The compact file label has no single-click selection. Give it its own native
// click surface, independent of the hosting window's gesture recognizer state.
private struct QuickDownloadFileLabel: View {
    let item: DownloadItem
    let state: QuickDownloadState
    let palette: ThemePalette
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.state.symbol).foregroundStyle(item.state.color(palette))
                .accessibilityLabel(L(item.state.label))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.savedURL?.lastPathComponent ?? item.title).font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                Text(item.localizedError ?? item.savedURL.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? L(item.state.label))
                    .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help(item.localizedError ?? item.localURLs.map(\.path).joined(separator: "\n"))
        .overlay(QuickDownloadFileInteraction(active: !item.localURLs.isEmpty) { state.open(item) }
            .accessibilityHidden(true))
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if !item.localURLs.isEmpty { Button(L("打开文件")) { state.open(item) } }
        }
        .accessibilityIdentifier("quick-file-" + item.id.uuidString)
    }
}

struct QuickDownloadFileInteraction: NSViewRepresentable {
    let active: Bool
    let open: () -> Void
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        view.isActive = active; view.open = open
    }
    final class Region: NSView {
        var isActive = false { didSet { if !isActive { armed = false } } }
        var open: () -> Void = {}
        private var armed = false
        #if TESTING
        var clickTrace: ((String) -> Void)?
        #endif
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isActive, !isHiddenOrHasHiddenAncestor else { return nil }
            return super.hitTest(point)
        }
        private func allows(_ event: NSEvent) -> Bool {
            isActive && window?.isVisible == true && event.windowNumber == window?.windowNumber &&
                !isHiddenOrHasHiddenAncestor &&
                event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty &&
                bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
        }
        override func mouseDown(with event: NSEvent) {
            armed = event.clickCount == 2 && allows(event)
            #if TESTING
            clickTrace?("down count=\(event.clickCount) armed=\(armed)")
            #endif
        }
        override func mouseDragged(with event: NSEvent) { armed = false }
        override func mouseUp(with event: NSEvent) {
            let shouldOpen = armed && event.clickCount == 2 && allows(event)
            armed = false
            #if TESTING
            clickTrace?("up count=\(event.clickCount) open=\(shouldOpen)")
            #endif
            if shouldOpen { open() }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); armed = false
        }
    }
}

// A native editor preserves selection/undo and handles submission in its own
// responder chain, even when the main window's download menu item is disabled.
struct QuickLinkEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let focusRequest: UUID
    let submit: () -> Void
    let close: () -> Void
    let rejected: () -> Void
    var captureTrace: ((Bool) -> Void)? = nil
    var captureInput: (String) throws -> String = PaperInput.captured
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = Editor()
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .systemFont(ofSize: 13); editor.textContainerInset = NSSize(width: 5, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.submit = submit; editor.close = close; editor.captureTrace = captureTrace
        editor.captureInput = captureInput
        editor.rejected = rejected
        editor.isEditable = isEnabled; editor.isSelectable = isEnabled
        if !isEnabled, editor.window?.firstResponder === editor { editor.window?.makeFirstResponder(nil) }
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.setAccessibilityLabel(L("下载链接"))
        if editor.string != text { editor.string = text; editor.undoManager?.removeAllActions() }
        if isEnabled && editor.focusRequest != focusRequest {
            editor.focusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.isEditable, editor.focusRequest == focusRequest else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QuickLinkEditor
        init(_ parent: QuickLinkEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            let allowed = (textView.string as NSString).replacingCharacters(in: range, with: replacementString).utf8.count <= ResourceLimits.inputBytes
            if !allowed { parent.rejected() }
            return allowed
        }
    }
    final class Editor: NSTextView {
        var submit: () -> Void = {}
        var close: () -> Void = {}
        var rejected: () -> Void = {}
        var focusRequest: UUID?
        var captureTrace: ((Bool) -> Void)?
        var captureInput: (String) throws -> String = PaperInput.captured
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if (event.keyCode == 36 || event.keyCode == 76) && modifiers == .command { submit(); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if (event.keyCode == 36 || event.keyCode == 76) && modifiers == .command { submit(); return }
            if event.keyCode == 53 && modifiers.isEmpty { close(); return }
            super.keyDown(with: event)
        }
        override func paste(_ sender: Any?) {
            guard let raw = NSPasteboard.general.string(forType: .string) else { return }
            do {
                insertText(try captureInput(raw), replacementRange: selectedRange())
                captureTrace?(true)
            } catch { captureTrace?(false); rejected() }
        }
    }
}

@MainActor final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private(set) var item: NSStatusItem?
    private(set) var actionMenu = NSMenu()
    private(set) var popover = NSPopover()
    let state: QuickDownloadState
    private var visibilityObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var sizeObservation: AnyCancellable?
    private var modelSizeObservation: AnyCancellable?
    private var activationObservation: AnyCancellable?
    private var resizeScheduled = false
    private var statusMouseMonitor: Any?
    private var statusPressInProgress = false
    private var statusNativeTracking = false
    private var actionMenuIsOpen = false
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let disabled: () -> Void

    init(model: DownloadModel, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void,
         quit: @escaping () -> Void, disabled: @escaping () -> Void = {}) {
        self.openWindow = openWindow; self.openSettings = openSettings; self.quit = quit; self.disabled = disabled
        state = QuickDownloadState(model: model)
        super.init()
        activationObservation = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in
            self?.statusPressInProgress = false
            self?.statusNativeTracking = false
        }
        popover.behavior = .transient
        popover.delegate = self
        // This utility behaves like a menu: opening, closing and rapid toggles
        // must not wait for the system popover's non-configurable fade duration.
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: QuickDownloadView(state: state, model: model,
            openWindow: { [weak self] in self?.showWindow() }, openSettings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.terminate() }, close: { [weak self] in self?.popover.performClose(nil) }))
        visibilityObservation = model.$showsMenuBarIcon.removeDuplicates().sink { [weak self] in self?.update(visible: $0) }
        languageObservation = model.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu(); self?.scheduleResize() }
        }
        modelSizeObservation = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleResize()
        }
        sizeObservation = state.objectWillChange.sink { [weak self] _ in
            self?.scheduleResize()
        }
    }
    deinit {
        if let statusMouseMonitor { NSEvent.removeMonitor(statusMouseMonitor) }
        if let item { NSStatusBar.system.removeStatusItem(item) }
    }
    private func update(visible: Bool) {
        if visible {
            if item == nil {
                let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Folioak")
                image?.isTemplate = true; status.button?.image = image
                status.button?.toolTip = "Folioak"; status.button?.setAccessibilityLabel("Folioak")
                status.button?.target = self; status.button?.action = #selector(activateStatusButton)
                status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item = status
                // Own this button's pointer sequence so AppKit cannot clear its
                // native highlight at mouse-up while the popover remains open.
                statusMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] event in
                    guard let self else { return event }
                    return self.handleStatusMouseEvent(event)
                }
            }
            updateMenu()
        } else if let item {
            if let statusMouseMonitor { NSEvent.removeMonitor(statusMouseMonitor); self.statusMouseMonitor = nil }
            statusPressInProgress = false; statusNativeTracking = false
            actionMenuIsOpen = false; actionMenu.cancelTracking()
            popover.close()
            NSStatusBar.system.removeStatusItem(item); self.item = nil
            disabled()
        }
    }
    private func updateMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        for (title, action) in [(L("显示 Folioak"), #selector(showWindow)), (L("设置…"), #selector(showSettings)), (L("退出 Folioak"), #selector(terminate))] {
            if action == #selector(terminate) { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        actionMenu = menu
    }
    private func setStatusSelected(_ selected: Bool) {
        guard let button = item?.button else { return }
        let state: NSControl.StateValue = selected ? .on : .off
        if button.state != state { button.state = state }
        if button.isHighlighted != selected { button.highlight(selected) }
    }
    func popoverWillShow(_ notification: Notification) { setStatusSelected(true); state.model.trace.record(.quickPanelShown, context: .quickPanel) }
    func popoverWillClose(_ notification: Notification) {
        if state.smart.needsSetup { state.smart.cancel() }
    }
    func popoverDidClose(_ notification: Notification) { setStatusSelected(actionMenuIsOpen); state.model.trace.record(.quickPanelHidden, context: .quickPanel) }
    func menuWillOpen(_ menu: NSMenu) { actionMenuIsOpen = true; setStatusSelected(true) }
    func menuDidClose(_ menu: NSMenu) { actionMenuIsOpen = false; setStatusSelected(popover.isShown) }

    private func hitsStatusButton(_ event: NSEvent) -> Bool {
        // Tahoe forwards status-item events with a window number but no NSWindow.
        guard let button = item?.button, let window = button.window,
              event.windowNumber == window.windowNumber else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let event = NSApp.currentEvent,
              !event.modifierFlags.contains(.command),
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) else { return true }
        // A second click belongs to our toggle, not transient outside-click dismissal.
        return !hitsStatusButton(event)
    }
    func handleStatusMouseEvent(_ event: NSEvent) -> NSEvent? {
        // NSMenu owns its tracking events; Command-drag belongs to macOS status-item rearrangement.
        if actionMenuIsOpen { return event }
        let hit = hitsStatusButton(event)
        if statusNativeTracking {
            if event.type == .leftMouseUp || event.type == .rightMouseUp { statusNativeTracking = false }
            return event
        }
        if event.modifierFlags.contains(.command) {
            statusPressInProgress = false
            statusNativeTracking = hit && (event.type == .leftMouseDown || event.type == .rightMouseDown)
            return event
        }
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            let consumed = statusPressInProgress || hit
            statusPressInProgress = false
            return consumed ? nil : event
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
        guard hit else { statusPressInProgress = false; return event }
        // Closing a transient panel can replay the down event. One press toggles once.
        guard !statusPressInProgress else { return nil }
        statusPressInProgress = true
        if event.type == .rightMouseDown {
            actionMenuIsOpen = true
            setStatusSelected(true)
            // Let transient-popover focus restoration finish before activating
            // the menu; otherwise Escape can be routed to the previous app.
            popover.close()
            // NSMenu starts a nested tracking loop. Enter it after the event
            // monitor returns so keyboard and mouse events can reach the menu.
            DispatchQueue.main.async { [weak self, weak button = item?.button] in
                guard let self, let button, self.item?.button === button, self.actionMenuIsOpen else { return }
                self.showActionMenu()
                self.statusPressInProgress = false
            }
        } else { togglePopover() }
        return nil
    }
    @objc private func activateStatusButton() {
        // Accessibility/keyboard activation still uses NSButton's native action.
        if NSApp.currentEvent?.type == .rightMouseUp { showActionMenu() }
        else { togglePopover() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setStatusSelected(self.popover.isShown || self.actionMenuIsOpen)
        }
    }
    private func showActionMenu() {
        guard let item, let button = item.button else { return }
        actionMenuIsOpen = true
        popover.close()
        setStatusSelected(true)
        // Native status-item tracking owns keyboard focus, including Escape,
        // even when another application is frontmost.
        item.menu = actionMenu
        button.performClick(nil)
        item.menu = nil
        actionMenuIsOpen = false
        setStatusSelected(popover.isShown)
    }

    @discardableResult
    func focusInputIfShown() -> Bool {
        guard popover.isShown else { return false }
        state.focusRequest = UUID()
        popover.contentViewController?.view.window?.makeKey()
        return true
    }

    @objc func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.close() }
        else {
            // The popover takes keyboard focus without activating the app,
            // which would also raise the workspace above the current app.
            resizePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            state.focusRequest = UUID()
        }
    }
    private func scheduleResize() {
        guard popover.isShown, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            if self.popover.isShown { self.resizePopover() }
        }
    }
    private func resizePopover() {
        guard let content = popover.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if size.width > 0 && size.height > 0 && popover.contentSize != size { popover.contentSize = size }
    }
    @objc private func showWindow() { popover.performClose(nil); openWindow() }
    @objc private func showSettings() { popover.performClose(nil); openSettings() }
    @objc private func terminate() { popover.performClose(nil); quit() }
}
