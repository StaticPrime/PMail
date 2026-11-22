# PMail

**Your inbox and your calendar together in one app, minus the ads and the snooping.**

PMail is an email, calendar and contacts app for the Mac. Add a Google, Microsoft or iCloud account, or any IMAP or POP mail account, and its mail, calendars and contacts are all in one window, a click apart. Add as many accounts as you like: switch from the picture in the corner and all three switch with you. Read whole conversations at a glance, write with formatting, take back a message you've just sent, archive with one key, plan your week with a Meet, Teams or FaceTime meeting on any event, and keep everyone you write to close at hand.

- Mail, Calendar and Contacts side by side in one window
- Any number of accounts, each with its own mail, calendars and contacts
- Conversations: a message and its replies together, your own replies included
- Inbox tabs that sort mail into Primary, Promotions, Social and Updates (Google accounts) or Focused and Other (Microsoft accounts)
- Undo for archiving, deleting, spam and moving, and Undo Send
- New mail as it arrives, with notifications, and everything you've opened still readable offline
- Snooze conversations until later, schedule messages to send later, and an Outbox for mail written offline
- A video meeting on any event in one click: Meet on Google calendars, Teams on Microsoft calendars, and FaceTime links on iCloud calendars
- Day, week, month and schedule views, with every calendar in its own color
- Pictures in messages stay hidden until you ask, so senders can't tell when you read their mail
- Contacts with labels and stars, and one-click buttons to email, invite, call or FaceTime someone

Works with: Google accounts (mail, calendars and contacts), Microsoft accounts (Outlook.com and Microsoft 365 mail, calendars and contacts), iCloud (Mail, Calendar and Contacts), and any mail server that speaks IMAP or POP with SMTP, with calendar (CalDAV) and contacts (CardDAV) servers if it has them.

PMail is free, needs no account of its own and has no tracking: it talks only to your own mail, calendar and contacts servers. It runs in the macOS app sandbox, on macOS 14 Sonoma or later. It's written in Swift with AppKit and SwiftUI, and is part of the PuggleSoft family with [PuggleDocs](https://github.com/StaticPrime/PuggleDocs), [PuggleSheets](https://github.com/StaticPrime/PuggleSheets), [PuggleSlides](https://github.com/StaticPrime/PuggleSlides) and [PugglePhotos](https://github.com/StaticPrime/PugglePhotos).

## Features

### Accounts

- **Adding an account.** File ▸ Add Account… (or the welcome screen) offers Google, Microsoft, iCloud and Other mail account. Google and Microsoft accounts sign in on the provider's own page, in the system's secure sign-in window: PMail never sees the password, only a key the provider gives it, which you can take back at any time in your account's security settings. iCloud takes an app-specific password, made at account.apple.com (iCloud doesn't let other apps sign in through a web page); one password opens iCloud Mail, Calendar and Contacts. Any other account takes its address and password, with its servers filled in from the address (IMAP or POP for incoming mail, SMTP for outgoing, with SSL/TLS or STARTTLS) and optional calendar and contacts servers. Every account is checked against its server before it's added.
- **Switching.** Click the picture at the top right for the account switcher: the account showing, every other account to switch to, Add another account and Account settings. The Account menu lists them too, with ⌃⌘1 to ⌃⌘9. Switching changes mail, calendars and contacts together, and each account remembers where you were. The switcher shows how much unread mail each account's inbox has, and the Dock icon shows them all added up.
- **Account settings.** The name on mail you send, a signature added under new messages, the account's servers, signing in again, and removing the account (nothing is deleted from the server).
- **Secrets.** Passwords and sign-in keys are kept in your Mac's keychain, never in PMail's own files.

### Mail

