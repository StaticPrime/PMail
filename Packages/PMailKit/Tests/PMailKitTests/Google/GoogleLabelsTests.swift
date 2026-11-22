import Foundation
import Testing
@testable import PMailKit

/// Making, changing and deleting labels on Google accounts.
@Suite struct GoogleLabelsTests {
    static let api = "/gmail/v1/users/me"

    private func service(_ transport: StubTransport) -> GoogleMailService {
        GoogleMailService(email: "jamie@gmail.com", client: .test(transport))
    }

    @Test func labelColorsComeFromGooglesPaletteWithTextThatReads() {
        #expect(GoogleMailService.labelColor(for: "#1D4488") == ["backgroundColor": "#1c4587", "textColor": "#ffffff"])
        #expect(GoogleMailService.labelColor(for: "fff0c0") == ["backgroundColor": "#fdedc1", "textColor": "#000000"])
        #expect(GoogleMailService.labelColor(for: "#16A766") == ["backgroundColor": "#16a766", "textColor": "#000000"])
        #expect(GoogleMailService.labelColor(for: "#000001") == ["backgroundColor": "#000000", "textColor": "#ffffff"])
        #expect(GoogleMailService.labelColor(for: "red") == nil && GoogleMailService.labelColor(for: nil) == nil)
        #expect(GoogleMailService.labelPalette.allSatisfy { WebColor.hex($0) != nil })
    }

    @Test func eachTabCountsItsUnreadInboxMessages() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/messages") { request in
            let labels = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "labelIds" }.compactMap(\.value) ?? []
            #expect(labels.contains("INBOX") && labels.contains("UNREAD"))
            if labels.contains("CATEGORY_PROMOTIONS") {
                return .json(#"{"messages": [{"id": "a"}, {"id": "b"}], "nextPageToken": "next", "resultSizeEstimate": 812}"#)
            }
            if labels.contains("CATEGORY_PERSONAL") { return .json(#"{"messages": [{"id": "c"}, {"id": "d"}, {"id": "e"}]}"#) }
            return .json(#"{"resultSizeEstimate": 0}"#)
        }
        let tabs = Array(GoogleMailService.tabs.prefix(3))
        let counts = try await service(transport).unreadCounts(inTabs: tabs)
        #expect(counts == ["CATEGORY_PERSONAL": 3, "CATEGORY_PROMOTIONS": 812, "CATEGORY_SOCIAL": 0])
    }

    @Test func labelsAreMadeRenamedWithTheLabelsInsideThemAndDeleted() async throws {
        let transport = StubTransport()
        transport.on("POST", "\(Self.api)/labels") { request in
            .json(#"""
            {"id": "Label_9", "name": "\#(request.bodyJSONValue["name"].string ?? "")", "type": "user",
             "color": {"textColor": "#ffffff", "backgroundColor": "#1c4587"}}
            """#)
        }
        transport.on("GET", "\(Self.api)/labels") { _ in
            .json(#"""
            {"labels": [{"id": "INBOX", "name": "INBOX", "type": "system"},
                        {"id": "Label_1", "name": "Work", "type": "user"},
                        {"id": "Label_3", "name": "Work/Puggle", "type": "user"},
                        {"id": "Label_7", "name": "Work/Puggle/2026", "type": "user"},
                        {"id": "Label_8", "name": "Work/Puggles", "type": "user"}]}
            """#)
        }
        transport.on("GET", "\(Self.api)/labels/Label_3") { _ in .json(#"{"id": "Label_3", "name": "Work/Puggle", "type": "user"}"#) }
        transport.on("PATCH", "\(Self.api)/labels/") { request in
            .json(#"""
            {"id": "\#(request.url?.lastPathComponent ?? "")", "name": "\#(request.bodyJSONValue["name"].string ?? "")",
             "type": "user", "color": {"backgroundColor": "#fdedc1", "textColor": "#000000"}}
            """#)
        }
        transport.on("DELETE", "\(Self.api)/labels/Label_9") { _ in .status(204) }
        let mail = service(transport)

        let trips = try await mail.createLabel(named: " Trips ", colorHex: "#1D4488")
        #expect(trips == MailFolder(id: "Label_9", name: "Trips", kind: .label, colorHex: "#1C4587"))
        #expect(transport.sent("POST", "\(Self.api)/labels").first?.bodyJSONValue == [
            "name": "Trips", "labelListVisibility": "labelShow", "messageListVisibility": "show",
            "color": ["backgroundColor": "#1c4587", "textColor": "#ffffff"],
        ])
        // Without a color, the label gets Google's own.
        _ = try await mail.createLabel(named: "Plain", colorHex: nil)
        #expect(transport.sent("POST", "\(Self.api)/labels").last?.bodyJSONValue["color"].isNull == true)
        await #expect(throws: PMailError.server("A label needs a name.")) { try await mail.createLabel(named: "  ", colorHex: nil) }

        // The name shown for a nested label is its last part: renaming keeps it where it is, and the labels inside it follow.
        let puggle = MailFolder(id: "Label_3", name: "Puggle", kind: .label, parentID: "Label_1")
        let renamed = try await mail.updateLabel(puggle, name: "PMail", colorHex: "fff0c0")
        #expect(renamed == MailFolder(id: "Label_3", name: "PMail", kind: .label, parentID: "Label_1", colorHex: "#FDEDC1"))
        let patches = transport.sent("PATCH", "\(Self.api)/labels/")
        #expect(patches.map { $0.url?.lastPathComponent } == ["Label_3", "Label_7"])
        #expect(patches.map(\.bodyJSONValue) == [
            ["name": "Work/PMail", "color": ["backgroundColor": "#fdedc1", "textColor": "#000000"]],
            ["name": "Work/PMail/2026"],
        ])

        try await mail.deleteLabel(trips)
        try await mail.deleteLabel(MailFolder(id: "Label_404", name: "Gone", kind: .label))  // Already gone.
        #expect(transport.sent("DELETE", "\(Self.api)/labels/").compactMap { $0.url?.lastPathComponent } == ["Label_9", "Label_404"])
    }
}
