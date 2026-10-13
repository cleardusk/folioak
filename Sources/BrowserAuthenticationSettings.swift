import AppKit
import SwiftUI

@MainActor final class BrowserAuthenticationSettings: ObservableObject {
    @Published private(set) var selection: BrowserAuthenticationSelection?
    @Published private(set) var enabled = false
    @Published private(set) var issue: BrowserAuthenticationIssue?
    @Published private(set) var readState: BrowserAuthenticationReadState = .ready
    @Published private(set) var lastHost: String?
    @Published private(set) var browserOpenError = false
    @Published private(set) var openingBrowser = false
    private let preferences: BrowserAuthenticationPreferences
    private let browserOpener: (CookieBrowser, URL?) async -> Bool

    init(_ preferences: UserDefaults, browserOpener: @escaping (CookieBrowser, URL?) async -> Bool = BrowserAuthenticationSettings.open) {
        self.preferences = BrowserAuthenticationPreferences(preferences)
        self.browserOpener = browserOpener
        do {
            selection = try self.preferences.configuredSelection()
            enabled = self.preferences.enabled && selection != nil
            if self.preferences.enabled && selection == nil {
                issue = .invalidSelection
                try self.preferences.setEnabled(false)
            }
        } catch {
            issue = .invalidSelection
            try? self.preferences.setEnabled(false)
        }
    }

    func activeSelection() throws -> BrowserAuthenticationSelection? { try preferences.activeSelection() }

    func receive(_ state: BrowserAuthenticationReadState, for selection: BrowserAuthenticationSelection, host: String? = nil) {
        guard enabled, self.selection == selection else { return }
        readState = state
        lastHost = host
    }

    var recoveryHint: String {
        guard enabled else { return L("启用前，请先在浏览器打开视频链接并确认可播放。") }
        switch readState {
        case .ready: return L("下载时读取最新 Cookie；读取结果不代表站点已接受登录。")
        case .reading: return L("正在读取所选浏览器；macOS 可能请求访问权限。")
        case .read: return L("Cookie 已读取不代表网站已接受登录；画质取决于视频和账号权限。")
        case .empty: return L("未找到 Cookie。请确认浏览器及配置，打开视频链接后再试。")
        case .failed: return L("无法读取 Cookie。请检查浏览器配置、钥匙串或文件访问权限。")
        case .rejected: return L("请在所选浏览器打开原链接，确认可播放并完成站点验证后重试。")
        }
    }

    func openBrowser(url: URL? = nil) async {
        guard let selection, !openingBrowser else { return }
        if let url, !MediaDownloader.accepts(url) { return }
        openingBrowser = true
        browserOpenError = false
        let opened = await browserOpener(selection.browser, url)
        openingBrowser = false
        guard self.selection == selection else { return }
        browserOpenError = !opened
    }

    private static func open(_ browser: CookieBrowser, url: URL?) async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else { return false }
        return await withCheckedContinuation { continuation in
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in continuation.resume(returning: error == nil) }
            if let url {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: completion)
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: completion)
            }
        }
    }

    private func resetStatus() {
        readState = .ready; lastHost = nil; browserOpenError = false; issue = nil
    }

    var status: String {
        guard let selection else { return L("未启用 · 匿名下载") }
        guard enabled else { return selection.browser.label + " · " + L("已关闭 · 匿名下载") }
        return L10n.text(readState.message(for: selection.browser))
    }

    func select(_ browser: CookieBrowser?) {
        guard let browser else { clear(); return }
        do {
            let choice = try BrowserAuthenticationSelection(browser: browser)
            preferences.select(choice)
            try preferences.setEnabled(enabled)
            selection = choice
            resetStatus()
        } catch { issue = .invalidSelection }
    }

    func setEnabled(_ value: Bool) {
        do {
            try preferences.setEnabled(value)
            enabled = value
            resetStatus()
        } catch { issue = .invalidSelection }
    }

    @discardableResult func setProfile(_ profile: String) -> Bool {
        guard let browser = selection?.browser else { issue = .invalidSelection; return false }
        do {
            let choice = try BrowserAuthenticationSelection(browser: browser, profile: profile)
            preferences.select(choice)
            selection = choice
            resetStatus()
            return true
        } catch { issue = .invalidSelection; return false }
    }

    func clear() {
        preferences.clear()
        selection = nil
        enabled = false
        resetStatus()
    }
}

