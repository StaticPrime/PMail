import Foundation
import Testing
@testable import PMailKit

@Suite struct GoogleContactsServiceTests {
    static let api = "/v1"
    static let photo = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    private func service(_ transport: StubTransport) -> GoogleContactsService {
        GoogleContactsService(client: .test(transport))
    }

    static let groups = #"""
    {"contactGroups": [
        {"resourceName": "contactGroups/myContacts", "groupType": "SYSTEM_CONTACT_GROUP", "name": "myContacts",
         "formattedName": "My Contacts"},
        {"resourceName": "contactGroups/starred", "groupType": "SYSTEM_CONTACT_GROUP", "name": "starred",
         "formattedName": "Starred"},
        {"resourceName": "contactGroups/7c9d1e", "groupType": "USER_CONTACT_GROUP", "name": "Family", "formattedName": "Family",
         "memberCount": 2}
    ], "totalItems": 3}
    """#

    static let jamie = #"""
    {"resourceName": "people/c111", "etag": "%EgUBAgMuNxoEAQIFByIMV2FmZmxlcw==",
     "metadata": {"sources": [{"type": "CONTACT", "id": "111", "etag": "#abc"}], "objectType": "PERSON"},
     "names": [{"metadata": {"primary": true}, "displayName": "Dr. Jamie Lee Rivera Jr.", "familyName": "Rivera",
      "givenName": "Jamie",
                "middleName": "Lee", "honorificPrefix": "Dr.", "honorificSuffix": "Jr."}],
     "nicknames": [{"value": "Jay"}],
     "emailAddresses": [{"metadata": {"primary": true}, "value": "jamie@example.com", "type": "work", "formattedType": "Work"},
                        {"value": "jamie.home@example.com", "type": "home"}],
     "phoneNumbers": [{"value": "+1 555-0100", "canonicalForm": "+15550100", "type": "mobile", "formattedType": "Mobile"}],
     "organizations": [{"metadata": {"primary": true}, "name": "Puggle & Co.", "title": "Designer", "department": "Design"}],
     "addresses": [{"type": "home", "streetAddress": "1 Bark Lane", "extendedAddress": "Apt 2", "city": "Springfield",
      "region": "IL",
                    "postalCode": "62701", "country": "United States", "countryCode": "US"}],
     "birthdays": [{"metadata": {"primary": true}, "date": {"month": 4, "day": 12}}],
     "biographies": [{"value": "Met at the dog park", "contentType": "TEXT_PLAIN"}],
     "urls": [{"value": "https://puggle.example", "type": "homePage"}],
     "photos": [{"metadata": {"primary": true}, "url": "https://lh3.googleusercontent.com/contacts/AAA111=s100"}],
     "memberships": [
        {"contactGroupMembership": {"contactGroupId": "myContacts", "contactGroupResourceName": "contactGroups/myContacts"}},
        {"contactGroupMembership": {"contactGroupId": "starred", "contactGroupResourceName": "contactGroups/starred"}},
        {"contactGroupMembership": {"contactGroupId": "7c9d1e", "contactGroupResourceName": "contactGroups/7c9d1e"}}
     ]}
    """#

    private func stubLoading(_ transport: StubTransport) {
        transport.on("GET", "\(Self.api)/contactGroups") { _ in .json(Self.groups) }
        transport.on("GET", "\(Self.api)/people/me/connections") { request in
            request.query("pageToken") == nil ? .json(#"""
            {"connections": [\#(Self.jamie),
                {"resourceName": "people/c222", "etag": "%E2", "names": [{"displayName": "Sam Lee", "givenName": "Sam",
                 "familyName": "Lee"}],
                 "photos": [{"url": "https://lh3.googleusercontent.com/cm/default=s100", "default": true}],
                 "birthdays": [{"date": {"year": 1990, "month": 2, "day": 3}}]}
            ], "nextPageToken": "c2", "totalPeople": 3}
            """#) : .json(#"""
            {"connections": [{"resourceName": "people/c333", "etag": "%E3", "names": [{"displayName": "Puggle & Co."}],
                              "photos": [{"url": "https://lh3.googleusercontent.com/contacts/BROKEN=s100"}]}], "totalPeople": 3}
            """#)
        }
        transport.on("GET", "\(Self.api)/otherContacts") { _ in
            .json(#"""
            {"otherContacts": [{"resourceName": "otherContacts/c444", "etag": "%E4",
                                "names": [{"displayName": "Pat Doe", "givenName": "Pat", "familyName": "Doe"}],
                                "emailAddresses": [{"value": "pat@example.org"}]}]}
            """#)
        }
        transport.on("GET", "/contacts/AAA111=s100") { _ in
            StubTransport.Response(status: 200, body: Self.photo, headers: ["Content-Type": "image/png"])
        }
    }

    @Test func contactsMapNamesLabelsStarsAndPhotos() async throws {
        let transport = StubTransport()
        stubLoading(transport)
        let contacts = try await service(transport).loadContacts()

        #expect(contacts.map(\.id) == ["people/c111", "people/c222", "people/c333", "otherContacts/c444"])
        let jamie = contacts[0]
        #expect(jamie == Contact(id: "people/c111", prefix: "Dr.", givenName: "Jamie", middleName: "Lee", familyName: "Rivera",
                                 suffix: "Jr.", nickname: "Jay", company: "Puggle & Co.", jobTitle: "Designer", department: "Design",
                                 emails: [LabeledValue(label: "work", value: "jamie@example.com"),
                                          LabeledValue(label: "home", value: "jamie.home@example.com")],
                                 phones: [LabeledValue(label: "mobile", value: "+1 555-0100")],
                                 addresses: [PostalAddress(label: "home", street: "1 Bark Lane\nApt 2", city: "Springfield", region: "IL",
                                                           postalCode: "62701", country: "United States")],
                                 urls: [LabeledValue(label: "homePage", value: "https://puggle.example")],
                                 birthday: DateComponents(month: 4, day: 12), notes: "Met at the dog park", photoData: Self.photo,
                                 labels: ["Family"], isStarred: true, etag: "%EgUBAgMuNxoEAQIFByIMV2FmZmxlcw=="))
        #expect(contacts[1].displayName == "Sam Lee" && !contacts[1].isStarred && contacts[1].photoData == nil)
        #expect(contacts[1].birthday == DateComponents(year: 1990, month: 2, day: 3))
        #expect(contacts[2].givenName == "Puggle & Co." && contacts[2].photoData == nil)  // Its picture failed to download.
        #expect(contacts[3].kind == .other && contacts[3].emails == [LabeledValue(value: "pat@example.org")])

        let connections = try #require(transport.sent("GET", "\(Self.api)/people/me/connections").first)
        #expect(connections.query("personFields") == "names,nicknames,emailAddresses,phoneNumbers,organizations,addresses,birthdays,"
                + "biographies,urls,photos,memberships,metadata")
        #expect(connections.query("pageSize") == "1000")
        #expect(transport.sent("GET", "\(Self.api)/otherContacts").first?.query("readMask") == "names,emailAddresses,phoneNumbers")
        // Pictures are fetched without the account's token, and the generated letter isn't fetched at all.
        let photos = transport.requests.filter { $0.url?.host == "lh3.googleusercontent.com" }
        #expect(Set(photos.compactMap { $0.url?.path }) == ["/contacts/AAA111=s100", "/contacts/BROKEN=s100"])
        #expect(photos.allSatisfy { $0.authorization == nil })
    }

    @Test func otherContactsAreSkippedWithoutPermission() async throws {
        let transport = StubTransport()
        stubLoading(transport)
        transport.on("GET", "\(Self.api)/otherContacts") { _ in
            .json(#"""
            {"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "status": "PERMISSION_DENIED"}}
            """#,
                  status: 403)
        }
        let contacts = try await service(transport).loadContacts()
        #expect(contacts.count == 3 && contacts.allSatisfy { $0.kind == .contact })
    }

    @Test func creatingSendsTheFieldsMakesNewGroupsAndStars() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/contactGroups") { _ in .json(Self.groups) }
        transport.on("POST", "\(Self.api)/contactGroups") { _ in
            .json(#"""
            {"resourceName": "contactGroups/d0g5", "groupType": "USER_CONTACT_GROUP", "name": "Dogs", "formattedName": "Dogs"}
            """#)
        }
        let created = #"""
        {"resourceName": "people/c999", "etag": "%E9", "names": [{"givenName": "Waffles", "familyName": "Pug"}],
         "emailAddresses": [{"value": "waffles@example.com", "type": "home"}]}
        """#
        transport.on("POST", "\(Self.api)/people:createContact") { _ in .json(created) }
        transport.on("POST", "\(Self.api)/contactGroups/starred/members:modify") { _ in .json("{}") }
        transport.on("GET", "\(Self.api)/people/c999") { _ in
            .json(#"{"resourceName": "people/c999", "etag": "%E10", "names": [{"givenName": "Waffles", "familyName": "Pug"}], "#
                  + #""memberships": [{"contactGroupMembership": {"contactGroupResourceName": "contactGroups/starred"}}, "#
                  + #"{"contactGroupMembership": {"contactGroupResourceName": "contactGroups/d0g5"}}]}"#)
        }
        let contact = Contact(givenName: "Waffles", familyName: "Pug", emails: [LabeledValue(label: "home", value: "waffles@example.com")],
                              birthday: DateComponents(year: 2019, month: 6, day: 1), photoData: Self.photo, labels: ["Family", "Dogs"],
                              isStarred: true)
        let saved = try await service(transport).create(contact)

        #expect(transport.sent("POST", "\(Self.api)/contactGroups").first?.bodyJSONValue == ["contactGroup": ["name": "Dogs"]])
        let create = try #require(transport.sent("POST", "\(Self.api)/people:createContact").first)
        #expect(create.query("personFields")?.hasPrefix("names,nicknames") == true)
        #expect(create.bodyJSONValue == [
            "names": [["givenName": "Waffles", "familyName": "Pug"]],
            "emailAddresses": [["value": "waffles@example.com", "type": "home"]],
            "birthdays": [["date": ["year": 2019, "month": 6, "day": 1]]],
            "memberships": [
                ["contactGroupMembership": ["contactGroupResourceName": "contactGroups/myContacts"]],
                ["contactGroupMembership": ["contactGroupResourceName": "contactGroups/7c9d1e"]],
                ["contactGroupMembership": ["contactGroupResourceName": "contactGroups/d0g5"]],
            ],
        ])
        #expect(transport.sent("POST", "\(Self.api)/contactGroups/starred/members:modify").first?.bodyJSONValue
                == ["resourceNamesToAdd": ["people/c999"]])
        #expect(saved.id == "people/c999" && saved.etag == "%E10" && saved.isStarred && saved.labels == ["Dogs"])
        #expect(saved.photoData == Self.photo)
    }

    @Test func updatingSendsOnlyChangedFieldsWithTheEtagAndUnstars() async throws {
        let transport = StubTransport()
        stubLoading(transport)
        let contacts = service(transport)
        let jamie = try #require(try await contacts.loadContacts().first)
        transport.on("PATCH", "\(Self.api)/people/c111:updateContact") { _ in
            .json(#"{"resourceName": "people/c111", "etag": "%E11", "names": [{"givenName": "Jamie", "familyName": "Rivera"}], "#
                  + #""organizations": [{"name": "Puggle & Co.", "title": "Lead Designer", "department": "Design"}]}"#)
        }
        transport.on("POST", "\(Self.api)/contactGroups/starred/members:modify") { _ in .json("{}") }
        transport.on("GET", "\(Self.api)/people/c111") { _ in
            .json(#"{"resourceName": "people/c111", "etag": "%E12", "names": [{"givenName": "Jamie", "familyName": "Rivera"}], "#
                  + #""organizations": [{"name": "Puggle & Co.", "title": "Lead Designer", "department": "Design"}]}"#)
        }
        var edited = jamie
        edited.jobTitle = "Lead Designer"
        edited.isStarred = false
        let saved = try await contacts.update(edited)

        let patch = try #require(transport.sent("PATCH", "\(Self.api)/people/c111:updateContact").first)
        #expect(patch.query("updatePersonFields") == "organizations")
        #expect(patch.bodyJSONValue == [
            "resourceName": "people/c111", "etag": "%EgUBAgMuNxoEAQIFByIMV2FmZmxlcw==",
            "organizations": [["name": "Puggle & Co.", "title": "Lead Designer", "department": "Design"]],
        ])
        #expect(transport.sent("POST", "\(Self.api)/contactGroups/starred/members:modify").first?.bodyJSONValue
                == ["resourceNamesToRemove": ["people/c111"]])
        #expect(saved.jobTitle == "Lead Designer" && saved.etag == "%E12" && !saved.isStarred)
        #expect(saved.photoData == Self.photo)
    }

    @Test func aStaleEtagIsAConflict() async throws {
        let transport = StubTransport()
        transport.on("PATCH", "\(Self.api)/people/c111:updateContact") { _ in
            .json(#"{"error": {"code": 400, "message": "Request person.etag is different than the current person.etag. "#
                  + #"Clear local cache and get the latest person.", "status": "FAILED_PRECONDITION"}}"#, status: 400)
        }
        let contact = Contact(id: "people/c111", givenName: "Jamie", etag: "%OLD")
        await #expect(throws: PMailError.conflict) { try await service(transport).update(contact) }
    }

    @Test func deletingUsesTheResourceName() async throws {
        let transport = StubTransport()
        transport.on("DELETE", "\(Self.api)/people/c111:deleteContact") { _ in .json("{}") }
        let contacts = service(transport)
        try await contacts.delete(Contact(id: "people/c111", givenName: "Jamie"))
        #expect(transport.sent("DELETE", "\(Self.api)/people/c111:deleteContact").count == 1)
        await #expect(throws: PMailError.notSupported("Other contacts can’t be deleted.")) {
            try await contacts.delete(Contact(id: "otherContacts/c444", kind: .other, givenName: "Pat"))
        }
    }
}
