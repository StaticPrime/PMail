import Foundation
import Testing
@testable import PMailKit

@Suite struct CardDAVTests {
    static let jamie = VCardTests.crlf("""
    BEGIN:VCARD
    VERSION:3.0
    N:Rivera;Jamie;;;
    FN:Jamie Rivera
    TITLE:Designer
    EMAIL;type=INTERNET;type=WORK:jamie@example.com
    X-SOCIALPROFILE;type=example:https://social.example/jamie
    CATEGORIES:Friends
    UID:jamie-uid
    END:VCARD
    """)

    static let sam = VCardTests.crlf("""
    BEGIN:VCARD
    VERSION:3.0
    N:Lee;Sam;;;
    FN:Sam Lee
    UID:sam-uid
    END:VCARD
    """)

    static let family = VCardTests.crlf("""
    BEGIN:VCARD
    VERSION:3.0
    N:Family
    FN:Family
    X-ADDRESSBOOKSERVER-KIND:group
    X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:jamie-uid
    UID:family-uid
    END:VCARD
    """)

    static let book = "/123/carddavhome/card/"
    /// The book's path the way the stub server matches it (URL.path drops the trailing slash).
    static let bookPath = "/123/carddavhome/card"

    static func server() -> StubTransport {
        let transport = StubTransport()
        transport.on("PROPFIND", "/") { _ in
            DAVStub.multistatus(DAVStub.response("/", "<d:current-user-principal><d:href>/123/principal/</d:href></d:current-user-principal>"))
        }
        transport.on("PROPFIND", "/123/principal") { _ in
            DAVStub.multistatus(DAVStub.response("/123/principal/",
                "<card:addressbook-home-set><d:href>https://p57-contacts.example.com/123/carddavhome/</d:href></card:addressbook-home-set>"))
        }
        transport.on("PROPFIND", "/123/carddavhome") { _ in
            DAVStub.multistatus(
                DAVStub.response("/123/carddavhome/", "<d:resourcetype><d:collection/></d:resourcetype>"),
                DAVStub.response(book, "<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>Card</d:displayname>")
            )
        }
        transport.on("PROPFIND", bookPath) { _ in
            DAVStub.multistatus(
                DAVStub.response(book, "<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>"),
                DAVStub.response(book + "jamie.vcf", "<d:resourcetype/><d:getetag>\"j1\"</d:getetag>"),
                DAVStub.response(book + "sam.vcf", "<d:resourcetype/><d:getetag>\"s1\"</d:getetag>"),
                DAVStub.response(book + "family.vcf", "<d:resourcetype/><d:getetag>\"g1\"</d:getetag>")
            )
        }
        transport.on("REPORT", bookPath) { _ in
            DAVStub.multistatus(
                DAVStub.response(book + "jamie.vcf", DAVStub.addressData(jamie, etag: "\"j1\"")),
                DAVStub.response(book + "sam.vcf", DAVStub.addressData(sam, etag: "\"s1\"")),
                DAVStub.response(book + "family.vcf", DAVStub.addressData(family, etag: "\"g1\""))
            )
        }
        transport.on("PUT", bookPath) { _ in DAVStub.saved(etag: "\"new\"") }
        transport.on("DELETE", bookPath) { _ in .status(204) }
        return transport
    }

    static func service(_ transport: StubTransport) throws -> CardDAVContactsService {
        CardDAVContactsService(serverURL: try #require(URL(string: "https://contacts.example.com/")), credential: DAVStub.password,
                               transport: transport)
    }

    @Test func contactsLoadWithGroupsAsLabels() async throws {
        let transport = Self.server()
        let service = try Self.service(transport)
        let contacts = try await service.loadContacts()
        try #require(contacts.count == 2)
        #expect(contacts.map(\.displayName) == ["Sam Lee", "Jamie Rivera"])
        #expect(contacts.map(\.labels) == [[], ["Friends", "Family"]])
        #expect(contacts.map(\.id) == [Self.book + "sam.vcf", Self.book + "jamie.vcf"])
        #expect(contacts.map(\.etag) == ["\"s1\"", "\"j1\""])
        #expect(contacts[1].emails == [LabeledValue(label: "work", value: "jamie@example.com")])

        let report = try #require(transport.sent("REPORT", Self.bookPath).first)
        #expect(report.url?.host == "p57-contacts.example.com")
        #expect(report.bodyText.contains("<card:addressbook-multiget") && report.bodyText.contains("<card:address-data/>"))
        #expect(report.bodyText.contains("<d:href>\(Self.book)jamie.vcf</d:href>"))

        // Nothing changed, so nothing is downloaded again.
        _ = try await service.loadContacts()
        #expect(transport.sent("REPORT", Self.bookPath).count == 1)
    }

