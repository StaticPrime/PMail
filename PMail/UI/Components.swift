import AppKit
import PMailKit
import SwiftUI

/// A round icon button that shows a soft circle under the pointer, as every toolbar icon does.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 16
    var tint: Color = Theme.icon
    var isDisabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering && !isDisabled ? Theme.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.38 : 1)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The big pastel Compose / Create button at the top of the sidebar.
struct BigActionButton: View {
    let title: String
    let symbol: String
    var collapsed = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                if !collapsed { Text(title).font(.pm(14, .medium)) }
            }
            .foregroundStyle(Theme.onCompose)
            .padding(.horizontal, collapsed ? 0 : 20)
            .frame(width: collapsed ? 56 : nil, height: 56)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.compose))
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: hovering ? 3 : 0, y: hovering ? 1.5 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A pill button with an outline (Reply, Today, the view picker).
struct OutlinePillButton: View {
    let title: String
    var symbol: String?
    var height: CGFloat = 36
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14)) }
                Text(title).font(.pm(13, .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(Capsule().fill(hovering ? Theme.hover : .clear))
            .overlay(Capsule().strokeBorder(Theme.textTertiary.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A filled pill in the accent color (Send, Save, Join).
struct FilledPillButton: View {
    let title: String
    var symbol: String?
    var height: CGFloat = 36
    var isDisabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
                Text(title).font(.pm(13, .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20)
            .frame(height: height)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }
}

/// A circle with a person's initials on a color made from their name, or the account's picture.
struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 32
    var color: Color?
    var imageData: Data?

    var body: some View {
        ZStack {
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(color ?? Theme.avatarColor(for: email.isEmpty ? name : email))
                Text(Account.initials(name: name, email: email))
                    .font(.system(size: size * (Account.initials(name: name, email: email).count > 1 ? 0.38 : 0.46), weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// An avatar for an account, in the account's own color.
struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 32

    var body: some View {
        let initials = Avatar(name: account.name, email: account.email, size: size,
                              color: Theme.avatarColors[abs(account.colorIndex) % Theme.avatarColors.count])
        // The provider's picture of the person, when it gave one; the initials until it loads, or if it can't.
        if let url = account.pictureURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
                } else {
                    initials
                }
            }
            .frame(width: size, height: size)
        } else {
            initials
        }
    }
}

/// A small rounded label ("Inbox", "Work"), optionally with a remove button.
struct Chip: View {
    let text: String
    var color: Color?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.pm(12)).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(text)")
            }
        }
        .foregroundStyle(color == nil ? Theme.textSecondary : .white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color ?? Theme.chip))
    }
}

/// A row with a pill highlight, for sidebars: folders, calendar views, contact groups.
struct SidebarRow<Trailing: View>: View {
    let title: String
    let symbol: String
    var isSelected: Bool
    var isBold = false
    var symbolColor: Color?
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(symbolColor ?? (isSelected ? Theme.onSelection : Theme.icon))
                    .frame(width: 20)
                    .padding(.trailing, 18)
                Text(title)
                    .font(.pm(13.5, isSelected || isBold ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.onSelection : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing()
                    .font(.pm(12, isSelected || isBold ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.onSelection : Theme.textPrimary)
            }
            .padding(.leading, 26)
            .padding(.trailing, 16)
            .frame(height: 32)
            .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 16,
                                               topTrailingRadius: 16, style: .continuous)
                .fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SidebarRow where Trailing == EmptyView {
    init(title: String, symbol: String, isSelected: Bool, isBold: Bool = false, symbolColor: Color? = nil, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, isSelected: isSelected, isBold: isBold, symbolColor: symbolColor,
                  trailing: { EmptyView() }, action: action)
    }
}

/// A checkbox drawn the same way in every row.
struct CheckBox: View {
    let isOn: Bool
    let help: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(isOn ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "checked" : "unchecked")
    }
}

/// The white rounded panel the lists and pages sit on.
struct Panel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A message across the top of a panel: an error, an offline note, a sign-in request.
struct Banner: View {
    let text: String
    var symbol = "exclamationmark.triangle"
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.danger)
            Text(text).font(.pm(12.5)).foregroundStyle(Theme.textPrimary).lineLimit(2).textSelection(.enabled)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.link).font(.pm(12.5, .medium))
            }
            if let onDismiss {
                IconButton(symbol: "xmark", help: "Dismiss", size: 24, iconSize: 10, action: onDismiss)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.08))
    }
}

/// Mouse-over tracking that also works inside buttons (onHover misses it in some nested layouts).
extension View {
    func hoverHighlight(_ hovering: Binding<Bool>) -> some View {
        onHover { hovering.wrappedValue = $0 }
    }
}

/// A pointer-shaped hand over links and clickable rows.
extension View {
    func pointingHand() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// The text cursor over a place to type, before it's clicked into as well as after (a text field only shows it
    /// itself once it's being edited).
    @ViewBuilder func textCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.horizontalText)
        } else {
            onHover { inside in
                if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
        }
    }

    /// The ordinary arrow, over something clickable inside a place to type (an address's chip, say).
    @ViewBuilder func arrowCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.default)
        } else {
            self
        }
    }
}
