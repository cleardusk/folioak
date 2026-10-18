import SwiftUI
private typealias NamingViewState<Value> = SwiftUI.State<Value>

struct AssetNamingSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: DownloadModel
    let palette: ThemePalette
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @NamingViewState private var kind: AssetNamingKind = .papers
    @NamingViewState private var rules: AssetNamingRules
    @NamingViewState private var paperStyle: NamingStyle
    @NamingViewState private var formats: [AssetNamingKind: String] = [:]
    @NamingViewState private var saved = false
    private var hasChanges: Bool { rules != model.namingRules || paperStyle != model.naming }
    private static let presets = ["", "{title}", "{date} - {title}", "{source} - {title}"]
    init(model: DownloadModel, palette: ThemePalette, embedded: Bool = false) {
        self.model = model; self.palette = palette; self.embedded = embedded
        _rules = NamingViewState(initialValue: model.namingRules); _paperStyle = NamingViewState(initialValue: model.naming)
    }
    private var template: Binding<String> { Binding(get: { rules[kind] }, set: { rules[kind] = $0; formats[kind] = "custom" }) }
    private var preset: Binding<String> {
        Binding(get: { formats[kind] ?? (Self.presets.contains(rules[kind]) ? rules[kind] : "custom") }, set: {
            formats[kind] = $0
            rules[kind] = $0 == "custom" ? "{title} - {id}" : $0
        })
    }
    private func valid(_ kind: AssetNamingKind) -> Bool {
        AssetNamingRules.validTemplate(rules[kind]) && !(formats[kind] == "custom" && rules[kind].isEmpty)
    }
    private var invalidKind: AssetNamingKind? { AssetNamingKind.allCases.first { !valid($0) } }
    private var example: String {
        let snapshot = AssetNamingSnapshot(rules: rules, paperStyle: paperStyle)
        let source = URL(string: kind == .papers ? "https://arxiv.org/abs/2501.12345v2" : "https://example.com/resource")!
        let title = L("研究笔记")
        if kind == .papers {
            let metadata = PaperMetadata(reference: ArxivReference(baseID: "2501.12345", version: 2), title: title, year: 2025, month: 1)
            return snapshot.paperFilename(metadata)
        }
        let ext: String
        switch kind { case .papers, .documents: ext = "pdf"; case .videos: ext = "mp4"; case .audio: ext = "m4a"; case .images: ext = "jpg"; case .archives: ext = "zip" }
        return PaperMetadata.filename(title: snapshot.title(title, kind: kind, source: source) ?? title, ending: "." + ext)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { Text(L("文件命名规则")).font(.system(size: 18, weight: .semibold)) }
            Text(L("规则用于新任务，已有文件与进行中的任务保持原命名。"))
                .font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.secondary)).fixedSize(horizontal: false, vertical: true)
            pickerRow("资产类型") {
                Picker(L("资产类型"), selection: $kind) {
                    ForEach(AssetNamingKind.allCases, id: \.self) { Text(L($0.label)).tag($0) }
                }.id(model.language).accessibilityLabel(L("资产类型")).accessibilityIdentifier("naming-kind")
            }
            pickerRow("命名格式") {
                Picker(L("命名格式"), selection: preset) {
                    Text(L("默认命名")).tag("")
                    Text(L("仅标题")).tag("{title}")
                    Text(L("日期 + 标题")).tag("{date} - {title}")
                    Text(L("来源 + 标题")).tag("{source} - {title}")
                    Text(L("自定义模板")).tag("custom")
                }.id(model.language).accessibilityLabel(L("命名格式")).accessibilityIdentifier("naming-format")
            }
            if kind == .papers && preset.wrappedValue.isEmpty {
                pickerRow("论文命名") {
                    Picker(L("论文命名"), selection: $paperStyle) {
                        ForEach(NamingStyle.allCases, id: \.self) { Text(L($0.label)).tag($0) }
                    }.id(model.language).accessibilityLabel(L("论文命名"))
                }
            } else {
                TextField(L("命名模板"), text: template).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced)).disabled(preset.wrappedValue.isEmpty)
                    .accessibilityLabel(L("命名模板")).accessibilityIdentifier("naming-template")
            }
            Text(L("{title} 标题 · {date} 任务日期 · {source} 来源域名 · {id} 来源编号"))
                .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("文件名预览")).font(.system(size: 11, weight: .medium))
                Text(valid(kind) ? example : L("模板须包含 {title} 或 {id}，且不能含路径、未知占位符或非法字符。"))
                    .font(.system(size: 12, design: .monospaced)).lineLimit(3)
                    .foregroundStyle(ThemePalette.color(valid(kind) ? palette.text : palette.secondary))
                    .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            }.padding(12).background(ThemePalette.color(palette.surface), in: RoundedRectangle(cornerRadius: 8))
            Text(L("扩展名自动保留；同名文件不会覆盖。多附件会追加编号，音频提取使用音频规则。"))
                .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary)).fixedSize(horizontal: false, vertical: true)
            if let invalid = invalidKind, invalid != kind {
                Button { kind = invalid } label: {
                    Label(L("需要修正模板") + " · " + L(invalid.label), systemImage: "exclamationmark.circle")
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ThemePalette.color(palette.accent))
            }
            HStack(spacing: 12) {
                Button(L("恢复默认")) { rules[kind] = ""; formats[kind] = ""; if kind == .papers { paperStyle = .dateTitle }; saved = false }
                    .controlSize(.small).help(L("恢复当前资产类型的默认命名规则"))
                Spacer(minLength: 4)
                if embedded {
                    Button(L("放弃更改")) {
                        rules = model.namingRules; paperStyle = model.naming; formats = [:]; saved = false
                    }.controlSize(.small).disabled(!hasChanges).accessibilityIdentifier("naming-discard")
                    Button(L("保存"), action: save).controlSize(.small)
                        .disabled(!hasChanges || !rules.valid || invalidKind != nil).accessibilityIdentifier("naming-save")
                } else {
                    Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("保存"), action: save).keyboardShortcut(.defaultAction)
                        .disabled(!rules.valid || invalidKind != nil).accessibilityIdentifier("naming-save")
                }
            }.padding(.top, 4)
            if embedded {
                Text(hasChanges ? L("更改尚未保存") : saved ? L("已保存") : "")
                    .font(.system(size: 11)).foregroundStyle(ThemePalette.color(palette.secondary))
                    .frame(maxWidth: .infinity, alignment: .trailing).accessibilityIdentifier("naming-save-status")
            }
        }.padding(embedded ? 0 : 24).frame(width: embedded ? nil : 520)
            .font(.system(size: 12)).frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
            .foregroundStyle(ThemePalette.color(palette.text)).tint(ThemePalette.color(palette.accent))
            .background(ThemePalette.color(palette.canvas))
            .onChange(of: rules) { _ in saved = false }
            .onChange(of: paperStyle) { _ in saved = false }
    }
    @ViewBuilder private func pickerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        if embedded {
            HStack(spacing: 16) {
                Text(L(label)).font(.system(size: 12, weight: .medium))
                    .frame(width: L10n.language.code() == "en" ? 106 : 68, alignment: .leading)
                content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 28)
        } else { content() }
    }
    private func save() {
        guard rules.valid, invalidKind == nil else { return }
        model.namingRules = rules; model.naming = paperStyle; saved = true
        if !embedded { dismiss() }
    }
}
