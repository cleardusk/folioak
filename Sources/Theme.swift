import SwiftUI
import AppKit

// Shared dimensions for the workspace. Preview artwork may use finer geometry.
enum WorkspaceMetrics {
    enum Space {
        static let small: CGFloat = 4
        static let compact: CGFloat = 8
        static let regular: CGFloat = 12
        static let section: CGFloat = 16
        static let inset: CGFloat = 20
        static let page: CGFloat = 24
    }
    enum Radius {
        static let control: CGFloat = 8
        static let sidebar: CGFloat = 12
        static let panel: CGFloat = 16
    }
    enum TypeScale {
        static let page = Font.system(size: 20, weight: .semibold)
        static let title = Font.system(size: 13, weight: .medium)
        static let rowTitle = Font.system(size: 13)
        static let body = Font.system(size: 13)
        static let supporting = Font.system(size: 11)
    }
    static let headerHeight: CGFloat = 76
    static let controlHeight: CGFloat = 32
    static let rowIconSize: CGFloat = 44
    static let inputHeight: CGFloat = 64
}

struct ThemePalette {
    let canvas: UInt32
    let surface: UInt32
    let text: UInt32
    let secondary: UInt32
    let border: UInt32
    let accent: UInt32
    let action: UInt32
    let onAction: UInt32

    var sidebar: UInt32 { surface }

    func accessibilityAdjusted(_ contrast: ColorSchemeContrast) -> ThemePalette {
        guard contrast == .increased else { return self }
        // Stronger secondary text and separators retain each theme's hue.
        func blend(_ first: UInt32, _ second: UInt32) -> UInt32 {
            var result: UInt32 = 0
            for shift: UInt32 in [16, 8, 0] {
                let value = Double((first >> shift) & 255) * 0.65 + Double((second >> shift) & 255) * 0.35
                result |= UInt32(value.rounded()) << shift
            }
            return result
        }
        return ThemePalette(canvas: canvas, surface: surface, text: text,
                            secondary: blend(secondary, text), border: text,
                            accent: accent, action: action, onAction: onAction)
    }

    static func color(_ hex: UInt32) -> Color { Color(nsColor: nativeColor(hex)) }
    static func nativeColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: 1)
    }
}

enum AppTheme: String, CaseIterable {
    case grove, native, graphite, iris, lagoon, amber, midnight
    case vscode, oneDark, dracula, nord, solarized, gruvbox

    // Grove is the signature palette derived from the oak-leaf mark.
    static let standardThemes: [AppTheme] = [.grove, .native, .graphite, .iris, .lagoon, .amber, .midnight]
    static let codingThemes: [AppTheme] = [.vscode, .oneDark, .dracula, .nord, .solarized, .gruvbox]

    var label: String {
        switch self {
        case .grove: return L("林叶")
        case .native: return L("暖砂")
        case .graphite: return L("石墨")
        case .iris: return L("鸢尾")
        case .lagoon: return L("海湾")
        case .amber: return L("琥珀")
        case .midnight: return L("午夜")
        case .vscode: return "VS Code"
        case .oneDark: return "One Dark"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .solarized: return "Solarized"
        case .gruvbox: return "Gruvbox"
        }
    }

