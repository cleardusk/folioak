import AppKit
import SwiftUI

struct WorkspaceSettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    private let categories = ["通用", "命名规则", "快捷键", "浏览器认证"]
    private let identifiers = ["general", "naming", "shortcuts", "authentication"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                        Button { model.settingsTab = category; model.trace.user(.pageChanged, context: .settings, detail: index == 0 ? .general : index == 1 ? .naming : index == 2 ? .shortcuts : .authentication) } label: {
                            Text(L(category)).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ThemePalette.color(model.settingsTab == category ? palette.text : palette.secondary))
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(ThemePalette.color(palette.text).opacity(model.settingsTab == category ? 0.075 : 0),
                                    in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(L(category))
                            .accessibilityIdentifier("preferences-category-" + identifiers[index])
                            .accessibilityAddTraits(model.settingsTab == category ? .isSelected : [])
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            // Keep each form mounted: leaving a category or workspace page must
            // preserve unfinished templates and browser profile input.
            ZStack(alignment: .topLeading) {
                WorkspaceGeneralSettings(model: model, palette: palette)
                    .modifier(PreferencesCategoryVisibility(visible: model.settingsTab == "通用"))
                ScrollView {
                    AssetNamingSettings(model: model, palette: palette, embedded: true)
                        .frame(maxWidth: 680, alignment: .leading).padding(.trailing, 16).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.modifier(PreferencesCategoryVisibility(visible: model.settingsTab == "命名规则"))
                ScrollView {
                    ShortcutSettingsView(shortcuts: model.shortcuts, palette: palette)
                        .frame(maxWidth: 600, alignment: .leading).padding(.trailing, 16).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.modifier(PreferencesCategoryVisibility(visible: model.settingsTab == "快捷键"))
                BrowserAuthenticationSettingsView(settings: model.browserAuthentication, palette: palette)
                    .frame(maxWidth: 680, alignment: .leading).padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(PreferencesCategoryVisibility(visible: model.settingsTab == "浏览器认证"))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(ThemePalette.color(palette.text)).tint(ThemePalette.color(palette.accent))
            .environment(\.locale, L10n.locale)
            .background(PreferencesFocusBoundary(category: model.settingsTab))
            .onReceive(model.browserAuthentication.$enabled.dropFirst().removeDuplicates()) { _ in model.traceSetting(.authentication) }
            .onAppear { if !categories.contains(model.settingsTab) { model.settingsTab = "通用" } }
    }
}

private struct PreferencesCategoryVisibility: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0).disabled(!visible).allowsHitTesting(visible).accessibilityHidden(!visible)
            .animation(nil, value: visible)
    }
}

// Resign only native editors belonging to this settings view's window. The
// asynchronous check also ignores stale focus work after rapid tab changes.
private struct PreferencesFocusBoundary: NSViewRepresentable {
    let category: String
    func makeNSView(context: Context) -> Boundary {
        let view = Boundary(); view.setAccessibilityElement(false); return view
    }
    func updateNSView(_ view: Boundary, context: Context) {
        let changed = view.category != nil && view.category != category
        view.category = category
        guard changed else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.category == category, let window = view.window,
                  window.firstResponder is NSTextView || window.firstResponder is ShortcutRecorder.Recorder else { return }
            window.makeFirstResponder(nil)
        }
    }
    final class Boundary: NSView {
        var category: String?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct WorkspaceGeneralSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    let palette: ThemePalette
    private var labelWidth: CGFloat { L10n.language.code() == "en" ? 106 : 68 }
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 16) {
                    row("保存位置") {
                        HStack(spacing: 12) {
                            Text(model.directoryLabel).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).help(model.directory.path)
                            Button(L("更改…"), action: model.chooseDirectory).controlSize(.small).disabled(model.busy)
                                .accessibilityLabel(L("更改保存位置"))
                        }
                    }
                    Text(L("按类型归入 Papers、Documents、Archives、Videos、Audio、Images；首次下载时创建。"))
                        .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, labelWidth + 16)
                    row("语言") {
                        Picker(L("语言"), selection: $model.language) {
                            ForEach(AppLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().id(localization.language).frame(maxWidth: 240, alignment: .leading)
                            .accessibilityLabel(L("语言"))
                    }
                    row("菜单栏") {
                        Toggle(L("显示 Folioak 图标"), isOn: $model.showsMenuBarIcon).toggleStyle(.checkbox)
                            .help(L("关闭主窗口后继续在菜单栏运行。"))
                    }
                    row("更新") { WorkspaceUpdateControls(checker: model.updates) }
                }
                Divider()
                InteractionTraceControls(settings: model.traceSettings, palette: palette)
                    .padding(.leading, labelWidth + 16)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    row("外观") {
                        SlidingSegments(selection: $model.appearance, options: AppAppearance.allCases, title: { L($0.label) },
                            segmentWidth: 80, accessibilityName: L("外观"), palette: palette)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Text(L("主题")).font(.system(size: 12, weight: .medium))
                            .frame(width: labelWidth, height: ThemeChoice.previewHeight, alignment: .leading)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                ThemeChoice(theme: theme, selected: model.theme == theme) { model.theme = theme }
                            }
                        }
                    }
                }
                if model.busy {
                    Text(L("下载结束后可更改目录。")).font(.system(size: 11)).foregroundStyle(secondary)
                        .padding(.leading, labelWidth + 16)
                }
            }.font(.system(size: 12)).frame(maxWidth: 680, alignment: .leading)
                .padding(.trailing, 16).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(L(label)).font(.system(size: 12, weight: .medium)).frame(width: labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 28)
    }
}

