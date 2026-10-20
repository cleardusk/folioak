import SwiftUI

struct SmartInputStatusView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var state: SmartDownloadState
    let palette: ThemePalette
    var compact = false
    var submitShortcut: KeyboardShortcut? = KeyboardShortcut(.return, modifiers: .command)
    var showsReviewActions = true
    var onEdit: (() -> Void)?

    private var secondary: Color { ThemePalette.color(palette.secondary) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = state.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L(progress.label)).font(.system(size: 12))
                        .accessibilityIdentifier("smart-input-progress")
                    Spacer(minLength: 4)
                    Button(L("取消"), action: state.cancel).controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("smart-input-cancel")
                }
            } else {
                if let message = state.message, !message.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        let text = Text(L(message)).font(.system(size: 12))
                            .foregroundStyle(state.failed ? Color.red : secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("smart-input-message")
                        if message.count > 160 {
                            ScrollView {
                                text.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 48)
                        } else { text }
                        if state.resolution == nil {
                            Spacer(minLength: 4)
                            Button(action: state.cancel) { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(secondary)
                                .accessibilityLabel(L("关闭智能输入结果"))
                        }
                    }
                }
                if let resolution = state.resolution {
                    if resolution.candidates.count == 1, let candidate = resolution.candidates.first {
                        candidateRow(candidate, showsSelection: resolution.selections.isEmpty)
                    } else if !resolution.candidates.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(resolution.candidates) { candidate in
                                    candidateRow(candidate, showsSelection: true)
                                    if candidate.id != resolution.candidates.last?.id {
                                        Divider().padding(.leading, 20)
                                    }
                                }
                            }.padding(.trailing, 4)
                        }
                        .frame(height: 160)
                        .accessibilityIdentifier("smart-input-candidates")
                    }
                    if !resolution.unresolved.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if !resolution.candidates.isEmpty {
                                Text(L("未完成")).font(.system(size: 11, weight: .medium))
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(resolution.unresolved.enumerated()), id: \.offset) { _, requirement in
                                        Text("• " + L(requirement)).font(.system(size: 11))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: min(60, max(22, CGFloat(resolution.unresolved.count) * 22)))
                        }.foregroundStyle(secondary)
                            .accessibilityIdentifier("smart-input-unresolved")
                    }
                    if showsReviewActions {
                        HStack {
                            Spacer(minLength: 0)
                            SmartInputReviewActionsView(state: state, palette: palette,
                                submitShortcut: submitShortcut, onEdit: onEdit)
                        }.padding(.top, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ThemePalette.color(palette.text))
        .tint(ThemePalette.color(palette.accent))
    }

    private func candidateRow(_ candidate: SmartCandidate, showsSelection: Bool) -> some View {
        let selected = state.selections.contains { $0.candidateID == candidate.id }
        let indices = state.selections.indices.filter { state.selections[$0].candidateID == candidate.id }
        let hasFormats = (try? DownloadSource.parse(candidate.url.absoluteString))?.supportsAudioExtraction == true
        return VStack(alignment: .leading, spacing: 6) {
            if showsSelection {
                Toggle(isOn: Binding(get: {
                    state.selections.contains { $0.candidateID == candidate.id }
                }, set: { state.setSelected(candidate, selected: $0) })) {
                    Text(candidate.title).font(.system(size: 13, weight: .medium))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .disabled(!selected && !state.canSelect(candidate))
                .accessibilityIdentifier("smart-input-candidate-" + candidate.id)
            } else {
                Text(candidate.title).font(.system(size: 13, weight: .medium))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("smart-input-candidate-" + candidate.id)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Link(sourceLabel(candidate), destination: candidate.url)
                        .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                        .accessibilityLabel(L("查看来源") + " · " + candidate.title)
                    if !hasFormats, let index = indices.first { options(index, candidate: candidate) }
                    Spacer(minLength: 0)
                }
                if hasFormats {
                    ForEach(indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            Picker(L("下载格式"), selection: format(index, candidateID: candidate.id)) {
                                ForEach(SmartFormat.allCases, id: \.self) { value in
                                    Text(L(value == .inherit
                                           ? (state.inheritedFormat == .audio ? "默认（仅音频）" : "默认（视频）")
                                           : value.label)).tag(value)
                                        .disabled(state.selections.indices.contains { other in
                                            other != index && state.selections[other].candidateID == candidate.id
                                                && state.selections[other].format == value
                                        })
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(maxWidth: 156, alignment: .leading)
                            .accessibilityLabel(L("下载格式") + " · " + candidate.title)
                            options(index, candidate: candidate)
                            Spacer(minLength: 0)
                        }.controlSize(.small)
                    }
                }
            }.padding(.leading, showsSelection ? 20 : 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func options(_ index: Int, candidate: SmartCandidate) -> some View {
        Menu {
            Toggle(L("已有的跳过"), isOn: skipExisting(index, candidateID: candidate.id))
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondary).frame(width: 24, height: 22)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .accessibilityLabel(L("下载选项") + " · " + candidate.title)
        .accessibilityIdentifier("smart-input-options-" + candidate.id + "-" + String(index))
        .help(L("下载选项"))
    }

    private func sourceLabel(_ candidate: SmartCandidate) -> String {
        let host = candidate.url.host ?? candidate.url.absoluteString
        let source = try? DownloadSource.parse(candidate.url.absoluteString)
        if source?.isPaper == true { return host + " · PDF" }
        let ext = candidate.url.pathExtension.lowercased()
        if FileStorage.extensions.contains(ext) || GenericFileStorage.extensions.contains(ext) {
            return host + " · " + ext.uppercased()
        }
        return host
    }

    private func format(_ index: Int, candidateID: String) -> Binding<SmartFormat> {
        Binding(get: {
            guard state.selections.indices.contains(index), state.selections[index].candidateID == candidateID else { return .inherit }
            return state.selections[index].format
        },
                set: { value in
                    guard state.selections.indices.contains(index), state.selections[index].candidateID == candidateID else { return }
                    state.selections[index].format = value
                })
    }

    private func skipExisting(_ index: Int, candidateID: String) -> Binding<Bool> {
        Binding(get: {
            guard state.selections.indices.contains(index), state.selections[index].candidateID == candidateID else { return false }
            return state.selections[index].skipExisting
        },
                set: { value in
                    guard state.selections.indices.contains(index), state.selections[index].candidateID == candidateID else { return }
                    state.selections[index].skipExisting = value
                })
    }
}

struct SmartInputReviewActionsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var state: SmartDownloadState
    let palette: ThemePalette
    var submitShortcut: KeyboardShortcut? = KeyboardShortcut(.return, modifiers: .command)
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(L("返回修改")) {
                if let onEdit { onEdit() } else { state.cancel() }
            }
            .buttonStyle(.plain).font(.system(size: 12))
            .foregroundStyle(ThemePalette.color(palette.secondary)).frame(minHeight: 36)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("smart-input-cancel")
            if state.resolution?.candidates.isEmpty == false {
                Button(state.selections.count > 1 ? L("下载 \(state.selections.count) 项") : L("下载文件"),
                       action: state.acceptSelection)
                    .buttonStyle(PrimaryActionStyle(palette: palette))
                    .keyboardShortcut(submitShortcut)
                    .disabled(state.selections.isEmpty || state.selections.count > SmartInput.targetLimit)
                    .accessibilityIdentifier("smart-input-accept")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

private extension SmartFormat {
    var label: String {
        switch self { case .inherit: return "沿用默认"; case .video: return "视频"; case .audio: return "仅音频" }
    }
}
