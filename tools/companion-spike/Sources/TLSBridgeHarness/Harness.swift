import Foundation
import Network
import SpikeCore
#if os(macOS)
import Darwin

private enum HarnessError: Error { case assertion(String), fixtureFailed, usage }

/// Only this child (started by this harness) is ever terminated. The synthetic
/// Go process has its own hard lifetime limit as a second line of defense.
private final class BridgeProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffered = Data()
    private var port: UInt16?
    private var malformed = false
    private var launched = false

    func start(binary: String, targetPort: UInt16) async throws -> UInt16 {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-test.run", "^TestSpikeProcess$", "-test.timeout", "120s"]
        // No provider credentials or inherited service environment enter the fixture.
        process.environment = ["SPIKE_TARGET_PORT": String(targetPort), "TS_NO_LOGS_NO_SUPPORT": "true", "GOMAXPROCS": "4"]
        let trace = ProcessInfo.processInfo.environment["SPIKE_TRACE"] == "1"
        if trace { process.environment?["SPIKE_TRACE"] = "1" }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.withLock {
                guard !self.malformed else { return }
                self.buffered.append(data)
                guard self.buffered.count <= 4096 else { self.malformed = true; return }
                if let end = self.buffered.firstIndex(of: 10), self.port == nil {
                    struct Ready: Decodable { let port: UInt16 }
                    if let ready = try? JSONDecoder().decode(Ready.self, from: self.buffered[..<end]), ready.port > 0 {
                        self.port = ready.port
                    } else { self.malformed = true }
                }
            }
        }
        // Drain diagnostics to prevent child pipe blockage; never print auth material.
        // Standalone Go tests separately inspect synthetic log canaries.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if trace, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") where line.hasPrefix("spike ") {
                    try? FileHandle.standardError.write(contentsOf: Data("\(line)\n".utf8))
                }
            }
        }
        try process.run()
        launched = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            let status = lock.withLock { (port, malformed) }
            if status.1 || !process.isRunning { throw HarnessError.fixtureFailed }
            if let port = status.0 { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessError.fixtureFailed
    }

    func stop() async -> Bool {
        try? input.fileHandleForWriting.close()
        guard launched else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let graceful = !process.isRunning
        if process.isRunning { process.terminate() }
        let terminationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning && ContinuousClock.now < terminationDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // waitUntilExit is bounded here by SIGKILL if graceful termination failed.
        if process.processIdentifier > 0 { process.waitUntilExit() }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        return graceful && process.terminationStatus == 0
    }
}

private struct Request: Codable, Sendable {
    enum Action: String, Codable { case snapshot, fakeStart, fakeStop, probe }
    var action: Action
    var padding: String = ""
}
private struct Reply: Codable, Sendable, Equatable {
    var synthetic = true
    var fakeProviderRunning: Bool
    var fakeMutationCount: Int
    var receivedPaddingBytes: Int
}
private final class FakeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var mutations = 0
    func respond(_ data: Data) throws -> Data {
        try lock.withLock { try handle(data) }
    }
    private func handle(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(Request.self, from: data)
        switch request.action {
        case .fakeStart: running = true; mutations += 1
        case .fakeStop: running = false; mutations += 1
        case .snapshot, .probe: break
        }
        return try JSONEncoder().encode(Reply(fakeProviderRunning: running, fakeMutationCount: mutations,
                                             receivedPaddingBytes: request.padding.utf8.count))
    }
}