    func palette(dark: Bool) -> ThemePalette {
        switch (self, dark) {
        case (.grove, false):
            return ThemePalette(canvas: 0xFBFCFA, surface: 0xF0F4F1, text: 0x18231E, secondary: 0x56665E, border: 0xD9E2DC, accent: 0x0A7A50, action: 0x0B7F53, onAction: 0xFFFFFF)
        case (.grove, true):
            return ThemePalette(canvas: 0x0B100E, surface: 0x141B18, text: 0xE2ECE6, secondary: 0xA0B3A9, border: 0x2A3731, accent: 0x4CCF97, action: 0x3FC58C, onAction: 0x04241A)
        case (.native, false):
            return ThemePalette(canvas: 0xFFFAF8, surface: 0xF5EEEA, text: 0x28201D, secondary: 0x766862, border: 0xE2D8D1, accent: 0x805644, action: 0x805644, onAction: 0xFFFFFF)
        case (.native, true):
            return ThemePalette(canvas: 0x100D0B, surface: 0x1B1613, text: 0xEBE0DA, secondary: 0xBAAAA2, border: 0x41352E, accent: 0xE9BFA9, action: 0x624638, onAction: 0xFFE1CF)
        case (.graphite, false):
            return ThemePalette(canvas: 0xFAFAFA, surface: 0xF0F0F0, text: 0x242424, secondary: 0x6C6C6C, border: 0xDDDDDD, accent: 0x555555, action: 0x444444, onAction: 0xFFFFFF)
        case (.graphite, true):
            return ThemePalette(canvas: 0x101010, surface: 0x1D1D1D, text: 0xE8E8E8, secondary: 0xA8A8A8, border: 0x363636, accent: 0xC9C9C9, action: 0x454545, onAction: 0xF0F0F0)
        case (.iris, false):
            return ThemePalette(canvas: 0xFCFAFF, surface: 0xF1EDF7, text: 0x292431, secondary: 0x70687A, border: 0xDED7E7, accent: 0x77608C, action: 0x77608C, onAction: 0xFFFFFF)
        case (.iris, true):
            return ThemePalette(canvas: 0x110F15, surface: 0x1D1923, text: 0xE9E1EF, secondary: 0xB3A7BD, border: 0x3B3346, accent: 0xD1B9E5, action: 0x51415F, onAction: 0xF3DDFF)
        case (.lagoon, false):
            return ThemePalette(canvas: 0xF9FCFB, surface: 0xEBF2F0, text: 0x202E2B, secondary: 0x5E706A, border: 0xD4E0DB, accent: 0x496F64, action: 0x496F64, onAction: 0xFFFFFF)
        case (.lagoon, true):
            return ThemePalette(canvas: 0x0D1210, surface: 0x171F1C, text: 0xE0E9E5, secondary: 0xA7B9B1, border: 0x303F38, accent: 0xADCEC0, action: 0x354E43, onAction: 0xD9EFE5)
        case (.amber, false):
            return ThemePalette(canvas: 0xFFFBF6, surface: 0xF6EFE4, text: 0x322B21, secondary: 0x776956, border: 0xE5DBCA, accent: 0x85672D, action: 0x87692F, onAction: 0xFFFFFF)
        case (.amber, true):
            return ThemePalette(canvas: 0x14110C, surface: 0x221C13, text: 0xEEE4D3, secondary: 0xBBAF9B, border: 0x443B2B, accent: 0xDEC491, action: 0x5B4B2D, onAction: 0xFFEAC0)
        case (.midnight, false):
            return ThemePalette(canvas: 0xFAFBFF, surface: 0xEDF0F7, text: 0x242C3C, secondary: 0x646C7F, border: 0xD7DDE9, accent: 0x576C91, action: 0x576C91, onAction: 0xFFFFFF)
        case (.midnight, true):
            return ThemePalette(canvas: 0x0E1016, surface: 0x191D27, text: 0xE2E6F1, secondary: 0xADB5C7, border: 0x333B50, accent: 0xB7C7E9, action: 0x3E4B69, onAction: 0xE2EAFF)
        // Editor palettes adapted for small UI text: supporting text and accents
        // retain at least 4.5:1 contrast on both canvas and surface.
        // https://github.com/microsoft/vscode/tree/main/extensions/theme-defaults/themes
        case (.vscode, false):
            return ThemePalette(canvas: 0xFFFFFF, surface: 0xF8F8F8, text: 0x3B3B3B, secondary: 0x616161, border: 0xCECECE, accent: 0x005FB8, action: 0x005FB8, onAction: 0xFFFFFF)
        case (.vscode, true):
            return ThemePalette(canvas: 0x1F1F1F, surface: 0x181818, text: 0xCCCCCC, secondary: 0x9D9D9D, border: 0x3C3C3C, accent: 0x4DAAFC, action: 0x0078D4, onAction: 0xFFFFFF)
        // Light appearance uses the companion One Light palette.
        // https://github.com/atom/one-dark-syntax/blob/master/styles/colors.less
        // https://github.com/atom/one-light-syntax/blob/master/styles/colors.less
        case (.oneDark, false):
            return ThemePalette(canvas: 0xFAFAFA, surface: 0xF0F0F1, text: 0x383A42, secondary: 0x696C77, border: 0xD7D7DA, accent: 0x305FC7, action: 0x305FC7, onAction: 0xFFFFFF)
        case (.oneDark, true):
            return ThemePalette(canvas: 0x282C34, surface: 0x21252B, text: 0xABB2BF, secondary: 0x9DA5B4, border: 0x3E4451, accent: 0x61AFEF, action: 0x61AFEF, onAction: 0x21252B)
        // Light appearance follows Dracula's Alucard Classic companion.
        // https://draculatheme.com/spec
        case (.dracula, false):
            return ThemePalette(canvas: 0xFFFBEB, surface: 0xEFEDDC, text: 0x1F1F1F, secondary: 0x6C664B, border: 0xCFCFDE, accent: 0x644AC9, action: 0x644AC9, onAction: 0xFFFFFF)
        case (.dracula, true):
            return ThemePalette(canvas: 0x282A36, surface: 0x21222C, text: 0xF8F8F2, secondary: 0xABB2CE, border: 0x44475A, accent: 0xBD93F9, action: 0xBD93F9, onAction: 0x282A36)
        // https://www.nordtheme.com/docs/colors-and-palettes/
        case (.nord, false):
            return ThemePalette(canvas: 0xECEFF4, surface: 0xE5E9F0, text: 0x2E3440, secondary: 0x4C566A, border: 0xD8DEE9, accent: 0x446789, action: 0x446789, onAction: 0xECEFF4)
        case (.nord, true):
            return ThemePalette(canvas: 0x2E3440, surface: 0x252B35, text: 0xECEFF4, secondary: 0xB8C2D3, border: 0x4C566A, accent: 0x88C0D0, action: 0x88C0D0, onAction: 0x2E3440)
        // https://ethanschoonover.com/solarized/
        case (.solarized, false):
            return ThemePalette(canvas: 0xFDF6E3, surface: 0xEEE8D5, text: 0x073642, secondary: 0x52686F, border: 0x93A1A1, accent: 0x216B8C, action: 0x216B8C, onAction: 0xFDF6E3)
        case (.solarized, true):
            return ThemePalette(canvas: 0x002B36, surface: 0x073642, text: 0xEEE8D5, secondary: 0x93A1A1, border: 0x586E75, accent: 0x35ACA3, action: 0x35ACA3, onAction: 0x002B36)
        // https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim
        case (.gruvbox, false):
            return ThemePalette(canvas: 0xFBF1C7, surface: 0xEBDBB2, text: 0x3C3836, secondary: 0x665C54, border: 0xBDAE93, accent: 0xA63803, action: 0xA63803, onAction: 0xFBF1C7)
        case (.gruvbox, true):
            return ThemePalette(canvas: 0x282828, surface: 0x32302F, text: 0xEBDBB2, secondary: 0xBDAE93, border: 0x504945, accent: 0xFE8019, action: 0xFE8019, onAction: 0x282828)
        }
    }
}

