import SwiftUI

struct SmartInputStatusView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var state: SmartDownloadState
    let palette: ThemePalette
    var compact = false
    var submitShortcut: KeyboardShortcut? = KeyboardShortcut(.return, modifiers: .command)

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
                        if state.resolution == nil {
                            ScrollView {
                                text.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 48, maxHeight: compact ? 60 : 80)
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
                    if !resolution.candidates.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(resolution.candidates) { candidate in
                                    candidateRow(candidate)
                                    if candidate.id != resolution.candidates.last?.id {
                                        Divider().padding(.leading, 20)
                                    }
                                }
                            }.padding(.trailing, 4)
                        }
                        .frame(minHeight: compact ? 160 : 80, idealHeight: 200,
                               maxHeight: compact ? 200 : .infinity)
                        .layoutPriority(1)
                        .accessibilityIdentifier("smart-input-candidates")
                    }
                    if !resolution.unresolved.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("未完成")).font(.system(size: 11, weight: .medium))
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
                    HStack(spacing: 12) {
                        Text(L("已选 \(state.selections.count) / 10"))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
                        Spacer(minLength: 4)
                        Button(L("取消"), action: state.cancel)
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(secondary)
                            .padding(.horizontal, 4).frame(minHeight: 36)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("smart-input-cancel")
                        Button(L("下载所选"), action: state.acceptSelection)
                            .buttonStyle(PrimaryActionStyle(palette: palette))
                            .keyboardShortcut(submitShortcut)
                            .disabled(state.selections.isEmpty || state.selections.count > SmartInput.targetLimit)
                            .accessibilityIdentifier("smart-input-accept")
                    }.padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ThemePalette.color(palette.text))
        .tint(ThemePalette.color(palette.accent))
    }

    private func candidateRow(_ candidate: SmartCandidate) -> some View {
        let selected = state.selections.contains { $0.candidateID == candidate.id }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: {
                state.selections.contains { $0.candidateID == candidate.id }
            }, set: { state.setSelected(candidate, selected: $0) })) {
                Text(candidate.title).font(.system(size: 13, weight: .medium))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(!selected && state.selections.count >= SmartInput.targetLimit)
            .accessibilityIdentifier("smart-input-candidate-" + candidate.id)
            VStack(alignment: .leading, spacing: 4) {
                Link(candidate.url.host ?? candidate.url.absoluteString, destination: candidate.url)
                    .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                    .accessibilityLabel(L("查看来源") + " · " + candidate.title)
                if !candidate.detail.isEmpty {
                    Text(candidate.origin == .supplied && candidate.detail == "用户提供的资源" ? L(candidate.detail) : candidate.detail)
                        .font(.system(size: 11)).foregroundStyle(secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if selected {
                    ForEach(state.selections.indices.filter { state.selections[$0].candidateID == candidate.id }, id: \.self) { index in
                        HStack(spacing: 12) {
                            if (try? DownloadSource.parse(candidate.url.absoluteString))?.supportsAudioExtraction == true {
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
                                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 160, alignment: .leading)
                                .accessibilityLabel(L("下载格式") + " · " + candidate.title)
                            }
                            Toggle(L("已有的跳过"), isOn: skipExisting(index, candidateID: candidate.id))
                                .toggleStyle(.checkbox).font(.system(size: 11))
                        }.controlSize(.small)
                    }
                }
            }.padding(.leading, 20)
        }.frame(maxWidth: .infinity, alignment: .leading)
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

private extension SmartFormat {
    var label: String {
        switch self { case .inherit: return "沿用默认"; case .video: return "视频"; case .audio: return "仅音频" }
    }
}
