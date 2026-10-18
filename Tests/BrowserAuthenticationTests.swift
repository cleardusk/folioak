import Foundation
import Darwin
import AppKit
import SwiftUI

private actor BrowserAuthenticationProviderProbe {
    private var issue = BrowserAuthenticationIssue.readFailed
    private(set) var calls = 0

    func selection() throws -> BrowserAuthenticationSelection? {
        calls += 1
        throw DownloadError.browserAuthentication(issue)
    }

    func setIssue(_ issue: BrowserAuthenticationIssue) { self.issue = issue }
}

private final class BrowserAuthenticationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BrowserAuthenticationReadState] = []
    private var fallbackValues: [AnonymousFallbackState] = []
    func receive(_ event: DownloadEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .browserAuthentication(_, let state) = event { values.append(state) }
        if case .anonymousFallback(_, let state) = event { fallbackValues.append(state) }
    }
    var fallbacks: [AnonymousFallbackState] {
        lock.lock(); defer { lock.unlock() }; return fallbackValues
    }
    var states: [BrowserAuthenticationReadState] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

extension CoreTests {
    @MainActor static func browserAuthenticationProviderTests(root: URL, image: URL) async throws {
        let probe = BrowserAuthenticationProviderProbe()
        let pdf = root.appendingPathComponent("authentication-provider.pdf")
        try createPDF(at: pdf)
        let folder = root.appendingPathComponent("authentication-provider-output")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = DownloadEngine(transport: MockTransport(sourcePDF: pdf),
                                    pdfTransport: MockTransport(sourcePDF: pdf), requestInterval: 0, retryDelay: 0,
                                    mediaAuthentication: { try await probe.selection() }, mediaDownload: { _, _, _, _, selection, _, _ in
                                        try expect(selection == nil, "a failed provider only reaches the anonymous attempt")
                                        throw DownloadError.browserAuthentication(.loginRequired)
                                    })
        let reference = try ArxivReference.parse("2501.12345v2")
        for source in [DownloadSource.arxiv(reference), .pdf(URL(string: "https://example.org/provider.pdf")!)] {
            let saved = try await engine.download(source, to: folder)
            try expect(saved.pages == 1, "native paper and PDF downloads succeed while the authentication provider would fail")
        }
        let imageEngine = DownloadEngine(pdfTransport: MockTransport(sourcePDF: image), requestInterval: 0, retryDelay: 0,
                                         mediaAuthentication: { try await probe.selection() })
        let savedImage = try await imageEngine.download(.file(URL(string: "https://example.org/provider.png")!), to: folder)
        let nativeCalls = await probe.calls
        try expect(savedImage.url.pathExtension == "png" && nativeCalls == 0,
                   "native arXiv, PDF and file routes never invoke the browser authentication provider")

        // Both the provider and media operation are fixtures; no browser or
        // network access occurs when the real queue retries anonymously.
        let suite = "folioak-authentication-provider-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DownloadModel(engine: engine, preferences: preferences)
        model.directory = folder
        model.input = "https://youtu.be/provider-fixture"
        model.start()
        try await waitForQueue(model)
        guard let failed = model.items.first else { throw TestFailure.failed("missing provider failure record") }
        let firstCalls = await probe.calls
        try expect(firstCalls == 1 && failed.state == .failed &&
                   failed.errorMessage?.id == DiagnosticMessage.ID.browserAuthLoginRequired.rawValue &&
                   model.logs.contains(where: { $0.diagnostic?.id == DiagnosticMessage.ID.browserAuthReadFailed.rawValue }) &&
                   model.logs.contains(where: { $0.diagnostic?.id == DiagnosticMessage.ID.browserAuthFallbackFailed.rawValue }),
                   "provider failure retries anonymously and retains both the first cause and final outcome")

        await probe.setIssue(.sessionRejected)
        model.retry(failed.id)
        try expect(model.items[0].error == nil && model.items[0].errorMessage == nil,
                   "media retry clears the previous authentication failure before requesting a fresh selection")
        try await waitForQueue(model)
        let retryCalls = await probe.calls
        try expect(retryCalls == 2 && model.items[0].state == .failed &&
                   model.items[0].errorMessage?.id == DiagnosticMessage.ID.browserAuthLoginRequired.rawValue &&
                   model.logs.contains(where: { $0.diagnostic?.id == DiagnosticMessage.ID.browserAuthSessionRejected.rawValue }),
                   "retry rereads the provider and logs its new value before the final anonymous error")
        print("PASS authentication provider: native-route bypass, awaited media failure and fresh queue-retry selection without credentials")
    }

