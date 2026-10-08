import Foundation
import Darwin

final class CapturedConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""
    func stdout(_ value: String) { lock.lock(); out += value; lock.unlock() }
    func stderr(_ value: String) { lock.lock(); err += value; lock.unlock() }
    var output: String { lock.lock(); defer { lock.unlock() }; return out }
    var errors: String { lock.lock(); defer { lock.unlock() }; return err }
}

extension CoreTests {
    static func cliTests(root: URL, pdf: URL) async throws {
        let suite = "arxiv-cli-test-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let original = root.appendingPathComponent("default-cli")
        prefs.set(original.path, forKey: "saveDirectory")
        prefs.set(NamingStyle.titleOnly.rawValue, forKey: "namingStyle")
        prefs.set("iris", forKey: "theme")
        let before = prefs.dictionaryRepresentation()
        let override = root.appendingPathComponent("cli-override 👩‍💻")
        let options = try CLIOptions.parse(["2501.12345v2", "https://arxiv.org/html/2501.12345v2", "--output=\(override.path)", "--naming", "id-title", "--json"])
        let transport = MockTransport(sourcePDF: pdf)
        let engine = DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0)
        let console = CapturedConsole()
        let result = await CLIRunner.run(options, version: "test", engine: engine, preferences: prefs, stdout: { console.stdout($0) }, stderr: { console.stderr($0) })
        let report = try JSONSerialization.jsonObject(with: Data(console.output.utf8)) as! [String: Any]
        let rows = report["results"] as! [[String: Any]]
        try expect(result == 0 && rows.count == 1 && report["deduplicated"] as? Int == 1, "CLI JSON and equivalent-link deduplication")
        try expect((rows[0]["path"] as? String)?.contains("[2501.12345v2]") == true && rows[0]["status"] as? String == "saved", "CLI naming and directory override")
        let human = CapturedConsole()
        let humanOptions = try CLIOptions.parse(["2501.12345v2", "-o", override.path, "--naming", "id-title"])
        let humanCode = await CLIRunner.run(humanOptions, version: "test", engine: engine, preferences: prefs, stdout: { human.stdout($0) }, stderr: { human.stderr($0) })
        try expect(humanCode == 0 && human.output == (rows[0]["path"] as! String) + "\n", "ordinary CLI output preserves actual Unicode file path")
        try expect(NSDictionary(dictionary: before).isEqual(to: prefs.dictionaryRepresentation()), "CLI overrides do not write shared/UI preferences")
        try expect(!FileManager.default.fileExists(atPath: original.path), "CLI override does not create the shared default directory")
        for args in [[], ["--unknown"], ["-o"], ["--naming", "bad"], ["-o", "--json"], ["2501.12345", "--output="], ["2501.12345", "-o", "a", "-o", "b"]] {
            try rejects({ _ = try CLIOptions.parse(args) }, "CLI invalid arguments accepted")
        }
        try rejects({ _ = try CLIOptions.parse([String(repeating: "x", count: ResourceLimits.inputBytes + 1)]) }, "CLI byte limit")
        try rejects({ _ = try CLIOptions.parse(Array(repeating: "2501.12345", count: 201)) }, "CLI batch limit before deduplication")
        try expect(try CLIOptions.parse(["--help"]).action == .help, "CLI help")
        try expect(CLIRunner.terminalText("a\u{1b}[31m\n\u{202E}b") == "a [31m  b", "CLI terminal control sequences removed")
        let unicodePath = "/tmp/研究 👩‍💻 👨‍👩‍👧‍👦.pdf"
        try expect(CLIRunner.terminalText(unicodePath) == unicodePath, "CLI preserves Unicode filename joiners")

