import AppKit
import SwiftUI
private typealias ShortcutViewState<Value> = SwiftUI.State<Value>

enum ShortcutAction: String, CaseIterable, Codable {
    case input, list, download, details
    var title: String { switch self { case .input: return "添加论文"; case .list: return "论文列表"; case .download: return "开始下载"; case .details: return "任务详情" } }
    var defaultKey: String { switch self { case .input: return "l"; case .list: return "j"; case .download: return "\r"; case .details: return "i" } }
}
struct AppShortcut: Codable, Equatable {
    var key: String
    var modifiers: UInt = NSEvent.ModifierFlags.command.rawValue
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var label: String { (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + "⌘" + (key == "\r" ? "↩" : key.uppercased()) }
    var swiftModifiers: EventModifiers {
        var result: EventModifiers = [.command]
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
    var valid: Bool {
        let allowed: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return flags.contains(.command) && flags.subtracting(allowed).isEmpty && (key == "\r" || key.range(of: "^[a-z0-9]$", options: .regularExpression) != nil)
    }
    var reserved: Bool {
        flags == .command && ["q", "w", "h", "m", "x", "c", "v", "a", "z", "f"].contains(key) ||
        flags == [.command, .shift] && ["z", "w", "q"].contains(key) || flags == [.command, .option] && ["h", "m", "w"].contains(key)
    }
    func matches(_ event: NSEvent) -> Bool {
        flags == event.modifierFlags.intersection([.command, .control, .option, .shift]) && key == event.characters(byApplyingModifiers: [])?.lowercased()
    }
}

@MainActor final class ShortcutSettings: ObservableObject {
    @Published private(set) var bindings: [String: AppShortcut]
    private let preferences: UserDefaults
    init(_ preferences: UserDefaults) {
        self.preferences = preferences
        let defaults = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, AppShortcut(key: $0.defaultKey)) })
        if let data = preferences.data(forKey: "shortcuts"), let saved = try? JSONDecoder().decode([String: AppShortcut].self, from: data),
           saved.count == defaults.count, ShortcutAction.allCases.allSatisfy({ saved[$0.rawValue]?.valid == true && saved[$0.rawValue]?.reserved == false }),
           Set(saved.values.map { "\($0.modifiers):\($0.key)" }).count == defaults.count { bindings = saved }
        else { bindings = defaults }
    }
    subscript(_ action: ShortcutAction) -> AppShortcut { bindings[action.rawValue]! }
    func set(_ shortcut: AppShortcut, for action: ShortcutAction) -> String? {
        guard shortcut.valid else { return "请使用 ⌘ 配合字母、数字或 Return。" }
        guard !shortcut.reserved else { return "这个组合保留给系统和编辑操作。" }
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self[$0] == shortcut }) { return "已用于“\(conflict.title)”。" }
        bindings[action.rawValue] = shortcut
        preferences.set(try? JSONEncoder().encode(bindings), forKey: "shortcuts")
        return nil
    }
    func reset() {
        bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, AppShortcut(key: $0.defaultKey)) })
        preferences.removeObject(forKey: "shortcuts")
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: AppShortcut
    let changed: (AppShortcut) -> String?
    let report: (String?) -> Void
    func makeNSView(context: Context) -> Recorder { Recorder() }
    func updateNSView(_ view: Recorder, context: Context) {
        view.shortcut = shortcut; view.changed = changed; view.report = report
        if !view.recording { view.title = shortcut.label; view.setAccessibilityValue(shortcut.label) }
    }
    final class Recorder: NSButton {
        var shortcut = AppShortcut(key: "l")
        var changed: ((AppShortcut) -> String?)?
        var report: ((String?) -> Void)?
        private(set) var recording = false
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override init(frame: NSRect) {
            super.init(frame: frame); bezelStyle = .rounded; target = self; action = #selector(beginRecording)
            setAccessibilityLabel("修改快捷键")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override var acceptsFirstResponder: Bool { true }
        @objc private func beginRecording() {
            window?.makeFirstResponder(self); recording = true; title = "请按组合键…"; report?(nil)
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.recording, self.window === NSApp.keyWindow else { return event }
                    if event.keyCode == 53 { self.stop(); return nil }
                    if event.keyCode == 48 { self.stop(); return event }
                    let shortcut = AppShortcut(key: event.characters(byApplyingModifiers: [])?.lowercased() ?? "", modifiers: event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue)
                    if let error = self.changed?(shortcut) { self.report?(error) }
                    else { self.shortcut = shortcut; self.report?(nil); self.stop() }
                    return nil
                }
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stop() }
            }
        }
        private func stop() {
            recording = false; title = shortcut.label; setAccessibilityValue(shortcut.label)
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        }
        override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
        override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { stop() }; super.viewWillMove(toWindow: newWindow) }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) }; if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: ShortcutSettings
    @ShortcutViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                HStack {
                    Text(action.title); Spacer()
                    ShortcutRecorder(shortcut: shortcuts[action], changed: { shortcuts.set($0, for: action) }, report: { error = $0 })
                        .frame(width: 140, height: 28).accessibilityLabel("\(action.title)快捷键")
                }
            }
            Text(error ?? "").foregroundStyle(UIColors.error).font(.system(size: 11)).frame(height: 28, alignment: .topLeading)
            Divider()
            HStack { Text("列表操作"); Spacer(); Text("↑ ↓ 选择   空格预览   ↩ 打开").foregroundStyle(.secondary) }
            HStack { Text("窗口操作"); Spacer(); Text("⌘W 关闭   ⌘, 设置").foregroundStyle(.secondary) }
            Spacer()
            HStack { Spacer(); Button("恢复默认") { shortcuts.reset(); error = nil }.controlSize(.small) }
        }.font(.system(size: 12))
    }
}
