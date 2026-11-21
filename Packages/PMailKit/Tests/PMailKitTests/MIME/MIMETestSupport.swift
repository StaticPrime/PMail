import Foundation
@testable import PMailKit

/// A message written as a string literal, with its LF line ends turned into CRLF as they are on the wire.
func mimeWire(_ text: String) -> Data {
    Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

/// Header text (LF line ends, turned into CRLF), a blank line, then body bytes exactly as given.
func mimeWire(_ headers: String, body: [UInt8]) -> Data {
    mimeWire(headers + "\n\n") + Data(body)
}

/// Repeatable pseudo-random bytes, for feeding the parser garbage.
func mimeGarbage(count: Int, seed: UInt64) -> Data {
    var state = seed
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes.append(UInt8(truncatingIfNeeded: state >> 33))
    }
    return Data(bytes)
}

extension Data {
    /// The bytes as text, for looking inside built messages.
    var mimeText: String { String(decoding: self, as: UTF8.self) }
}
