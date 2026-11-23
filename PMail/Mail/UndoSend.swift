import Foundation

/// How long a message waits before it goes, and a calendar change before it's made, so Undo can still stop it
/// (Settings ▸ Mail ▸ Undo Send).
enum UndoSend {
    static let key = "UndoSendSeconds"
    /// The pauses offered, in seconds.
    static let choices = [1, 3, 5, 10]
    static let standard = 3

    /// The pause chosen, in seconds.
    static var seconds: TimeInterval { TimeInterval(choice(UserDefaults.standard.integer(forKey: key))) }

    /// The choice a stored pause comes to: itself when it's offered, else the nearest that is (the 20 and 30 seconds
    /// once offered come to 10).
    static func choice(_ stored: Int) -> Int {
        choices.min { abs($0 - stored) < abs($1 - stored) } ?? standard
    }

    /// Brings a pause chosen from the earlier choices to one offered now, so Settings shows it.
    static func settleChoice(in defaults: UserDefaults = .standard) {
        let stored = defaults.integer(forKey: key)
        if !choices.contains(stored) { defaults.set(choice(stored), forKey: key) }
    }
}
