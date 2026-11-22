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

/// An event's title, after its kind's symbol (out of office, focus time) where it has one. Tasks draw their own
/// check circle, which can be clicked.
func eventTitle(_ event: CalendarEvent) -> Text {
    guard event.type == .outOfOffice || event.type == .focusTime else { return Text(verbatim: event.shownTitle) }
    return Text("\(Image(systemName: event.type.symbol)) \(event.shownTitle)")
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
