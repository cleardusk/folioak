import AppKit
import SwiftUI

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DownloadProgress] = []
    func add(_ value: DownloadProgress) { lock.lock(); values.append(value); lock.unlock() }
    var samples: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

extension CoreTests {
    @MainActor static func downloadProgressTests(root: URL, pdf: URL) async throws {
        FixtureProtocol.reset(); defer { FixtureProtocol.reset() }
        func ownedTemps() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("folioak-transfer-") } ?? []) }
        let initialTemps = ownedTemps()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let transport = URLSessionTransport(testConfiguration: configuration)
        let body = Data(repeating: 37, count: 262144)
        for known in [false, true] {
            let path = known ? "/known-progress" : "/unknown-progress"
            FixtureProtocol.install(.init(headers: known ? ["Content-Length": String(body.count)] : [:], body: body), path: path)
            let capture = ProgressCapture()
            let (file, _) = try await transport.download(for: URLRequest(url: URL(string: "https://arxiv.org" + path)!)) { capture.add($0) }
            defer { try? FileManager.default.removeItem(at: file) }
            let samples = capture.samples
            try expect(!samples.isEmpty && samples.contains { $0.received > 0 }, "real URLSession delegate reports bytes while downloading")
            try expect(samples.allSatisfy { known ? $0.total == Int64(body.count) : $0.fraction == nil }, "known and unknown totals retain honest progress semantics")
            try expect(try Data(contentsOf: file) == body, "delegate transfer preserves complete file contents")
        }
        try await transportTests(root: root, pdf: pdf)
        try expect(ownedTemps().subtracting(initialTemps).isEmpty, "transport failures and cancellation leave no owned temporary files")
        let palette = AppTheme.graphite.palette(dark: false)
        let appearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = appearance }
        let waiting = DownloadTransferProgress(progress: DownloadProgress(received: 0, total: -1), bytesPerSecond: nil, palette: palette)
        try expect(waiting.status == L("连接下载…"), "zero-byte transfer explicitly displays connection activity")
        let unknown = DownloadTransferProgress(progress: DownloadProgress(received: 32768, total: -1), bytesPerSecond: 4096, palette: palette)
        try expect(!unknown.status.contains("%") && unknown.status.contains("/s"), "unknown total shows actual bytes and rate without fake percent")
        let known = DownloadTransferProgress(progress: DownloadProgress(received: 50, total: 100), bytesPerSecond: nil, palette: palette)
        try expect(known.status.hasPrefix("50%"), "known total displays actual fraction")
        let suite = "folioak-progress-" + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let mock = MockTransport(sourcePDF: pdf, delay: 100_000_000, latestVersion: 1)
        let model = DownloadModel(engine: DownloadEngine(transport: mock, requestInterval: 0.8, retryDelay: 0), preferences: prefs)
        model.directory = root.appendingPathComponent("progress-output")
        var waitingSeen = false, downloadingSeen = false, missingProgress = false
        let observation = model.$items.sink { items in
            guard let item = items.first else { return }
            if case .waiting = item.state { waitingSeen = true }
            if item.state == .downloading { downloadingSeen = true; if item.progress == nil { missingProgress = true } }
        }
        defer { observation.cancel() }
        _ = try model.submitQuickDownload("2610.17080")
        for _ in 0..<500 {
            if let item = model.items.first {
                if case .waiting = item.state { waitingSeen = true }
                if item.state == .downloading { downloadingSeen = true; try expect(item.progress != nil, "downloading never comes from metadata alone") }
            }
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(waitingSeen && downloadingSeen && !missingProgress && model.items.first?.state == .saved, "arXiv pacing proceeds to visible transfer and saved result")
        let qa = URL(fileURLWithPath: "build/qa/library-grid"); try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        let states = [DownloadItem(original: "2610.17080", reference: try ArxivReference.parse("2610.17080"), state: .waiting(Date().addingTimeInterval(10))),
                      DownloadItem(original: "2610.17080", reference: try ArxivReference.parse("2610.17080"), state: .downloading, progress: DownloadProgress(received: 0, total: -1)),
                      DownloadItem(original: "2610.17080", reference: try ArxivReference.parse("2610.17080"), state: .downloading, progress: DownloadProgress(received: 6291456, total: 19656282))]
        let host = NSHostingView(rootView: VStack(spacing: 10) { ForEach(states) { DownloadRow(item: $0, model: model) } }.padding(16).frame(width: 620).foregroundStyle(ThemePalette.color(palette.text)).background(ThemePalette.color(palette.canvas)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("arxiv-progress-states.png"))
        }
        window.orderOut(nil)
        print("PASS arXiv progress: real URLSession delegate bytes, unknown length, cancellation and waiting-to-transfer state")
    }
}
