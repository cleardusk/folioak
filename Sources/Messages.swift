import Foundation

// Stable identifiers and arguments accompany the existing text so old app
// versions can still read records, and unknown future identifiers stay readable.
struct DiagnosticMessage: Codable, Equatable, Sendable {
    let id: String
    let arguments: [String]
    let fallback: String

    enum ID: String, CaseIterable {
        case invalidInput = "download.invalid_input"
        case metadata = "download.metadata"
        case forbidden = "download.http.forbidden"
        case notFound = "download.http.not_found"
        case rateLimited = "download.http.rate_limited"
        case http = "download.http"
        case cooldown = "download.cooldown"
        case unknownCooldown = "download.cooldown.unknown"
        case invalidPDF = "download.invalid_pdf"
        case invalidFile = "download.invalid_file"
        case invalidFileDirectory = "download.invalid_file_directory"
        case webPage = "download.web_page"
        case storage = "download.storage"
        case limit = "download.limit"
        case unsafeResponse = "download.unsafe_response"
        case coordination = "download.coordination"
        case queued = "state.queued"
        case coordinating = "state.coordinating"
        case fetchingMetadata = "state.metadata"
        case checkingLocal = "state.checking_local"
        case downloading = "state.downloading"
        case validating = "state.validating"
        case retrying = "state.retrying"
        case waiting = "state.waiting"
        case paused = "state.paused"
        case saved = "state.saved"
        case existing = "state.existing"
        case failed = "state.failed"
        case cancelled = "state.cancelled"
        case missing = "state.missing"
        case redownload = "queue.redownload"
        case start = "queue.start"
        case startDeduplicated = "queue.start_deduplicated"
        case retry = "queue.retry"
        case cancelling = "queue.cancelling"
        case interrupted = "queue.interrupted"
        case restored = "queue.restored"
        case finished = "queue.finished"
        case preparing = "queue.preparing"
        case paperMetadata = "queue.paper_metadata"
        case siteCooldown = "queue.site_cooldown"
        case networkTimeout = "download.network.timeout"
        case networkFailure = "download.network.failure"
        case temporaryStorage = "download.storage.temporary"
        case localMissing = "queue.local_missing"
        case browserAuthReady = "browser_auth.status.ready"
        case browserAuthReading = "browser_auth.status.reading"
        case browserAuthRead = "browser_auth.status.read"
        case browserAuthEmpty = "browser_auth.status.empty"
        case browserAuthReadStatusFailed = "browser_auth.status.failed"
        case browserAuthRejected = "browser_auth.status.rejected"
        case browserAuthInvalidSelection = "browser_auth.invalid_selection"
        case browserAuthReadFailed = "browser_auth.read_failed"
        case browserAuthSessionRejected = "browser_auth.session_rejected"
        case browserAuthLoginRequired = "browser_auth.login_required"
        case browserAuthFreshCookiesRequired = "browser_auth.fresh_cookies_required"
        case browserAuthFallbackStarted = "browser_auth.fallback.started"
        case browserAuthFallbackSucceeded = "browser_auth.fallback.succeeded"
        case browserAuthFallbackFailed = "browser_auth.fallback.failed"
        case browserAuthFallbackCancelled = "browser_auth.fallback.cancelled"
        case douyinAnonymous = "media.douyin.anonymous"

