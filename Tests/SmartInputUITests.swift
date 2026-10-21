import AppKit
import SwiftUI
import Vision

private final class SmartUICredentials: SmartCredentialStorage {
    private var value: String?
    private(set) var reads = 0
    private(set) var writes = 0
    func read() throws -> String? { reads += 1; return value }
    func write(_ key: String) throws { writes += 1; value = key }
    func delete() throws { value = nil }
}

private actor SmartUIConnectionValidator: SmartCredentialValidating {
    var suspended = false
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(suspended: Bool = false) { self.suspended = suspended }
    func validate(_ key: String) async throws {
        calls += 1
        if suspended { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct SmartUIResolver: SmartResolving {
    enum Mode { case review, pending, failure }
    static let pendingQuery = "Attention Is All You Need PDF"
    let result: SmartResolution
    var mode = Mode.review
    func resolve(_ input: String, apiKey: String, thinking: SmartThinkingEffort,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution {
        if mode == .failure { throw SmartResolverError.unavailable }
        if mode == .pending {
            progress(.searchingQuery("transformer original paper"))
            progress(.readingSource("https://arxiv.org/abs/1706.03762?access=private-fixture"))
            progress(.checkingSources(2))
            progress(.searchingQuery(Self.pendingQuery))
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return result
    }
}

private actor SmartUIRecordingResolver: SmartResolving {
    private(set) var calls = 0
    func resolve(_ input: String, apiKey: String, thinking: SmartThinkingEffort,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution {
        calls += 1
        return SmartResolution(candidates: [], selections: [], unresolved: [],
                               needsReview: true, modelCalls: 0, toolCalls: 0)
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

private struct SmartUIHeldDownload: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        throw CancellationError()
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        throw CancellationError()
    }
}

private final class SmartUIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor private final class SmartUISurface {
    let host: NSHostingView<AnyView>
    let window: NSPanel
    init(_ view: some View, size: NSSize) {
        host = NSHostingView(rootView: AnyView(view))
        window = SmartUIPanel(contentRect: NSRect(origin: .zero, size: size),
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
    func verifyVisibleQueueRow() throws {
        let rows = Self.descendants(host).compactMap { $0 as? FileRowClickRegion.Region }
            .filter { !$0.isControls && !$0.isHiddenOrHasHiddenAncestor }
        try expect(rows.contains { $0.visibleRect.height >= 24 && $0.visibleRect.width >= 80 },
                   "the minimum window keeps a real download row visible below the input panel")
    }
    func scrollDetailsToEnd() async throws {
        guard let scroll = Self.descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.height <= 112 && $0.bounds.height >= 80 &&
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 10
        }), let document = scroll.documentView else {
            throw TestFailure.failed("expanded details have a bounded native scroll region")
        }
        let y = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
    }
    static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func image(in view: NSView? = nil) throws -> NSBitmapImageRep {
        let view = view ?? host
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw TestFailure.failed("smart UI bitmap allocation")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    func verify(_ name: String, labels: [String], uniqueLabels: [String] = [],
                absentLabels: [String] = [], snapshots: Bool, in view: NSView? = nil) throws {
        let bitmap = try image(in: view)
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
    func enterKey(_ key: String, in view: NSView? = nil) async throws {
        let surface = view ?? host
        try expect(surface.window?.isVisible == true, "connection typing window is mounted and visible")
        try await settle()
        guard let field = Self.descendants(surface).compactMap({ $0 as? NSSecureTextField })
            .first(where: { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor &&
                $0.placeholderString == L("DeepSeek API Key") && $0.window === surface.window }) else {
            throw TestFailure.failed("connection form has a visible enabled native secure API key field with its exact localized placeholder")
        }
        field.window?.makeKeyAndOrderFront(nil)
        field.selectText(nil)
        // Returning to a mounted settings tab establishes a new focus binding.
        // Let that native focus event finish before simulating text input.
        try await settle()
        guard let editor = field.currentEditor() as? NSTextView else {
            throw TestFailure.failed("connection secure field has its native editor")
        }
        try expect(field.window?.firstResponder === editor, "native key entry targets the focused secure editor")
        editor.insertText(key, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }
    func returnKey(in view: NSView? = nil) async throws {
        guard let targetWindow = (view ?? host).window, targetWindow.isVisible,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWindow.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw TestFailure.failed("connection Return key event")
        }
        let focusedSecureEditor = Self.descendants(view ?? host).compactMap { $0 as? NSSecureTextField }
            .contains { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor &&
                $0.window === targetWindow && $0.currentEditor() is NSTextView &&
                $0.currentEditor() === targetWindow.firstResponder }
        try expect(focusedSecureEditor,
                   "native connection Return targets the focused secure editor; key=\(NSApp.keyWindow === targetWindow), active=\(NSApp.isActive), responder=\(String(describing: targetWindow.firstResponder.map { type(of: $0) }))")
        // Exercise the real window/field-editor key route. macOS may refuse to
        // activate this CLI test host; global application activation is not part
        // of a window-local SecureField submission.
        targetWindow.sendEvent(event)
        try await settle()
    }
    func press(_ label: String, in view: NSView? = nil) async throws {
        let view = view ?? host
        guard let image = try image(in: view).cgImage, let targetWindow = view.window else {
            throw TestFailure.failed("connection control surface is visible")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        func normalized(_ value: String) -> String {
            String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let observations = request.results ?? []
        let exact = observations.first(where: {
            normalized($0.topCandidates(1).first?.string ?? "") == normalized(label)
        })?.boundingBox
        // Vision may group a disclosure chevron or a neighboring button into
        // the same text line. Click only the requested label's own bounds.
        let labelBounds = try observations.compactMap { observation -> CGRect? in
            guard let recognized = observation.topCandidates(1).first,
                  let range = recognized.string.range(of: label) else { return nil }
            return try recognized.boundingBox(for: range)?.boundingBox
        }
        guard let box = exact ?? (labelBounds.count == 1 ? labelBounds.first : nil) else {
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
            throw TestFailure.failed("visible action: \(label); actual: \(text)")
        }
        let point = NSPoint(x: box.midX * view.bounds.width,
                            y: (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height)
        targetWindow.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            targetWindow.sendEvent(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: targetWindow.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await settle()
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
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-smart-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
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
        func makeModel(_ mode: SmartUIResolver.Mode = .review, resolution: SmartResolution? = nil,
                       transport: any HTTPTransport = SmartUINoNetwork()) -> DownloadModel {
            let model = DownloadModel(engine: DownloadEngine(transport: transport, pdfTransport: transport,
                                                 requestInterval: 0, retryDelay: 0),
                          preferences: preferences, opener: { _ in false }, smartSettings: settings,
                          smartResolver: SmartUIResolver(result: resolution ?? result, mode: mode))
            model.directory = fixtureRoot.appendingPathComponent(UUID().uuidString)
            return model
        }
        func waitForReview(_ state: SmartDownloadState) async throws {
            for _ in 0..<100 {
                if state.resolution != nil { return }
                if state.failed { throw TestFailure.failed("smart UI fixture resolver failed") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw TestFailure.failed("smart UI fixture resolver did not complete")
        }
        func waitForFixture(_ ready: () -> Bool) async throws {
            for _ in 0..<200 {
                if ready() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw TestFailure.failed("the controlled resolver did not reach its requested snapshot state")
        }
        // Replay the real search table through the resolver before rendering.
        // A hand-polished candidate would miss the original filename/evidence bug.
        let paperResult = try await smartPaperPresentationFixture()
        let subjectiveResult = try await smartSubjectivePresentationFixture()
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
                                  labels: [L("下载 3 项"), L("还有 2 项待补充"), L("修改需求")],
                                  absentLabels: [L("已有的跳过")], snapshots: snapshots)
                let scrolls = SmartUISurface.descendants(status.host).compactMap { $0 as? NSScrollView }
                try expect(!scrolls.isEmpty && scrolls.allSatisfy { $0.bounds.height <= 202 },
                           "review scroll regions stay bounded")
                status.window.close()

                let main = SmartUISurface(DownloaderView(model: model).environment(\.colorScheme, scheme),
                                          size: NSSize(width: 780, height: 540))
                try await main.settle()
                try expect(main.host.bounds.size == NSSize(width: 780, height: 540), "review keeps minimum main-window size")
                try main.verify("main-" + name, labels: [L("下载 3 项"), L("还有 2 项待补充"), L("修改需求"), L("视频"), L("仅音频")],
                                uniqueLabels: [L("下载 3 项")],
                                absentLabels: [L("已有的跳过"), L("添加资源"), L("粘贴链接，开始下载"), L("试试示例：Attention Is All You Need")],
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
                try quick.verify("quick-" + name, labels: [L("下载 3 项"), L("还有 2 项待补充"), L("打开 Folioak"), L("视频"), L("仅音频")],
                                 uniqueLabels: [L("下载 3 项")], absentLabels: [L("已有的跳过")], snapshots: snapshots)
                quick.window.close()
                quickState.smart.cancel()

                let configuration = SmartUISurface(SmartSettingsView(settings: settings, palette: palette)
                    .padding(16).background(ThemePalette.color(palette.canvas)).environment(\.colorScheme, scheme),
                    size: NSSize(width: 540, height: 380))
                try await configuration.settle()
                try configuration.verify("settings-" + name,
                                         labels: [L("已连接"), L("停用"), L("更换 Key"), L("移除 Key"),
                                                  L("思考强度"), L("关闭（省用量）")], snapshots: snapshots)
                try expect(!SmartUISurface.descendants(configuration.host).contains { $0 is NSSecureTextField },
                           "connected settings never display or read the saved credential")
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
                                                 L("已连接"), L("更换 Key"), L("移除 Key")], snapshots: snapshots)
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
                             "cdn.openai.com", L("下载文件"), L("修改需求"), "ReviewPapers", "Earlier saved paper"],
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

                let recommended = makeModel(resolution: subjectiveResult)
                recommended.language = selectedLanguage
                recommended.theme = .grove
                recommended.history = [DownloadItem(original: "https://example.org/earlier.pdf",
                    directURL: URL(string: "https://example.org/earlier.pdf"), state: .failed,
                    documentTitle: "Earlier saved paper", preservesInput: true)]
                recommended.input = "21世纪最牛逼的论文"
                recommended.start()
                try await waitForReview(recommended.smartInput)
                try expect(recommended.smartInput.resolution?.unresolved.isEmpty == true &&
                           recommended.smartInput.resolution?.notes.isEmpty == false,
                           "the real subjective-query resolver fixture separates recommendation guidance from missing work")
                let preview = SmartUISurface(DownloaderView(model: recommended).environment(\.colorScheme, scheme),
                                             size: NSSize(width: 780, height: 540))
                try await preview.settle()
                try preview.verify("subjective-main-" + name,
                    labels: ["Deep Residual Learning for Image Recognition", "arXiv 1512.03385", L("选择说明"),
                             L("下载文件"), "Earlier saved paper"],
                    absentLabels: [L("还有 1 项待补充"), L("添加资源")], snapshots: snapshots)
                try preview.verifyVisibleQueueRow()
                try await preview.press(L("选择说明"))
                try preview.verify("subjective-main-notes-" + name,
                    labels: subjectiveResult.notes + ["Earlier saved paper"], snapshots: snapshots)
                try preview.verifyVisibleQueueRow()
                preview.window.close()
                recommended.smartInput.cancel()
                let recommendedQuick = QuickDownloadState(model: recommended)
                recommendedQuick.draft = "21世纪最牛逼的论文"
                recommendedQuick.submit()
                try await waitForReview(recommendedQuick.smart)
                let quickPreview = SmartUISurface(QuickDownloadView(state: recommendedQuick, model: recommended,
                    openWindow: {}, openSettings: {}, quit: {}, close: {}).environment(\.colorScheme, scheme),
                    size: NSSize(width: 380, height: 540))
                quickPreview.fitHeight(width: 380)
                try await quickPreview.settle()
                try quickPreview.verify("subjective-quick-" + name,
                    labels: ["Deep Residual Learning for Image Recognition", L("选择说明"), L("下载文件")],
                    absentLabels: [L("还有 1 项待补充")], snapshots: snapshots)
                try await quickPreview.press(L("选择说明"))
                quickPreview.fitHeight(width: 380)
                try await quickPreview.settle()
                try expect(quickPreview.host.bounds.height <= 720, "expanded selection guidance keeps Quick compact")
                try quickPreview.verify("subjective-quick-notes-" + name,
                    labels: subjectiveResult.notes + [L("打开 Folioak")], snapshots: snapshots)
                quickPreview.window.close()
                recommendedQuick.smart.cancel()
            }
        }

        AppLocalization.shared.language = .chinese
        NSApp.appearance = NSAppearance(named: .aqua)
        for stage in ["idle", "progress", "error", "postaccept"] {
            for useQuick in [false, true] {
                let mode: SmartUIResolver.Mode = stage == "progress" ? .pending : stage == "error" ? .failure : .review
                let transport: any HTTPTransport
                if stage == "postaccept" { transport = SmartUIHeldDownload() }
                else { transport = SmartUINoNetwork() }
                let model = makeModel(mode, resolution: subjectiveResult, transport: transport)
                model.language = .chinese
                model.theme = .grove
                model.history = [DownloadItem(original: "https://example.org/earlier.pdf",
                    directURL: URL(string: "https://example.org/earlier.pdf"), state: .failed,
                    documentTitle: "Earlier saved paper", preservesInput: true)]
                let quick = QuickDownloadState(model: model)
                let state = useQuick ? quick.smart : model.smartInput
                let original = "21世纪最牛逼的论文"
                model.input = useQuick ? "主窗口未提交的草稿" : original
                quick.draft = original
                if stage != "idle" {
                    if useQuick { quick.submit() } else { model.start() }
                    if stage == "progress" || stage == "error" {
                        try await waitForFixture {
                            stage == "progress" ? state.progress == .searchingQuery(SmartUIResolver.pendingQuery) : state.failed
                        }
                    }
                    if stage == "postaccept" {
                        try await waitForReview(state)
                        if useQuick { quick.submit() } else { model.start() }
                        try expect(model.busy && model.items.count == 1 && state.resolution == nil &&
                                   state.remainingRequirements.isEmpty && (useQuick ? quick.draft.isEmpty : model.input.isEmpty),
                                   "confirmed recommendations clear fulfilled input and hand progress to the queue")
                    }
                }
                let surface: SmartUISurface
                if useQuick {
                    surface = SmartUISurface(QuickDownloadView(state: quick, model: model,
                        openWindow: {}, openSettings: {}, quit: {}, close: {}), size: NSSize(width: 380, height: 640))
                    surface.fitHeight(width: 380)
                } else {
                    surface = SmartUISurface(DownloaderView(model: model), size: NSSize(width: 780, height: 540))
                }
                try await surface.settle()
                let name = (useQuick ? "quick-" : "main-") + stage
                let labels: [String]
                switch stage {
                case "idle": labels = [L("查找资源"), "Earlier saved paper"]
                case "progress": labels = [L("正在查找资源…"), SmartUIResolver.pendingQuery, L("检索步骤"), L("取消")]
                case "error": labels = [L("未能完成查找"), L("重试"), original]
                default: labels = ["Deep Residual", L("停止")]
                }
                try surface.verify(name, labels: labels,
                    absentLabels: [L("添加资源")] + (stage == "postaccept" ? [original, L("选择说明")] : []),
                    snapshots: snapshots)
                if useQuick {
                    try expect(surface.host.bounds.height <= 720, "full Quick state remains within its compact height limit")
                } else {
                    try expect(surface.host.bounds.size == NSSize(width: 780, height: 540),
                               "full smart-input state keeps the minimum main-window size")
                    try surface.verifyVisibleQueueRow()
                    if stage == "idle" || stage == "error" {
                        let editor = SmartUISurface.descendants(surface.host).compactMap { $0 as? LinkTextView }.first
                        try expect(editor?.font?.pointSize == 13 && editor?.string == original,
                                   "idle and recoverable errors retain the native 13-point request editor")
                    }
                }
                if stage == "progress" {
                    try await surface.press(L("检索步骤"))
                    if useQuick { surface.fitHeight(width: 380); try await surface.settle() }
                    try surface.verify(name + "-activity", labels: ["transformer original paper", "arxiv.org", L("取消")],
                        absentLabels: ["private-fixture"], snapshots: snapshots)
                    if useQuick { try expect(surface.host.bounds.height <= 720, "expanded retrieval activity keeps Quick compact") }
                    else { try surface.verifyVisibleQueueRow() }
                }
                surface.window.close()
                state.cancel()
                await model.cancelAndWait()
            }
        }
        for language in [AppLanguage.chinese, .english] {
            let pending = makeModel(.pending)
            pending.language = language
            pending.input = "查找论文及附件"
            pending.start()
            try await waitForFixture { pending.smartInput.progress == .searchingQuery(SmartUIResolver.pendingQuery) }
            let progress = SmartUISurface(SmartInputStatusView(state: pending.smartInput,
                palette: pending.theme.palette(dark: false), compact: true).padding(12)
                    .background(ThemePalette.color(pending.theme.palette(dark: false).surface)),
                size: NSSize(width: 380, height: 90))
            progress.fitHeight(width: 380)
            try await progress.settle()
            try expect(pending.smartInput.resolving, "pending UI fixture remains cancellable")
            try progress.verify("progress-" + language.rawValue,
                labels: [L("正在查找资源…"), SmartUIResolver.pendingQuery, L("检索步骤"), L("取消")],
                absentLabels: ["arxiv.org", "transformer original paper", "private-fixture"], snapshots: snapshots)
            try await progress.press(L("检索步骤"))
            progress.fitHeight(width: 380)
            try await progress.settle()
            try expect(progress.host.bounds.height <= 210, "expanded narrow activity has a bounded height")
            try progress.verify("progress-expanded-" + language.rawValue,
                labels: ["transformer original paper", "arxiv.org", L("官方资料"), L("取消")],
                absentLabels: ["private-fixture"], snapshots: snapshots)
            try await progress.press(L("取消"))
            try expect(!pending.smartInput.resolving && pending.smartInput.activityHistory.isEmpty && pending.input == "查找论文及附件",
                       "visible cancel clears session activity and preserves the request draft")
            progress.window.close()
        }
        AppLocalization.shared.language = .chinese

        let failed = makeModel(.failure)
        failed.input = "查找论文"
        failed.start()
        try await waitForFixture { failed.smartInput.failed }
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
        emptyReview.fitHeight(width: 380)
        try await emptyReview.settle()
        try expect(notFound.smartInput.message == nil && notFound.items.isEmpty,
                   "no-match result keeps a single explanation and never creates a queue")
        try emptyReview.verify("no-match", labels: ["未找到匹配的论文", L("修改需求")],
            absentLabels: [L("已选 0 / 10")], snapshots: snapshots)
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
            unresolved: (1...10).map {
                "要求 \($0)：" + String(repeating: "尚未确认补充材料的来源，请保留原请求以便继续核对。", count: 8) +
                ($0 == 10 ? " Final remaining requirement." : "")
            },
            needsReview: true, modelCalls: 1, toolCalls: 0)
        let partial = makeModel(resolution: longResult)
        // An existing queue item exercises acceptance without starting a worker.
        partial.items = [DownloadItem(original: candidates[1].url.absoluteString,
                                      directURL: candidates[1].url, state: .queued,
                                      documentTitle: "Already queued paper", preservesInput: true)]
        partial.input = "查找论文及全部补充材料"
        partial.start()
        try await waitForReview(partial.smartInput)
        partial.start()
        try expect(partial.smartInput.resolution == nil &&
                   partial.smartInput.remainingRequirements == longResult.unresolved &&
                   (partial.smartInput.message?.count ?? 0) < 100,
                   "long partial acceptance preserves every requirement outside its concise receipt")
        let longMain = SmartUISurface(DownloaderView(model: partial), size: NSSize(width: 780, height: 540))
        try await longMain.settle()
        try longMain.verify("main-long-partial",
            labels: [L("还有 10 项待补充"), "Already queued paper"],
            absentLabels: [L("添加资源"), "Final remaining requirement"], snapshots: snapshots)
        try expect(longMain.host.bounds.size == NSSize(width: 780, height: 540),
                   "long partial result keeps minimum main-window size")
        try longMain.verifyVisibleQueueRow()
        try await longMain.press(L("还有 10 项待补充"))
        try longMain.verify("main-long-partial-expanded", labels: ["要求 1", "Already queued paper"], snapshots: snapshots)
        try longMain.verifyVisibleQueueRow()
        try await longMain.scrollDetailsToEnd()
        try longMain.verify("main-long-partial-last-detail", labels: ["Final remaining requirement"], snapshots: snapshots)
        longMain.window.close()

        let partialQuick = QuickDownloadState(model: partial)
        partialQuick.draft = "查找论文及全部补充材料"
        partialQuick.submit()
        try await waitForReview(partialQuick.smart)
        partialQuick.submit()
        try expect(!partialQuick.draft.isEmpty && partialQuick.smart.remainingRequirements == longResult.unresolved &&
                   (partialQuick.smart.message?.count ?? 0) < 100,
                   "quick partial acceptance retains draft and complete requirements with a concise receipt")
        let longQuick = SmartUISurface(QuickDownloadView(state: partialQuick, model: partial, openWindow: {},
            openSettings: {}, quit: {}, close: {}), size: NSSize(width: 380, height: 640))
        longQuick.fitHeight(width: 380)
        try await longQuick.settle()
        try expect(longQuick.host.bounds.height <= 720, "long partial result keeps compact quick-panel height")
        try longQuick.verify("quick-long-partial", labels: [L("还有 10 项待补充"), L("打开 Folioak")],
                             absentLabels: ["Final remaining requirement"], snapshots: snapshots)
        try await longQuick.press(L("还有 10 项待补充"))
        longQuick.fitHeight(width: 380)
        try await longQuick.settle()
        try expect(longQuick.host.bounds.height <= 720, "expanded missing requirements keep Quick within its height limit")
        try longQuick.verify("quick-long-partial-expanded", labels: ["要求 1", L("打开 Folioak")], snapshots: snapshots)
        try await longQuick.scrollDetailsToEnd()
        try longQuick.verify("quick-long-partial-last-detail", labels: ["Final remaining requirement"], snapshots: snapshots)
        longQuick.window.close()
        partialQuick.smart.cancel()
        partial.smartInput.cancel()
        try await smartConnectionUITests(snapshots: snapshots)
        print("PASS smart input native UI: bilingual light/dark review, two output formats, unmet requirements, minimum main window, compact quick panel, settings, progress and errors")
    }

    @MainActor private static func smartConnectionUITests(snapshots: Bool) async throws {
        let suite = "folioak-smart-connection-ui-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "updates.automatic")
        preferences.set(false, forKey: "showsMenuBarIcon")
        let palette = AppTheme.grove.palette(dark: false)
        AppLocalization.shared.language = .english
        NSApp.appearance = NSAppearance(named: .aqua)
        let credentials = SmartUICredentials()
        let validator = SmartUIConnectionValidator()
        let settings = SmartSettings(preferences, credentials: credentials, validator: validator)
        var connected = 0
        let form = SmartUISurface(SmartConnectionForm(settings: settings, palette: palette,
            continuesRequest: true, onConnected: { connected += 1 }, onCancel: {})
            .padding(20).frame(width: 380), size: NSSize(width: 380, height: 280))
        form.fitHeight(width: 380)
        try await form.settle()
        try expect(SmartUISurface.descendants(form.host).compactMap { $0 as? NSSecureTextField }
            .contains { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor &&
                $0.placeholderString == L("DeepSeek API Key") },
                   "new connection presents the exact API key placeholder in a native secure input")
        try form.verify("connection-new-key", labels: [L("获取 Key"), L("连接并继续"), L("取消")],
                        snapshots: snapshots)
        try expect(credentials.reads == 0 && credentials.writes == 0 && !settings.enabled,
                   "opening connection never reads, saves or enables a credential")
        try await form.enterKey("sk-ui-native-entry")
        try await form.settle()
        try await form.returnKey()
        try expect(settings.hasKey && settings.enabled && credentials.writes == 1 && connected == 1,
                   "native SecureField and Connect validate, save, enable and continue once")
        settings.enabled = false
        try await form.settle()
        try expect(!SmartUISurface.descendants(form.host).contains { $0 is NSSecureTextField } && credentials.reads == 0,
                   "saved disabled connection does not expose or pre-read the key")
        try await form.press(L("连接并继续"))
        try expect(settings.enabled && credentials.reads == 1 && credentials.writes == 1 && connected == 2,
                   "saved-key connection validates without requiring entry or rewriting credentials")
        form.window.close()

        // These fixtures use the real sheets and native controls, with in-memory
        // credentials and an injected validator. They never reach Keychain or HTTP.
        try settings.clearKey()
        settings.enabled = false
        let pendingValidator = SmartUIConnectionValidator(suspended: true)
        let pendingCredentials = SmartUICredentials()
        let pendingSettings = SmartSettings(preferences, credentials: pendingCredentials, validator: pendingValidator)
        let emptyResult = SmartResolution(candidates: [], selections: [], unresolved: [],
                                          needsReview: true, modelCalls: 0, toolCalls: 0)
        func makeModel() -> DownloadModel {
            DownloadModel(engine: DownloadEngine(transport: SmartUINoNetwork(), pdfTransport: SmartUINoNetwork(),
                                                 requestInterval: 0, retryDelay: 0),
                preferences: preferences, opener: { _ in false }, smartSettings: pendingSettings,
                smartResolver: SmartUIResolver(result: emptyResult))
        }
        let configurationModel = makeModel()
        configurationModel.language = .english
        configurationModel.settingsTab = "智能输入"
        configurationModel.preferencesPage = .settings
        let configuration = SmartUISurface(DownloaderView(model: configurationModel),
                                          size: NSSize(width: 780, height: 540))
        try await configuration.settle()
        for leavesPage in [false, true] {
            configurationModel.preferencesPage = .settings
            configurationModel.settingsTab = "智能输入"
            try await configuration.settle()
            try await configuration.enterKey("sk-ui-cancel-before-save")
            try await configuration.settle()
            try configuration.verify("connection-settings-before-\(leavesPage)", labels: [L("连接")], snapshots: snapshots)
            try await configuration.press(L("连接"))
            let calls = await pendingValidator.calls
            try configuration.verify("connection-settings-after-\(leavesPage)", labels: [], snapshots: snapshots)
            try expect(calls == (leavesPage ? 2 : 1), "native connection starts validation; leavesPage=\(leavesPage), calls=\(calls)")
            if leavesPage { configurationModel.preferencesPage = nil }
            else { configurationModel.settingsTab = "通用" }
            try await configuration.settle()
            try expect(SmartUISurface.descendants(configuration.host).compactMap { $0 as? NSSecureTextField }
                .allSatisfy { $0.stringValue.isEmpty }, "leaving settings clears native temporary key text")
            await pendingValidator.release()
            try await configuration.settle()
            try expect(!pendingSettings.enabled && !pendingSettings.hasKey && pendingCredentials.writes == 0,
                       "hidden settings reject late validation even when validator ignores cancellation")
        }
        configuration.window.close()

        for language in [AppLanguage.chinese, .english] {
            let model = makeModel()
            model.language = language
            let scheme = language == .chinese ? ColorScheme.light : .dark
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let main = SmartUISurface(DownloaderView(model: model).environment(\.colorScheme, scheme),
                                      size: NSSize(width: 780, height: 540))
            try await main.settle()
            model.input = "下载 gpt-1 论文"
            model.start()
            try await main.settle()
            guard let sheet = main.window.attachedSheet?.contentView else {
                throw TestFailure.failed("first smart request presents the main connection sheet")
            }
            try expect(SmartUISurface.descendants(sheet).compactMap { $0 as? NSSecureTextField }
                .contains { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && $0.window === sheet.window &&
                    $0.placeholderString == L("DeepSeek API Key") &&
                    $0.currentEditor() != nil && $0.currentEditor() === sheet.window?.firstResponder },
                       "main setup gives the native secure field initial focus")
            try main.verify("connection-main-" + language.rawValue,
                labels: [L("获取 Key"), L("连接并继续"), L("取消")],
                snapshots: snapshots, in: sheet)
            try expect(sheet.bounds.width <= 420 && sheet.bounds.height < 400,
                       "main connection sheet remains compact and all actions fit")
            try await main.press(L("取消"), in: sheet)
            try expect(!model.smartInput.needsSetup && model.input == "下载 gpt-1 论文",
                       "cancelling the actual main sheet preserves the request")
            main.window.close()

            let quickState = QuickDownloadState(model: model)
            quickState.draft = "下载 gpt-1 论文"
            let quick = SmartUISurface(QuickDownloadView(state: quickState, model: model,
                openWindow: {}, openSettings: {}, quit: {}, close: {}).environment(\.colorScheme, scheme),
                size: NSSize(width: 380, height: 540))
            try await quick.settle()
            quickState.submit()
            try await quick.settle()
            guard let quickSheet = quick.window.attachedSheet?.contentView else {
                throw TestFailure.failed("first quick request presents its connection sheet")
            }
            try expect(SmartUISurface.descendants(quickSheet).compactMap { $0 as? NSSecureTextField }
                .contains { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && $0.window === quickSheet.window &&
                    $0.placeholderString == L("DeepSeek API Key") &&
                    $0.currentEditor() != nil && $0.currentEditor() === quickSheet.window?.firstResponder },
                       "quick setup focuses the secure field instead of the request editor")
            try quick.verify("connection-quick-" + language.rawValue,
                labels: [L("获取 Key"), L("连接并继续"), L("取消")],
                snapshots: snapshots, in: quickSheet)
            try expect(quickSheet.bounds.width <= 380 && quickSheet.bounds.height < 400,
                       "quick connection sheet keeps every action within its narrow surface")
            try await quick.press(L("取消"), in: quickSheet)
            try expect(!quickState.smart.needsSetup && quickState.draft == "下载 gpt-1 论文",
                       "cancelling the actual quick sheet preserves the request")
            quick.window.close()
        }

        // A real transient menu popover retains its hosting tree after closing.
        // Its delegate, not only SwiftUI onDisappear, must invalidate setup.
        let menuCredentials = SmartUICredentials()
        let menuValidator = SmartUIConnectionValidator(suspended: true)
        let menuSettings = SmartSettings(preferences, credentials: menuCredentials, validator: menuValidator)
        let menuResolver = SmartUIRecordingResolver()
        let menuModel = DownloadModel(
            engine: DownloadEngine(transport: SmartUINoNetwork(), pdfTransport: SmartUINoNetwork(),
                                   requestInterval: 0, retryDelay: 0),
            preferences: preferences, opener: { _ in false },
            smartSettings: menuSettings, smartResolver: menuResolver)
        menuModel.language = .english
        menuModel.showsMenuBarIcon = true
        let controller = MenuBarController(model: menuModel, openWindow: {}, openSettings: {}, quit: {})
        defer {
            controller.popover.close()
            menuModel.showsMenuBarIcon = false
            Task { await menuValidator.release() }
        }
        try await form.settle()
        controller.togglePopover()
        try await form.settle()
        guard let popoverContent = controller.popover.contentViewController?.view,
              let editor = SmartUISurface.descendants(popoverContent)
                .compactMap({ $0 as? QuickLinkEditor.Editor }).first,
              let popoverWindow = popoverContent.window else {
            throw TestFailure.failed("real menu popover mounts its native request editor")
        }
        try expect(controller.popover.isShown && controller.popover.behavior == .transient,
                   "connection regression uses the actual transient menu popover")
        editor.insertText("Find the GPT-1 paper", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popoverWindow.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        try expect(editor.performKeyEquivalent(with: submit), "real menu request submits with Command Return")
        try await form.settle()
        try expect(controller.popover.isShown && controller.state.smart.needsSetup,
                   "presenting the connection sheet does not dismiss its transient popover")
        guard let menuSheet = popoverWindow.attachedSheet?.contentView else {
            throw TestFailure.failed("real menu popover presents its connection sheet")
        }
        try form.verify("connection-menu-popover",
            labels: [L("连接 DeepSeek"), L("获取 Key"), L("连接并继续"), L("取消")],
            snapshots: snapshots, in: menuSheet)
        try await form.enterKey("sk-ui-menu-cancelled", in: menuSheet)
        try await form.settle()
        try await form.returnKey(in: menuSheet)
        let validationCalls = await menuValidator.calls
        try expect(validationCalls == 1 && controller.popover.isShown && controller.state.smart.needsSetup,
                   "menu sheet validation starts without closing the transient popover")
        controller.popover.performClose(nil)
        try await form.settle()
        try expect(!controller.popover.isShown && !controller.state.smart.needsSetup
                   && controller.state.draft == "Find the GPT-1 paper",
                   "closing the real popover cancels setup immediately and preserves its draft")
        await menuValidator.release()
        try await form.settle()
        let resolverCalls = await menuResolver.calls
        try expect(!menuSettings.hasKey && !menuSettings.enabled && menuCredentials.writes == 0
                   && resolverCalls == 0 && menuModel.items.isEmpty,
                   "a late menu validation cannot save, enable, resolve or enqueue after popover close")
    }
}