    @Test func largeAddressBooksAreFetchedInBatches() async throws {
        let transport = Self.server()
        let listing = (0..<150).map { DAVStub.response(Self.book + "c\($0).vcf", "<d:getetag>\"\($0)\"</d:getetag>") }
        transport.on("PROPFIND", Self.bookPath) { _ in
            DAVStub.multistatus(listing.joined())
        }
        transport.on("REPORT", Self.bookPath) { request in
            let hrefs = request.bodyText.components(separatedBy: "<d:href>").dropFirst()
                .compactMap { $0.components(separatedBy: "</d:href>").first }
            return DAVStub.multistatus(hrefs.map { href in
                DAVStub.response(href, DAVStub.addressData("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:\(href)\r\nEND:VCARD\r\n", etag: "\"x\""))
            }.joined())
        }
        let contacts = try await Self.service(transport).loadContacts()
        #expect(contacts.count == 150)
        #expect(transport.sent("REPORT", Self.bookPath).count == 2)
    }

    @Test func newContactsJoinTheirGroups() async throws {
        let transport = Self.server()
        let service = try Self.service(transport)
        _ = try await service.loadContacts()
        let contact = Contact(givenName: "Robin", emails: [LabeledValue(label: "home", value: "robin@example.com")],
                              labels: ["Family", "Gym"], uid: "robin-uid")
        let saved = try await service.create(contact)
        #expect(saved.id == Self.book + "robin-uid.vcf" && saved.etag == "\"new\"" && saved.uid == "robin-uid")
        let put = try #require(transport.sent("PUT", Self.book + "robin-uid.vcf").first)
        #expect(DAVStub.header(put, "If-None-Match") == "*" && DAVStub.header(put, "Content-Type") == "text/vcard; charset=utf-8")
        #expect(put.bodyText.contains("\r\nCATEGORIES:Gym\r\n") && put.bodyText.contains("\r\nUID:robin-uid\r\n"))
        let group = try #require(transport.sent("PUT", Self.book + "family.vcf").first)
        #expect(DAVStub.header(group, "If-Match") == "\"g1\"")
        #expect(group.bodyText.contains("X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:jamie-uid\r\n"))
        #expect(group.bodyText.contains("X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:robin-uid\r\n"))
    }

    @Test func updatesKeepUnknownLinesAndLeaveGroups() async throws {
        let transport = Self.server()
        let service = try Self.service(transport)
        var jamie = try #require(try await service.loadContacts().first { $0.givenName == "Jamie" })
        jamie.jobTitle = "Design Director"
        jamie.labels = ["Friends"]
        let saved = try await service.update(jamie)
        let put = try #require(transport.sent("PUT", Self.book + "jamie.vcf").first)
        #expect(DAVStub.header(put, "If-Match") == "\"j1\"")
        #expect(put.bodyText.contains("TITLE:Design Director\r\n"))
        #expect(put.bodyText.contains("X-SOCIALPROFILE;type=example:https://social.example/jamie"))
        #expect(put.bodyText.contains("EMAIL;type=INTERNET;type=WORK:jamie@example.com") && put.bodyText.contains("CATEGORIES:Friends"))
        #expect(saved.etag == "\"new\"" && saved.jobTitle == "Design Director")
        let group = try #require(transport.sent("PUT", Self.book + "family.vcf").first)
        #expect(!group.bodyText.contains("jamie-uid") && DAVStub.header(group, "If-Match") == "\"g1\"")

        // Someone else changed it first: the newest card is read, but the save is refused.
        transport.on("GET", Self.book + "jamie.vcf") { _ in
            StubTransport.Response(status: 200, body: Data(Self.jamie.utf8), headers: ["ETag": "\"j9\""])
        }
        transport.on("PUT", Self.book + "jamie.vcf") { _ in .status(412) }
        var stale = saved
        stale.etag = "\"old\""
        await #expect(throws: PMailError.conflict) { _ = try await service.update(stale) }
    }

    @Test func groupsAreKnownEvenBeforeTheFirstListing() async throws {
        let transport = Self.server()
        let service = try Self.service(transport)
        // The app saved this contact earlier and edits it straight away after starting.
        let robin = Contact(id: Self.book + "robin.vcf", givenName: "Robin", labels: ["Family"], etag: nil, uid: "robin-uid")
        transport.on("GET", Self.book + "robin.vcf") { _ in
            StubTransport.Response(status: 200, body: Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Robin\r\nUID:robin-uid\r\nEND:VCARD\r\n".utf8),
                                   headers: ["ETag": "\"r1\""])
        }
        _ = try await service.update(robin)
        let put = try #require(transport.sent("PUT", Self.book + "robin.vcf").first)
        #expect(!put.bodyText.contains("CATEGORIES"))
        let group = try #require(transport.sent("PUT", Self.book + "family.vcf").first)
        #expect(group.bodyText.contains("X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:robin-uid"))
    }

    @Test func deletingAContactChecksItsVersion() async throws {
        let transport = Self.server()
        let service = try Self.service(transport)
        let sam = try #require(try await service.loadContacts().first { $0.givenName == "Sam" })
        try await service.delete(sam)
        let delete = try #require(transport.sent("DELETE", Self.book + "sam.vcf").first)
        #expect(DAVStub.header(delete, "If-Match") == "\"s1\"" && delete.url?.host == "p57-contacts.example.com")
        #expect(transport.sent("PUT", "/").isEmpty, "Sam wasn't in any group")

        transport.on("DELETE", Self.bookPath) { _ in .status(404) }
        await #expect(throws: PMailError.notFound) { try await service.delete(sam) }
    }
}
