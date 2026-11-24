import Foundation
import Testing
@testable import PMailKit

/// DNS answers set by the test.
private struct FakeDNS: DNSRecordLookup {
    var exchangers: [String: [String]] = [:]
    var records: [String: [ServiceRecord]] = [:]

    func mailExchangers(for domain: String) async -> [String] { exchangers[domain] ?? [] }
    func services(_ name: String) async -> [ServiceRecord] { records[name] ?? [] }
}

/// Servers that answer, as the test says, recording which were tried.
private final class FakeProbe: MailServerProbe, @unchecked Sendable {
    private let lock = NSLock()
    private let answering: Set<String>
    private var asked: [String] = []

    /// `answering`: "imap:mail.example.org:993" and the like.
    init(answering: Set<String> = []) {
        self.answering = answering
    }

    var tried: [String] { lock.withLock { asked } }

    func answers(_ server: ServerSettings) async -> Bool {
        let key = "\(server.mailProtocol.rawValue):\(server.host):\(server.port)"
        lock.withLock { asked.append(key) }
        return answering.contains(key)
    }
}

/// Finding an address's mail servers from the address alone.
@Suite struct MailSettingsLookupTests {
    private func lookup(dns: FakeDNS = FakeDNS(), transport: StubTransport = StubTransport(), probe: FakeProbe = FakeProbe()) -> MailSettingsLookup {
        MailSettingsLookup(dns: dns, transport: transport, probe: probe)
    }

    @Test func providersPMailKnowsNeedNoLookingUp() async {
        let transport = StubTransport()
        let probe = FakeProbe()
        let result = await lookup(transport: transport, probe: probe).lookUp(email: "pug@yahoo.com")
        guard case let .servers(found) = result else { Issue.record("expected servers, got \(result)"); return }
        #expect(found.source == .knownProvider)
        #expect(found.incoming == ServerSettings(mailProtocol: .imap, host: "imap.mail.yahoo.com", security: .tls, username: "pug@yahoo.com"))
        #expect(found.otherIncoming?.host == "pop.mail.yahoo.com" && found.outgoing.host == "smtp.mail.yahoo.com" && found.outgoing.port == 465)
        #expect(transport.requests.isEmpty && probe.tried.isEmpty)
        #expect(await lookup().lookUp(email: "pug@gmail.com") == .provider(.google))
        #expect(await lookup().lookUp(email: "pug@icloud.com") == .provider(.icloud))
        #expect(await lookup().lookUp(email: "not an address") == .notFound)
    }

    @Test func aCompanysDomainAtABigProviderIsSentToItsSignIn() async {
        let dns = FakeDNS(exchangers: ["dogs.example": ["aspmx.l.google.com", "alt1.aspmx.l.google.com"],
                                       "cats.example": ["cats-example.mail.protection.outlook.com"],
                                       "birds.example": ["mx01.mail.icloud.com"],
                                       "fish.example": ["in1-smtp.messagingengine.com"]])
        let mail = lookup(dns: dns)
        #expect(await mail.lookUp(email: "pug@dogs.example") == .provider(.google))
        #expect(await mail.lookUp(email: "pug@cats.example") == .provider(.microsoft))
        #expect(await mail.lookUp(email: "pug@birds.example") == .provider(.icloud))
        guard case let .servers(fish) = await mail.lookUp(email: "pug@fish.example") else { Issue.record("expected Fastmail"); return }
        #expect(fish.incoming.host == "imap.fastmail.com" && fish.incoming.username == "pug@fish.example")
    }