struct PrimaryActionStyle: ButtonStyle {
    let palette: ThemePalette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @WorkspaceViewState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ThemePalette.color(enabled ? palette.onAction : palette.secondary))
            .padding(.horizontal, 16)
            .frame(minWidth: 40, minHeight: 36)
            .background(shape.fill(enabled ? ThemePalette.color(palette.action) : ThemePalette.color(palette.border).opacity(0.55)))
            .overlay(shape.fill(Color.white.opacity(enabled ? (configuration.isPressed ? 0 : hovered ? 0.10 : 0) : 0)))
            .overlay(shape.fill(Color.black.opacity(enabled && configuration.isPressed ? 0.12 : 0)))
            .contentShape(shape)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: enabled)
    }
}

// The oak-leaf mark as a tintable template. Falls back to a system leaf when
// the resource is not bundled, such as in command-line test hosts.
struct FolioakGlyph: View {
    static let image: NSImage? = {
        let roots = [Bundle.main.resourceURL, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            if let image = NSImage(contentsOf: root.appendingPathComponent("FolioakGlyph.png")) { image.isTemplate = true; return image }
        }
        return nil
    }()
    var body: some View {
        if let image = Self.image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
        else { Image(systemName: "leaf.fill").resizable().aspectRatio(contentMode: .fit) }
    }
}

struct ThemeChoice: View {
    @ObservedObject private var localization = AppLocalization.shared
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = theme.palette(dark: scheme == .dark).accessibilityAdjusted(contrast)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(ThemePalette.color(palette.secondary)).frame(width: 26, height: 3)
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(ThemePalette.color(palette.surface))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ThemePalette.color(palette.border), lineWidth: 1))
                        RoundedRectangle(cornerRadius: 3).fill(ThemePalette.color(palette.action)).frame(width: 20)
                    }.frame(height: 14)
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThemePalette.color(palette.canvas))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemePalette.color(selected ? palette.accent : palette.border), lineWidth: selected ? 2 : 1))
                HStack(spacing: 4) {
                    Text(theme.label)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark").opacity(selected ? 1 : 0)
                }.font(.system(size: 11, weight: selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(L("\(theme.label)主题"))
            .accessibilityValue(selected ? L("已选中") : L("未选中"))
    }
}
