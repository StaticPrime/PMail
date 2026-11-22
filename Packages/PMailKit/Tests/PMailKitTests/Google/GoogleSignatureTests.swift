import Foundation
import Testing
@testable import PMailKit

/// The signature of a Google account, kept with its own send-as address.
@Suite struct GoogleSignatureTests {
    static let api = "/gmail/v1/users/me"

    @Test func theSignatureComesFromAndGoesToTheAccountsOwnAddress() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/settings/sendAs") { _ in
            .json(#"""
            {"sendAs": [{"sendAsEmail": "alias@example.com", "signature": "Not this one"},
                        {"sendAsEmail": "jamie@gmail.com", "isPrimary": true, "signature": "<b>Jamie</b> <img src=\"https://example.com/logo.png\">"}]}
            """#)
        }
        transport.on("PATCH", "\(Self.api)/settings/sendAs/jamie@gmail.com") { _ in .json(#"{"sendAsEmail": "jamie@gmail.com"}"#) }
        let service = GoogleMailService(email: "jamie@gmail.com", client: .test(transport))
        #expect(service.capabilities.syncsSignature)
        #expect(try await service.loadSignature() == #"<b>Jamie</b> <img src="https://example.com/logo.png">"#)
        try await service.saveSignature(html: "<i>Jamie</i>")
        let patch = try #require(transport.sent("PATCH", "\(Self.api)/settings/sendAs/").first)
        #expect(patch.bodyJSONValue["signature"].string == "<i>Jamie</i>")
    }

    @Test func noSignatureIsNil() async throws {
        let transport = StubTransport()
        transport.on("GET", "\(Self.api)/settings/sendAs") { _ in
            .json(#"{"sendAs": [{"sendAsEmail": "jamie@gmail.com", "isPrimary": true, "signature": "  "}]}"#)
        }
        #expect(try await GoogleMailService(email: "jamie@gmail.com", client: .test(transport)).loadSignature() == nil)
    }
}