    static let setupFile = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <clientConfig version="1.1">
      <emailProvider id="dogs.example">
        <domain>dogs.example</domain>
        <incomingServer type="imap">
          <hostname>imap.%EMAILDOMAIN%</hostname><port>143</port><socketType>plain</socketType>
          <authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username>
        </incomingServer>
        <incomingServer type="imap">
          <hostname>mx.dogs.example</hostname><port>993</port><socketType>SSL</socketType>
          <authentication>password-cleartext</authentication><username>%EMAILLOCALPART%</username>
        </incomingServer>
        <incomingServer type="pop3">
          <hostname>pop.dogs.example</hostname><port>995</port><socketType>SSL</socketType>
          <authentication>OAuth2</authentication><username>%EMAILADDRESS%</username>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>mx.dogs.example</hostname><port>587</port><socketType>STARTTLS</socketType>
          <authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username>
        </outgoingServer>
      </emailProvider>
      <addressBook type="carddav"><serverURL>https://dav.dogs.example/contacts/</serverURL></addressBook>
      <calendar type="caldav"><serverURL>https://dav.dogs.example/calendars/</serverURL></calendar>
    </clientConfig>
    """#

    @Test func theDomainsOwnSetupFileIsRead() async throws {
        let transport = StubTransport()
        transport.on("GET", "/mail/config-v1.1.xml") { _ in .text(Self.setupFile, contentType: "text/xml") }
        let result = await lookup(transport: transport).lookUp(email: "pug@dogs.example")
        guard case let .servers(found) = result else { Issue.record("expected servers, got \(result)"); return }
        #expect(found.source == .setupFile)
        #expect(found.incoming == ServerSettings(mailProtocol: .imap, host: "mx.dogs.example", port: 993, security: .tls, username: "pug"),
                "the encrypted IMAP server, not the plain one")
        #expect(found.otherIncoming == nil, "the POP server takes only OAuth")
        #expect(found.outgoing == ServerSettings(mailProtocol: .smtp, host: "mx.dogs.example", port: 587, security: .startTLS,
                                                 username: "pug@dogs.example"))
        #expect(found.contactsServer?.absoluteString == "https://dav.dogs.example/contacts/")
        #expect(found.calendarServer?.absoluteString == "https://dav.dogs.example/calendars/")
        let asked = try #require(transport.requests.first?.url)
        #expect(asked.host == "autoconfig.dogs.example" && asked.scheme == "https")
        #expect(URLComponents(url: asked, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "pug@dogs.example")
    }

    @Test func srvRecordsNameTheServers() async {
        let dns = FakeDNS(records: [
            "_imaps._tcp.dogs.example": [ServiceRecord(host: "imap2.dogs.example", port: 993, priority: 20),
                                         ServiceRecord(host: "imap1.dogs.example", port: 993, priority: 10)],
            "_submissions._tcp.dogs.example": [ServiceRecord(host: "smtp.dogs.example", port: 465)],
        ])
        let result = await lookup(dns: dns).lookUp(email: "pug@dogs.example")
        guard case let .servers(found) = result else { Issue.record("expected servers, got \(result)"); return }
        #expect(found.source == .dnsRecords)
        #expect(found.incoming.host == "imap1.dogs.example" && found.incoming.security == .tls, "the lowest priority first")
        #expect(found.outgoing == ServerSettings(mailProtocol: .smtp, host: "smtp.dogs.example", port: 465, security: .tls,
                                                 username: "pug@dogs.example"))
    }

    @Test func theUsualNamesAreTriedStartingWithTheDomainsOwnMailExchanger() async {
        // As a server of the domain's own with nothing published: its MX host answers on the encrypted ports.
        let dns = FakeDNS(exchangers: ["dogs.example": ["mail.dogs.example"]])
        let probe = FakeProbe(answering: ["imap:mail.dogs.example:993", "imap:mail.dogs.example:143", "smtp:mail.dogs.example:465",
                                          "smtp:mail.dogs.example:587", "pop3:pop.dogs.example:995"])
        let result = await lookup(dns: dns, probe: probe).lookUp(email: "pug@dogs.example")
        guard case let .servers(found) = result else { Issue.record("expected servers, got \(result)"); return }
        #expect(found.source == .triedServers)
        #expect(found.incoming == ServerSettings(mailProtocol: .imap, host: "mail.dogs.example", security: .tls, username: "pug@dogs.example"))
        #expect(found.outgoing == ServerSettings(mailProtocol: .smtp, host: "mail.dogs.example", security: .tls, username: "pug@dogs.example"))
        #expect(found.otherIncoming?.host == "pop.dogs.example")
        #expect(!probe.tried.contains { $0.contains("password") })
    }

    @Test func aFilteringServicesExchangersArentTriedButItsCompanysNamesAre() async {
        let dns = FakeDNS(exchangers: ["dogs.example": ["mx1.hosting.example"]])
        let probe = FakeProbe(answering: ["imap:imap.hosting.example:993", "smtp:smtp.hosting.example:465"])
        let result = await lookup(dns: dns, probe: probe).lookUp(email: "pug@dogs.example")
        guard case let .servers(found) = result else { Issue.record("expected servers, got \(result)"); return }
        #expect(found.incoming.host == "imap.hosting.example" && found.outgoing.host == "smtp.hosting.example")
        #expect(!probe.tried.contains { $0.contains("mx1.hosting.example") })
    }

    @Test func nothingFoundSaysSo() async {
        #expect(await lookup().lookUp(email: "pug@nowhere.example") == .notFound)
    }

    @Test func dnsRecordDataReads() {
        // MX 10 mail.example.org
        let mx = Data([0, 10, 4] + Array("mail".utf8) + [7] + Array("example".utf8) + [3] + Array("org".utf8) + [0])
        #expect(DNSRecordData.mailExchanger(mx)?.preference == 10 && DNSRecordData.mailExchanger(mx)?.host == "mail.example.org")
        // SRV 0 5 993 imap.example.org, and one saying there's no such service (".").
        let srv = Data([0, 0, 0, 5, 3, 225, 4] + Array("imap".utf8) + [7] + Array("example".utf8) + [3] + Array("org".utf8) + [0])
        #expect(DNSRecordData.service(srv) == ServiceRecord(host: "imap.example.org", port: 993, priority: 0, weight: 5))
        #expect(DNSRecordData.service(Data([0, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(DNSRecordData.name(in: [0xC0, 0x0C], from: 0) == nil, "a pointer elsewhere can't be followed")
        #expect(MailSettingsLookup.registeredDomain(of: "mx1.mail.example.co.uk") == "example.co.uk")
        #expect(MailSettingsLookup.registeredDomain(of: "aspmx.l.google.com") == "google.com")
    }

    @Test func greetingsAreRecognized() {
        #expect(NetworkMailServerProbe.isGreeting("* OK [CAPABILITY IMAP4rev1] ready\r\n", for: .imap))
        #expect(NetworkMailServerProbe.isGreeting("+OK POP3 ready\r\n", for: .pop3))
        #expect(NetworkMailServerProbe.isGreeting("220 mail.example.org ESMTP\r\n", for: .smtp))
        #expect(!NetworkMailServerProbe.isGreeting("HTTP/1.1 400 Bad Request\r\n", for: .imap))
    }

    /// Looks up a real address (PMAIL_LIVE_LOOKUP_EMAIL) through the Mac's DNS and its servers' greetings, for checking
    /// by hand. Skipped unless that's set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PMAIL_LIVE_LOOKUP_EMAIL"] != nil))
    func aRealAddressCanBeLookedUp() async {
        let email = ProcessInfo.processInfo.environment["PMAIL_LIVE_LOOKUP_EMAIL"] ?? ""
        let started = Date()
        let result = await MailSettingsLookup().lookUp(email: email)
        print("LIVE LOOKUP after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(result)")
        #expect(result != .notFound)
    }
}
