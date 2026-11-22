import MapKit
import Observation
import SwiftUI

/// A place suggested for an event's location: its name and address.
struct PlaceSuggestion: Hashable, Identifiable {
    let title: String
    let subtitle: String

    var id: String { title + "\n" + subtitle }
    /// What goes in the event's location: the name, then the address.
    var text: String { subtitle.isEmpty ? title : title + ", " + subtitle }
}

/// Finds places for what's typed in an event's location.
@MainActor
protocol PlaceFinder: AnyObject {
    /// Looks for places matching some text and hands them to `found` (perhaps more than once, as better ones come).
    func find(_ text: String, found: @escaping @MainActor ([PlaceSuggestion]) -> Void)
    func cancel()
}

/// Places from Apple Maps (MapKit's search completer): names and addresses for what's typed. It needs no location
/// access; what's typed goes to Apple.
@MainActor
final class AppleMapsPlaceFinder: NSObject, PlaceFinder {
    private let completer = MKLocalSearchCompleter()
    private var found: (@MainActor ([PlaceSuggestion]) -> Void)?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func find(_ text: String, found: @escaping @MainActor ([PlaceSuggestion]) -> Void) {
        self.found = found
        completer.queryFragment = text
    }

    func cancel() {
        found = nil
        completer.cancel()
    }
}

extension AppleMapsPlaceFinder: @MainActor MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        found?(completer.results.map { PlaceSuggestion(title: $0.title, subtitle: $0.subtitle) })
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        found?([])
    }
}

#if DEBUG
/// Made-up places for sample runs, so nothing is asked of Apple Maps.
@MainActor
final class SamplePlaceFinder: PlaceFinder {
    static let places = [
        PlaceSuggestion(title: "Bluebird Bakery", subtitle: "412 SE Oak St, Portland, OR 97214"),
        PlaceSuggestion(title: "Bluebell Park", subtitle: "1800 NE Elm Ave, Portland, OR 97212"),
        PlaceSuggestion(title: "Bright Smiles Dental", subtitle: "220 SW Main St, Portland, OR 97204"),
        PlaceSuggestion(title: "City Library", subtitle: "801 SW Tenth Ave, Portland, OR 97205"),
        PlaceSuggestion(title: "Dog Mountain Trailhead", subtitle: "WA-14, Stevenson, WA 98648"),
        PlaceSuggestion(title: "Good Puppy School", subtitle: "2025 NE Birch St, Portland, OR 97211"),
        PlaceSuggestion(title: "Happy Tails Veterinary", subtitle: "4000 N Maple Ave, Portland, OR 97227"),
        PlaceSuggestion(title: "Mt. Hood Lodge", subtitle: "27500 E Timberline Rd, Government Camp, OR 97028"),
        PlaceSuggestion(title: "Sunrise Yoga", subtitle: "915 SE Pine St, Portland, OR 97214"),
        PlaceSuggestion(title: "123 Main Street", subtitle: "Portland, OR 97204"),
    ]

    private var latest = 0

    func find(_ text: String, found: @escaping @MainActor ([PlaceSuggestion]) -> Void) {
        latest += 1
        let request = latest
        let words = text.lowercased().split(separator: " ")
        let matches = Self.places.filter { place in words.allSatisfy { place.text.lowercased().contains($0) } }
        // A moment later, as if from a server.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            if request == latest { found(Array(matches.prefix(5))) }
        }
    }

    func cancel() { latest += 1 }
}
#endif

/// What an event's location field suggests as it's typed: places for the latest text, from Apple Maps (or made-up
/// places in sample runs), or nothing when Settings ▸ Privacy says not to look.
@MainActor
@Observable
final class PlaceSearch {
    private(set) var suggestions: [PlaceSuggestion] = []
    @ObservationIgnored private let finder: (any PlaceFinder)?
    @ObservationIgnored private var latest = ""

    init(finder: (any PlaceFinder)? = PlaceSearch.makeFinder()) {
        self.finder = finder
    }

    static func makeFinder() -> (any PlaceFinder)? {
        guard PrivacySettings.shared.suggestsPlaces else { return nil }
        #if DEBUG
        if DebugLaunchOptions.usesSampleAccounts { return SamplePlaceFinder() }
        #endif
        return AppleMapsPlaceFinder()
    }

    var isAvailable: Bool { finder != nil }

    /// Looks for places matching what's typed (from two letters on).
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        latest = trimmed
        guard let finder, trimmed.count >= 2 else {
            clear()
            return
        }
        finder.find(trimmed) { [weak self] places in
            guard let self, self.latest == trimmed else { return }
            self.suggestions = places
        }
    }

    func clear() {
        latest = ""
        suggestions = []
        finder?.cancel()
    }
}

/// An event's location, with places from Apple Maps suggested under it as it's typed: click one (or pick it with the
/// arrow keys and Return) for its name and address.
struct LocationField: View {
    @Binding var location: String
    @State private var search = PlaceSearch()
    @State private var highlighted: Int?
    @State private var chosen: String?
    @FocusState private var focused: Bool

    private var shown: [PlaceSuggestion] { Array(search.suggestions.prefix(5)) }

    var body: some View {
        TextField("Add location", text: $location)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onChange(of: location) {
                guard focused, location != chosen else { return }
                chosen = nil
                highlighted = nil
                search.search(location)
            }
            .onChange(of: focused) {
                if !focused { search.clear() }
            }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.return) {
                guard let highlighted, shown.indices.contains(highlighted) else { return .ignored }
                choose(shown[highlighted])
                return .handled
            }
            .onKeyPress(.escape) {
                guard !shown.isEmpty else { return .ignored }
                search.clear()
                return .handled
            }
            .overlay(alignment: .topLeading) {
                if focused, !shown.isEmpty { suggestionList.padding(.top, 28) }
            }
            #if DEBUG
            // `-PMLocationSearch blue` types that into the location and shows what's suggested.
            .onAppear {
                if let text = UserDefaults.standard.string(forKey: "PMLocationSearch") {
                    focused = true
                    location = text
                    search.search(text)
                }
            }
            #endif
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, place in
                Button { choose(place) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill").font(.system(size: 17)).foregroundStyle(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.title).font(.pm(13, .medium)).foregroundStyle(Theme.textPrimary)
                            if !place.subtitle.isEmpty {
                                Text(place.subtitle).font(.pm(11.5)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(highlighted == index ? Theme.hover : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
            Text("Places from Apple Maps")
                .font(.pm(10.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceRaised))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let next = (highlighted ?? (step > 0 ? -1 : shown.count)) + step
        highlighted = min(max(next, 0), shown.count - 1)
        return .handled
    }

    private func choose(_ place: PlaceSuggestion) {
        chosen = place.text
        location = place.text
        highlighted = nil
        search.clear()
    }
}
