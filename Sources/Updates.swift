import Foundation
import Combine
import AppKit

struct AppVersion: Comparable {
    let components: [Int]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), String(value) == part else { return nil }
            values.append(value)
        }
        components = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct AppRelease: Equatable {
    let version: String
    let notes: String
    var pageURL: URL { URL(string: "https://github.com/cleardusk/folioak/releases/tag/v\(version)")! }

    static func decode(_ data: Data) throws -> Self {
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let state: String; let size: Int }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let published_at: String?
            let body: String?
            let assets: [Asset]
        }
        guard data.count <= UpdateHTTPClient.maximumBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.draft, !payload.prerelease, payload.published_at != nil,
              payload.tag_name.hasPrefix("v") else { throw UpdateCheckError.invalidRelease }
        let version = String(payload.tag_name.dropFirst())
        guard AppVersion(version) != nil,
              payload.assets.contains(where: {
                  ["Folioak-v\(version)-macos-arm64.dmg", "Folioak-v\(version)-macos-arm64.zip"].contains($0.name)
                      && $0.state == "uploaded" && $0.size > 0
              }) else { throw UpdateCheckError.invalidRelease }
        // Release notes are bounded plain text; no HTML, scripts or remote links are rendered.
        let notes = (payload.body ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(6).joined(separator: "\n")
        return Self(version: version, notes: String(notes.prefix(600)))
    }
}

enum UpdateCheckError: Error {
    case invalidRelease, invalidResponse, http(Int), rateLimited(Date)

    var message: String {
        switch self {
        case .invalidRelease: return L("发布信息不完整或格式有误，请稍后重试。")
        case .invalidResponse: return L("更新服务返回了无效响应，请稍后重试。")
        case .http(let code): return String(format: L("更新服务暂不可用（HTTP %@），请稍后重试。"), String(code))
        case .rateLimited(let date): return String(format: L("GitHub 更新接口暂时限流，同一网络可能共用请求额度。可在 %@ 后重试，或现在打开发布页查看。"), L10n.date(date))
        }
    }
}

