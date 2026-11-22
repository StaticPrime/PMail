import Foundation

/// The rules that sort a message into one of the inbox's categories, from its sender's address, its subject and
/// snippet, and what its headers say about the sender (`SenderHints`).
///
/// They're cautious. Mail that looks like it's from a person (an ordinary address, and no sign of a mailing list or of
/// mail sent in bulk or by a machine) stays in Primary whatever it says, so a friend's note about an order or a sale
/// isn't sorted away. Mail with those signs (a List-Id, List-Unsubscribe, Precedence or Auto-Submitted header, a no-reply
/// address, a role address like orders@ or deals@, a social network's domain) is sorted by what it's about:
///
/// - Social: social networks' notifications, from their own domains or saying someone tagged you, followed you, sent
///   a friend request or wants to connect.
/// - Transactions: receipts, orders, shipping and delivery, invoices, bills, payments, statements, bookings, refunds and
///   renewals.
/// - Promotions: sales, offers, coupons and other marketing.
/// - Updates: everything else sent by a machine or to a list: notifications, alerts, security and sign-in codes,
///   newsletters, digests, and people writing to mailing lists.
///
/// A bounce (from a mailer-daemon or postmaster) stays in Primary, where the person sees that their mail didn't arrive.
/// The words looked for are English ones. `InboxSorter` puts the person's own choice for a sender before these rules.
public enum InboxCategorizer {
    /// The category the rules give a message.
    public static func category(for message: MessageSummary) -> InboxCategory {
        let sender = SenderAddress(message.from?.email ?? "")
        if sender.isMailSystem { return .primary }
        let hints = message.senderHints ?? SenderHints()
        let subject = CategoryText(message.subject)
        let role = sender.role
        let isFromList = hints.listID != nil
        let headerSigns = isFromList || hints.canUnsubscribe || hints.isBulk || hints.isAutomatic
        // A role address is staffed by people too: a reply from orders@ is someone answering.
        let addressSigns = sender.isNoReply || sender.isSocialNetwork || (role != nil && !subject.isReply)
        guard headerSigns || addressSigns else { return .primary }
        // Someone writing to a mailing list.
        if isFromList && !addressSigns { return .updates }

        if Phrases.security.matches(subject) { return .updates }
        // Marketing borrows the words of orders and bookings ("Your trip awaits: 30% off"); a receipt rarely advertises
        // in its subject.
        let isPromotional = Phrases.promotions.matches(subject) || subject.hasAmountOff
        if Phrases.transactions.matches(subject), !isPromotional || role == .transactions { return .transactions }
        if subject.hasOneTimeCode { return .updates }
        let snippet = CategoryText(message.snippet)
        if sender.isSocialNetwork || Phrases.social.matches(subject) || Phrases.social.matches(snippet) { return .social }
        if isPromotional || role == .promotions { return .promotions }
        if hints.canUnsubscribe || hints.isBulk, Phrases.promotions.matches(snippet) || snippet.hasAmountOff { return .promotions }
        if role == .transactions || Phrases.transactionDetails.matches(snippet) { return .transactions }
        return .updates
    }
}

// MARK: - The sender's address

/// What a sender's address says about who sent it.
struct SenderAddress {
    /// The part before the @, without any "+tag", in lowercase.
    let localPart: String
    /// The part after the @, in lowercase.
    let domain: String

