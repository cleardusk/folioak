import Foundation

// Public single-video metadata, independent of yt-dlp's web-detail extractor.
// Transfer, audio extraction and validation remain shared.
struct DouyinResolver {
    // API discovery reference; implemented natively rather than bundling Python.
    static let referenceRevision = "dab12708368eae054ba2dae5db16d8b040b9029e"
    static let referenceURL = URL(string: "https://github.com/wujunwei928/parse-video-py/blob/\(referenceRevision)/src/parse_video_py/parser/douyin.py")!
    static let userAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    static let referer = "https://www.iesdouyin.com/"
    let transport: HTTPTransport

    init(transport: HTTPTransport = URLSessionTransport(policy: .externalPDF)) { self.transport = transport }

    struct Information: Encodable {
        struct Format: Encodable {
            let format_id: String
            let url: String
            let ext = "mp4"
            let width: Int?
            let height: Int?
            let filesize: Int64?
            let tbr: Double?
            let vcodec: String?
            let source_preference: Int
        }
        let id: String
        let title: String
        let duration: Double?
        let formats: [Format]
        let webpage_url: String
        let extractor = "FolioakDouyin"
        let http_headers = ["User-Agent": DouyinResolver.userAgent, "Referer": DouyinResolver.referer]
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Video: Decodable {
                struct Address: Decodable {
                    let url_list: [String]?
                    let width: Int?
                    let height: Int?
                    let data_size: Int64?
                }
                struct Bitrate: Decodable {
                    let play_addr: Address?
                    let bit_rate: Double?
                    let is_h265: Int?
                }
                let play_addr: Address?
                let bit_rate: [Bitrate]?
                let duration: Double?
                let is_h265: Int?
            }
            let aweme_id: String
            let desc: String?
            let video: Video?
            let images: [IgnoredImage]?
        }
        struct IgnoredImage: Decodable {}
        let status_code: Int?
        let aweme_details: [Item]?
    }

    static func videoID(_ url: URL) -> String? {
        guard PublicHTTPS.allows(url),
              ["douyin.com", "www.douyin.com", "m.douyin.com", "www.iesdouyin.com", "iesdouyin.com"].contains(url.host?.lowercased() ?? ""),
              url.path.range(of: #"^/(?:share/)?video/[0-9]+/?$"#, options: .regularExpression) != nil else { return nil }
        return url.path.split(separator: "/").last.map(String.init)
    }

    func resolve(_ url: URL) async throws -> Information {
        guard MediaSite.site(for: url.host) == .douyin, MediaDownloader.accepts(url) else { throw DownloadError.invalidLink(url.absoluteString) }
        try Task.checkCancellation()
        let id: String
        if let direct = Self.videoID(url) { id = direct }
        else {
            let (_, response) = try await transport.data(for: request(url))
            try Self.check(response)
            guard let final = response.url, let resolved = Self.videoID(final) else { throw DownloadError.unsafeResponse }
            id = resolved
        }
        var endpoint = URLComponents(string: Self.referer + "web/api/v2/aweme/slidesinfo/")!
        // request_source=200 is for image posts and filters out ordinary videos.
        endpoint.queryItems = [URLQueryItem(name: "aweme_ids", value: "[\(id)]")]
        let (data, response) = try await transport.data(for: request(endpoint.url!))
        try Task.checkCancellation()
        try Self.check(response)
        guard response.url?.host == "www.iesdouyin.com", response.url?.path == endpoint.url?.path else { throw DownloadError.unsafeResponse }
        return try Self.information(data, videoID: id)
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        return request
    }

    private static func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let delay = DownloadEngine.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            if response.statusCode == 429 { throw DownloadError.cooldown(max(60, delay ?? 0)) }
            throw DownloadError.http(response.statusCode, retryAfter: delay)
        }
    }

    static func information(_ data: Data, videoID id: String) throws -> Information {
        guard data.count <= ResourceLimits.metadataBytes else { throw DownloadError.limit("抖音视频信息超过 1 MB，已停止处理。") }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.status_code == 0 else {
            throw DownloadError.metadata("抖音匿名接口未返回有效视频信息，请稍后重试或更新应用。")
        }
        guard let item = response.aweme_details?.first(where: { $0.aweme_id == id }) else {
            throw DownloadError.metadata("抖音未返回此视频，内容可能不可公开访问或已被删除。")
        }
        guard item.images?.isEmpty != false, let video = item.video else {
            throw DownloadError.metadata("此抖音链接没有可下载的视频；图文作品暂不支持。")
        }
        var formats: [Information.Format] = [], seen = Set<String>()
        func append(_ address: Response.Item.Video.Address?, name: String, codec: Int?, bitrate: Double? = nil) {
            guard let address else { return }
            for (index, value) in (address.url_list ?? []).prefix(20).enumerated() {
                guard let url = URL(string: value), PublicHTTPS.allows(url), seen.insert(value).inserted else { continue }
                formats.append(.init(format_id: "\(name)-\(index)", url: value,
                                     width: address.width.flatMap { $0 > 0 ? $0 : nil },
                                     height: address.height.flatMap { $0 > 0 ? $0 : nil },
                                     filesize: address.data_size.flatMap { $0 > 0 ? $0 : nil },
                                     tbr: bitrate.flatMap { $0 > 0 ? $0 / 1000 : nil },
                                     vcodec: codec == 1 ? "hevc" : (codec == 0 ? "h264" : nil), source_preference: -index))
            }
        }
        append(video.play_addr, name: "play", codec: video.is_h265)
        for (index, rate) in (video.bit_rate ?? []).prefix(20).enumerated() {
            append(rate.play_addr, name: "rate\(index)", codec: rate.is_h265, bitrate: rate.bit_rate)
        }
        guard !formats.isEmpty else { throw DownloadError.metadata("抖音未返回安全的公开播放地址，请稍后重试。") }
        let title = item.desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Information(id: id, title: title.isEmpty ? "Douyin \(id)" : String(title.prefix(ResourceLimits.titleCharacters)),
                           duration: video.duration.flatMap { $0 > 0 ? $0 / 1000 : nil }, formats: formats,
                           webpage_url: "https://www.douyin.com/video/\(id)")
    }
}
