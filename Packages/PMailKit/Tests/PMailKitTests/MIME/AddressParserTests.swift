import Foundation
import Testing
@testable import PMailKit

@Suite struct AddressParserTests {
    private let jamie = MailAddress(name: "Jamie Rivera", email: "jamie@example.com")

    @Test func namesAndBareAddresses() {
        #expect(AddressParser.parse("Jamie Rivera <jamie@example.com>") == [jamie])
        #expect(AddressParser.parse("  jamie@example.com  ") == [MailAddress(email: "jamie@example.com")])
        #expect(AddressParser.parse("<jamie@example.com>") == [MailAddress(email: "jamie@example.com")])
        #expect(AddressParser.parse("Jamie Rivera <jamie@example.com>, sam@example.com, <alex@example.com>") == [
            jamie, MailAddress(email: "sam@example.com"), MailAddress(email: "alex@example.com"),
        ])
    }

    @Test func quotedNamesKeepTheirCommasAndQuotes() {
        #expect(AddressParser.parse("\"Rivera, Jamie\" <jamie@example.com>, Sam <sam@example.com>") == [
            MailAddress(name: "Rivera, Jamie", email: "jamie@example.com"), MailAddress(name: "Sam", email: "sam@example.com"),
        ])
        #expect(AddressParser.parse(#""Jamie \"JR\" Rivera" <jr@example.com>"#)
            == [MailAddress(name: "Jamie \"JR\" Rivera", email: "jr@example.com")])
        #expect(AddressParser.parse("\"Pug; Waffles: the dog\" <w@example.com>")
            == [MailAddress(name: "Pug; Waffles: the dog", email: "w@example.com")])
    }

    @Test func commentsGiveANameOnlyWhenThereIsNoOther() {
        #expect(AddressParser.parse("jamie@example.com (Jamie Rivera)") == [jamie])
        #expect(AddressParser.parse("Jamie <jamie@example.com> (work, mostly)") == [MailAddress(name: "Jamie", email: "jamie@example.com")])
        #expect(AddressParser.parse("<jamie@example.com> (Jamie (JR) Rivera)")
            == [MailAddress(name: "Jamie (JR) Rivera", email: "jamie@example.com")])
    }

    @Test func groupsListTheirMembers() {
        #expect(AddressParser.parse("Friends: a@example.com, Bo <b@example.com>;, c@example.com") == [
            MailAddress(email: "a@example.com"), MailAddress(name: "Bo", email: "b@example.com"), MailAddress(email: "c@example.com"),
        ])
        #expect(AddressParser.parse("undisclosed-recipients:;").isEmpty)
        #expect(AddressParser.parse("Team: x@example.com") == [MailAddress(email: "x@example.com")])
    }

    @Test func missingAngleBracketsAreRepaired() {
        #expect(AddressParser.parse("Jamie Rivera jamie@example.com") == [jamie])
        #expect(AddressParser.parse("Jamie Rivera <jamie@example.com") == [jamie])
        #expect(AddressParser.parse("Jamie Rivera jamie@example.com>") == [jamie])
        #expect(AddressParser.parse("<<jamie@example.com>>") == [MailAddress(email: "jamie@example.com")])
    }

    @Test func encodedNamesAreDecodedAfterSplitting() {
        #expect(AddressParser.parse("=?utf-8?Q?J=C3=BCrgen_M=C3=BCller?= <jm@example.de>")
            == [MailAddress(name: "Jürgen Müller", email: "jm@example.de")])
        #expect(AddressParser.parse("=?utf-8?Q?Rivera=2C_Jamie?= <jamie@example.com>, sam@example.com") == [
            MailAddress(name: "Rivera, Jamie", email: "jamie@example.com"), MailAddress(email: "sam@example.com"),
        ])
        #expect(AddressParser.parse("\"=?utf-8?B?R3LDvMOfZSBhdXMgS8O2bG4=?=\" <koeln@example.de>") == [
            MailAddress(name: "Grüße aus Köln", email: "koeln@example.de"),
        ])
        #expect(AddressParser.parse("=?iso-8859-1?Q?Andr=E9?= =?iso-8859-1?Q?_Gide?= <andre@example.fr>") == [
            MailAddress(name: "André Gide", email: "andre@example.fr"),
        ])
    }

    @Test func junkIsSkippedOrRepaired() {
        #expect(AddressParser.parse("Rivera, Jamie <jamie@example.com>")
            == [MailAddress(name: "Rivera, Jamie", email: "jamie@example.com")])
        #expect(AddressParser.parse("not an address").isEmpty)
        #expect(AddressParser.parse("").isEmpty)
        #expect(AddressParser.parse(", , sam@example.com,,") == [MailAddress(email: "sam@example.com")])
        #expect(AddressParser.parse("'Jamie Rivera' <jamie@example.com>") == [jamie])
        #expect(AddressParser.parse("jamie@example.com <jamie@example.com>") == [MailAddress(email: "jamie@example.com")])
        #expect(AddressParser.parse("\"JAMIE@example.com\" <jamie@example.com>") == [MailAddress(email: "jamie@example.com")])
        #expect(AddressParser.parse("Jamie <mailto:jamie@example.com>") == [MailAddress(name: "Jamie", email: "jamie@example.com")])
        #expect(AddressParser.parse("<@relay.example,@other.example:jamie@example.com>") == [MailAddress(email: "jamie@example.com")])
        #expect(AddressParser.parse("Mail Delivery System <MAILER-DAEMON>")
            == [MailAddress(name: "Mail Delivery System", email: "MAILER-DAEMON")])
        #expect(AddressParser.parse("Nobody <>").isEmpty)
        #expect(AddressParser.parse("\"john doe\"@example.com") == [MailAddress(email: "\"john doe\"@example.com")])
        #expect(AddressParser.parse("postmaster@[IPv6:2001:db8::1]") == [MailAddress(email: "postmaster@[IPv6:2001:db8::1]")])
        #expect(AddressParser.parse("a@example.com\r\n\t, b@example.com")
            == [MailAddress(email: "a@example.com"), MailAddress(email: "b@example.com")])
        #expect(AddressParser.parse("\"unclosed <a@example.com>").isEmpty)
        #expect(AddressParser.parse(") > ; : , <").isEmpty)
    }
}
