import Darwin
import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Secure local endpoint discovery")
struct LocalEndpointDiscoveryTests {
    @Test("a private current loopback record is accepted")
    func acceptsCurrentPrivateRecord() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try fixture.write(
            #"{"base_url":"http://127.0.0.1:8100/v1","api_key":"fixture-secret"}"#,
            permissions: 0o600,
            modifiedAt: fixture.now.addingTimeInterval(-1)
        )

        let result = try await fixture.reader.read(for: fixture.daemon)

        #expect(result.baseURL == URL(string: "http://127.0.0.1:8100/v1"))
        #expect(result.apiKey == "fixture-secret")
        #expect(result.evidenceAt == fixture.now.addingTimeInterval(-1))
    }

    @Test("non-loopback or credential-leaking endpoints are rejected", arguments: [
        "https://127.0.0.1:8100/v1",
        "http://example.com:8100/v1",
        "http://user:password@127.0.0.1:8100/v1",
        "http://127.0.0.1:8100/v1?redirect=example.com",
        "http://127.0.0.1:8100/v1#secret",
        "http://127.0.0.1/v1",
        "http://127.0.0.1:8100/not-v1",
    ])
    func rejectsUnsafeEndpoint(_ baseURL: String) async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try fixture.write(
            "{\"base_url\":\"(baseURL)\",\"api_key\":\"fixture-secret\"}",
            permissions: 0o600,
            modifiedAt: fixture.now
        )

        await #expect(throws: LocalEndpointDiscoveryError.insecureEndpoint) {
            try await fixture.reader.read(for: fixture.daemon)
        }
    }

    @Test("empty credentials and malformed records fail without disclosing contents")
    func rejectsInvalidRecordSafely() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        for body in [
            #"{"base_url":"http://127.0.0.1:8100/v1","api_key":""}"#,
            #"{"base_url":"http://127.0.0.1:8100/v1","api_key":"fixture-secret""#,
        ] {
            try fixture.write(body, permissions: 0o600, modifiedAt: fixture.now)
            do {
                _ = try await fixture.reader.read(for: fixture.daemon)
                Issue.record("Expected invalid discovery record")
            } catch {
                #expect(error as? LocalEndpointDiscoveryError == .invalidRecord)
                #expect(!error.localizedDescription.contains("fixture-secret"))
            }
        }
    }

    @Test("file type permissions size owner and timestamps fail closed")
    func validatesFileSecurityAndFreshness() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let validBody = #"{"base_url":"http://localhost:8100/v1","api_key":"fixture-secret"}"#

        try fixture.write(validBody, permissions: 0o644, modifiedAt: fixture.now)
        await #expect(throws: LocalEndpointDiscoveryError.insecurePermissions) {
            try await fixture.reader.read(for: fixture.daemon)
        }

        try fixture.write(
            String(repeating: "x", count: DarkbloomSourcePolicy.localEndpointDiscoveryByteLimit + 1),
            permissions: 0o600,
            modifiedAt: fixture.now
        )
        await #expect(throws: LocalEndpointDiscoveryError.tooLarge) {
            try await fixture.reader.read(for: fixture.daemon)
        }

        try fixture.write(
            validBody,
            permissions: 0o600,
            modifiedAt: Date(timeIntervalSince1970: fixture.daemon.startedAt - 5.001)
        )
        await #expect(throws: LocalEndpointDiscoveryError.stale) {
            try await fixture.reader.read(for: fixture.daemon)
        }

        try fixture.write(
            validBody,
            permissions: 0o600,
            modifiedAt: fixture.now.addingTimeInterval(1.001)
        )
        await #expect(throws: LocalEndpointDiscoveryError.future) {
            try await fixture.reader.read(for: fixture.daemon)
        }

        let symlink = fixture.directory.appendingPathComponent("local-link.json")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: fixture.url
        )
        let symlinkReader = LocalEndpointDiscoveryReader(
            url: symlink,
            now: { fixture.now }
        )
        await #expect(throws: LocalEndpointDiscoveryError.notRegularFile) {
            try await symlinkReader.read(for: fixture.daemon)
        }

        #expect(throws: LocalEndpointDiscoveryError.insecureOwner) {
            try LocalEndpointDiscoveryReader.validate(
                metadata: LocalEndpointFileMetadata(
                    ownerID: getuid() &+ 1,
                    permissions: 0o600,
                    size: validBody.utf8.count,
                    modifiedAt: fixture.now,
                    isRegularFile: true
                ),
                expectedOwnerID: getuid(),
                providerStartedAt: fixture.daemon.startedAt,
                now: fixture.now
            )
        }
    }
}

private struct Fixture {
    let directory: URL
    let url: URL
    let now: Date
    let daemon: DaemonState
    let reader: LocalEndpointDiscoveryReader

    static func make() throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LocalEndpointDiscoveryTests-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("local.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        return Self(
            directory: directory,
            url: url,
            now: now,
            daemon: DaemonState(
                schema: 1,
                version: "0.8.15",
                currentModel: "gemma",
                warmModels: ["gemma"],
                stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
                trust: TrustState(level: "verified", status: "online", reason: "", receivedAt: now.timeIntervalSince1970),
                capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 12, gpuMemoryCacheGB: 0),
                slots: [],
                inferenceActive: false,
                startedAt: now.addingTimeInterval(-30).timeIntervalSince1970,
                writtenAt: now.timeIntervalSince1970,
                pid: 123,
                processIdentity: ProcessIdentity(pid: 123, startTimeMicros: 1)
            ),
            reader: LocalEndpointDiscoveryReader(url: url, now: { now })
        )
    }

    func write(_ string: String, permissions: mode_t, modifiedAt: Date) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
        guard chmod(url.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
