import Foundation

/// The video meeting new events on one account's calendars are offered (Settings ▸ Calendar ▸ Video meetings, kept
/// with the account's calendar preferences): the account's own (Meet on Google, Teams on Microsoft work or school
/// accounts, a FaceTime link on iCloud), Zoom on any account, or none. A Zoom meeting is one the person schedules in
/// Zoom and pastes in, or their Personal Room.
public struct VideoMeetingChoice: Codable, Equatable, Sendable {
    public enum Option: String, Codable, Sendable, Hashable {
        case meet, teams, faceTime, zoom
        /// No video meeting is offered.
        case noMeeting

        /// The account's own meeting as an option, if it has one.
        public init?(own kind: Conference.Kind?) {
            switch kind {
            case .meet?: self = .meet
            case .teams?: self = .teams
            case .faceTime?: self = .faceTime
            default: return nil
            }
        }

        /// The meeting the calendar makes by itself when the event is saved: Meet and Teams.
        public var madeByCalendar: Conference.Kind? {
            switch self {
            case .meet: .meet
            case .teams: .teams
            default: nil
            }
        }

        public var title: String {
            switch self {
            case .meet: Conference.Kind.meet.displayName
            case .teams: Conference.Kind.teams.displayName
            case .faceTime: Conference.Kind.faceTime.displayName
            case .zoom: Conference.Kind.zoom.displayName
            case .noMeeting: "None"
            }
        }
    }

    /// Zoom's page for scheduling a meeting, which Add Zoom Meeting opens.
    public static let zoomSchedulePage = URL(string: "https://zoom.us/meeting/schedule")!

    /// What's chosen; nil until something is.
    public var chosen: Option?
    /// Add Zoom Meeting puts the Personal Room on the event at once, instead of opening Zoom to schedule one.
    public var alwaysUsesPersonalRoom: Bool
    /// The Personal Room's link.
    public var personalRoom: String

    public init(_ chosen: Option? = nil, alwaysUsesPersonalRoom: Bool = false, personalRoom: String = "") {
        self.chosen = chosen
        self.alwaysUsesPersonalRoom = alwaysUsesPersonalRoom
        self.personalRoom = personalRoom
    }

    /// What an account can choose: its own meeting (`own`: Meet on Google, Teams on Microsoft, FaceTime on iCloud, where
    /// it has one), Zoom or none.
    public static func options(own: Conference.Kind?) -> [Option] {
        (Option(own: own).map { [$0] } ?? []) + [.zoom, .noMeeting]
    }

    /// The account's option: what's chosen, if the account can have it; otherwise (and until something is chosen) its
    /// own meeting, or none where it has none.
    public func option(own: Conference.Kind?) -> Option {
        if let chosen, Self.options(own: own).contains(chosen) { return chosen }
        return Option(own: own) ?? .noMeeting
    }

    /// What a new event on one of the account's calendars is offered: the account's option, except that Meet and
    /// Teams aren't offered on a calendar that can't make them (`calendarsOwn`, the meeting it makes by itself).
    public func offer(calendarsOwn: Conference.Kind?, accountsOwn: Conference.Kind?) -> Option {
        let option = option(own: accountsOwn)
        if let kind = option.madeByCalendar, kind != calendarsOwn { return .noMeeting }
        return option
    }

    /// The Personal Room Add Zoom Meeting puts on an event at once: when that's chosen and its link is a Zoom link.
    public var personalRoomMeeting: Conference? {
        chosen == .zoom && alwaysUsesPersonalRoom ? ConferenceDetector.zoomMeeting(in: personalRoom) : nil
    }

    /// A Personal Room as typed or pasted: just its link, when that's in a whole invitation.
    public static func personalRoom(from text: String) -> String {
        ConferenceDetector.zoomMeeting(in: text)?.joinURL.absoluteString ?? text
    }
}
