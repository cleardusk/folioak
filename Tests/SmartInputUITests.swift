import AppKit
import SwiftUI
import Vision

private final class SmartUICredentials: SmartCredentialStorage {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ key: String) throws { value = key }
    func delete() throws { value = nil }
}

private struct SmartUIResolver: SmartResolving {
    enum Mode { case review, pending, failure }
    let result: SmartResolution
    var mode = Mode.review
    func resolve(_ input: String, apiKey: String,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution {
        if mode == .failure { throw SmartResolverError.unavailable }
        if mode == .pending {
            progress(.searching)
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return result
    }
}

private struct SmartUINoNetwork: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw TestFailure.failed("smart UI fixture must not request the network")
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        throw TestFailure.failed("smart UI fixture must not start a download")
    }
}

@MainActor private final class SmartUISurface {
    let host: NSHostingView<AnyView>
    let window: NSPanel
    init(_ view: some View, size: NSSize) {
        host = NSHostingView(rootView: AnyView(view))
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = host
        window.orderFront(nil)
    }
    func settle() async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    func fitHeight(width: CGFloat) {
        host.layoutSubtreeIfNeeded()
        let height = ceil(host.fittingSize.height)
        if height > 0 { window.setContentSize(NSSize(width: width, height: height)) }
    }
    static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func image() throws -> NSBitmapImageRep {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw TestFailure.failed("smart UI bitmap allocation")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    func verify(_ name: String, labels: [String], uniqueLabels: [String] = [],
                absentLabels: [String] = [], snapshots: Bool) throws {
        let bitmap = try image()
        if snapshots {
            let folder = URL(fileURLWithPath: "build/qa/smart-input", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw TestFailure.failed("smart UI PNG encoding")
            }
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
        guard let image = bitmap.cgImage else { throw TestFailure.failed("smart UI CGImage") }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        func normalized(_ value: String) -> String {
            String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        for label in labels {
            try expect(normalized(text).contains(normalized(label)),
                       "visible smart UI control \(name): \(label); actual: \(text)")
        }
        for label in uniqueLabels {
            try expect(normalized(text).components(separatedBy: normalized(label)).count == 2,
                       "one smart UI action \(name): \(label); actual: \(text)")
        }
        for label in absentLabels {
            try expect(!normalized(text).contains(normalized(label)),
                       "absent smart UI action \(name): \(label); actual: \(text)")
        }
    }
}

extension CoreTests {
    @MainActor static func smartInputUITests(snapshots: Bool) async throws {
        _ = NSApplication.shared
        let language = AppLocalization.shared.language, appearance = NSApp.appearance
        defer { AppLocalization.shared.language = language; NSApp.appearance = appearance }
        let suite = "folioak-smart-ui-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "updates.automatic")
        preferences.set(false, forKey: "showsMenuBarIcon")
        let settings = SmartSettings(preferences, credentials: SmartUICredentials())
        try settings.saveKey("sk-isolated-ui-fixture")
        settings.enabled = true
        let candidates = [
            SmartCandidate(id: "talk", title: "A long research presentation title — reliable retrieval, document identity, and reproducible evaluation",
                           url: URL(string: "https://example.org/research-presentation.mp4")!,
                           detail: "Presentation associated with the research project. Review both requested output formats.",
                           origin: .search)
        ] + (1...4).map { index in
            SmartCandidate(id: "paper-\(index)", title: "Research paper \(index): Robust resource discovery with a deliberately long descriptive title for narrow windows",
                           url: URL(string: "https://example.org/paper-\(index).pdf")!,
                           detail: "A distinct paper candidate with a long description. Compare the source before choosing a file.",
                           origin: .search)
        }
        let result = SmartResolution(candidates: candidates, selections: [
            SmartSelection(candidateID: "talk", format: .video, skipExisting: true),
            SmartSelection(candidateID: "talk", format: .audio, skipExisting: true),
            SmartSelection(candidateID: "paper-1", format: .inherit, skipExisting: false)
        ], unresolved: ["尚未找到官方补充材料。", "The requested supplementary archive was not found on the inspected page."],
           needsReview: true, modelCalls: 2, toolCalls: 1)
        func makeModel(_ mode: SmartUIResolver.Mode = .review, resolution: SmartResolution? = nil) -> DownloadModel {
            DownloadModel(engine: DownloadEngine(transport: SmartUINoNetwork(), pdfTransport: SmartUINoNetwork(),
                                                 requestInterval: 0, retryDelay: 0),
                          preferences: preferences, opener: { _ in false }, smartSettings: settings,
                          smartResolver: SmartUIResolver(result: resolution ?? result, mode: mode))
        }
        func waitForReview(_ state: SmartDownloadState) async throws {
            for _ in 0..<100 {
                if state.resolution != nil { return }
                if state.failed { throw TestFailure.failed("smart UI fixture resolver failed") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw TestFailure.failed("smart UI fixture resolver did not complete")
        }
        // Replay the real search table through the resolver before rendering.
        // A hand-polished candidate would miss the original filename/evidence bug.
        let paperResult = try await smartPaperPresentationFixture()
        for selectedLanguage in [AppLanguage.chinese, .english] {
            for scheme in [ColorScheme.light, .dark] {
                let model = makeModel()
                model.language = selectedLanguage
                model.theme = .grove
                NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let name = selectedLanguage.rawValue + "-" + (scheme == .dark ? "dark" : "light")
                let palette = model.theme.palette(dark: scheme == .dark)
                model.input = "Find the paper and supplementary materials, and save the presentation as both video and audio."
                model.start()
                try await waitForReview(model.smartInput)
                try expect(model.smartInput.selections.filter { $0.candidateID == "talk" }.count == 2,
                           "review preserves both requested formats")
                model.smartInput.setSelected(candidates[0], selected: false)
                model.smartInput.setSelected(candidates[0], selected: true)
                try expect(model.smartInput.selections.filter { $0.candidateID == "talk" } ==
                           result.selections.filter { $0.candidateID == "talk" },
                           "reselecting a matched resource restores its own formats and skip-existing options")

                let status = SmartUISurface(SmartInputStatusView(state: model.smartInput, palette: palette, compact: true)
                    .padding(12).frame(width: 380).background(ThemePalette.color(palette.canvas))
                    .environment(\.colorScheme, scheme), size: NSSize(width: 380, height: 440))
                status.fitHeight(width: 380)
                try await status.settle()
                try expect(status.host.bounds.height <= 440, "standalone review has bounded compact height")
                try status.verify("review-" + name,
                                  labels: [L("下载 3 项"), L("未完成"), L("返回修改")],
                                  absentLabels: [L("已有的跳过")], snapshots: snapshots)
                let scrolls = SmartUISurface.descendants(status.host).compactMap { $0 as? NSScrollView }
                try expect(!scrolls.isEmpty && scrolls.allSatisfy { $0.bounds.height <= 202 },
                           "review scroll regions stay bounded")
                status.window.close()

                let main = SmartUISurface(DownloaderView(model: model).environment(\.colorScheme, scheme),
                                          size: NSSize(width: 780, height: 540))
                try await main.settle()
                try expect(main.host.bounds.size == NSSize(width: 780, height: 540), "review keeps minimum main-window size")
                try main.verify("main-" + name, labels: [L("下载 3 项"), L("未完成"), L("返回修改"), L("视频"), L("仅音频")],
                                uniqueLabels: [L("下载 3 项")],
                                absentLabels: [L("已有的跳过"), L("粘贴链接，开始下载"), L("试试示例：Attention Is All You Need")],
                                snapshots: snapshots)
                try expect(SmartUISurface.descendants(main.host).allSatisfy { !($0 is LinkTextView) },
                           "review replaces the large input editor with a compact request summary")
                main.window.close()

                let quickState = QuickDownloadState(model: model)
                quickState.draft = "Find the paper, supplementary archive, and presentation."
                quickState.submit()
                try await waitForReview(quickState.smart)
                model.history = (0..<3).map { index in
                    DownloadItem(original: "https://example.org/recent-\(index).pdf",
                                 directURL: URL(string: "https://example.org/recent-\(index).pdf"),
                                 state: .failed, error: "Fixture", documentTitle: "Previous download \(index)",
                                 preservesInput: true)
                }
                let quick = SmartUISurface(QuickDownloadView(state: quickState, model: model, openWindow: {},
                    openSettings: {}, quit: {}, close: {}).environment(\.colorScheme, scheme),
                    size: NSSize(width: 380, height: 640))
                quick.fitHeight(width: 380)
                try await quick.settle()
                try expect(quick.host.bounds.width == 380 && quick.host.bounds.height <= 720,
                           "quick review fits a compact window even with recent downloads")
                try quick.verify("quick-" + name, labels: [L("下载 3 项"), L("未完成"), L("打开 Folioak"), L("视频"), L("仅音频")],
                                 uniqueLabels: [L("下载 3 项")], absentLabels: [L("已有的跳过")], snapshots: snapshots)
                quick.window.close()
                quickState.smart.cancel()

                let configuration = SmartUISurface(SmartSettingsView(settings: settings, palette: palette)
                    .padding(16).background(ThemePalette.color(palette.canvas)).environment(\.colorScheme, scheme),
                    size: NSSize(width: 540, height: 380))
                try await configuration.settle()
                try configuration.verify("settings-" + name,
                                         labels: [L("启用智能输入"), L("保存"), L("移除 Key")], snapshots: snapshots)
                configuration.window.close()
                model.smartInput.cancel()

                model.settingsTab = "智能输入"
                model.preferencesPage = .settings
                let fullSettings = SmartUISurface(DownloaderView(model: model).environment(\.colorScheme, scheme),
                                                  size: NSSize(width: 780, height: 540))
                try await fullSettings.settle()
                try expect(fullSettings.host.bounds.size == NSSize(width: 780, height: 540),
                           "smart settings keep minimum main-window size")
                try fullSettings.verify("main-settings-" + name,
                                        labels: [L("通用"), L("命名规则"), L("快捷键"), L("浏览器认证"), L("智能输入"),
                                                 L("启用智能输入"), L("保存"), L("移除 Key")], snapshots: snapshots)
                fullSettings.window.close()

                let paperModel = makeModel(resolution: paperResult)
                paperModel.language = selectedLanguage
                paperModel.theme = .grove
                paperModel.pdfDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewPapers")
                paperModel.setPDFDirectoryEnabled(true)
                paperModel.input = "下载 gpt-1 论文"
                paperModel.history = [DownloadItem(original: "https://example.org/earlier.pdf",
                    directURL: URL(string: "https://example.org/earlier.pdf"), state: .failed,
                    documentTitle: "Earlier saved paper")]
                paperModel.start()
                try await waitForReview(paperModel.smartInput)
                let paperReview = SmartUISurface(DownloaderView(model: paperModel).environment(\.colorScheme, scheme),
                                                 size: NSSize(width: 780, height: 540))
                try await paperReview.settle()
                try paperReview.verify("paper-" + name,
                    labels: ["Improving Language Understanding by Generative Pre-Training",
                             "cdn.openai.com", L("下载文件"), L("返回修改"), "ReviewPapers", "Earlier saved paper"],
                    absentLabels: ["language_understanding_paper.pdf", "Local copy", "one-sentence answer",
                                   L("已有的跳过"), L("已选 1 / 10")], snapshots: snapshots)
                try expect(paperReview.host.bounds.size == NSSize(width: 780, height: 540),
                           "real paper review and history fit the minimum main window")
                paperModel.focusInput()
                try await paperReview.settle()
                guard let restoredEditor = SmartUISurface.descendants(paperReview.host)
                    .compactMap({ $0 as? LinkTextView }).first else {
                    throw TestFailure.failed("returning to edit remounts the native input")
                }
                try expect(paperModel.smartInput.resolution == nil && paperModel.input == "下载 gpt-1 论文"
                           && restoredEditor.naturalLanguageInput
                           && restoredEditor.font?.pointSize == 13,
                           "return to edit preserves the exact request and native editor, including CJK font fallback")
                try paperReview.verify("paper-edit-" + name, labels: [L("查找资源")],
                    absentLabels: ["Improving Language Understanding by Generative Pre-Training"], snapshots: snapshots)
                paperReview.window.close()
                paperModel.setPDFDirectoryEnabled(false)
            }
        }

        AppLocalization.shared.language = .chinese
        NSApp.appearance = NSAppearance(named: .aqua)
        let pending = makeModel(.pending)
        pending.input = "查找论文及附件"
        pending.start()
        let progress = SmartUISurface(SmartInputStatusView(state: pending.smartInput, palette: pending.theme.palette(dark: false))
            .padding(12), size: NSSize(width: 380, height: 90))
        try await progress.settle()
        try expect(pending.smartInput.resolving, "pending UI fixture remains cancellable")
        try progress.verify("progress", labels: [L("正在查找资源…"), L("取消")], snapshots: snapshots)
        pending.smartInput.cancel()
        progress.window.close()

        let failed = makeModel(.failure)
        failed.input = "查找论文"
        failed.start()
        let error = SmartUISurface(SmartInputStatusView(state: failed.smartInput, palette: failed.theme.palette(dark: false))
            .padding(12), size: NSSize(width: 380, height: 100))
        try await error.settle()
        try expect(failed.smartInput.failed && failed.items.isEmpty, "failed resolution never creates a queue")
        try error.verify("error", labels: [L("智能服务暂时不可用，请稍后重试。")], snapshots: snapshots)
        error.window.close()
        failed.smartInput.cancel()

        let notFound = makeModel(resolution: SmartResolution(candidates: [], selections: [],
            unresolved: ["未找到匹配的论文，请补充作者或标题。"], needsReview: true, modelCalls: 3, toolCalls: 2))
        notFound.input = "查找论文"
        notFound.start()
        try await waitForReview(notFound.smartInput)
        let emptyReview = SmartUISurface(SmartInputStatusView(state: notFound.smartInput,
            palette: notFound.theme.palette(dark: false)).padding(12), size: NSSize(width: 380, height: 130))
        try await emptyReview.settle()
        try expect(notFound.smartInput.message == nil && notFound.items.isEmpty,
                   "no-match result keeps a single explanation and never creates a queue")
        try emptyReview.verify("no-match", labels: ["未找到匹配的论文", L("返回修改")],
            absentLabels: [L("下载文件"), L("已选 0 / 10")], snapshots: snapshots)
        emptyReview.window.close()
        notFound.start()
        try expect(!notFound.smartInput.failed && notFound.smartInput.message == nil && notFound.items.isEmpty,
                   "main submission with no matches is a no-op")
        let emptyQuickState = QuickDownloadState(model: notFound)
        emptyQuickState.draft = "查找论文"
        emptyQuickState.submit()
        try await waitForReview(emptyQuickState.smart)
        let emptyQuick = SmartUISurface(QuickDownloadView(state: emptyQuickState, model: notFound,
            openWindow: {}, openSettings: {}, quit: {}, close: {}), size: NSSize(width: 380, height: 540))
        try await emptyQuick.settle()
        guard let emptyEditor = SmartUISurface.descendants(emptyQuick.host).compactMap({ $0 as? QuickLinkEditor.Editor }).first,
              let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: emptyQuick.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw TestFailure.failed("empty quick review mounts its native editor")
        }
        try expect(emptyEditor.performKeyEquivalent(with: submit) && !emptyQuickState.smart.failed &&
                   emptyQuickState.smart.message == nil && emptyQuickState.smart.resolution != nil &&
                   emptyQuickState.draft == "查找论文" && notFound.items.isEmpty,
                   "Command Return on a no-match quick review preserves the explanation and draft")
        emptyQuick.window.close()
        emptyQuickState.smart.cancel()
        notFound.smartInput.cancel()

        let longResult = SmartResolution(candidates: [candidates[1]],
            selections: [SmartSelection(candidateID: candidates[1].id, format: .inherit, skipExisting: false)],
            unresolved: (1...10).map { "要求 \($0)：" + String(repeating: "尚未确认补充材料的来源，请保留原请求以便继续核对。", count: 8) },
            needsReview: true, modelCalls: 1, toolCalls: 0)
        let partial = makeModel(resolution: longResult)
        // An existing queue item exercises acceptance without starting a worker.
        partial.items = [DownloadItem(original: candidates[1].url.absoluteString,
                                      directURL: candidates[1].url, state: .queued)]
        partial.input = "查找论文及全部补充材料"
        partial.start()
        try await waitForReview(partial.smartInput)
        partial.start()
        try expect(partial.smartInput.resolution == nil && (partial.smartInput.message?.count ?? 0) > 1_000,
                   "long partial-acceptance fixture preserves every unmet requirement")
        let longMain = SmartUISurface(DownloaderView(model: partial), size: NSSize(width: 780, height: 540))
        try await longMain.settle()
        try longMain.verify("main-long-partial", labels: [L("添加资源"), L("仍未完成：")], snapshots: snapshots)
        try expect(longMain.host.bounds.size == NSSize(width: 780, height: 540),
                   "long partial result keeps minimum main-window size")
        longMain.window.close()

        let partialQuick = QuickDownloadState(model: partial)
        partialQuick.draft = "查找论文及全部补充材料"
        partialQuick.submit()
        try await waitForReview(partialQuick.smart)
        partialQuick.submit()
        try expect(!partialQuick.draft.isEmpty && (partialQuick.smart.message?.count ?? 0) > 1_000,
                   "quick partial acceptance retains draft and every unmet requirement")
        let longQuick = SmartUISurface(QuickDownloadView(state: partialQuick, model: partial, openWindow: {},
            openSettings: {}, quit: {}, close: {}), size: NSSize(width: 380, height: 640))
        longQuick.fitHeight(width: 380)
        try await longQuick.settle()
        try expect(longQuick.host.bounds.height <= 720, "long partial result keeps compact quick-panel height")
        try longQuick.verify("quick-long-partial", labels: [L("仍未完成："), L("打开 Folioak")], snapshots: snapshots)
        longQuick.window.close()
        partialQuick.smart.cancel()
        partial.smartInput.cancel()
        print("PASS smart input native UI: bilingual light/dark review, two output formats, unmet requirements, minimum main window, compact quick panel, settings, progress and errors")
    }
}
