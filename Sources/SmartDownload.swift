import Foundation
import Combine

// UI sessions are separate from the download queue. A session ends at durable
// acceptance; cancellation after that point belongs to the existing queue.
@MainActor final class SmartDownloadState: ObservableObject {
    @Published private(set) var progress: SmartProgress?
    @Published private(set) var resolution: SmartResolution?
    @Published var selections: [SmartSelection] = []
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    var resolving: Bool { progress != nil }
    var inheritedFormat: MediaFormat { defaultFormat }
    private weak var model: DownloadModel?
    private let quick: Bool
    private let resolver: SmartResolving
    private var worker: Task<Void, Never>?
    private var sessionID: UUID?
    private var original = ""
    private var defaultFormat = MediaFormat.automatic
    private var onAccepted: ((Bool) -> Void)?
    private var subscriptions = Set<AnyCancellable>()

    init(model: DownloadModel, quick: Bool = false, resolver: SmartResolving? = nil) {
        self.model = model; self.quick = quick
        self.resolver = resolver ?? model.smartResolver
        model.smartCancellation.sink { [weak self] in self?.cancel() }.store(in: &subscriptions)
        model.smartSettings.$enabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.cancel() }
        }.store(in: &subscriptions)
        model.smartSettings.$hasKey.dropFirst().sink { [weak self] present in
            if !present { self?.cancel() }
        }.store(in: &subscriptions)
    }

    deinit { worker?.cancel() }

    func submit(_ input: String, onAccepted: ((Bool) -> Void)? = nil) {
        cancel()
        guard let model, !model.isTerminating else { return }
        do {
            guard model.smartSettings.enabled else { throw DownloadError.limit("请先在设置中启用智能输入。") }
            guard !model.cancelling, quick || !model.busy else { throw DownloadError.limit("正在下载，请稍后再试。") }
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.utf8.count <= SmartInput.inputLimit else { throw DownloadError.limit("智能请求请控制在 8 KB 以内。") }
            let key = try model.smartSettings.apiKey()
            let id = UUID()
            sessionID = id; original = input; defaultFormat = model.mediaFormat
            self.onAccepted = onAccepted; progress = .understanding
            let resolver = self.resolver
            worker = Task { [weak self] in
                do {
                    let result = try await resolver.resolve(input, apiKey: key) { [weak self] phase in
                        Task { @MainActor [weak self] in
                            guard self?.sessionID == id, self?.resolving == true else { return }
                            self?.progress = phase
                        }
                    }
                    guard let self, self.sessionID == id, !Task.isCancelled,
                          self.model?.isTerminating == false, self.model?.smartSettings.enabled == true else { return }
                    self.worker = nil; self.progress = nil
                    self.resolution = result; self.selections = result.selections
                    // Discovery is reviewed even if the model asks to auto-submit.
                    let review = result.needsReview || !result.unresolved.isEmpty ||
                        result.candidates.contains { $0.origin != .supplied }
                    if review {
                        self.message = result.candidates.isEmpty && result.unresolved.isEmpty
                            ? "未找到可下载的资源，请补充线索后重试。" : nil
                    } else { self.acceptSelection() }
                } catch {
                    guard let self, self.sessionID == id, !Task.isCancelled else { return }
                    self.worker = nil; self.progress = nil; self.failed = true
                    // Resolver and settings errors have bounded, user-safe messages.
                    self.message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription; failed = true }
    }

    func inputChanged(_ input: String) {
        if sessionID != nil && input != original { cancel() }
    }

    func cancel() {
        sessionID = nil
        worker?.cancel(); worker = nil; progress = nil
        resolution = nil; selections = []; message = nil; failed = false; onAccepted = nil
    }

    func acceptSelection() {
        guard let model, let result = resolution, let id = sessionID, !resolving, !selections.isEmpty else { return }
        do {
            let receipt = try model.submitSmartDownload(result, selections: selections, sessionID: id,
                                                       quick: quick, defaultFormat: defaultFormat)
            let completion = onAccepted
            // Invalidate before invoking callbacks that can change the draft.
            sessionID = nil; onAccepted = nil; resolution = nil; selections = []; failed = false
            completion?(result.unresolved.isEmpty)
            var parts: [String] = []
            if receipt.accepted > 0 { parts.append(L("已加入 \(receipt.accepted) 项")) }
            if receipt.skipped > 0 { parts.append(L("已有 \(receipt.skipped) 项，已跳过")) }
            if receipt.duplicates > 0 { parts.append(L("队列中已有 \(receipt.duplicates) 项")) }
            if !result.unresolved.isEmpty {
                parts.append(L("仍未完成：") + result.unresolved.map { L($0) }.joined(separator: "；"))
            }
            message = parts.joined(separator: " · ")
        } catch { failed = true; message = error.localizedDescription }
    }

    func canSelect(_ candidate: SmartCandidate) -> Bool {
        resolution?.allowsSelection(of: candidate) == true &&
            selections.count + selectionOptions(for: candidate).count <= SmartInput.targetLimit
    }

    private func selectionOptions(for candidate: SmartCandidate) -> [SmartSelection] {
        let proposed = resolution?.selections ?? []
        let original = proposed.filter { $0.candidateID == candidate.id }
        if !original.isEmpty { return original }
        // Only additional user-supplied links inherit common proposal options.
        let formats = Set(proposed.map(\.format))
        return [SmartSelection(candidateID: candidate.id, format: formats.count == 1 ? proposed[0].format : .inherit,
                               skipExisting: !proposed.isEmpty && proposed.allSatisfy(\.skipExisting))]
    }

    func setSelected(_ candidate: SmartCandidate, selected: Bool) {
        if selected, !selections.contains(where: { $0.candidateID == candidate.id }), canSelect(candidate) {
            selections += selectionOptions(for: candidate)
        } else if !selected { selections.removeAll { $0.candidateID == candidate.id } }
    }
}