        var template: String {
            switch self {
            case .invalidInput: return "无法识别：请输入论文、支持站点的视频链接，或 HTTPS 文件直链。"
            case .metadata: return "%@"
            case .forbidden: return "下载站点拒绝访问（403），可能需要登录或浏览器验证。"
            case .notFound: return "下载站点未找到文件或指定版本（404）。"
            case .rateLimited: return "下载站点暂时限流（429），请稍后重试。"
            case .http: return "下载站点返回 HTTP %@，请稍后重试。"
            case .cooldown: return "arXiv 要求暂停请求，请约 %@ 分钟后重试。"
            case .unknownCooldown: return "arXiv 要求暂停请求，请稍后重试。"
            case .invalidPDF: return "收到的文件不是完整、可读的 PDF，未保存。"
            case .invalidFile: return "文件内容与格式不符或文件已损坏，未保存。"
            case .invalidFileDirectory: return "无法读取文件目录，文件可能损坏或过于复杂。"
            case .webPage: return "收到的是网页而不是文件，请使用文件的直接下载链接。"
            case .storage: return "保存失败：%@"
            case .limit: return "%@"
            case .unsafeResponse: return "连接或重定向不符合安全 HTTPS 要求，已停止请求。"
            case .coordination: return "%@"
            case .queued: return "等待下载"
            case .coordinating: return "等待其他下载任务"
            case .fetchingMetadata: return "获取信息"
            case .checkingLocal: return "检查本地文件"
            case .downloading: return "下载中"
            case .validating: return "校验并保存"
            case .retrying: return "自动重试 %@/3"
            case .waiting: return "等待请求 · %@ 后继续"
            case .paused: return "等待重试"
            case .saved: return "已保存"
            case .existing: return "文件已存在"
            case .failed: return "下载失败"
            case .cancelled: return "已取消"
            case .missing: return "文件不存在"
            case .redownload: return "重新下载"
            case .start: return "开始下载 · %@ 项"
            case .startDeduplicated: return "开始下载 · %@ 项 · 去重 %@ 条"
            case .retry: return "重试 %@ 项"
            case .cancelling: return "正在取消下载"
            case .interrupted: return "上次下载中断，可重试。"
            case .restored: return "已恢复 %@ 项未完成任务"
            case .finished: return "本批结束 · 已保存 %@ · 失败 %@"
            case .preparing: return "准备下载"
            case .paperMetadata: return "获取论文信息"
            case .siteCooldown: return "下载站点要求暂停请求，可在 %@ 后重试。"
            case .networkTimeout: return "连接超时，自动重试后仍未成功。请检查网络后重试。"
            case .networkFailure: return "网络连接失败：%@"
            case .temporaryStorage: return "临时文件无法写入，请检查磁盘空间和权限。"
            case .localMissing: return "本地文件不存在"
            case .browserAuthReady: return "%@ · 已启用，下载时读取"
            case .browserAuthReading: return "%@ · 正在读取 Cookie"
            case .browserAuthRead: return "%@ · Cookie 已读取"
            case .browserAuthEmpty: return "%@ · 未找到 Cookie"
            case .browserAuthReadStatusFailed: return "%@ · Cookie 读取失败"
            case .browserAuthRejected: return "%@ · 站点未接受此会话"
            case .browserAuthInvalidSelection: return "浏览器认证设置无效，请重新选择浏览器和配置名称。"
            case .browserAuthReadFailed: return "无法读取浏览器认证。请确认浏览器已安装、所选配置存在，并检查 macOS 钥匙串或文件访问权限后重试。"
            case .browserAuthSessionRejected: return "站点未接受浏览器会话。请在所选浏览器中打开原链接，确认可播放并完成站点验证，再重试。"
            case .browserAuthLoginRequired: return "此内容需要登录或站点验证。可在设置中选择浏览器认证，先在该浏览器确认链接可访问，再重试。"
            case .browserAuthFreshCookiesRequired: return "站点要求新的 Cookie，不一定需要登录。请在所选浏览器打开原链接，完成验证后重试。"
            case .browserAuthFallbackStarted: return "认证失败，正在匿名重试一次。"
            case .browserAuthFallbackSucceeded: return "匿名重试成功，文件已验证并保存。"
            case .browserAuthFallbackFailed: return "匿名重试也未完成，请查看最终错误。"
            case .browserAuthFallbackCancelled: return "匿名重试已取消。"
            case .douyinAnonymous: return "使用抖音匿名解析，不读取浏览器 Cookie。"
            }
        }
    }

    static func formatted(_ template: String, arguments: [String]) -> String? {
        let parts = template.components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return nil }
        return zip(arguments, parts.dropFirst()).reduce(parts[0]) { $0 + $1.0 + $1.1 }
    }
}

extension DiagnosticMessage {
    init(_ id: ID, _ arguments: String...) {
        self.id = id.rawValue
        self.arguments = arguments
        fallback = Self.formatted(id.template, arguments: arguments) ?? id.template
    }
}
