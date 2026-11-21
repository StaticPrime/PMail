import AppKit
import PMailKit
import SwiftUI

/// A button with a menu of times to come (for snoozing or scheduling) and "Pick date & time…".
struct LaterPicker<Label: View>: View {
    let help: String
    let heading: String
    let choices: () -> [LaterTimes.Choice]
    let pick: (Date) -> Void
    @ViewBuilder var label: () -> Label
    @State private var showsCustom = false
    @State private var custom = Date()

    var body: some View {
        Menu {
            Text(heading)
            ForEach(choices(), id: \.title) { choice in
                Button("\(choice.title)   \(AppClock.formatting.laterDate(choice.date))") { pick(choice.date) }
            }
            Divider()
            Button("Pick date & time…") {
                custom = Calendar.current.date(byAdding: .hour, value: 1, to: AppClock.now()) ?? AppClock.now()
                showsCustom = true
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(help)
        .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
            CustomTimePicker(title: heading, date: $custom) { date in
                showsCustom = false
                pick(date)
            } cancel: {
                showsCustom = false
            }
        }
    }
}

/// A calendar and a time, for a snooze or a scheduled message at a time of one's own.
struct CustomTimePicker: View {
    let title: String
    @Binding var date: Date
    let save: (Date) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.pm(15, .medium)).foregroundStyle(Theme.textPrimary)
            DatePicker("Date", selection: $date, in: AppClock.now()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(date <= AppClock.now())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.surfaceRaised)
    }
}

/// Send, with a menu on its right half for sending later.
struct SplitSendButton: View {
    let isSending: Bool
    let send: () -> Void
    let schedule: (Date) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: send) {
                Text(isSending ? "Sending…" : "Send")
                    .font(.pm(13, .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.leading, 20)
                    .padding(.trailing, 14)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘Return)")
            Rectangle().fill(Theme.onAccent.opacity(0.35)).frame(width: 1, height: 22)
            LaterPicker(help: "Schedule send", heading: "Schedule send", choices: { LaterTimes.scheduleSend(now: AppClock.now()) },
                        pick: schedule) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            }
            .frame(width: 32)
        }
        .background(Capsule().fill(Theme.accent))
        .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 2, y: 1)
        .onHover { hovering = $0 }
        .disabled(isSending)
        .opacity(isSending ? 0.6 : 1)
    }
}

/// The note across the top of a panel while PMail is showing what it last loaded.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(Theme.textSecondary)
            Text("You’re offline. PMail is showing what it last loaded; new mail, sending and changes wait until it can reach the server.")
                .font(.pm(12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.chip.opacity(0.6))
        .accessibilityElement(children: .combine)
    }
}
