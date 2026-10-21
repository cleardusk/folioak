import Foundation

enum SmartThinkingEffort: String, CaseIterable, Sendable {
    case off, low, high, max

    var label: String {
        switch self {
        case .off: return "关闭（省用量）"
        case .low: return "低"
        case .high: return "高"
        case .max: return "最高"
        }
    }
    var deadline: TimeInterval {
        switch self { case .off: return 25; case .low: return 35; case .high: return 50; case .max: return 75 }
    }
    var maxOutputTokens: Int {
        switch self { case .off: return 1200; case .low: return 2400; case .high: return 4800; case .max: return 8000 }
    }
}

// The model proposes a selection. Only DownloadModel can accept a download.
enum SmartFormat: String, Codable, Sendable, CaseIterable {
    case inherit, video, audio
    func resolved(default value: MediaFormat) -> MediaFormat {
        switch self { case .inherit: return value; case .video: return .automatic; case .audio: return .audio }
    }
}

struct SmartCandidate: Identifiable, Equatable, Sendable {
    enum Origin: String, Sendable { case supplied, search, page }
    let id: String
    let title: String
    let url: URL
    let detail: String
    let origin: Origin
    // A literal title observed in this resource's evidence, not model metadata.
    let observedTitle: String?

    init(id: String, title: String, url: URL, detail: String, origin: Origin, observedTitle: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.detail = detail
        self.origin = origin; self.observedTitle = observedTitle
    }
}

struct SmartSelection: Equatable, Sendable {
    let candidateID: String
    var format: SmartFormat
    var skipExisting: Bool
}

// API-reported counts only. Missing or incomplete usage is not estimated.
struct SmartTokenUsage: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cacheHitTokens: Int?
}

struct SmartResolution: Sendable {
    let candidates: [SmartCandidate]
    let selections: [SmartSelection]
    let unresolved: [String]
    let needsReview: Bool
    let modelCalls: Int
    let toolCalls: Int
    let usage: SmartTokenUsage?
    let notes: [String]

    init(candidates: [SmartCandidate], selections: [SmartSelection], unresolved: [String],
         needsReview: Bool, modelCalls: Int, toolCalls: Int, usage: SmartTokenUsage? = nil, notes: [String] = []) {
        self.candidates = candidates; self.selections = selections; self.unresolved = unresolved
        self.needsReview = needsReview; self.modelCalls = modelCalls; self.toolCalls = toolCalls
        self.usage = usage
        self.notes = notes
    }

    // Search observations are not download choices until the resolver has
    // matched them. User-supplied links remain available for manual selection.
    func allowsSelection(of candidate: SmartCandidate) -> Bool {
        candidates.contains(candidate) &&
            (candidate.origin == .supplied || selections.contains { $0.candidateID == candidate.id })
    }
}

struct SmartSubmission {
    let accepted: Int
    let skipped: Int
    let duplicates: Int
}

enum SmartProgress: Sendable, Equatable {
    case understanding, searching, reading, checking
    case searchingQuery(String), readingSource(String), checkingSources(Int)
    var label: String {
        switch self {
        case .understanding: return "正在理解请求…"
        case .searching, .searchingQuery: return "正在查找资源…"
        case .reading, .readingSource: return "正在读取页面…"
        case .checkingSources: return "正在读取官方资料…"
        case .checking: return "正在核对候选…"
        }
    }

    var detail: String? {
        switch self {
        case .searchingQuery(let query): return query
        case .readingSource(let source): return source
        case .checkingSources(let count): return L("\(count) 篇论文")
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .searching, .searchingQuery: return "magnifyingglass"
        case .reading, .readingSource: return "globe"
        case .checkingSources: return "doc.text.magnifyingglass"
        case .understanding, .checking: return "sparkle"
        }
    }

    // Only tool actions belong in the visible activity history. Thinking and
    // semantic decisions remain the agent's private work.
    var isToolAction: Bool {
        switch self {
        case .searchingQuery, .readingSource, .checkingSources: return true
        default: return false
        }
    }
}

protocol SmartResolving {
    func resolve(_ input: String, apiKey: String, thinking: SmartThinkingEffort,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution
}

extension SmartResolving {
    func resolve(_ input: String, apiKey: String,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution {
        try await resolve(input, apiKey: apiKey, thinking: .off, progress: progress)
    }
}

enum SmartInput {
    static let targetLimit = 10
    static let modelCallLimit = 5
    static let readCallLimit = 4
    static let candidateLimit = 90
    static let inputLimit = 8 * 1024
    static let deadline = SmartThinkingEffort.off.deadline
    private static let attachedCommand = try! NSRegularExpression(
        pattern: #"[，。；！？：](?=(?:只要|只下载|只保存|只取|仅|请|下载|保存|跳过|已有|不要|帮我|提取|获取|音频|视频|把这个|把这些|但|并|还要))"#)

    // Literal punctuation is valid in URL paths and query values. Only clear
    // adjacent commands are separated; percent-encoded punctuation is untouched.
    static func separatingCommands(_ input: String) -> String {
        attachedCommand.stringByReplacingMatches(in: input,
            range: NSRange(location: 0, length: (input as NSString).length), withTemplate: " ")
    }

    // Extracting links is safe only after the entire input has been classified.
    // Prose, including Markdown labels, goes through the intent path.
    static func isDirect(_ input: String) -> Bool {
        guard separatingCommands(input) == input else { return false }
        let tokens = DownloadSource.tokens(in: input)
        return !tokens.isEmpty && tokens.allSatisfy { (try? DownloadSource.parse($0)) != nil }
    }

    static func preserved(_ input: String) throws -> String {
        guard input.utf8.count <= ResourceLimits.inputBytes else {
            throw DownloadError.limit("输入超过 64 KB，请分批导入。")
        }
        return input.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    }
}
