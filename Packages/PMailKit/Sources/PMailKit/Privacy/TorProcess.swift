import Darwin
import Foundation
import os

/// Something that runs Tor and says how it's going: the Tor Project's program (`TorProcess`), or a stand-in.
public protocol TorRunner: AnyObject, Sendable {
    func start() throws
    func stop()
}

/// What Tor says as it runs.
public enum TorEvent: Sendable, Equatable {
    /// How far along connecting it is, in percent, and what it's doing (100 is connected).
    case progress(Int, String)
    /// A warning or error it printed.
    case problem(String)
    /// It stopped, with its exit status.
    case exited(Int32)
}

/// Tor's own client program, run beside PMail for Settings ▸ Privacy ▸ Hide IP address. PMail starts it with
/// everything it needs on the command line: a client only, a SOCKS port on the Mac's loopback address, each server
/// reached over a circuit of its own, and notices printed, which is how PMail follows it. Tor also quits by itself if
/// PMail goes away without stopping it.
public final class TorProcess: TorRunner, @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        public var executable: URL
        public var dataDirectory: URL
        public var socksPort: Int
        /// PMail's process: Tor watches it, and quits when it's gone.
        public var owner: Int32

        public init(executable: URL, dataDirectory: URL, socksPort: Int, owner: Int32 = ProcessInfo.processInfo.processIdentifier) {
            self.executable = executable
            self.dataDirectory = dataDirectory
            self.socksPort = socksPort
            self.owner = owner
        }

        /// The command line. No configuration files are read: everything is here. (A client needs no GeoIP files;
        /// pointing them into its own folder keeps Tor from looking anywhere outside PMail's.)
        public var arguments: [String] {
            ["-f", "/dev/null", "--defaults-torrc", "/dev/null", "--ignore-missing-torrc",
             "--DataDirectory", dataDirectory.path,
             "--GeoIPFile", dataDirectory.appendingPathComponent("geoip").path,
             "--GeoIPv6File", dataDirectory.appendingPathComponent("geoip6").path,
             "--SocksPort", "127.0.0.1:\(socksPort) IsolateDestAddr",
             "--ClientOnly", "1",
             "--AvoidDiskWrites", "1",
             "--Log", "notice stdout",
             "--__OwningControllerProcess", String(owner)]
        }
    }

    public let settings: Settings
    private let onEvent: @Sendable (TorEvent) -> Void
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var pending = Data()
    private var exitStatus: Int32?
    private var outputEnded = false
    private var finished = false

    /// `onEvent` is called on a background queue.
    public init(settings: Settings, onEvent: @escaping @Sendable (TorEvent) -> Void) {
        self.settings = settings
        self.onEvent = onEvent
    }

    public func start() throws {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: settings.executable.path) else {
            throw PMailError.notConfigured("Tor isn’t in this copy of PMail.")
        }
        try manager.createDirectory(at: settings.dataDirectory, withIntermediateDirectories: true)
        // Tor refuses a data directory anyone else can read.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: settings.dataDirectory.path)
        process.executableURL = settings.executable
        process.arguments = settings.arguments
        process.currentDirectoryURL = settings.dataDirectory
        process.environment = ["HOME": settings.dataDirectory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                lock.withLock { outputEnded = true }
                finishIfDone()
            } else {
                received(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            lock.withLock { exitStatus = process.terminationStatus }
            finishIfDone()
            // Its last words normally arrive first; if they don't come within a second, it ends without them.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.finishIfDone(force: true) }
        }
        try process.run()
    }

    /// Says it exited, once it has and what it printed has all been read.
    private func finishIfDone(force: Bool = false) {
        let status: Int32? = lock.withLock {
            guard !finished, let exitStatus, outputEnded || force else { return nil }
            finished = true
            return exitStatus
        }
        guard let status else { return }
        if force { output.fileHandleForReading.readabilityHandler = nil }
        received(Data([0x0A]))
        onEvent(.exited(status))
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

    /// Hands on each whole line as it arrives.
    private func received(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending += data
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
        for line in lines {
            if let event = Self.event(fromLine: line) { onEvent(event) }
        }
    }

    /// What a line Tor printed says, if it's something PMail follows: its progress connecting (as Tor has printed it
    /// since 0.4: `Bootstrapped 45% (loading_descriptors): Loading relay descriptors`, and before), and its warnings
    /// and errors.
    public static func event(fromLine line: String) -> TorEvent? {
        let text = line as NSString
        if let match = bootstrapped.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
           let percent = Int(text.substring(with: match.range(at: 1))) {
            return .progress(min(max(percent, 0), 100), text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces))
        }
        for marker in ["[err] ", "[warn] "] {
            if let range = line.range(of: marker) { return .problem(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }

    private static let bootstrapped = try! NSRegularExpression(pattern: #"Bootstrapped (\d+)%(?: \([^)]*\))?: (.*)$"#)

    /// A port on the loopback address that nothing is using, for Tor's SOCKS port.
    public static func freePort() -> Int? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic -> Bool in
                bind(socket, generic, length) == 0 && getsockname(socket, generic, &length) == 0
            }
        }
        guard bound else { return nil }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return port > 0 ? port : nil
    }
}

/// Holds requests until the way to the internet is ready (Tor connecting), then passes them on. While it isn't
/// ready, nothing goes anywhere: requests wait (as long as `timeout`), or are refused once it has failed.
public final class PendingFetcher: RemoteFetcher {
    private enum State: Sendable {
        case waiting
        case ready(any RemoteFetcher)
        case failed(String)
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .waiting)
    /// What a request that waited too long is told.
    public let waitingReason: String
    public let timeout: TimeInterval

    public init(waitingReason: String, timeout: TimeInterval = 120) {
        self.waitingReason = waitingReason
        self.timeout = timeout
    }

    /// Passes requests on to `fetcher` from now on, the waiting ones too.
    public func resolve(_ fetcher: any RemoteFetcher) { state.withLock { $0 = .ready(fetcher) } }

    /// Refuses requests from now on, the waiting ones too, saying why.
    public func fail(_ reason: String) { state.withLock { $0 = .failed(reason) } }

    /// Holds requests again (Tor is starting over).
    public func hold() { state.withLock { $0 = .waiting } }

    public var isReady: Bool {
        state.withLock { if case .ready = $0 { true } else { false } }
    }

    public func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state.withLock({ $0 }) {
            case let .ready(fetcher):
                return try await fetcher.fetch(request, limit: limit)
            case let .failed(reason):
                throw RemoteContentError.notSetUp(reason)
            case .waiting:
                guard Date() < deadline else { throw RemoteContentError.notSetUp(waitingReason) }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
