import Foundation
import AppKit

extension CoreTests {
    static func logGroupingTests() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = ISO8601DateFormatter().date(from: "2026-10-09T23:59:58Z")!
        let first = UUID(), second = UUID()
        func entry(_ offset: TimeInterval, _ id: UUID?, _ subject: String?, _ level: ActivityLevel = .info) -> ActivityEntry {
            ActivityEntry(date: start.addingTimeInterval(offset), level: level, message: "事件 \(offset)", subject: subject, itemID: id)
        }
        let entries = [entry(0, first, "1706.03762"), entry(1, first, "同名论文", .success),
                       entry(3, first, "同名论文"), entry(4, second, "同名论文"), entry(5, first, "同名论文"),
                       entry(6, nil, "旧记录"), entry(7, nil, "旧记录"), entry(8, nil, nil)]
        let headings = LogHeading.headings(entries, calendar: calendar)
        try expect(Set(headings.keys) == Set([0, 2, 3, 4, 5, 6, 7].map { entries[$0].id }), "logs preserve task identity, interleaving, midnight boundaries and unidentified events")
        try expect(headings[entries[0].id]?.subject == "同名论文", "a group's resolved title replaces its initial identifier")
        try expect(Set(headings.filter { $0.value.date != nil }.keys) == Set([entries[0].id, entries[2].id]), "each visible day has one date heading")
        let filtered = LogHeading.headings(entries.filter { $0.level == .success }, calendar: calendar)
        try expect(filtered[entries[1].id]?.subject == "同名论文" && filtered[entries[1].id]?.date != nil, "filtered results supply their own title and date context")
        let many = (0..<1501).map { entry(Double($0), first, "论文") }
        let trimmed = LogHeading.headings(Array(many.suffix(1500)), calendar: calendar)
        try expect(trimmed[many[1].id]?.subject == "论文" && trimmed[many[1].id]?.date != nil && trimmed.count == 2, "trimmed logs retain date boundaries without copying every entry")
        print("PASS log grouping: identity, resolved titles, interleaving, dates, filtering and retention")
    }

    @MainActor static func workspaceBenchmark(root: URL) throws {
        let ref = try ArxivReference.parse("1706.03762v1")
        let metadata = PaperMetadata(reference: ref, title: "Attention Is All You Need — performance fixture", year: 2017, month: 6)
        let history = (0..<500).map { n in
            DownloadItem(original: ref.identifier, reference: ref, metadata: metadata, state: .saved, savedURL: root.appendingPathComponent("paper-\(n).pdf"))
        }
        let logs = (0..<1500).map { n in ActivityEntry(level: .info, message: "记录 \(n) · 校验并保存", subject: metadata.title, itemID: nil) }
        let snapshot = WorkspaceSnapshot(input: "1706.03762v1", items: Array(history.prefix(200)), history: history, logs: logs)
        let target = root.appendingPathComponent("benchmark.json")
        var times: [Double] = []
        for _ in 0..<30 {
            let start = Date()
            try WorkspaceStore.write(snapshot, to: target)
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        times.sort()
        let bytes = try Data(contentsOf: target).count
        try expect(try WorkspaceStore.read(target)?.history.count == 500, "full ordinary history survives benchmark")
        print(String(format: "BENCH workspace: 200 tasks / 500 history / 1500 logs; %d bytes; save median %.2f ms / p95 %.2f ms", bytes, times[15], times[28]))
    }

    static func sidebarMotionTests() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var motion = SelectionIndicatorMotion(index: 0)
        let original = motion.rect(at: start)
        motion.select(2, stride: 50, at: start, reduceMotion: false)
        try expect(motion.rect(at: start) == original, "selection starts from the visible indicator")
        let middle = motion.rect(at: start.addingTimeInterval(0.16))
        try expect(middle.height > 16 && middle.minY >= original.minY && middle.maxY <= motion.target.maxY, "indicator stretches within the old and target rows")
        let settled = motion.rect(at: start.addingTimeInterval(0.32))
        try expect(abs(settled.midY - 122) < 0.001 && abs(settled.height - 16) < 0.001, "indicator settles centered on the target row")
        let reverseAt = start.addingTimeInterval(0.16)
        motion.select(0, stride: 50, at: reverseAt, reduceMotion: false)
        try expect(motion.rect(at: reverseAt) == middle, "rapid reversal must not jump back to a previous row")
        for frame in 0...20 {
            let rect = motion.rect(at: reverseAt.addingTimeInterval(Double(frame) * 0.016))
            try expect(rect.height >= 16 && rect.minY >= original.minY - 0.001 && rect.maxY <= middle.maxY + 0.001, "reversed animation remains bounded")
        }
        try expect(motion.rect(at: reverseAt.addingTimeInterval(1)) == original, "reversal reaches its destination")
        motion.select(1, stride: 50, at: start, reduceMotion: true)
        try expect(motion.rect(at: start) == motion.target, "reduced motion switches immediately")
        for name in ["arrow.down.circle", "arrow.down.circle.fill", "books.vertical", "books.vertical.fill", "text.alignleft", "doc.text"] {
            try expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "navigation and task symbols exist")
        }
        let firstTab = CGRect(x: 12, y: 33, width: 24, height: 3)
        let lastTab = CGRect(x: 216, y: 33, width: 36, height: 3)
        var tabs = SelectionIndicatorMotion(rect: firstTab, axis: .horizontal)
        tabs.select(lastTab, at: start, reduceMotion: false)
        let stretched = tabs.rect(at: start.addingTimeInterval(0.16))
        try expect(stretched.width > lastTab.width && stretched.minX >= firstTab.minX && stretched.maxX <= lastTab.maxX, "horizontal tabs stretch within measured label bounds")
        try expect(tabs.rect(at: start.addingTimeInterval(1)) == lastTab, "tab underline settles at the target label width")
        tabs.select(firstTab, at: reverseAt, reduceMotion: false)
        try expect(tabs.rect(at: reverseAt) == stretched, "rapid tab reversal keeps its current geometry")
        for frame in 0...20 {
            let rect = tabs.rect(at: reverseAt.addingTimeInterval(Double(frame) * 0.016))
            try expect(rect.width >= firstTab.width - 0.001 && rect.minX >= firstTab.minX - 0.001 && rect.maxX <= stretched.maxX + 0.001 && rect.height == 3, "horizontal reversal remains bounded and thin")
        }
        tabs.select(lastTab, at: start, reduceMotion: true)
        try expect(tabs.rect(at: start) == lastTab, "reduced motion also applies to horizontal tabs")
        let widths: [Int: CGFloat] = [0: 48, 1: 60, 2: 72]
        try expect(FilterTabLayout.indicator(widths: widths, index: 0) == firstTab, "first underline has local text insets")
        try expect(FilterTabLayout.indicator(widths: widths, index: 2) == CGRect(x: 128, y: 33, width: 48, height: 3), "unequal labels include their widths and inter-tab gaps")
        try expect(FilterTabLayout.indicator(widths: [2: 72], index: 2) == nil, "incomplete layout cannot place the indicator in a guessed position")
        print("PASS selection motion: both axes, measured widths, stretch, settle, interrupted reversal, reduced motion and symbols")
    }

    @MainActor static func workspaceTests(root: URL, pdf: URL) async throws {
        let suite = "arxiv-workspace-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let state = root.appendingPathComponent("state/workspace.json")
        let output = root.appendingPathComponent("workspace-papers")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let transport = MockTransport(sourcePDF: pdf)
        let model = DownloadModel(engine: DownloadEngine(transport: transport, requestInterval: 0, retryDelay: 0), preferences: prefs, stateURL: state)
        model.directory = output
        model.input = "2501.12345v2\nbad-link"
        model.start()
        try await waitForQueue(model)
        try expect(model.logs.contains { $0.level == .error } && model.logs.contains { $0.level == .success }, "structured success and failure logs")
        guard let successIndex = model.logs.firstIndex(where: { $0.level == .success }),
              let validationIndex = model.logs.firstIndex(where: { $0.message == ItemState.validating.label }) else { throw TestFailure.failed("missing ordered events") }
        try expect(validationIndex < successIndex, "validation must appear before completion in logs")
        let restored = DownloadModel(preferences: prefs, stateURL: state)
        try expect(restored.items.count == 2 && restored.successes == 1 && restored.input == "bad-link", "queue and draft survive restart")
        try expect(restored.history.count == 1 && restored.history[0].savedURL == model.items[0].savedURL, "library persists PDF paths")
        try expect(restored.logs.map(\.id) == model.logs.map(\.id), "log identity persists")
        let permissions = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "private workspace permissions")

        model.input = "2501.12345v2"
        model.start()
        try await waitForQueue(model)
        try expect(model.history.count == 1, "repeated download reuses library record")
        let savedID = model.items[0].id
        model.items.append(DownloadItem(original: "2502.12345", reference: try ArxivReference.parse("2502.12345"), state: .downloading, progress: DownloadProgress(received: 5, total: 10)))
        model.input = "2502.12345"
        model.persistWorkspace()
        let interrupted = DownloadModel(preferences: prefs, stateURL: state)
        try expect(interrupted.items[0].id == savedID && interrupted.items[0].state == .existing, "completed state preserved after interrupted batch")
        try expect(interrupted.items[1].state == .cancelled && interrupted.items[1].progress == nil && interrupted.items[1].canRetry && !interrupted.busy, "interrupted work restores without automatically using network")
        try expect(interrupted.input == "2502.12345", "interrupted input preserved")

        for i in 0...WorkspaceStore.logLimit { model.record(.info, "entry \(i)") }
        try expect(model.logs.count == WorkspaceStore.logLimit && model.logs.last?.message == "entry \(WorkspaceStore.logLimit)", "bounded logs retain newest entries")
        for scheme in ["https", "HTTPS", "hTtPs", "HTTP"] {
            let redacted = ActivityEntry.redacted("Failed \(scheme)://user:password@example.com/file.pdf?token=secret#private")
            try expect(!redacted.contains("password") && !redacted.contains("secret") && !redacted.contains("private"), "URL redaction is case insensitive")
        }
        let secret = "https://user:password@example.com/file.pdf?token=secret#private"
        for malformed in ["https://user:password@[invalid/file?token=secret", "HTTPS://user:password@example.com:bad/file?token=secret"] {
            try expect(ActivityEntry.redacted("Failed \(malformed)") == "Failed [链接]", "malformed URL credentials are redacted")
        }
        let scrubbed = ActivityEntry.redacted("Failed \(secret) and https://example.net/report?key=secret")
        try expect(!scrubbed.contains("secret") && !scrubbed.contains("password") && !scrubbed.contains("private") && scrubbed.contains("file.pdf"), "diagnostic URLs redact query, credentials and fragments")
        model.record(.error, secret, item: DownloadItem(original: secret, reference: nil, state: .failed))
        try expect(!model.logs.last!.line.contains("secret"), "redaction applies to messages and subjects")
        model.persistWorkspace()
        try expect(try WorkspaceStore.read(state)?.logs.count == WorkspaceStore.logLimit, "bounded logs roundtrip")

        let missing = model.history[0]
        try FileManager.default.removeItem(at: missing.savedURL!)
        model.openFile(missing)
        let libraryMissing = model.history[0]
        try expect(libraryMissing.state == .missing && libraryMissing.savedURL == nil, "missing file updates library state")
        model.input = "2503.99999"
        model.retryFromLibrary(libraryMissing)
        try await waitForQueue(model)
        try expect(model.items.count == 1 && model.successes == 1 && model.input == "2503.99999", "library repair downloads one exact version and preserves draft")
        try expect(model.history.count == 1 && model.history[0].id == missing.id && model.history[0].state == .saved, "library repair replaces missing record without duplicates")

        let export1 = try WorkspaceStore.export(Data("one".utf8), named: "log.txt", to: output)
        let export2 = try WorkspaceStore.export(Data("two".utf8), named: "log.txt", to: output)
        try expect(export1 != export2 && (try String(contentsOf: export1, encoding: .utf8)) == "one" && (try String(contentsOf: export2, encoding: .utf8)) == "two", "exports never replace existing files")

        let corrupt = root.appendingPathComponent("corrupt.json")
        let original = Data("{broken".utf8)
        try original.write(to: corrupt)
        let damaged = DownloadModel(preferences: prefs, stateURL: corrupt)
        try expect(damaged.persistenceNotice != nil && damaged.items.isEmpty, "corrupt state is recoverable")
        damaged.input = "1706.03762"
        damaged.persistWorkspace()
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("corrupt.json.backup-") }
        try expect(backups.count == 1 && (try Data(contentsOf: backups[0])) == original, "corrupt original is preserved before new state is saved")
        try expect(try WorkspaceStore.read(corrupt)?.input == "1706.03762", "writing works after corrupt state recovery")

        let tooMany = WorkspaceSnapshot(input: "", items: [], history: [], logs: Array(repeating: model.logs[0], count: WorkspaceStore.logLimit + 1))
        let malformed = root.appendingPathComponent("oversized-state.json")
        try JSONEncoder().encode(tooMany).write(to: malformed)
        try rejects({ _ = try WorkspaceStore.read(malformed) }, "over-limit state accepted")
        let invalidURL = DownloadItem(original: "broken", reference: nil, directURL: URL(string: "file:///etc/passwd"), state: .cancelled)
        try JSONEncoder().encode(WorkspaceSnapshot(input: "", items: [invalidURL], history: [], logs: [])).write(to: malformed)
        try rejects({ _ = try WorkspaceStore.read(malformed) }, "unsafe decoded URL accepted")
        let invalidReference = DownloadItem(original: "broken", reference: ArxivReference(baseID: "not an ID", version: nil), state: .queued)
        try JSONEncoder().encode(WorkspaceSnapshot(input: "", items: [invalidReference], history: [], logs: [])).write(to: malformed)
        try rejects({ _ = try WorkspaceStore.read(malformed) }, "invalid decoded reference accepted")
        let longTitle = String(repeating: "论文", count: 2048)
        let metadata = PaperMetadata(reference: try ArxivReference.parse("1706.03762v1"), title: longTitle, year: 2017, month: 6)
        let largeHistory = (0..<WorkspaceStore.historyLimit).map { n in
            DownloadItem(original: "1706.03762v1", reference: metadata.reference, metadata: metadata, state: .saved, savedURL: output.appendingPathComponent("paper-\(n).pdf"))
        }
        let largeLogs = (0..<WorkspaceStore.logLimit).map { _ in
            ActivityEntry(level: .error, message: String(longTitle.prefix(2048)), subject: String(longTitle.prefix(2048)), itemID: nil)
        }
        let largeState = root.appendingPathComponent("large-state.json")
        let large = WorkspaceSnapshot(input: "keep-draft", items: Array(largeHistory.prefix(200)), history: largeHistory, logs: largeLogs)
        try expect(try JSONEncoder().encode(large).count > WorkspaceStore.byteLimit, "fixture exceeds persistence budget")
        let retained = try WorkspaceStore.write(large, to: largeState)
        let loaded = try WorkspaceStore.read(largeState)!
        try expect(loaded.input == "keep-draft" && loaded.items.map(\.id) == large.items.map(\.id), "byte pressure preserves all current tasks and draft")
        try expect(loaded.history.first?.id == largeHistory.first?.id && loaded.logs.last?.id == largeLogs.last?.id, "byte pressure keeps the newest history and logs")
        try expect(loaded.history.count < largeHistory.count && loaded.logs.count < largeLogs.count && retained.logs.count == loaded.logs.count, "bounded state can be saved and read again")
        try expect(try Data(contentsOf: largeState).count <= WorkspaceStore.byteLimit * 3 / 4, "trimmed snapshots leave growth headroom")
        let compact = DownloadModel(preferences: prefs, stateURL: largeState)
        compact.history = largeHistory; compact.logs = largeLogs
        compact.persistWorkspace()
        try expect(compact.persistenceNotice == nil && compact.history.count < largeHistory.count && compact.logs.count < largeLogs.count, "in-memory retention follows the successfully saved snapshot")

        let badParent = root.appendingPathComponent("not-a-directory")
        try Data().write(to: badParent)
        let unwritable = DownloadModel(preferences: prefs, stateURL: badParent.appendingPathComponent("workspace.json"))
        unwritable.persistWorkspace()
        try expect(unwritable.persistenceNotice != nil, "storage failure remains visible")

        model.input = "keep-this-draft"
        model.appendInput(String(repeating: "x", count: ResourceLimits.inputBytes))
        try expect(model.input == "keep-this-draft" && model.notice != nil, "oversized import preserves draft")
        model.edit(DownloadItem(original: "missing-link", reference: nil, state: .failed))
        try expect(model.input.contains("missing-link") && model.editTarget == "missing-link", "editing restored invalid links reintroduces the target")
        model.persistWorkspace()
        print("PASS workspace: ordered logs, restart recovery, library deduplication, redaction, retention, atomic state and corruption recovery")
    }
}
