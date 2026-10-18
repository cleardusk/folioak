import AppKit
import SwiftUI

@MainActor final class InteractionTraceSettings: ObservableObject {
    static let preferenceKey = "recordsInteractionTrace"
    let recorder: InteractionTrace
    private let preferences: UserDefaults
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            preferences.set(enabled, forKey: Self.preferenceKey)
            notice = nil
            recorder.setEnabled(enabled)
        }
    }
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    init(preferences: UserDefaults, recorder: InteractionTrace) {
        self.preferences = preferences; self.recorder = recorder
        enabled = preferences.bool(forKey: Self.preferenceKey)
        recorder.failureHandler = { [weak self] in
            DispatchQueue.main.async { self?.notice = "操作轨迹写入失败，记录已暂停。可关闭后重新开启；下载不受影响。" }
        }
        recorder.setEnabled(enabled)
    }
    func export(_ range: InteractionTrace.Range) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("导出操作轨迹")
        panel.prompt = L("导出")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        busy = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let directory = panel.url else { self.busy = false; return }
            Task {
                defer { self.busy = false }
                do {
                    let result = try await self.recorder.export(to: directory, range: range)
                    self.notice = nil
                    NSWorkspace.shared.activateFileViewerSelecting([result])
                } catch { self.notice = "操作轨迹导出失败，请检查保存位置。" }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }
    func clear() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await recorder.clear(); notice = "操作轨迹已清除。" }
        catch { notice = "操作轨迹清除失败，请检查文件访问权限。" }
    }
}

struct InteractionTraceControls: View {
    @ObservedObject var settings: InteractionTraceSettings
    let palette: ThemePalette
    @WorkspaceViewState private var confirmingClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("记录操作轨迹"), isOn: $settings.enabled).toggleStyle(.checkbox)
                .accessibilityIdentifier("interaction-trace-toggle")
            Text(L("仅保存在本机，最多 20 MB，保留最近 7 天。不记录输入内容、文件名或完整链接。"))
                .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Menu {
                    Button(L("本次运行")) { settings.export(.session) }
                    Button(L("今天")) { settings.export(.today) }
                    Button(L("最近 7 天")) { settings.export(.week) }
                } label: { Text(L("导出操作轨迹…")) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(settings.busy)
                    .accessibilityIdentifier("interaction-trace-export")
                Button(L("清除记录…")) { confirmingClear = true }
                    .buttonStyle(.plain).disabled(settings.busy)
                    .accessibilityIdentifier("interaction-trace-clear")
                if settings.busy { ProgressView().controlSize(.mini) }
            }
            if let notice = settings.notice {
                Text(L(notice)).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(L("清除操作轨迹？"), isPresented: $confirmingClear) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清除"), role: .destructive) { Task { await settings.clear() } }
        } message: { Text(L("清除本机保存的操作轨迹；已导出的文件需自行删除。")) }
    }
}

extension DownloadModel {
    var trace: InteractionTrace { traceSettings.recorder }
    func traceSetting(_ detail: InteractionEvent.Detail) {
        trace.user(.settingChanged, context: .settings, detail: detail)
    }
    func finishTrace() async {
        // Recording is diagnostic: a slow or broken disk must not hold up quit.
        trace.record(.sessionEnded)
        await trace.flushBeforeExit()
    }
}


// Read only the current application event at semantic action boundaries.
// No global event monitor, raw keystrokes or per-mouse-event recording.
extension InteractionTrace {
    @MainActor func user(_ action: InteractionEvent.Action, context: InteractionEvent.Context = .app,
                        outcome: InteractionEvent.Outcome = .performed, item: UUID? = nil,
                        operation: UUID? = nil, detail: InteractionEvent.Detail? = nil,
                        count: Int? = nil, diagnostic: DiagnosticMessage.ID? = nil) {
        guard isEnabled else { return }
        let trigger: InteractionEvent.Trigger
        switch NSApp?.currentEvent?.type {
        case .keyDown?, .keyUp?: trigger = .keyboard
        case .leftMouseDown?, .leftMouseUp?, .rightMouseDown?, .rightMouseUp?: trigger = .pointer
        default: trigger = .unspecified
        }
        record(action, context: context, outcome: outcome, item: item, operation: operation,
               detail: detail, count: count, diagnostic: diagnostic, trigger: trigger)
    }
}
