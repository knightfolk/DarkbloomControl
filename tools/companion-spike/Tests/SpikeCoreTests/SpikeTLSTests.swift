import Foundation
import Network
import Testing
@testable import SpikeCore

@Suite(.serialized)
struct SpikeTLSTests {
    @Test func incompleteHandshakeTerminatesAndCancellationDoesNotWaitForTimeout() async throws {
        let silent = try SilentTCPPeer()
        let port = try await silent.start()
        defer { silent.stop() }
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        await #expect(throws: SpikeTransportError.timedOut) {
            _ = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256, timeout: 0.15)
        }
        let began = ContinuousClock.now
        let task = Task { try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256, timeout: 10) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: SpikeTransportError.cancelled) { _ = try await task.value }
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func stalledReadDeadlineAndCancellation() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        await #expect(throws: SpikeTransportError.timedOut) { _ = try await client.receive(timeout: 0.05) }
        client.cancel()
        let second = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        let task = Task { try await second.receive() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: SpikeTransportError.cancelled) { _ = try await task.value }
        second.cancel()
        await server.stop()
        #expect(server.activeConnections == 0)
    }

    @Test func inboundOversizedFrameRejectedWithoutPayloadAllocation() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        try await client.sendUnframedForTesting(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        await #expect(throws: (any Error).self) { _ = try await client.receive(timeout: 1) }
        #expect(server.applicationRequests == 0)
        client.cancel()
        await server.stop()
    }

    @Test func partialFrameUsesOneDeadlineAcrossHeaderAndPayload() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256, frameTimeout: 0.25)
        let port = try await server.start()
        let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        try await client.sendUnframedForTesting(Data([0, 0]))
        try await Task.sleep(for: .milliseconds(150))
        try await client.sendUnframedForTesting(Data([0, 1]))
        try await Task.sleep(for: .milliseconds(180))
        #expect(server.activeConnections == 0)
        #expect(server.applicationRequests == 0)
        client.cancel()
        await server.stop()
    }

    @Test func ninthConnectionIsRejectedAndConcurrentStopIsIdempotent() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        var clients: [SpikeTLSConnection] = []
        for _ in 0..<8 {
            clients.append(try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256))
        }
        await #expect(throws: (any Error).self) {
            let ninth = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256, timeout: 1)
            defer { ninth.cancel() }
            try await ninth.send(Data("must not arrive".utf8))
            _ = try await ninth.receive(timeout: 1)
        }
        #expect(server.activeConnections == 8)
        async let first: Void = server.stop()
        async let second: Void = server.stop()
        _ = await (first, second)
        for client in clients { client.cancel() }
        #expect(server.activeConnections == 0)
    }

    @Test func wrongSPKIRejectedBeforeApplicationData() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let impostor = try SpikeIdentity.make(role: .host)
        let observed = SpikeTrustObservations()
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        await #expect(throws: (any Error).self) {
            let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: impostor.spkiSHA256, observations: observed)
            defer { client.cancel() }
            try await client.send(Data("fake.start".utf8))
            _ = try await client.receive()
        }
        #expect(server.applicationRequests == 0)
        #expect(observed.rejections == 1)
        await server.stop()
    }

    @Test func missingClientCertificateRejected() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        await #expect(throws: (any Error).self) {
            let client = try await SpikeTLSConnection.connect(port: port, identity: nil, expectedHostSPKI: host.spkiSHA256)
            defer { client.cancel() }
            try await client.send(Data("fake.start".utf8))
            _ = try await client.receive()
        }
        #expect(server.applicationRequests == 0)
        await server.stop()
    }

    @Test func unpairedPhoneRejected() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let stranger = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        await #expect(throws: (any Error).self) {
            let client = try await SpikeTLSConnection.connect(port: port, identity: stranger, expectedHostSPKI: host.spkiSHA256)
            defer { client.cancel() }
            try await client.send(Data("fake.start".utf8))
            _ = try await client.receive()
        }
        #expect(server.applicationRequests == 0)
        #expect(server.phoneTrust.rejections == 1)
        await server.stop()
    }

    @Test func nativeIdentityRoundTrip() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        let payload = Data(repeating: 0xA5, count: 128 * 1024)
        try await client.send(payload)
        let reply = try await client.receive()
        #expect(reply == payload)
        #expect(server.applicationRequests == 1)
        client.cancel()
        await server.stop()
        #expect(server.activeConnections == 0)
    }

    @Test func revocationClosesExistingSessionAndRejectsReconnect() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        try await client.send(Data("first".utf8))
        #expect(try await client.receive() == Data("first".utf8))
        server.revokePhone()
        await #expect(throws: (any Error).self) {
            try await client.send(Data("after-revocation".utf8))
            _ = try await client.receive()
        }
        client.cancel()
        await #expect(throws: (any Error).self) {
            let second = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
            defer { second.cancel() }
            try await second.send(Data("reconnect".utf8))
            _ = try await second.receive()
        }
        #expect(server.applicationRequests == 1)
        await server.stop()
    }

    @Test func oversizeFrameRejectedBeforeSend() async throws {
        let host = try SpikeIdentity.make(role: .host)
        let phone = try SpikeIdentity.make(role: .phone)
        let server = try SpikeTLSServer(identity: host, allowedPhoneSPKI: phone.spkiSHA256)
        let port = try await server.start()
        let client = try await SpikeTLSConnection.connect(port: port, identity: phone, expectedHostSPKI: host.spkiSHA256)
        await #expect(throws: SpikeTransportError.frameTooLarge) {
            try await client.send(Data(repeating: 0, count: 256 * 1024 + 1))
        }
        #expect(server.applicationRequests == 0)
        client.cancel()
        await server.stop()
    }
}

private final class SilentTCPPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "companion.spike.silent-test-peer")
    private let lock = NSLock()
    private var port: UInt16?
    private var connections: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self { self.lock.withLock { self.port = self.listener.port?.rawValue } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let port = lock.withLock({ port }) { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SpikeTransportError.timedOut
    }
    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }
}
