import AppKit
import SwiftUI

extension CoreTests {
    @MainActor static func localizationTests() async throws {
        try expect(AppLanguage.system.code(preferred: ["zh-Hans-CN", "en"]) == "zh-Hans", "system Chinese")
        try expect(AppLanguage.system.code(preferred: ["en-GB", "zh-Hans"]) == "en", "preferred language order")
        try expect(AppLanguage.system.code(preferred: ["fr"]) == "en", "unsupported system language falls back to English")
        try expect(L10n.english.count > 350, "English resources are packaged in the test executable")
        for (key, value) in L10n.english {
            let template = DiagnosticMessage.ID.allCases.first { key == $0.rawValue || key.hasPrefix($0.rawValue + ".one") }?.template ?? key
            try expect(!value.isEmpty && template.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "translation arguments are preserved")
        }
        let suite = "folioak-language-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); AppLocalization.shared.language = .chinese }
        let model = DownloadModel(preferences: preferences)
        try expect(model.language == .system, "language defaults to system")
        model.input = "用户草稿 BV1MaHp6KENU"
        model.items = [DownloadItem(original: "123", state: .failed, error: DownloadError.invalidLink("123").localizedDescription)]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let stored = try encoder.encode(model.items)
        let view = NSHostingView(rootView: DownloaderView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func editor(in view: NSView) -> LinkTextView? {
            if let editor = view as? LinkTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        view.layoutSubtreeIfNeeded()
        guard let input = editor(in: view) else { throw TestFailure.failed("localized input view") }
        input.setSelectedRange(NSRange(location: 2, length: 3))
        let settings = NSHostingView(rootView: SettingsView(model: model))
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 588), styleMask: [.borderless], backing: .buffered, defer: false)
        settingsWindow.contentView = settings
        let namingSettings = NSHostingView(rootView: AssetNamingSettings(model: model, palette: model.theme.palette(dark: false)))
        let namingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
        namingWindow.contentView = namingSettings
        defer { namingWindow.orderOut(nil) }
        defer { settingsWindow.orderOut(nil) }
        func pickerTitles(in view: NSView) -> [String] {
            if let picker = view as? NSPopUpButton { return picker.itemTitles }
            return view.subviews.flatMap { pickerTitles(in: $0) }
        }
        settings.layoutSubtreeIfNeeded(); namingSettings.layoutSubtreeIfNeeded()
        try expect(pickerTitles(in: namingSettings).contains("年月 + 标题"), "native naming picker starts in Chinese")
        let palette = AppTheme.graphite.palette(dark: false)
        let tabs = NSHostingView(rootView: FilterTabs(options: ActivityLevel.allCases, selection: .constant(.success), title: { L($0.label) }, palette: palette).frame(width: 540, height: 40))
        let day = NSHostingView(rootView: LogDaySeparator(date: Date(timeIntervalSince1970: 1_791_635_400), palette: palette).frame(width: 540, height: 40))
        let tabsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let dayWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        tabsWindow.contentView = tabs; dayWindow.contentView = day
        defer { tabsWindow.orderOut(nil); dayWindow.orderOut(nil) }
        func pixels(_ host: NSView) throws -> Data {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds), let data = bitmap.bitmapData else { throw TestFailure.failed("localized log bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Ignore the underline while its width is animating between languages.
            return Data(bytes: data, count: bitmap.bytesPerRow * Int(CGFloat(bitmap.pixelsHigh) * 30 / 40))
        }
        let chineseTabs = try pixels(tabs), chineseDay = try pixels(day)
        model.language = .english
        try await Task.sleep(nanoseconds: 150_000_000)
        view.layoutSubtreeIfNeeded()
        settings.layoutSubtreeIfNeeded(); namingSettings.layoutSubtreeIfNeeded()
        try expect(try pixels(tabs) != chineseTabs && pixels(day) != chineseDay, "mounted log filters and date update immediately without remounting")
        for hour in [0, 12, 23] {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: hour, minute: 2, second: 30))!
            try expect(L10n.logTime(date) == String(format: "%02d:02:30", hour), "English log times use an unambiguous 24-hour clock")
        }
        try expect(pickerTitles(in: namingSettings).contains("Year & Month + Title") && pickerTitles(in: settings).contains("System"), "native picker menus update to English")
        try expect(editor(in: view) === input && input.selectedRange() == NSRange(location: 2, length: 3), "language changes preserve the native editor and selection")
        try expect(input.accessibilityLabel() == "Download links, one per line" && LinkTextView.example == "Paste paper or media links", "native labels and placeholder update immediately")
        try expect(L("设置") == "Settings" && L("自动重试 2/3") == "Retrying 2/3", "labels and dynamic state translate")
        try expect(L(DownloadError.invalidLink("123").localizedDescription).hasPrefix("Unrecognized input."), "historical errors translate at presentation")
        try expect(L("保存失败：所选目录不存在，请重新选择。") == "Could not save: The selected folder does not exist. Choose another folder.", "nested stored errors translate")
        try expect(L("下载的更多操作") == "More actions for 下载" && L("清除标签筛选：下载") == "Clear tag filter: 下载", "user titles and tags are not translated")
        try expect(L("下载 · 下载的更多操作") == "More actions for 下载 · 下载", "separators inside user titles stay intact")
        try expect(L("1 项失败 · 2 项取消") == "1 failed · 2 canceled", "composed footer messages translate")
        try expect(L("0.4 秒") == "0.4 s", "diagnostic duration translates")
        try expect(L("开始下载 · 2 项 · 去重 1 条") == "Starting download · 2 items · 1 duplicate removed", "combined download log translates")
        try expect(L("本次耗时 0.4 秒 · 重试 1 次") == "Elapsed time 0.4 s · 1 retry", "copied diagnostic translates duration and retries")
        try expect(L("本次耗时 2 分 0 秒 · 重试 2 次") == "Elapsed time 2 min 0 s · 2 retries", "composed long diagnostic duration translates")
        try expect(L("1 页") == "1 page", "English singular counts")
        try expect(model.input == "用户草稿 BV1MaHp6KENU" && (try encoder.encode(model.items)) == stored, "language changes do not rewrite user data or stored errors")
        try expect(DownloadModel(preferences: preferences).language == .english, "explicit language persists")
        model.language = .chinese
        try await Task.sleep(nanoseconds: 150_000_000)
        settings.layoutSubtreeIfNeeded(); namingSettings.layoutSubtreeIfNeeded()
        try expect(try pixels(tabs) == chineseTabs, "mounted log filters update back to Chinese")
        try expect(try pixels(day) == chineseDay, "mounted log date updates back to Chinese")
        try expect(pickerTitles(in: namingSettings).contains("年月 + 标题") && pickerTitles(in: settings).contains("跟随系统") && !pickerTitles(in: namingSettings).contains("Year & Month + Title"), "native picker menus refresh when switching back to Chinese")
        try expect(L("设置") == "设置" && L(DownloadError.invalidLink("123").localizedDescription) == DownloadError.invalidLink("123").localizedDescription, "switching back restores Chinese")
        preferences.set("unsupported", forKey: "language")
        try expect(DownloadModel(preferences: preferences).language == .system, "unknown saved language falls back to system")
        print("PASS language: system fallback, persistence, live native updates, retained draft/selection, stored diagnostics and user content")
    }
}