    @MainActor static func browserAuthenticationTests(root: URL) throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.language = .chinese
        defer { AppLocalization.shared.language = originalLanguage }
        let suite = "folioak-browser-auth-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = BrowserAuthenticationPreferences(preferences)
        try expect(!store.enabled && (try store.activeSelection()) == nil && (try store.configuredSelection()) == nil,
                   "fresh preferences are anonymous and select no browser")
        try rejects({ try store.setEnabled(true) }, "enabling authentication requires an explicit browser choice")

        let chrome = try BrowserAuthenticationSelection(browser: .chrome, profile: " Profile 1 ")
        try expect(chrome.argument == "chrome:Profile 1", "Chromium profile names retain internal spaces")
        let firefox = try BrowserAuthenticationSelection(browser: .firefox, profile: "abc.default-release")
        try expect(firefox.argument == "firefox:abc.default-release", "Firefox directory basenames retain dots and hyphens")
        for browser in CookieBrowser.allCases {
            try expect(try BrowserAuthenticationSelection(browser: browser).argument == browser.rawValue,
                       "every selectable browser is an explicit yt-dlp whitelist value")
        }
        for invalid in ["/Users/private/Profile 1", "~/Library/Cookies", "../Default", ".", "..", "chrome:Default", "Default::work",
                        "Default+keyring", "--cookies", "Default\n", "Default\0", "Default\\child", "$(touch x)", String(repeating: "a", count: 129)] {
            try rejects({ _ = try BrowserAuthenticationSelection(browser: .chrome, profile: invalid) },
                        "profile input cannot select a path, inject yt-dlp syntax, or contain control characters")
        }
        for browser in [CookieBrowser.safari, .opera] {
            try rejects({ _ = try BrowserAuthenticationSelection(browser: browser, profile: "Default") },
                        "browsers without profile-name support cannot interpret it as a cookie-file path")
        }
        store.select(chrome)
        try expect(try store.activeSelection() == nil, "selecting a browser does not enable credential access")
        try store.setEnabled(true)
        try expect(try store.activeSelection() == chrome, "only explicit enablement activates the chosen browser")
        store.select(firefox)
        try expect(try store.activeSelection() == firefox, "each read uses the current saved selection")
        try store.setEnabled(false)
        try expect((try store.activeSelection()) == nil && (try store.configuredSelection()) == firefox,
                   "turning authentication off retains the choice without activating it")
        preferences.set("chrome:--cookies", forKey: BrowserAuthenticationPreferences.Key.browser)
        try expect(try store.activeSelection() == nil, "disabled malformed preferences cannot read credentials")
        try rejects({ try store.setEnabled(true) }, "malformed browser values never reach yt-dlp")
        preferences.set("chrome", forKey: BrowserAuthenticationPreferences.Key.browser)
        preferences.set(Data([0]), forKey: BrowserAuthenticationPreferences.Key.profile)
        try rejects({ try store.setEnabled(true) }, "malformed profile types cannot silently select a different profile")
        preferences.set(true, forKey: BrowserAuthenticationPreferences.Key.enabled)
        let repairedSettings = BrowserAuthenticationSettings(preferences)
        repairedSettings.select(.chrome)
        try expect(!repairedSettings.enabled && (try store.activeSelection()) == nil,
                   "repairing invalid saved settings does not silently activate browser access")
        store.clear()
        try expect(try store.activeSelection() == nil, "clearing selection returns to anonymous mode")
        for key in [BrowserAuthenticationPreferences.Key.enabled, BrowserAuthenticationPreferences.Key.browser, BrowserAuthenticationPreferences.Key.profile] {
            try expect(preferences.object(forKey: key) == nil, "clear removes all authentication preferences")
        }

        let settings = BrowserAuthenticationSettings(preferences)
        settings.select(.chrome)
        try expect(settings.selection?.browser == .chrome && !settings.enabled, "settings browser selection stays unverified and disabled")
        settings.setEnabled(true)
        try expect(settings.enabled && (try store.activeSelection())?.browser == .chrome, "settings opt-in persists to the injected preference domain")
        try expect(settings.setProfile("Profile 1") && settings.selection?.profile == "Profile 1", "valid profile edits are saved explicitly")
        try expect(!settings.setProfile("../other") && settings.selection?.profile == "Profile 1", "invalid profile edits keep the last saved selection")
        let active = settings.selection!
        settings.receive(.reading, for: active)
        try expect(settings.readState == .reading, "real reader events update the selected browser")
        settings.receive(.read, for: active)
        try expect(settings.status == "Chrome · Cookie 已读取" && !settings.status.contains("Profile 1"),
                   "successful reads have a concise status without a profile name or a claim of site sign-in")
        settings.receive(.rejected, for: active)
        try expect(settings.readState == .rejected, "site rejection remains distinct from cookie reading")
        _ = settings.setProfile("Default")
        settings.receive(.read, for: active)
        try expect(settings.readState == .ready && settings.status == "Chrome · 已启用，下载时读取",
                   "changing profile clears old results and ignores late events from the previous profile")
        _ = settings.setProfile("Profile 1")
        settings.setEnabled(false)
        settings.receive(.read, for: settings.selection!)
        try expect(settings.readState == .ready, "disabled authentication ignores outstanding reader events")
        try expect((try store.activeSelection()) == nil && settings.selection?.profile == "Profile 1", "settings disable stops future reads and retains the profile")
        settings.select(.safari)
        try expect(settings.selection?.profile == nil, "changing browser clears any previous profile")
        settings.clear()
        try expect(settings.selection == nil && !settings.enabled, "settings clear disables and removes the selection")

