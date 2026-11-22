#if DEBUG
import AppKit
import ImageIO
import PMailKit

/// Made-up accounts, mail, calendars and contacts for debug runs, snapshots and the self-test, so PMail can be tried
/// without signing in to anything. Everything is placed relative to "today".
enum SampleData {
    static let googleID = UUID(uuidString: "5E000000-0000-0000-0000-000000000001")!
    static let microsoftID = UUID(uuidString: "5E000000-0000-0000-0000-000000000002")!
    static let iCloudID = UUID(uuidString: "5E000000-0000-0000-0000-000000000003")!

    static var accounts: [Account] {
        let iCloud = ServerPresets.iCloud(email: "jamie@example.net")
        return [
            Account(id: googleID, kind: .google, name: "Jamie Rivera", email: "jamie.rivera@example.com", colorIndex: 2,
                    signature: "Jamie"),
            Account(id: microsoftID, kind: .microsoft, name: "Jamie Rivera", email: "jrivera@example.org", colorIndex: 4,
                    signature: "Jamie Rivera\nProduct Designer, Pawprint Studio"),
            Account(id: iCloudID, kind: .icloud, name: "Jamie Rivera", email: "jamie@example.net", colorIndex: 0,
                    incoming: iCloud.incoming, outgoing: iCloud.outgoing, calendarServer: iCloud.calendar, contactsServer: iCloud.contacts,
                    serverLoginName: iCloud.login),
        ]
    }

    // MARK: People

    struct Person {
        let name: String
        let email: String
        var company = ""
        var title = ""
        var phone = ""
        var labels: [String] = []
        var starred = false
    }

    static let people: [Person] = [
        Person(name: "Alex Kim", email: "alex.kim@example.com", company: "Pawprint Studio", title: "Engineering Lead", phone: "(503) 555-0142",
               labels: ["Work"], starred: true),
        Person(name: "Priya Shah", email: "priya@example.com", company: "Pawprint Studio", title: "Product Manager", phone: "(503) 555-0178",
               labels: ["Work"]),
        Person(name: "Marcus Lee", email: "marcus.lee@example.com", company: "Northwind Outfitters", title: "Account Director",
               phone: "(206) 555-0110", labels: ["Work"]),
        Person(name: "Grandma Rose", email: "rose.rivera@example.net", phone: "(541) 555-0199", labels: ["Family"], starred: true),
        Person(name: "Sam Rivera", email: "sam.rivera@example.net", phone: "(503) 555-0123", labels: ["Family"], starred: true),
        Person(name: "Olivia Chen", email: "olivia.chen@example.com", company: "Bluebird Bakery", title: "Owner", phone: "(503) 555-0161"),
        Person(name: "Dr. Nina Patel", email: "frontdesk@happytailsvet.example", company: "Happy Tails Veterinary", title: "Veterinarian",
               phone: "(503) 555-0190", labels: ["Puppy School"]),
        Person(name: "Coach Dana", email: "dana@goodpuppyschool.example", company: "Good Puppy School", title: "Trainer",
               phone: "(503) 555-0105", labels: ["Puppy School"]),
        Person(name: "Leo Martins", email: "leo.martins@example.com", company: "Pawprint Studio", title: "Designer", labels: ["Work"]),
        Person(name: "Hannah Brooks", email: "hannah.b@example.org", company: "City Library", title: "Librarian", phone: "(503) 555-0137"),
        Person(name: "Ethan Wright", email: "ethan.wright@example.com", company: "Trailhead Running Club", title: "Organizer"),
        Person(name: "Maya Johnson", email: "maya.j@example.net", phone: "(971) 555-0150", labels: ["Family"]),
        Person(name: "Carlos Gomez", email: "carlos@example.com", company: "Gomez Landscaping", title: "Owner", phone: "(503) 555-0188"),
        Person(name: "Zoe Anderson", email: "zoe.anderson@example.org", company: "Pawprint Studio", title: "Researcher", labels: ["Work"]),
        Person(name: "Ben Turner", email: "ben.turner@example.com", company: "Turner & Co. Accounting", title: "Accountant"),
        Person(name: "Aisha Rahman", email: "aisha.rahman@example.com", company: "Pawprint Studio", title: "Data Scientist", labels: ["Work"]),
        Person(name: "Noah Fischer", email: "noah.f@example.net", title: "Neighbor", phone: "(503) 555-0174"),
        Person(name: "Lily Nguyen", email: "lily.nguyen@example.com", company: "Sunrise Yoga", title: "Instructor"),
        Person(name: "Owen Price", email: "owen.price@example.org", company: "Riverside Realty", title: "Agent", phone: "(503) 555-0155"),
        Person(name: "Waffles' Groomer", email: "hello@sudsandpups.example", company: "Suds & Pups", phone: "(503) 555-0101",
               labels: ["Puppy School"]),
    ]

    static func person(_ name: String) -> MailAddress {
        let match = people.first { $0.name == name }
        return MailAddress(name: name, email: match?.email ?? "\(name.lowercased().replacingOccurrences(of: " ", with: "."))@example.com")
    }

    /// People in the sample Google and Microsoft accounts' organization directories, who aren't in their contacts.
    static func directory(for account: Account) -> [Contact] {
        switch account.kind {
        case .google:
            [Contact(givenName: "Taylor", familyName: "Brooks", company: "Pawprint Studio", jobTitle: "Product Designer", department: "Design",
                     emails: [LabeledValue(label: "work", value: "taylor.brooks@pawprint.example")],
                     phones: [LabeledValue(label: "work", value: "(503) 555-0161")])]
        case .microsoft:
            [Contact(givenName: "Jordan", familyName: "Lee", company: "Northwind Traders", jobTitle: "Account Manager",
                     emails: [LabeledValue(label: "work", value: "jordan.lee@northwind.example")],
                     phones: [LabeledValue(label: "work", value: "(425) 555-0177")])]
        default:
            []
        }
    }

