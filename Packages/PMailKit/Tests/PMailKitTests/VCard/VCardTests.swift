import Foundation
import Testing
@testable import PMailKit

@Suite struct VCardTests {
    static func crlf(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\r\n") + "\r\n"
    }

    /// A card the way iCloud stores one, with grouped labels and lines PMail doesn't use.
    static let appleCard = crlf(#"""
    BEGIN:VCARD
    VERSION:3.0
    PRODID:-//Example Corp//Phone 18.0//EN
    N:Rivera;Jamie;Lee;Dr.;PhD
    FN:Dr. Jamie Lee Rivera PhD
    NICKNAME:Jay
    ORG:Puggle & Co.;Design
    TITLE:Lead Designer
    EMAIL;type=INTERNET;type=HOME;type=pref:jamie@home.example
    item1.EMAIL;type=INTERNET:jamie@other.example
    item1.X-ABLabel:_$!<Other>!$_
    item2.EMAIL;type=INTERNET:jamie@club.example
    item2.X-ABLabel:Dog club
    TEL;type=CELL;type=VOICE;type=pref:+1 555 0100
    TEL;type=WORK;type=VOICE:+1 555 0101
    item3.TEL:+1 555 0102
    item3.X-ABLabel:_$!<HomeFAX>!$_
    item4.ADR;type=HOME;type=pref:;;1 Pug Lane\nApt 2;Portland;OR;97201;USA
    item4.X-ABADR:us
    item5.URL;type=pref:http\://puggle.example
    item5.X-ABLabel:_$!<HomePage>!$_
    BDAY;X-APPLE-OMIT-YEAR=1604:1604-05-17
    NOTE:Loves waffles\, and naps.
    item6.X-ABRELATEDNAMES:Waffles
    item6.X-ABLabel:_$!<Friend>!$_
    X-SOCIALPROFILE;type=example:https://social.example/jamie
    IMPP;X-SERVICE-TYPE=Chat;type=HOME:chat:jamie
    CATEGORIES:Friends,Design
    UID:6C5A2B9E-1111-2222-3333-444455556666
    END:VCARD
    """#)

    @Test func appleCardReadsWithGroupedLabels() throws {
        let contact = try #require(VCard.contacts(in: Self.appleCard).first)
        #expect(contact.prefix == "Dr." && contact.givenName == "Jamie" && contact.middleName == "Lee")
        #expect(contact.familyName == "Rivera" && contact.suffix == "PhD" && contact.nickname == "Jay")
        #expect(contact.company == "Puggle & Co." && contact.department == "Design" && contact.jobTitle == "Lead Designer")
        #expect(contact.emails == [LabeledValue(label: "home", value: "jamie@home.example"),
                                   LabeledValue(label: "other", value: "jamie@other.example"),
                                   LabeledValue(label: "Dog club", value: "jamie@club.example")])
        #expect(contact.phones == [LabeledValue(label: "mobile", value: "+1 555 0100"), LabeledValue(label: "work", value: "+1 555 0101"),
                                   LabeledValue(label: "home fax", value: "+1 555 0102")])
        #expect(contact.addresses == [PostalAddress(label: "home", street: "1 Pug Lane\nApt 2", city: "Portland", region: "OR",
                                                    postalCode: "97201", country: "USA")])
        #expect(contact.urls == [LabeledValue(label: "homepage", value: "http://puggle.example")])
        #expect(contact.birthday == DateComponents(month: 5, day: 17))
        #expect(contact.notes == "Loves waffles, and naps.")
        #expect(contact.labels == ["Friends", "Design"])
        #expect(contact.uid == "6C5A2B9E-1111-2222-3333-444455556666")
        #expect(contact.kind == .contact && !contact.isStarred)
    }

    @Test func picturesComeInlineOnly() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let text = Self.crlf("""
        BEGIN:VCARD
        VERSION:3.0
        FN:Pic Three
        PHOTO;ENCODING=b;TYPE=JPEG:\(jpeg.base64EncodedString())
        END:VCARD
        BEGIN:VCARD
        VERSION:4.0
        FN:Pic Four
        PHOTO:data:image/png;base64,\(png.base64EncodedString())
        END:VCARD
        BEGIN:VCARD
        VERSION:2.1
        FN:Pic Old
        PHOTO;JPEG;ENCODING=BASE64:\(jpeg.base64EncodedString())
        END:VCARD
        BEGIN:VCARD
        VERSION:3.0
        FN:Pic Remote
        PHOTO;VALUE=uri:https://example.com/pug.jpg
        END:VCARD
        """)
        let contacts = VCard.contacts(in: text)
        #expect(contacts.map(\.photoData) == [jpeg, png, jpeg, nil])
        #expect(contacts.map(\.givenName) == ["Pic Three", "Pic Four", "Pic Old", "Pic Remote"])
    }

    @Test func birthdaysWithAndWithoutYears() {
        let text = Self.crlf("""
        BEGIN:VCARD
        VERSION:3.0
        FN:A
        BDAY:1990-05-17
        END:VCARD
        BEGIN:VCARD
        VERSION:4.0
        FN:B
        BDAY:--0517
        END:VCARD
        BEGIN:VCARD
        VERSION:3.0
        FN:C
        BDAY;VALUE=date:19900517
        END:VCARD
        BEGIN:VCARD
        VERSION:4.0
        FN:D
        BDAY;VALUE=text:circa 1800
        END:VCARD
        """)
        #expect(VCard.contacts(in: text).map(\.birthday) == [DateComponents(year: 1990, month: 5, day: 17), DateComponents(month: 5, day: 17),
                                                            DateComponents(year: 1990, month: 5, day: 17), nil])
    }

    @Test func groupsBecomeLabelsAndAreNotListed() {
        let text = Self.crlf("""
        BEGIN:VCARD
        VERSION:3.0
        N:Kim;Alex;;;
        UID:alex-uid
        CATEGORIES:Neighbors
        END:VCARD
        BEGIN:VCARD
        VERSION:3.0
        N:Lee;Sam;;;
        UID:sam-uid
        END:VCARD
        BEGIN:VCARD
        VERSION:3.0
        N:Family
        FN:Family
        X-ADDRESSBOOKSERVER-KIND:group
        X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:alex-uid
        X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:SAM-UID
        UID:group-1
        END:VCARD
        BEGIN:VCARD
        VERSION:4.0
        KIND:group
        FN:Dog walkers
        MEMBER:urn:uuid:sam-uid
        UID:group-2
        END:VCARD
        """)
        let contacts = VCard.contacts(in: text)
        #expect(contacts.map(\.displayName) == ["Alex Kim", "Sam Lee"])
        #expect(contacts.map(\.labels) == [["Neighbors", "Family"], ["Family", "Dog walkers"]])
    }

    @Test func oldCardsWithQuotedPrintableRead() {
        let text = "BEGIN:VCARD\r\nVERSION:2.1\r\nN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:M=C3=BCller;J=C3=BCrgen;;;\r\n"
            + "NOTE;ENCODING=QUOTED-PRINTABLE:Hello=\r\n World=0D=0Aagain\r\nTEL;WORK;VOICE:+49 30 1234\r\nEND:VCARD\r\n"
        let contact = VCard.contacts(in: text).first
        #expect(contact?.familyName == "Müller" && contact?.givenName == "Jürgen")
        #expect(contact?.notes == "Hello World\r\nagain")
        #expect(contact?.phones == [LabeledValue(label: "work", value: "+49 30 1234")])
    }

    @Test func rewritingKeepsWhatItDoesNotUnderstand() throws {
        let card = try #require(VCardCard.parse(Data(Self.appleCard.utf8)).first)
        var contact = card.contact(id: "/card/jamie.vcf", etag: nil)
        contact.jobTitle = "Design Director"
        contact.phones.append(LabeledValue(label: "Kennel", value: "+1 555 0199"))
        contact.emails.remove(at: 1)
        let text = VCardWriter.card(updating: card, with: contact, uid: contact.uid, categories: contact.labels,
                                    now: ICS.moment("2026-11-21 12:00"))
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
        for kept in ["EMAIL;type=INTERNET;type=HOME;type=pref:jamie@home.example", "item2.EMAIL;type=INTERNET:jamie@club.example",
                     "item2.X-ABLabel:Dog club", "item4.X-ABADR:us", "item5.URL;type=pref:http\\://puggle.example",
                     "item6.X-ABRELATEDNAMES:Waffles", "item6.X-ABLabel:_$!<Friend>!$_",
                     "X-SOCIALPROFILE;type=example:https://social.example/jamie", "IMPP;X-SERVICE-TYPE=Chat;type=HOME:chat:jamie",
                     "BDAY;X-APPLE-OMIT-YEAR=1604:1604-05-17", "FN:Dr. Jamie Lee Rivera PhD", "UID:6C5A2B9E-1111-2222-3333-444455556666"] {
            #expect(unfolded.contains(kept), "lost \(kept)")
        }
        #expect(!unfolded.contains("jamie@other.example") && !unfolded.contains("item1."))
        #expect(unfolded.contains("TITLE:Design Director"))
        #expect(unfolded.contains("item7.TEL;TYPE=VOICE:+1 555 0199") && unfolded.contains("item7.X-ABLabel:Kennel"))
        #expect(unfolded.contains("REV:2026-11-21T12:00:00Z"))
        #expect(text.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\nPRODID:-//PuggleSoft//PMail//EN\r\n"))

        // Reading it back gives the edited contact.
        let reread = try #require(VCard.contacts(in: text).first)
        #expect(reread.jobTitle == "Design Director" && reread.phones == contact.phones && reread.emails == contact.emails)
        #expect(reread.addresses == contact.addresses && reread.urls == contact.urls && reread.birthday == contact.birthday)
    }

    @Test func newCardsAreVersionThree() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let contact = Contact(givenName: "Sam", familyName: "Lee; Jr", company: "Pugs, Inc.",
                              emails: [LabeledValue(label: "work", value: "sam@pugs.example"),
                                       LabeledValue(label: "other", value: "sam@x.example")],
                              phones: [LabeledValue(label: "mobile", value: "+1 555 0123")],
                              addresses: [PostalAddress(label: "work", street: "2 Bark St", city: "Salem", region: "MA", postalCode: "01970",
                                                        country: "USA")],
                              urls: [LabeledValue(label: "homepage", value: "https://pugs.example/a,b")],
                              birthday: DateComponents(month: 2, day: 29), notes: "Line 1\nLine 2", photoData: png, labels: ["Work"],
                              isStarred: true)
        let text = VCardWriter.newCard(for: contact, uid: "sam-1", categories: contact.labels, now: ICS.moment("2026-11-21 12:00"))
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
        for line in ["VERSION:3.0", "N:Lee\\; Jr;Sam;;;", "FN:Sam Lee\\; Jr", "ORG:Pugs\\, Inc.", "EMAIL;TYPE=INTERNET,WORK:sam@pugs.example",
                     "item1.EMAIL;TYPE=INTERNET:sam@x.example", "item1.X-ABLabel:_$!<Other>!$_", "TEL;TYPE=CELL,VOICE:+1 555 0123",
                     "ADR;TYPE=WORK:;;2 Bark St;Salem;MA;01970;USA", "item2.URL:https://pugs.example/a,b",
                     "item2.X-ABLabel:_$!<HomePage>!$_", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-02-29", "NOTE:Line 1\\nLine 2",
                     "PHOTO;ENCODING=b;TYPE=PNG:\(png.base64EncodedString())", "CATEGORIES:Work", "X-PMAIL-STARRED:TRUE", "UID:sam-1"] {
            #expect(unfolded.contains("\r\n" + line + "\r\n"), "missing \(line)")
        }
        let reread = try #require(VCard.contacts(in: text).first)
        #expect(reread.givenName == contact.givenName && reread.familyName == contact.familyName && reread.company == contact.company)
        #expect(reread.emails == contact.emails && reread.phones == contact.phones && reread.addresses == contact.addresses)
        #expect(reread.urls == contact.urls && reread.birthday == contact.birthday && reread.notes == contact.notes)
        #expect(reread.photoData == png && reread.labels == ["Work"] && reread.isStarred)

        let company = VCardWriter.newCard(for: Contact(company: "Puggle Bakery"), uid: "b", categories: [])
        #expect(company.contains("\r\nX-ABShowAs:COMPANY\r\n") && company.contains("\r\nFN:Puggle Bakery\r\n"))
    }

    @Test func versionFourCardsStayVersionFour() throws {
        let card = try #require(VCardCard.parse(Data(Self.crlf("""
        BEGIN:VCARD
        VERSION:4.0
        FN:Robin
        N:;Robin;;;
        TEL;VALUE=uri;TYPE=cell:tel:+1-555-0142
        UID:urn:uuid:robin
        END:VCARD
        """).utf8)).first)
        var contact = card.contact(id: "r", etag: nil)
        #expect(contact.phones == [LabeledValue(label: "mobile", value: "+1-555-0142")])
        contact.birthday = DateComponents(month: 7, day: 4)
        contact.photoData = Data([0xFF, 0xD8, 0xFF])
        let text = VCardWriter.card(updating: card, with: contact, uid: nil, categories: [])
        #expect(text.contains("\r\nVERSION:4.0\r\n") && text.contains("\r\nBDAY:--0704\r\n"))
        #expect(text.contains("\r\nPHOTO:data:image/jpeg;base64,/9j/\r\n"))
        #expect(text.contains("TEL;VALUE=uri;TYPE=cell:tel:+1-555-0142") && text.contains("UID:urn:uuid:robin"))
    }

    @Test func groupMembersAreAddedAndRemoved() throws {
        let group = try #require(VCardCard.parse(Data(Self.crlf("""
        BEGIN:VCARD
        VERSION:3.0
        FN:Family
        X-ADDRESSBOOKSERVER-KIND:group
        X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:alex-uid
        END:VCARD
        """).utf8)).first)
        #expect(VCardWriter.addingMember("ALEX-UID", to: group) == nil)
        let added = try #require(VCardWriter.addingMember("sam-uid", to: group))
        #expect(added.contains("X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:sam-uid"))
        let removed = try #require(VCardWriter.removingMember("urn:uuid:alex-uid", from: group))
        #expect(!removed.contains("alex-uid") && removed.contains("FN:Family"))
        #expect(VCardWriter.removingMember("nobody", from: group) == nil)
    }

    @Test func brokenCardsNeverCrash() {
        for sample in ["", "BEGIN:VCARD", "BEGIN:VCARD\r\nN:;;;;;;;;;;\r\nBDAY:--13\r\nPHOTO;ENCODING=b:!!!\r\nADR:;;;\r\nEND:VCARD",
                       "BEGIN:VCARD\r\nEMAIL;ENCODING=QUOTED-PRINTABLE:=Z=\r\nTEL:\r\nEND:VCARD"] {
            _ = VCard.contacts(in: sample)
        }
        #expect(VCard.contacts(in: "BEGIN:VCARD\r\nN:;;;;;;;;;;\r\nEND:VCARD").count == 1)
    }
}