- **The window.** The rail on the far left moves between Mail, Calendar and Contacts (⌘1, ⌘2, ⌘3). Mail's sidebar has Compose, then Inbox, Starred, Sent and Drafts (and Snoozed and Important where the account has them), More for Spam, Trash, Archive and All Mail, and the account's own labels or folders, nested, each with its unread count. The big search field runs across the top. The menu button at the top left (or ⌃⌘S) narrows the sidebar to icons. Light and Dark Mode both work.
- **The list.** A row for each conversation: tick box, star, who wrote (or, in Sent, who it went to), the subject and the start of the latest message, a paper clip for attachments, and when. Unread conversations are bold. Point at a row for Archive, Delete and Mark as read in place of its date; right-click it for more. Fifty conversations to a page, with "1–50 of 2,345" and arrows for older and newer pages.
- **Inbox tabs.** Google accounts' inboxes sort into Primary, Promotions, Social and Updates; Microsoft accounts' into Focused and Other.
- **Ticking rows.** Tick rows, or use the select menu for all, none, read, unread, starred or unstarred; the toolbar then archives, reports spam, deletes, marks read or unread, moves and labels them all at once. Drag rows onto a folder or label in the sidebar.
- **Reading.** Click a conversation to open it: its subject and labels, then each message, the newest open and older ones folded to a line (click to open them). Each message shows who sent it, to whom ("to me, Alex" opens the full From, To, Cc and date), when ("2 hours ago"), its star, Reply, and more: Reply all, Forward, Delete this message, Mark unread from here, Download message and Unsubscribe. Reply, Reply all and Forward wait at the bottom. The arrows at the top go to newer and older conversations; ← goes back to the list. In Dark Mode, formatted messages sit on a white card, as their senders drew them.
- **Pictures.** Pictures from the internet in a message stay hidden, because loading them tells the sender when and where the message was read. Show pictures loads them once; Always show pictures from the sender remembers. Pictures sent inside a message always show. A message's own scripts never run, nothing in it can load anything from the internet until you allow pictures, and links open in your browser.
- **Attachments.** Files show as cards under their message: click to save to Downloads, double-click to open, or right-click for Save As….
- **Actions with Undo.** Archive, Delete, Report spam and Move leave the list at once, and a note along the bottom offers Undo for a few seconds before anything reaches the server. Star and Mark as read or unread happen right away. Opening a conversation marks it read.
- **Sent, Drafts, Archive, Junk and Trash on every account.** When a server has no folder for one of them (an iCloud account that has only ever had an inbox, for one, or any POP account), PMail keeps that folder on your Mac: sent copies and drafts are saved there, and archived, junk and deleted mail is copied there before it leaves the server. Move to Inbox (or Not spam) puts a message back on the server, and Delete forever in that Trash removes it for good. If the server gets its own folder later, the one on your Mac shows as “Sent on this Mac” (and so on) until it's empty. The spam folder is called Spam or Junk, as the server words it, and Junk when it says neither or PMail keeps it.
- **Blocking senders.** Report spam asks whether to block the sender too: their address, or everything from their domain. Their other conversations in the inbox go to the spam folder with it, and their new mail goes there as PMail finds it, without a notification. Undo right after reporting unblocks them again; later, Settings ▸ Blocked senders lists everyone blocked on each account, with Unblock.
- **Search.** Type in the search field and press Return. Google and Microsoft accounts search all your mail in their own search language; IMAP accounts search the folder showing; POP accounts search the mail on your Mac.

### Writing

- **Compose.** Compose (or ⌘N, or C) opens a message in a window docked at the bottom right of the main window, up to three side by side. Minimize it to its title, make it bigger, or close it to keep a draft.
- **Drafts.** A draft opens straight into its window to carry on writing, from Drafts or from the conversation it replies to, where it shows as Draft with Edit and Discard. Opening it again brings that window forward; saving replaces the draft, and sending or discarding deletes it. Drafts aren't mail yet, so there's nothing to reply to, mark read, star or file away: ticking drafts offers only Discard Drafts (with Undo).
- **Addresses.** Type a name or address in To, Cc or Bcc and PMail suggests people from your contacts; Return, Tab or a comma turns what you typed into a chip, and Delete takes the last one back. Paste a whole list at once.
- **Formatting.** Bold, italic, underline (⌘B, ⌘I, ⌘U), strikethrough, colors, sizes, bulleted and numbered lists, links (⌘K) and emoji, from the formatting bar (the Aa button). Every message goes out as both formatted and plain text.
- **Files.** Attach files with the paper clip, or drag them onto the message.
- **Replies and forwards.** Replies go to the right people (Reply all leaves you out and keeps everyone else; replying to your own message goes to the people it went to), with "Re:" and the original quoted underneath (folded away; click ••• to see it), and stay in their conversation. Forwards bring the original's attachments.
- **Sending.** Send (or ⌘Return) closes the window and sends a few seconds later; Undo in the note along the bottom stops it and opens it again. Settings sets how long the wait is (5 to 30 seconds).
- **Links from other apps.** PMail opens `mailto:` links as new messages, so it can be your Mac's email app.

