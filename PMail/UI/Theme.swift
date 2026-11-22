import AppKit
import SwiftUI

/// PMail's colors, each with a light and a dark version, and the fonts the window uses.
enum Theme {
    /// A color that follows the window's appearance.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNS(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexNS(dark, darkAlpha) : hexNS(light, lightAlpha)
        }
    }

    static func hexNS(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func hex(_ hex: UInt32, _ alpha: CGFloat = 1) -> Color { Color(nsColor: hexNS(hex, alpha)) }

    /// "#RRGGBB" (or "#RRGGBBAA") as a color, or nil if it isn't one.
    static func color(hexString: String?) -> Color? {
        guard var text = hexString?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 8 { text = String(text.prefix(6)) }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return hex(value)
    }

    // MARK: Surfaces

    /// The window's background, behind the panels.
    static let canvas = dynamic(light: 0xF6F8FC, dark: 0x1B1C1E)
    static let canvasNS = dynamicNS(light: 0xF6F8FC, dark: 0x1B1C1E)
    /// The white panels the lists and pages sit on.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x232427)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x2B2C30)
    static let divider = dynamic(light: 0xE3E6EA, dark: 0x3A3C40)
    static let hover = dynamic(light: 0x1F1F1F, dark: 0xE3E3E3, lightAlpha: 0.06, darkAlpha: 0.08)
    static let pressed = dynamic(light: 0x1F1F1F, dark: 0xE3E3E3, lightAlpha: 0.12, darkAlpha: 0.14)

    // MARK: Text and icons

    static let textPrimary = dynamic(light: 0x1F1F1F, dark: 0xE3E3E3)
    static let textSecondary = dynamic(light: 0x444746, dark: 0xC4C7C5)
    static let textTertiary = dynamic(light: 0x5E6266, dark: 0x9AA0A6)
    static let icon = dynamic(light: 0x444746, dark: 0xC4C7C5)

    // MARK: Selection and accents

    static let accent = dynamic(light: 0x1557E8, dark: 0x8AB4F8)
    /// Text and icons on the accent color.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x062E6F)
    /// The pill behind the chosen folder, calendar view or rail item.
    static let selection = dynamic(light: 0xD3E3FD, dark: 0x004A77)
    static let onSelection = dynamic(light: 0x041E49, dark: 0xC2E7FF)
    /// Rows the person ticked.
    static let rowChecked = dynamic(light: 0xC2DBFF, dark: 0x3A4A63)
    /// Rows already read.
    static let rowRead = dynamic(light: 0xF2F6FC, dark: 0x1E1F21, lightAlpha: 0.75)
    /// The big Compose / Create button.
    static let compose = dynamic(light: 0xC2E7FF, dark: 0x004A77)
    static let onCompose = dynamic(light: 0x001D35, dark: 0xC2E7FF)
    static let searchField = dynamic(light: 0xE9EEF6, dark: 0x2D2F33)
    static let searchFieldFocused = dynamic(light: 0xFFFFFF, dark: 0x3A3C40)
    static let star = dynamic(light: 0xF4B400, dark: 0xFDD663)
    static let important = dynamic(light: 0xF4B400, dark: 0xFDD663)
    static let danger = dynamic(light: 0xD93025, dark: 0xF28B82)
    /// Junk's mark and banner.
    static let junk = dynamic(light: 0xA0522D, dark: 0xE3A57E)
    static let now = dynamic(light: 0xEA4335, dark: 0xF28B82)
    static let chip = dynamic(light: 0xE8EAED, dark: 0x3C4043)
    static let composeHeader = dynamic(light: 0xF2F6FC, dark: 0x303134)
    static let toast = dynamic(light: 0x303134, dark: 0xE3E3E3)
    static let onToast = dynamic(light: 0xF2F2F2, dark: 0x202124)

    /// Colors for avatars without pictures, picked by account or by name.
    static let avatarColors: [Color] = [0x1E8E3E, 0xD93025, 0x1A73E8, 0xE37400, 0x9334E6, 0x188038, 0xC5221F, 0x12B5CB, 0xE52592,
                                        0x7E57C2, 0x5F6368, 0x00897B].map { hex($0) }

    static func avatarColor(for text: String) -> Color {
        var hash: UInt32 = 5381
        for byte in text.lowercased().utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return avatarColors[Int(hash % UInt32(avatarColors.count))]
    }

    /// The colors an event or calendar can be given, in the order the color picker shows them.
    static let eventColors: [(name: String, hex: String)] = [
        ("Red", "#D93025"), ("Pink", "#E8717A"), ("Orange", "#F06B1F"), ("Yellow", "#F2B90C"), ("Green", "#2FB57A"),
        ("Dark green", "#188038"), ("Sky blue", "#129EE0"), ("Blue", "#3B5BDB"), ("Lavender", "#7C8BD6"), ("Purple", "#9334E6"),
        ("Gray", "#5F6368"),
    ]
}

extension Font {
    /// The window's fonts: the system font at the sizes PMail's layout is drawn for.
    static func pm(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}
