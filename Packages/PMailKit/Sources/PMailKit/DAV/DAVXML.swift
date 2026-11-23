import Foundation

/// The XML namespaces WebDAV, CalDAV and CardDAV servers use.
enum DAVNamespace {
    static let dav = "DAV:"
    static let calDAV = "urn:ietf:params:xml:ns:caldav"
    static let cardDAV = "urn:ietf:params:xml:ns:carddav"
    /// Calendar colors and order, as iCloud and many other servers keep them.
    static let appleICal = "http://apple.com/ns/ical/"
    /// getctag and the shared and subscribed calendar markers.
    static let calendarServer = "http://calendarserver.org/ns/"

    /// The prefix request bodies use for each namespace.
    static let prefixes: [(namespace: String, prefix: String)] = [
        (dav, "d"), (calDAV, "c"), (cardDAV, "card"), (appleICal, "ic"), (calendarServer, "cs"),
    ]
}

/// A WebDAV property name: its namespace and local name.
struct DAVProperty: Sendable, Hashable {
    var namespace: String
    var name: String

    init(_ namespace: String, _ name: String) {
        self.namespace = namespace
        self.name = name
    }

    static let currentUserPrincipal = DAVProperty(DAVNamespace.dav, "current-user-principal")
    static let resourceType = DAVProperty(DAVNamespace.dav, "resourcetype")
    static let displayName = DAVProperty(DAVNamespace.dav, "displayname")
    static let getETag = DAVProperty(DAVNamespace.dav, "getetag")
    static let currentUserPrivilegeSet = DAVProperty(DAVNamespace.dav, "current-user-privilege-set")
    static let calendarHomeSet = DAVProperty(DAVNamespace.calDAV, "calendar-home-set")
    static let supportedCalendarComponentSet = DAVProperty(DAVNamespace.calDAV, "supported-calendar-component-set")
    static let calendarData = DAVProperty(DAVNamespace.calDAV, "calendar-data")
    static let addressbookHomeSet = DAVProperty(DAVNamespace.cardDAV, "addressbook-home-set")
    static let addressData = DAVProperty(DAVNamespace.cardDAV, "address-data")
    static let calendarColor = DAVProperty(DAVNamespace.appleICal, "calendar-color")
    static let calendarOrder = DAVProperty(DAVNamespace.appleICal, "calendar-order")
    static let calendarDescription = DAVProperty(DAVNamespace.calDAV, "calendar-description")
    static let getCTag = DAVProperty(DAVNamespace.calendarServer, "getctag")
}

/// An element of a WebDAV answer, with its namespace, attributes, text and children.
struct DAVElement: Sendable, Hashable {
    var namespace: String
    var name: String
    var attributes: [String: String]
    var text: String
    var children: [DAVElement]

    func child(_ namespace: String, _ name: String) -> DAVElement? {
        children.first { $0.namespace == namespace && $0.name == name }
    }

    func children(_ namespace: String, _ name: String) -> [DAVElement] {
        children.filter { $0.namespace == namespace && $0.name == name }
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The DAV:href elements inside, as text.
    var hrefs: [String] {
        children(DAVNamespace.dav, "href").map(\.trimmedText).filter { !$0.isEmpty }
    }
}

/// One resource in a multistatus answer: its href, and the properties the server found for it.
struct DAVResponse: Sendable {
    var href: String
    /// The response's own status, for a resource that is gone or can't be read.
    var status: Int?
    /// The properties that came with a 2xx status.
    var properties: [DAVElement]

    func property(_ property: DAVProperty) -> DAVElement? {
        properties.first { $0.namespace == property.namespace && $0.name == property.name }
    }

    /// Whether the resource itself came back fine (no status of its own, or a 2xx one).
    var isAvailable: Bool { status.map { (200..<300).contains($0) } ?? true }
}

/// A WebDAV multistatus answer (RFC 4918 section 13), with the address that sent it so its hrefs can be resolved.
struct DAVMultistatus: Sendable {
    var responses: [DAVResponse]
    /// The address that answered (after redirects): hrefs are relative to it.
    var baseURL: URL

    init(responses: [DAVResponse], baseURL: URL) {
        self.responses = responses
        self.baseURL = baseURL
    }

    /// Reads a multistatus body. An empty body is an empty answer; anything that isn't a multistatus is an error.
    init(parsing data: Data, baseURL: URL) throws {
        self.baseURL = baseURL
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            responses = []
            return
        }
        let builder = DAVTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root, root.namespace == DAVNamespace.dav, root.name == "multistatus" else {
            throw PMailError.protocolError("the server’s answer wasn’t a WebDAV multistatus")
        }
        responses = root.children(DAVNamespace.dav, "response").compactMap { response in
            guard let href = response.child(DAVNamespace.dav, "href")?.trimmedText, !href.isEmpty else { return nil }
            let status = response.child(DAVNamespace.dav, "status").flatMap { Self.statusCode($0.trimmedText) }
            let properties = response.children(DAVNamespace.dav, "propstat").filter { propstat in
                let status = propstat.child(DAVNamespace.dav, "status").flatMap { Self.statusCode($0.trimmedText) }
                return status.map { (200..<300).contains($0) } ?? true
            }.flatMap { $0.child(DAVNamespace.dav, "prop")?.children ?? [] }
            return DAVResponse(href: href, status: status, properties: properties)
        }
    }

