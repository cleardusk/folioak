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
    static let countLimit = 96
    static let byteLimit = 16 * 1024 * 1024
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = Self.countLimit
        images.totalCostLimit = Self.byteLimit
    }

    static func key(url: URL, scale: CGFloat) -> String? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return "\(url.standardizedFileURL.path)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values.fileSize ?? 0)|\(scale)"
    }

    func image(url: URL, key: String, scale: CGFloat) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = images.object(forKey: key as NSString) { return cached }
        let request = MediaThumbnailRequest(url: url, size: CGSize(width: 44, height: 44), scale: scale)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { request.start($0) }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        guard !Task.isCancelled, let result else { return nil }
        let side = Int((44 * scale).rounded(.up))
        images.setObject(result, forKey: key as NSString, cost: side * side * 4)
        return result
    }
}

struct MediaThumbnail: View {
    let url: URL?
    let fallbackSymbol: String
    let palette: ThemePalette
    @Environment(\.displayScale) private var scale
    @ThumbnailState private var thumbnail: NSImage?

    var body: some View {
        let key = url.flatMap { MediaThumbnailCache.key(url: $0, scale: scale) }
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: 22, weight: .light))
                    .foregroundStyle(ThemePalette.color(palette.secondary))
            }
        }
        .frame(width: WorkspaceMetrics.rowIconSize, height: WorkspaceMetrics.rowIconSize)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.Radius.control))
        .accessibilityHidden(true)
        .task(id: key) {
            thumbnail = nil
            guard let url, let key else { return }
            let image = await MediaThumbnailCache.shared.image(url: url, key: key, scale: scale)
            if !Task.isCancelled { thumbnail = image }
        }
    }
}