// Only public release metadata is fetched. Never use browser credentials or shared cookies.
final class UpdateHTTPClient: NSObject, URLSessionTaskDelegate {
    static let endpoint = URL(string: "https://api.github.com/repos/cleardusk/folioak/releases/latest")!
    static let releasePage = URL(string: "https://github.com/cleardusk/folioak/releases/latest")!
    static let maximumBytes = 512 * 1024

    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) async throws -> (Data, HTTPURLResponse) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: UpdateHTTPClient(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == endpoint,
              response.expectedContentLength <= maximumBytes else { throw UpdateCheckError.invalidResponse }
        guard response.statusCode == 200 else { return (Data(), response) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw UpdateCheckError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UpdateNotice: Equatable {
    enum Result: Equatable { case available(AppRelease), current, failed(String) }
    let result: Result
    let manual: Bool
}

@MainActor
final class UpdateChecker: ObservableObject {
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let interval: TimeInterval = 24 * 60 * 60
    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    @Published var automaticallyChecks: Bool {
        didSet {
            preferences.set(automaticallyChecks, forKey: "updates.automatic")
            if !automaticallyChecks, notice?.manual == false { notice = nil }
        }
    }
    @Published private(set) var isChecking = false
    @Published private(set) var notice: UpdateNotice?
    let currentVersion: String
    private let preferences: UserDefaults
    private let fetch: Fetch
    private let now: () -> Date
    private var manualRequested = false
    private struct Cache: Codable { let etag: String?; let data: Data }

    init(preferences: UserDefaults, currentVersion: String? = nil,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = { try await UpdateHTTPClient.fetch($0) }) {
        self.preferences = preferences
        self.currentVersion = currentVersion ?? Self.installedVersion
        self.now = now
        self.fetch = fetch
        automaticallyChecks = preferences.object(forKey: "updates.automatic") as? Bool ?? true
    }

    func dismiss(skip version: String? = nil) {
        if let version { preferences.set(version, forKey: "updates.skippedVersion") }
        notice = nil
    }

    func check(manual: Bool = false) async {
        if isChecking { manualRequested = manualRequested || manual; return }
        let date = now()
        let retry = preferences.object(forKey: "updates.retryAfter") as? Date
        if !manual {
            guard automaticallyChecks, notice == nil else { return }
            // A persisted server cooldown also overrides 2.6.0's longer backoff.
            if retry == nil, let next = preferences.object(forKey: "updates.nextCheck") as? Date, date < next { return }
        }
        if let retry, date < retry {
            if manual { notice = UpdateNotice(result: .failed(UpdateCheckError.rateLimited(retry).message), manual: true) }
            return
        }
        preferences.removeObject(forKey: "updates.retryAfter")
        isChecking = true
        manualRequested = manual
        notice = nil
        // Persist before requesting so relaunches and repeated failures do not hammer the API.
        preferences.set(date.addingTimeInterval(Self.interval), forKey: "updates.nextCheck")
        defer { isChecking = false; manualRequested = false }
        do {
            guard let current = AppVersion(currentVersion) else { throw UpdateCheckError.invalidRelease }
            let saved = preferences.data(forKey: "updates.cache").flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            let cache = saved.flatMap { (try? AppRelease.decode($0.data)) == nil ? nil : $0 }
            var request = URLRequest(url: UpdateHTTPClient.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Folioak/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard response.url == UpdateHTTPClient.endpoint else { throw UpdateCheckError.invalidResponse }
            let release: AppRelease
            switch response.statusCode {
            case 200:
                release = try AppRelease.decode(data)
                let updated = Cache(etag: response.value(forHTTPHeaderField: "ETag"), data: data)
                preferences.set(try JSONEncoder().encode(updated), forKey: "updates.cache")
            case 304:
                guard let cache else { throw UpdateCheckError.invalidResponse }
                release = try AppRelease.decode(cache.data)
            case 403, 429:
                guard response.statusCode == 429 || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                        || response.value(forHTTPHeaderField: "Retry-After") != nil else { throw UpdateCheckError.http(403) }
                let retry = Self.retryDate(response, now: date)
                preferences.set(retry, forKey: "updates.retryAfter")
                throw UpdateCheckError.rateLimited(retry)
            default: throw UpdateCheckError.http(response.statusCode)
            }
            preferences.removeObject(forKey: "updates.retryAfter")
            preferences.removeObject(forKey: "updates.failures")
            let manual = manualRequested
            guard manual || automaticallyChecks else { return }
            if AppVersion(release.version)! > current {
                if manual || preferences.string(forKey: "updates.skippedVersion") != release.version {
                    notice = UpdateNotice(result: .available(release), manual: manual)
                }
            } else if manual {
                notice = UpdateNotice(result: .current, manual: true)
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case UpdateCheckError.rateLimited(let retry) = error {
                // A shared-IP limit is not a repeated service failure. Resume at
                // the server deadline instead of postponing checks for days.
                preferences.set(retry, forKey: "updates.nextCheck")
            } else {
                let failures = min(max(preferences.integer(forKey: "updates.failures"), 0), 3) + 1
                preferences.set(failures, forKey: "updates.failures")
                let delay = Self.interval * min(pow(2, Double(failures - 1)), 7)
                preferences.set(date.addingTimeInterval(delay), forKey: "updates.nextCheck")
            }
            if manualRequested {
                let message = (error as? UpdateCheckError)?.message ?? L("无法连接更新服务，请检查网络后重试。")
                notice = UpdateNotice(result: .failed(message), manual: true)
            }
        }
    }

    private static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date {
        var retry = now.addingTimeInterval(60)
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(value), seconds.isFinite {
                retry = max(retry, now.addingTimeInterval(max(0, seconds)))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: value) { retry = max(retry, date) }
            }
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = TimeInterval(value), seconds.isFinite {
            retry = max(retry, Date(timeIntervalSince1970: seconds))
        }
        return retry
    }
}

@MainActor
enum UpdatePresentation {
    static func respond(to notice: UpdateNotice, response: NSApplication.ModalResponse,
                        checker: UpdateChecker, open: (URL) -> Bool) -> NSAlert? {
        let target: URL
        switch notice.result {
        case .available(let release):
            checker.dismiss(skip: response == .alertThirdButtonReturn ? release.version : nil)
            target = release.pageURL
        case .failed:
            checker.dismiss()
            target = UpdateHTTPClient.releasePage
        case .current:
            checker.dismiss(); return nil
        }
        guard response == .alertFirstButtonReturn, !open(target) else { return nil }
        let failure = NSAlert()
        failure.messageText = L("无法打开下载页")
        failure.informativeText = target.absoluteString
        failure.addButton(withTitle: L("好"))
        return failure
    }

    static func alert(for notice: UpdateNotice, currentVersion: String) -> NSAlert {
        let alert = NSAlert()
        switch notice.result {
        case .available(let release):
            alert.messageText = String(format: L("Folioak %@ 已发布"), release.version)
            alert.informativeText = String(format: L("当前版本 %@。请从发布页下载安装，替换应用前先退出 Folioak。"), currentVersion)
            if !release.notes.isEmpty { alert.informativeText += "\n\n" + release.notes }
            alert.addButton(withTitle: L("下载新版"))
            alert.addButton(withTitle: L("稍后"))
            alert.addButton(withTitle: L("跳过此版本"))
        case .current:
            alert.messageText = L("已是最新版本")
            alert.informativeText = "Folioak \(currentVersion)"
            alert.addButton(withTitle: L("好"))
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = L("无法检查更新")
            alert.informativeText = message
            alert.addButton(withTitle: L("打开发布页"))
            alert.addButton(withTitle: L("稍后"))
        }
        return alert
    }
}
