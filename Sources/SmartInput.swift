import Foundation

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
}

struct SmartSelection: Equatable, Sendable {
    let candidateID: String
    var format: SmartFormat
    var skipExisting: Bool
}

struct SmartResolution: Sendable {
    let candidates: [SmartCandidate]
    let selections: [SmartSelection]
    let unresolved: [String]
    let needsReview: Bool
    let modelCalls: Int
    let toolCalls: Int

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

enum SmartProgress: Sendable {
    case understanding, searching, reading, checking
    var label: String {
        switch self {
        case .understanding: return "正在理解请求…"
        case .searching: return "正在查找资源…"
        case .reading: return "正在读取页面…"
        case .checking: return "正在核对候选…"
        }
    }
}

protocol SmartResolving {
    func resolve(_ input: String, apiKey: String,
                 progress: @escaping @Sendable (SmartProgress) -> Void) async throws -> SmartResolution
}

enum SmartInput {
    static let targetLimit = 10
    static let inputLimit = 8 * 1024
    static let deadline: TimeInterval = 15
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
