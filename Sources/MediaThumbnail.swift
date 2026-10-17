import AppKit
import SwiftUI
import QuickLookThumbnailing

private typealias ThumbnailState<Value> = SwiftUI.State<Value>

/// A request owns its continuation so cancellation also completes callers when
/// Quick Look elects not to deliver a completion for a cancelled generation.
@MainActor private final class MediaThumbnailRequest {
    private let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var finished = false

    init(url: URL, size: CGSize, scale: CGFloat) {
        request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
    }

    func start(_ continuation: CheckedContinuation<NSImage?, Never>) {
        guard !finished else { continuation.resume(returning: nil); return }
        self.continuation = continuation
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async { self?.finish(representation?.nsImage) }
        }
    }

    private func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: image)
        continuation = nil
    }

    func cancel() {
        QLThumbnailGenerator.shared.cancel(request)
        finish(nil)
    }
}

@MainActor final class MediaThumbnailCache {
    static let shared = MediaThumbnailCache()
    #if TESTING
    static var loadCount = 0
    #endif
    static let countLimit = 96
    static let byteLimit = 16 * 1024 * 1024
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = Self.countLimit
        images.totalCostLimit = Self.byteLimit
    }

    nonisolated static func key(url: URL, scale: CGFloat, size: CGSize = CGSize(width: 44, height: 44)) -> String? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return "\(url.standardizedFileURL.path)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values.fileSize ?? 0)|\(scale)|\(size.width)x\(size.height)"
    }

    static func load(url: URL, scale: CGFloat, size: CGSize = CGSize(width: 44, height: 44)) async -> NSImage? {
        #if TESTING
        loadCount += 1
        #endif
        let key = await Task.detached(priority: .utility) { Self.key(url: url, scale: scale, size: size) }.value
        guard !Task.isCancelled, let key else { return nil }
        return await shared.image(url: url, key: key, scale: scale, size: size)
    }

    func image(url: URL, key: String, scale: CGFloat, size: CGSize = CGSize(width: 44, height: 44)) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = images.object(forKey: key as NSString) { return cached }
        let request = MediaThumbnailRequest(url: url, size: size, scale: scale)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { request.start($0) }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        guard !Task.isCancelled, let result else { return nil }
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        images.setObject(result, forKey: key as NSString, cost: width * height * 4)
        return result
    }
}

struct FileThumbnail: View {
    let url: URL?
    let fallbackSymbol: String
    let palette: ThemePalette
    var revision = ""
    var size = CGSize(width: 44, height: 44)
    var flexible = false
    var contentInset: CGFloat = 0
    var loadImage: ((URL, CGFloat) async -> NSImage?)? = nil
    @Environment(\.displayScale) private var scale
    @ThumbnailState private var thumbnail: NSImage?

    var body: some View {
        let requestID = "\(url?.absoluteString ?? "")|\(scale)|\(revision)|\(size.width)x\(size.height)"
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: min(size.height * 0.5, 40), weight: .light))
                    .foregroundStyle(ThemePalette.color(palette.secondary))
            }
        }
        .padding(contentInset)
        .frame(width: flexible ? nil : size.width, height: flexible ? nil : size.height)
        .frame(maxWidth: flexible ? .infinity : nil, maxHeight: flexible ? .infinity : nil)
        .background(ThemePalette.color(palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control))
        .accessibilityHidden(true)
        .task(id: requestID) {
            thumbnail = nil
            guard let url else { return }
            let image: NSImage?
            if let loadImage { image = await loadImage(url, scale) }
            else { image = await MediaThumbnailCache.load(url: url, scale: scale, size: size) }
            if !Task.isCancelled { thumbnail = image }
        }
    }
}
