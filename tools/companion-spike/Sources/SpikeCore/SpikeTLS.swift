import Foundation
import Network
import Security

public enum SpikeTransportError: Error, Equatable, Sendable {
    case timedOut, cancelled, closed, invalidEndpoint, invalidTLS, frameTooLarge, emptyFrame
}

/// Counts decisions, never certificate/key data. Negative tests must observe an
/// actual trust decision instead of mistaking a dead route for authentication.
public final class SpikeTrustObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = 0
    public init() {}
    public var rejections: Int { lock.withLock { rejected } }
    fileprivate func record(_ accepted: Bool) { if !accepted { lock.withLock { rejected += 1 } } }
}

/// Resolves cancellation, deadline and a Network callback exactly once. The callback
/// may arrive after cancellation; it cannot resume the continuation a second time.
private final class Pending<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var timer: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let completed = lock.withLock { () -> Result<Value, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil as Result<Value, any Error>?
        }
        if let completed { continuation.resume(with: completed) }
    }

    @discardableResult func resolve(_ outcome: Result<Value, any Error>) -> Bool {
        let (won, callback) = lock.withLock { () -> (Bool, CheckedContinuation<Value, any Error>?) in
            guard result == nil else { return (false, nil) }
            result = outcome
            timer?.cancel()
            timer = nil
            let callback = continuation
            continuation = nil
            return (true, callback)
        }
        callback?.resume(with: outcome)
        return won
    }

    func arm(seconds: TimeInterval, abort: @escaping @Sendable () -> Void) {
        let timeout = DispatchWorkItem { [weak self] in
            if self?.resolve(.failure(SpikeTransportError.timedOut)) == true { abort() }
        }
        let shouldSchedule = lock.withLock {
            guard result == nil else { return false }
            timer = timeout
            return true
        }
        if shouldSchedule { DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds), execute: timeout) }
    }
}

private func bounded<Value: Sendable>(
    timeout: TimeInterval,
    abort: @escaping @Sendable () -> Void,
    start: @escaping @Sendable (Pending<Value>) -> Void
) async throws -> Value {
    guard timeout > 0 else { abort(); throw SpikeTransportError.timedOut }
    let pending = Pending<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            pending.install(continuation)
            pending.arm(seconds: timeout, abort: abort)
            start(pending)
        }
    } onCancel: {
        pending.resolve(.failure(SpikeTransportError.cancelled))
        abort()
    }
}

private enum TLSPolicy {
    static let alpn = "darkbloom-companion/1"
    static let queue = DispatchQueue(label: "companion.spike.tls-verification")

    static func parameters(identity: SpikeIdentity?, pin: Data, peerRole: SpikeRole,
                           observations: SpikeTrustObservations? = nil,
                           authorized: @escaping @Sendable () -> Bool = { true }) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, alpn)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        if peerRole == .host { sec_protocol_options_set_tls_server_name(options, "companion-spike.invalid") }
        if let identity, let native = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, native)
        }
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let native = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = SecTrustCopyCertificateChain(native) as? [SecCertificate] ?? []
            let accepted = authorized() && SpikeTrust.validate(chain, expectedSPKI: pin, role: peerRole)
            observations?.record(accepted)
            complete(accepted)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func validNegotiation(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        let security = metadata.securityProtocolMetadata
        guard sec_protocol_metadata_get_negotiated_tls_protocol_version(security) == .TLSv13 else { return false }
        // The copy API requires iOS 18.5/macOS 15.5; keep the candidate iOS 17/macOS 14 floor.
        guard let protocolName = sec_protocol_metadata_get_negotiated_protocol(security) else { return false }
        return String(cString: protocolName) == alpn
    }
}

