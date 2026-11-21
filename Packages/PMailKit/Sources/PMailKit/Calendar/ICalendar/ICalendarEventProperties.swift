import Foundation

/// Reading and writing the VEVENT properties that carry people, answers, reminders, colors and status.
enum ICalendarEventProperties {
    /// The person an ORGANIZER or ATTENDEE line names: a `mailto:` address (or the EMAIL parameter, for servers that
    /// name people by URN), with CN as the name.
    static func address(of line: ICalendarLine) -> MailAddress? {
        var value = line.value.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("mailto:") {
            value = String(value.dropFirst(7))
        } else if let email = line.parameter("EMAIL") {
            value = email
        }
        value = (value.removingPercentEncoding ?? value).trimmingCharacters(in: .whitespaces)
        guard value.contains("@"), !value.contains(":"), !value.contains(" ") else { return nil }
        return MailAddress(name: line.parameter("CN").map(ICalendarParameter.decode), email: value)
    }

    /// Whether two addresses are the same mailbox. iCloud's me.com, mac.com and icloud.com addresses for one name
    /// are the same mailbox too, since invitations reach the person at any of them.
    static func isSameMailbox(_ first: String, _ second: String) -> Bool {
        normalizedMailbox(first) == normalizedMailbox(second)
    }

    private static func normalizedMailbox(_ email: String) -> String {
        let lowered = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard let at = lowered.lastIndex(of: "@") else { return lowered }
        let domain = lowered[lowered.index(after: at)...]
        if domain == "me.com" || domain == "mac.com" { return String(lowered[..<at]) + "@icloud.com" }
        return lowered
    }

    static func response(ofPartstat value: String?) -> AttendeeResponse {
        switch value?.uppercased() {
        case "ACCEPTED": .accepted
        case "DECLINED", "DELEGATED": .declined
        case "TENTATIVE": .tentative
        default: .needsAction
        }
    }

    static func partstat(_ response: AttendeeResponse) -> String {
        switch response {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .declined: "DECLINED"
        case .tentative: "TENTATIVE"
        }
    }

    static func isOptional(_ line: ICalendarLine) -> Bool {
        let role = line.parameter("ROLE")?.uppercased()
        return role == "OPT-PARTICIPANT" || role == "NON-PARTICIPANT"
    }

    static func attendee(from line: ICalendarLine, organizer: MailAddress?) -> Attendee? {
        guard let address = address(of: line) else { return nil }
        let isOrganizer = organizer.map { isSameMailbox($0.email, address.email) } ?? false
        return Attendee(address: address, response: response(ofPartstat: line.parameter("PARTSTAT")), isOptional: isOptional(line),
                        isOrganizer: isOrganizer)
    }

    static func status(of component: ICalendarComponent) -> CalendarEvent.Status {
        switch component.property("STATUS")?.value.trimmingCharacters(in: .whitespaces).uppercased() {
        case "TENTATIVE": .tentative
        case "CANCELLED": .cancelled
        default: .confirmed
        }
    }

    static func statusValue(_ status: CalendarEvent.Status) -> String {
        switch status {
        case .confirmed: "CONFIRMED"
        case .tentative: "TENTATIVE"
        case .cancelled: "CANCELLED"
        }
    }

    static func availability(of component: ICalendarComponent) -> EventAvailability {
        component.property("TRANSP")?.value.trimmingCharacters(in: .whitespaces).uppercased() == "TRANSPARENT" ? .free : .busy
    }

    // MARK: Reminders

    /// The minutes before the start a VALARM reminds, for the alarms PMail understands: pop-up or sound alarms
    /// timed from the event's start. Others (emails, alarms at a fixed time or from the end) are left alone.
    static func reminderMinutes(of alarm: ICalendarComponent) -> Int? {
        guard alarm.name == "VALARM" else { return nil }
        let action = alarm.property("ACTION")?.value.trimmingCharacters(in: .whitespaces).uppercased() ?? "DISPLAY"
        guard action == "DISPLAY" || action == "AUDIO", let trigger = alarm.property("TRIGGER") else { return nil }
        if trigger.parameter("VALUE")?.uppercased() == "DATE-TIME" || trigger.parameter("RELATED")?.uppercased() == "END" { return nil }
        guard let duration = ICalendarDuration(trigger.value) else { return nil }
        let before = -duration.approximateSeconds
        guard before >= 0, before <= 366 * 86_400 else { return nil }
        return Int(before / 60)
    }

