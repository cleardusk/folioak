import AppKit
import SwiftUI
import Combine

@MainActor final class QuickDownloadState: ObservableObject {
    @Published var draft = "" { didSet { message = nil; failed = false } }
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published var focusRequest = UUID()
    let model: DownloadModel

    init(model: DownloadModel) { self.model = model }

    func inputTooLarge() {
        message = "输入超过 64 KB，请分批粘贴。"
        failed = true
    }

    func submit() {
        do {
            let count = try model.submitQuickDownload(draft)
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
                QuickLinkEditor(text: $state.draft, focusRequest: state.focusRequest, submit: state.submit, close: close, rejected: state.inputTooLarge)
                    .frame(height: 112)
                if state.draft.isEmpty {
                    Text(L("粘贴链接，每行一条"))
                        .font(.system(size: 13)).foregroundStyle(ThemePalette.color(palette.secondary))
                        .padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .background(ThemePalette.color(palette.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ThemePalette.color(palette.border), lineWidth: 1))
            HStack(spacing: 12) {
                Label(model.directoryLabel, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                    .lineLimit(1).truncationMode(.middle).help(model.directory.path)
                Spacer(minLength: 0)
                Button(L(model.busy ? "加入队列" : "开始下载"), action: state.submit)
                    .buttonStyle(QuietButtonStyle(palette: palette))
                    .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.cancelling)
                    .help(L("⌘ Return 下载"))
                    .accessibilityIdentifier("quick-download-submit")
            }
            if let message = state.message {
                Label(L(message), systemImage: state.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(state.failed ? UIColors.error : UIColors.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quick-download-feedback")
            }
            Divider()
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini) }
                Text(model.summary.isEmpty ? L("就绪") : L(model.summary))
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
    }
}

// A native editor preserves selection/undo and handles submission in its own
// responder chain, even when the main window's download menu item is disabled.
struct QuickLinkEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let submit: () -> Void
    let close: () -> Void
    let rejected: () -> Void
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
        editor.submit = submit; editor.close = close
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.setAccessibilityLabel(L("下载链接"))
        if editor.string != text { editor.string = text; editor.undoManager?.removeAllActions() }
        if editor.focusRequest != focusRequest {
            editor.focusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.focusRequest == focusRequest else { return }
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
        var focusRequest: UUID?
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
            guard let raw = NSPasteboard.general.string(forType: .string), let captured = try? PaperInput.captured(raw) else {
                super.paste(sender); return
            }
            insertText(captured, replacementRange: selectedRange())
        }
    }
}

@MainActor final class MenuBarController: NSObject {
    private(set) var item: NSStatusItem?
    private(set) var actionMenu = NSMenu()
    private(set) var popover = NSPopover()
    let state: QuickDownloadState
    private var visibilityObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var sizeObservation: AnyCancellable?
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let disabled: () -> Void

    init(model: DownloadModel, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void,
         quit: @escaping () -> Void, disabled: @escaping () -> Void = {}) {
        self.openWindow = openWindow; self.openSettings = openSettings; self.quit = quit; self.disabled = disabled
        state = QuickDownloadState(model: model)
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: QuickDownloadView(state: state, model: model,
            openWindow: { [weak self] in self?.showWindow() }, openSettings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.terminate() }, close: { [weak self] in self?.popover.performClose(nil) }))
        visibilityObservation = model.$showsMenuBarIcon.removeDuplicates().sink { [weak self] in self?.update(visible: $0) }
        languageObservation = model.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu(); self?.resizePopover() }
        }
        sizeObservation = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePopover() }
        }
    }
    deinit { if let item { NSStatusBar.system.removeStatusItem(item) } }
    private func update(visible: Bool) {
        if visible {
            if item == nil {
                let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Folioak")
                image?.isTemplate = true; status.button?.image = image
                status.button?.toolTip = "Folioak"; status.button?.setAccessibilityLabel("Folioak")
                status.button?.target = self; status.button?.action = #selector(togglePopover)
                status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item = status
            }
            updateMenu()
        } else if let item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item); self.item = nil
            disabled()
        }
    }
    private func updateMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [(L("显示 Folioak"), #selector(showWindow)), (L("设置…"), #selector(showSettings)), (L("退出 Folioak"), #selector(terminate))] {
            if action == #selector(terminate) { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        actionMenu = menu
    }
    @objc func togglePopover() {
        guard let button = item?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            actionMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            resizePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            state.focusRequest = UUID()
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