/// Test-only framed native TLS socket. Each instance supports one sequential
/// reader and writer; frames are bounded independently of the embedded route.
public final class SpikeTLSConnection: @unchecked Sendable {
    public static let maximumFrame = 256 * 1024
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "companion.spike.connection")

    fileprivate init(_ connection: NWConnection) { self.connection = connection }

    public static func connect(port: UInt16, identity: SpikeIdentity?, expectedHostSPKI: Data,
                               observations: SpikeTrustObservations? = nil,
                               timeout: TimeInterval = 10) async throws -> SpikeTLSConnection {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SpikeTransportError.invalidEndpoint }
        let parameters = TLSPolicy.parameters(identity: identity, pin: expectedHostSPKI, peerRole: .host, observations: observations)
        let connection = SpikeTLSConnection(NWConnection(host: .ipv4(.loopback), port: endpointPort, using: parameters))
        try await connection.start(timeout: timeout)
        return connection
    }

    fileprivate func start(timeout: TimeInterval = 10) async throws {
        try await bounded(timeout: timeout, abort: { self.cancel() }) { (pending: Pending<Void>) in
            self.connection.stateUpdateHandler = { [weak socket = self] state in
                guard let socket else { pending.resolve(.failure(SpikeTransportError.closed)); return }
                switch state {
                case .ready:
                    socket.connection.stateUpdateHandler = nil
                    if TLSPolicy.validNegotiation(socket.connection) { pending.resolve(.success(())) }
                    else { pending.resolve(.failure(SpikeTransportError.invalidTLS)); socket.cancel() }
                case .failed(let error): socket.connection.stateUpdateHandler = nil; pending.resolve(.failure(error)); socket.cancel()
                case .waiting(let error): socket.connection.stateUpdateHandler = nil; pending.resolve(.failure(error)); socket.cancel()
                case .cancelled: socket.connection.stateUpdateHandler = nil; pending.resolve(.failure(SpikeTransportError.cancelled))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    public func cancel() { connection.cancel() }

    public func send(_ payload: Data, timeout: TimeInterval = 10) async throws {
        guard !payload.isEmpty else { throw SpikeTransportError.emptyFrame }
        guard payload.count <= Self.maximumFrame else { throw SpikeTransportError.frameTooLarge }
        let size = UInt32(payload.count)
        var frame = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        frame.append(payload)
        try await sendUnframedForTesting(frame, timeout: timeout)
    }

    // Internal malformed-frame injection for the standalone test target only.
    func sendUnframedForTesting(_ bytes: Data, timeout: TimeInterval = 10) async throws {
        try await bounded(timeout: timeout, abort: { self.cancel() }) { (pending: Pending<Void>) in
            self.connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { pending.resolve(.failure(error)) }
                else { pending.resolve(.success(())) }
            })
        }
    }

    public func receive(timeout: TimeInterval = 10) async throws -> Data {
        let began = ContinuousClock.now
        let header = try await readExactly(4, timeout: timeout)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0 else { cancel(); throw SpikeTransportError.emptyFrame }
        guard count <= Self.maximumFrame else { cancel(); throw SpikeTransportError.frameTooLarge }
        let elapsed = began.duration(to: .now).components
        let remaining = timeout - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
        return try await readExactly(Int(count), timeout: remaining)
    }

    private func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        try await bounded(timeout: timeout, abort: { self.cancel() }) { pending in
            self.connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { pending.resolve(.failure(error)) }
                else if let data, data.count == count { pending.resolve(.success(data)) }
                else { pending.resolve(.failure(SpikeTransportError.closed)) }
            }
        }
    }
}

/// Fixed-loopback synthetic host; it cannot run processes or read app state.
public final class SpikeTLSServer: @unchecked Sendable {
    private struct Session {
        let connection: SpikeTLSConnection
        let task: Task<Void, Never>
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var revoked = false
        var stopped = false
        var requests = 0
        var sessions: [UUID: Session] = [:]
    }
    private let state: State
    public let phoneTrust = SpikeTrustObservations()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "companion.spike.listener")
    // Only bounded synchronous synthetic transforms belong here. Real operations
    // need the later command policy/journal; they cannot be supplied as callbacks.
    private let respond: @Sendable (Data) throws -> Data
    private let frameTimeout: TimeInterval

    public init(identity: SpikeIdentity, allowedPhoneSPKI: Data,
                frameTimeout: TimeInterval = 10,
                respond: @escaping @Sendable (Data) throws -> Data = { $0 }) throws {
        let state = State()
        self.state = state
        self.respond = respond
        self.frameTimeout = min(10, max(0.01, frameTimeout))
        let parameters = TLSPolicy.parameters(identity: identity, pin: allowedPhoneSPKI, peerRole: .phone, observations: phoneTrust) {
            state.lock.withLock { !state.revoked && !state.stopped }
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    public var activeConnections: Int { state.lock.withLock { state.sessions.count } }
    public var applicationRequests: Int { state.lock.withLock { state.requests } }

    public func start() async throws -> UInt16 {
        try await bounded(timeout: 10, abort: { self.listener.cancel() }) { pending in
            self.listener.newConnectionHandler = { [weak server = self] connection in
                guard let server else { connection.cancel(); return }
                server.accept(connection)
            }
            self.listener.stateUpdateHandler = { [weak server = self] status in
                switch status {
                case .ready:
                    guard let port = server?.listener.port else { pending.resolve(.failure(SpikeTransportError.invalidEndpoint)); return }
                    pending.resolve(.success(port.rawValue))
                case .failed(let error): pending.resolve(.failure(error))
                case .cancelled: pending.resolve(.failure(SpikeTransportError.cancelled))
                default: break
                }
            }
            self.listener.start(queue: self.queue)
        }
    }

    private func accept(_ native: NWConnection) {
        state.lock.withLock {
            guard !state.revoked, !state.stopped, state.sessions.count < 8 else { native.cancel(); return }
            let id = UUID()
            let connection = SpikeTLSConnection(native)
            let task = Task {
                defer {
                    connection.cancel()
                    _ = self.state.lock.withLock { self.state.sessions.removeValue(forKey: id) }
                }
                do {
                    try await connection.start()
                    while !Task.isCancelled {
                        let frame = try await connection.receive(timeout: self.frameTimeout)
                        let allowed = self.state.lock.withLock {
                            guard !self.state.revoked && !self.state.stopped else { return false }
                            self.state.requests += 1
                            return true
                        }
                        guard allowed else { return }
                        let reply = try self.respond(frame)
                        try await connection.send(reply)
                    }
                } catch { /* Expected rejection/timeout; no certificate or payload logging. */ }
            }
            state.sessions[id] = Session(connection: connection, task: task)
        }
    }

    public func revokePhone() {
        let sessions = state.lock.withLock {
            state.revoked = true
            return Array(state.sessions.values)
        }
        for session in sessions { session.connection.cancel(); session.task.cancel() }
    }

    public func stop() async {
        let sessions = state.lock.withLock {
            state.stopped = true
            return Array(state.sessions.values)
        }
        listener.cancel()
        for session in sessions { session.connection.cancel(); session.task.cancel() }
        for session in sessions { await session.task.value }
    }
}