    static func contacts(for account: Account) -> [Contact] {
        let subset: [Person] = switch account.kind {
        case .microsoft: Array(people.filter { $0.labels.contains("Work") || $0.company.contains("Northwind") || $0.company.contains("Turner") })
        case .icloud: Array(people.filter { $0.labels.contains("Family") || $0.labels.contains("Puppy School") || $0.phone.contains("01") })
        default: people
        }
        var contacts = subset.enumerated().map { index, person -> Contact in
            let parts = person.name.split(separator: " ")
            let given = parts.count > 1 ? parts.dropLast().joined(separator: " ") : person.name
            let family = parts.count > 1 ? String(parts.last!) : ""
            return Contact(id: "sample-contact-\(account.kind.rawValue)-\(index)", givenName: given, familyName: family,
                           company: person.company, jobTitle: person.title,
                           emails: [LabeledValue(label: person.labels.contains("Work") ? "work" : "home", value: person.email)],
                           phones: person.phone.isEmpty ? [] : [LabeledValue(label: "mobile", value: person.phone)],
                           addresses: index % 4 == 0 ? [PostalAddress(label: "home", street: "\(100 + index * 7) Maple Street", city: "Portland",
                                                                     region: "OR", postalCode: "97205", country: "United States")] : [],
                           birthday: index % 5 == 0 ? DateComponents(month: (index % 12) + 1, day: (index * 3 % 27) + 1) : nil,
                           notes: index == 3 ? "Loves Waffles. Bakes the best lemon bars." : "",
                           labels: person.labels, isStarred: person.starred)
        }
        if account.kind == .google {
            contacts += ["newsletter@trailmix.example", "orders@shop.example", "noreply@citylibrary.example"].enumerated().map { index, email in
                Contact(id: "sample-other-\(index)", kind: .other, emails: [LabeledValue(value: email)])
            }
        }
        return contacts
    }

    // MARK: Mail

    /// A sample message and where it is.
    struct Message {
        var summary: MessageSummary
        var html: String?
        var text: String?
        var attachments: [Attachment] = []
        var inline: [Attachment] = []
    }

    static func mail(for account: Account, today: Date) -> (folders: [MailFolder], messages: [Message]) {
        switch account.kind {
        case .google: googleMail(account, today: today)
        case .microsoft: microsoftMail(account, today: today)
        default: iCloudMail(account, today: today)
        }
    }

