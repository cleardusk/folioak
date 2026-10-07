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
        case .native: return "原生"
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
            return ThemePalette(canvas: 0xF3F4F6, surface: 0xFFFFFF, text: 0x202124, secondary: 0x5F6368, border: 0xD1D5DB, accent: 0x005AB8, action: 0x0069D9, onAction: 0xFFFFFF)
        case (.native, true):
            return ThemePalette(canvas: 0x1E1E1E, surface: 0x252525, text: 0xEAEAEA, secondary: 0xB3B3B3, border: 0x484848, accent: 0x75B5FF, action: 0x75B5FF, onAction: 0x102139)
        case (.graphite, false):
            return ThemePalette(canvas: 0xF7F7F7, surface: 0xFFFFFF, text: 0x242424, secondary: 0x626262, border: 0xD6D6D6, accent: 0x414141, action: 0x242424, onAction: 0xFFFFFF)
        case (.graphite, true):
            return ThemePalette(canvas: 0x171717, surface: 0x232323, text: 0xECECEC, secondary: 0xB0B0B0, border: 0x444444, accent: 0xD8D8D8, action: 0xE7E7E7, onAction: 0x202020)
        case (.iris, false):
            return ThemePalette(canvas: 0xF6F3FA, surface: 0xFEFCFF, text: 0x2A2532, secondary: 0x675F73, border: 0xD9D0E5, accent: 0x7050A0, action: 0x7050A0, onAction: 0xFFFFFF)
        case (.iris, true):
            return ThemePalette(canvas: 0x211D29, surface: 0x2D2738, text: 0xEDE7F5, secondary: 0xBDB2CA, border: 0x51465F, accent: 0xC9ABEF, action: 0xC9ABEF, onAction: 0x2A183F)
        case (.lagoon, false):
            return ThemePalette(canvas: 0xF0F6F6, surface: 0xFBFFFF, text: 0x203333, secondary: 0x526A6A, border: 0xC8DADB, accent: 0x007278, action: 0x007278, onAction: 0xFFFFFF)
        case (.lagoon, true):
            return ThemePalette(canvas: 0x152526, surface: 0x1E3234, text: 0xE2EEEE, secondary: 0xABC2C3, border: 0x3C595C, accent: 0x79CBCD, action: 0x79CBCD, onAction: 0x123335)
        case (.amber, false):
            return ThemePalette(canvas: 0xF8F4EF, surface: 0xFFFCF8, text: 0x352C24, secondary: 0x716254, border: 0xE0D4C7, accent: 0x935719, action: 0x935719, onAction: 0xFFFFFF)
        case (.amber, true):
            return ThemePalette(canvas: 0x28221C, surface: 0x352D24, text: 0xF0E8DE, secondary: 0xC7B9A8, border: 0x5D4E3E, accent: 0xE8BA7B, action: 0xE8BA7B, onAction: 0x39250D)
        case (.midnight, false):
            return ThemePalette(canvas: 0xEFF3FA, surface: 0xFCFDFF, text: 0x26324A, secondary: 0x5B6780, border: 0xCDD6E8, accent: 0x365FA9, action: 0x365FA9, onAction: 0xFFFFFF)
        case (.midnight, true):
            return ThemePalette(canvas: 0x182235, surface: 0x233047, text: 0xE4EAF6, secondary: 0xB0BED7, border: 0x42526C, accent: 0xA3BFFD, action: 0xA3BFFD, onAction: 0x192C50)
        }
    }
}

struct PrimaryActionStyle: ButtonStyle {
    let palette: ThemePalette
    var prominent = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ThemePalette.color(enabled ? (prominent ? palette.onAction : palette.text) : palette.secondary))
            .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 28)
            .background(ThemePalette.color(enabled && prominent ? palette.action : palette.surface).opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(enabled && prominent ? Color.clear : ThemePalette.color(palette.border), lineWidth: 1))
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
