import AppKit
import SwiftUI

// The native service is optional in headless CI. A nil image is recorded as a
// fallback, never counted as successful thumbnail generation.
@MainActor enum ThumbnailTestMatrix {
    struct Result: Codable {
        let name: String
        let outcome: String
        let width: Int?
        let height: Int?
    }

    static func image(_ url: URL, cache: MediaThumbnailCache, timeout: Double = 2) async throws -> (NSImage?, Bool) {
        guard let key = MediaThumbnailCache.key(url: url, scale: 2) else {
            throw TestFailure.failed("thumbnail fixture has no local key: \(url.lastPathComponent)")
        }
        var settled = false, completed = false
        var generation: Task<Void, Never>?, deadline: Task<Void, Never>?
        let started = Date()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<(NSImage?, Bool), Never>) in
            generation = Task { @MainActor in
                let result = await cache.image(url: url, key: key, scale: 2)
                completed = true
                guard !settled else { return }
                settled = true
                continuation.resume(returning: (result, false))
            }
            deadline = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                catch { return }
                guard !settled else { return }
                settled = true
                generation?.cancel()
                continuation.resume(returning: (nil, true))
            }
        }
        deadline?.cancel()
        // A separate join bound detects a broken cancellation handler without
        // making a stalled OS service hang the entire regression process.
        let joinDeadline = Date().addingTimeInterval(1)
        while !completed && Date() < joinDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(completed && Date().timeIntervalSince(started) < timeout + 2, "native thumbnail cancellation completes within its deadline")
        return outcome
    }

    static func writeImage(_ url: URL, color: NSColor, jpeg: Bool = false) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard let pixels = bitmap.bitmapData, let rgb = color.usingColorSpace(.sRGB) else {
            throw TestFailure.failed("thumbnail bitmap pixels")
        }
        let rgba = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { UInt8(($0 * 255).rounded()) }
        for y in 0..<64 { for x in 0..<96 {
            for channel in 0..<4 { pixels[y * bitmap.bytesPerRow + x * 4 + channel] = rgba[channel] }
        } }
        guard let data = bitmap.representation(using: jpeg ? .jpeg : .png, properties: [:]) else {
            throw TestFailure.failed("thumbnail bitmap encoding")
        }
        try data.write(to: url, options: .atomic)
    }

    static func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            throw TestFailure.failed("Quick Look returned an unusable image")
        }
        return bitmap
    }

    static func center(_ image: NSImage) throws -> NSColor {
        let bitmap = try bitmap(image)
        guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else {
            throw TestFailure.failed("thumbnail pixel color")
        }
        return color
    }

    static func run(in root: URL, artifacts: URL? = nil) async throws -> [Result] {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        if let artifacts { try manager.createDirectory(at: artifacts, withIntermediateDirectories: true) }
        let fixtures = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/Media")
        let pdf = root.appendingPathComponent("document.pdf"), png = root.appendingPathComponent("image.png")
        try createPDF(at: pdf)
        try writeImage(png, color: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        let cover = root.appendingPathComponent("cover.jpg"), covered = root.appendingPathComponent("covered.mp3")
        try writeImage(cover, color: NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1), jpeg: true)
        let tools = try MediaTools.installed()
        // Stream-copy an existing audio signal and a generated JPEG. This needs
        // no development encoder, third-party artwork or additional fixture.
        let status = try await MediaProcess().run(try tools.executable("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-i", fixtures.appendingPathComponent("tone.mp3").path,
            "-i", cover.path, "-map", "0:a:0", "-map", "1:v:0", "-c", "copy", "-id3v2_version", "3",
            "-disposition:v:0", "attached_pic", covered.path
        ], timeout: 10) { _ in }
        try expect(status == 0, "covered audio fixture is generated with bundled stream-copy support")
        let coverStreams = try await FileStorage.validate(covered, extension: "mp3")
        try expect(coverStreams.contains { $0.codec_type == "audio" } &&
                   coverStreams.contains { $0.codec_type == "video" && !$0.isVideo }, "audio fixture has a real embedded cover")

        let corrupt = root.appendingPathComponent("corrupt.pdf")
        try Data("not a PDF or image".utf8).write(to: corrupt)
        let missing = root.appendingPathComponent("missing.pdf")
        let remote = URL(string: "https://example.com/unrequested-thumbnail.pdf")!
        for url in [missing, remote, root] {
            try expect(MediaThumbnailCache.key(url: url, scale: 2) == nil, "missing, remote and directory URLs never reach Quick Look")
        }
        func fallback(_ url: URL?, symbol: String = "doc.text") throws -> Data {
            let renderer = ImageRenderer(content: FileThumbnail(url: url, fallbackSymbol: symbol, palette: AppTheme.graphite.palette(dark: false))
                .environment(\.displayScale, 2))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let data = try bitmap(image).representation(using: .png, properties: [:]) else {
                throw TestFailure.failed("native fallback rendering")
            }
            return data
        }
        let fallbackPixels = try fallback(nil)
        for url in [missing, remote, root] {
            try expect(try fallback(url) == fallbackPixels, "unusable file URLs render the same FileThumbnail fallback as no file")
        }
        let cache = MediaThumbnailCache()
        var results: [Result] = []
        for (name, url) in [("pdf", pdf), ("png", png), ("video", fixtures.appendingPathComponent("h264.mp4")),
                            ("audio-without-cover", fixtures.appendingPathComponent("tone.m4a")),
                            ("audio-with-cover", covered), ("corrupt", corrupt)] {
            let (generated, expired) = try await image(url, cache: cache)
            let rep = try generated.map(bitmap)
            let outcome = generated != nil ? "thumbnail" : expired ? "timeout-fallback" : "fallback"
            results.append(Result(name: name, outcome: outcome, width: rep?.pixelsWide, height: rep?.pixelsHigh))
            if name == "corrupt" { try expect(generated == nil, "malformed PDF data falls back instead of displaying a stale thumbnail") }
            if let generated, name == "png" {
                let color = try center(generated)
                try expect(color.redComponent > color.greenComponent + 0.3, "PNG thumbnail contains the source pixels")
            }
            if let rep, let artifacts {
                try rep.representation(using: .png, properties: [:])?.write(to: artifacts.appendingPathComponent(name + ".png"))
            } else if let artifacts {
                let symbol = name.hasPrefix("audio") ? "waveform" : name == "video" ? "film" : name == "png" ? "photo" : "doc.text"
                try fallback(nil, symbol: symbol).write(to: artifacts.appendingPathComponent(name + "-fallback.png"))
            }
            if let generated, let key = MediaThumbnailCache.key(url: url, scale: 2) {
                let cached = await cache.image(url: url, key: key, scale: 2)
                try expect(cached === generated, "a successful native image is reused by the cache")
            }
        }
        for name in ["missing", "remote", "directory"] {
            results.append(Result(name: name, outcome: "guarded-fallback", width: nil, height: nil))
        }

        let cancellationFile = root.appendingPathComponent("cancel.png")
        try manager.copyItem(at: png, to: cancellationFile)
        guard let cancellationKey = MediaThumbnailCache.key(url: cancellationFile, scale: 2) else {
            throw TestFailure.failed("cancellation fixture key")
        }
        let cancellationCache = MediaThumbnailCache()
        let preCancelled = Task { await cancellationCache.image(url: cancellationFile, key: cancellationKey, scale: 2) }
        preCancelled.cancel()
        try expect(await preCancelled.value == nil, "pre-cancelled thumbnail work cannot return or cache an image")
        var started = false, completed = false
        let inFlight = Task { @MainActor in
            started = true
            let result = await cancellationCache.image(url: cancellationFile, key: cancellationKey, scale: 2)
            completed = true
            return result
        }
        while !started { await Task.yield() }
        if !completed {
            let start = Date()
            inFlight.cancel()
            while !completed && Date().timeIntervalSince(start) < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(completed, "cancelled native generation joins without waiting for a service callback")
            try expect(await inFlight.value == nil && Date().timeIntervalSince(start) < 2,
                       "cancellation joins active Quick Look work without a late image")
        } else {
            _ = await inFlight.value
            print("SKIP thumbnail in-flight cancellation: native service completed before cancellation")
        }

        let replacement = root.appendingPathComponent("replacement.png")
        try writeImage(replacement, color: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        let beforeKey = MediaThumbnailCache.key(url: replacement, scale: 2)
        let (before, _) = try await image(replacement, cache: cache)
        try writeImage(replacement, color: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: replacement.path)
        try expect(MediaThumbnailCache.key(url: replacement, scale: 2) != beforeKey &&
                   MediaThumbnailCache.key(url: replacement, scale: 1) != MediaThumbnailCache.key(url: replacement, scale: 2),
                   "file replacement and display scale invalidate the thumbnail cache identity")
        let (after, _) = try await image(replacement, cache: cache)
        if let before, let after {
            let old = try center(before), new = try center(after)
            try expect(old.redComponent > old.blueComponent + 0.3 && new.blueComponent > new.redComponent + 0.3,
                       "replaced local files display new content rather than the old cached image")
        } else {
            print("SKIP thumbnail replacement pixels: Quick Look unavailable; cache-key invalidation remains verified")
        }
        try manager.removeItem(at: replacement)
        try expect(MediaThumbnailCache.key(url: replacement, scale: 2) == nil, "deleted files lose their thumbnail identity")
        try expect(MediaThumbnailCache.countLimit == 96 && MediaThumbnailCache.byteLimit <= 16 * 1024 * 1024,
                   "document and media previews share the existing cache budgets")
        if let artifacts {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: artifacts.appendingPathComponent("results.json"))
        }
        let thumbnails = results.filter { $0.outcome == "thumbnail" }.count
        print("PASS thumbnail matrix: \(thumbnails) native images; \(results.count - thumbnails) explicit fallbacks; cancellation, replacement identity and local-only guards verified")
        for result in results { print("THUMBNAIL \(result.name): \(result.outcome)") }
        return results
    }
}

extension CoreTests {
    @MainActor static func thumbnailTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-thumbnail-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ThumbnailTestMatrix.run(in: root)
    }
}
