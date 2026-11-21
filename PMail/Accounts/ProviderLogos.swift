import PMailKit
import SwiftUI

/// Each provider's mark, for choosing an account kind: the multicolored G, the four squares, the cloud, and an
/// envelope for every other mail service.
struct ProviderLogo: View {
    let kind: AccountKind
    var size: CGFloat = 40

    var body: some View {
        switch kind {
        case .google: GoogleMark().frame(width: size, height: size)
        case .microsoft: MicrosoftMark().frame(width: size * 0.9, height: size * 0.9).frame(width: size, height: size)
        case .icloud:
            Image(systemName: "icloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(LinearGradient(colors: [Theme.hex(0x5AC8FA), Theme.hex(0x007AFF)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size * 0.75)
                .frame(width: size, height: size)
        case .other:
            Image(systemName: "envelope.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.accent)
                .frame(width: size * 0.82, height: size * 0.62)
                .frame(width: size, height: size)
        }
    }
}

/// The four-colored G: a ring open at the upper right, with a bar into its middle.
private struct GoogleMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let stroke = side * 0.19
            let ring = side - stroke
            ZStack {
                arc(0.0, 0.125, Theme.hex(0x4285F4), ring: ring, stroke: stroke)
                arc(0.125, 0.375, Theme.hex(0x34A853), ring: ring, stroke: stroke)
                arc(0.375, 0.56, Theme.hex(0xFBBC05), ring: ring, stroke: stroke)
                arc(0.56, 0.875, Theme.hex(0xEA4335), ring: ring, stroke: stroke)
                Rectangle()
                    .fill(Theme.hex(0x4285F4))
                    .frame(width: side * 0.47, height: stroke)
                    .offset(x: side * 0.235, y: 0)
            }
            .frame(width: side, height: side)
        }
    }

    private func arc(_ from: CGFloat, _ to: CGFloat, _ color: Color, ring: CGFloat, stroke: CGFloat) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
            .frame(width: ring, height: ring)
    }
}

/// Four squares in a window: red, green, blue and yellow.
private struct MicrosoftMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let gap = side * 0.06
            let square = (side - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Rectangle().fill(Theme.hex(0xF25022)).frame(width: square, height: square)
                    Rectangle().fill(Theme.hex(0x7FBA00)).frame(width: square, height: square)
                }
                HStack(spacing: gap) {
                    Rectangle().fill(Theme.hex(0x00A4EF)).frame(width: square, height: square)
                    Rectangle().fill(Theme.hex(0xFFB900)).frame(width: square, height: square)
                }
            }
        }
    }
}

/// The four ways to add an account, as big tiles.
struct ProviderGrid: View {
    let app: AppModel
    let choose: (AccountKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(AccountKind.allCases, id: \.self) { kind in
                ProviderTile(kind: kind, subtitle: subtitle(kind)) { choose(kind) }
            }
        }
    }

    private func subtitle(_ kind: AccountKind) -> String {
        switch kind {
        case .google, .microsoft: "Mail, calendar, contacts and \(kind == .google ? "Meet" : "Teams") meetings"
        case .icloud: "Mail, calendar, contacts and FaceTime links"
        case .other: "Any IMAP, POP and SMTP mail account"
        }
    }
}

private struct ProviderTile: View {
    let kind: AccountKind
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ProviderLogo(kind: kind, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind == .other ? "Other mail account" : kind.displayName).font(.pm(15, .medium)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.pm(12)).foregroundStyle(Theme.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 18)
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 14).fill(hovering ? Theme.hover : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.divider))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(kind == .other ? "Other mail account" : kind.displayName)
        .accessibilityHint(subtitle)
    }
}
