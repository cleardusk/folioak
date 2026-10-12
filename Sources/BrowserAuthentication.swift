import Foundation

// This is an explicit opt-in to yt-dlp's browser-cookie reader. It never reads
// browser files itself, and callers (including the CLI) are anonymous by default.
enum CookieBrowser: String, Codable, CaseIterable, Sendable {
    case chrome, safari, firefox, edge, brave, chromium, vivaldi, opera

    var label: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .chromium: return "Chromium"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        }
    }

    // Safari's PROFILE argument is a cookie-file path; Opera ignores profiles.
    // Neither is exposed as a profile-name input here.
    var supportsProfile: Bool { self != .safari && self != .opera }
}

struct BrowserAuthenticationSelection: Equatable, Sendable {
    let browser: CookieBrowser
    let profile: String?

    init(browser: CookieBrowser, profile: String? = nil) throws {
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            // A basename is enough for Chromium and Firefox profiles. Do not
            // accept paths, yt-dlp's keyring/container syntax, or shell-like input.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
            guard browser.supportsProfile, trimmed.utf8.count <= 128,
                  trimmed != ".", trimmed != "..", !trimmed.hasPrefix("-"),
                  trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  profile?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true else {
                throw DownloadError.browserAuthentication(.invalidSelection)
            }
        } else if profile?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) == true {
            throw DownloadError.browserAuthentication(.invalidSelection)
        }
        self.browser = browser
        self.profile = trimmed.isEmpty ? nil : trimmed
    }

    var argument: String { browser.rawValue + (profile.map { ":" + $0 } ?? "") }
}

struct BrowserAuthenticationPreferences {
    // Kept out of workspace/history exports. Only a browser choice and optional
    // profile name are stored; never Cookie contents or arbitrary filesystem paths.
    enum Key {
        static let enabled = "browserAuthentication.enabled"
        static let browser = "browserAuthentication.browser"
        static let profile = "browserAuthentication.profile"
    }

    private let preferences: UserDefaults
    init(_ preferences: UserDefaults) { self.preferences = preferences }

    var enabled: Bool { preferences.object(forKey: Key.enabled) as? Bool ?? false }

    func configuredSelection() throws -> BrowserAuthenticationSelection? {
        guard let raw = preferences.string(forKey: Key.browser) else { return nil }
        guard let browser = CookieBrowser(rawValue: raw) else {
            throw DownloadError.browserAuthentication(.invalidSelection)
        }
        if let value = preferences.object(forKey: Key.profile), !(value is String) {
            throw DownloadError.browserAuthentication(.invalidSelection)
        }
        return try BrowserAuthenticationSelection(browser: browser, profile: preferences.string(forKey: Key.profile))
    }

    func activeSelection() throws -> BrowserAuthenticationSelection? {
        guard enabled else { return nil }
        guard let selection = try configuredSelection() else {
            throw DownloadError.browserAuthentication(.invalidSelection)
        }
        return selection
    }

    func select(_ selection: BrowserAuthenticationSelection) {
        preferences.set(selection.browser.rawValue, forKey: Key.browser)
        if let profile = selection.profile { preferences.set(profile, forKey: Key.profile) }
        else { preferences.removeObject(forKey: Key.profile) }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled, try configuredSelection() == nil {
            throw DownloadError.browserAuthentication(.invalidSelection)
        }
        preferences.set(enabled, forKey: Key.enabled)
    }

    func clear() {
        preferences.removeObject(forKey: Key.enabled)
        preferences.removeObject(forKey: Key.browser)
        preferences.removeObject(forKey: Key.profile)
    }
}

// Reading cookies is distinct from a site accepting the account's session.
enum BrowserAuthenticationReadState: Equatable, Sendable {
    case ready, reading, read, empty, failed, rejected

    func message(for browser: CookieBrowser) -> DiagnosticMessage {
        let id: DiagnosticMessage.ID
        switch self {
        case .ready: id = .browserAuthReady
        case .reading: id = .browserAuthReading
        case .read: id = .browserAuthRead
        case .empty: id = .browserAuthEmpty
        case .failed: id = .browserAuthReadStatusFailed
        case .rejected: id = .browserAuthRejected
        }
        return DiagnosticMessage(id, browser.label)
    }
}

enum BrowserAuthenticationIssue: Sendable {
    case invalidSelection, readFailed, sessionRejected, loginRequired

    var message: DiagnosticMessage {
        switch self {
        case .invalidSelection: return DiagnosticMessage(.browserAuthInvalidSelection)
        case .readFailed: return DiagnosticMessage(.browserAuthReadFailed)
        case .sessionRejected: return DiagnosticMessage(.browserAuthSessionRejected)
        case .loginRequired: return DiagnosticMessage(.browserAuthLoginRequired)
        }
    }

    static func matches(_ message: DiagnosticMessage?) -> Bool {
        guard let id = message?.id else { return false }
        return [Self.invalidSelection, .readFailed, .sessionRejected, .loginRequired].contains { $0.message.id == id }
    }

    // yt-dlp currently exposes these failures as text. Classify known diagnostics
    // conservatively and return fixed messages; never retain raw paths or cookies.
    static func readFailure(in raw: String) -> Self? {
        let lower = raw.lowercased()
        let cookieFailure = lower.contains("cookie") && ["could not find", "could not copy", "could not read", "unable to",
                                                          "failed to", "permission denied", "operation not permitted", "could not be decrypted"]
            .contains(where: lower.contains)
        if cookieFailure || lower.contains("find-generic-password failed") ||
            lower.contains("exception running find-generic-password") ||
            lower.contains("failed to decrypt") || lower.contains("cookies.binarycookies") && lower.contains("permission") {
            return .readFailed
        }
        return nil
    }
}