    static func reminders(of component: ICalendarComponent) -> [Int] {
        Array(Set(component.components.compactMap(reminderMinutes))).sorted()
    }

    /// A new pop-up alarm some minutes before the start.
    static func alarm(minutesBefore minutes: Int) -> ICalendarComponent {
        ICalendarComponent(name: "VALARM", properties: [
            ICalendarLine("UID", value: UUID().uuidString),
            ICalendarLine("ACTION", value: "DISPLAY"),
            .text("DESCRIPTION", "Reminder"),
            ICalendarLine("TRIGGER", value: triggerText(minutesBefore: minutes)),
        ])
    }

    /// "-PT15M", "-PT1H30M", "-P1D", "-P1W", or "PT0S" for at the start.
    static func triggerText(minutesBefore minutes: Int) -> String {
        guard minutes > 0 else { return "PT0S" }
        if minutes % 10_080 == 0 { return "-P\(minutes / 10_080)W" }
        if minutes % 1440 == 0 { return "-P\(minutes / 1440)D" }
        var text = "-P"
        if minutes >= 1440 { text += "\(minutes / 1440)D" }
        text += "T"
        let rest = minutes % 1440
        if rest / 60 > 0 { text += "\(rest / 60)H" }
        if rest % 60 > 0 { text += "\(rest % 60)M" }
        return text
    }
}