        let failed = CapturedConsole()
        let broken = DownloadEngine(transport: MockTransport(sourcePDF: pdf, pdf: [.corrupt]), requestInterval: 0, retryDelay: 0)
        let brokenCode = await CLIRunner.run(options, version: "test", engine: broken, preferences: prefs, stdout: { failed.stdout($0) }, stderr: { failed.stderr($0) })
        // Reuse the trusted PDF for the success case; use a fresh directory here.
        let corruptOptions = try CLIOptions.parse(["2501.12345v2", "-o", root.appendingPathComponent("cli-corrupt").path, "--json"])
        let errors = CapturedConsole()
        let errorCode = await CLIRunner.run(corruptOptions, version: "test", engine: broken, preferences: prefs, stdout: { errors.stdout($0) }, stderr: { errors.stderr($0) })
        try expect(brokenCode == 0 && errorCode == 1 && errors.output.contains("failed") && !errors.errors.isEmpty, "CLI corrupted PDF exit code and JSON error")
        let cancelled = CapturedConsole()
        let slow = DownloadEngine(transport: MockTransport(sourcePDF: pdf, delay: 5_000_000_000), requestInterval: 0, retryDelay: 0)
        let cancelOptions = try CLIOptions.parse(["2501.12345", "2501.12345v2", "-o", root.appendingPathComponent("cli-cancel").path, "--json"])
        let job = Task { await CLIRunner.run(cancelOptions, version: "test", engine: slow, preferences: prefs, stdout: { cancelled.stdout($0) }, stderr: { cancelled.stderr($0) }) }
        try await Task.sleep(nanoseconds: 30_000_000); job.cancel()
        try expect(await job.value == 130 && cancelled.output.components(separatedBy: "cancelled").count == 3, "CLI cancellation outputs complete batch JSON")
        let pauseOptions = try CLIOptions.parse(["2501.12345", "2501.12345v2", "-o", root.appendingPathComponent("cli-pause").path, "--json"])
        let paused = CapturedConsole()
        let throttled = DownloadEngine(transport: MockTransport(sourcePDF: pdf, metadata: [.status(429, "600")]), requestInterval: 0, retryDelay: 0)
        let pausedCode = await CLIRunner.run(pauseOptions, version: "test", engine: throttled, preferences: prefs, stdout: { paused.stdout($0) }, stderr: { paused.stderr($0) })
        try expect(pausedCode == 1 && paused.output.components(separatedBy: "paused").count == 3 && paused.output.contains("retryAfter"), "CLI rate limit pauses remaining inputs")
        print("PASS CLI: parsing, bounded batches, config overrides, deduplication, JSON, exit codes, cancellation and cooldown")
    }

    static func coordinatorTests(root: URL, pdf: URL) async throws {
        let directory = root.appendingPathComponent("shared-state")
        let coordinator = RequestCoordinator(directory: directory)
        var held: RequestLease? = try await coordinator.acquire()
        try held!.store(RequestState())
        let waiter = Task { try await coordinator.acquire() }
        try await Task.sleep(nanoseconds: 30_000_000); waiter.cancel()
        do { _ = try await waiter.value; throw TestFailure.failed("lock wait ignored cancellation") }
        catch is CancellationError { }
        held = nil
        let lease = try await coordinator.acquire()
        try expect(try lease.load().schema == 1, "released lock can be acquired")
        withExtendedLifetime(lease) { }
        // A separate directory avoids extending lease lifetime through this scope.
        let networkCoordinator = RequestCoordinator(directory: root.appendingPathComponent("engine-state"))
        let folder = root.appendingPathComponent("shared-papers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ref = try ArxivReference.parse("2501.12345v2")
        let first = MockTransport(sourcePDF: pdf)
        let second = MockTransport(sourcePDF: pdf)
        _ = try await DownloadEngine(transport: first, requestInterval: 0.08, retryDelay: 0, coordinator: networkCoordinator).download(ref, to: folder)
        _ = try await DownloadEngine(transport: second, requestInterval: 0.08, retryDelay: 0, coordinator: networkCoordinator).download(ref, to: folder)
        let firstTimes = await first.times, secondTimes = await second.times
        try expect(secondTimes[0].timeIntervalSince(firstTimes.last!) >= 0.075, "request spacing survives a new engine")
        let limited = MockTransport(sourcePDF: pdf, metadata: [.status(429, "600")])
        do { _ = try await DownloadEngine(transport: limited, requestInterval: 0, retryDelay: 0, coordinator: networkCoordinator).download(ref, to: folder); throw TestFailure.failed("shared cooldown ignored") }
        catch DownloadError.cooldown { }
        let next = MockTransport(sourcePDF: pdf)
        do { _ = try await DownloadEngine(transport: next, requestInterval: 0, retryDelay: 0, coordinator: networkCoordinator).download(ref, to: folder); throw TestFailure.failed("new engine bypassed cooldown") }
        catch DownloadError.cooldown(let seconds) { try expect(seconds > 590, "persisted cooldown shortened") }
        try expect(await next.metadataCalls == 0, "cooldown blocks network before request")
        let legacySuite = "arxiv-legacy-cooldown-\(UUID().uuidString)"
        let legacyPreferences = UserDefaults(suiteName: legacySuite)!
        defer { legacyPreferences.removePersistentDomain(forName: legacySuite) }
        legacyPreferences.set(Date().addingTimeInterval(900), forKey: "requestCooldownUntil")
        let migration = RequestCoordinator(directory: root.appendingPathComponent("legacy-state"))
        do { _ = try await DownloadEngine(transport: MockTransport(sourcePDF: pdf), cooldownPreferences: legacyPreferences, coordinator: migration).download(ref, to: folder); throw TestFailure.failed("legacy cooldown bypassed") }
        catch DownloadError.cooldown { }
        let independent = MockTransport(sourcePDF: pdf)
        do { _ = try await DownloadEngine(transport: independent, coordinator: migration).download(ref, to: folder); throw TestFailure.failed("legacy cooldown was not shared") }
        catch DownloadError.cooldown(let seconds) { try expect(seconds > 890, "longer legacy cooldown preserved") }
        try expect(await independent.metadataCalls == 0, "migrated cooldown stops independent entry point")
        let resets = RequestCoordinator(directory: root.appendingPathComponent("reset-state"))
        do { let current = try await resets.acquire(); try current.store(RequestState(strikes: 3)) }
        let cached = DownloadEngine(transport: MockTransport(sourcePDF: pdf, metadata: [.status(404, nil), .status(429, nil)]), requestInterval: 0, retryDelay: 0, rateLimitDelay: 61, coordinator: resets)
        do { _ = try await cached.download(ref, to: folder); throw TestFailure.failed("404 unexpectedly succeeded") }
        catch DownloadError.http(404, _) { }
        _ = try await DownloadEngine(transport: MockTransport(sourcePDF: pdf), requestInterval: 0, coordinator: resets).download(ref, to: folder)
        do { _ = try await cached.download(ref, to: folder); throw TestFailure.failed("429 unexpectedly succeeded") }
        catch DownloadError.cooldown(let seconds) { try expect(seconds <= 61, "other process reset stale exponential backoff") }

        let cancellationCoordinator = RequestCoordinator(directory: root.appendingPathComponent("active-cancel-state"))
        let slowEngine = DownloadEngine(transport: MockTransport(sourcePDF: pdf, delay: 5_000_000_000), requestInterval: 0, coordinator: cancellationCoordinator)
        let active = Task { try await slowEngine.download(ref, to: folder) }
        try await Task.sleep(nanoseconds: 40_000_000); active.cancel()
        do { _ = try await active.value; throw TestFailure.failed("active coordinated request ignored cancellation") }
        catch is CancellationError { }
        do { let recovered = try await cancellationCoordinator.acquire(); try expect(try recovered.load().lastRequest != nil, "active cancellation releases lock and preserves request spacing") }
        let corrupt = RequestCoordinator(directory: root.appendingPathComponent("corrupt-state"))
        do {
            let current = try await corrupt.acquire()
            let state = corrupt.directory.appendingPathComponent("request-state.json")
            try Data("broken".utf8).write(to: state)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
            try rejects({ _ = try current.load() }, "corrupt coordination state ignored")
        }
        let blocked = MockTransport(sourcePDF: pdf)
        do { _ = try await DownloadEngine(transport: blocked, coordinator: corrupt).download(ref, to: folder); throw TestFailure.failed("corrupt state allowed request") }
        catch DownloadError.coordination { }
        try expect(await blocked.metadataCalls == 0, "state errors fail before network")
        let linked = root.appendingPathComponent("linked-state")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
        do { _ = try await RequestCoordinator(directory: linked).acquire(); throw TestFailure.failed("symlink coordination directory accepted") }
        catch DownloadError.coordination { }
        print("PASS coordination: cancellable lock, engine restart spacing/cooldown, corrupt-state fail closed and symlink rejection")
    }

    static func processTests(root: URL, pdf: URL) async throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/CoordinationProbe")
        func process(_ arguments: [String]) throws -> (Process, Pipe) {
            let child = Process(); let pipe = Pipe()
            child.executableURL = executable; child.arguments = arguments
            child.standardOutput = pipe; child.standardError = FileHandle.standardError
            try child.run(); return (child, pipe)
        }
        let coordinator = RequestCoordinator(directory: root.appendingPathComponent("ipc-lock"))
        let (holder, pipe) = try process(["lock", coordinator.directory.path])
        defer { if holder.isRunning { holder.terminate() } }
        let ready = try pipe.fileHandleForReading.read(upToCount: 9)
        try expect(ready == Data("acquired\n".utf8), "child acquired lock")
        let waiting = Task { try await coordinator.acquire() }
        try await Task.sleep(nanoseconds: 30_000_000); waiting.cancel()
        do { _ = try await waiting.value; throw TestFailure.failed("cross-process waiting ignored cancellation") }
        catch is CancellationError { }
        try expect(kill(holder.processIdentifier, SIGKILL) == 0, "kill test holder")
        holder.waitUntilExit()
        do { let recovered = try await coordinator.acquire(); try recovered.store(RequestState()) }
        for iteration in 0..<8 {
            let location = root.appendingPathComponent("ipc-requests-\(iteration)")
            let (one, out1) = try process(["request", location.path, pdf.path])
            let (two, out2) = try process(["request", location.path, pdf.path])
            one.waitUntilExit(); two.waitUntilExit()
            let times = [out1, out2].flatMap { pipe -> [Double] in
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return text.split(separator: "\n").compactMap { $0.hasPrefix("request ") ? Double($0.dropFirst(8)) : nil }
            }.sorted()
            try expect(one.terminationStatus == 0 && two.terminationStatus == 0 && times.count == 3, "independent processes download and reuse PDF")
            try expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 0.19 }, "request interval enforced across processes")
        }
        let cooldown = root.appendingPathComponent("ipc-cooldown")
        let (limited, limitedOut) = try process(["429", cooldown.path, pdf.path]); limited.waitUntilExit()
        let (blocked, blockedOut) = try process(["request", cooldown.path, pdf.path]); blocked.waitUntilExit()
        let limitedText = String(decoding: limitedOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let blockedText = String(decoding: blockedOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expect(limitedText.contains("request ") && blockedText == "cooldown\n", "cooldown survives independent process restart")
        let suite = "arxiv-ipc-prefs-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(root.appendingPathComponent("preferences-folder").path, forKey: "saveDirectory")
        preferences.set(NamingStyle.identifierTitle.rawValue, forKey: "namingStyle")
        preferences.synchronize() // Test barrier before starting an independent reader.
        let (reader, prefsOut) = try process(["preferences", suite]); reader.waitUntilExit()
        let prefsText = String(decoding: prefsOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expect(prefsText == root.appendingPathComponent("preferences-folder").path + "\nidentifierTitle\n", "shared preferences can be read by another process")

        let cli = executable.deletingLastPathComponent().appendingPathComponent("arxiv-download-test")
        for arguments in [["--help"], ["--version"], ["--unknown"], ["not-an-arxiv-link", "--json"]] {
            let child = Process(); let out = Pipe(); let error = Pipe()
            child.executableURL = cli; child.arguments = arguments; child.standardOutput = out; child.standardError = error
            try child.run(); child.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status: Int32 = arguments == ["--unknown"] ? 2 : arguments[0] == "not-an-arxiv-link" ? 1 : 0
            try expect(child.terminationStatus == status, "CLI executable exit status")
            if arguments.last == "--json" { _ = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
            else if status == 0 { try expect(!text.isEmpty, "CLI executable help/version output") }
        }
        for signal in [SIGINT, SIGTERM] {
            let coordinator = RequestCoordinator(directory: root.appendingPathComponent("cli-signal-\(signal)"))
            let held = try await coordinator.acquire()
            let child = Process(); let out = Pipe(); let error = Pipe()
            child.executableURL = cli
            child.arguments = ["2501.12345", "2501.12345v2", "--json", "-o", root.appendingPathComponent("cli-signal-papers-\(signal)").path]
            var environment = ProcessInfo.processInfo.environment
            environment["ARXIV_TEST_COORDINATION"] = coordinator.directory.path
            child.environment = environment; child.standardOutput = out; child.standardError = error
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            let waiting = error.fileHandleForReading.availableData
            try expect(String(decoding: waiting, as: UTF8.self).contains("等待其他下载任务"), "CLI signal test reached cancellable lock wait")
            try expect(kill(child.processIdentifier, signal) == 0, "signal CLI child")
            child.waitUntilExit()
            let report = try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
            let rows = report["results"] as! [[String: Any]]
            try expect(child.terminationStatus == 128 + signal && rows.count == 2 && rows.allSatisfy { $0["status"] as? String == "cancelled" }, "SIGINT/SIGTERM gracefully emit cancellation JSON")
            try expect(!FileManager.default.fileExists(atPath: coordinator.directory.appendingPathComponent("request-state.json").path), "cancelled CLI never made a request")
            withExtendedLifetime(held) { }
        }
        print("PASS IPC: two processes serialized, request spacing, waiting cancellation, SIGKILL lock release, shared preferences/cooldown and CLI SIGINT/SIGTERM")
    }
}
