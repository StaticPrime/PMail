import AppKit
import PMailKit
import SwiftUI

/// A timed event being dragged in the day or week view: where it was grabbed, where the pointer is, and where it
/// would land.
struct TimeDrag {
    let event: CalendarEvent
    /// How far into the event it was grabbed, so it moves with the pointer from there.
    let grab: TimeInterval
    /// The pointer, in the hours' own space (`TimeGridView.space`).
    var pointer: CGPoint
    /// The day it would land on (its column), and when it would start: on a quarter hour.
    var day = 0
    var start: Date

    var length: TimeInterval { event.end.timeIntervalSince(event.start) }
    var end: Date { start.addingTimeInterval(length) }
}

/// An event being dragged from one day to another: the day it was grabbed on, and the day the pointer is over.
struct DayDrag {
    let event: CalendarEvent
    let from: Date
    var to: Date
    /// The pointer, in the view's own space.
    var pointer: CGPoint

    /// How many days it moves.
    func shift(in calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// Its times moved by as many days, on the wall clock.
    func moved(in calendar: Calendar) -> (start: Date, end: Date) {
        let days = shift(in: calendar)
        return (calendar.date(byAdding: .day, value: days, to: event.start) ?? event.start,
                calendar.date(byAdding: .day, value: days, to: event.end) ?? event.end)
    }
}

/// Scrolls the hours of the day or week view while an event is dragged near (or past) their top or bottom edge,
/// faster nearer the edge, and says how far the hours moved under the pointer (points; more is later in the day).
final class EdgeScroller {
    weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var onScroll: ((CGFloat) -> Void)?

    func start(onScroll: @escaping (CGFloat) -> Void) {
        stop()
        self.onScroll = onScroll
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The pointer is held down: keep scrolling whatever the run loop is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onScroll = nil
    }

    private func tick() {
        guard let scrollView, let window = scrollView.window, let document = scrollView.documentView else { return }
        let visible = window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
        let pointer = NSEvent.mouseLocation
        let zone: CGFloat = 40
        // Screen coordinates rise upward: near the top shows earlier hours, near the bottom later ones.
        var speed: CGFloat = 0
        if pointer.y > visible.maxY - zone {
            speed = -min(1, (pointer.y - (visible.maxY - zone)) / zone)
        } else if pointer.y < visible.minY + zone {
            speed = min(1, (visible.minY + zone - pointer.y) / zone)
        }
        guard speed != 0 else { return }
        let step = speed * 14
        let clip = scrollView.contentView
        let flipped = document.isFlipped
        let limit = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        let before = origin.y
        origin.y = min(max(0, before + (flipped ? step : -step)), limit)
        guard origin.y != before else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        onScroll?(flipped ? origin.y - before : before - origin.y)
    }
}

/// Finds the scroll view a SwiftUI view is in, so it can be scrolled by hand.
struct ScrollViewFinder: NSViewRepresentable {
    let found: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FinderView()
        view.found = found
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FinderView: NSView {
        var found: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scrollView = enclosingScrollView { found?(scrollView) }
        }
    }
}