### Keeping up to date

- **New mail.** PMail checks every account's inbox every couple of minutes while it's open (Settings sets how often; accounts other than the one showing are checked half as often). An IMAP account (iCloud included) is watched all the time while it's showing: new mail appears the moment the server says so, or within a minute on servers that can't, and mail read, moved or deleted on another device updates too. The list showing and the unread counts update by themselves.
- **Notifications.** New mail shows a notification with who it's from, the subject and the start of the message, unless you're looking at that inbox already; click it to open the conversation, switching accounts if need be. Settings turns them off.
- **Offline.** Folders, the lists you've looked at, conversations you've opened, calendars and contacts are kept on your Mac, so PMail opens straight away and you can read them without a network. A note across the top says when you're offline; changes you make wait and reach the server once it can be reached.
- **The Outbox.** A message sent while offline (or when the server can't be reached) waits in the Outbox, which appears in the sidebar while it has something in it, and goes as soon as it can. Open it there to Send Now, Edit or Delete it.
- **Snooze.** The clock button (on the toolbar, when you point at a row, or in the right-click menu) puts conversations away until later today, tomorrow, this weekend, next week, or a date and time you pick. They leave the inbox at once (with Undo) and come back to the top, unread, with a notification, when their time comes. Snoozed lists them with when they'll be back; Unsnooze brings one back now.
- **Scheduled send.** The arrow beside Send schedules the message for tomorrow morning or afternoon, Monday morning, or a date and time you pick. Scheduled lists what's waiting, with when it will go; open one to Send Now, Cancel Send (to edit it again) or Delete it.
- **Open at login.** Settings ▸ Open PMail when I log in, so new mail, snoozes and scheduled messages keep coming.

### Calendar

- **The window.** Create at the top of the sidebar, a small month to jump to any day, then My calendars and Other calendars, each with a colored box to show or hide it. Today, the arrows and the month's name across the top, with the view on the right.
- **Day and week.** A column for each day, the hours down the side, the time zone in the corner, all-day and multi-day events as bars across the top, and a red line at the time now. Events that overlap share the column. Click an empty slot to make an event there, or a day's number to see just that day.
- **Month.** Whole weeks, each day with as many events as fit (all-day ones as bars, the rest with a colored dot and their time), and "3 more" for the rest.
- **Schedule.** The next thirty days as a list, a day at a time. Searching the calendar lists every event that matches, by title, place, description or guest.
- **Event details.** Click an event for its time (and how it repeats), the meeting to join, its guests and their answers, where it is (click for Maps), its description, reminder and calendar, with Edit, Delete and Email guests at the top, and Going? Yes, No or Maybe for invitations.
- **Making and changing events.** Title, when (or all day), the video meeting, place, reminder, calendar, color, busy or free, description, and guests with suggestions from your contacts; guests get invitations by email from your provider when you save. A repeating event asks whether a change or deletion is for that event or all of them.
- **Keys.** D, W, M and A pick the view, T goes to today, J and K step forward and back, and C makes an event.

### Video meetings

- **Google calendars.** Add Google Meet video conferencing makes a Meet meeting for the event when you save; its link, meeting code and dial-in numbers go to every guest.
- **Microsoft calendars.** Add Microsoft Teams meeting makes a Teams meeting for the event when you save (on accounts where the calendar allows Teams meetings).
- **iCloud and other calendars.** Add FaceTime link: make a link in FaceTime (Create Link, then Copy Link) and paste it; PMail offers the one already copied. Guests join from a Mac, iPhone or iPad, or a web browser. Message guests opens Messages with every guest.
- **Joining.** Every event with a meeting, whichever app it's for (Meet, Teams, FaceTime, Zoom or Webex), has a Join button in its details.

### Contacts

- **The list.** Contacts, Other contacts (people your Google account remembers you writing to) and your labels in the sidebar; a table of names, email addresses, phone numbers, job titles and companies, and labels, with starred contacts first. Point at a row to star, edit or delete it. Searching filters as you type.
- **A contact's page.** A big picture, their name, job and labels, buttons to email them, invite them to an event, call them or FaceTime them, and every detail they have.
- **Editing.** Names (with prefix, middle name, suffix and nickname), company and job title, email addresses, phone numbers and postal addresses with labels, birthday, notes and labels.

### Your privacy

- **Nothing in between.** PMail connects straight to your own providers' servers; there's no PuggleSoft server and no PuggleSoft account. Nothing about you or your mail is sent anywhere else.
- **No tracking.** No analytics, no ads, no crash reporting that calls home. Pictures that could tell senders when you read their mail stay hidden until you ask.
- **Kept on your Mac.** The list of accounts is kept in PMail's own folder, and passwords and sign-in keys in your keychain. So is a copy of what each account last loaded (folders, the lists and conversations you've opened, calendars and contacts), its snoozes, the senders it blocks and the messages waiting to be sent; removing an account removes them. Accounts without calendar or contacts servers keep their calendar and contacts in PMail's folder too, POP accounts their mail, and IMAP accounts whose server lacks them their Sent, Drafts, Archive, Junk and Trash.

