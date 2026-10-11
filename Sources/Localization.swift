import Foundation
import Combine

enum AppLanguage: String, CaseIterable {
    case system, chinese, english

    var label: String {
        switch self { case .system: return L("跟随系统"); case .chinese: return "简体中文"; case .english: return "English" }
    }
    func code(preferred: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        case .system:
            for language in preferred {
                if language.hasPrefix("zh") { return "zh-Hans" }
                if language.hasPrefix("en") { return "en" }
            }
            return "en"
        }
    }
}

@MainActor final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    @Published var language = AppLanguage.system {
        didSet { L10n.language = language }
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var selected = AppLanguage.system
    static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set { lock.lock(); selected = newValue; lock.unlock() }
    }
    static var locale: Locale { Locale(identifier: language.code()) }

    // Chinese source text stays in stored diagnostics. Translate it only when
    // presenting it, including records written by earlier app versions.
    private struct Template {
        let prefix: String
        let suffix: String
        let expression: NSRegularExpression
        let translation: [String]
        let nested: Bool
    }
    static let english: [String: String] = {
        let roots = [Bundle.main.resourceURL, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let file = root.appendingPathComponent("en.lproj/Localizable.strings")
            if let data = try? Data(contentsOf: file),
               let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] { return values }
        }
        return [:]
    }()
    private static let templates: [Template] = english.compactMap { key, value in
        let parts = key.components(separatedBy: "%@")
        guard parts.count > 1, value.components(separatedBy: "%@").count == parts.count else { return nil }
        let numeric = ["页", "项", "条", "篇", "个文件", "秒", "分", "×"].contains { key.hasPrefix("%@ " + $0) }
        let capture = numeric ? "([0-9]+(?:\\.[0-9]+)?)" : "(.*?)"
        let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: capture) + "$"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
        return Template(prefix: parts[0], suffix: parts.last!, expression: expression, translation: value.components(separatedBy: "%@"),
                        nested: ["保存失败：%@", "版本检查已停止：%@", "下载记录未能清空：%@", "媒体库无法读取，原文件已保留：%@",
                                 "媒体库未能保存：%@", "文档库无法读取，原文件已保留：%@", "文档库未能保存：%@", "导出失败：%@",
                                 "历史记录未能保存：%@", "网络连接失败：%@", "已用于“%@”。", "暂无%@任务", "下载状态：%@",
                                 "本次耗时 %@ · 重试 %@ 次", "本次耗时 %@ · 重试 1 次"].contains(key))
    }.sorted { $0.prefix.count == $1.prefix.count ? $0.suffix.count > $1.suffix.count : $0.prefix.count > $1.prefix.count }

    static func text(_ source: String) -> String {
        guard language.code() == "en" else { return source }
        return translated(source, depth: 0)
    }
    private static func translated(_ source: String, depth: Int) -> String {
        if let value = english[source] { return value }
        guard depth < 4, source.utf8.count <= 65_536 else { return source }
        let string = source as NSString
        for template in templates where source.hasPrefix(template.prefix) && source.hasSuffix(template.suffix) {
            guard let match = template.expression.firstMatch(in: source, range: NSRange(location: 0, length: string.length)) else { continue }
            var result = template.translation[0]
            for index in 1..<match.numberOfRanges {
                let argument = string.substring(with: match.range(at: index))
                result += (template.nested ? translated(argument, depth: depth + 1) : argument) + template.translation[index]
            }
            return result
        }
        if source.contains(" · ") {
            return source.components(separatedBy: " · ").map { translated($0, depth: depth + 1) }.joined(separator: " · ")
        }
        return source
    }
    static func date(_ date: Date, dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
                     time: Date.FormatStyle.TimeStyle = .standard) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time).locale(locale))
    }
}

func L(_ source: String) -> String { L10n.text(source) }