    init(_ email: String) {
        let address = email.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>")).lowercased()
        var local = address
        var domain = ""
        if let at = address.lastIndex(of: "@") {
            local = String(address[..<at])
            domain = address[address.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        localPart = local
        self.domain = domain
    }

    /// A mail system writing about mail that didn't arrive (a bounce) or about the mailbox itself.
    var isMailSystem: Bool { Self.mailSystemNames.contains(localPart) }

    /// "noreply", "no-reply", "do_not_reply" and the like: nobody reads the replies.
    var isNoReply: Bool {
        let letters = localPart.filter(\.isLetter)
        return letters.contains("noreply") || letters.contains("donotreply") || letters.contains("dontreply")
    }

    /// A social network's own domain (or one of its subdomains), which only sends notifications.
    var isSocialNetwork: Bool {
        !domain.isEmpty && Self.socialNetworkDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// What a role address like orders@, deals@ or notifications@ sends: Transactions, Promotions or Updates. Nil for
    /// any other address. Every word in it has to be one role addresses use ("order-update", "TrackingUpdates"), so
    /// someone whose name happens to be one, like john.deal@, still counts as a person.
    var role: InboxCategory? {
        var words: [String] = []
        for token in localPart.split(whereSeparator: { !$0.isLetter }) {
            guard let parts = Self.roleAddressWords(in: String(token)) else { return nil }
            words += parts
        }
        let roles = Set(words.compactMap { Self.roleWords[$0] })
        // The most particular wins: "order-update" is about an order.
        return [InboxCategory.transactions, .promotions, .updates].first { roles.contains($0) }
    }

    /// The words role addresses use that make up `token`, longest first where they run together ("trackingupdates" is
    /// "tracking" and "updates"), or nil when it isn't made of them.
    static func roleAddressWords(in token: String) -> [String]? {
        func isKnown(_ word: String) -> Bool { roleWords[word] != nil || serviceWords.contains(word) }
        if isKnown(token) { return [token] }
        let characters = Array(token)
        guard !characters.isEmpty, characters.count <= 64 else { return nil }
        // found[n]: the words that make up the first n characters, if they can.
        var found: [[String]?] = Array(repeating: nil, count: characters.count + 1)
        found[0] = []
        for end in 1...characters.count {
            for start in 0..<end {
                guard let before = found[start] else { continue }
                let word = String(characters[start..<end])
                if isKnown(word) {
                    found[end] = before + [word]
                    break
                }
            }
        }
        return found[characters.count]
    }

    static let mailSystemNames: Set<String> = ["mailer-daemon", "mailerdaemon", "mail-daemon", "postmaster"]

    /// The domains social networks send their notifications from.
    static let socialNetworkDomains = [
        "facebookmail.com", "facebook.com", "messenger.com", "instagram.com", "threads.net", "linkedin.com", "twitter.com",
        "x.com", "pinterest.com", "reddit.com", "redditmail.com", "tiktok.com", "snapchat.com", "tumblr.com",
        "nextdoor.com", "meetup.com", "quora.com", "discord.com", "discordapp.com", "strava.com", "goodreads.com",
        "bsky.app", "mastodon.social", "flickr.com", "youtube.com", "twitch.tv", "vk.com", "xing.com", "letterboxd.com",
        "deviantart.com",
    ]

    /// Words in role addresses, and the category of the mail they send.
    static let roleWords: [String: InboxCategory] = {
        var words: [String: InboxCategory] = [:]
        for word in ["order", "orders", "receipt", "receipts", "billing", "invoice", "invoices", "payment", "payments",
                     "shipping", "shipment", "shipments", "tracking", "delivery", "deliveries", "booking", "bookings",
                     "reservation", "reservations", "statement", "statements", "estatement", "estatements", "confirm",
                     "confirmation", "confirmations", "autoconfirm", "purchase", "purchases", "transaction", "transactions",
                     "itinerary", "itineraries", "refund", "refunds", "returns"] {
            words[word] = .transactions
        }
        for word in ["deals", "offers", "marketing", "promo", "promos", "promotion", "promotions", "specials", "coupons",
                     "discounts", "rewards", "shop", "mkt", "ads", "advertising", "campaign", "campaigns"] {
            words[word] = .promotions
        }
        for word in ["notification", "notifications", "notify", "notifier", "alert", "alerts", "update", "updates", "news",
                     "newsletter", "newsletters", "digest", "digests", "mailer", "mailers", "automated", "robot", "daemon",
                     "system", "reminder", "reminders", "survey", "surveys", "invitations", "invites", "notice", "notices",
                     "announce", "announcements", "welcome", "report", "reports", "listserv", "majordomo", "mailman",
                     "bounce", "bounces"] {
            words[word] = .updates
        }
        return words
    }()

    /// Words that go with role words in an address without saying what kind of mail it is ("auto-confirm",
    /// "customer-service"). An address made only of these (info@, support@, hello@) isn't a role address: people
    /// answer them.
    static let serviceWords: Set<String> = [
        "no", "not", "do", "dont", "reply", "noreply", "donotreply", "auto", "e", "mail", "email", "emails", "info", "hello",
        "team", "service", "services", "customer", "customers", "care", "account", "accounts", "my", "online", "web",
        "digital", "app", "mobile", "member", "members", "membership", "club", "community", "help", "support", "contact",
        "message", "messages", "center", "centre", "calendar", "security", "jobs", "events", "official", "status", "desk",
    ]
}

// MARK: - Text

/// A subject or snippet ready for looking up words: lowercase, without accents, with plain apostrophes and single
/// spaces, as UTF-8.
struct CategoryText {
    let bytes: [UInt8]

    init(_ text: String) {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var normalized = ""
        normalized.reserveCapacity(folded.utf8.count)
        var lastWasSpace = true
        for character in folded {
            if character.isWhitespace {
                if !lastWasSpace { normalized.append(" ") }
                lastWasSpace = true
            } else {
                normalized.append(Self.apostrophes.contains(character) ? "'" : character)
                lastWasSpace = false
            }
        }
        if normalized.hasSuffix(" ") { normalized.removeLast() }
        bytes = Array(normalized.utf8)
    }

    private static let apostrophes: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}", "`", "\u{00B4}"]

    /// A subject that answers another ("Re:", "AW:", "SV:", "Re[2]:").
    var isReply: Bool {
        guard let colon = bytes.prefix(10).firstIndex(of: UInt8(ascii: ":")) else { return false }
        let letters = bytes[..<colon].filter { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
        return Self.replyPrefixes.contains(String(decoding: letters, as: UTF8.self))
    }

    private static let replyPrefixes: Set<String> = ["re", "aw", "sv", "antw", "odp", "rif", "res"]

    /// A one-time code: a number of 4 to 8 digits on its own, and the word "code" (or PIN, passcode, OTP), not a
    /// coupon's.
    var hasOneTimeCode: Bool {
        guard Phrases.codeWords.matches(self) else { return false }
        var index = 0
        while index < bytes.count {
            guard Self.isDigit(bytes[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            let startsAlone = start == 0 || !Self.isWordByte(bytes[start - 1])
            let endsAlone = index == bytes.count || !Self.isWordByte(bytes[index])
            if startsAlone, endsAlone, (4...8).contains(index - start) { return true }
        }
        return false
    }

    /// An amount of money off: "$20 off", "15€ off" ("20% off" is one of the promotion phrases).
    var hasAmountOff: Bool {
        var from = 0
        while let range = PhraseList.find([Array(" off".utf8)], in: bytes, from: from) {
            from = range.lowerBound + 1
            // The word before " off", back to the space before it.
            var start = range.lowerBound
            while start > 0, bytes[start - 1] != UInt8(ascii: " ") { start -= 1 }
            let word = bytes[start..<range.lowerBound]
            guard word.contains(where: Self.isDigit) else { continue }
            let text = String(decoding: word, as: UTF8.self)
            if text.contains(where: { "$€£¥".contains($0) }) { return true }
        }
        return false
    }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    /// Part of a word: a letter or digit (bytes beyond ASCII are letters of other scripts).
    static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }
}

/// Words and phrases to look for in a `CategoryText`, each as whole words. A "*" stands for any one word, so
/// "your * order" finds "your amazon.com order". Exceptions are taken out of the text first, so with "off your order"
/// among them, "20% off your order" isn't an order.
struct PhraseList: Sendable {
    /// Each phrase, in pieces between its "*"s.
    private let phrases: [[[UInt8]]]
    private let exceptions: [[UInt8]]

    init(_ phrases: [String], except exceptions: [String] = []) {
        self.phrases = phrases.map { phrase in phrase.components(separatedBy: " * ").map { Array($0.utf8) } }
        self.exceptions = exceptions.map { Array($0.utf8) }
    }

    func matches(_ text: CategoryText) -> Bool {
        var bytes = text.bytes
        for exception in exceptions {
            var from = 0
            while let range = Self.find([exception], in: bytes, from: from) {
                for index in range { bytes[index] = UInt8(ascii: "|") }
                from = range.upperBound
            }
        }
        return phrases.contains { Self.find($0, in: bytes, from: 0) != nil }
    }

    /// Where a phrase (its pieces between "*"s) first appears as whole words, at or after `from`.
    static func find(_ pieces: [[UInt8]], in bytes: [UInt8], from: Int) -> Range<Int>? {
        guard let first = pieces.first, !first.isEmpty, from < bytes.count else { return nil }
        for position in max(0, from)..<bytes.count {
            if let end = match(pieces, in: bytes, at: position) { return position..<end }
        }
        return nil
    }

    /// Where a phrase that starts at `position` ends, or nil when it doesn't start there as whole words.
    private static func match(_ pieces: [[UInt8]], in bytes: [UInt8], at position: Int) -> Int? {
        guard let first = pieces.first, let firstByte = first.first, Self.bytes(bytes, at: position, startWith: first) else {
            return nil
        }
        if CategoryText.isWordByte(firstByte), position > 0, CategoryText.isWordByte(bytes[position - 1]) { return nil }
        let space = UInt8(ascii: " ")
        var end = position + first.count
        for piece in pieces.dropFirst() {
            // A space, one word, a space, then the piece.
            guard end < bytes.count, bytes[end] == space else { return nil }
            var wordEnd = end + 1
            while wordEnd < bytes.count, bytes[wordEnd] != space { wordEnd += 1 }
            guard wordEnd > end + 1, Self.bytes(bytes, at: wordEnd + 1, startWith: piece) else { return nil }
            end = wordEnd + 1 + piece.count
        }
        if let last = pieces.last?.last, CategoryText.isWordByte(last), end < bytes.count, CategoryText.isWordByte(bytes[end]) {
            return nil
        }
        return end
    }

    private static func bytes(_ bytes: [UInt8], at start: Int, startWith piece: [UInt8]) -> Bool {
        guard start >= 0, start + piece.count <= bytes.count else { return false }
        for offset in 0..<piece.count where bytes[start + offset] != piece[offset] { return false }
        return true
    }
}

// MARK: - Phrases

/// What the rules look for in subjects and snippets, in lowercase without accents.
enum Phrases {
    /// Security notices and sign-in codes: Updates, whoever sends them.
    static let security = PhraseList([
        "verification code", "verify your email", "verify your e-mail", "verify your account", "verify your identity",
        "verify your phone", "verify your number", "verify your address", "verify it's you", "verify that it's you",
        "confirm your email", "confirm your e-mail", "confirm your account", "confirm your address",
        "confirm your registration", "confirm your subscription", "confirm your sign-up", "confirm your signup",
        "confirm it's you", "security code", "login code", "log-in code", "log in code", "sign-in code", "sign in code",
        "signin code", "one-time code", "one-time passcode", "one-time password", "one-time pin", "one time code",
        "one time passcode", "one time password", "passcode", "authentication code", "activation code", "recovery code",
        "is your * code", "is your code", "your code is", "your * code is", "2fa", "two-factor", "two factor", "two-step",
        "2-step", "multi-factor", "password reset", "reset your password", "forgot your password", "forgot password",
        "new password", "password change", "password changed", "password was changed", "password has been changed",
        "password updated", "password expires", "password expiring", "new sign-in", "new sign in", "new login",
        "new log-in", "sign-in attempt", "sign in attempt", "login attempt", "log-in attempt", "signed in", "sign-in from",
        "login from", "new device", "unusual activity", "unusual sign-in", "unusual login", "suspicious activity",
        "suspicious sign-in", "suspicious login", "security alert", "security notice", "security notification",
        "account locked", "account suspended", "account disabled", "account recovery", "recovery email",
        "activate your account", "magic link", "sign-in link", "login link",
    ], except: codeExceptions)

    /// Receipts, orders, shipping, bills, payments, bookings, refunds and renewals.
    static let transactions = PhraseList([
        // Orders and purchases
        "your order", "your * order", "order confirmation", "order confirmed", "order received", "order number",
        "order no", "order #", "order status", "order update", "order details", "order summary", "order receipt",
        "order has", "order is", "order was", "order placed", "thanks for your order", "thank you for your order",
        "ordered:", "you ordered", "purchase confirmation", "purchase receipt", "your purchase", "thanks for your purchase",
        "thank you for your purchase", "ready for pickup", "ready for pick up", "ready to pick up", "pickup confirmation",
        // Receipts, invoices, bills and statements
        "receipt", "receipts", "e-receipt", "ereceipt", "invoice", "invoices", "your bill", "your * bill",
        "bill is ready", "bill is available", "new bill", "bill due", "bill reminder", "billing statement",
        "statement is ready", "statement is available", "statement is now available", "new statement", "your statement",
        "your * statement", "e-statement", "estatement", "amount due", "balance due", "autopay", "auto-pay",
        "automatic payment",
        // Payments and money
        "payment received", "payment confirmation", "payment confirmed", "payment processed", "payment successful",
        "payment was successful", "payment scheduled", "payment sent", "payment failed", "payment declined",
        "payment reminder", "payment is due", "payment due", "your payment", "your * payment", "we received your payment",
        "payment to", "payment from", "you sent $", "you sent a payment", "you paid", "you received $", "you've received $",
        "you have received $", "you received a payment", "you've received a payment", "you've been paid", "you've got money",
        "sent you $", "sent you money", "paid you", "requested $", "money request",
        "transfer received", "transfer sent", "transfer complete", "transfer completed", "transfer confirmation",
        "direct deposit", "deposit received", "deposit confirmation", "transaction alert", "transaction receipt",
        "transaction confirmation", "purchase alert", "card was charged", "has been charged", "you've been charged",
        "payment method",
        // Shipping and delivery
        "has shipped", "have shipped", "was shipped", "has been shipped", "shipped:", "shipping confirmation",
        "shipping update", "shipping notification", "shipment", "shipments", "out for delivery", "was delivered",
        "been delivered", "delivered:", "delivery update", "delivery scheduled", "delivery attempt",
        "delivery notification", "delivery confirmation", "delivery estimate", "arriving today", "arriving tomorrow",
        "arriving soon", "arrives today", "arrives tomorrow", "your * is on its way", "on its way to you",
        "tracking number", "tracking info", "tracking information", "track your package", "track your order",
        "track your shipment", "your package", "your parcel", "your shipment", "your delivery",
        // Travel, bookings, tickets and appointments
        "booking confirmation", "booking confirmed", "booking reference", "booking details", "your booking",
        "your * booking", "booking #", "reservation confirmation", "reservation confirmed", "reservation reminder",
        "your reservation", "your * reservation", "reservation #", "itinerary", "e-ticket", "eticket", "your e-ticket",
        "your tickets", "tickets for", "ticket confirmation", "boarding pass", "check in for your flight",
        "check-in for your flight", "time to check in", "check-in is open", "flight confirmation", "your flight",
        "your trip", "trip confirmation", "rental confirmation", "your stay", "upcoming stay", "upcoming trip",
        "upcoming reservation", "upcoming booking", "appointment confirmation", "appointment confirmed",
        "appointment reminder", "your appointment",
        // Refunds, returns and renewals
        "refund", "refunded", "refunds", "return received", "return label", "your return", "return confirmation",
        "renewal", "renewal notice", "renewal reminder", "will renew", "renews on", "auto-renew", "auto renew",
        "has been renewed", "was renewed", "subscription renewed", "subscription receipt", "subscription payment",
        "subscription confirmation", "subscription expires", "subscription expiring", "subscription has expired",
        "subscription cancelled", "subscription canceled", "trial ends", "trial is ending", "trial ending",
    ], except: [
        "off your order", "on your order", "to your order", "your next order", "your first order", "first order",
        "next order", "on orders", "order now", "order today", "order by", "order online", "orders over", "on all orders",
        "every order", "any order", "pre-order now", "preorder now", "your next trip", "your next stay", "your dream trip",
        "plan your trip", "book your trip", "your next booking", "free shipping", "free delivery", "free returns",
    ])

    /// Marketing: sales, offers, coupons, new things to buy.
    static let promotions = PhraseList([
        "% off", "percent off", "sale", "sales event", "flash sale", "clearance", "deals", "deal of the day",
        "deal of the week", "daily deal", "deal alert", "today's deal", "hot deal", "exclusive deal", "special offer",
        "special offers", "exclusive offer", "limited-time offer", "limited time offer", "offer ends", "offers",
        "today only", "one day only", "weekend only", "limited time", "limited-time", "last chance", "ends tonight",
        "ends today", "ends soon", "ending soon", "final hours", "hours left", "don't miss", "dont miss", "coupon",
        "coupons", "promo", "promo code", "promocode", "discount", "discounts", "free shipping", "free delivery",
        "free gift", "start your free trial", "start a free trial", "try it free", "new arrivals", "just dropped",
        "just landed", "shop now", "shop the", "shop our", "shop new", "buy now", "order now", "book now", "save up to",
        "save $", "save big", "big savings", "exclusive savings", "% savings", "bogo", "buy one get one", "half price",
        "half off", "black friday", "cyber monday", "lowest price", "lowest prices", "best price", "price drop",
        "back in stock", "gift guide", "gift ideas", "early access", "exclusive access", "members only",
        "member exclusive", "vip", "treat yourself", "your cart", "in your cart", "left something", "sitewide",
        "storewide", "doorbuster", "doorbusters", "new collection", "new season", "subscribe and save",
        "special pricing", "upgrade now",
    ])

    /// Social networks' notifications.
    static let social = PhraseList([
        "tagged you", "tagged a photo of you", "mentioned you in a post", "mentioned you in their story",
        "mentioned you in a story", "mentioned you in a tweet", "mentioned you in a photo", "mentioned you in a video",
        "commented on your post", "commented on your photo", "commented on your status", "commented on your video",
        "commented on your story", "commented on your reel", "commented on your tweet", "replied to your comment",
        "replied to your post", "replied to your tweet", "replied to your story", "liked your", "loved your",
        "reacted to your", "new follower", "new followers", "started following you", "is now following you",
        "followed you", "follows you", "friend request", "friend requests", "friend suggestion", "friend suggestions",
        "people you may know", "wants to be friends", "added you as a friend", "accepted your friend request",
        "wants to connect", "invitation to connect", "invited you to connect", "accepted your invitation to connect",
        "connection request", "new connections", "endorsed you", "viewed your profile", "profile views", "poked you",
        "shared a post", "shared a photo", "shared a video", "posted a photo", "posted a video", "posted a new photo",
        "added a new photo", "sent you a friend",
    ])

    /// What a receipt or shipping notice says in its first lines.
    static let transactionDetails = PhraseList([
        "order number", "order #", "order no", "order total", "tracking number", "receipt", "invoice", "amount paid",
        "amount charged", "total charged", "total paid", "grand total", "subtotal", "payment method", "paid with",
        "charged to", "billed to", "confirmation number", "booking reference", "reservation number", "has shipped",
        "was delivered", "out for delivery",
    ])

    /// The words a one-time code comes with.
    static let codeWords = PhraseList(["code", "passcode", "pin", "otp"], except: codeExceptions)

    /// Codes that aren't for signing in.
    static let codeExceptions = [
        "promo code", "coupon code", "discount code", "gift code", "voucher code", "referral code", "offer code",
        "bonus code", "use code", "with code", "zip code", "postal code", "dress code", "source code", "qr code",
    ]
}
