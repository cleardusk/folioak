import SwiftUI
private typealias PresentationState<Value> = SwiftUI.State<Value>

enum LibraryDisplayMode: String, CaseIterable {
    case list, grid
    var label: String { self == .list ? "列表视图" : "网格视图" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum LibraryGridLayout {
    static let minimumColumnWidth: CGFloat = 232
    static let spacing: CGFloat = 16
    static func columns(width: CGFloat) -> Int { max(1, Int((max(0, width - 18) + spacing) / (minimumColumnWidth + spacing))) }
    static func destination(index: Int, count: Int, columns: Int, action: PaperListKeyboard.Action) -> Int {
        let columns = max(1, columns)
        switch action {
        case .up, .extendUp: return index < columns ? index : index - columns
        case .down, .extendDown: return index / columns >= (count - 1) / columns ? index : min(count - 1, index + columns)
        case .left, .extendLeft: return max(0, index - 1)
        case .right, .extendRight: return min(count - 1, index + 1)
        default: return index
        }
    }
    static func offset(_ action: PaperListKeyboard.Action, columns: Int) -> Int? {
        switch action {
        case .up, .extendUp: return -max(1, columns)
        case .down, .extendDown: return max(1, columns)
        case .left, .extendLeft: return -1
        case .right, .extendRight: return 1
        default: return nil
        }
    }
}

struct LibraryDisplayPicker: View {
    @Binding var selection: LibraryDisplayMode
    let palette: ThemePalette
    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                Button {
                    guard selection != mode else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { selection = mode }
                } label: {
                    Image(systemName: mode.symbol).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(LibraryDisplayButtonStyle(selected: selection == mode, palette: palette)).help(L(mode.label)).accessibilityLabel(L(mode.label))
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    .accessibilityIdentifier("library-display-" + mode.rawValue)
            }
        }.padding(2).background(ThemePalette.color(palette.surface), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain).accessibilityLabel(L("显示方式"))
    }
}

private struct LibraryDisplayButtonStyle: ButtonStyle {
    let selected: Bool
    let palette: ThemePalette
    @PresentationState private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ThemePalette.color(selected ? palette.accent : palette.secondary))
            .background(ThemePalette.color(palette.accent).opacity(configuration.isPressed ? 0.22 : selected ? 0.12 : hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

enum AssetGridPreview {
    case document, media
    // Keep the preview compact even when fewer columns make each card wider.
    var height: CGFloat { 156 }
    // Stable request sizes avoid generating new thumbnails on every window resize.
    var requestSize: CGSize { self == .document ? CGSize(width: 280, height: 280) : CGSize(width: 320, height: 200) }
    var inset: CGFloat { self == .document ? 14 : 8 }
}

struct AssetGridCard<Controls: View>: View {
    let title: String
    let subtitle: String
    let file: URL?
    let symbol: String
    let badge: String
    let palette: ThemePalette
    let revision: String
    var preview: AssetGridPreview = .document
    var subtitleIsError = false
    var favorite = false
    var unread = false
    @ViewBuilder let controls: () -> Controls
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileThumbnail(url: file, fallbackSymbol: symbol, palette: palette, revision: revision,
                          size: preview.requestSize, flexible: true, contentInset: preview.inset)
                .frame(height: preview.height)
                .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(WorkspaceMetrics.TypeScale.title).lineLimit(3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).help(title)
                Text(subtitle).font(WorkspaceMetrics.TypeScale.supporting)
                    .foregroundStyle(subtitleIsError ? UIColors.error : ThemePalette.color(palette.secondary))
                    .lineLimit(1).help(subtitle)
            }.frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 70, alignment: .topLeading)
                .padding(.horizontal, 4)
            HStack(spacing: 6) {
                Text(badge).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(ThemePalette.color(palette.secondary))
                if favorite {
                    Image(systemName: "star.fill").font(.system(size: 10))
                        .foregroundStyle(ThemePalette.color(palette.accent)).accessibilityLabel(L("已收藏"))
                }
                if unread {
                    HStack(spacing: 4) {
                        Circle().fill(ThemePalette.color(palette.accent)).frame(width: 4, height: 4)
                        Text(L("未读")).font(.system(size: 10)).foregroundStyle(ThemePalette.color(palette.secondary))
                    }.accessibilityElement(children: .ignore).accessibilityLabel(L("未读"))
                }
                Spacer(minLength: 0)
                controls().fixedSize()
            }.frame(height: WorkspaceMetrics.controlHeight).padding(.leading, 4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