    /// The full address an href names, resolved against the address that answered.
    func url(for href: String) -> URL? {
        if let url = URL(string: href, relativeTo: baseURL) { return url.absoluteURL }
        // Some servers leave spaces and other characters unencoded.
        let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        return encoded.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
    }

    /// The first href any response gives for a property (like current-user-principal), resolved.
    func firstURL(of property: DAVProperty) -> URL? {
        for response in responses {
            if let href = response.property(property)?.hrefs.first, let url = url(for: href) { return url }
        }
        return nil
    }

    /// Reads "HTTP/1.1 200 OK" as 200.
    static func statusCode(_ line: String) -> Int? {
        line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }
}

/// Builds a tree of `DAVElement`s from XMLParser's events.
private final class DAVTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [DAVElement] = []
    private(set) var root: DAVElement?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        stack.append(DAVElement(namespace: namespaceURI ?? "", name: elementName, attributes: attributeDict, text: "", children: []))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty { root = finished } else { stack[stack.count - 1].children.append(finished) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

/// The XML bodies of WebDAV, CalDAV and CardDAV requests.
enum DAVRequestBody {
    static func propfind(_ properties: [DAVProperty]) -> Data {
        document("d:propfind", properties: properties, inner: "")
    }

    /// A CalDAV calendar-query for every VEVENT with an occurrence in a window (RFC 4791 section 7.8).
    static func calendarQuery(from start: Date, to end: Date) -> Data {
        let range = "<c:time-range start=\"\(utc(start))\" end=\"\(utc(end))\"/>"
        let events = "<c:comp-filter name=\"VEVENT\">\(range)</c:comp-filter>"
        let filter = "<c:filter><c:comp-filter name=\"VCALENDAR\">\(events)</c:comp-filter></c:filter>"
        return document("c:calendar-query", properties: [.getETag, .calendarData], inner: filter)
    }

    /// A CalDAV calendar-query for the event with an iCalendar UID (RFC 4791 section 9.7.5).
    static func calendarQuery(uid: String) -> Data {
        let match = "<c:prop-filter name=\"UID\"><c:text-match collation=\"i;octet\">\(escape(uid))</c:text-match></c:prop-filter>"
        let events = "<c:comp-filter name=\"VEVENT\">\(match)</c:comp-filter>"
        let filter = "<c:filter><c:comp-filter name=\"VCALENDAR\">\(events)</c:comp-filter></c:filter>"
        return document("c:calendar-query", properties: [.getETag, .calendarData], inner: filter)
    }

    /// A PROPPATCH setting properties to text values.
    static func propertyUpdate(_ values: [(DAVProperty, String)]) -> Data {
        let declarations = DAVNamespace.prefixes.map { " xmlns:\($0.prefix)=\"\($0.namespace)\"" }.joined()
        let props = values.map { property, value -> String in
            let name = DAVNamespace.prefixes.first { $0.namespace == property.namespace }.map { "\($0.prefix):\(property.name)" } ?? property.name
            return "<\(name)>\(escape(value))</\(name)>"
        }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<d:propertyupdate\(declarations)><d:set><d:prop>\(props)</d:prop></d:set></d:propertyupdate>"
        return Data(xml.utf8)
    }

    static func calendarMultiget(_ hrefs: [String]) -> Data {
        document("c:calendar-multiget", properties: [.getETag, .calendarData], inner: hrefList(hrefs))
    }

    static func addressbookMultiget(_ hrefs: [String]) -> Data {
        document("card:addressbook-multiget", properties: [.getETag, .addressData], inner: hrefList(hrefs))
    }

    private static func hrefList(_ hrefs: [String]) -> String {
        hrefs.map { "<d:href>\(escape($0))</d:href>" }.joined()
    }

    /// Text made safe for XML.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func document(_ root: String, properties: [DAVProperty], inner: String) -> Data {
        let declarations = DAVNamespace.prefixes.map { " xmlns:\($0.prefix)=\"\($0.namespace)\"" }.joined()
        let prop = properties.map { property -> String in
            let prefix = DAVNamespace.prefixes.first { $0.namespace == property.namespace }?.prefix
            return prefix.map { "<\($0):\(property.name)/>" } ?? "<\(property.name) xmlns=\"\(escape(property.namespace))\"/>"
        }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<\(root)\(declarations)><d:prop>\(prop)</d:prop>\(inner)</\(root)>"
        return Data(xml.utf8)
    }

    private static func utc(_ date: Date) -> String {
        ICalendarDateTime(wall: ICalendarZone.utc.wall(from: date), form: .utc).text
    }
}
