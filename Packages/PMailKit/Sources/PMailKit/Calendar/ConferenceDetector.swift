import Foundation

/// Finds a video meeting's link in an event's location, description or URL, for events that don't carry one as
/// structured data (a FaceTime link pasted in, an invitation from another app).
public enum ConferenceDetector {
    /// The first meeting link in the texts, in order.
    public static func detect(in texts: [String?]) -> Conference? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for url in links(in: text) {
                if let kind = kind(of: url) { return Conference(kind: kind, joinURL: url, meetingCode: code(in: url, kind: kind)) }
            }
        }
        return nil
    }

    /// What kind of meeting a link joins, or nil for a link that isn't a meeting.
    public static func kind(of url: URL) -> Conference.Kind? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "facetime" || scheme == "facetime-audio" { return .faceTime }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return nil }
        if host == "facetime.apple.com" { return .faceTime }
        if host == "meet.google.com" { return .meet }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host.hasSuffix(".teams.microsoft.com") { return .teams }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return url.path.contains("/j/") || url.path.contains("/my/") ? .zoom : nil }
        if host.hasSuffix(".webex.com") { return .webex }
        return nil
    }

    /// The Zoom meeting in pasted text: a whole invitation as Zoom copies it ("Join Zoom Meeting https://…/j/…", with
    /// its meeting ID, passcode and numbers to dial), or just the meeting's link. Nil when there's no Zoom meeting link
    /// in it (the invitation's "Find your local number" page isn't one).
    public static func zoomMeeting(in text: String) -> Conference? {
        guard let url = links(in: text).first(where: { kind(of: $0) == .zoom }) else { return nil }
        return Conference(kind: .zoom, joinURL: url, meetingCode: code(in: url, kind: .zoom))
    }

    /// Whether a link is a FaceTime link someone made in the FaceTime app.
    public static func isFaceTimeLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kind(of: url) == .faceTime
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var urls = detector.matches(in: text, range: range).compactMap(\.url)
        // NSDataDetector doesn't know facetime: links.
        if let regex = try? NSRegularExpression(pattern: "facetime(-audio)?:[^\\s<>\"]+", options: .caseInsensitive) {
            urls += regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).flatMap { URL(string: String(text[$0])) } }
        }
        return urls
    }

    private static func code(in url: URL, kind: Conference.Kind) -> String? {
        switch kind {
        case .meet:
            let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return code.isEmpty ? nil : code
        case .zoom:
            return url.pathComponents.last.flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
        default:
            return nil
        }
    }
}
