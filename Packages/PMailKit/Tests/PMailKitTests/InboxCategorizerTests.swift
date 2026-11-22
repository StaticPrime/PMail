import Foundation
import Testing
@testable import PMailKit

/// The rules that sort an inbox into categories, and what headers say about a sender.
struct InboxCategorizerTests {
    private struct Example {
        var name: String
        var message: MessageSummary
        var expected: InboxCategory
    }

    private static func example(_ name: String, from email: String, _ subject: String, snippet: String = "",
                                hints: SenderHints? = nil, _ expected: InboxCategory) -> Example {
        Example(name: name, message: MessageSummary(id: name, from: MailAddress(email: email), subject: subject, snippet: snippet,
                                                    senderHints: hints),
                expected: expected)
    }

    private static let unsubscribe = SenderHints(canUnsubscribe: true)

    private static let examples: [Example] = [
        // From people: Primary, whatever they say.
        example("a friend's note", from: "alex.kim@gmail.com", "Lunch tomorrow?", snippet: "Want to grab tacos at noon?", .primary),
        example("a friend writing about an order and a sale", from: "jamie@example.com", "Your order of cookies is ready!",
                snippet: "The bake sale went great, 20% off the leftovers", .primary),
        example("a colleague's reply about an invoice", from: "sam@company.example", "Re: Invoice for March",
                snippet: "Looks good, approved.", .primary),
        example("someone whose name is a role word", from: "john.deal@example.com", "Weekend plans", .primary),
        example("a reply from a shop's order desk", from: "orders@bakery.example", "Re: Custom cake for Saturday",
                snippet: "Yes, we can do chocolate.", .primary),
        example("a shared address people answer", from: "info@plumber.example", "Your quote for Tuesday", .primary),
        example("a bounce of the person's own mail", from: "MAILER-DAEMON@mail.example.com", "Undelivered Mail Returned to Sender",
                hints: SenderHints(isAutomatic: true), .primary),
        example("a message with no sender", from: "", "Hello", .primary),

        // Transactions
        example("a receipt", from: "no_reply@email.apple.com", "Your receipt from Apple.", .transactions),
        example("an order that shipped", from: "shipment-tracking@amazon.com",
                "Your Amazon.com order #112-3456789 has shipped", .transactions),
        example("a delivery", from: "auto-confirm@amazon.com", "Delivered: \"Squeaky dog toy\"", .transactions),
        example("a carrier's tracking update", from: "TrackingUpdates@fedex.com", "Your package is out for delivery",
                .transactions),
        example("an invoice", from: "billing@hosting.example", "Invoice INV-2041 for November", .transactions),
        example("a payment", from: "alerts@bank.example", "Your Visa payment is scheduled", .transactions),
        example("money received", from: "no-reply@bank.example", "You\u{2019}ve received $250.00 from Alex", .transactions),
        example("a statement", from: "no-reply@alerts.bank.example", "Your November statement is ready", .transactions),
        example("a booking", from: "reservations@hotel.example", "Reservation confirmed: Seaside Inn, Dec 12–14", .transactions),
        example("a flight itinerary", from: "noreply@airline.example", "Your itinerary: New York to San Francisco",
                .transactions),
        example("a refund", from: "no-reply@store.example", "Your refund of $18.99 has been processed", .transactions),
        example("a renewal", from: "billing+acct42@streaming.example", "Your subscription will renew on December 1",
                .transactions),
        example("an order with the details in the snippet", from: "orders@shop.example", "Thanks for shopping with us, Jamie!",
                snippet: "Order number 4512. Order total $54.20", .transactions),
        example("a social network's receipt", from: "billing@linkedin.com", "Your LinkedIn Premium receipt", .transactions),

        // Promotions
        example("a sale", from: "hello@brand.example", "Black Friday: 40% off everything", hints: unsubscribe, .promotions),
        example("a deals sender", from: "deals@travel.example", "Weekend getaways from $99", .promotions),
        example("marketing that borrows an order's words", from: "offers@shop.example",
                "Your order is waiting: 20% off ends tonight", hints: unsubscribe, .promotions),
        example("a cart left behind", from: "no-reply@shop.example", "You left something in your cart", hints: unsubscribe,
                .promotions),
        example("an amount off a first order", from: "hello@brand.example", "Take $20 off your first order", hints: unsubscribe,
                .promotions),
        example("a promo code isn't a sign-in code", from: "marketing@pizza.example", "Use code 2024 for a free dessert",
                hints: unsubscribe, .promotions),
        example("an offer in the snippet", from: "news@outdoors.example", "The winter collection is here",
                snippet: "Shop now and get free shipping on orders over $50", hints: unsubscribe, .promotions),

        // Social
        example("a comment on a photo", from: "notification@facebookmail.com", "Jamie Rivera commented on your photo.", .social),
        example("an invitation to connect", from: "invitations@linkedin.com", "Alex Kim wants to connect", .social),
        example("a new follower elsewhere", from: "no-reply@photos.example", "Sam started following you", .social),
        example("a friend request in the snippet", from: "notify@friends.example", "You have 1 new notification",
                snippet: "Robin sent you a friend request", .social),

        // Updates
        example("a newsletter", from: "newsletter@weekly.example", "This week in Swift: concurrency tips",
                hints: SenderHints(canUnsubscribe: true, listID: "weekly.example"), .updates),
        example("a verification code", from: "no-reply@accounts.example", "Your verification code is 482913", .updates),
        example("a social network's sign-in code", from: "security@mail.instagram.com", "123456 is your Instagram code",
                .updates),
        example("a one-time code", from: "no-reply@rides.example", "Your Rides code: 4821", .updates),
        example("a sign-in alert", from: "no-reply@accounts.example", "New sign-in on Mac", .updates),
        example("a password reset", from: "support@app.example", "Reset your password", hints: SenderHints(isAutomatic: true),
                .updates),
        example("someone writing to a mailing list", from: "maria@university.example", "[swift-dev] Proposal: faster builds",
                hints: SenderHints(canUnsubscribe: true, listID: "swift-dev.lists.example.org"), .updates),
        example("a mailing list thread about invoices", from: "pat@example.org", "[billing-dev] Invoice export is broken",
                hints: SenderHints(listID: "billing-dev.example.org"), .updates),
        example("a code review notification", from: "notifications@github.com", "Re: [pmail/pmail] Fix crash on launch (#42)",
                hints: SenderHints(canUnsubscribe: true, listID: "pmail.pmail.github.com"), .updates),
        example("bulk mail from a school", from: "announcements@school.example", "Snow day: school closed Friday",
                hints: SenderHints(isBulk: true), .updates),
        example("an alert", from: "alerts@monitor.example", "Disk space low on build server", .updates),
        example("an out-of-office reply", from: "jamie@company.example", "Automatic reply: Lunch tomorrow?",
                hints: SenderHints(isAutomatic: true), .updates),
    ]

