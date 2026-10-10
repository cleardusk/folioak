import SwiftUI
import AppKit

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

    static func color(_ hex: UInt32) -> Color { Color(nsColor: nativeColor(hex)) }
    static func nativeColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: 1)
    }
}

enum AppTheme: String, CaseIterable {
    case native, graphite, iris, lagoon, amber, midnight

    var label: String {
        switch self {
        case .native: return "暖砂"
        case .graphite: return "石墨"
        case .iris: return "鸢尾"
        case .lagoon: return "海湾"
        case .amber: return "琥珀"
        case .midnight: return "午夜"
        }
    }

    func palette(dark: Bool) -> ThemePalette {
        switch (self, dark) {
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
        }
    }
}

struct PrimaryActionStyle: ButtonStyle {
    let palette: ThemePalette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(ThemePalette.color(enabled ? palette.onAction : palette.secondary).opacity(enabled ? 1 : 0.5))
            .frame(width: 40, height: 40)
            .background(ThemePalette.color(enabled ? palette.action : palette.border).opacity(enabled ? 1 : 0.4), in: Circle())
            .contentShape(Circle())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.95 : 1)
    }
}

struct ThemeChoice: View {
    static let previewHeight: CGFloat = 41
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = theme.palette(dark: scheme == .dark)
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
            .accessibilityLabel("\(theme.label)主题")
            .accessibilityValue(selected ? "已选中" : "未选中")
    }
}