Help ▸ Keyboard Shortcuts (⌘/) lists every keyboard shortcut. Single-key shortcuts (C to compose, E to archive, # to delete, R, A and F to reply, reply all and forward, S to star, J and K to move through conversations, U to go back to the list, / to search) work whenever you aren't typing, and can be turned off in Settings.

## Known limits

- Signing in with Google or Microsoft needs PMail's own client ID from each provider, built into the copy you run (see Signing in with Google and Microsoft below). A copy without them says so and still works with iCloud and other accounts; a Google account can then be added for mail only, with an app password, as an Other mail account.
- iCloud doesn't let other apps sign in through a web page, so iCloud accounts take an app-specific password.
- macOS gives apps no way to make FaceTime links, so a FaceTime link is made in FaceTime and pasted into the event.
- Teams meetings can only be added on Microsoft calendars that allow them (work and school accounts); personal accounts may not.
- Snoozes and scheduled messages are kept on this Mac, not on the server: they happen while PMail is open (or the next time it opens), and other apps and devices don't know about them.
- Changes made offline wait while PMail is open; if it quits before the server can be reached again, they're tried once more as it quits and otherwise lost (the Outbox is kept).
- Folders kept on your Mac aren't on the server, so other devices and apps don't see them; searching shows what's in them only while that folder is showing.
- Blocking happens in PMail, not on the server: mail from a blocked sender arrives in the inbox as usual and goes to the spam folder when PMail next checks, so other devices can see it in the inbox until then. The list of blocked senders is kept on this Mac.
- Microsoft and Google accounts hear about new mail by checking every couple of minutes; only IMAP servers can tell PMail at once. Microsoft accounts go by when each message arrived, so one held up on its way into the inbox (while an attachment is scanned, say) shows in the inbox without a notification.
- New events can't be made repeating yet. Repeating events show, and can be changed or deleted one at a time or all together, except that changing all of them leaves their time as it was. Microsoft calendars don't say how their repeating events repeat.
- Labels and folders can't be made, renamed or deleted in PMail yet.
- POP accounts leave mail on the server, download the newest 300 messages the first time, and need the server to show the inbox.
- Contact pictures show for Google contacts but can't be changed in PMail; Microsoft contacts show without pictures.
- Microsoft accounts' categories don't show as labels.
- An IMAP conversation opened from the inbox includes your replies from Sent, but one opened from Sent doesn't bring in the inbox side.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (developed with Xcode 27.2, Swift 6)

## Building and running

Open `PMail.xcodeproj` in Xcode and run the **PMail** scheme. Or, from the command line:

```sh
xcodebuild -project PMail.xcodeproj -scheme PMail -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/PMail.app
```

The app is sandboxed, with access to the network (to reach your servers), to files you choose (attachments) and to the Downloads folder (saving attachments). Debug builds are signed to run on the Mac that built them, unless `Config/Signing.xcconfig` names a team; releases are signed by `Tools/make-installer.sh`.

To try PMail without signing in to anything, run a debug build with `-PMSampleAccounts YES`: three made-up accounts (one of each provider kind), with mail, calendars and contacts that change in memory only.

### Signing in with Google and Microsoft

Each provider asks apps that sign in through its page to be registered with it. Register PMail once with each, then give PMail the client IDs.

**Google.** In the Google Cloud console, make a project and enable the Gmail API, the Google Calendar API and the People API. Set up the OAuth consent screen (External) with the scopes `https://mail.google.com/`, `https://www.googleapis.com/auth/calendar`, `https://www.googleapis.com/auth/contacts` and `https://www.googleapis.com/auth/contacts.other.readonly`, and add yourself as a test user. Then make an OAuth client ID of the type **iOS**, with the bundle ID `com.pugglesoft.PMail`. Its client ID (`…apps.googleusercontent.com`) is `PMAIL_GOOGLE_CLIENT_ID`; PMail works out the redirect URI from it (the client ID reversed, `com.googleusercontent.apps.…:/oauth2redirect`). Until Google verifies the app, only the test users on the consent screen can sign in; full mail access is a restricted scope, which Google reviews before anyone else can use it.

**Microsoft.** In the Microsoft Entra admin center, under App registrations, make a new registration named PMail for accounts in any organizational directory and personal Microsoft accounts. Add the platform **iOS / macOS** with the bundle ID `com.pugglesoft.PMail` (which gives the redirect URI `msauth.com.pugglesoft.PMail://auth`), and turn on Allow public client flows. Under API permissions, add the Microsoft Graph delegated permissions `User.Read`, `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `Contacts.ReadWrite` and `offline_access`. Its Application (client) ID is `PMAIL_MICROSOFT_CLIENT_ID`.

Then give PMail the IDs, in any of these ways:

- **In a file, for every build on this Mac:** put them in `Config/Secrets.xcconfig`, which Git ignores:

  ```
  PMAIL_GOOGLE_CLIENT_ID = 1234567890-abcdefg.apps.googleusercontent.com
  PMAIL_MICROSOFT_CLIENT_ID = 00000000-0000-0000-0000-000000000000
  ```

- **As environment variables:** in the shell that runs `xcodebuild` or `Tools/make-installer.sh`, or in Xcode's scheme under Run ▸ Arguments ▸ Environment Variables (PMail reads those when it starts).
- **For releases:** as repository secrets (see Releasing a new version).

| Setting | What it holds |
| --- | --- |
| `PMAIL_GOOGLE_CLIENT_ID` | The OAuth client ID registered for PMail with Google |
| `PMAIL_GOOGLE_CLIENT_SECRET` | Optional: the client's secret, for a registration type that has one |
| `PMAIL_GOOGLE_REDIRECT_URI` | Optional: a redirect URI other than the reversed client ID |
| `PMAIL_MICROSOFT_CLIENT_ID` | The Application (client) ID registered for PMail with Microsoft |
| `PMAIL_MICROSOFT_TENANT` | Optional: `common` (the default), `consumers`, `organizations` or a tenant ID |
| `PMAIL_MICROSOFT_REDIRECT_URI` | Optional: a redirect URI other than `msauth.com.pugglesoft.PMail://auth` |

PMail ▸ Settings ▸ Signing in shows whether the copy running has each one.

### Installer

```sh
Tools/make-installer.sh
```

This builds `build/PMail.pkg`, which installs PMail.app in /Applications for all users (macOS asks for an administrator's password). The app runs on every Mac with macOS 14 or later. Beside it goes `build/PMail.dSYM.zip`, the build's debug symbols (see Reading a crash report below). The sign-in client IDs come from the environment or `Config/Secrets.xcconfig`, as above; the script says which providers the build can sign in to.

A local build is ad-hoc signed and the installer is unsigned. That's fine on the Mac that built it, but a copy that arrives by download or email is blocked the first time: the user has to click **Open Anyway** in System Settings ▸ Privacy & Security. To sign with a Developer ID and have the installer notarized, set the variables described at the top of `Tools/make-installer.sh` before running it. Releases built on GitHub are signed and notarized this way when the repository has the Developer ID secrets (see below).

### Releasing a new version

Versions are MAJOR.MINOR.FIX. To release the next one, run this on `main`, up to date with GitHub and with everything committed:

```sh
Tools/release.sh            # a fix:          1.2.3 → 1.2.4
Tools/release.sh minor      # a minor update: 1.2.3 → 1.3.0
Tools/release.sh major      # a major update: 1.2.3 → 2.0.0
```

The script raises the version and the build number in the Xcode project, commits "Release version 1.2.4", tags it `v1.2.4` and pushes both. The tag starts the Release workflow on GitHub, which runs the package tests, builds the installer with `Tools/make-installer.sh` and publishes it, with its debug symbols, as a GitHub release. The installer keeps the same name in every release, so https://github.com/StaticPrime/PMail/releases/latest/download/PMail.pkg always downloads the newest one. `Tools/release.sh --dry-run` shows the next version without changing anything.

Add these secrets under the repository's Settings ▸ Secrets and variables ▸ Actions. Without the Developer ID ones, releases are published unsigned, with a warning on the run; without the sign-in ones, released copies can't sign in with that provider.

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | A .p12 file with the "Developer ID Application" and "Developer ID Installer" certificates and their private keys, base64-encoded (`base64 -i DeveloperID.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12 file's password |
| `NOTARY_API_KEY` | The text of an App Store Connect API key file (`AuthKey_….p8`), used to notarize |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys in App Store Connect |
| `PMAIL_GOOGLE_CLIENT_ID` | PMail's Google client ID |
| `PMAIL_GOOGLE_CLIENT_SECRET` | Optional, as above |
| `PMAIL_MICROSOFT_CLIENT_ID` | PMail's Microsoft client ID |
| `PMAIL_MICROSOFT_TENANT` | Optional, as above |

### Reading a crash report

Release builds are stripped, so a crash report from an installed copy shows the PMail lines of its stack only as addresses. Every release carries `PMail.dSYM.zip`, the debug symbols for that build. Unzip the one for the version in the report and look the addresses up, giving the load address from the PMail line under Binary Images:

```sh
atos -o PMail.app.dSYM/Contents/Resources/DWARF/PMail -arch arm64 -l 0x102048000 0x1020b5e4c 0x1020d2c2c
```

Use `-arch x86_64` for a report from an Intel Mac. Symbols fit only the build they came with: `dwarfdump --uuid PMail.app.dSYM` should list the UUID the report gives for PMail.

## Tests

The engine lives in a Swift package with unit tests that need no network: pretend mail servers answer IMAP, POP and SMTP sessions line by line, and pretend web servers answer Google, Microsoft, CalDAV and CardDAV requests with answers shaped like the real ones. They cover reading messages of every shape (nested parts, transfer encodings, character sets, encoded words, file names, broken messages), writing them and reading back what was written, addresses and dates; IMAP's responses, its sessions and every action; SMTP's and POP's sessions and sign-ins (passwords and tokens, STARTTLS, refusals); the mailbox POP accounts keep, and the folders kept for IMAP servers without them (deleting, archiving, junk, putting back, sent copies, drafts, and finding a snoozed conversation again); blocked senders (addresses, and domains with their subdomains); iCalendar and repeating events (across daylight saving changes), vCards, and CalDAV and CardDAV with their discovery and change checks; the web services' requests and answers, including making Meet and Teams meetings; sign-in (PKCE, client IDs from the environment, refreshing tokens); replies and forwards; formatted text; checking for new mail (an IMAP inbox's next message number, waiting with IDLE or asking every minute, POP's message list, Google's mail history and Microsoft's newest messages) and finding messages again by their Message-IDs; the copy of each account kept on the Mac, the Outbox and Scheduled, snoozes and the times offered for later; and dates, calendar grids and event layout as the window shows them:

```sh
cd Packages/PMailKit && swift test
```

Debug builds also include an end-to-end check that drives the real window on the sample accounts (never a real account, the keychain or a server) and prints `SELFTEST PASS/FAIL` lines. It covers every menu item checked in each part of the app, pages and inbox tabs, opening a conversation (oldest first, the newest open, read on the server and in the counts), message pages refusing pictures from the internet until asked, single-key shortcuts, archiving with and without Undo, All Mail, Sent and search, sending (with Undo Send, a missing or broken address, and the plain and formatted versions), replies and reply all, `mailto:` links, the week and month views, turning calendars off, events with Meet, Teams and pasted FaceTime links on each kind of account, deleting an event, switching accounts (mail, calendars and contacts together), contacts (sorting, searching, suggestions, creating, starring and deleting), the add-account sheet, the About window, removing an account, Dark Mode, and keeping up to date (the first check announcing nothing, new mail noticed, announced and put at the top of the inbox, a notification opening its conversation, snoozing and the conversation coming back with a notification, a scheduled message going when its time comes, a conversation read offline from the copy on the Mac with the offline note, and a message sent offline waiting in the Outbox until the server answers), and blocking senders (Report spam offering the sender and their domain, the conversation going to Junk, the sender's next message going straight to Junk without a notification, and unblocking):

```sh
build/DerivedData/Build/Products/Debug/PMail.app/Contents/MacOS/PMail -PMSelfTest YES -PMToday 2026-11-21
```

Other debug launch arguments: `-PMSampleAccounts YES` uses the sample accounts. `-PMToday 2026-11-21` fixes the day they treat as today. `-PMSnapshot name.png` saves a picture of the window (with its sheet and popovers, or the About or Settings window) to the app's temporary folder and quits, always on the sample accounts; `-PMSnapshotPrint YES` prints it too, in base64, for when that folder can't be read from outside. Combine it with `-PMAccount 2`, `-PMModule calendar` (or `contacts`), `-PMFolder sent` (a folder's role or name, or `all`), `-PMTab 2`, `-PMSearch words`, `-PMOpen 3` (opens a conversation), `-PMCompose YES` (or `reply`), `-PMCalendarView month` (or `day`, `week`, `schedule`), `-PMEvent 2` (an event's details), `-PMEventEditor new` (or a number), `-PMContact 1`, `-PMContactEditor YES`, `-PMAddAccount YES` (or `google`, `microsoft`, `icloud`, `other`), `-PMAccountMenu YES`, `-PMShortcuts YES`, `-PMSettings YES`, `-PMShowAbout YES`, `-PMCollapsed YES`, `-PMNoAccounts YES` (the welcome screen), `-PMDark YES`, and `-PMWindowWidth` and `-PMWindowHeight`.

## Project layout

```
PMail/                       macOS app target (files are picked up automatically by Xcode)
  App/                       Entry point, app delegate, app model, clock, debug-only sample accounts, launch options and self-test
  Accounts/                  Accounts and their sessions, the service factory, adding accounts (provider marks, sign-in through the
                             provider's page, the iCloud and other-account forms), the account switcher and account settings
  Mail/                      Mail's view model, sidebar, list, conversation, message pages, compose windows and the editor
  Calendar/                  The calendar's view model, sidebar, day, week, month and schedule views, event details and editor
  Contacts/                  The contacts' view model, list, contact page and editor
  Sync/                      Keeping every account up to date in the background, sending later, snoozes and notifications
  UI/                        The window, its top bar and rail, the theme, shared controls, the menu bar, About and Settings
  Resources/                 Asset catalog: the app icon, the About logo and the accent color
Packages/PMailKit/           Swift package with the engine (no UI), and its tests
  Sources/PMailKit/
    Accounts/                Accounts, servers and the usual settings for well-known providers, credentials, the account list
                             and the keychain
    Auth/                    OAuth 2.0 sign-in: client IDs from the environment, PKCE, tokens and refreshing them
    Mail/                    The mail model and service interface, and replies and forwards
    Mail/MIME/               Reading and writing messages: MIME, encoded words, character sets, addresses and dates
    Mail/IMAP/               The IMAP client and the mail service for IMAP accounts
    Mail/SMTP/, Mail/POP/    Sending through SMTP; the POP client and the mail service for POP accounts
    Mail/Local/              Mail kept on the Mac: a POP account's mailbox, and Sent, Drafts, Archive, Junk and Trash for IMAP servers without them
    Calendar/                The calendar model and service interface, meeting links, iCalendar and repeating events
    Contacts/                The contacts model and service interface, and vCard
    DAV/                     WebDAV, and the CalDAV and CardDAV services
    Local/                   Calendars and contacts kept on the Mac, for accounts without servers for them
    Web/                     The web service client, and the Google and Microsoft mail, calendar and contacts services
    Network/                 Byte streams with TLS or STARTTLS, reading lines and literals, and HTTP
    Compose/                 Formatted text as HTML for sending
    Sync/                    The copy of each account kept on the Mac, the Outbox and Scheduled, snoozes, blocked senders, and the times offered for later
    Support/                 Errors worded for people, dates and sizes as the window shows them, calendar grids, event layout
  Tests/PMailKitTests/       The package's tests, with a pretend mail server and a pretend web server
Config/                      Debug and Release build settings (Signing.xcconfig and Secrets.xcconfig are local and ignored by Git)
Tools/                       make-icons.swift (draws the app icon), make-installer.sh, release.sh
.github/workflows/           The Release and CLA workflows
```

## How it works

- **One account at a time, all of it.** Each account has a session: its mail, calendar and contacts services, made from its kind and its keychain secret, and what the three parts of the window show for it. Switching accounts swaps the whole session, so mail, calendars and contacts always belong together, and each keeps its place.
- **One interface, many servers.** Mail, calendars and contacts each go through one interface, with an implementation for each kind of server: IMAP or POP with SMTP, the Google and Microsoft web APIs, CalDAV and CardDAV, or files on the Mac. Lists come a page of conversations at a time, so nothing waits for a whole mailbox.
- **Mail protocols.** IMAP, POP and SMTP run over URLSession stream tasks, with TLS from the first byte or STARTTLS before signing in, and refuse to send a password over a plain connection unless the account says so. Whole messages are read by PMail's own MIME parser, whatever server they come from, and every message sent is written by its MIME builder: plain text and HTML, attachments and inline pictures, encoded headers, and never a Bcc header.
- **Sign-in.** OAuth 2.0 with PKCE in the system's sign-in window, in a private session so nothing stays in a browser. The refresh token is kept in the keychain; access tokens are refreshed one at a time as they run out, and once more when a server turns one down.
- **Undo.** Archiving, deleting, spam and moves change the list at once and reach the server a few seconds later; Undo cancels the wait. Sending waits the same way. Anything still waiting is sent before PMail quits or switches accounts.
- **Message pages.** Each message body is drawn by WebKit at its full height inside the conversation. The page's scripts are off, a content security policy and a content blocker refuse anything from the internet until pictures are allowed, pictures inside the message come from the message itself, and every link goes to the browser.
- **Meetings.** Google events get Meet through the calendar API's conference request, and Microsoft events get Teams by asking the calendar for an online meeting; PMail waits for the link if the provider is still making it. A FaceTime link is saved in the event's URL and description, so every calendar app shows it. Meeting links in any event's location or description are recognized for its Join button.
- **Keeping up to date.** Every couple of minutes each account's service is asked what's new in its inbox since the last time, cheaply: Google's mail history, Microsoft's newest inbox messages, an IMAP inbox's next message number, a POP server's message list. The IMAP account showing also keeps a second connection open on its inbox, waiting with IDLE where the server has it (renewed every 25 minutes) and asking every minute where it doesn't, and checks the moment something changes. What's new is announced with the system's notifications and the window refreshes what it shows.
- **The copy on the Mac.** Each account has a folder of its own with a copy of its folders, the pages of conversations it listed, the conversations it opened (minus big attachments' data) and its calendars, events and contacts; the window shows the copy first and the server's answer replaces it. Snoozes and the Outbox (and Scheduled) are kept there too, one file per waiting message, so nothing is lost if PMail quits. Snoozed conversations are found again by their Message-IDs when they come back, since archiving can give a message a new ID.
- **Folders kept on the Mac.** An IMAP account's folders come from the plain LIST, with special-use marks (RFC 6154) asked for too where the server offers them, then the usual names (Sent Messages, Deleted Messages, Junk…). Sent, Drafts, Archive, Junk and Trash the server still lacks are served from a store on the Mac, the same kind a POP account keeps its mail in, beside the server's folders. Deleting reads the whole message and stores it before deleting it from the server; moving a kept message to a server folder uploads it with APPEND, then lets the copy on the Mac go.
- **Blocked senders.** Each account keeps a list of blocked addresses and domains on the Mac. Every check for new mail moves messages from them to the spam folder through the account's own Report spam (the server's, or the one kept on the Mac) before announcing the rest.
- **The day and week views** share a day between events that overlap: each takes the first free column at its start and stretches right where nothing overlaps it.

## Contributing

Bug reports, ideas and pull requests are welcome. Before your first pull request is merged, you sign the [PuggleSoft Contributor License Agreement](CLA.md) by posting one comment, and a bot walks you through it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 PuggleSoft.

PMail is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.