    @Test func realisticMessagesLandInTheirCategories() {
        for example in Self.examples {
            #expect(InboxCategorizer.category(for: example.message) == example.expected, "\(example.name)")
        }
    }

    @Test func phrasesMatchWholeWordsAndSkipTheirExceptions() {
        let orders = PhraseList(["your order", "your * order", "% off", "ordered:"], except: ["off your order"])
        #expect(orders.matches(CategoryText("Your ORDER is ready")))
        #expect(orders.matches(CategoryText("Your Amazon.com order of 2 items")), "a * is one word")
        #expect(!orders.matches(CategoryText("Your  big  red order")), "but only one")
        #expect(!orders.matches(CategoryText("yourorder")) && !orders.matches(CategoryText("your orders")), "whole words")
        #expect(orders.matches(CategoryText("Ordered: Dog toy")))
        #expect(!orders.matches(CategoryText("Get 20 off your order")), "an exception doesn't count")
        #expect(orders.matches(CategoryText("Get 20% off")))
        #expect(!orders.matches(CategoryText("Get 20% offers")))
        #expect(PhraseList(["cafe"]).matches(CategoryText("Café\u{00A0}news")), "without accents")
        #expect(PhraseList(["don't miss"]).matches(CategoryText("Don’t miss it")), "with plain apostrophes")
    }

