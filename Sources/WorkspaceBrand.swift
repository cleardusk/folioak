import SwiftUI

// Live breakdown of the draft so users see what Folioak understood before
// starting. Parsing is bounded by the batch limit and has no side effects.
struct InputRecognition: Equatable {
    var papers = 0, media = 0, files = 0, invalid = 0
    var total: Int { papers + media + files + invalid }

    init(_ text: String) {
        for token in DownloadSource.tokens(in: text).prefix(ResourceLimits.batchCount) {
            switch try? DownloadSource.parse(token) {
            case .arxiv?, .pdf?: papers += 1
            case .media?: media += 1
            case .file?: files += 1
            case nil: invalid += 1
            }
        }
    }
}

struct InputRecognitionChips: View {
    @ObservedObject private var localization = AppLocalization.shared
    let recognition: InputRecognition
    let palette: ThemePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parts: [(id: String, symbol: String, label: String, count: Int, error: Bool)] {
        [("papers", "doc.text", L("论文"), recognition.papers, false),
         ("media", "play.rectangle", L("视频"), recognition.media, false),
         ("files", "doc", L("文件"), recognition.files, false),
         ("invalid", "exclamationmark.circle", L("无法识别"), recognition.invalid, true)].filter { $0.count > 0 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(parts, id: \.id) { part in
                HStack(spacing: 4) {
                    Image(systemName: part.symbol).font(.system(size: 10, weight: .semibold))
                    Text("\(part.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(part.error ? UIColors.error : ThemePalette.color(palette.accent))
                .padding(.horizontal, 8).frame(height: 22)
                .background((part.error ? UIColors.error : ThemePalette.color(palette.accent)).opacity(0.10), in: Capsule())
                .help(part.label + " · " + L("\(part.count) 项"))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: recognition)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { $0.label + " " + L("\($0.count) 项") }.joined(separator: "，"))
        .accessibilityHidden(parts.isEmpty)
    }
}

// First-run state for the download page: explains scope in one glance and
// offers a single example so a new user reaches a finished file quickly.
struct DownloadsWelcome: View {
    @ObservedObject private var localization = AppLocalization.shared
    let palette: ThemePalette
    let busy: Bool
    let tryExample: () -> Void
    private static let sources = ["arXiv", "OpenReview", "ACL", "CVF", "YouTube", "Bilibili", "X", "抖音", "小红书", "PDF"]
    private var accent: Color { ThemePalette.color(palette.accent) }
    private var secondary: Color { ThemePalette.color(palette.secondary) }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.10)).frame(width: 64, height: 64)
                Circle().strokeBorder(accent.opacity(0.18), lineWidth: 1).frame(width: 88, height: 88)
                FolioakGlyph().foregroundStyle(accent).frame(width: 28, height: 28)
            }.accessibilityHidden(true).padding(.bottom, 4)
            Text(L("粘贴链接，开始下载")).font(.system(size: 15, weight: .semibold))
            Text(L("论文、视频与文件直链，自动按类型归档到本地。"))
                .font(WorkspaceMetrics.TypeScale.body).foregroundStyle(secondary).multilineTextAlignment(.center)
            WelcomeFlow(spacing: 6) {
                ForEach(Self.sources, id: \.self) { source in
                    Text(L(source)).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                        .padding(.horizontal, 9).frame(height: 22)
                        .overlay(Capsule().strokeBorder(ThemePalette.color(palette.border), lineWidth: 1))
                }
            }.frame(maxWidth: 420).padding(.top, 2)
            Button(action: tryExample) {
                Label(L("试试示例：Attention Is All You Need"), systemImage: "sparkles")
            }.buttonStyle(QuietButtonStyle(palette: palette)).disabled(busy).padding(.top, 6)
                .help("arxiv.org/abs/1706.03762")
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Wrapping row for short chips; avoids GeometryReader feedback loops.
private struct WelcomeFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else { rows.append(([index], size.width, size.height)) }
        }
        return rows
    }
}
