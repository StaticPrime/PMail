import Foundation
import Testing
@testable import PMailKit

/// Looking people up by email address, to fill in new contacts: Google's directory and other contacts, Microsoft's
/// people, and names written in one piece.
struct ContactLookupTests {
    @Test func namesInOnePiece() {
        #expect(PersonName.split("Sam Rivera") == ("Sam", "Rivera"))
        #expect(PersonName.split("Mary Ann Smith") == ("Mary Ann", "Smith"))
        #expect(PersonName.split("Rivera, Sam") == ("Sam", "Rivera"))
        #expect(PersonName.split("\"Sam Rivera (Work)\"") == ("Sam", "Rivera"), "quotes and what's in brackets go")
        #expect(PersonName.split("Waffles") == ("Waffles", ""))
        #expect(PersonName.split("sam@example.com") == ("", ""), "an address isn't a name")
        #expect(PersonName.split("  ") == ("", ""))
    }

    @Test func googleFindsSomeoneInTheDirectory() async throws {
        let transport = StubTransport()
        transport.on("GET", "/v1/people:searchDirectoryPeople") { request in
            #expect(request.queryValues(named: "sources") == ["DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE", "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"])
            return StubTransport.Response.json(#"""
            {"people": [
              {"resourceName": "people/other", "names": [{"givenName": "Taylor", "familyName": "Ng"}], "emailAddresses": [{"value": "tng@acme.example"}]},
              {"resourceName": "people/c123", "etag": "%EgU=",
               "names": [{"givenName": "Taylor", "familyName": "Brooks", "displayName": "Taylor Brooks"}],
               "emailAddresses": [{"value": "Taylor.Brooks@acme.example", "type": "work"}],
               "phoneNumbers": [{"value": "+1 503-555-0199", "type": "work"}],
               "organizations": [{"name": "Acme", "title": "Designer", "department": "Product"}],
               "photos": [{"url": "https://lh3.example/taylor.jpg"}]}
            ]}
            """#)
        }
        transport.on("GET", "/taylor.jpg") { _ in StubTransport.Response(status: 200, body: Data([0x89, 0x50, 0x4E, 0x47]), headers: ["Content-Type": "image/jpeg"]) }
        let found = try #require(try await GoogleContactsService(client: .test(transport)).lookUp(email: "taylor.brooks@acme.example"))
        #expect(found.givenName == "Taylor" && found.familyName == "Brooks" && found.jobTitle == "Designer" && found.company == "Acme")
        #expect(found.department == "Product" && found.phones.map(\.value) == ["+1 503-555-0199"])
        #expect(found.photoData == Data([0x89, 0x50, 0x4E, 0x47]), "with their picture")
        #expect(found.id != "people/c123" && found.etag == nil && found.kind == .contact, "as a new contact of the account's own")
        #expect(transport.sent("GET", "/v1/otherContacts:search").isEmpty, "the directory was enough")
    }

    @Test func googleFallsBackToOtherContacts() async throws {
        let transport = StubTransport()
        transport.on("GET", "/v1/people:searchDirectoryPeople") { _ in
            .json(#"{"error": {"code": 403, "message": "Request had insufficient authentication scopes."}}"#, status: 403)
        }
        transport.on("GET", "/v1/otherContacts:search") { request in
            guard request.queryValues(named: "query") == ["sam@example.com"] else { return StubTransport.Response.json("{}") }
            return StubTransport.Response.json(#"{"results": [{"person": {"resourceName": "otherContacts/c9", "names": [{"displayName": "Sam Rivera", "givenName": "Sam", "familyName": "Rivera"}], "emailAddresses": [{"value": "sam@example.com"}], "phoneNumbers": [{"value": "555-0100"}]}}]}"#)
        }
        let google = GoogleContactsService(client: .test(transport))
        let found = try #require(try await google.lookUp(email: "sam@example.com"))
        #expect(found.givenName == "Sam" && found.phones.first?.value == "555-0100" && found.kind == .contact)
        let searches = transport.sent("GET", "/v1/otherContacts:search")
        #expect(searches.map { $0.queryValues(named: "query").first ?? "?" } == ["", "sam@example.com"], "warmed up first, as Google asks")
        #expect(try await google.lookUp(email: "nobody@example.com") == nil)
        #expect(transport.sent("GET", "/v1/otherContacts:search").count == 3, "and only once")
    }

    @Test func microsoftFindsSomeoneInTheOrganization() async throws {
        let transport = StubTransport()
        transport.on("GET", "/v1.0/me/people") { request in
            #expect(request.queryValues(named: "$search") == ["\"alex@contoso.example\""])
            return StubTransport.Response.json(#"""
            {"value": [{"givenName": "Alex", "surname": "Kim", "jobTitle": "Engineering Lead", "companyName": "Contoso", "department": "Atlas",
                        "scoredEmailAddresses": [{"address": "Alex@contoso.example"}],
                        "phones": [{"type": "business", "number": "+1 425-555-0142"}, {"type": "mobile", "number": "+1 425-555-0143"}]}]}
            """#)
        }
        let found = try #require(try await MicrosoftContactsService(client: .test(transport)).lookUp(email: "alex@contoso.example"))
        #expect(found.givenName == "Alex" && found.familyName == "Kim" && found.jobTitle == "Engineering Lead" && found.company == "Contoso")
        #expect(found.phones == [LabeledValue(label: "work", value: "+1 425-555-0142"), LabeledValue(label: "mobile", value: "+1 425-555-0143")])
        #expect(found.emails == [LabeledValue(label: "work", value: "alex@contoso.example")])

        let personal = StubTransport()
        personal.on("GET", "/v1.0/me/people") { _ in .json(#"{"error": {"code": "ErrorAccessDenied"}}"#, status: 403) }
        #expect(try await MicrosoftContactsService(client: .test(personal)).lookUp(email: "a@b.example") == nil, "a personal account finds no one")
    }
}
