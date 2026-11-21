import Foundation
@testable import PMailKit

/// A pretend server for protocol tests. It sends its greeting, then answers each line the client writes with the
/// response the script gives for it, checking the client wrote what the script expected.
///
///     let stream = ScriptedByteStream(greeting: "* OK ready\r\n", script: [
///         .expect("A1 CAPABILITY", reply: "* CAPABILITY IMAP4rev1\r\nA1 OK done\r\n"),
///     ])
///
/// An expectation can be a prefix (`.expectPrefix`) for lines with generated parts (tags, base64). After the script
/// runs out, writes are recorded and get no answer. `mismatches` lists anything that didn't match.
final class ScriptedByteStream: ByteStream, @unchecked Sendable {
    enum Step {
        case expect(String, reply: String)
        case expectPrefix(String, reply: String)
        /// Takes `count` raw bytes (an IMAP literal's contents, a message's DATA) before the next step.
        case expectBytes(Int, reply: String)
    }

    private let lock = NSLock()
    private var pending = Data()
    private var steps: [Step]
    private var written = Data()
    private var waiting: CheckedContinuation<Data, Error>?
    private(set) var lines: [String] = []
    private(set) var mismatches: [String] = []
    private(set) var tlsStarted = false
    private(set) var closed = false

    init(greeting: String = "", script: [Step]) {
        pending = Data(greeting.utf8)
        steps = script
    }

    /// Everything the client wrote, as text.
    var writtenText: String { lock.withLock { String(decoding: written, as: UTF8.self) } }

    /// The lines written so far, safe to read while the client is still busy on another task.
    var linesSoFar: [String] { lock.withLock { lines } }

    var isFinished: Bool { lock.withLock { steps.isEmpty } }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            if let data = takePendingOrWait(continuation) { continuation.resume(returning: data) }
        }
    }

    /// Returns what's waiting to be read, or parks the reader until a write produces a reply.
    private func takePendingOrWait(_ continuation: CheckedContinuation<Data, Error>) -> Data? {
        lock.withLock {
            if !pending.isEmpty {
                let data = pending
                pending = Data()
                return data
            }
            if closed { return Data() }
            waiting = continuation
            return nil
        }
    }

    func write(_ data: Data) async throws {
        if let (continuation, reply) = accept(data) { continuation.resume(returning: reply) }
    }

    /// Takes what the client wrote, works out the replies, and hands them to a waiting reader if there is one.
    private func accept(_ data: Data) -> (CheckedContinuation<Data, Error>, Data)? {
        lock.withLock {
            written.append(data)
            var replies = Data()
            processWritten(into: &replies)
            if !replies.isEmpty { pending.append(replies) }
            guard !pending.isEmpty, let continuation = waiting else { return nil }
            waiting = nil
            let reply = pending
            pending = Data()
            return (continuation, reply)
        }
    }

    func startTLS() async throws {
        lock.withLock { tlsStarted = true }
    }

    func close() {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            closed = true
            let continuation = waiting
            waiting = nil
            return continuation
        }
        continuation?.resume(returning: Data())
    }

    /// Consumes whole lines (or byte counts) from what the client wrote, matching them against the script.
    private func processWritten(into replies: inout Data) {
        while let step = steps.first {
            switch step {
            case let .expectBytes(count, reply):
                guard written.count >= count else { return }
                written.removeSubrange(0..<count)
                steps.removeFirst()
                replies.append(Data(reply.utf8))
            case let .expect(expected, reply), let .expectPrefix(expected, reply):
                guard let newline = written.firstIndex(of: 0x0A) else { return }
                var lineData = written[written.startIndex..<newline]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                let line = String(decoding: lineData, as: UTF8.self)
                written.removeSubrange(written.startIndex...newline)
                lines.append(line)
                steps.removeFirst()
                let matches: Bool
                if case .expectPrefix = step { matches = line.hasPrefix(expected) } else { matches = line == expected }
                if !matches { mismatches.append("expected \"\(expected)\", got \"\(line)\"") }
                replies.append(Data(reply.utf8))
            }
        }
        // Past the script: keep the lines for the test to look at.
        while let newline = written.firstIndex(of: 0x0A) {
            var lineData = written[written.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            written.removeSubrange(written.startIndex...newline)
        }
    }
}

/// Hands out scripted streams in order, recording where each "connection" went.
final class ScriptedConnector: ByteStreamConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [ScriptedByteStream]
    private(set) var connections: [(host: String, port: Int, security: ConnectionSecurity)] = []

    init(_ streams: [ScriptedByteStream]) {
        self.streams = streams
    }

    func connect(host: String, port: Int, security: ConnectionSecurity) async throws -> any ByteStream {
        try lock.withLock {
            connections.append((host, port, security))
            guard !streams.isEmpty else { throw PMailError.connectionFailed("no more scripted connections") }
            return streams.removeFirst()
        }
    }
}
