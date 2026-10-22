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
        VStack(alignment: .leading, spacing: 14) {
            if let progress = state.progress {
                SmartRetrievalProgressView(state: state, progress: progress, palette: palette,
                    compact: compact, onCancel: {
                        if let onEdit { onEdit() } else { state.cancel() }
                    })
            } else {
                if let message = state.message, !message.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: state.failed ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(state.failed ? UIColors.error : ThemePalette.color(palette.accent))
                            .font(.system(size: 13)).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            if state.failed {
                                Text(L("未能完成查找")).font(.system(size: 12, weight: .medium))
                            }
                            Text(L(message)).font(.system(size: state.failed ? 11 : 12))
                                .foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("smart-input-message")
                        }
                        Spacer(minLength: 4)
                        if state.resolution == nil {
                            Button(action: state.cancel) { Image(systemName: "xmark").frame(width: 22, height: 22) }
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
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(resolution.candidates) { candidate in
                                    candidateRow(candidate, showsSelection: true)
                                    if candidate.id != resolution.candidates.last?.id { Divider() }
                                }
                            }.padding(.trailing, 4)
                        }
                        .frame(height: compact ? 166 : 182)
                        .accessibilityIdentifier("smart-input-candidates")
                    }
                    if !resolution.notes.isEmpty {
                        SmartInputDetailsView(label: L("选择说明"), details: resolution.notes,
                            palette: palette, identifier: "smart-input-notes")
                    }
                    if !resolution.unresolved.isEmpty {
                        if resolution.candidates.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("暂未找到可下载的资料")).font(.system(size: 15, weight: .medium))
                                Text(L(resolution.unresolved[0])).font(.system(size: 12))
                                    .foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                                if resolution.unresolved.count > 1 {
                                    SmartInputDetailsView(label: L("还有 \(resolution.unresolved.count - 1) 项待补充"),
                                        details: Array(resolution.unresolved.dropFirst()), palette: palette,
                                        identifier: "smart-input-unresolved")
                                }
                            }
                        } else {
                            SmartInputDetailsView(label: L("还有 \(resolution.unresolved.count) 项待补充"),
                                details: resolution.unresolved, palette: palette, identifier: "smart-input-unresolved")
                        }
                    }
                    if showsReviewActions {
                        HStack {
                            Spacer(minLength: 0)
                            SmartInputReviewActionsView(state: state, palette: palette,
                                submitShortcut: submitShortcut, onEdit: onEdit)
                        }.padding(.top, 2)
                    }
                } else if !state.remainingRequirements.isEmpty {
                    SmartInputDetailsView(label: L("还有 \(state.remainingRequirements.count) 项待补充"),
                        details: state.remainingRequirements, palette: palette, identifier: "smart-input-unresolved")
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
        let source = try? DownloadSource.parse(candidate.url.absoluteString)
        let hasFormats = source?.supportsAudioExtraction == true
        let multiple = (state.resolution?.candidates.count ?? 0) > 1
        return HStack(alignment: .top, spacing: compact ? 10 : 14) {
            if showsSelection {
                Toggle(L("选择资料"), isOn: Binding(get: {
                    state.selections.contains { $0.candidateID == candidate.id }
                }, set: { state.setSelected(candidate, selected: $0) }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(!selected && !state.canSelect(candidate))
                    .padding(.top, 4)
                    .accessibilityLabel(L("选择资料") + " · " + candidate.title)
                    .accessibilityIdentifier("smart-input-selection-" + candidate.id)
            }
            if !compact || !multiple {
                SmartResourceMark(source: source, palette: palette)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(candidate.title).font(.system(size: compact ? 14 : 17, weight: .semibold))
                    .lineSpacing(2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(candidate.title).accessibilityIdentifier("smart-input-candidate-" + candidate.id)
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
            }.frame(maxWidth: .infinity, alignment: .leading)
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
        if source?.isPaper == true { return source?.reference.map { "arXiv " + $0.identifier + " · PDF" } ?? (host + " · PDF") }
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

private struct SmartResourceMark: View {
    let source: DownloadSource?
    let palette: ThemePalette
    private var isPaper: Bool { source?.isPaper == true }
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: isPaper ? "doc.text" : source?.isMedia == true ? "play.rectangle" : "doc")
                .font(.system(size: 21, weight: .light))
            if isPaper { Text("PDF").font(.system(size: 8, weight: .semibold)) }
        }
        .foregroundStyle(ThemePalette.color(palette.accent))
        .frame(width: 42, height: 56)
        .background(ThemePalette.color(palette.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(ThemePalette.color(palette.accent).opacity(0.18), lineWidth: 1))
    }
}

private struct SmartRetrievalProgressView: View {
    @ObservedObject var state: SmartDownloadState
    let progress: SmartProgress
    let palette: ThemePalette
    let compact: Bool
    let onCancel: () -> Void
    @WorkspaceViewState private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var secondary: Color { ThemePalette.color(palette.secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(L(progress.label)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .accessibilityIdentifier("smart-input-progress")
                Spacer(minLength: 4)
                if !state.activityHistory.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L("检索步骤"))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }.frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(secondary)
                    .accessibilityIdentifier("smart-input-activity-toggle")
                    .accessibilityValue(L(expanded ? "已展开" : "已折叠"))
                }
                Button(action: onCancel) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 7))
                        Text(L("取消")).font(.system(size: 11))
                    }.padding(.horizontal, 9).frame(height: 28)
                        .background(secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).foregroundStyle(secondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("smart-input-cancel")
            }
            if let detail = progress.detail, !detail.isEmpty {
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(secondary)
                    .lineLimit(1).truncationMode(.middle).help(detail)
                    .padding(.leading, 25).accessibilityIdentifier("smart-input-progress-detail")
            }
            if expanded {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(state.activityHistory.enumerated()), id: \.offset) { index, action in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: action.symbol).font(.system(size: 11))
                                        .frame(width: 15, height: 16).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(L(actionTitle(action))).font(.system(size: 11, weight: .medium))
                                        if let detail = action.detail {
                                            Text(verbatim: detail).font(.system(size: 11)).lineLimit(1)
                                                .truncationMode(.middle).help(detail)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.foregroundStyle(secondary).id(index)
                            }
                        }.padding(.vertical, 2).padding(.trailing, 4)
                    }
                    .frame(height: min(compact ? 104 : 120, CGFloat(state.activityHistory.count) * 42))
                    .onChange(of: state.activityHistory) { _ in
                        reader.scrollTo(state.activityHistory.count - 1, anchor: .bottom)
                    }
                }
                .padding(.leading, 25).padding(.top, 2)
                .accessibilityIdentifier("smart-input-activity-history")
            }
        }
    }

    private func actionTitle(_ action: SmartProgress) -> String {
        switch action {
        case .searchingQuery: return "搜索"
        case .readingSource: return "读取页面"
        case .checkingSources: return "官方资料"
        default: return action.label
        }
    }
}

struct SmartInputDetailsView: View {
    let label: String
    let details: [String]
    let palette: ThemePalette
    let identifier: String
    @WorkspaceViewState private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(label).font(.system(size: 11))
                }.frame(minHeight: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier(identifier)
            .accessibilityValue(L(expanded ? "已展开" : "已折叠"))
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            Text(L(detail)).font(.system(size: 12)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.trailing, 4)
                }
                .frame(height: min(110, CGFloat(details.reduce(0) { $0 + max(1, ($1.count + 39) / 40) }) * 19 + 8))
                .padding(.leading, 14)
            }
        }.foregroundStyle(ThemePalette.color(palette.secondary))
            .onChange(of: details) { _ in expanded = false }
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
            Button(L("修改需求")) {
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
                    .disabled(!state.canAcceptSelection)
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
