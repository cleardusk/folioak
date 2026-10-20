import Foundation

private final class SmartInputCredentials: SmartCredentialStorage {
    private var key: String?
    func read() throws -> String? { key }
    func write(_ key: String) throws { self.key = key }
    func delete() throws { key = nil }
}

// Deliberately ignores cancellation: the UI must reject late results even when
// a transport cannot stop a response already on its way.
private actor DelayedSmartResolver: SmartResolving {
    private(set) var inputs: [String] = []
    private var pending: [Int: CheckedContinuation<SmartResolution, Never>] = [:]
    func resolve(_ input: String, apiKey: String,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution {
        let index = inputs.count
        inputs.append(input)
        progress(.understanding)
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, with result: SmartResolution) {
        pending.removeValue(forKey: index)?.resume(returning: result)
    }
}

private actor SmartInputTransport: HTTPTransport {
    let pdf: URL
    var suspended = false
    private(set) var requests: [URL] = []
    init(pdf: URL) { self.pdf = pdf }
    func suspend() { suspended = true }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
    func download(for request: URLRequest,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        requests.append(request.url!)
        while suspended { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.copyItem(at: pdf, to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/pdf"])!)
    }
}

extension CoreTests {
    @MainActor private static func awaitSmart(_ ready: () async -> Bool) async throws {
        let end = ContinuousClock().now.advanced(by: .seconds(3))
        while !(await ready()) {
            if ContinuousClock().now >= end { throw TestFailure.failed("intelligent input fixture timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor static func smartInputTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-smart-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "folioak-smart-input-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let credentials = SmartInputCredentials()
        let settings = SmartSettings(preferences, credentials: credentials)
        try settings.saveKey("sk-isolated-smart-input-fixture")
        settings.enabled = true
        let pdf = root.appendingPathComponent("fixture.pdf")
        try createPDF(at: pdf)

        for input in ["https://example.org/paper.pdf", "1706.03762v1\nBV1MaHp6KENU",
                      "https://example.org/download?token=a,b;c%2Bd"] {
            try expect(SmartInput.isDirect(input), "unambiguous addresses remain local")
        }
        for input in ["找作者是某某的那篇论文", "https://example.org/paper.pdf 只要第二个",
                      "[Attention](https://arxiv.org/abs/1706.03762)",
                      "https://example.org/movie.mp4，只要音频"] {
            try expect(!SmartInput.isDirect(input), "prose and conditions retain intelligent routing")
        }
        let prose = "  这两个链接，只要第二个的音频：\nhttps://example.org/a.mp4\nhttps://example.org/b.mp4  "
        let captureModel = DownloadModel(preferences: preferences, smartSettings: settings)
        try expect(try captureModel.captureInput(prose) == prose, "enabled capture retains full original intent and whitespace")
        settings.enabled = false
        try expect(try captureModel.captureInput(prose) == PaperInput.captured(prose), "disabled capture retains legacy parsing")
        settings.enabled = true
        try rejects({ _ = try captureModel.captureInput(String(repeating: "x", count: ResourceLimits.inputBytes + 1)) },
                    "capture remains bounded before any network request")

        func proposal(_ path: String = "paper.pdf", review: Bool = false, unresolved: [String] = []) -> SmartResolution {
            SmartResolution(candidates: [
                SmartCandidate(id: "c1", title: "Fixture", url: URL(string: "https://example.org/" + path)!,
                               detail: "fixture", origin: review ? .search : .supplied)
            ], selections: [SmartSelection(candidateID: "c1", format: .inherit, skipExisting: false)],
               unresolved: unresolved, needsReview: review, modelCalls: 1, toolCalls: review ? 1 : 0)
        }

        let directTransport = SmartInputTransport(pdf: pdf), directResolver = DelayedSmartResolver()
        let direct = DownloadModel(engine: DownloadEngine(transport: directTransport, pdfTransport: directTransport,
            requestInterval: 0, retryDelay: 0), preferences: preferences,
            smartSettings: settings, smartResolver: directResolver)
        direct.directory = root.appendingPathComponent("direct")
        direct.input = "https://example.org/direct.pdf"
        direct.start()
        try await waitForQueue(direct)
        try expect(await directResolver.inputs.isEmpty, "direct submission never calls the model")
        try expect(direct.successes == 1, "enabled intelligent mode preserves native direct downloads")

        for boundary in ["cancel", "edit", "disable", "quit"] {
            let resolver = DelayedSmartResolver(), transport = SmartInputTransport(pdf: pdf)
            let model = DownloadModel(engine: DownloadEngine(transport: transport, pdfTransport: transport,
                requestInterval: 0, retryDelay: 0), preferences: preferences,
                smartSettings: settings, smartResolver: resolver)
            model.directory = root.appendingPathComponent(boundary)
            settings.enabled = true
            model.input = "保存这个链接的论文 https://example.org/late.pdf"
            model.start()
            try await awaitSmart { await resolver.inputs.count == 1 }
            switch boundary {
            case "cancel": model.smartInput.cancel()
            case "edit":
                model.input = "新的未提交请求"
                model.smartInput.inputChanged(model.input)
            case "disable": settings.enabled = false
            default: model.beginTermination()
            }
            await resolver.complete(0, with: proposal("late.pdf"))
            try await Task.sleep(nanoseconds: 40_000_000)
            try expect(model.items.isEmpty && !model.busy && model.smartInput.resolution == nil,
                       "\(boundary) rejects a late resolver result before queue acceptance")
            try expect(await transport.requests.isEmpty, "\(boundary) prevents download side effects")
            model.smartInput.cancel()
        }
        settings.enabled = true

        // A completed response from an obsolete session must not replace a new
        // session's candidates, even if both used the same input text.
        let supersededResolver = DelayedSmartResolver()
        let superseded = DownloadModel(preferences: preferences, smartSettings: settings, smartResolver: supersededResolver)
        superseded.smartInput.submit("找论文")
        try await awaitSmart { await supersededResolver.inputs.count == 1 }
        superseded.smartInput.cancel()
        superseded.smartInput.submit("找论文")
        try await awaitSmart { await supersededResolver.inputs.count == 2 }
        await supersededResolver.complete(0, with: proposal("obsolete.pdf", review: true))
        try await Task.sleep(nanoseconds: 25_000_000)
        try expect(superseded.smartInput.resolving && superseded.smartInput.resolution == nil,
                   "old session cannot publish candidates into a new session")
        await supersededResolver.complete(1, with: proposal("current.pdf", review: true, unresolved: ["未找到补充材料"]))
        try await awaitSmart { superseded.smartInput.resolution != nil }
        try expect(superseded.smartInput.resolution?.candidates.first?.url.lastPathComponent == "current.pdf" &&
                   superseded.smartInput.resolution?.unresolved == ["未找到补充材料"] && superseded.items.isEmpty,
                   "discovery requires review and retains unresolved requirements")
        superseded.smartInput.cancel()

        let reviewTransport = SmartInputTransport(pdf: pdf), reviewResolver = DelayedSmartResolver()
        await reviewTransport.suspend()
        let reviewed = DownloadModel(engine: DownloadEngine(transport: reviewTransport, pdfTransport: reviewTransport,
            requestInterval: 0, retryDelay: 0), preferences: preferences,
            smartSettings: settings, smartResolver: reviewResolver)
        reviewed.directory = root.appendingPathComponent("reviewed")
        var acceptedCallbacks = 0
        reviewed.smartInput.submit("保存论文和补充材料", onAccepted: { complete in
            if !complete { acceptedCallbacks += 1 }
        })
        try await awaitSmart { await reviewResolver.inputs.count == 1 }
        await reviewResolver.complete(0, with: proposal("reviewed.pdf", review: true, unresolved: ["未找到补充材料"]))
        try await awaitSmart { reviewed.smartInput.resolution != nil }
        reviewed.smartInput.acceptSelection()
        reviewed.smartInput.acceptSelection()
        try expect(reviewed.items.count == 1 && acceptedCallbacks == 1 &&
                   reviewed.smartInput.message?.contains("未找到补充材料") == true,
                   "accepting a partial selection enqueues once and keeps unmet requirements visible")
        await reviewed.cancelAndWait()

        let actionResolver = DelayedSmartResolver(), actionTransport = SmartInputTransport(pdf: pdf)
        await actionTransport.suspend()
        let actionModel = DownloadModel(engine: DownloadEngine(transport: actionTransport, pdfTransport: actionTransport,
            requestInterval: 0, retryDelay: 0), preferences: preferences,
            smartSettings: settings, smartResolver: actionResolver)
        actionModel.directory = root.appendingPathComponent("review-actions")
        actionModel.input = "查找论文"
        actionModel.notice = "Previous direct-input error"
        actionModel.start()
        try expect(actionModel.notice == nil, "a new intelligent request clears obsolete main-window errors")
        try await awaitSmart { await actionResolver.inputs.count == 1 }
        let first = proposal("first.pdf", review: true), second = proposal("chosen.pdf", review: true)
        let choice = SmartCandidate(id: "chosen", title: "Chosen", url: second.candidates[0].url, detail: "", origin: .search)
        await actionResolver.complete(0, with: SmartResolution(candidates: first.candidates + [choice],
            selections: first.selections, unresolved: [], needsReview: true, modelCalls: 2, toolCalls: 1))
        try await awaitSmart { actionModel.smartInput.resolution != nil }
        actionModel.smartInput.selections = [SmartSelection(candidateID: "chosen", format: .inherit, skipExisting: true)]
        actionModel.start()
        let actionCalls = await actionResolver.inputs.count
        try expect(actionModel.items.first?.original == choice.url.absoluteString &&
                   actionCalls == 1,
                   "main primary action accepts the edited review without another model request")
        await actionModel.cancelAndWait()

        let quickResolver = DelayedSmartResolver(), quickTransport = SmartInputTransport(pdf: pdf)
        await quickTransport.suspend()
        let quickModel = DownloadModel(engine: DownloadEngine(transport: quickTransport, pdfTransport: quickTransport,
            requestInterval: 0, retryDelay: 0), preferences: preferences,
            smartSettings: settings, smartResolver: quickResolver)
        quickModel.directory = root.appendingPathComponent("quick-review")
        let quick = QuickDownloadState(model: quickModel)
        settings.enabled = false
        quick.draft = "查找论文和补充材料"
        quick.submit()
        try expect(quick.failed, "fixture begins with a rejected native request")
        settings.enabled = true
        quick.submit()
        try expect(!quick.failed && quick.message == nil && quick.resultError == nil,
                   "intelligent routing clears obsolete quick-panel errors")
        try await awaitSmart { await quickResolver.inputs.count == 1 }
        await quickResolver.complete(0, with: proposal("partial.pdf", review: true, unresolved: ["未找到补充材料"]))
        try await awaitSmart { quick.smart.resolution != nil }
        quick.submit()
        let quickCalls = await quickResolver.inputs.count
        try expect(quickModel.items.count == 1 && quick.draft == "查找论文和补充材料" &&
                   quick.smart.message?.contains("未找到补充材料") == true && quickCalls == 1,
                   "quick primary action accepts once and keeps the original request when requirements remain")
        await quickModel.cancelAndWait()
        quick.draft = "查找论文"
        quick.submit()
        try await awaitSmart { await quickResolver.inputs.count == 2 }
        await quickResolver.complete(1, with: proposal("complete.pdf", review: true))
        try await awaitSmart { quick.smart.resolution != nil }
        quick.submit()
        try expect(quick.draft.isEmpty && quickModel.items.count == 1,
                   "fully resolved quick acceptance clears the submitted draft")
        await quickModel.cancelAndWait()

        let blockedParent = root.appendingPathComponent("blocked-parent")
        try Data("not a directory".utf8).write(to: blockedParent)
        let blockedTransport = SmartInputTransport(pdf: pdf)
        let blocked = DownloadModel(engine: DownloadEngine(transport: blockedTransport, pdfTransport: blockedTransport,
            requestInterval: 0, retryDelay: 0), preferences: preferences,
            stateURL: blockedParent.appendingPathComponent("workspace.json"), smartSettings: settings)
        blocked.input = "原请求保持可重试"
        let blockedResult = proposal("never.pdf")
        try rejects({
            _ = try blocked.submitSmartDownload(blockedResult, selections: blockedResult.selections,
                sessionID: UUID(), quick: false, defaultFormat: .automatic)
        }, "failed persistence rejects structured submission")
        try expect(blocked.items.isEmpty && !blocked.busy && blocked.input == "原请求保持可重试",
                   "failed acceptance preserves queue and draft")
        try expect(await blockedTransport.requests.isEmpty, "failed commit never starts transport")

        // Effective output format participates in active identity. Source-only
        // deduplication would incorrectly discard the requested second format.
        let mediaEngine = DownloadEngine(mediaDownload: { _, _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw CancellationError()
        })
        let mediaState = root.appendingPathComponent("formats/workspace.json")
        let media = DownloadModel(engine: mediaEngine, preferences: preferences, stateURL: mediaState,
                                  smartSettings: settings)
        media.directory = root.appendingPathComponent("formats-output")
        let videoCandidate = SmartCandidate(id: "v1", title: "Video",
            url: URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!, detail: "", origin: .supplied)
        let mediaResult = SmartResolution(candidates: [videoCandidate], selections: [], unresolved: [],
                                         needsReview: false, modelCalls: 1, toolCalls: 0)
        let sessionID = UUID()
        let audioSelection = [SmartSelection(candidateID: "v1", format: .inherit, skipExisting: false)]
        let audio = try media.submitSmartDownload(mediaResult, selections: audioSelection,
            sessionID: sessionID, quick: true, defaultFormat: .audio)
        let videoSelection = [SmartSelection(candidateID: "v1", format: .video, skipExisting: false)]
        let video = try media.submitSmartDownload(mediaResult, selections: videoSelection,
            sessionID: UUID(), quick: true, defaultFormat: .audio)
        try expect(audio.accepted == 1 && video.accepted == 1 &&
                   Set(media.items.compactMap(\.mediaFormat)) == Set([MediaFormat.audio, .automatic]),
                   "same source accepts audio and explicit video independently")
        let previousIDs = media.items.map(\.id)
        _ = try? media.submitSmartDownload(mediaResult, selections: audioSelection,
            sessionID: sessionID, quick: true, defaultFormat: .audio)
        _ = try? media.submitSmartDownload(mediaResult, selections: videoSelection,
            sessionID: UUID(), quick: true, defaultFormat: .audio)
        try expect(media.items.map(\.id) == previousIDs, "duplicate session and equivalent active format cannot enqueue twice")
        media.mediaFormat = .automatic
        await media.cancelAndWait()
        let restored = DownloadModel(preferences: preferences, stateURL: mediaState, smartSettings: settings)
        try expect(restored.items.compactMap(\.mediaFormat) == [.audio, .automatic] && !restored.busy,
                   "effective per-item formats survive restart without resuming network")

        let mixed = DownloadModel(engine: mediaEngine, preferences: preferences, smartSettings: settings)
        mixed.directory = root.appendingPathComponent("mixed-native-smart")
        _ = try mixed.submitSmartDownload(mediaResult, selections: audioSelection,
            sessionID: UUID(), quick: true, defaultFormat: .audio)
        mixed.mediaFormat = .automatic
        let nativeCount = try mixed.submitQuickDownload(videoCandidate.url.absoluteString)
        try expect(nativeCount == 1 && mixed.items.compactMap(\.mediaFormat) == [.audio, .automatic],
                   "native quick video submission is not discarded by an active smart audio download")
        try rejects({ _ = try mixed.submitQuickDownload(videoCandidate.url.absoluteString) },
                    "equivalent native video submission still deduplicates")
        await mixed.cancelAndWait()

        let frozenResolver = DelayedSmartResolver()
        let frozen = DownloadModel(engine: mediaEngine, preferences: preferences,
            smartSettings: settings, smartResolver: frozenResolver)
        frozen.directory = root.appendingPathComponent("frozen-format")
        frozen.mediaFormat = .audio
        frozen.smartInput.submit("保存这个视频 https://www.youtube.com/watch?v=aaaaaaaaaaa")
        try await awaitSmart { await frozenResolver.inputs.count == 1 }
        frozen.mediaFormat = .automatic
        await frozenResolver.complete(0, with: SmartResolution(candidates: [videoCandidate], selections: audioSelection,
            unresolved: [], needsReview: false, modelCalls: 1, toolCalls: 0))
        try await awaitSmart { !frozen.items.isEmpty }
        try expect(frozen.items.first?.mediaFormat == .audio,
                   "inherit uses the preference snapshot from submission, not a later setting change")
        await frozen.cancelAndWait()

        let skipTransport = SmartInputTransport(pdf: pdf)
        await skipTransport.suspend()
        let skip = DownloadModel(engine: DownloadEngine(transport: skipTransport, pdfTransport: skipTransport,
            requestInterval: 0, retryDelay: 0), preferences: preferences, smartSettings: settings)
        skip.directory = root.appendingPathComponent("skip")
        let saved = root.appendingPathComponent("already-saved.pdf")
        try FileManager.default.copyItem(at: pdf, to: saved)
        let savedURL = URL(string: "https://example.org/saved.pdf")!
        let old = DownloadItem(original: savedURL.absoluteString, directURL: savedURL,
            state: .saved, savedURL: saved, documentTitle: "Saved fixture")
        skip.papers = [LibraryPaper(old)]
        let skipResult = proposal("saved.pdf")
        let skipSelection = [SmartSelection(candidateID: "c1", format: .inherit, skipExisting: true)]
        let alreadySaved = try skip.submitSmartDownload(skipResult, selections: skipSelection,
            sessionID: UUID(), quick: true, defaultFormat: .automatic)
        try expect(alreadySaved.accepted == 0 && alreadySaved.skipped == 1 && skip.items.isEmpty,
                   "existing verified local output satisfies skip without enqueuing")
        try FileManager.default.removeItem(at: saved)
        let missing = try skip.submitSmartDownload(skipResult, selections: skipSelection,
            sessionID: UUID(), quick: true, defaultFormat: .automatic)
        try expect(missing.accepted == 1 && missing.skipped == 0,
                   "stale saved record cannot skip a missing file")
        await skip.cancelAndWait()

        let savedReference = try ArxivReference.parse("1706.03762v1")
        for identifier in ["1706.03762v1", "1706.03762v2", "1706.03762"] {
            let transport = SmartInputTransport(pdf: pdf)
            let versioned = DownloadModel(engine: DownloadEngine(transport: transport, pdfTransport: transport,
                requestInterval: 0, retryDelay: 0), preferences: preferences, smartSettings: settings)
            versioned.directory = root.appendingPathComponent("version-" + identifier)
            let record = DownloadItem(original: "1706.03762", reference: try ArxivReference.parse("1706.03762"),
                metadata: PaperMetadata(reference: savedReference, title: "Saved v1", year: 2017, month: 6),
                state: .saved, savedURL: pdf)
            versioned.papers = [LibraryPaper(record)]
            let result = SmartResolution(candidates: [
                SmartCandidate(id: "a1", title: "Paper", url: try ArxivReference.parse(identifier).abstractURL,
                               detail: "", origin: .supplied)
            ], selections: [], unresolved: [], needsReview: false, modelCalls: 1, toolCalls: 0)
            let receipt = try versioned.submitSmartDownload(result,
                selections: [SmartSelection(candidateID: "a1", format: .inherit, skipExisting: true)],
                sessionID: UUID(), quick: true, defaultFormat: .automatic)
            try expect(receipt.skipped == (identifier == "1706.03762v1" ? 1 : 0) &&
                       receipt.accepted == (identifier == "1706.03762v1" ? 0 : 1),
                       "local skip requires exact requested arXiv version; bare/latest must still resolve")
            await versioned.cancelAndWait()
        }

        print("PASS intelligent input: local routing, preserved intent, stale/cancelled/disabled/quit responses, candidate review, durable acceptance, per-item formats, session deduplication, restart and existing-file checks")
    }
}
