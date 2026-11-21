import Foundation

/// A two-way byte stream to a server: TCP, protected by TLS from the start or after STARTTLS.
public protocol ByteStream: AnyObject, Sendable {
    /// The bytes that have arrived, at least one; empty data once the server has closed the connection.
    func read() async throws -> Data
    func write(_ data: Data) async throws
    /// Switches the connection to TLS, after the server accepted STARTTLS. Nothing may be waiting unread.
    func startTLS() async throws
    func close()
}

/// Opens byte streams. Tests give the protocol clients a scripted one instead of the network.
public protocol ByteStreamConnector: Sendable {
    /// Connects to `host:port`. With `.tls` the stream is encrypted from the start; with `.startTLS` or `.none` it
    /// starts plain, and the protocol client calls `startTLS()` once the server agrees.
    func connect(host: String, port: Int, security: ConnectionSecurity) async throws -> any ByteStream
}

/// Real connections, through URLSession stream tasks (which take part in the app sandbox's network permission and
/// check server certificates the way the system does).
public struct URLSessionConnector: ByteStreamConnector {
    /// Seconds to wait for each read or write before giving up.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 90) {
        self.timeout = timeout
    }

    public func connect(host: String, port: Int, security: ConnectionSecurity) async throws -> any ByteStream {
        let stream = URLSessionByteStream(host: host, port: port, timeout: timeout)
        if security == .tls { try await stream.startTLS() }
        return stream
    }
}

/// A `ByteStream` over a `URLSessionStreamTask`.
public final class URLSessionByteStream: ByteStream, @unchecked Sendable {
    private let task: URLSessionStreamTask
    private let session: URLSession
    private let timeout: TimeInterval

    public init(host: String, port: Int, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        task.resume()
    }

    deinit {
        task.cancel()
        session.invalidateAndCancel()
    }

    public func read() async throws -> Data {
        do {
            let (data, atEnd) = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout)
            if let data, !data.isEmpty { return data }
            if atEnd { return Data() }
            throw PMailError.timedOut
        } catch let error as PMailError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    public func write(_ data: Data) async throws {
        do {
            try await task.write(data, timeout: timeout)
        } catch {
            throw Self.translate(error)
        }
    }

    public func startTLS() async throws {
        task.startSecureConnection()
    }

    public func close() {
        task.closeWrite()
        task.closeRead()
        task.cancel()
    }

    private static func translate(_ error: Error) -> PMailError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed:
                return .connectionFailed("the server’s security certificate isn’t valid")
            default: break
            }
        }
        return .connectionFailed(nsError.localizedDescription)
    }
}

/// Reads a line-based protocol (IMAP, SMTP, POP) from a byte stream: whole CRLF-ended lines, or a given number of
/// bytes (IMAP literals). One connection per actor, used from one task at a time.
public actor LineConnection {
    public let stream: any ByteStream
    private var buffer = Data()
    private var start = 0
    /// Every line written and read, for diagnosing a failed connection, when set.
    public var transcript: [String]?

    public init(stream: any ByteStream) {
        self.stream = stream
    }

    public func startTranscript() { transcript = [] }

    /// The next line, without its CRLF (a bare LF also ends a line). Throws `connectionFailed` if the server closes
    /// the connection first.
    public func readLine(maximumLength: Int = 64 * 1024 * 1024) async throws -> Data {
        while true {
            if let newline = buffer[start...].firstIndex(of: 0x0A) {
                var end = newline
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                let line = buffer.subdata(in: start..<end)
                start = newline + 1
                compact()
                transcript?.append("S: " + String(decoding: line.prefix(500), as: UTF8.self))
                return line
            }
            if buffer.count - start > maximumLength { throw PMailError.protocolError("a line from the server was too long") }
            try await fill()
        }
    }

    /// The next line as text (UTF-8, with anything that isn't valid UTF-8 replaced).
    public func readLineString() async throws -> String {
        String(decoding: try await readLine(), as: UTF8.self)
    }

    /// Exactly `count` bytes.
    public func readBytes(_ count: Int) async throws -> Data {
        while buffer.count - start < count { try await fill() }
        let data = buffer.subdata(in: start..<(start + count))
        start += count
        compact()
        return data
    }

    public func write(_ data: Data) async throws {
        transcript?.append("C: " + String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .newlines))
        try await stream.write(data)
    }

    /// Writes a line, adding the CRLF.
    public func writeLine(_ line: String) async throws {
        try await write(Data((line + "\r\n").utf8))
    }

    /// Writes a line that holds a secret (a password, a token), keeping it out of the transcript.
    public func writeSecretLine(_ line: String, shownAs placeholder: String) async throws {
        transcript?.append("C: " + placeholder)
        try await stream.write(Data((line + "\r\n").utf8))
    }

    /// Switches to TLS after STARTTLS. Throws if the server sent anything more first (that would be an attack).
    public func startTLS() async throws {
        guard buffer.count == start else { throw PMailError.protocolError("the server sent data before encryption started") }
        try await stream.startTLS()
    }

    public func close() {
        stream.close()
    }

    private func fill() async throws {
        let data = try await stream.read()
        if data.isEmpty { throw PMailError.connectionFailed("the server closed the connection") }
        buffer.append(data)
    }

    private func compact() {
        if start > 64 * 1024, start > buffer.count / 2 {
            buffer.removeSubrange(0..<start)
            start = 0
        } else if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
    }
}