        // Building argument arrays does not run yt-dlp or inspect a browser.
        let tools = try MediaTools.installed()
        let urls = ["https://youtu.be/BaW_jenozKc", "https://www.bilibili.com/video/BV1MaHp6KENU/",
                    "https://www.xiaohongshu.com/explore/674051740000000007027a15?xsec_token=fake"]
        for urlString in urls {
            let url = URL(string: urlString)!
            let anonymous = try MediaDownloader.arguments(url: url, format: .automatic, tools: tools, folder: root)
            let authenticated = try MediaDownloader.arguments(url: url, format: .automatic, tools: tools, folder: root, authentication: chrome)
            try expect(anonymous.contains("--no-cookies-from-browser") && !anonymous.contains("--cookies-from-browser"),
                       "default media and CLI arguments explicitly disable browser credentials")
            try expect(anonymous.contains("--no-cookies") && authenticated.contains("--no-cookies") && !authenticated.contains("--cookies"),
                       "neither mode exports a cookie jar to disk")
            let cookies = authenticated.firstIndex(of: "--cookies-from-browser")!
            try expect(authenticated[cookies + 1] == "chrome:Profile 1" && cookies < authenticated.firstIndex(of: "--")!,
                       "explicit browser authentication is one literal argument before the URL boundary")
            try expect(authenticated.contains("--no-quiet") && !authenticated.contains("--verbose") && !anonymous.contains("--no-quiet"),
                       "only opt-in downloads expose normal cookie-reader status without verbose diagnostics")
            try expect(authenticated.suffix(2) == ["--", url.absoluteString] && authenticated.contains("bv*+ba/b"),
                       "authentication preserves the URL and existing best-available format selection")
        }
        try rejects({
            _ = try MediaDownloader.arguments(url: URL(string: "https://youtube.com.evil.invalid/watch?v=1")!,
                                               format: .automatic, tools: tools, folder: root, authentication: chrome)
        }, "browser credentials cannot be enabled for unrecognized media origins")

        let privateDiagnostic = "ERROR: could not find chrome cookies database in /Users/fake-private-person/Profile 1; SESSDATA=fake-secret"
        let readFailure = MediaDownloader.failure(privateDiagnostic, authentication: chrome).message
        try expect(readFailure.id == "browser_auth.read_failed" && readFailure.arguments.isEmpty &&
                   !readFailure.fallback.contains("fake-private-person") && !readFailure.fallback.contains("fake-secret"),
                   "read and permission errors use stable messages without raw cookie values or browser paths")
        let session = MediaDownloader.failure("ERROR: HTTP Error 403: Forbidden", authentication: chrome).message
        let login = MediaDownloader.failure("ERROR: Sign in to confirm your age").message
        try expect(session.id == "browser_auth.session_rejected" && login.id == "browser_auth.login_required",
                   "site rejection distinguishes selected authentication from anonymous login guidance")
        try expect(BrowserAuthenticationIssue.matches(session) && BrowserAuthenticationIssue.matches(login) &&
                   !BrowserAuthenticationIssue.matches(DiagnosticMessage(.invalidPDF)), "only authentication diagnostics expose the settings recovery entry")
        guard case .cooldown(60) = MediaDownloader.failure("ERROR: HTTP Error 429: Too Many Requests", authentication: chrome) else {
            throw TestFailure.failed("browser authentication must preserve platform rate-limit handling")
        }
        try expect(MediaDownloader.failure("ERROR: Unable to extract video data", authentication: chrome, readIssue: .readFailed).message.id == "browser_auth.read_failed",
                   "generic extraction errors retain a preceding cookie-read failure so anonymous fallback remains available")
        try expect(MediaDownloader.failure("ERROR: No space left on device", authentication: chrome, readIssue: .readFailed).message.id == DiagnosticMessage.ID.metadata.rawValue,
                   "cookie warnings cannot turn disk failures into authentication retries")
        let output = MediaOutput()
        output.receive("WARNING: find-generic-password failed") { _ in }
        try expect(output.authenticationIssue?.message.id == "browser_auth.read_failed" && output.error.isEmpty,
                   "Keychain warnings retain a typed recovery cause without copying raw output to stored diagnostics")
        let reading = MediaOutput(authentication: chrome)
        reading.receive("APP_TITLE:\"Extracted 22 cookies from chrome\"") { _ in }
        try expect(reading.authenticationState == .ready, "a video title cannot claim successful cookie reading")
        reading.receive("Extracted 22 cookies from chrome") { _ in }
        try expect(reading.authenticationState == .read, "normal cookie reader output confirms the read")
        reading.receive("WARNING: failed to decrypt cookies; fake-secret") { _ in }
        reading.receive("Extracted 2 cookies from chrome") { _ in }
        try expect(reading.authenticationState == .failed, "partial decryption failures cannot become a successful read")
        let empty = MediaOutput(authentication: chrome)
        empty.receive("[Cookies] Extracted 0 cookies from chrome") { _ in }
        try expect(empty.authenticationState == .empty, "an empty cookie jar is not reported as authenticated")
        let anonymous = MediaOutput()
        anonymous.receive("Extracted 22 cookies from chrome") { _ in }
        try expect(anonymous.authenticationState == .ready, "anonymous output cannot create authentication feedback")
        print("PASS browser authentication: real read states, stale-selection isolation, anonymous defaults, explicit isolated preferences, safe profile names, literal arguments and redacted failure recovery")
    }
}

