import Foundation

extension CoreTests {
    @MainActor static func messageTests() throws {
        let previousLanguage = L10n.language
        defer { L10n.language = previousLanguage }
        for id in DiagnosticMessage.ID.allCases {
            guard let english = L10n.english[id.rawValue] else { throw TestFailure.failed("missing stable-message translation: " + id.rawValue) }
            try expect(id.template.components(separatedBy: "%@").count == english.components(separatedBy: "%@").count,
                       "stable-message translations preserve their argument count")
        }
        let stable = DiagnosticMessage(id: DiagnosticMessage.ID.invalidPDF.rawValue, arguments: [], fallback: "An older wording")
        let unknown = DiagnosticMessage(id: "future.message", arguments: ["ignored"], fallback: "Future fallback")
        let malformed = DiagnosticMessage(id: DiagnosticMessage.ID.http.rawValue, arguments: [], fallback: "Malformed fallback")
        L10n.language = .chinese
        try expect(L10n.text(stable) == DiagnosticMessage.ID.invalidPDF.template, "known Chinese messages resolve by identifier rather than fallback wording")
        try expect(L10n.text(unknown) == unknown.fallback && L10n.text(malformed) == malformed.fallback,
                   "unknown identifiers and wrong argument counts keep their readable fallback")
        L10n.language = .english
        try expect(L10n.text(stable) == "The response is not a complete, readable PDF. It was not saved.", "stable English messages do not depend on the old source wording")
        try expect(L10n.text(unknown) == unknown.fallback && L10n.text(malformed) == malformed.fallback,
                   "English fallback handles future identifiers and malformed arguments")
        try expect(L10n.text(DiagnosticMessage(.storage, "所选目录不存在，请重新选择。")) == "Could not save: The selected folder does not exist. Choose another folder.",
                   "typed errors still translate legacy nested detail strings")
        for (message, expected) in [
            (DiagnosticMessage(.start, "1"), "Starting download · 1 item"),
            (DiagnosticMessage(.start, "2"), "Starting download · 2 items"),
            (DiagnosticMessage(.startDeduplicated, "1", "1"), "Starting download · 1 item · 1 duplicate removed"),
            (DiagnosticMessage(.startDeduplicated, "1", "2"), "Starting download · 1 item · 2 duplicates removed"),
            (DiagnosticMessage(.startDeduplicated, "2", "1"), "Starting download · 2 items · 1 duplicate removed"),
            (DiagnosticMessage(.retry, "1"), "Retrying 1 item"),
            (DiagnosticMessage(.restored, "1"), "Restored 1 unfinished task")
        ] { try expect(L10n.text(message) == expected, "stable log messages preserve English singular counts") }
        let literal = "100% %@ https://example.org/file.pdf?a=b"
        try expect(L10n.text(DiagnosticMessage(.metadata, literal)) == literal, "arguments are inserted literally rather than treated as format strings")
        try expect(DownloadError.http(403, retryAfter: nil).message.id == DiagnosticMessage.ID.forbidden.rawValue &&
                   DownloadError.http(500, retryAfter: nil).message.arguments == ["500"], "HTTP errors retain typed codes")
        try expect(DownloadError.cooldown(.infinity).message.id == DiagnosticMessage.ID.unknownCooldown.rawValue &&
                   DownloadError.cooldown(61).message.arguments == ["2"], "cooldown formatting preserves bounds and minute rounding")
        try expect(DiagnosticMessage.downloadFailure(URLError(.timedOut)).id == DiagnosticMessage.ID.networkTimeout.rawValue &&
                   DiagnosticMessage.downloadFailure(URLError(.cannotWriteToFile)).id == DiagnosticMessage.ID.temporaryStorage.rawValue,
                   "network and temporary-storage errors retain their specific identities")

        var item = DownloadItem(original: "bad-link", state: .failed)
        item.setError(stable)
        try expect(item.localizedError == L10n.text(stable), "download records present the stable message")
        item.error = "Replacement error"
        try expect(item.errorMessage == nil && item.localizedError == "Replacement error", "replacing a legacy error clears stale structured metadata")
        item.setError(stable); item.error = nil
        try expect(item.errorMessage == nil && item.localizedError == nil, "clearing an error clears both stored representations")
        print("PASS stable messages: identifiers, source-independent rendering, fallback, literal arguments, counts and error replacement")
    }