    private static func date(_ today: Date, daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: today)) ?? today
        let result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        // Today's messages are never in the future.
        return daysAgo == 0 && result > today ? today.addingTimeInterval(-Double((hour * 60 + minute) % 300) * 60 - 60) : result
    }

    nonisolated static let samplePicture: Data = {
        // A small orange paw on cream, drawn once, for pictures inside messages and attachments.
        let size = 120
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                var inside = false
                let pads: [(Double, Double, Double)] = [(60, 72, 26), (30, 42, 11), (48, 28, 12), (72, 28, 12), (90, 42, 11)]
                for pad in pads where hypot(Double(x) - pad.0, Double(y) - pad.1) < pad.2 { inside = true }
                pixels[i] = inside ? 0xFF : 0xFF
                pixels[i + 1] = inside ? 0xB0 : 0xF4
                pixels[i + 2] = inside ? 0x20 : 0xE0
                pixels[i + 3] = 0xFF
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let data = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return data as Data
    }()

    private static func newsletter(title: String, body: String, button: String, color: String) -> String {
        """
        <html><head><style>.card{max-width:560px;margin:0 auto;font-family:Helvetica,Arial,sans-serif}</style></head><body>
        <div class="card"><div style="background:\(color);color:white;padding:24px;border-radius:12px 12px 0 0">
        <h1 style="margin:0;font-size:24px">\(title)</h1></div>
        <div style="border:1px solid #e3e3e3;border-top:none;padding:24px;border-radius:0 0 12px 12px;color:#333;font-size:15px;line-height:1.5">
        <p>\(body)</p>
        <img src="https://images.example.com/hero.jpg" width="1" height="1" alt="">
        <p style="text-align:center;margin-top:24px"><a href="https://example.com" style="background:\(color);color:white;padding:12px 22px;border-radius:24px;text-decoration:none">\(button)</a></p>
        <p style="font-size:12px;color:#888;margin-top:28px">You’re getting this because you signed up. <a href="https://example.com/unsubscribe">Unsubscribe</a></p>
        </div></div></body></html>
        """
    }

    private static func googleMail(_ account: Account, today: Date) -> ([MailFolder], [Message]) {
        let me = account.address
        let folders = [
            MailFolder(id: "INBOX", name: "INBOX", role: .inbox, kind: .label),
            MailFolder(id: "STARRED", name: "STARRED", role: .starred, kind: .label),
            MailFolder(id: "SNOOZED", name: "SNOOZED", role: .snoozed, kind: .label),
            MailFolder(id: "IMPORTANT", name: "IMPORTANT", role: .important, kind: .label),
            MailFolder(id: "SENT", name: "SENT", role: .sent, kind: .label),
            MailFolder(id: "DRAFT", name: "DRAFT", role: .drafts, kind: .label),
            MailFolder(id: "SPAM", name: "SPAM", role: .spam, kind: .label),
            MailFolder(id: "TRASH", name: "TRASH", role: .trash, kind: .label),
            MailFolder(id: "Label_work", name: "Work", kind: .label, colorHex: "#16A766"),
            MailFolder(id: "Label_family", name: "Family", kind: .label, colorHex: "#F691B2"),
            MailFolder(id: "Label_receipts", name: "Receipts", kind: .label, colorHex: "#FFAD47"),
            MailFolder(id: "Label_travel", name: "Travel", kind: .label, colorHex: "#4A86E8"),
            MailFolder(id: "Label_travel_2026", name: "2026", kind: .label, parentID: "Label_travel", colorHex: "#4A86E8"),
            MailFolder(id: "Label_puppy", name: "Puppy School", kind: .label, colorHex: "#B694E8"),
        ]
        var messages: [Message] = []
        var counter = 0
        func add(from: MailAddress, to: [MailAddress]? = nil, cc: [MailAddress] = [], subject: String, text: String? = nil, html: String? = nil,
                 daysAgo: Int, hour: Int, minute: Int = 0, labels: [String], unread: Bool = false, starred: Bool = false, important: Bool = false,
                 thread: String? = nil, attachments: [Attachment] = [], inline: [Attachment] = []) {
            counter += 1
            let id = "g\(counter)"
            let body = text ?? html.map(HTMLText.plainText(fromHTML:)) ?? ""
            var summary = MessageSummary(id: id, threadID: thread ?? id, labelIDs: labels + (unread ? ["UNREAD"] : []), from: from,
                                         to: to ?? [me], cc: cc, subject: subject, snippet: HTMLText.snippet(from: body),
                                         date: date(today, daysAgo: daysAgo, hour: hour, minute: minute), isUnread: unread,
                                         isStarred: starred, isImportant: important, isDraft: labels.contains("DRAFT"),
                                         hasAttachments: !attachments.isEmpty, messageIDHeader: "<\(id)@example.com>")
            if let thread, thread != id { summary.references = ["<\(thread)@example.com>"]; summary.inReplyTo = "<\(thread)@example.com>" }
            messages.append(Message(summary: summary, html: html, text: text, attachments: attachments, inline: inline))
        }
        let alex = person("Alex Kim"), priya = person("Priya Shah"), rose = person("Grandma Rose"), sam = person("Sam Rivera")
        let olivia = person("Olivia Chen"), vet = person("Dr. Nina Patel"), dana = person("Coach Dana"), leo = person("Leo Martins")
        let hannah = person("Hannah Brooks"), ethan = person("Ethan Wright"), maya = person("Maya Johnson"), zoe = person("Zoe Anderson")
        let ben = person("Ben Turner"), aisha = person("Aisha Rahman"), groomer = person("Waffles' Groomer"), owen = person("Owen Price")
        let paw = Attachment(id: "2", filename: "waffles-certificate.png", mimeType: "image/png", size: samplePicture.count, data: samplePicture)
        let pdf = Attachment(id: "3", filename: "Q4 roadmap.pdf", mimeType: "application/pdf", size: 248_000,
                             data: Data("%PDF-1.4\n% sample\n".utf8))

        add(from: alex, cc: [priya, leo], subject: "Design review moved to Thursday",
            text: "Hi Jamie,\n\nQuick heads-up: the design review is now Thursday at 2pm so Priya can join. Same room, and there's a video link on the invite.\n\nCan you bring the onboarding flows? Leo has the latest prototypes.\n\nThanks!\nAlex",
            daysAgo: 0, hour: 9, minute: 12, labels: ["INBOX", "CATEGORY_PERSONAL", "IMPORTANT", "Label_work"], unread: true, important: true, thread: "t-review")
        add(from: rose, subject: "Thanksgiving pie plans 🥧",
            text: "Hello sweetheart,\n\nI'm making the pecan pie again this year, and the lemon bars, of course. Could you bring a salad? Sam says he'll bring rolls.\n\nGive Waffles a scratch behind the ears for me.\n\nLove,\nGrandma",
            daysAgo: 0, hour: 8, minute: 3, labels: ["INBOX", "CATEGORY_PERSONAL", "Label_family"], unread: true, starred: true)
        add(from: vet, subject: "Reminder: Waffles' checkup on Tuesday",
            text: "Hi Jamie,\n\nThis is a reminder that Waffles has a wellness checkup on Tuesday at 10:30 AM with Dr. Patel.\n\nPlease bring a fresh stool sample and his vaccination record. Reply to this email if you need to reschedule.\n\nHappy Tails Veterinary",
            daysAgo: 0, hour: 7, minute: 45, labels: ["INBOX", "CATEGORY_UPDATES", "Label_puppy"], unread: true)
        add(from: priya, to: [me, alex], subject: "Q4 roadmap draft",
            html: "<p>Hi both,</p><p>Here's the <b>Q4 roadmap draft</b>. The big items:</p><ul><li>Offline reading</li><li>Snooze and scheduled send</li><li>Calendar invitations</li></ul><p>Comments by Friday would be great.</p><p>Priya</p>",
            daysAgo: 1, hour: 16, minute: 20, labels: ["INBOX", "CATEGORY_PERSONAL", "Label_work"], starred: true, thread: "t-roadmap", attachments: [pdf])
        add(from: me, to: [priya], cc: [alex], subject: "Re: Q4 roadmap draft",
            text: "Looks great! I'd move calendar invitations up; people keep asking.\n\nJamie", daysAgo: 1, hour: 17, minute: 2,
            labels: ["SENT", "Label_work"], thread: "t-roadmap")
        add(from: priya, to: [me, alex], subject: "Re: Q4 roadmap draft", text: "Good call, moved it up. Thanks Jamie!", daysAgo: 0, hour: 6, minute: 50,
            labels: ["INBOX", "CATEGORY_PERSONAL", "Label_work"], unread: true, thread: "t-roadmap")
        add(from: dana, subject: "Puppy class: week 4 homework",
            html: "<p>Hi pup parents!</p><p>Great job this week. Homework: practice <i>stay</i> for 30 seconds, three times a day, and <i>leave it</i> with a favorite toy.</p><p>Waffles did especially well with <b>sit</b>. See you Saturday!</p><img src=\"cid:paw\" width=\"60\" height=\"60\" alt=\"paw\"><p>Coach Dana</p>",
            daysAgo: 1, hour: 11, labels: ["INBOX", "CATEGORY_PERSONAL", "Label_puppy"],
            inline: [Attachment(id: "1.2", filename: "paw.png", mimeType: "image/png", size: samplePicture.count, contentID: "paw", isInline: true, data: samplePicture)])
        add(from: olivia, subject: "Your order is ready for pickup", text: "Hi Jamie, your sourdough loaf and two cinnamon rolls are ready. We're open until 6. — Bluebird Bakery",
            daysAgo: 1, hour: 9, labels: ["INBOX", "CATEGORY_UPDATES", "Label_receipts"])
        add(from: sam, subject: "Hiking Saturday?", text: "Want to do Dog Mountain this weekend? Waffles is invited obviously. I can drive.",
            daysAgo: 2, hour: 19, minute: 33, labels: ["INBOX", "CATEGORY_PERSONAL", "Label_family"], thread: "t-hike")
        add(from: me, to: [sam], subject: "Re: Hiking Saturday?", text: "Yes! Let's leave at 8. I'll bring snacks.", daysAgo: 2, hour: 20,
            labels: ["SENT", "Label_family"], thread: "t-hike")
        add(from: sam, subject: "Re: Hiking Saturday?", text: "Perfect, see you then 🥾", daysAgo: 2, hour: 20, minute: 15,
            labels: ["INBOX", "CATEGORY_PERSONAL", "Label_family"], thread: "t-hike")
        add(from: MailAddress(name: "Trail Mix Weekly", email: "newsletter@trailmix.example"), subject: "10 dog-friendly hikes for late fall",
            html: newsletter(title: "Trail Mix Weekly", body: "Crisp air, golden larches and muddy paws. Here are ten dog-friendly hikes that shine in late fall, from easy loops to lung-busting climbs.", button: "Read the list", color: "#2E7D32"),
            daysAgo: 2, hour: 7, labels: ["INBOX", "CATEGORY_PROMOTIONS"])
        add(from: MailAddress(name: "Cozy Paws Shop", email: "deals@cozypaws.example"), subject: "Up to 40% off winter dog jackets",
            html: newsletter(title: "Winter is coming 🧥", body: "Keep your pup toasty with our softest jackets yet, now up to 40% off for one week only.", button: "Shop jackets", color: "#C2185B"),
            daysAgo: 1, hour: 6, labels: ["INBOX", "CATEGORY_PROMOTIONS"], unread: true)
        add(from: MailAddress(name: "City Library", email: "noreply@citylibrary.example"), subject: "Your hold is ready: The Art of Raising a Puppy",
            text: "Your hold is ready for pickup at Central Library. It will be held for 7 days.", daysAgo: 3, hour: 10, labels: ["INBOX", "CATEGORY_UPDATES"])
        add(from: MailAddress(name: "Neighborhood Pups", email: "group@neighborhoodpups.example"), subject: "Who's up for a park meetup Sunday?",
            text: "We're meeting at Laurelhurst Park at 10. Bring treats and poop bags!", daysAgo: 3, hour: 14, labels: ["INBOX", "CATEGORY_SOCIAL"])
        add(from: MailAddress(name: "PupPals", email: "notifications@puppals.example"), subject: "Biscuit and 3 others liked Waffles' photo",
            text: "Biscuit, Mochi, Pickles and Bean liked your photo “Waffles meets the ocean”.", daysAgo: 1, hour: 21, labels: ["INBOX", "CATEGORY_SOCIAL"], unread: true)
        add(from: leo, cc: [alex], subject: "Prototype links for Thursday", text: "Here are the latest prototypes: https://example.com/proto/onboarding-v7\n\nThe empty states are new.",
            daysAgo: 3, hour: 15, minute: 40, labels: ["INBOX", "CATEGORY_PERSONAL", "Label_work"])
        add(from: hannah, subject: "Book club pick for December", text: "We're reading “The Wild Robot” for December. Hope you can make it on the 12th!",
            daysAgo: 4, hour: 12, labels: ["INBOX", "CATEGORY_PERSONAL"])
        add(from: ethan, subject: "Turkey Trot 5K registration", text: "Registration closes Monday. Team Pawprint has 6 runners so far.", daysAgo: 4, hour: 8,
            labels: ["INBOX", "CATEGORY_PERSONAL"], starred: true)
        add(from: maya, subject: "Photos from the beach day", text: "Attaching my favorite one of Waffles chasing the waves 🌊", daysAgo: 5, hour: 18,
            labels: ["INBOX", "CATEGORY_PERSONAL", "Label_family"], attachments: [paw])
        add(from: zoe, to: [me, aisha], subject: "Interview notes from the pilot", text: "Five interviews done. Biggest theme: people want their calendar and inbox in one place.",
            daysAgo: 5, hour: 13, labels: ["INBOX", "CATEGORY_PERSONAL", "Label_work"])
        add(from: ben, subject: "Documents for your tax appointment", text: "Please send your 1099s and the mortgage statement before our meeting on the 4th.",
            daysAgo: 6, hour: 10, labels: ["INBOX", "CATEGORY_PERSONAL"], important: true)
        add(from: groomer, subject: "Waffles is booked for a bath 🛁", text: "See you next Friday at 3pm! Reply STOP to cancel reminders.", daysAgo: 7, hour: 9,
            labels: ["INBOX", "CATEGORY_UPDATES", "Label_puppy"])
        add(from: MailAddress(name: "Sky Airlines", email: "itinerary@skyair.example"), subject: "Your trip to Denver: confirmation K7Q2LM",
            text: "Thanks for booking. PDX → DEN, December 18, 7:05 AM. Seat 14C.", daysAgo: 9, hour: 11, labels: ["INBOX", "CATEGORY_UPDATES", "Label_travel", "Label_travel_2026"], starred: true)
        add(from: owen, subject: "Open house this Sunday", text: "The bungalow on Elm is open Sunday 1–3. It has a fenced yard Waffles would love.", daysAgo: 10, hour: 16,
            labels: ["INBOX", "CATEGORY_PERSONAL"])
        add(from: aisha, subject: "Dashboard numbers for November", text: "Weekly active users are up 12%. Charts attached in the deck.", daysAgo: 12, hour: 9,
            labels: ["INBOX", "CATEGORY_PERSONAL", "Label_work"])
        add(from: MailAddress(name: "Bluebird Bakery", email: "orders@bluebird.example"), subject: "Receipt for your order #4412", text: "Sourdough loaf $8.00\nCinnamon rolls (2) $9.00\nTotal $17.00",
            daysAgo: 14, hour: 8, labels: ["Label_receipts"])
        add(from: me, to: [rose], subject: "Re: Thanksgiving pie plans 🥧", text: "I'll bring the salad! Can't wait. ❤️", daysAgo: 0, hour: 8, minute: 40,
            labels: ["DRAFT"])
        add(from: me, to: [ethan], subject: "Turkey Trot team shirts", text: "What if the team shirts had a paw print on them?", daysAgo: 3, hour: 22,
            labels: ["DRAFT"])
        add(from: MailAddress(name: "Prize Center", email: "winner@totally-legit.example"), subject: "You've WON a $1,000 gift card!!!", text: "Click here to claim now.",
            daysAgo: 1, hour: 3, labels: ["SPAM"])
        add(from: MailAddress(name: "Account Team", email: "security@acc0unt-verify.example"), subject: "Urgent: verify your account", text: "Your account will be closed.",
            daysAgo: 2, hour: 4, labels: ["SPAM"])
        add(from: MailAddress(name: "Old Newsletter", email: "news@oldlist.example"), subject: "Last chance!", text: "This offer ends soon.", daysAgo: 6, hour: 5,
            labels: ["TRASH"])
        // Older mail, so the inbox needs a second page.
        let fillers = ["Weekly team update", "Lunch next week?", "Re: parking at the office", "Photos from the offsite", "Volunteer day signup",
                       "Gym membership renewal", "Your library books are due", "Garden club meeting", "New comment on your doc", "Coffee chat"]
        for index in 0..<44 {
            let sender = [alex, priya, leo, hannah, ethan, zoe, aisha, owen, maya, sam][index % 10]
            add(from: sender, subject: fillers[index % fillers.count], text: "Just following up on this. Let me know what you think when you get a chance.",
                daysAgo: 15 + index * 2, hour: 9 + index % 8, labels: ["INBOX", "CATEGORY_PERSONAL"] + (index % 3 == 0 ? ["Label_work"] : []))
        }
        return (folders, messages)
    }

    private static func microsoftMail(_ account: Account, today: Date) -> ([MailFolder], [Message]) {
        let me = account.address
        let folders = [
            MailFolder(id: "inbox", name: "Inbox", role: .inbox),
            MailFolder(id: "pmail:flagged", name: "Flagged", role: .starred),
            MailFolder(id: "drafts", name: "Drafts", role: .drafts),
            MailFolder(id: "sentitems", name: "Sent Items", role: .sent),
            MailFolder(id: "archive", name: "Archive", role: .archive),
            MailFolder(id: "junkemail", name: "Junk Email", role: .spam),
            MailFolder(id: "deleteditems", name: "Deleted Items", role: .trash),
            MailFolder(id: "projects", name: "Projects"),
            MailFolder(id: "projects-atlas", name: "Atlas", parentID: "projects"),
            MailFolder(id: "clients", name: "Clients"),
        ]
        var messages: [Message] = []
        var counter = 0
        func add(from: MailAddress, to: [MailAddress]? = nil, subject: String, text: String, daysAgo: Int, hour: Int, folder: String,
                 focused: Bool = true, unread: Bool = false, flagged: Bool = false, thread: String? = nil) {
            counter += 1
            let id = "m\(counter)"
            let summary = MessageSummary(id: id, threadID: thread ?? id, folderID: folder, labelIDs: focused ? ["focused"] : ["other"], from: from,
                                         to: to ?? [me], subject: subject, snippet: HTMLText.snippet(from: text),
                                         date: date(today, daysAgo: daysAgo, hour: hour), isUnread: unread, isStarred: flagged,
                                         messageIDHeader: "<\(id)@example.org>")
            messages.append(Message(summary: summary, text: text))
        }
        let marcus = person("Marcus Lee"), alex = person("Alex Kim"), ben = person("Ben Turner"), zoe = person("Zoe Anderson")
        add(from: marcus, subject: "Northwind kickoff agenda", text: "Hi Jamie,\n\nAttached is the agenda for Monday's kickoff. We'll meet on Teams; the link is in the invite.\n\nBest,\nMarcus",
            daysAgo: 0, hour: 8, folder: "inbox", unread: true, flagged: true)
        add(from: alex, subject: "Atlas sprint planning", text: "Sprint planning is Wednesday at 10. Please groom your tickets beforehand.", daysAgo: 0, hour: 7,
            folder: "inbox", unread: true, thread: "atlas")
        add(from: zoe, subject: "Research readout slides", text: "Slides for Friday's readout are in the shared folder.", daysAgo: 1, hour: 15, folder: "inbox")
        add(from: ben, subject: "Invoice 2026-118", text: "Please find the invoice for October attached. Net 30.", daysAgo: 2, hour: 10, folder: "inbox", focused: false)
        add(from: MailAddress(name: "Office Facilities", email: "facilities@example.org"), subject: "Elevator maintenance Saturday",
            text: "The north elevators will be out of service Saturday 8am–2pm.", daysAgo: 2, hour: 9, folder: "inbox", focused: false, unread: true)
        add(from: MailAddress(name: "IT Help Desk", email: "it@example.org"), subject: "Password expires in 7 days", text: "Please change your password before it expires.",
            daysAgo: 3, hour: 8, folder: "inbox", focused: false)
        add(from: marcus, subject: "Re: Statement of work", text: "Signed copy attached. Excited to get started!", daysAgo: 4, hour: 16, folder: "clients")
        add(from: alex, subject: "Atlas architecture notes", text: "Notes from today's architecture session are in the wiki.", daysAgo: 6, hour: 13, folder: "projects-atlas")
        add(from: me, to: [marcus], subject: "Re: Northwind kickoff agenda", text: "Thanks Marcus, looks good. See you Monday.", daysAgo: 0, hour: 8,
            folder: "sentitems")
        for index in 0..<12 {
            add(from: [marcus, alex, zoe, ben][index % 4], subject: ["Status update", "Quick question", "Follow-up", "Meeting notes"][index % 4],
                text: "Sharing a quick update on where things stand this week.", daysAgo: 7 + index * 3, hour: 9 + index % 6, folder: "inbox")
        }
        return (folders, messages)
    }

    private static func iCloudMail(_ account: Account, today: Date) -> ([MailFolder], [Message]) {
        let me = account.address
        let folders = [
            MailFolder(id: "INBOX", name: "INBOX", role: .inbox),
            MailFolder(id: "pmail:starred", name: "Starred", role: .starred),
            MailFolder(id: "Drafts", name: "Drafts", role: .drafts),
            MailFolder(id: "Sent Messages", name: "Sent Messages", role: .sent),
            MailFolder(id: "Archive", name: "Archive", role: .archive),
            MailFolder(id: "Junk", name: "Junk", role: .spam),
            MailFolder(id: "Deleted Messages", name: "Deleted Messages", role: .trash),
            MailFolder(id: "Receipts", name: "Receipts"),
        ]
        var messages: [Message] = []
        var counter = 0
        func add(from: MailAddress, subject: String, text: String, daysAgo: Int, hour: Int, folder: String = "INBOX", unread: Bool = false, starred: Bool = false) {
            counter += 1
            let id = "i\(counter)"
            let summary = MessageSummary(id: id, folderID: folder, from: from, to: [me], subject: subject, snippet: HTMLText.snippet(from: text),
                                         date: date(today, daysAgo: daysAgo, hour: hour), isUnread: unread, isStarred: starred,
                                         messageIDHeader: "<\(id)@example.net>")
            messages.append(Message(summary: summary, text: text))
        }
        add(from: person("Sam Rivera"), subject: "FaceTime tonight?", text: "Mom wants to FaceTime at 7 so she can see Waffles' new haircut.", daysAgo: 0, hour: 10, unread: true)
        add(from: person("Grandma Rose"), subject: "Recipe card", text: "Here's the lemon bar recipe you asked for. Don't skimp on the zest!", daysAgo: 1, hour: 9, starred: true)
        add(from: person("Maya Johnson"), subject: "Saturday brunch", text: "Brunch at Bluebird at 11? I'll save a table on the patio.", daysAgo: 2, hour: 12, unread: true)
        add(from: person("Noah Fischer"), subject: "Package for you", text: "I grabbed a package from your porch so it wouldn't get rained on. Swing by anytime!", daysAgo: 3, hour: 17)
        add(from: MailAddress(name: "App Store", email: "no_reply@email.example"), subject: "Your receipt", text: "Thanks for your purchase.", daysAgo: 5, hour: 8, folder: "Receipts")
        add(from: person("Lily Nguyen"), subject: "Class schedule for December", text: "Sunrise yoga moves to 7:30 starting December 1.", daysAgo: 8, hour: 7)
        return (folders, messages)
    }

    // MARK: Calendars

    static func calendars(for account: Account) -> [CalendarInfo] {
        switch account.kind {
        case .google:
            [CalendarInfo(id: "primary", name: account.name, colorHex: "#129EE0", isPrimary: true, nativeConference: .meet),
             CalendarInfo(id: "family", name: "Family", colorHex: "#2FB57A", nativeConference: .meet),
             CalendarInfo(id: "puppy", name: "Waffles", colorHex: "#F06B1F", nativeConference: .meet),
             CalendarInfo(id: "holidays", name: "Holidays", colorHex: "#188038", isReadOnly: true, isOther: true)]
        case .microsoft:
            [CalendarInfo(id: "calendar", name: "Calendar", colorHex: "#3B5BDB", isPrimary: true, nativeConference: .teams),
             CalendarInfo(id: "birthdays", name: "Birthdays", colorHex: "#9334E6", isReadOnly: true, isOther: true)]
        default:
            [CalendarInfo(id: "home", name: "Home", colorHex: "#2FB57A", isPrimary: true),
             CalendarInfo(id: "work", name: "Work", colorHex: "#D93025")]
        }
    }

    /// The kinds of event each sample calendar holds itself, as the provider's do: a Google account's main calendar holds
    /// out of office and focus time, a Microsoft calendar out of office, and the others only events.
    static func eventTypes(for account: Account) -> [String: Set<EventType>] {
        switch account.kind {
        case .google: ["primary": [.event, .outOfOffice, .focusTime], "family": [.event], "puppy": [.event]]
        case .microsoft: ["calendar": [.event, .outOfOffice]]
        default: ["home": [.event], "work": [.event]]
        }
    }

    static func taskLists(for account: Account) -> [TaskList] {
        switch account.kind {
        case .google: [TaskList(id: "my-tasks", name: "My Tasks", isDefault: true), TaskList(id: "waffles-tasks", name: "Waffles")]
        case .microsoft: [TaskList(id: "tasks", name: "Tasks", isDefault: true)]
        default: []
        }
    }

    static func tasks(for account: Account, today: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let week = CalendarGrid(calendar: calendar).startOfWeek(today)
        var tasks: [CalendarEvent] = []
        func add(_ listID: String, _ title: String, day: Int, notes: String? = nil, done: Bool = false) {
            let date = calendar.date(byAdding: .day, value: day, to: week) ?? week
            tasks.append(TaskDates.event(id: "sample-task-\(account.kind.rawValue)-\(tasks.count + 1)", listID: listID, title: title, notes: notes,
                                         day: date, isCompleted: done))
        }
        switch account.kind {
        case .google:
            add("my-tasks", "Send slides to Priya", day: 2, done: true)
            add("my-tasks", "Renew passport", day: 3, notes: "Photos are in the desk drawer.")
            add("waffles-tasks", "Order dog food", day: 5)
            add("my-tasks", "Book the offsite bus", day: 7)
        case .microsoft:
            add("tasks", "Submit expense report", day: 2)
            add("tasks", "Review the Northwind SOW", day: 4, done: true)
        default:
            break
        }
        return tasks
    }

    /// When a sample person is busy: Alex in the late morning and mid-afternoon, Priya on Tuesday and Thursday mornings
    /// and after lunch, everyone else late on Monday, Wednesday and Friday mornings; Zoe doesn't share her calendar.
    nonisolated static func freeBusy(for address: String, from start: Date, to end: Date) -> FreeBusy {
        let email = address.lowercased()
        if email == "zoe.anderson@example.org" { return .unknown("Their calendar isn’t shared with you.") }
        let calendar = Calendar.current
        var busy: [DateInterval] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            let weekday = calendar.component(.weekday, from: day)
            func block(_ hour: Int, _ minute: Int, minutes: Int) {
                guard let begin = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return }
                let stretch = DateInterval(start: begin, duration: TimeInterval(minutes * 60))
                if stretch.end > start, stretch.start < end { busy.append(stretch) }
            }
            if (2...6).contains(weekday) {
                switch email {
                case "alex.kim@example.com":
                    block(10, 0, minutes: 60)
                    block(14, 0, minutes: 90)
                case "priya@example.com":
                    if weekday == 3 || weekday == 5 { block(9, 0, minutes: 180) }
                    block(13, 0, minutes: 60)
                default:
                    if weekday % 2 == 0 { block(11, 0, minutes: 60) }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        return FreeBusy(busy: busy)
    }

    /// A few holidays on their real dates, this year and next.
    static func holidays(around today: Date) -> [(String, Date)] {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: today)
        var result: [(String, Date)] = []
        for year in [year, year + 1] {
            func day(_ month: Int, _ day: Int) -> Date? { calendar.date(from: DateComponents(year: year, month: month, day: day)) }
            if let date = day(1, 1) { result.append(("New Year’s Day", date)) }
            if let date = day(7, 4) { result.append(("Independence Day", date)) }
            if let date = day(10, 31) { result.append(("Halloween", date)) }
            if let date = day(12, 25) { result.append(("Christmas Day", date)) }
            // The fourth Thursday of November.
            if let first = day(11, 1) {
                let weekday = calendar.component(.weekday, from: first)
                let offset = (5 - weekday + 7) % 7 + 21
                if let date = calendar.date(byAdding: .day, value: offset, to: first) { result.append(("Thanksgiving", date)) }
            }
        }
        return result
    }

    static func events(for account: Account, today: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let week = CalendarGrid(calendar: calendar).startOfWeek(today)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: week) ?? week
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func allDay(_ dayOffset: Int, days: Int = 1) -> (Date, Date) {
            let start = calendar.date(byAdding: .day, value: dayOffset, to: week) ?? week
            return (start, calendar.date(byAdding: .day, value: days, to: start) ?? start)
        }
        let me = Attendee(address: account.address, response: .accepted, isOrganizer: true)
        func guests(_ names: [String], _ responses: [AttendeeResponse] = []) -> [Attendee] {
            [me] + names.enumerated().map { index, name in Attendee(address: person(name), response: responses[safe: index] ?? .accepted) }
        }
        var events: [CalendarEvent] = []
        var counter = 0
        func add(_ calendarID: String, _ title: String, _ start: Date, _ end: Date, allDay: Bool = false, location: String? = nil, notes: String? = nil,
                 attendees: [Attendee] = [], conference: Conference? = nil, myResponse: AttendeeResponse? = nil, recurring: Bool = false,
                 type: EventType = .event, declines: Bool = false, notesHTML: String? = nil) {
            counter += 1
            events.append(CalendarEvent(id: "sample-event-\(account.kind.rawValue)-\(counter)", calendarID: calendarID, title: title, start: start, end: end,
                                        isAllDay: allDay, location: location, notes: notes, attendees: attendees,
                                        organizer: attendees.first(where: \.isOrganizer)?.address, conference: conference,
                                        recurrence: recurring ? ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"] : [], seriesID: recurring ? "series-\(title)" : nil,
                                        myResponse: myResponse, reminderMinutes: allDay ? [] : [10], type: type, declinesInvitations: declines,
                                        notesHTML: notesHTML))
        }
        switch account.kind {
        case .google:
            let meet = { (code: String) in Conference(kind: .meet, joinURL: URL(string: "https://meet.google.com/\(code)")!, meetingCode: code,
                                                      phoneNumbers: ["+1 503-555-0100 PIN: 482 913#"]) }
            for day in 1...5 {
                add("primary", "Team standup", at(day, 9, 30), at(day, 9, 45), attendees: guests(["Alex Kim", "Priya Shah", "Leo Martins"]),
                    conference: meet("abc-defg-hij"), recurring: true)
            }
            add("primary", "Design review", at(4, 14), at(4, 15), location: "Room 4B / video",
                notes: "Agenda\n• Onboarding flows\n• Settings redesign\nBring the latest mockups, and see the design notes.",
                attendees: guests(["Alex Kim", "Priya Shah", "Leo Martins"], [.accepted, .tentative, .needsAction]), conference: meet("rvw-qxpz-tme"),
                notesHTML: "<b>Agenda</b><ul><li>Onboarding flows</li><li>Settings redesign</li></ul>Bring the <i>latest</i> mockups, and see "
                    + "<a href=\"https://docs.example.com/design-notes\">the design notes</a>.")
            add("primary", "1:1 with Alex", at(2, 11), at(2, 11, 30), attendees: guests(["Alex Kim"]), conference: meet("one-onea-lex"))
            add("primary", "Roadmap planning", at(3, 10), at(3, 12), attendees: guests(["Priya Shah", "Zoe Anderson", "Aisha Rahman"]), conference: meet("map-plan-q4x"))
            add("primary", "Interview: product designer", at(3, 11), at(3, 12), attendees: guests(["Zoe Anderson"]), conference: meet("hir-inga-dsn"))
            add("primary", "Lunch with Olivia", at(2, 12, 30), at(2, 13, 30), location: "Bluebird Bakery")
            add("primary", "Focus time", at(1, 13), at(1, 16), type: .focusTime, declines: true)
            add("primary", "Dentist", at(5, 8), at(5, 9), location: "Bright Smiles Dental")
            add("primary", "Out of office", at(5, 13), at(5, 17), type: .outOfOffice, declines: true)
            add("family", "Hike at Dog Mountain", at(6, 8), at(6, 14), location: "Dog Mountain Trailhead", attendees: guests(["Sam Rivera"]))
            add("family", "Call Grandma", at(0, 17), at(0, 17, 30), conference: meet("grn-dmar-ose"))
            let birthday = allDay(4)
            add("family", "Sam's birthday 🎂", birthday.0, birthday.1, allDay: true)
            add("puppy", "Waffles' checkup", at(2, 10, 30), at(2, 11, 15), location: "Happy Tails Veterinary")
            add("puppy", "Puppy class", at(6, 9, 30), at(6, 10, 30), location: "Good Puppy School", myResponse: .accepted)
            let offsite = allDay(8, days: 2)
            add("primary", "Team offsite", offsite.0, offsite.1, allDay: true, location: "Mt. Hood Lodge")
            add("primary", "Quarterly planning", at(10, 13), at(10, 15), attendees: guests(["Alex Kim", "Priya Shah"]), conference: meet("qtr-plan-nng"))
            add("primary", "Coffee with Marcus", at(-3, 9), at(-3, 9, 30), location: "Stumptown")
            for (name, date) in holidays(around: today) {
                let end = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                add("holidays", name, date, end, allDay: true)
            }
            let gotcha = allDay(4)
            add("puppy", "Waffles' gotcha day 🐶", gotcha.0, gotcha.1, allDay: true)
            add("primary", "Book club", at(12, 19), at(12, 20, 30), location: "City Library",
                attendees: [Attendee(address: person("Hannah Brooks"), response: .accepted, isOrganizer: true), Attendee(address: account.address)],
                myResponse: .needsAction)
            // Invitations this week: one waiting for an answer, one answered Maybe and one No.
            func invitation(from organizer: String, answer: AttendeeResponse) -> [Attendee] {
                [Attendee(address: person(organizer), response: .accepted, isOrganizer: true), Attendee(address: account.address, response: answer)]
            }
            add("primary", "Vendor demo", at(4, 16), at(4, 17), attendees: invitation(from: "Ben Turner", answer: .needsAction), myResponse: .needsAction)
            add("primary", "Product sync", at(2, 15), at(2, 16), attendees: invitation(from: "Priya Shah", answer: .tentative), myResponse: .tentative)
            add("primary", "Budget review", at(3, 14), at(3, 15), attendees: invitation(from: "Marcus Lee", answer: .declined), myResponse: .declined)
        case .microsoft:
            let teams = Conference(kind: .teams, joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_sample%40thread.v2/0")!)
            add("calendar", "Northwind kickoff", at(1, 10), at(1, 11, 30), attendees: guests(["Marcus Lee", "Alex Kim"]), conference: teams)
            add("calendar", "Atlas sprint planning", at(3, 10), at(3, 11), attendees: guests(["Alex Kim", "Zoe Anderson"]), conference: teams)
            add("calendar", "Research readout", at(5, 15), at(5, 16), attendees: guests(["Zoe Anderson", "Aisha Rahman"]), conference: teams)
            add("calendar", "Invoice review with Ben", at(2, 14), at(2, 14, 30), attendees: guests(["Ben Turner"]))
            for day in 1...5 { add("calendar", "Daily sync", at(day, 9), at(day, 9, 15), attendees: guests(["Alex Kim"]), conference: teams, recurring: true) }
            let birthday = allDay(3)
            add("birthdays", "Marcus Lee's birthday", birthday.0, birthday.1, allDay: true)
            let vacation = allDay(8, days: 3)
            add("calendar", "Vacation", vacation.0, vacation.1, allDay: true, type: .outOfOffice)
        default:
            let faceTime = Conference(kind: .faceTime, joinURL: URL(string: "https://facetime.apple.com/join#v=1&p=sampleLink&k=sampleKey")!)
            add("home", "FaceTime with Mom", at(0, 19), at(0, 19, 30), conference: faceTime)
            add("home", "Brunch with Maya", at(6, 11), at(6, 12, 30), location: "Bluebird Bakery")
            add("home", "Yoga", at(2, 7, 30), at(2, 8, 30), location: "Sunrise Yoga")
            add("home", "Yoga", at(4, 7, 30), at(4, 8, 30), location: "Sunrise Yoga")
            add("work", "Portfolio review", at(3, 13), at(3, 14), conference: faceTime)
            let trip = allDay(9, days: 3)
            add("home", "Denver trip ✈️", trip.0, trip.1, allDay: true)
        }
        return events
    }
}
#endif
