import Foundation
import Testing
@testable import PMailKit

@Suite struct MicrosoftContactsServiceTests {
    static let api = "/v1.0/me"

    private func service(_ transport: StubTransport) -> MicrosoftContactsService {
        MicrosoftContactsService(client: .test(transport))
    }

    static let jamie = #"""
    {"@odata.etag": "W/\"EQAAABYAAAA1\"", "id": "AAMkCon1=", "createdDateTime": "2026-01-02T03:04:05Z",
     "changeKey": "EQAAABYAAAA1",
     "categories": ["Family", "Dog park"], "parentFolderId": "AAMkContacts=", "birthday": "1990-04-12T11:59:00Z",
      "fileAs": "Rivera, Jamie",
     "displayName": "Jamie Rivera", "givenName": "Jamie", "initials": "J.L.R.", "middleName": "Lee", "nickName": "Jay",
      "surname": "Rivera",
     "title": "Dr.", "generation": "Jr.", "imAddresses": [], "jobTitle": "Designer", "companyName": "Puggle & Co.",
      "department": "Design",
     "officeLocation": null, "businessHomePage": "https://puggle.example", "homePhones": ["+1 555-0101"],
      "mobilePhone": "+1 555-0100",
     "businessPhones": ["+1 555-0102", ""], "personalNotes": "Met at the dog park",
     "emailAddresses": [{"name": "Jamie Rivera", "address": "jamie@example.com"}, {"name": "jamie.home@example.com",
      "address": "jamie.home@example.com"}],
     "homeAddress": {"street": "1 Bark Lane", "city": "Springfield", "state": "IL", "countryOrRegion": "United States",
      "postalCode": "62701"},
     "businessAddress": {}, "otherAddress": {"city": "Chicago"}}
    """#

    @Test func contactsMapNamesPhonesAddressesAndCategories() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/contacts") { request in
            request.query("$skip") == nil
                ? .json(#"""
                {"value": [\#(Self.jamie)],
                 "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/contacts?%24top=500&%24skip=1"}
                """#)
                : .json(#"""
                {"value": [{"id": "AAMkCon2=", "displayName": "Puggle & Co.", "companyName": "Puggle & Co.",
                            "birthday": "1604-06-01T11:59:00Z"},
                           {"id": "AAMkCon3=", "displayName": "Waffles", "emailAddresses": [{"address": "waffles@example.com"}]},
                           {"displayName": "No ID"}]}
                """#)
        }
        let contacts = try await service(transport).loadContacts()
        #expect(transport.requests.first?.query("$top") == "500")
        #expect(contacts.map(\.id) == ["AAMkCon1=", "AAMkCon2=", "AAMkCon3="])
        #expect(contacts[0] == Contact(id: "AAMkCon1=", prefix: "Dr.", givenName: "Jamie", middleName: "Lee", familyName: "Rivera",
                                       suffix: "Jr.", nickname: "Jay", company: "Puggle & Co.", jobTitle: "Designer", department: "Design",
                                       emails: [LabeledValue(value: "jamie@example.com"), LabeledValue(value: "jamie.home@example.com")],
                                       phones: [LabeledValue(label: "mobile", value: "+1 555-0100"),
                                                LabeledValue(label: "work", value: "+1 555-0102"),
                                                LabeledValue(label: "home", value: "+1 555-0101")],
                                       addresses: [PostalAddress(label: "home", street: "1 Bark Lane", city: "Springfield", region: "IL",
                                                                 postalCode: "62701", country: "United States"),
                                                   PostalAddress(label: "other", city: "Chicago")],
                                       urls: [LabeledValue(label: "work", value: "https://puggle.example")],
                                       birthday: DateComponents(year: 1990, month: 4, day: 12), notes: "Met at the dog park",
                                       labels: ["Family", "Dog park"], etag: "EQAAABYAAAA1"))
        #expect(contacts[1].displayName == "Puggle & Co." && contacts[1].givenName.isEmpty)
        #expect(contacts[1].birthday == DateComponents(month: 6, day: 1))  // A birthday without a year.
        #expect(contacts[2].givenName == "Waffles")
    }

    @Test func creatingSendsOnlyWhatTheContactHas() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/contacts") { request in
            var echo = request.bodyJSONValue.object ?? [:]
            echo["id"] = "AAMkNew="
            echo["changeKey"] = "EQAAABYAAAA9"
            return .json(String(decoding: JSONValue.object(echo).encoded(), as: UTF8.self), status: 201)
        }
        let contact = Contact(givenName: "Waffles", familyName: "Pug", company: "Puggle & Co.",
                              emails: [LabeledValue(label: "home", value: "waffles@example.com")],
                              phones: [LabeledValue(label: "mobile", value: "+1 555-0199"),
                                       LabeledValue(label: "home", value: "+1 555-0198"),
                                       LabeledValue(label: "work", value: "+1 555-0197"),
                                       LabeledValue(label: "mobile", value: "+1 555-0196")],
                              addresses: [PostalAddress(label: "work", street: "2 Kennel Rd", city: "Springfield")],
                              birthday: DateComponents(month: 6, day: 1), photoData: Data([1, 2, 3]), labels: ["Dogs"])
        let saved = try await service(transport).create(contact)

        let body = try #require(transport.requests.first?.bodyJSONValue)
        #expect(body == [
            "givenName": "Waffles", "surname": "Pug", "companyName": "Puggle & Co.",
            "emailAddresses": [["address": "waffles@example.com", "name": "Waffles Pug"]],
            "mobilePhone": "+1 555-0199", "homePhones": ["+1 555-0198"], "businessPhones": ["+1 555-0197", "+1 555-0196"],
            "businessAddress": ["street": "2 Kennel Rd", "city": "Springfield", "state": "", "postalCode": "", "countryOrRegion": ""],
            "birthday": "1604-06-01T11:59:00Z", "categories": ["Dogs"],
        ])
        #expect(saved.id == "AAMkNew=" && saved.etag == "EQAAABYAAAA9" && saved.photoData == Data([1, 2, 3]))
        #expect(saved.birthday == DateComponents(month: 6, day: 1) && saved.labels == ["Dogs"])
    }

    @Test func updatingSendsEveryFieldSoClearedOnesClear() async throws {
        let transport = StubTransport()
        transport.on("PATCH", "\(Self.api)/contacts/AAMkCon1=") { _ in .json(Self.jamie) }
        let contact = Contact(id: "AAMkCon1=", givenName: "Jamie", familyName: "Rivera", emails: [LabeledValue(value: "jamie@example.com")],
                              etag: "EQAAABYAAAA1")
        _ = try await service(transport).update(contact)
        let body = try #require(transport.sent("PATCH", "\(Self.api)/contacts/AAMkCon1=").first?.bodyJSONValue)
        #expect(body["givenName"] == "Jamie" && body["surname"] == "Rivera")
        #expect(body["nickName"] == "" && body["jobTitle"] == "" && body["personalNotes"] == "" && body["mobilePhone"] == "")
        #expect(body["homePhones"] == [] && body["businessPhones"] == [] && body["categories"] == [])
        #expect(body["emailAddresses"] == [["address": "jamie@example.com", "name": "Jamie Rivera"]])
        #expect(body["homeAddress"] == ["street": "", "city": "", "state": "", "postalCode": "", "countryOrRegion": ""])
        #expect(body["birthday"] == .null)
        #expect(body.object?.keys.contains("birthday") == true)
    }

    @Test func deletingIsQuietWhenAlreadyGone() async throws {
        let transport = StubTransport()
        transport.on("DELETE", "\(Self.api)/contacts/") { _ in
            .json(#"""
            {"error": {"code": "ErrorItemNotFound", "message": "The specified object was not found in the store."}}
            """#, status: 404)
        }
        try await service(transport).delete(Contact(id: "AAMkCon1=", givenName: "Jamie"))
        #expect(transport.sent("DELETE", "\(Self.api)/contacts/AAMkCon1=").count == 1)
    }
}
