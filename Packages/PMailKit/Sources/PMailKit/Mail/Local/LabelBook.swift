import Foundation

/// An account's labels kept on this Mac: their names and colors, and, for a server that can't keep labels itself,
/// which messages have them. Filled in by the labels work.
public actor LabelBook {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }
}
