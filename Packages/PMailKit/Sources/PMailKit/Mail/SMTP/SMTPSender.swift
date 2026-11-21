import Foundation

/// Sends finished messages through an account's SMTP server, with a connection of its own for each message.
public struct SMTPSender: MailSending {
    public let settings: ServerSettings
    private let credential: Credential
    private let connector: any ByteStreamConnector

    public init(settings: ServerSettings, credential: Credential, connector: any ByteStreamConnector = URLSessionConnector()) {
        self.settings = settings
        self.credential = credential
        self.connector = connector
    }

    public func send(_ raw: Data, from sender: String, to recipients: [String]) async throws {
        let client = SMTPClient(settings: settings, credential: credential, connector: connector)
        try await client.send(raw, from: sender, to: recipients)
    }
}