@main struct Harness {
    static func emit(_ name: String, _ passed: Bool) {
        // Names and booleans only: never expose keys, certificate bytes or payloads.
        print("{\"assertion\":\"\(name)\",\"passed\":\(passed)}")
    }
    static func check(_ condition: Bool, _ name: String) throws {
        emit(name, condition)
        if !condition { throw HarnessError.assertion(name) }
    }
    private static func exchange(port: UInt16, phone: SpikeIdentity?, pin: Data, request: Request,
                                 observations: SpikeTrustObservations? = nil) async throws -> Reply {
        let connection = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: pin, observations: observations)
        defer { connection.cancel() }
        try await connection.send(JSONEncoder().encode(request))
        return try JSONDecoder().decode(Reply.self, from: await connection.receive())
    }
    static func rejected(port: UInt16, phone: SpikeIdentity?, pin: Data, requirePinDecision: Bool = false) async -> Bool {
        let observations = SpikeTrustObservations()
        do {
            _ = try await exchange(port: port, phone: phone, pin: pin, request: Request(action: .fakeStart), observations: observations)
            return false
        } catch {
            if let error = error as? SpikeTransportError, [.timedOut, .cancelled, .invalidEndpoint].contains(error) { return false }
            if error is CancellationError { return false }
            if let error = error as? NWError {
                switch error {
                case .posix(let code) where [.ECONNREFUSED, .ETIMEDOUT, .ECANCELED, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH].contains(code): return false
                case .dns: return false
                default: break
                }
            }
            return !requirePinDecision || observations.rejections == 1
        }
    }
    static func main() async {
        var server: SpikeTLSServer?
        var bridge: BridgeProcess?
        do {
            let args = CommandLine.arguments
            guard args.count == 1 || (args.count == 3 && args[1] == "--bridge") else { throw HarnessError.usage }
            let host = try SpikeIdentity.make(role: .host)
            let phone = try SpikeIdentity.make(role: .phone)
            let stranger = try SpikeIdentity.make(role: .phone)
            let wrongHost = try SpikeIdentity.make(role: .host)
            let fake = FakeHost()
            let listener = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256) { try fake.respond($0) }
            server = listener
            let nativePort = try await listener.start()
            let port: UInt16
            if args.count == 3 {
                let child = BridgeProcess()
                bridge = child
                port = try await child.start(binary: args[2], targetPort: nativePort)
            } else { port = nativePort }

            // First prove a working route, then the rejection boundary, then prove
            // subsequent legitimate traffic still works. No real action is exposed.
            let baseline = try await exchange(port: port, phone: phone, pin: host.spkiSHA256, request: Request(action: .snapshot))
            try check(baseline.synthetic && baseline.fakeMutationCount == 0, "routeHealthyBeforeRejectionProbes")
            try check(await rejected(port: port, phone: phone, pin: wrongHost.spkiSHA256, requirePinDecision: true), "wrongSPKIRejected")
            try check(await rejected(port: port, phone: nil, pin: host.spkiSHA256), "missingClientCertificateRejected")
            try check(await rejected(port: port, phone: stranger, pin: host.spkiSHA256), "unpairedPhoneRejected")
            try check(listener.phoneTrust.rejections == 1, "unpairedPhoneReachedHostTrustCheck")
            try check(listener.applicationRequests == 1, "rejectedPeersCannotInvokeFakeRunner")
            let snapshot = try await exchange(port: port, phone: phone, pin: host.spkiSHA256, request: Request(action: .snapshot))
            try check(snapshot.synthetic && !snapshot.fakeProviderRunning && snapshot.fakeMutationCount == 0, "nativeIdentityRoundTrip")
            let large = try await exchange(port: port, phone: phone, pin: host.spkiSHA256,
                                           request: Request(action: .probe, padding: String(repeating: "p", count: 128 * 1024)))
            try check(large.receivedPaddingBytes == 128 * 1024,
                      args.count == 3 ? "largeFrameTraversesEncryptedBridge" : "largeFrameTraversesNativeTLS")
            let started = try await exchange(port: port, phone: phone, pin: host.spkiSHA256, request: Request(action: .fakeStart))
            let stopped = try await exchange(port: port, phone: phone, pin: host.spkiSHA256, request: Request(action: .fakeStop))
            try check(started.fakeProviderRunning && !stopped.fakeProviderRunning && stopped.fakeMutationCount == 2, "fakeRunnerOnlyRoundTrip")
            listener.revokePhone()
            try check(await rejected(port: port, phone: phone, pin: host.spkiSHA256), "revokedPhoneRejected")
            try check(listener.applicationRequests == 5, "revocationPreventsFurtherApplicationRequests")
            await listener.stop()
            try check(listener.activeConnections == 0, "nativeStopClosesOwnedSessions")
            if let bridge {
                let graceful = await bridge.stop()
                try check(graceful, "adapterProcessStopsGracefully")
            }
        } catch {
            if let server { await server.stop() }
            if let bridge { _ = await bridge.stop() }
            // These are synthetic local failures. Emit only a bounded error kind/code.
            if let error = error as? SpikeTransportError { print("{\"failure\":\"\(error)\"}") }
            else if let error = error as? NWError {
                switch error {
                case .tls(let code): print("{\"failure\":\"tls\",\"code\":\(code)}")
                case .posix(let code): print("{\"failure\":\"posix\",\"code\":\(code.rawValue)}")
                case .dns(let code): print("{\"failure\":\"dns\",\"code\":\(code)}")
                default: print("{\"failure\":\"network\"}")
                }
            } else { print("{\"failure\":\"fixtureOrAssertion\"}") }
            emit("harnessCompleted", false)
            exit(1)
        }
        emit("harnessCompleted", true)
    }
}
#else
// Only SpikeCore is the portable library; the process runner is a Mac test tool.
@main struct Harness {
    static func main() { print("Run the integration process harness on macOS.") }
}
#endif
