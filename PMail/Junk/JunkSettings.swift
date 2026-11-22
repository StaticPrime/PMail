import Foundation
import Observation
import PMailKit

/// Settings ▸ Junk Mail: how junk and mail from blocked senders are handled (the same for every account), and PMail's
/// junk filter, which learns from every account. Kept in the app's settings (the sample settings in sample runs), the
/// filter in its own file.
@Observable
final class JunkSettings {
    /// The app's. Sample runs swap in their own before anything reads it.
    static var shared = JunkSettings(store: .standard, filterFile: AppDelegate.supportFolder.appendingPathComponent("Junk Filter.json"))

    private static let key = "JunkMail"

    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored let filter: JunkFilter

    var policy: JunkPolicy {
        didSet { store.set(try? JSONEncoder().encode(policy), forKey: Self.key) }
    }

    init(store: UserDefaults, filterFile: URL) {
        self.store = store
        filter = JunkFilter(file: filterFile)
        policy = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(JunkPolicy.self, from: $0) } ?? JunkPolicy()
    }
}