    @MainActor static func messagePersistenceTests(root: URL, pdf: URL) async throws {
        let suite = "folioak-message-persistence-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let previousLanguage = L10n.language
        defer { preferences.removePersistentDomain(forName: suite); L10n.language = previousLanguage }
        let model = DownloadModel(preferences: preferences)
        var item = DownloadItem(original: "bad-link", state: .failed)
        item.setError(DiagnosticMessage(.invalidInput))
        model.items = [item]
        let privateURL = "https://user:password@example.org/file.pdf?token=secret#private"
        model.record(.error, DiagnosticMessage(.storage, "Failed " + privateURL), item: item)
        guard let entry = model.logs.last, let payload = entry.diagnostic else { throw TestFailure.failed("structured diagnostic missing") }
        try expect(payload.arguments == ["Failed https://example.org/file.pdf"] &&
                   !payload.fallback.contains("secret") && !entry.message.contains("password") && !entry.line.contains("private"),
                   "structured log arguments, fallback, legacy text and copied lines all redact signed URLs")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let snapshot = WorkspaceSnapshot(input: "unchanged draft", items: [item], history: [], logs: [entry])
        let newData = try encoder.encode(snapshot)
        struct LegacyItem: Decodable { let original: String; let error: String? }
        struct LegacyLog: Decodable { let message: String }
        struct LegacySnapshot: Decodable { let schema: Int; let input: String; let items: [LegacyItem]; let logs: [LegacyLog] }
        let legacyReader = try JSONDecoder().decode(LegacySnapshot.self, from: newData)
        try expect(legacyReader.schema == 1 && legacyReader.items[0].error == item.error && legacyReader.logs[0].message == entry.message,
                   "new snapshots keep schema 1 and the old error/message fields for older readers")
        var oldObject = try JSONSerialization.jsonObject(with: newData) as! [String: Any]
        var oldItems = oldObject["items"] as! [[String: Any]]
        var oldLogs = oldObject["logs"] as! [[String: Any]]
        oldItems[0].removeValue(forKey: "errorMessage"); oldLogs[0].removeValue(forKey: "diagnostic")
        oldObject["items"] = oldItems; oldObject["logs"] = oldLogs
        let oldURL = root.appendingPathComponent("legacy-messages.json")
        try JSONSerialization.data(withJSONObject: oldObject).write(to: oldURL)
        let oldSnapshot = try WorkspaceStore.read(oldURL)!
        try expect(oldSnapshot.items[0].errorMessage == nil && oldSnapshot.logs[0].diagnostic == nil &&
                   oldSnapshot.items[0].error == item.error && oldSnapshot.logs[0].message == entry.message,
                   "old snapshots without optional message payloads decode unchanged")
        L10n.language = .english
        try expect(oldSnapshot.items[0].localizedError?.hasPrefix("Unrecognized input.") == true,
                   "old error strings keep their presentation translation")
        let newURL = root.appendingPathComponent("new-messages.json")
        try WorkspaceStore.write(snapshot, to: newURL)
        let loaded = try WorkspaceStore.read(newURL)!
        let storedBytes = try Data(contentsOf: newURL)
        L10n.language = .chinese
        _ = loaded.items[0].localizedError; _ = loaded.logs[0].line
        L10n.language = .english
        _ = loaded.items[0].localizedError; _ = loaded.logs[0].line
        try expect(try encoder.encode(loaded) == newData && Data(contentsOf: newURL) == storedBytes,
                   "changing presentation language leaves structured records and on-disk JSON unchanged")
        let future = DiagnosticMessage(id: "future.error", arguments: ["future argument"], fallback: "Readable future error")
        var futureItem = item; futureItem.setError(future)
        let futureURL = root.appendingPathComponent("future-messages.json")
        var malformedItem = item; malformedItem.id = UUID()
        malformedItem.setError(DiagnosticMessage(id: DiagnosticMessage.ID.http.rawValue, arguments: [], fallback: "Readable malformed error"))
        try WorkspaceStore.write(WorkspaceSnapshot(input: "", items: [futureItem, malformedItem], history: [], logs: []), to: futureURL)
        let futureRecords = try WorkspaceStore.read(futureURL)!.items
        try expect(futureRecords[0].localizedError == future.fallback && futureRecords[1].localizedError == malformedItem.error,
                   "unknown future messages and malformed argument counts survive disk round trips")

        // Exercise the actual queue failure path, rather than only hand-built records.
        let state = root.appendingPathComponent("queue-messages/workspace.json")
        let output = root.appendingPathComponent("queue-message-files")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let failing = DownloadEngine(transport: MockTransport(sourcePDF: pdf, metadata: [.status(403)]), requestInterval: 0, retryDelay: 0)
        let queue = DownloadModel(engine: failing, preferences: preferences, stateURL: state)
        queue.directory = output; queue.input = "2501.12345v2\nbad-link"; queue.start()
        try await waitForQueue(queue)
        let saved = try WorkspaceStore.read(state)!
        try expect(saved.items.map { $0.errorMessage?.id } == [DiagnosticMessage.ID.forbidden.rawValue, DiagnosticMessage.ID.invalidInput.rawValue] &&
                   saved.logs.contains { $0.diagnostic?.id == DiagnosticMessage.ID.forbidden.rawValue } &&
                   saved.logs.contains { $0.diagnostic?.id == DiagnosticMessage.ID.finished.rawValue },
                   "queue failures and completion diagnostics persist stable identities")
        let successful = DownloadEngine(transport: MockTransport(sourcePDF: pdf), requestInterval: 0, retryDelay: 0)
        let restored = DownloadModel(engine: successful, preferences: preferences, stateURL: state)
        L10n.language = .english
        restored.items[0].setError(DiagnosticMessage(id: DiagnosticMessage.ID.forbidden.rawValue, arguments: [], fallback: "Obsolete diagnostic wording"))
        let failed = restored.items[0]
        let report = TaskDiagnosticView(model: restored, item: failed).report
        try expect(failed.localizedError?.contains("(403)") == true && report.contains(L10n.text(failed.errorMessage!)) && !report.contains("Obsolete diagnostic wording"),
                   "restart, detail presentation and copied diagnostics use the stored message identity")
        restored.retry(failed.id)
        try expect(restored.items[0].error == nil && restored.items[0].errorMessage == nil, "retry clears both error representations before execution")
        try await waitForQueue(restored)
        let retried = try WorkspaceStore.read(state)!.items[0]
        try expect(retried.state == .saved && retried.error == nil && retried.errorMessage == nil,
                   "successful retry persists without stale error metadata")

        let large = String(repeating: "x", count: 40_000)
        let bulky = (0..<120).map { _ -> DownloadItem in
            var result = DownloadItem(original: "bad-link", state: .failed)
            result.setError(DiagnosticMessage(.metadata, large))
            return result
        }
        let pressureURL = root.appendingPathComponent("message-pressure.json")
        let retained = try WorkspaceStore.write(WorkspaceSnapshot(input: "keep this draft", items: [], history: bulky, logs: []), to: pressureURL)
        try expect(retained.input == "keep this draft" && !retained.history.isEmpty && retained.history.count < bulky.count &&
                   (try Data(contentsOf: pressureURL)).count <= WorkspaceStore.byteLimit,
                   "byte pressure includes structured arguments and fallback while preserving the draft and newest records")
        print("PASS message persistence: legacy/new JSON, language independence, redaction, real queue/restart/retry, copied diagnostics and byte pressure")
    }
}