extension CoreTests {
    @MainActor static func browserAuthenticationProcessTests(root: URL) async throws {
        let mock = root.appendingPathComponent("mock-browser-cookie-process", isDirectory: true)
        let staging = mock.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let shim = mock.appendingPathComponent("yt-dlp")
        // This is a fixture executable, never the installed yt-dlp. It reads no
        // browser files and contacts no site, even when given opt-in arguments.
        let script = #"""
        #!/bin/sh
        mock_dir=${0%/*}
        mode=$(/bin/cat "$mock_dir/mode")
        auth=anonymous
        for argument do
            if [ "$argument" = '--cookies-from-browser' ]; then auth=selected; fi
        done
        permissions=$(/usr/bin/stat -f %Lp "$TMPDIR")
        printf '%s\n' "$TMPDIR" "$permissions" "$auth" > "$mock_dir/probe"
        if [ "$auth" = selected ]; then
            printf 'mock database, contains no cookies' > "$TMPDIR/mock.sqlite"
        fi
        case "$mode" in
            success)
                if [ "$auth" = selected ]; then printf 'Extracted 22 cookies from chrome\n'; fi
                /bin/cat "$mock_dir/file-message"; exit 0
                ;;
            failure)
                printf 'Extracted 22 cookies from chrome\nERROR: HTTP Error 403: Forbidden\n'; exit 1
                ;;
            fallback)
                if [ "$auth" = selected ]; then
                    printf 'ERROR: HTTP Error 403: Forbidden\n'; exit 1
                fi
                /bin/cat "$mock_dir/file-message"; exit 0
                ;;
            rate-limit)
                printf 'WARNING: failed to decrypt cookies; fixture only\nWARNING: HTTP Error 429: Too Many Requests\nERROR: Fresh cookies are needed\n'; exit 1
                ;;
            empty)
                printf 'Extracted 0 cookies from chrome\n'
                /bin/cat "$mock_dir/file-message"; exit 0
                ;;
            read-failure)
                printf 'WARNING: failed to decrypt cookies; fixture only\nExtracted 2 cookies from chrome\n'
                /bin/cat "$mock_dir/file-message"; exit 0
                ;;
            closed-output)
                exec 1>&- 2>&-
                /bin/sleep 0.05
                printf finished > "$mock_dir/closed-output-finished"
                exit 0
                ;;
            cancel)
                trap 'exit 0' TERM
                /bin/sh "$mock_dir/stubborn-child" "$mock_dir" "$TMPDIR" &
                printf '%s\n' "$!" > "$mock_dir/child-pid"
                while [ ! -f "$mock_dir/child-ready" ]; do /bin/sleep 0.01; done
                printf ready > "$mock_dir/ready"
                /bin/sleep 30
                ;;
        esac
        """#
        let stubbornChild = #"""
        #!/bin/sh
        trap '' TERM
        exec >/dev/null 2>&1
        printf ready > "$1/child-ready"
        while :; do
            /bin/mkdir -p "$2"
            printf 'mock only' > "$2/mock.sqlite"
            /bin/sleep 0.02
        done
        """#
        try Data(script.utf8).write(to: shim)
        let childScript = mock.appendingPathComponent("stubborn-child")
        try Data(stubbornChild.utf8).write(to: childScript)
        let qjs = mock.appendingPathComponent("qjs")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: qjs)
        for executable in [shim, childScript, qjs] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let outputPath = staging.appendingPathComponent("mock-output.mp4").path
        let outputMessage = "APP_FILE:" + String(decoding: try JSONEncoder().encode(outputPath), as: UTF8.self) + "\n"
        try Data(outputMessage.utf8).write(to: mock.appendingPathComponent("file-message"))
        let tools = MediaTools(directory: mock)
        let url = URL(string: "https://youtu.be/mock-cookie-fixture")!
        let selection = try BrowserAuthenticationSelection(browser: .chrome, profile: "Fixture Profile")
        func mode(_ value: String) throws { try Data(value.utf8).write(to: mock.appendingPathComponent("mode")) }
        func probe() throws -> [String] {
            try String(contentsOf: mock.appendingPathComponent("probe"), encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func authDirectories() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0.hasPrefix(".browser-auth-") }
        }
        func confirmCleaned(_ values: [String], _ scenario: String) throws {
            try expect(values.count == 3 && values[1] == "700" && values[2] == "selected",
                       "\(scenario) uses an isolated 0700 authentication TMPDIR")
            let temporary = URL(fileURLWithPath: values[0])
            try expect(temporary.deletingLastPathComponent().path == staging.path &&
                       temporary.lastPathComponent.hasPrefix(".browser-auth-"), "\(scenario) places the authentication TMPDIR in its staging directory")
            let remaining = try authDirectories()
            try expect(!FileManager.default.fileExists(atPath: temporary.path) && remaining.isEmpty,
                       "\(scenario) removes the authentication directory and mock database before returning; remaining=\(remaining)")
        }

        try mode("success")
        let successfulEvents = BrowserAuthenticationEvents()
        let successful = try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools, folder: staging,
                                                                 authentication: selection, event: { successfulEvents.receive($0) })
        try expect(successful.files.first?.path == outputPath && successfulEvents.states == [.reading, .read, .read],
                   "mock success reports real cookie reading before the production file output")
        try confirmCleaned(probe(), "success")

        try mode("failure")
        let failedEvents = BrowserAuthenticationEvents()
        do {
            _ = try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools, folder: staging,
                                                       authentication: selection, event: { failedEvents.receive($0) })
            throw TestFailure.failed("mock nonzero exit succeeded")
        } catch let error as TestFailure { throw error }
        catch let error as DownloadError {
            try expect(error.message.id == "browser_auth.session_rejected", "mock failure retains typed authentication recovery")
        }
        try confirmCleaned(probe(), "failure")
        try expect(failedEvents.states == [.reading, .read, .rejected, .rejected], "site rejection supersedes a successful cookie read")
        for (scenario, expected) in [("empty", BrowserAuthenticationReadState.empty), ("read-failure", .failed)] {
            try mode(scenario)
            let output = try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools, folder: staging, authentication: selection)
            try expect(output.authenticationState == expected, "successful media transfer does not mask \(scenario) authentication")
            try confirmCleaned(probe(), scenario)
        }

        try mode("fallback")
        let fallbackFolder = mock.appendingPathComponent("anonymous-staging")
        try FileManager.default.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
        let fallbackEvents = BrowserAuthenticationEvents()
        _ = try await MediaDownloader.withAuthenticationFallback(authentication: { selection }, event: { fallbackEvents.receive($0) }) { auth in
            if auth == nil { try confirmCleaned(probe(), "before anonymous fallback") }
            return try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools,
                folder: auth == nil ? fallbackFolder : staging, authentication: auth, event: { fallbackEvents.receive($0) })
        }
        try expect(try probe()[2] == "anonymous" && fallbackEvents.fallbacks == [.started, .succeeded],
                   "the fallback launches a fresh process without browser arguments after authenticated temporary data is gone")
        try mode("rate-limit")
        let limitedEvents = BrowserAuthenticationEvents()
        do {
            _ = try await MediaDownloader.withAuthenticationFallback(authentication: { selection }, event: { limitedEvents.receive($0) }) { auth in
                try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools, folder: staging,
                    authentication: auth, event: { limitedEvents.receive($0) })
            }
            throw TestFailure.failed("rate-limited process succeeded")
        } catch DownloadError.cooldown(60) { }
        try expect(limitedEvents.fallbacks.isEmpty, "a cookie warning cannot override the final HTTP 429 or bypass its cooldown")
        try confirmCleaned(probe(), "rate limit")

        try mode("cancel")
        let cancelledEvents = BrowserAuthenticationEvents()
        let task = Task { try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools, folder: staging,
                                                                authentication: selection, event: { cancelledEvents.receive($0) }) }
        let ready = mock.appendingPathComponent("ready")
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(nanoseconds: 20_000_000) }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            task.cancel()
            _ = try? await task.value
            throw TestFailure.failed("mock authentication process did not reach cancellation fixture")
        }
        let cancellationProbe = try probe()
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; throw TestFailure.failed("cancelled authentication process succeeded") }
        catch is CancellationError {}
        try expect(Date().timeIntervalSince(cancelledAt) < 4, "closed-output stubborn descendants cannot hang cancellation")
        try expect(cancelledEvents.states == [.reading, .ready], "cancellation cannot leave a permanent reading or success status")
        try confirmCleaned(cancellationProbe, "cancellation")
        try await Task.sleep(nanoseconds: 100_000_000)
        try confirmCleaned(cancellationProbe, "after cancellation")
        if let child = Int32(try String(contentsOf: mock.appendingPathComponent("child-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) {
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, child]
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            let result = withUnsafeMutablePointer(to: &info) { sysctl(&query, u_int(query.count), $0, &size, nil, 0) }
            try expect(result == 0 && (size == 0 || Int32(info.kp_proc.p_stat) == SZOMB),
                       "the TERM-ignoring child has exited and cannot write before temporary-directory cleanup completes")
        }

        try mode("closed-output")
        let closedStatus = try await MediaProcess().run(shim, arguments: []) { _ in }
        try expect(closedStatus == 0 && FileManager.default.fileExists(atPath: mock.appendingPathComponent("closed-output-finished").path),
                   "closing stdout and stderr does not kill an active successful leader or change its exit code")

        try mode("success")
        _ = try await MediaDownloader.runDownloader(url, format: .automatic, tools: tools, folder: staging)
        let anonymousProbe = try probe()
        try expect(anonymousProbe.count == 3 && anonymousProbe[0] == NSTemporaryDirectory() && anonymousProbe[2] == "anonymous" &&
                   (try authDirectories()).isEmpty, "anonymous invocation preserves the original TMPDIR and creates no authentication directory")
        print("PASS browser authentication process: mock 0700 TMPDIR, success/failure cleanup, bounded group cancellation and unchanged anonymous environment")
    }
}


private actor AnonymousFallbackProbe {
    private(set) var attempts: [Bool] = []
    func download(authentication: BrowserAuthenticationSelection?, image: URL,
                  event: @escaping @Sendable (DownloadEvent) -> Void) throws -> SavedDocument {
        attempts.append(authentication != nil)
        if let authentication {
            event(.browserAuthentication(authentication, .reading))
            event(.browserAuthentication(authentication, .rejected))
            throw DownloadError.browserAuthentication(.sessionRejected)
        }
        // Exercise the production bounded queue stream, not only the helper.
        for index in 0..<2000 { event(.progress(DownloadProgress(received: Int64(index), total: 2000))) }
        return SavedDocument(title: "Anonymous fixture", metadata: nil, url: image, alreadyExisted: false, pages: 0)
    }
}

extension CoreTests {
    @MainActor static func anonymousFallbackTests(root: URL, image: URL) async throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.language = .chinese
        defer { AppLocalization.shared.language = originalLanguage }
        let selection = try BrowserAuthenticationSelection(browser: .chrome, profile: "Private Fixture Profile")
        let url = URL(string: "https://youtu.be/anonymous-fallback-fixture")!
        let anonymousKey = MediaDownloader.stagingKey(url, directory: root, format: .automatic, authentication: nil)
        try expect(anonymousKey == PDFStorage.key(url.absoluteString + "|" + MediaFormat.automatic.rawValue + "|" + root.standardizedFileURL.path) &&
                   anonymousKey != MediaDownloader.stagingKey(url, directory: root, format: .automatic, authentication: selection),
                   "anonymous fallback retains the old resume key and cannot use authenticated partials")
        let fresh = MediaDownloader.failure("ERROR: Fresh cookies (not necessarily logged in) are needed", url: url)
        try expect(fresh.message.id == DiagnosticMessage.ID.browserAuthFreshCookiesRequired.rawValue &&
                   BrowserAuthenticationIssue.matches(fresh.message), "a fresh-cookie request is not falsely reported as confirmed login failure")
        for issue in [BrowserAuthenticationIssue.readFailed, .sessionRejected, .freshCookiesRequired] {
            var attempts: [Bool] = []
            let events = BrowserAuthenticationEvents()
            let value = try await MediaDownloader.withAuthenticationFallback(authentication: { selection }, event: { events.receive($0) }) { auth in
                attempts.append(auth != nil)
                if auth != nil { throw DownloadError.browserAuthentication(issue) }
                return "saved"
            }
            try expect(value == "saved" && attempts == [true, false] && events.fallbacks == [.started, .succeeded] && events.states.last == issue.readState,
                       "each known cookie failure gets one anonymous retry and retains the rejected/read-failed status")
        }
        for failure in [DownloadError.cooldown(60), .storage("fixture"), .metadata("fixture"), .unsafeResponse] {
            var calls = 0
            let events = BrowserAuthenticationEvents()
            do {
                let _: String = try await MediaDownloader.withAuthenticationFallback(authentication: { selection }, event: { events.receive($0) }) { _ in
                    calls += 1; throw failure
                }
                throw TestFailure.failed("non-auth failure succeeded")
            } catch is TestFailure { throw TestFailure.failed("non-auth failure succeeded") }
            catch { try expect(calls == 1 && events.fallbacks.isEmpty, "rate limits, disk and other failures do not cause anonymous traffic") }
        }
        for auth in [selection, nil] {
            var calls = 0
            let events = BrowserAuthenticationEvents()
            do {
                let _: String = try await MediaDownloader.withAuthenticationFallback(authentication: { auth }, event: { events.receive($0) }) { _ in
                    calls += 1; throw DownloadError.browserAuthentication(.freshCookiesRequired)
                }
                throw TestFailure.failed("rejected anonymous attempt succeeded")
            } catch let failure as DownloadError {
                try expect(calls == (auth == nil ? 1 : 2) && failure.message.id == fresh.message.id &&
                           events.fallbacks == (auth == nil ? [] : [.started, .failed]), "anonymous rejection retains the final cause and never loops")
            }
        }
        let cancelledEvents = BrowserAuthenticationEvents()
        let cancelled = Task { () throws -> String in
            try await MediaDownloader.withAuthenticationFallback(authentication: { selection }, event: { cancelledEvents.receive($0) }) { _ in
                throw CancellationError()
            }
        }
        do { _ = try await cancelled.value; throw TestFailure.failed("cancelled attempt succeeded") }
        catch is CancellationError { }
        try expect(cancelledEvents.fallbacks.isEmpty, "cancellation never starts an anonymous retry")
        let retryCancelledEvents = BrowserAuthenticationEvents()
        let retryCancelled = Task { () throws -> String in
            try await MediaDownloader.withAuthenticationFallback(authentication: { selection }, event: { retryCancelledEvents.receive($0) }) { auth in
                if auth != nil { throw DownloadError.browserAuthentication(.readFailed) }
                throw CancellationError()
            }
        }
        do { _ = try await retryCancelled.value; throw TestFailure.failed("cancelled fallback succeeded") }
        catch is CancellationError { }
        try expect(retryCancelledEvents.fallbacks == [.started, .cancelled], "cancelling the anonymous attempt has a distinct outcome")

        let suite = "folioak-anonymous-fallback-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let probe = AnonymousFallbackProbe()
        let engine = DownloadEngine(mediaAuthentication: { selection }, mediaDownload: { _, _, _, _, auth, _, event in
            try await probe.download(authentication: auth, image: image, event: event)
        })
        let model = DownloadModel(engine: engine, preferences: preferences)
        model.browserAuthentication.select(.chrome)
        _ = model.browserAuthentication.setProfile(selection.profile!)
        model.browserAuthentication.setEnabled(true)
        model.directory = root
        model.input = url.absoluteString
        model.start()
        try await waitForQueue(model)
        let attempts = await probe.attempts
        try expect(attempts == [true, false] && model.items.first?.state == .saved && model.items.first?.errorMessage == nil,
                   "production queue publishes anonymous success without retaining the intermediate task error")
        let ids = model.logs.compactMap { $0.diagnostic?.id }
        for id in [DiagnosticMessage.ID.browserAuthSessionRejected, .browserAuthFallbackStarted, .browserAuthFallbackSucceeded] {
            try expect(ids.filter { $0 == id.rawValue }.count == 1, "progress bursts preserve one log per authentication/fallback phase")
        }
        try expect(ids.lastIndex(of: DiagnosticMessage.ID.browserAuthRejected.rawValue)! < ids.firstIndex(of: DiagnosticMessage.ID.browserAuthFallbackSucceeded.rawValue)!,
                   "late browser status precedes anonymous success, keeping the final log outcome unambiguous")
        try expect(model.browserAuthentication.readState == .rejected && model.browserAuthentication.enabled &&
                   model.browserAuthentication.selection == selection && model.browserAuthentication.lastHost == url.host,
                   "anonymous success does not claim browser authentication succeeded or change saved preferences")
        let serialized = try JSONEncoder().encode(model.logs)
        let restored = try JSONDecoder().decode([ActivityEntry].self, from: serialized)
        try expect(restored.compactMap { $0.diagnostic?.id } == ids && !String(decoding: serialized, as: UTF8.self).contains(selection.profile!),
                   "fallback log history round-trips typed phases without profile names or cookie contents")
        var opens: [(CookieBrowser, URL?)] = []
        let settings = BrowserAuthenticationSettings(preferences, browserOpener: { browser, url in opens.append((browser, url)); return true })
        await settings.openBrowser(url: url)
        await settings.openBrowser(url: URL(string: "https://evil.example/")!)
        try expect(opens.count == 1 && opens[0].0 == .chrome && opens[0].1 == url && !settings.browserOpenError,
                   "recovery opens only the supported original link in the selected browser")
        settings.receive(.empty, for: selection, host: url.host)
        try expect(settings.recoveryHint.contains("未找到 Cookie"), "empty cookie state provides an actionable recovery hint")
        settings.select(.firefox)
        try expect(settings.lastHost == nil && settings.readState == .ready, "new selection cannot show a stale site outcome")
        let failedOpener = BrowserAuthenticationSettings(preferences, browserOpener: { _, _ in false })
        await failedOpener.openBrowser(url: url)
        try expect(failedOpener.browserOpenError && !failedOpener.openingBrowser, "browser launch failures are visible and retryable")
        print("PASS anonymous fallback: one retry, final cause, no loops, cancellation/rate-limit/storage boundaries, isolated resume keys, burst-safe typed logs, unchanged preferences and selected-browser recovery")
    }
}

extension CoreTests {
    @MainActor static func authenticationInterfaceTests() async throws {
        let suite = "folioak-authentication-interface-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let application = NSApplication.shared
        let appearance = application.appearance
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = .chinese; application.appearance = appearance }
        let model = DownloadModel(preferences: preferences)
        let url = URL(string: "https://v.douyin.com/fixture/")!
        var item = DownloadItem(original: url.absoluteString, directURL: url, state: .failed, documentTitle: "视频下载 · 认证与匿名重试")
        item.setError(BrowserAuthenticationIssue.freshCookiesRequired.message)
        model.history = [item]
        model.record(.warning, BrowserAuthenticationIssue.readFailed.message, item: item)
        model.record(.warning, AnonymousFallbackState.started.message, item: item)
        model.record(.warning, AnonymousFallbackState.failed.message, item: item)
        model.record(.error, BrowserAuthenticationIssue.freshCookiesRequired.message, item: item)
        model.record(.info, DiagnosticMessage(.start, "1"))
        let filtered = DownloaderView(model: model, page: .logs, logItem: item)
        try expect(filtered.visibleLogs.count == 4 && filtered.visibleLogs.allSatisfy { $0.itemID == item.id },
                   "task log view and its export contain only the selected task, including both attempts")
        try expect(DownloaderView(model: model, page: .logs).visibleLogs.count == 5,
                   "all-log navigation restores unrelated and global activity")
        guard CommandLine.arguments.contains("--snapshots") else { return }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/authentication-261")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture<V: View>(_ content: V, width: CGFloat, height: CGFloat, name: String, scheme: ColorScheme) async throws {
            let view = NSHostingView(rootView: content.environment(\.colorScheme, scheme).environment(\.controlActiveState, .key))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            defer { window.orderOut(nil) }
            try await Task.sleep(nanoseconds: 120_000_000)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("authentication UI bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure.failed("authentication UI PNG") }
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
        model.browserAuthentication.select(.chrome)
        model.browserAuthentication.setEnabled(true)
        for language in [AppLanguage.chinese, .english] {
            model.language = language
            for scheme in [ColorScheme.light, .dark] {
                application.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let suffix = "\(language.rawValue)-\(scheme == .light ? "light" : "dark")"
                model.settingsTab = "浏览器认证"
                for state in [BrowserAuthenticationReadState.read, .empty, .failed, .rejected] {
                    model.browserAuthentication.receive(state, for: model.browserAuthentication.selection!, host: "v.douyin.com")
                    try await capture(WorkspaceSettingsView(model: model), width: 680, height: 520, name: "settings-\(state)-\(suffix)", scheme: scheme)
                }
                try await capture(DownloaderView(model: model, page: .logs, logItem: item), width: 780, height: 540, name: "task-logs-\(suffix)", scheme: scheme)
                try await capture(DownloaderView(model: model), width: 780, height: 540, name: "recovery-\(suffix)", scheme: scheme)
            }
        }
        print("PASS authentication interface: task-filtered log/export scope, native settings snapshots in Chinese/English and light/dark at minimum sizes")
    }
}