private struct WorkspaceUpdateControls: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var checker: UpdateChecker
    var body: some View {
        HStack(spacing: 12) {
            Toggle(L("自动检查更新"), isOn: $checker.automaticallyChecks).toggleStyle(.checkbox)
                .help(L("运行期间每天检查一次正式版，有新版时提醒。"))
            Spacer(minLength: 0)
            WorkspaceUpdateButton(checker: checker)
        }
    }
}

private struct WorkspaceUpdateButton: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var checker: UpdateChecker
    var body: some View {
        Button(checker.isChecking ? L("检查中…") : L("检查更新…")) {
            NSApp.sendAction(#selector(AppDelegate.checkForUpdates), to: NSApp.delegate, from: nil)
        }.controlSize(.small).disabled(checker.isChecking).fixedSize()
            .help(L("检查更新…")).accessibilityLabel(L("检查更新…"))
    }
}

// Bundle metadata and component manifests are immutable for a running app.
// Cache their small reads once, independently of theme/language/body updates.
@MainActor private enum WorkspaceAboutAssets {
    static let tools = try? MediaTools.installed()
    static let components = tools.map { AboutInformation.components(in: $0) } ?? []
    static let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        ?? NSImage(contentsOfFile: "Resources/AppIcon.icns")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
}

struct WorkspaceAboutView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette { model.theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 18) {
                    Group {
                        if let icon = WorkspaceAboutAssets.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                        else { Image(systemName: "leaf").resizable().scaledToFit().padding(12).foregroundStyle(ThemePalette.color(palette.accent)) }
                    }.frame(width: 64, height: 64).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Folioak").font(.system(size: 24, weight: .semibold)).accessibilityIdentifier("about-product")
                        Text(String(format: L("版本 %@（%@）"), WorkspaceAboutAssets.version ?? model.updates.currentVersion, WorkspaceAboutAssets.build))
                            .font(.system(size: 12)).foregroundStyle(secondary).textSelection(.enabled).accessibilityIdentifier("about-version")
                        Text("Jianzhu Guo & Codex (GPT)").font(.system(size: 11)).foregroundStyle(secondary)
                    }
                    Spacer(minLength: 8)
                    WorkspaceUpdateButton(checker: model.updates)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("开源组件")).font(.system(size: 13, weight: .semibold))
                    if WorkspaceAboutAssets.components.isEmpty {
                        Text(L("组件版本信息不可用")).font(.system(size: 12)).foregroundStyle(secondary)
                    } else {
                        VStack(spacing: 0) {
                            HStack(spacing: 16) {
                                Text(L("组件")).frame(maxWidth: .infinity, alignment: .leading)
                                Text(L("版本")).frame(width: 94, alignment: .leading)
                                Text(L("许可证")).frame(width: 126, alignment: .leading)
                            }.font(.system(size: 11)).foregroundStyle(secondary).padding(.bottom, 8)
                            ForEach(WorkspaceAboutAssets.components, id: \.name) { component in
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Button { NSWorkspace.shared.open(component.url) } label: {
                                        Text(component.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).foregroundStyle(ThemePalette.color(palette.accent))
                                        .accessibilityLabel(component.name).accessibilityIdentifier("about.component." + component.name)
                                        .help(component.url.absoluteString)
                                    Text(component.version).monospacedDigit().frame(width: 94, alignment: .leading).textSelection(.enabled)
                                    Text(component.license).font(.system(size: 11)).foregroundStyle(secondary)
                                        .frame(width: 126, alignment: .leading)
                                }.font(.system(size: 12)).frame(minHeight: 34)
                            }
                        }
                    }
                }
                Divider()
                HStack(alignment: .center, spacing: 16) {
                    Button(L("项目主页")) { NSWorkspace.shared.open(AboutInformation.repository) }
                        .buttonStyle(.plain).foregroundStyle(ThemePalette.color(palette.accent))
                        .accessibilityIdentifier("about.repository").help(AboutInformation.repository.absoluteString)
                    if let tools = WorkspaceAboutAssets.tools {
                        Button(L("许可证与第三方声明")) { NSWorkspace.shared.open(tools.directory.appendingPathComponent("licenses", isDirectory: true)) }
                            .buttonStyle(.plain).foregroundStyle(ThemePalette.color(palette.accent))
                            .accessibilityIdentifier("about.licenses").help(L("许可证与第三方声明"))
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 12))
                Text("© 2026 Jianzhu Guo").font(.system(size: 11)).foregroundStyle(secondary)
            }.frame(maxWidth: 680, alignment: .leading).padding(.top, 4).padding(.trailing, 16).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.locale, L10n.locale).foregroundStyle(ThemePalette.color(palette.text))
            .tint(ThemePalette.color(palette.accent))
    }
}
