import Foundation

enum DownloadError: LocalizedError {
    case invalidLink(String)
    case metadata(String)
    case http(Int, retryAfter: Double?)
    case cooldown(Double)
    case invalidPDF
    case storage(String)
    case limit(String)
    case unsafeResponse
    case coordination(String)
    case browserAuthentication(BrowserAuthenticationIssue)

    var message: DiagnosticMessage {
        switch self {
        case .invalidLink: return DiagnosticMessage(.invalidInput)
        case .metadata(let detail): return DiagnosticMessage(.metadata, detail)
        case .limit(let detail): return DiagnosticMessage(.limit, detail)
        case .coordination(let detail): return DiagnosticMessage(.coordination, detail)
        case .browserAuthentication(let issue): return issue.message
        case .http(let code, _):
            switch code {
            case 403: return DiagnosticMessage(.forbidden)
            case 404: return DiagnosticMessage(.notFound)
            case 429: return DiagnosticMessage(.rateLimited)
            default: return DiagnosticMessage(.http, String(code))
            }
        case .cooldown(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= ResourceLimits.retryAfterSeconds else {
                return DiagnosticMessage(.unknownCooldown)
            }
            return DiagnosticMessage(.cooldown, String(format: "%.0f", max(1, ceil(seconds / 60))))
        case .invalidPDF: return DiagnosticMessage(.invalidPDF)
        case .storage(let detail): return DiagnosticMessage(.storage, detail)
        case .unsafeResponse: return DiagnosticMessage(.unsafeResponse)
        }
    }

    // Preserve the CLI and older callers' source-language error descriptions.
    var errorDescription: String? { message.fallback }
}

extension DiagnosticMessage {
    static func downloadFailure(_ error: Error) -> DiagnosticMessage {
        if let failure = error as? DownloadError { return failure.message }
        if let network = error as? URLError {
            if [.cannotCreateFile, .cannotOpenFile, .cannotWriteToFile].contains(network.code) {
                return DiagnosticMessage(.temporaryStorage)
            }
            if network.code == .timedOut { return DiagnosticMessage(.networkTimeout) }
            return DiagnosticMessage(.networkFailure, network.localizedDescription)
        }
        return DiagnosticMessage(.metadata, error.localizedDescription)
    }
}
