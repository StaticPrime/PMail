import Foundation
import Testing
@testable import PMailKit

/// Outlook categories as the labels of Microsoft accounts.
@Suite struct MicrosoftCategoriesTests {
    static let api = "/v1.0/me"

    private func service(_ transport: StubTransport) -> MicrosoftMailService {
        MicrosoftMailService(email: "jamie@outlook.com", client: .test(transport))
    }

    static let categories = #"""
    {"value": [
        {"id": "cat-1", "displayName": "Work", "color": "preset7"},
        {"id": "cat-2", "displayName": "Family", "color": "preset4"},
        {"id": "cat-3", "displayName": "Someday", "color": "none"}
    ]}
    """#

    /// An inbox and Deleted Items, and the special folders' IDs (other special folders aren't there).
    private func stubFolders(_ transport: StubTransport) {
        transport.on("GET", "\(Self.api)/mailFolders") { _ in
            .json(#"""
            {"value": [{"id": "AAMkInbox=", "displayName": "Inbox", "childFolderCount": 0, "unreadItemCount": 2, "totalItemCount": 9},
                       {"id": "AAMkDeleted=", "displayName": "Deleted Items", "childFolderCount": 0}]}
            """#)
        }
        transport.on("GET", "\(Self.api)/mailFolders/") { request in
            let parts = request.url?.pathComponents ?? []
            let ids = ["inbox": "AAMkInbox=", "deleteditems": "AAMkDeleted=", "junkemail": "AAMkJunk="]
            guard parts.count > 4, let id = ids[parts[4]] else {
                return .json(#"{"error": {"code": "ErrorFolderNotFound", "message": "Not found."}}"#, status: 404)
            }
            return .json(#"{"id": "\#(id)"}"#)
        }
    }

    private func stubBatch(_ transport: StubTransport) {
        transport.on("POST", "/v1.0/$batch") { request in
            let answers = request.bodyJSONValue["requests"].array.map { #"{"id": "\#($0["id"].string ?? "")", "status": 200, "body": {}}"# }
            return .json(#"{"responses": [\#(answers.joined(separator: ","))]}"#)
        }
    }

    private func batched(_ transport: StubTransport) -> [JSONValue] {
        transport.sent("POST", "/v1.0/$batch").flatMap { $0.bodyJSONValue["requests"].array }
    }

    @Test func presetsHaveColors() {
        #expect(MicrosoftMailService.categoryColor("preset7") == "#3267B8")
        #expect(MicrosoftMailService.categoryColor("PRESET24") == "#82375F")
        #expect(MicrosoftMailService.categoryColor("none") == nil && MicrosoftMailService.categoryColor("preset99") == nil)
        #expect(MicrosoftMailService.categoryPreset(nearest: "#3267B8") == "preset7")
        #expect(MicrosoftMailService.categoryPreset(nearest: "#2B5090") == "preset22")
        #expect(MicrosoftMailService.categoryPreset(nearest: "teal") == nil)
        #expect(MicrosoftMailService.categoryName(fromLabelID: "category:Bob's") == "Bob's")
        #expect(MicrosoftMailService.categoryName(fromLabelID: "category:") == nil)
        #expect(MicrosoftMailService.categoryName(fromLabelID: "AAMkInbox=") == nil)
    }

    @Test func masterCategoriesAreTheLabelsWithTheirColors() async throws {
        let transport = StubTransport()
        stubFolders(transport)
        transport.on("GET", "\(Self.api)/outlook/masterCategories") { _ in .json(Self.categories) }
        let folders = try await service(transport).loadFolders()
        #expect(folders.map(\.id) == ["AAMkInbox=", "AAMkDeleted=", MicrosoftMailService.flaggedFolderID,
                                      "category:Family", "category:Someday", "category:Work"])
        #expect(folders.suffix(3) == [MailFolder(id: "category:Family", name: "Family", kind: .label, colorHex: "#4AB63F"),
                                      MailFolder(id: "category:Someday", name: "Someday", kind: .label),
                                      MailFolder(id: "category:Work", name: "Work", kind: .label, colorHex: "#3267B8")])

        // An account PMail can't read the categories of still has its folders.
        transport.on("GET", "\(Self.api)/outlook/masterCategories") { _ in
            .json(#"{"error": {"code": "ErrorAccessDenied", "message": "Access is denied."}}"#, status: 403)
        }
        let plain = try await service(transport).loadFolders()
        #expect(!plain.contains { $0.kind == .label } && plain.last?.id == MicrosoftMailService.flaggedFolderID)
    }

    @Test func aLabelListsItsCategoryInEveryFolderButDeletedItemsAndJunk() async throws {
        let transport = StubTransport()
        stubFolders(transport)
        transport.on("GET", "\(Self.api)/messages") { _ in
            .json(#"""
            {"@odata.count": 3, "value": [
                {"id": "AAMkW1=", "conversationId": "C1", "subject": "Plans", "parentFolderId": "AAMkProjects=",
                 "receivedDateTime": "2026-11-23T17:00:00Z", "categories": ["Work", "Family"]},
                {"id": "AAMkW2=", "conversationId": "C2", "subject": "Old plans", "parentFolderId": "AAMkDeleted=",
                 "receivedDateTime": "2026-11-23T16:00:00Z", "categories": ["Work"]},
                {"id": "AAMkW3=", "conversationId": "C3", "subject": "Budget", "parentFolderId": "AAMkInbox=",
                 "receivedDateTime": "2026-11-23T15:00:00Z", "categories": ["work"]},
                {"id": "AAMkW4=", "conversationId": "C4", "subject": "Not this", "parentFolderId": "AAMkInbox=",
                 "receivedDateTime": "2026-11-23T14:00:00Z", "categories": []}
             ],
             "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/messages?%24skip=25"}
            """#)
        }
        let mail = service(transport)
        let page = try await mail.listConversations(ListRequest(folderID: "category:Work", pageSize: 25))
        let request = try #require(transport.sent("GET", "\(Self.api)/messages").first)
        #expect(request.query("$filter") == "receivedDateTime ge 1900-01-01T00:00:00Z and categories/any(c:c eq 'Work')")
        #expect(request.query("$orderby") == "receivedDateTime desc" && request.query("$top") == "25")
        #expect(request.query("$select") == MicrosoftMailService.messageFields)
        #expect(page.conversations.flatMap(\.messages).map(\.id) == ["AAMkW1=", "AAMkW3="])
        #expect(page.conversations.first?.messages.first?.labelIDs == ["category:Work", "category:Family"])
        #expect(page.nextPageToken == "https://graph.microsoft.com/v1.0/me/messages?%24skip=25")

        // A search can't be narrowed to a category on the server, so each message is checked here.
        let found = try await mail.listConversations(ListRequest(folderID: "category:Work", query: "plans"))
        let search = try #require(transport.sent("GET", "\(Self.api)/messages").last)
        #expect(search.query("$search") == "\"plans\"" && search.query("$filter") == nil)
        #expect(found.conversations.flatMap(\.messages).map(\.id) == ["AAMkW1=", "AAMkW3="])
        _ = try await mail.listConversations(ListRequest(folderID: "category:Work", pageToken: page.nextPageToken))
        #expect(transport.requests.last?.url?.absoluteString == page.nextPageToken)
    }

    @Test func labelingPatchesEachMessagesCategories() async throws {
        let transport = StubTransport()
        stubBatch(transport)
        let mail = service(transport)
        let family = MessageSummary(id: "AAMkMsg1=", labelIDs: ["category:Family"])
        try await mail.perform(.addLabel("category:Work"), on: [family, MessageSummary(id: "AAMkMsg3="), family])
        let both = MessageSummary(id: "AAMkMsg1=", labelIDs: ["category:Family", "category:Work"])
        try await mail.perform(.removeLabel("category:family"), on: [both])
        let requests = batched(transport)
        #expect(requests.map { $0["method"] } == ["PATCH", "PATCH", "PATCH"])
        #expect(requests.map { $0["url"] } == ["/me/messages/AAMkMsg1=", "/me/messages/AAMkMsg3=", "/me/messages/AAMkMsg1="])
        #expect(requests.map { $0["body"] } == [["categories": ["Family", "Work"]], ["categories": ["Work"]], ["categories": ["Work"]]])
        #expect(requests.allSatisfy { $0["headers"]["Prefer"] == "IdType=\"ImmutableId\"" })
    }

    @Test func categoriesAreMadeRecoloredRenamedAndDeleted() async throws {
        let transport = StubTransport()
        stubBatch(transport)
        transport.on("GET", "\(Self.api)/outlook/masterCategories") { _ in .json(Self.categories) }
        transport.on("POST", "\(Self.api)/outlook/masterCategories") { request in
            let body = request.bodyJSONValue
            let name = body["displayName"].string ?? "", color = body["color"].string ?? "none"
            return .json(#"{"id": "cat-new", "displayName": "\#(name)", "color": "\#(color)"}"#, status: 201)
        }
        transport.on("PATCH", "\(Self.api)/outlook/masterCategories/") { request in
            .json(#"{"id": "cat-1", "displayName": "Work", "color": "\#(request.bodyJSONValue["color"].string ?? "")"}"#)
        }
        transport.on("DELETE", "\(Self.api)/outlook/masterCategories/") { _ in .status(204) }
        transport.on("GET", "\(Self.api)/messages") { _ in
            .json(#"{"value": [{"id": "AAMkW1=", "categories": ["Work", "Family"]}, {"id": "AAMkW3=", "categories": ["work"]}]}"#)
        }
        let mail = service(transport)

        let trips = try await mail.createLabel(named: "Trips", colorHex: "#2B5090")
        #expect(trips == MailFolder(id: "category:Trips", name: "Trips", kind: .label, colorHex: "#2A5191"))
        #expect(transport.sent("POST", "\(Self.api)/outlook/masterCategories").first?.bodyJSONValue
                == ["displayName": "Trips", "color": "preset22"])

        let work = MailFolder(id: "category:Work", name: "Work", kind: .label, colorHex: "#3267B8")
        let recolored = try await mail.updateLabel(work, name: "Work", colorHex: "#D52530")
        #expect(recolored == MailFolder(id: "category:Work", name: "Work", kind: .label, colorHex: "#D6252E"))
        let patch = try #require(transport.sent("PATCH", "\(Self.api)/outlook/masterCategories/").first)
        #expect(patch.url?.lastPathComponent == "cat-1" && patch.bodyJSONValue == ["color": "preset0"])

        // Outlook can't rename a category: a new one, in the old one's color, takes its messages, then the old one goes.
        let job = try await mail.updateLabel(work, name: "Job", colorHex: nil)
        #expect(job == MailFolder(id: "category:Job", name: "Job", kind: .label, colorHex: "#3267B8"))
        #expect(transport.sent("POST", "\(Self.api)/outlook/masterCategories").last?.bodyJSONValue
                == ["displayName": "Job", "color": "preset7"])
        let lookup = try #require(transport.sent("GET", "\(Self.api)/messages").first)
        #expect(lookup.query("$filter") == "categories/any(c:c eq 'Work')" && lookup.query("$select") == "id,categories")
        #expect(batched(transport).map { $0["url"] } == ["/me/messages/AAMkW1=", "/me/messages/AAMkW3="])
        #expect(batched(transport).map { $0["body"] } == [["categories": ["Family", "Job"]], ["categories": ["Job"]]])
        #expect(transport.sent("DELETE", "\(Self.api)/outlook/masterCategories/").compactMap { $0.url?.lastPathComponent } == ["cat-1"])

        try await mail.deleteLabel(MailFolder(id: "category:family", name: "family", kind: .label))
        try await mail.deleteLabel(MailFolder(id: "category:Nowhere", name: "Nowhere", kind: .label))  // Already gone.
        #expect(transport.sent("DELETE", "\(Self.api)/outlook/masterCategories/").compactMap { $0.url?.lastPathComponent }
                == ["cat-1", "cat-2"])
        await #expect(throws: PMailError.notFound) {
            try await mail.updateLabel(MailFolder(id: "AAMkInbox=", name: "Inbox"), name: "Mine", colorHex: nil)
        }
    }
}
