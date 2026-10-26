import AppKit
import Foundation

extension CoreTests {
    @MainActor static func featureTests(root: URL, pdf: URL) async throws {
        let mixed = "推荐：[Attention](https://arxiv.org/abs/1706.03762v1)\n另一篇 arXiv: 2003.07733v2\nPDF <https://example.org/file(a).pdf>\nHF https://huggingface.co/papers/2608.15763。"
        let captured = try PaperInput.captured(mixed)
        let batch = try BatchInput(captured)
        try expect(batch.entries.count == 4 && batch.entries.allSatisfy { $0.source != nil }, "capture extracts links and IDs from Markdown and prose")
        try expect(try PaperInput.captured("https://example.org/file.pdf?sig=abc)") == "https://example.org/file.pdf?sig=abc)", "bare signed query closing parenthesis preserved")
        try expect(try PaperInput.captured("[https://github.com/openai/math/blob/main/overview.pdf](https://github.com/openai/math/blob/main/overview.pdf)") == "https://github.com/openai/math/blob/main/overview.pdf", "URL as Markdown label resolves destination once")
        try expect(try PaperInput.captured("[1706.03762](https://arxiv.org/abs/1706.03762)") == "https://arxiv.org/abs/1706.03762", "ID label does not create duplicate input")
        let signed = "https://example.org/file.pdf?sig=a,b;c%2Bd&token=secret"
        try expect(try PaperInput.captured("[PDF](\(signed))") == signed, "capture preserves signed URL punctuation")
        try expect(try PaperInput.captured("bad-link") == "bad-link", "unrecognized input remains editable")
        let bvInput = "BV1MaHp6KENU"
        let bvSuite = "folioak-bv-capture-\(UUID().uuidString)", bvPreferences = UserDefaults(suiteName: bvSuite)!
        defer { bvPreferences.removePersistentDomain(forName: bvSuite) }
        let bvModel = DownloadModel(preferences: bvPreferences)
        bvModel.appendInput(bvInput)
        let bvBatch = try BatchInput(bvModel.input)
        try expect(bvModel.hasMediaInput && bvBatch.entries.count == 1 && bvBatch.entries[0].source?.webURL.absoluteString == "https://www.bilibili.com/video/BV1MaHp6KENU/", "app capture and batch input recognize a complete BV identifier through the shared parser")
        let mixedBV = "https://example.org/file.pdf\n\(bvInput)\n1706.03762"
        bvModel.input = ""; bvModel.appendInput(mixedBV)
        try expect(bvModel.input == mixedBV && (try BatchInput(bvModel.input)).entries.count == 3, "mixed paste retains PDF, BV and arXiv inputs")
        let bvFile = root.appendingPathComponent("bv-links.txt")
        try Data(mixedBV.utf8).write(to: bvFile)
        try expect(try await CLIOptions.parse(["-i", bvFile.path]).resolvedInput() == mixedBV, "CLI file import retains mixed BV input")
        try expect(try PaperInput.decode(Data(mixedBV.utf8)) == mixedBV, "stdin decoding retains mixed BV input")
        for invalid in ["bv1MaHp6KENU", "BV1MaHp6KEN0", "prefixBV1MaHp6KENU", "BV1MaHp6KENU.txt"] {
            try expect(try PaperInput.captured("https://example.org/file.pdf\n" + invalid) == "https://example.org/file.pdf", "capture does not promote malformed BV text")
        }
        try rejects({ _ = try PaperInput.captured(String(repeating: "1706.03762 ", count: 201)) }, "capture batch limit before dedup")
        try rejects({ _ = try PaperInput.captured(String(repeating: "x", count: ResourceLimits.inputBytes + 1)) }, "capture byte limit before extraction")
        try rejects({ _ = try PaperInput.decode(Data([0xff, 0xfe])) }, "non-UTF8 input rejected")
        let unsafe = try BatchInput(PaperInput.captured("PDF: https://user:password@example.org/p.pdf"))
        try expect(unsafe.entries.count == 1 && unsafe.entries[0].source == nil, "capture never bypasses URL validation")

        let file = root.appendingPathComponent("links.md")
        try Data(mixed.utf8).write(to: file)
        let options = try CLIOptions.parse(["-i", file.path, "--verbose", "--json"])
        let resolved = try await options.resolvedInput()
        try expect(options.verbose && options.json && resolved == captured, "CLI file shares smart capture")
        try expect(try CLIOptions.parse([], pipedInput: true).inputFiles == ["-"], "CLI automatic pipe")
        try expect(try CLIOptions.parse(["-i", "-"]).inputFiles == ["-"], "explicit stdin")
        try rejects({ _ = try CLIOptions.parse(["-", "-i", "-"]) }, "duplicate stdin rejected")
        let oversized = root.appendingPathComponent("oversized.txt")
        try Data(repeating: 65, count: ResourceLimits.inputBytes + 1).write(to: oversized)
        do { _ = try await CLIOptions.parse(["-i", oversized.path]).resolvedInput(); throw TestFailure.failed("oversized input file accepted") }
        catch DownloadError.limit { }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(mixed.utf8)); try pipe.fileHandleForWriting.close()
        let piped = try await CLIOptions.readStandardInput(descriptor: pipe.fileHandleForReading.fileDescriptor)
        try expect(try PaperInput.decode(piped) == captured, "bounded pipe UTF8 input")
        let held = Pipe()
        let waiting = Task { try await CLIOptions.readStandardInput(descriptor: held.fileHandleForReading.fileDescriptor) }
        try await Task.sleep(nanoseconds: 30_000_000); waiting.cancel()
        do { _ = try await waiting.value; throw TestFailure.failed("stdin cancellation ignored") } catch is CancellationError { }
        try held.fileHandleForWriting.close()

        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/folioak-test")
        for signal in [SIGINT, SIGTERM] {
            let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
            process.executableURL = executable; process.arguments = ["--json", "--verbose"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let ready = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            try expect(ready.contains("读取标准输入"), "CLI stdin signal handler ready")
            try expect(kill(process.processIdentifier, signal) == 0, "signal CLI blocked on stdin")
            let deadline = ContinuousClock().now.advanced(by: .seconds(3))
            while process.isRunning && ContinuousClock().now < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
            if !process.isRunning { process.waitUntilExit() }
            let stopped = !process.isRunning
            print("STDIN signal \(signal): stopped \(stopped), reason \(stopped ? process.terminationReason.rawValue : 0), status \(stopped ? process.terminationStatus : -1)")
            try expect(stopped && process.terminationReason == .exit && process.terminationStatus == 128 + signal, "SIGINT/SIGTERM cancels stdin without waiting for pipe EOF")
            try input.fileHandleForWriting.close()
        }
        let start = Date(timeIntervalSince1970: 1000)
        var trace = TaskDiagnostics(now: start)
        trace.receive(.metadata, now: start)
        trace.receive(.retry(1), now: start.addingTimeInterval(2))
        trace.receive(.waiting(start.addingTimeInterval(8)), now: start.addingTimeInterval(2))
        trace.receive(.retry(1), now: start.addingTimeInterval(8))
        trace.receive(.metadata, now: start.addingTimeInterval(8))
        trace.receive(.progress(DownloadProgress(received: 0, total: -1)), now: start.addingTimeInterval(10))
        for byte in 1...1000 { trace.receive(.progress(DownloadProgress(received: Int64(byte), total: 1000)), now: start.addingTimeInterval(10)) }
        trace.receive(.validating, now: start.addingTimeInterval(15))
        trace.finish(now: start.addingTimeInterval(16))
        trace.finish(now: start.addingTimeInterval(100))
        try expect(trace.elapsed() == 16 && trace.duration(.metadata) == 4 && trace.duration(.waiting) == 6 && trace.duration(.transfer) == 5 && trace.retries == 1, "phase durations and duplicate retry events")
        try expect(trace.valid && (try JSONEncoder().encode(trace)).count < 1024, "diagnostics remain bounded regardless of progress events")

        let suite = "arxiv-features-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let output = root.appendingPathComponent("feature-downloads")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("features.json")
        let model = DownloadModel(engine: DownloadEngine(transport: MockTransport(sourcePDF: pdf), requestInterval: 0, retryDelay: 0), preferences: prefs, stateURL: stateURL)
        model.directory = output
        model.input = "2003.07733"
        let provider = NSItemProvider(object: NSURL(string: "https://github.com/openai/math/blob/main/overview.pdf")!)
        let proseProvider = NSItemProvider(object: "推荐：[Paper](https://arxiv.org/abs/1706.03762v1)" as NSString)
        try expect(model.acceptDrop([provider, proseProvider]), "accept native URL and text drag providers")
        let dropDeadline = ContinuousClock().now.advanced(by: .seconds(3))
        while !model.input.contains("1706.03762v1") && ContinuousClock().now < dropDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(model.input == "2003.07733\nhttps://github.com/openai/math/blob/main/overview.pdf\n推荐：[Paper](https://arxiv.org/abs/1706.03762v1)", "drop appends in provider order and preserves prose without replacing input")
        model.busy = true
        let beforeBusyDrop = model.input
        try expect(model.acceptDrop([provider]), "busy queue accepts a new draft drop")
        let busyDropDeadline = ContinuousClock().now.advanced(by: .seconds(3))
        while model.input == beforeBusyDrop && ContinuousClock().now < busyDropDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(model.input == beforeBusyDrop + "\nhttps://github.com/openai/math/blob/main/overview.pdf", "busy drop appends to draft without submitting")
        model.busy = false; model.input = ""
        model.appendInput("https://arxiv.org/abs/2501.12345v2")
        model.start(); try await waitForQueue(model)
        let item = model.items[0]
        try expect(item.diagnostics?.finishedAt != nil && item.state == .saved, "successful model finalizes diagnostics")
        model.preview(item)
        try expect(model.previewURL == item.savedURL, "preview uses verified local URL")
        let restored = try WorkspaceStore.read(stateURL)
        try expect(restored?.items[0].diagnostics?.finishedAt != nil, "diagnostics survive restart")
        try FileManager.default.removeItem(at: item.savedURL!)
        model.preview(item)
        try expect(model.previewURL == nil && model.items[0].state == .missing && model.history[0].state == .missing, "preview missing file repairs queue and library")
        let old = DownloadItem(original: "2501.12345", reference: try ArxivReference.parse("2501.12345"), state: .saved)
        let oldData = try JSONEncoder().encode(old)
        try expect(try JSONDecoder().decode(DownloadItem.self, from: oldData).diagnostics == nil, "legacy records without diagnostics remain readable")
        print("PASS 2.1: smart capture, bounded files/pipes, stdin cancellation, diagnostics, persistence and preview missing-file recovery")
    }
}
