import dnssd
import Foundation

/// A server an SRV record names.
public struct ServiceRecord: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var priority: Int
    public var weight: Int

    public init(host: String, port: Int, priority: Int = 0, weight: Int = 0) {
        self.host = host
        self.port = port
        self.priority = priority
        self.weight = weight
    }
}

/// The DNS records looking up an address's mail servers needs: who handles a domain's mail (MX) and where its mail
/// services are (SRV).
public protocol DNSRecordLookup: Sendable {
    /// The servers that take the domain's mail, most preferred first; none when it has none or DNS can't say.
    func mailExchangers(for domain: String) async -> [String]
    /// The servers an SRV record names for a service ("_imaps._tcp.example.com"), most preferred first. A record
    /// that says the service isn't offered (a target of ".") gives none.
    func services(_ name: String) async -> [ServiceRecord]
}

/// DNS through the Mac's own resolver (DNS Service Discovery), which the app sandbox allows.
public struct SystemDNS: DNSRecordLookup {
    /// Seconds a query waits for its answer.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func mailExchangers(for domain: String) async -> [String] {
        let answers = await Self.query(domain, type: UInt16(kDNSServiceType_MX), timeout: timeout)
        return answers.compactMap(DNSRecordData.mailExchanger).sorted { $0.preference < $1.preference }.map(\.host)
    }

    public func services(_ name: String) async -> [ServiceRecord] {
        let answers = await Self.query(name, type: UInt16(kDNSServiceType_SRV), timeout: timeout)
        return DNSRecordData.ordered(answers.compactMap(DNSRecordData.service))
    }

    /// The data of each record of a type for a name. A name with none (or no answer in time) gives none.
    static func query(_ name: String, type: UInt16, timeout: TimeInterval) async -> [Data] {
        await withCheckedContinuation { continuation in
            let pending = PendingQuery(type: type, continuation: continuation)
            let context = Unmanaged.passRetained(pending).toOpaque()
            var reference: DNSServiceRef?
            // Negative answers come back too (rather than nothing until the time runs out).
            let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout)
            let status = DNSServiceQueryRecord(&reference, flags, 0, name, type, UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, type, _, length, data, _, context in
                guard let context else { return }
                let pending = Unmanaged<PendingQuery>.fromOpaque(context).takeUnretainedValue()
                if error == kDNSServiceErr_NoError, type == pending.type, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data {
                    pending.add(Data(bytes: data, count: Int(length)))
                }
                if error != kDNSServiceErr_NoError || flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { pending.finish() }
            }, context)
            guard status == kDNSServiceErr_NoError, let reference else {
                Unmanaged<PendingQuery>.fromOpaque(context).release()
                continuation.resume(returning: [])
                return
            }
            pending.start(reference, context: context, timeout: timeout)
        }
    }
}

/// One query in flight: the answers so far, finished once (by the last answer, an error or the time running out),
/// on a queue of its own.
private final class PendingQuery: @unchecked Sendable {
    let type: UInt16
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Data], Never>?
    private var answers: [Data] = []
    private var reference: DNSServiceRef?
    private var context: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "com.pugglesoft.PMail.dns")

    init(type: UInt16, continuation: CheckedContinuation<[Data], Never>) {
        self.type = type
        self.continuation = continuation
    }

    func start(_ reference: DNSServiceRef, context: UnsafeMutableRawPointer, timeout: TimeInterval) {
        queue.sync {
            lock.withLock {
                self.reference = reference
                self.context = context
            }
            DNSServiceSetDispatchQueue(reference, queue)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in finish() }
    }

    func add(_ data: Data) {
        lock.withLock { answers.append(data) }
    }

    /// Hands the answers back and lets the query go. Runs on the query's queue (DNS-SD calls back there).
    func finish() {
        let (waiting, found, reference, context) = lock.withLock { () -> (CheckedContinuation<[Data], Never>?, [Data], DNSServiceRef?, UnsafeMutableRawPointer?) in
            defer {
                continuation = nil
                self.reference = nil
                self.context = nil
            }
            return (continuation, answers, self.reference, self.context)
        }
        guard let waiting else { return }
        if let reference { DNSServiceRefDeallocate(reference) }
        waiting.resume(returning: found)
        if let context { Unmanaged<PendingQuery>.fromOpaque(context).release() }
    }
}

/// Reading MX and SRV record data (RFC 1035, RFC 2782).
enum DNSRecordData {
    /// An MX record's preference and host.
    static func mailExchanger(_ data: Data) -> (preference: Int, host: String)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, let host = name(in: bytes, from: 2), !host.isEmpty else { return nil }
        return (Int(bytes[0]) << 8 | Int(bytes[1]), host)
    }

    /// An SRV record's server; nil for one saying the service isn't offered (a target of ".").
    static func service(_ data: Data) -> ServiceRecord? {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, let host = name(in: bytes, from: 6), !host.isEmpty else { return nil }
        func number(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        return ServiceRecord(host: host, port: number(4), priority: number(0), weight: number(2))
    }

    /// A domain name written as labels ("\u{4}mail\u{7}example\u{3}com\u{0}"), without the root's dot. Names that
    /// point elsewhere in a message (compression) or run past the end can't be read here.
    static func name(in bytes: [UInt8], from start: Int) -> String? {
        var labels: [String] = []
        var index = start
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { return labels.joined(separator: ".").lowercased() }
            guard length < 64, index + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(index + 1)...(index + length)], as: UTF8.self))
            index += 1 + length
        }
        return nil
    }

    /// Servers in the order to try them: lowest priority first, the heaviest first among equals (RFC 2782 leaves
    /// the order among those to chance; trying the heaviest first is steady and close).
    static func ordered(_ records: [ServiceRecord]) -> [ServiceRecord] {
        records.sorted { ($0.priority, -$0.weight, $0.host) < ($1.priority, -$1.weight, $1.host) }
    }
}