/// Event and calendar colors. RFC 7986 has COLOR hold a CSS color name, though some programs write "#RRGGBB" there;
/// CalDAV calendar colors come as "#RRGGBB" or "#RRGGBBAA".
enum ICalendarColor {
    /// "#RRGGBB" for a CSS color name or a hex color, or nil for something else.
    static func hex(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return normalizedHex(trimmed) }
        return cssColors[trimmed.lowercased()]
    }

    /// "#RRGGBB" from "#RGB", "#RRGGBB" or "#RRGGBBAA" (the alpha is dropped), in capitals.
    static func normalizedHex(_ text: String) -> String? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII) else { return nil }
        switch digits.count {
        case 3: return "#" + digits.map { "\($0)\($0)" }.joined().uppercased()
        case 6, 8: return "#" + digits.prefix(6).uppercased()
        default: return nil
        }
    }

    /// What to write in COLOR for a color: its CSS name when it has one exactly, else "#RRGGBB".
    static func value(forHex hex: String) -> String {
        let normalized = normalizedHex(hex) ?? hex
        return cssNamesByHex[normalized] ?? normalized
    }

    private static let cssNamesByHex: [String: String] = {
        var names: [String: String] = [:]
        for (name, hex) in cssColors.sorted(by: { $0.key < $1.key }) where names[hex] == nil { names[hex] = name }
        return names
    }()

    /// The CSS color names.
    static let cssColors: [String: String] = [
        "aliceblue": "#F0F8FF", "antiquewhite": "#FAEBD7", "aqua": "#00FFFF", "aquamarine": "#7FFFD4", "azure": "#F0FFFF",
        "beige": "#F5F5DC", "bisque": "#FFE4C4", "black": "#000000", "blanchedalmond": "#FFEBCD", "blue": "#0000FF",
        "blueviolet": "#8A2BE2", "brown": "#A52A2A", "burlywood": "#DEB887", "cadetblue": "#5F9EA0", "chartreuse": "#7FFF00",
        "chocolate": "#D2691E", "coral": "#FF7F50", "cornflowerblue": "#6495ED", "cornsilk": "#FFF8DC", "crimson": "#DC143C",
        "cyan": "#00FFFF", "darkblue": "#00008B", "darkcyan": "#008B8B", "darkgoldenrod": "#B8860B", "darkgray": "#A9A9A9",
        "darkgreen": "#006400", "darkgrey": "#A9A9A9", "darkkhaki": "#BDB76B", "darkmagenta": "#8B008B",
        "darkolivegreen": "#556B2F", "darkorange": "#FF8C00", "darkorchid": "#9932CC", "darkred": "#8B0000",
        "darksalmon": "#E9967A", "darkseagreen": "#8FBC8F", "darkslateblue": "#483D8B", "darkslategray": "#2F4F4F",
        "darkslategrey": "#2F4F4F", "darkturquoise": "#00CED1", "darkviolet": "#9400D3", "deeppink": "#FF1493",
        "deepskyblue": "#00BFFF", "dimgray": "#696969", "dimgrey": "#696969", "dodgerblue": "#1E90FF", "firebrick": "#B22222",
        "floralwhite": "#FFFAF0", "forestgreen": "#228B22", "fuchsia": "#FF00FF", "gainsboro": "#DCDCDC", "ghostwhite": "#F8F8FF",
        "gold": "#FFD700", "goldenrod": "#DAA520", "gray": "#808080", "green": "#008000", "greenyellow": "#ADFF2F",
        "grey": "#808080", "honeydew": "#F0FFF0", "hotpink": "#FF69B4", "indianred": "#CD5C5C", "indigo": "#4B0082",
        "ivory": "#FFFFF0", "khaki": "#F0E68C", "lavender": "#E6E6FA", "lavenderblush": "#FFF0F5", "lawngreen": "#7CFC00",
        "lemonchiffon": "#FFFACD", "lightblue": "#ADD8E6", "lightcoral": "#F08080", "lightcyan": "#E0FFFF",
        "lightgoldenrodyellow": "#FAFAD2", "lightgray": "#D3D3D3", "lightgreen": "#90EE90", "lightgrey": "#D3D3D3",
        "lightpink": "#FFB6C1", "lightsalmon": "#FFA07A", "lightseagreen": "#20B2AA", "lightskyblue": "#87CEFA",
        "lightslategray": "#778899", "lightslategrey": "#778899", "lightsteelblue": "#B0C4DE", "lightyellow": "#FFFFE0",
        "lime": "#00FF00", "limegreen": "#32CD32", "linen": "#FAF0E6", "magenta": "#FF00FF", "maroon": "#800000",
        "mediumaquamarine": "#66CDAA", "mediumblue": "#0000CD", "mediumorchid": "#BA55D3", "mediumpurple": "#9370DB",
        "mediumseagreen": "#3CB371", "mediumslateblue": "#7B68EE", "mediumspringgreen": "#00FA9A",
        "mediumturquoise": "#48D1CC", "mediumvioletred": "#C71585", "midnightblue": "#191970", "mintcream": "#F5FFFA",
        "mistyrose": "#FFE4E1", "moccasin": "#FFE4B5", "navajowhite": "#FFDEAD", "navy": "#000080", "oldlace": "#FDF5E6",
        "olive": "#808000", "olivedrab": "#6B8E23", "orange": "#FFA500", "orangered": "#FF4500", "orchid": "#DA70D6",
        "palegoldenrod": "#EEE8AA", "palegreen": "#98FB98", "paleturquoise": "#AFEEEE", "palevioletred": "#DB7093",
        "papayawhip": "#FFEFD5", "peachpuff": "#FFDAB9", "peru": "#CD853F", "pink": "#FFC0CB", "plum": "#DDA0DD",
        "powderblue": "#B0E0E6", "purple": "#800080", "rebeccapurple": "#663399", "red": "#FF0000", "rosybrown": "#BC8F8F",
        "royalblue": "#4169E1", "saddlebrown": "#8B4513", "salmon": "#FA8072", "sandybrown": "#F4A460", "seagreen": "#2E8B57",
        "seashell": "#FFF5EE", "sienna": "#A0522D", "silver": "#C0C0C0", "skyblue": "#87CEEB", "slateblue": "#6A5ACD",
        "slategray": "#708090", "slategrey": "#708090", "snow": "#FFFAFA", "springgreen": "#00FF7F", "steelblue": "#4682B4",
        "tan": "#D2B48C", "teal": "#008080", "thistle": "#D8BFD8", "tomato": "#FF6347", "turquoise": "#40E0D0",
        "violet": "#EE82EE", "wheat": "#F5DEB3", "white": "#FFFFFF", "whitesmoke": "#F5F5F5", "yellow": "#FFFF00",
        "yellowgreen": "#9ACD32",
    ]
}
