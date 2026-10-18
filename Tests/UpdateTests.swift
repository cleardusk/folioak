import Foundation
import AppKit
import SwiftUI

extension CoreTests {
    @MainActor static func updateIntegrationTests() async throws {
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        let suite = "folioak-update-integration-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            app.mainMenu = originalMenu
            preferences.removePersistentDomain(forName: suite)
            AppLocalization.shared.language = .chinese
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v2.6.0", "draft": false, "prerelease": false,
            "published_at": "2026-10-13T00:00:00Z", "body": "Integration fixture",
            "assets": [["name": "Folioak-v2.6.0-macos-arm64.zip", "state": "uploaded", "size": 100]]
        ])
        let response = HTTPURLResponse(url: UpdateHTTPClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        var requests = 0
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        let checker = UpdateChecker(preferences: preferences, currentVersion: "2.5.0", fetch: { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        var opened: [URL] = []
        let model = DownloadModel(preferences: preferences, opener: { opened.append($0); return true }, updates: checker)
        let delegate = AppDelegate(model: model)
        // Exercise the actual target/action menu without launching user windows or using accessibility.
        for language in [AppLanguage.chinese, .english] {
            model.language = language
            delegate.makeMenu()
            guard let item = app.mainMenu?.items.first?.submenu?.item(withTitle: L("检查更新…")) else {
                throw TestFailure.failed("localized update command is present in Folioak menu")
            }
            try expect(item.target === delegate && delegate.validateMenuItem(item), "update command targets the application delegate")
            try expect(app.sendAction(item.action!, to: item.target, from: item), "native menu dispatch reaches the update checker")
            for _ in 0..<100 where pending == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(pending != nil && checker.isChecking && !delegate.validateMenuItem(item), "pending request disables repeated menu actions")
            pending?.resume(returning: (data, response))
            pending = nil
            for _ in 0..<100 where checker.isChecking { try await Task.sleep(nanoseconds: 10_000_000) }
            guard let notice = checker.notice, case .available(let release) = notice.result else {
                throw TestFailure.failed("menu request produces a release prompt")
            }
            try expect(notice.manual && delegate.validateMenuItem(item), "finished menu request restores command and manual feedback")
            for (index, code) in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn].enumerated() {
                preferences.removeObject(forKey: "updates.skippedVersion")
                opened.removeAll()
                let alert = UpdatePresentation.alert(for: notice, currentVersion: checker.currentVersion)
                let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                parent.isReleasedWhenClosed = false
                var result: NSApplication.ModalResponse?
                alert.beginSheetModal(for: parent) { selected in
                    result = selected
                    _ = UpdatePresentation.respond(to: notice, response: selected, checker: checker, open: model.opener)
                }
                // Direct NSButton target/action tests the real native sheet completion, even while the desktop is locked.
                alert.buttons[index].performClick(nil)
                for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                if result == nil { parent.endSheet(alert.window, returnCode: .abort) }
                parent.orderOut(nil)
                try expect(result == code, "native prompt button \(index) dispatches its modal response in \(language)")
                try expect(checker.notice == nil, "prompt response clears pending presentation")
                try expect(opened == (index == 0 ? [release.pageURL] : []), "only Download Update opens the exact release page")
                try expect(preferences.string(forKey: "updates.skippedVersion") == (index == 2 ? release.version : nil), "only Skip This Version persists a skip")
            }
            let failedOpen = UpdatePresentation.respond(to: notice, response: .alertFirstButtonReturn, checker: checker, open: { _ in false })
            try expect(failedOpen?.messageText == L("无法打开下载页") && failedOpen?.informativeText == release.pageURL.absoluteString,
                       "browser launch failure exposes a recoverable download URL")
            let error = UpdateNotice(result: .failed("fixture error"), manual: true)
            try expect(UpdatePresentation.alert(for: error, currentVersion: checker.currentVersion).messageText == L("无法检查更新"), "failed request never renders the up-to-date prompt")
            opened.removeAll()
            try expect(UpdatePresentation.respond(to: error, response: .alertSecondButtonReturn, checker: checker, open: model.opener) == nil && opened.isEmpty,
                       "dismissing an error never opens a browser")
            for index in 0..<2 {
                opened.removeAll()
                let alert = UpdatePresentation.alert(for: error, currentVersion: checker.currentVersion)
                try expect(alert.buttons.map(\.title) == [L("打开发布页"), L("稍后")], "error prompt exposes a release-page recovery action")
                let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
                var result: NSApplication.ModalResponse?
                alert.beginSheetModal(for: parent) { selected in
                    result = selected
                    _ = UpdatePresentation.respond(to: error, response: selected, checker: checker, open: model.opener)
                }
                alert.buttons[index].performClick(nil)
                for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                if result == nil { parent.endSheet(alert.window, returnCode: .abort) }
                parent.orderOut(nil)
                try expect(result == (index == 0 ? .alertFirstButtonReturn : .alertSecondButtonReturn) &&
                           opened == (index == 0 ? [UpdateHTTPClient.releasePage] : []), "native error buttons recover to the fixed release page or dismiss")
            }
        }
        try expect(requests == 2, "each menu command starts exactly one request")
        checker.automaticallyChecks = false
        try expect(!DownloadModel(preferences: preferences).updates.automaticallyChecks, "settings checkbox model persists to a new application model")
        print("PASS update integration: bilingual native menu dispatch, busy validation, ten native sheet button actions, exact browser destination, skip/later persistence and failed-browser recovery without accessibility or desktop input")
    }

    @MainActor static func updateTests() async throws {
        let suite = "folioak-updates-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); FixtureProtocol.reset() }
        func reset() { preferences.removePersistentDomain(forName: suite) }
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        func payload(version: String = "2.6.0", draft: Bool = false, prerelease: Bool = false,
                     assets: Bool = true, state: String = "uploaded") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "tag_name": "v" + version, "draft": draft, "prerelease": prerelease,
                "published_at": "2026-10-13T00:00:00Z", "body": "Update test\n\n- Improved checks",
                "html_url": "https://untrusted.example/ignore-this",
                "assets": assets ? [["name": "Folioak-v\(version)-macos-arm64.dmg", "state": state, "size": 100]] : []
            ])
        }
        func response(_ status: Int = 200, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: UpdateHTTPClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        var calls = 0
        var data = try payload()
        var reply = response(200, ["ETag": "\"v260\""])
        var error: Error?
        var lastRequest: URLRequest?
        let fetch: UpdateChecker.Fetch = { request in
            calls += 1
            lastRequest = request
            if let error { throw error }
            return (data, reply)
        }
        func checker(_ version: String = "2.5.0") -> UpdateChecker {
            UpdateChecker(preferences: preferences, currentVersion: version, now: { time }, fetch: fetch)
        }
        try expect(AppVersion("2.10.0")! > AppVersion("2.9.9")! && AppVersion("3.0.0")! > AppVersion("2.99.99")!, "versions compare numerically")
        for value in ["", "2.5", "2.5.0.0", "v2.5.0", "2.5.0-beta", "2.5.0+1", "02.5.0", "2.-1.0", "٢.5.0", "999999999999999999999.0.0"] {
            try expect(AppVersion(value) == nil, "reject malformed version \(value)")
        }
        let release = try AppRelease.decode(data)
        try expect(release.pageURL.absoluteString == "https://github.com/cleardusk/folioak/releases/tag/v2.6.0", "download opens the fixed repository's version page, never an API-supplied URL")
        for invalid in [try payload(draft: true), try payload(prerelease: true), try payload(assets: false), try payload(state: "new"),
                        try payload(version: "2.6.0-beta"), Data("{}".utf8), Data(repeating: 0, count: UpdateHTTPClient.maximumBytes + 1)] {
            try rejects({ _ = try AppRelease.decode(invalid) }, "only complete stable releases are offered")
        }
        let updates = checker()
        try expect(updates.automaticallyChecks && calls == 0, "construction does not access network; automatic checks default on")
        await updates.check()
        try expect(calls == 1 && updates.notice == UpdateNotice(result: .available(release), manual: false), "automatic new release notification")
        try expect(lastRequest?.value(forHTTPHeaderField: "Authorization") == nil && lastRequest?.value(forHTTPHeaderField: "Cookie") == nil, "public release checks do not carry credentials")
        updates.dismiss()
        await updates.check()
        let restarted = checker()
        await restarted.check()
        try expect(calls == 1, "daily interval survives dismissal and application restart")
        time.addTimeInterval(UpdateChecker.interval)
        reply = response(304)
        await restarted.check()
        try expect(calls == 2 && lastRequest?.value(forHTTPHeaderField: "If-None-Match") == "\"v260\"" && restarted.notice?.result == .available(release), "304 reuses validated cache")
        restarted.dismiss(skip: "2.6.0")
        time.addTimeInterval(UpdateChecker.interval)
        await restarted.check()
        try expect(restarted.notice == nil, "skipped versions are silent automatically")
        await restarted.check(manual: true)
        try expect(restarted.notice == UpdateNotice(result: .available(release), manual: true), "manual checks bypass skipped versions and the daily interval")
        restarted.dismiss()
        restarted.automaticallyChecks = false
        let disabled = checker()
        let before = calls
        time.addTimeInterval(UpdateChecker.interval)
        await disabled.check()
        try expect(!disabled.automaticallyChecks && calls == before, "automatic opt-out persists")
        await disabled.check(manual: true)
        try expect(calls == before + 1 && disabled.notice?.result == .available(release), "manual checks remain available when automatic checks are off")
        disabled.dismiss()
        reply = response()
        data = try payload(version: "2.7.0")
        disabled.automaticallyChecks = true
        time.addTimeInterval(UpdateChecker.interval)
        await disabled.check()
        try expect(disabled.notice?.result == .available(try AppRelease.decode(data)), "skipping one version does not skip future versions")
        for version in ["2.7.0", "3.0.0"] {
            let newer = checker(version)
            await newer.check(manual: true)
            try expect(newer.notice?.result == .current, "same and newer installed versions are up to date")
        }

        reset()
        error = URLError(.notConnectedToInternet)
        let offline = checker()
        await offline.check()
        try expect(offline.notice == nil, "background network errors remain silent")
        await offline.check(manual: true)
        guard case .failed = offline.notice?.result else { throw TestFailure.failed("manual network error must not say up to date") }
        try expect((preferences.object(forKey: "updates.nextCheck") as? Date) == time.addingTimeInterval(2 * UpdateChecker.interval), "consecutive failures back off")
        error = nil
        for status in [404, 500, 304] {
            reset()
            reply = response(status)
            let failed = checker()
            await failed.check(manual: true)
            guard case .failed = failed.notice?.result else { throw TestFailure.failed("HTTP \(status) without a cache fails explicitly") }
        }
        reset()
        reply = response(200)
        data = Data("not JSON".utf8)
        let malformed = checker()
        await malformed.check(manual: true)
        guard case .failed = malformed.notice?.result else { throw TestFailure.failed("malformed response is an error") }
        try expect(preferences.data(forKey: "updates.cache") == nil, "invalid release never poisons the cache")

        for status in [403, 429] {
            reset()
            reply = response(status, ["Retry-After": "120", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(time.timeIntervalSince1970 + 300))])
            let limited = checker()
            await limited.check(manual: true)
            let count = calls
            await checker().check(manual: true)
            try expect(calls == count, "rate limit is persisted and honored by manual checks")
            try expect((preferences.object(forKey: "updates.nextCheck") as? Date) == time.addingTimeInterval(300),
                       "automatic checks resume at the server deadline without a days-long failure backoff")
            guard case .failed(let limitedMessage) = limited.notice?.result else { throw TestFailure.failed("missing rate-limit message") }
            try expect(limitedMessage.contains("GitHub") && !limitedMessage.contains("检查过于频繁"), "shared rate limits do not blame the user's clicks")
            // A user upgrading while 2.6.0 is cooling down may have a full-day backoff.
            preferences.set(time.addingTimeInterval(UpdateChecker.interval), forKey: "updates.nextCheck")
            time.addTimeInterval(301)
            data = try payload()
            reply = response()
            limited.dismiss()
            await limited.check()
            try expect(calls == count + 1 && limited.notice?.result == .available(try AppRelease.decode(data)), "rate-limited requests resume after the server delay")
        }
        reset()
        preferences.set(Data("broken cache".utf8), forKey: "updates.cache")
        await checker().check(manual: true)
        try expect(lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil, "corrupt cache triggers an unconditional request")

        reset()
        var suspended: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var coalescedCalls = 0
        let delayed = UpdateChecker(preferences: preferences, currentVersion: "2.5.0", now: { time }, fetch: { _ in
            coalescedCalls += 1
            return try await withCheckedThrowingContinuation { suspended = $0 }
        })
        let task = Task { await delayed.check() }
        while suspended == nil { await Task.yield() }
        await delayed.check(manual: true)
        await delayed.check()
        suspended!.resume(returning: (try payload(), response()))
        await task.value
        try expect(coalescedCalls == 1 && delayed.notice?.manual == true && !delayed.isChecking, "concurrent manual and automatic checks share one request and preserve manual feedback")
        reset()
        suspended = nil
        let changing = UpdateChecker(preferences: preferences, currentVersion: "2.5.0", now: { time }, fetch: { _ in
            try await withCheckedThrowingContinuation { suspended = $0 }
        })
        let pending = Task { await changing.check() }
        while suspended == nil { await Task.yield() }
        changing.automaticallyChecks = false
        suspended!.resume(returning: (try payload(), response()))
        await pending.value
        try expect(changing.notice == nil, "turning automatic checks off suppresses an in-flight background result")

        FixtureProtocol.reset()
        let path = UpdateHTTPClient.endpoint.path
        func fetchHTTP() async throws -> (Data, HTTPURLResponse) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            return try await UpdateHTTPClient.fetch(URLRequest(url: UpdateHTTPClient.endpoint), configuration: configuration)
        }
        let valid = try payload()
        FixtureProtocol.install(.init(body: valid), path: path)
        try expect(try await fetchHTTP().0 == valid, "real URLSession transport returns release metadata")
        FixtureProtocol.install(.init(status: 304), path: path)
        try expect(try await fetchHTTP().1.statusCode == 304, "transport preserves conditional cache status")
        for fixture in [FixtureProtocol.Reply(body: valid, finalURL: URL(string: "https://untrusted.example/releases")),
                        .init(headers: ["Content-Length": String(UpdateHTTPClient.maximumBytes + 1)], body: Data()),
                        .init(body: Data(repeating: 65, count: UpdateHTTPClient.maximumBytes + 1)),
                        .init(error: .timedOut)] {
            FixtureProtocol.install(fixture, path: path)
            do { _ = try await fetchHTTP(); throw TestFailure.failed("unsafe/oversized/failed HTTP response accepted") }
            catch is TestFailure { throw TestFailure.failed("HTTP transport boundary failed") }
            catch { }
        }
        for language in [AppLanguage.chinese, .english] {
            AppLocalization.shared.language = language
            let alert = UpdatePresentation.alert(for: UpdateNotice(result: .available(release), manual: true), currentVersion: "2.5.0")
            try expect(alert.buttons.map(\.title) == [L("下载新版"), L("稍后"), L("跳过此版本")], "native update prompt has all actions in \(language)")
            try expect(alert.messageText.contains("2.6.0") && alert.informativeText.contains("2.5.0"), "prompt distinguishes installed and available versions")
        }
        AppLocalization.shared.language = .chinese
        print("PASS updates: numeric versions, stable assets, trusted release links, daily/restart scheduling, ETag/304, skip/opt-out, manual feedback, backoff, rate limits, concurrent checks and bounded URLSession responses")
    }

    @MainActor static func liveUpdateTest() async throws {
        let suite = "folioak-live-update-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(preferences: preferences, currentVersion: "0.0.0")
        await checker.check(manual: true)
        guard case .available(let release) = checker.notice?.result else {
            throw TestFailure.failed("live GitHub release check: \(String(describing: checker.notice))")
        }
        checker.dismiss()
        await checker.check(manual: true)
        try expect(checker.notice?.result == .available(release), "live conditional release check")
        print("PASS live updates: v\(release.version), ready arm64 installer, conditional recheck, \(release.pageURL.absoluteString)")
    }

    @MainActor static func renderUpdateSnapshots() throws {
        let suite = "folioak-update-ui-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = .chinese }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/updates")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("update UI bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure.failed("update UI PNG") }
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        for language in [AppLanguage.chinese, .english] {
            for scheme in [ColorScheme.light, .dark] {
                let model = DownloadModel(preferences: preferences)
                model.language = language
                let suffix = "\(language)-\(scheme == .light ? "light" : "dark")"
                let host = NSHostingView(rootView: WorkspaceSettingsView(model: model).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                try capture(host, name: "settings-" + suffix)
                window.orderOut(nil)
            }
        }
        print("Update UI snapshots: \(output.path)")
    }
}