private typealias AuthenticationViewState<Value> = SwiftUI.State<Value>

// Reference lock: existing SettingsView's compact native picker/checkbox rows,
// 16-point rhythm and muted helper text. No custom sign-in form or account badge.
struct BrowserAuthenticationSettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var settings: BrowserAuthenticationSettings
    let palette: ThemePalette
    @AuthenticationViewState private var profile = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("复用浏览器登录")).font(.headline)
                    Text(L("先在浏览器打开视频并确认可播放，再启用认证。"))
                        .font(.caption).foregroundStyle(ThemePalette.color(palette.secondary))
                }
                Divider()
                HStack(spacing: 16) {
                    Text(L("浏览器")).font(.body).frame(width: 64, alignment: .leading)
                    Picker(L("浏览器"), selection: Binding(get: { settings.selection?.browser }, set: settings.select)) {
                        Text(L("选择浏览器…")).tag(Optional<CookieBrowser>.none)
                        ForEach(CookieBrowser.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }.labelsHidden().id(localization.language)
                }
                Toggle(L("下载时使用浏览器认证"), isOn: Binding(get: { settings.enabled }, set: settings.setEnabled))
                    .toggleStyle(.checkbox).disabled(settings.selection == nil)
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.status).font(.caption.weight(.medium))
                        .accessibilityIdentifier("browser-authentication-status")
                    if let host = settings.lastHost { Text(host).font(.caption).foregroundStyle(ThemePalette.color(palette.secondary)) }
                    Text(settings.recoveryHint).font(.caption).foregroundStyle(ThemePalette.color(palette.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("认证失败时自动匿名重试一次；不会更改浏览器选择。"))
                    .font(.caption).foregroundStyle(ThemePalette.color(palette.secondary)).fixedSize(horizontal: false, vertical: true)

                if let selection = settings.selection {
                    HStack(spacing: 12) {
                        Button(L("打开浏览器")) { Task { await settings.openBrowser() } }.controlSize(.small).disabled(settings.openingBrowser)
                        Button(L("清除选择"), action: settings.clear).controlSize(.small)
                    }
                    if selection.browser.supportsProfile {
                        DisclosureGroup(L("配置名称（可选）")) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    TextField("Default / Profile 1", text: $profile)
                                        .textFieldStyle(.roundedBorder).onSubmit(saveProfile)
                                        .accessibilityLabel(L("浏览器配置名称"))
                                    Button(L("保存"), action: saveProfile).controlSize(.small)
                                        .disabled(profile == (selection.profile ?? ""))
                                }
                                Text(L("留空自动选择；多账号可填配置目录名，如 Profile 1。"))
                                    .font(.caption).foregroundStyle(ThemePalette.color(palette.secondary))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.body).disclosureGroupStyle(RecordDisclosureStyle())
                    }
                }
                if let issue = settings.issue {
                    Text(L10n.text(issue.message)).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if settings.browserOpenError {
                    Text(L("浏览器未安装，或无法打开。请确认安装后重试。"))
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DisclosureGroup(L("认证说明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("仅媒体下载时读取所选配置的整个 Cookie 库，不导出、不写入日志。"))
                        Text(L("macOS 可能请求钥匙串或文件访问权限。"))
                        Text(L("Cookie 已读取不代表网站已接受登录；画质取决于视频和账号权限。"))
                    }.font(.caption).foregroundStyle(ThemePalette.color(palette.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.body).disclosureGroupStyle(RecordDisclosureStyle())
            }.padding(.trailing, 4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { profile = settings.selection?.profile ?? "" }
        .onChange(of: settings.selection) { choice in profile = choice?.profile ?? "" }
    }

    private func saveProfile() { _ = settings.setProfile(profile) }

}

private extension CookieBrowser {
    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .chromium: return "org.chromium.Chromium"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        }
    }
}
