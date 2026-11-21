import Foundation

/// A BEGIN…END block of an iCalendar file (VCALENDAR, VEVENT, VTIMEZONE, VALARM…) or a vCard file (VCARD), with its
/// properties and the blocks inside it, in the order the file had them.
struct ICalendarComponent: Sendable, Hashable {
    /// The component's name, in capitals ("VEVENT").
    var name: String
    var properties: [ICalendarLine]
    var components: [ICalendarComponent]

    init(name: String, properties: [ICalendarLine] = [], components: [ICalendarComponent] = []) {
        self.name = name.uppercased()
        self.properties = properties
        self.components = components
    }

    /// The top-level components in a file (usually one VCALENDAR, or a run of VCARDs). Never fails: lines that make
    /// no sense are skipped, stray ENDs are ignored, and blocks a cut-off file never closed keep what arrived.
    static func parse(_ data: Data) -> [ICalendarComponent] {
        var stack: [ICalendarComponent] = []
        var roots: [ICalendarComponent] = []
        func close() {
            guard let finished = stack.popLast() else { return }
            if stack.isEmpty { roots.append(finished) } else { stack[stack.count - 1].components.append(finished) }
        }
        for text in ICalendarFolding.unfoldedLines(data) {
            guard let line = ICalendarLine(parsing: text) else { continue }
            switch line.name {
            case "BEGIN":
                stack.append(ICalendarComponent(name: line.value.trimmingCharacters(in: .whitespaces)))
            case "END":
                let name = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                guard let match = stack.lastIndex(where: { $0.name == name }) else { continue }
                while stack.count > match { close() }
            default:
                if !stack.isEmpty { stack[stack.count - 1].properties.append(line) }
            }
        }
        while !stack.isEmpty { close() }
        return roots
    }

    static func parse(_ text: String) -> [ICalendarComponent] {
        parse(Data(text.utf8))
    }

    /// The component as file text: folded lines ending in CRLF.
    var serialized: String {
        var text = ""
        appendLines(to: &text)
        return text
    }

    private func appendLines(to text: inout String) {
        text += "BEGIN:\(name)\r\n"
        for property in properties {
            text += ICalendarFolding.fold(property.serialized)
            text += "\r\n"
        }
        for component in components { component.appendLines(to: &text) }
        text += "END:\(name)\r\n"
    }

    /// The first property with a name.
    func property(_ name: String) -> ICalendarLine? {
        properties.first { $0.name == name }
    }

    /// Every property with a name, in order.
    func properties(_ name: String) -> [ICalendarLine] {
        properties.filter { $0.name == name }
    }

    mutating func removeProperties(_ name: String) {
        properties.removeAll { $0.name == name }
    }

    /// Puts a line in place of the first property with its name (dropping any others with that name), or adds it at
    /// the end.
    mutating func setProperty(_ line: ICalendarLine) {
        guard let index = properties.firstIndex(where: { $0.name == line.name }) else {
            properties.append(line)
            return
        }
        properties[index] = line
        var seen = false
        properties.removeAll { property in
            guard property.name == line.name else { return false }
            defer { seen = true }
            return seen
        }
    }

    /// Sets a text property, or removes it when the text is empty.
    mutating func setText(_ name: String, _ text: String?) {
        if let text, !text.isEmpty {
            setProperty(.text(name, text))
        } else {
            removeProperties(name)
        }
    }

    /// The UID property's value.
    var uid: String? {
        property("UID").map { $0.text.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
