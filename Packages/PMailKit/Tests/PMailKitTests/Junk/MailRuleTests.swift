import Foundation
import Testing
@testable import PMailKit

struct MailRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func facts(from: MailAddress = MailAddress(name: "Great Deals", email: "deals@offers.example"), to: [MailAddress] = [],
                       subject: String = "Big savings", raw: String? = nil, attachments: [PMailKit.Attachment] = [], daysOld: Double = 1) -> MessageFacts {
        let summary = MessageSummary(id: "1", from: from, to: to, subject: subject, snippet: "Save on everything this weekend",
                                     date: now.addingTimeInterval(-daysOld * 86_400))
        let message = raw.map { MailMessage(summary: summary, textBody: "Save on everything this weekend", attachments: attachments, rawSource: Data($0.utf8)) }
            ?? MailMessage(summary: summary, textBody: "Save on everything this weekend", attachments: attachments)
        return MessageFacts(summary: summary, message: message, account: "Jamie@Example.com", fullName: "Jamie Rivera", now: now)
    }

    @Test func textConditions() {
        let facts = facts()
        #expect(RuleCondition(.from, .contains, "offers.example").matches(facts))
        #expect(RuleCondition(.from, .isEqualTo, "great deals").matches(facts), "names count too, ignoring case")
        #expect(RuleCondition(.from, .isEqualTo, "deals@offers.example").matches(facts))
        #expect(RuleCondition(.from, .beginsWith, "deals@").matches(facts) && RuleCondition(.from, .endsWith, ".example").matches(facts))
        #expect(RuleCondition(.subject, .doesNotContain, "invoice").matches(facts) && !RuleCondition(.subject, .doesNotContain, "savings").matches(facts))
        #expect(RuleCondition(.content, .contains, "weekend").matches(facts))
        #expect(!RuleCondition(.subject, .contains, "  ").matches(facts), "an empty value never matches")
    }

    @Test func peopleAndNames() {
        var facts = facts(to: [MailAddress(name: "\"Jamie  Rivera\"", email: "jamie@example.com")])
        #expect(facts.addressedToFullName, "by full name, quotes and spacing aside")
        #expect(RuleCondition(.addressedToFullName).matches(facts) && !RuleCondition(.notAddressedToFullName).matches(facts))
        #expect(!self.facts(to: [MailAddress(name: "Jamie", email: "jamie@example.com")]).addressedToFullName)
        #expect(!self.facts(to: [MailAddress(name: "Jamie Rivera", email: "other@example.com")]).addressedToFullName, "to the account's own address")
        facts.senderInContacts = true
        facts.senderIsStarred = true
        facts.senderLabels = ["family"]
        #expect(RuleCondition(.senderInContacts).matches(facts) && !RuleCondition(.senderNotInContacts).matches(facts))
        #expect(RuleCondition(.senderNotInPreviousRecipients).matches(facts) && RuleCondition(.senderIsStarred).matches(facts))
        #expect(RuleCondition(.senderHasLabel, .contains, "Family").matches(facts) && !RuleCondition(.senderLacksLabel, .contains, "family").matches(facts))
        #expect(RuleCondition(.account, .isEqualTo, "jamie@example.com").matches(facts) && !RuleCondition(.account, .isEqualTo, "x@y.z").matches(facts))
    }

    @Test func datesHeadersAndAttachments() {
        let raw = "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"\r\nX-Priority: 1 (Highest)\r\nX-Mailer: BulkSender 9\r\n\r\nHi"
        let pdf = PMailKit.Attachment(id: "2", filename: "Invoice 42.PDF", mimeType: "application/octet-stream", size: 10)
        let facts = facts(raw: raw, attachments: [pdf], daysOld: 10)
        #expect(RuleCondition(.dateReceived, .moreThanDaysOld, "7").matches(facts) && !RuleCondition(.dateSent, .lessThanDaysOld, "7").matches(facts))
        #expect(RuleCondition(.header, .contains, "bulksender", header: "X-Mailer").matches(facts))
        #expect(RuleCondition(.isSigned).matches(facts) && !RuleCondition(.isEncrypted).matches(facts))
        #expect(RuleCondition(.priorityHigh).matches(facts) && !RuleCondition(.priorityNormal).matches(facts))
        #expect(RuleCondition(.attachmentName, .endsWith, ".pdf").matches(facts))
        #expect(RuleCondition(.attachmentType, .isEqualTo, AttachmentKind.pdf.rawValue).matches(facts), "by the name's extension when the type says nothing")
        #expect(RuleCondition(.priorityNormal).matches(self.facts()), "normal when no header says")
        #expect(AttachmentKind.of(PMailKit.Attachment(id: "1", filename: "a.jpg", mimeType: "image/jpeg", size: 1)) == .image)
        #expect(AttachmentKind.of(PMailKit.Attachment(id: "1", filename: "Budget.xlsx", mimeType: "application/octet-stream", size: 1)) == .spreadsheet)
    }

    @Test func allOrAnyAndWhatNeedsTheWholeMessage() {
        let rule = MailRule(description: "Deals", matchesAll: true,
                            conditions: [RuleCondition(.from, .contains, "offers"), RuleCondition(.subject, .contains, "invoice")], actions: [RuleAction(.star)])
        #expect(!rule.matches(facts()))
        var any = rule
        any.matchesAll = false
        #expect(any.matches(facts()))
        #expect(!rule.needsWholeMessage && MailRule(description: "", conditions: [RuleCondition(.content, .contains, "x")], actions: []).needsWholeMessage)
        #expect(!MailRule(description: "", conditions: [], actions: []).matches(facts()), "a rule with no conditions never matches")
    }

    @Test func theJunkRuleAndThePolicy() throws {
        var facts = facts()
        facts.isJunk = true
        #expect(MailRule.junk.matches(facts), "junk from a stranger who doesn't know the person's name")
        var policy = JunkPolicy()
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .markJunk, "marked and left in the inbox at first")
        policy.junkAction = .moveToJunk
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .moveToJunk)
        #expect(policy.outcome(for: facts, fromBlockedSender: true) == .moveToJunk, "blocked senders' mail goes to Junk")
        policy.blockedAction = .moveToTrash
        #expect(policy.outcome(for: facts, fromBlockedSender: true) == .moveToTrash)
        policy.filtersBlocked = false
        #expect(policy.outcome(for: facts, fromBlockedSender: true) == .moveToJunk, "with blocking off it's judged like any mail")

        facts.senderInPreviousRecipients = true
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .nothing, "someone written to before is never junk")
        policy.exemptsPreviousRecipients = false
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .moveToJunk)

        policy.junkAction = .custom
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .nothing, "the rule asks for a stranger")
        facts.senderInPreviousRecipients = false
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .actions(MailRule.junk.actions))
        policy.filtersJunk = false
        #expect(policy.outcome(for: facts, fromBlockedSender: false) == .nothing)

        // Saved settings missing newer keys keep their defaults.
        let old = try JSONDecoder().decode(JunkPolicy.self, from: Data(#"{"filtersJunk":false,"junkAction":"moveToJunk"}"#.utf8))
        #expect(!old.filtersJunk && old.junkAction == .moveToJunk && old.exemptsContacts && old.blockedAction == .moveToJunk && old.customRule == .junk)
        let saved = try JSONDecoder().decode(JunkPolicy.self, from: JSONEncoder().encode(policy))
        #expect(saved == policy)

        // A rule saved with an action PMail no longer has loads without it, keeping the rest.
        let star = UUID(), folder = UUID()
        let older = #"{"description":"Old","matchesAll":true,"conditions":[],"actions":[{"id":"\#(folder)","kind":"moveToFolder","value":"Promos"},{"id":"\#(star)","kind":"star","value":""}]}"#
        let rule = try JSONDecoder().decode(MailRule.self, from: Data(older.utf8))
        #expect(rule.actions == [RuleAction(.star, id: star)])
        let onlyFolder = #"{"description":"Old","matchesAll":true,"conditions":[],"actions":[{"id":"\#(folder)","kind":"moveToFolder","value":"Promos"}]}"#
        #expect(try JSONDecoder().decode(MailRule.self, from: Data(onlyFolder.utf8)).actions.map(\.kind) == [.moveToJunk], "and never with no actions at all")
    }

    @Test func serversSpamMarks() {
        func hints(_ headers: [String: String]) -> SenderHints { SenderHints(field: { headers[$0] }) }
        #expect(hints(["x-spam-flag": "YES"]).serverMarkedJunk == true)
        #expect(hints(["x-spam-status": "Yes, score=7.2 required=5.0"]).serverMarkedJunk == true)
        #expect(hints(["x-spam-status": "No, score=0.1"]).serverMarkedJunk == false)
        #expect(hints(["x-ms-exchange-organization-scl": "6"]).serverMarkedJunk == true)
        #expect(hints(["x-ms-exchange-organization-scl": "-1"]).serverMarkedJunk == false)
        #expect(hints(["list-id": "<news.example>"]).serverMarkedJunk == nil, "nothing said either way")
    }

    @Test func marksAndPreviousRecipients() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PMailMarks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marks = JunkMarks(file: folder.appendingPathComponent("JunkMarks.json"))
        let a = MessageSummary(id: "1", messageIDHeader: "<A@example>"), b = MessageSummary(id: "2", messageIDHeader: "<b@example>")
        await marks.mark([a], as: .junk)
        await marks.mark([b], as: .blocked)
        #expect(await marks.marks(for: [a, b]) == ["1": .junk, "2": .blocked])
        let moved = MessageSummary(id: "other-id", messageIDHeader: "<a@EXAMPLE>")
        #expect(await JunkMarks(file: folder.appendingPathComponent("JunkMarks.json")).marks(for: [moved]) == ["other-id": .junk],
                "kept, and found by Message-ID wherever the message is")
        await marks.clear([a])
        #expect(await marks.marks(for: [a, b]) == ["2": .blocked])

        let recipients = PreviousRecipients(file: folder.appendingPathComponent("Recipients.json"))
        await recipients.record([" Alex@Example.com ", "not an address"])
        #expect(await recipients.contains("alex@example.com"))
        #expect(await recipients.all() == ["alex@example.com"])
    }
}