    @Test func roleAddressesAndPeople() {
        #expect(SenderAddress("orders@shop.example").role == .transactions)
        #expect(SenderAddress("Order-Update@shop.example").role == .transactions, "the most particular word wins")
        #expect(SenderAddress("shop-news@shop.example").role == .promotions)
        #expect(SenderAddress("deals2@shop.example").role == .promotions, "digits split words")
        #expect(SenderAddress("AccountAlerts@bank.example").role == .updates, "words run together")
        #expect(SenderAddress("john.deal@example.com").role == nil)
        #expect(SenderAddress("support@example.com").role == nil && SenderAddress("hello@example.com").role == nil)
        #expect(SenderAddress("No.Reply@example.com").isNoReply && SenderAddress("do_not_reply@example.com").isNoReply)
        #expect(!SenderAddress("noreen@example.com").isNoReply)
        #expect(SenderAddress("x@em.linkedin.com").isSocialNetwork && !SenderAddress("x@notlinkedin.com").isSocialNetwork)
        #expect(SenderAddress("orders+42@Shop.Example.").localPart == "orders", "without its +tag")
        #expect(SenderAddress("a@Shop.Example.").domain == "shop.example")
    }

    @Test func repliesAndCodes() {
        #expect(CategoryText("Re: Lunch").isReply && CategoryText("AW: Termin").isReply && CategoryText("RE[2]: Lunch").isReply)
        #expect(!CategoryText("Receipt: Lunch").isReply && !CategoryText("Fwd: Lunch").isReply)
        #expect(CategoryText("Your code is 123456").hasOneTimeCode)
        #expect(!CategoryText("Your code is 12").hasOneTimeCode && !CategoryText("Order 123456 shipped").hasOneTimeCode)
        #expect(!CategoryText("Promo code 2024SALE inside").hasOneTimeCode)
        #expect(CategoryText("Take $20 off today").hasAmountOff && CategoryText("15€ off").hasAmountOff)
        #expect(!CategoryText("Take 20 off today").hasAmountOff && !CategoryText("$20 offer").hasAmountOff)
    }

    // MARK: Sender hints

    @Test func senderHintsFromIMAPHeaderFields() {
        let headers = IMAPHeaderFields.parse(Data(("References: <a@example.com>\r\nList-Unsubscribe: <mailto:u@lists.example>\r\n"
            + "List-ID: Swift Dev\r\n <swift-dev.lists.example.org>\r\nPrecedence: Bulk\r\n"
            + "Auto-Submitted: auto-generated\r\n\r\n").utf8))
        let hints = IMAPMailService.senderHints(from: headers)
        #expect(hints == SenderHints(canUnsubscribe: true, listID: "swift-dev.lists.example.org", isBulk: true, isAutomatic: true))

        let person = IMAPMailService.senderHints(from: IMAPHeaderFields.parse(Data("In-Reply-To: <a@example.com>\r\n\r\n".utf8)))
        #expect(person == SenderHints(), "read, and nothing to say")
        let notAutomatic = IMAPMailService.senderHints(from: ["auto-submitted": " No ", "precedence": "first-class", "list-id": "  "])
        #expect(notAutomatic == SenderHints())
        let replied = IMAPMailService.senderHints(from: ["auto-submitted": "auto-replied; owner-email=\"a@example.com\"",
                                                         "precedence": "list (mailman)", "list-id": "plain.example.org"])
        #expect(replied == SenderHints(listID: "plain.example.org", isBulk: true, isAutomatic: true))
    }

    @Test func senderHintsFromARawMessage() {
        let raw = Data(("From: Weekly <newsletter@weekly.example>\r\nTo: pug@example.com\r\nSubject: This week\r\n"
            + "Message-ID: <w1@weekly.example>\r\nList-Unsubscribe: <https://weekly.example/u/1>\r\n"
            + "List-Id: \"Weekly\" <weekly.example>\r\nPrecedence: bulk\r\n\r\nHello!\r\n").utf8)
        let parsed = MIMEParser.parse(raw)
        let expected = SenderHints(canUnsubscribe: true, listID: "weekly.example", isBulk: true)
        #expect(parsed.senderHints == expected)
        #expect(parsed.summary(id: "1").senderHints == expected)

        let personal = MIMEParser.parse(Data("From: alex@example.com\r\nSubject: Hi\r\n\r\nHello\r\n".utf8))
        #expect(personal.summary(id: "2").senderHints == SenderHints())
    }
}
