import PMailKit
import SwiftUI

extension EventType {
    /// The symbol shown with the kind.
    var symbol: String {
        switch self {
        case .event: "calendar"
        case .task: "checkmark.circle"
        case .outOfOffice: "airplane"
        case .focusTime: "headphones"
        }
    }
}

extension CalendarEvent {
    /// The title as shown: "(No title)" for none.
    var shownTitle: String { title.isEmpty ? "(No title)" : title }

    /// The symbol shown before the title: a task's check circle (filled once it's done), or out of office's and focus
    /// time's own; none for an event.
    var titleSymbol: String? {
        switch type {
        case .event: nil
        case .task: isCompleted ? "checkmark.circle.fill" : "circle"
        case .outOfOffice, .focusTime: type.symbol
        }
    }
}

/// An event's title, after its kind's symbol (out of office, focus time) where it has one, and with "(Maybe)" or
/// "(Canceled)" after it. Tasks draw their own check circle, which can be clicked.
func eventTitle(_ event: CalendarEvent) -> Text {
    let note = Text(verbatim: AnswerLook(event).titleNote)
    guard event.type == .outOfOffice || event.type == .focusTime else { return Text(verbatim: event.shownTitle) + note }
    return Text("\(Image(systemName: event.type.symbol)) \(event.shownTitle)") + note
}

/// An event's title as `eventTitle` words it, as plain text (for checks and spoken labels).
func eventTitleString(_ event: CalendarEvent) -> String {
    event.shownTitle + AnswerLook(event).titleNote
}

/// How an event shows on the calendar for the answer you gave its invitation: solid for Yes (and for your own
/// events), outlined while it waits for an answer, see-through with "(Maybe)" after the title for Maybe, and
/// see-through and struck through for No. A canceled event is see-through and struck through, with "(Canceled)".
enum AnswerLook: Equatable {
    case solid
    case pending
    case maybe
    case declined
    case canceled

    init(_ event: CalendarEvent) {
        if event.status == .cancelled {
            self = .canceled
            return
        }
        switch event.myResponse {
        case .needsAction?: self = .pending
        case .tentative?: self = .maybe
        case .declined?: self = .declined
        case .accepted?, nil: self = .solid
        }
    }

    /// Whether the event's color shows only faintly (Maybe, No and canceled).
    var isFaint: Bool { self == .maybe || self == .declined || self == .canceled }
    /// How strongly the event's color fills it: none while it waits for an answer, faintly for Maybe, No and canceled.
    var fillOpacity: Double {
        switch self {
        case .solid: 1
        case .pending: 0
        case .maybe, .declined, .canceled: 0.32
        }
    }
    var isStruckThrough: Bool { self == .declined || self == .canceled }

    /// What goes after the title.
    var titleNote: String {
        switch self {
        case .maybe: " (Maybe)"
        case .canceled: " (Canceled)"
        default: ""
        }
    }

    /// The color for the event's words on its fill: white on a solid color, the event's color on an outline, and the
    /// usual text colors on a faint one (dimmer for No).
    func textColor(on color: Color) -> Color {
        switch self {
        case .solid: .white
        case .pending: color
        case .maybe: Theme.textPrimary
        case .declined, .canceled: Theme.textSecondary
        }
    }

    /// What VoiceOver adds after the event's name.
    var spoken: String {
        switch self {
        case .solid: ""
        case .pending: ", not answered yet"
        case .maybe: ", maybe"
        case .declined: ", declined"
        case .canceled: ", canceled"
        }
    }
}

/// An event's color as a dot in lists: filled for Yes, a ring while it waits for an answer, faint for Maybe and No.
struct AnswerDot: View {
    let look: AnswerLook
    let color: Color
    let size: CGFloat

    var body: some View {
        if look == .pending {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: size, height: size)
        } else {
            Circle().fill(color.opacity(look.isFaint ? 0.4 : 1)).frame(width: size, height: size)
        }
    }
}

/// One of the kinds of item, as a pill to pick in the editor.
struct EventTypeChoice: View {
    let type: EventType
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: type.symbol).font(.system(size: 12, weight: .medium))
                Text(type.name).font(.pm(12.5, .medium))
            }
            .foregroundStyle(isSelected ? Theme.onSelection : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.textTertiary.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(type.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A task's check circle, which ticks it off (or back on).
struct TaskCheck: View {
    let model: CalendarViewModel
    let task: CalendarEvent
    var size: CGFloat = 13
    var color: Color = .white

    var body: some View {
        Button { model.setCompleted(task, !task.isCompleted) } label: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.isCompleted ? "Mark as not done" : "Mark as done")
        .accessibilityLabel(task.isCompleted ? "Mark \(task.shownTitle) as not done" : "Mark \(task.shownTitle) as done")
    }
}
