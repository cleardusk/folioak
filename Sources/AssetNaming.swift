import Foundation

// Rules name a basename only. The validated output owns its extension and the
// publisher owns collision/attachment suffixes, even after UTF-8 truncation.
enum AssetNamingKind: String, Codable, CaseIterable, Sendable {
    case papers, documents, videos, audio, images, archives
    var label: String {
        switch self {
        case .papers: return "arXiv 论文"
        case .documents: return "文档与 PDF"
        case .videos: return "视频"
        case .audio: return "音频"
        case .images: return "图片"
        case .archives: return "压缩文件"
        }
    }
    static func output(_ ext: String) -> Self {
        let ext = ext.lowercased()
        if FileStorage.imageExtensions.contains(ext) { return .images }
        if FileStorage.videoExtensions.contains(ext) { return .videos }
        if FileStorage.extensions.contains(ext) { return .audio }
        return GenericFileStorage.archiveExtensions.contains(ext) ? .archives : .documents
    }
}

struct AssetNamingRules: Codable, Equatable, Sendable {
    static let preferenceKey = "assetNamingRules"
    static let tokens = ["title", "date", "source", "id"]
    var templates: [String: String] = [:]
    subscript(_ kind: AssetNamingKind) -> String {
        get { templates[kind.rawValue] ?? "" }
        set { templates[kind.rawValue] = newValue.isEmpty ? nil : newValue }
    }
    var valid: Bool {
        templates.count <= AssetNamingKind.allCases.count && templates.allSatisfy {
            AssetNamingKind(rawValue: $0.key) != nil && Self.validTemplate($0.value)
        }
    }
    static func validTemplate(_ template: String) -> Bool {
        guard template.utf8.count <= 512,
              !template.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !template.contains(where: { "/\\:*?\"<>|".contains($0) }) else { return false }
        if template.isEmpty { return true }
        guard let parts = parts(template), parts.contains(where: { $0.token == "title" || $0.token == "id" }) else { return false }
        return true
    }
    private struct Part { let text: String; let token: String? }
    private static func parts(_ template: String) -> [Part]? {
        var result: [Part] = [], text = "", token: String?
        for character in template {
            if character == "{" {
                guard token == nil else { return nil }
                result.append(Part(text: text, token: nil)); text = ""; token = ""
            } else if character == "}" {
                guard let key = token, tokens.contains(key) else { return nil }
                result.append(Part(text: "", token: key)); token = nil
            } else if token != nil { token!.append(character) }
            else { text.append(character) }
        }
        guard token == nil else { return nil }
        result.append(Part(text: text, token: nil)); return result
    }
    func title(for kind: AssetNamingKind, title: String, source: URL, date: String, identifier: String? = nil) -> String? {
        let template = self[kind]
        guard !template.isEmpty, Self.validTemplate(template), let parts = Self.parts(template) else { return nil }
        // Render once: braces inside a downloaded title are literal text.
        let values = ["title": title, "source": source.host?.lowercased() ?? "file", "date": date,
                      "id": identifier ?? String(PDFStorage.key(source.absoluteString).prefix(10))]
        return PaperMetadata.cleanTitle(parts.map { $0.token.map { values[$0] ?? "" } ?? $0.text }.joined())
    }
    static func read(_ preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: preferenceKey), data.count <= 4096,
              let rules = try? JSONDecoder().decode(Self.self, from: data), rules.valid else { return Self() }
        return rules
    }
}

struct AssetNamingSnapshot: Codable, Equatable, Sendable {
    let rules: AssetNamingRules
    let paperStyle: NamingStyle
    let date: String
    private(set) var savedNames: [String]? = nil
    init(rules: AssetNamingRules = .init(), paperStyle: NamingStyle = .dateTitle, now: Date = Date(), timeZone: TimeZone = .current) {
        self.rules = rules; self.paperStyle = paperStyle
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        date = formatter.string(from: now)
    }
    var valid: Bool {
        rules.valid && date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil &&
        (savedNames.map { $0.count <= 20 && $0.allSatisfy { name in
            name.utf8.count <= 250 && (name as NSString).lastPathComponent == name && !name.contains("\\") &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            (["pdf"].contains((name as NSString).pathExtension.lowercased()) || FileStorage.extensions.union(GenericFileStorage.extensions).contains((name as NSString).pathExtension.lowercased()))
        } } ?? true)
    }
    func saving(_ files: [URL]) -> Self {
        var copy = self; copy.savedNames = files.map(\.lastPathComponent); return copy
    }
    func savedTitle(extension ext: String, index: Int = 0) -> String? {
        guard let names = savedNames, names.indices.contains(index), (names[index] as NSString).pathExtension.lowercased() == ext.lowercased() else { return nil }
        return (names[index] as NSString).deletingPathExtension
    }
    func title(_ title: String, kind: AssetNamingKind, source: URL, identifier: String? = nil) -> String? {
        rules.title(for: kind, title: title, source: source, date: date, identifier: identifier)
    }
    func paperFilename(_ metadata: PaperMetadata, suffix: String = "") -> String {
        if let title = savedTitle(extension: "pdf") { return PaperMetadata.filename(title: title, ending: suffix + ".pdf") }
        guard let title = title(metadata.title, kind: .papers, source: metadata.reference.pdfURL, identifier: metadata.reference.identifier) else {
            return metadata.filename(style: paperStyle, suffix: suffix)
        }
        return PaperMetadata.filename(title: title, ending: suffix + ".pdf")
    }
}
