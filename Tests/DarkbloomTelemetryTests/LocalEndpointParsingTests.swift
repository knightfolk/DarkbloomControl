import Darwin
import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Local endpoint discovery")
struct LocalEndpointParsingTests {
    // Synthetic fixture values only; deliberately not in the real token format.
    private func payload(
        baseURL: String = "http://127.0.0.1:8000/v1",
        apiKey: String = "synthetic-token-value",
        host: String = "127.0.0.1",
        port: Int = 8000,
        pid: Int = 4242,
        extra: String = ""
    ) -> Data {
        Data("""
        {"base_url": "\(baseURL)", "api_key": "\(apiKey)", "host": "\(host)", \
        "port": \(port), "pid": \(pid), "version": "0.9.7", "updated_at": 1750000000\(extra)}
        """.utf8)
    }

    @Test("a live record decodes with every documented field")
    func liveRecord() throws {
        let record = try #require(try LocalEndpointParser.parse(payload()))
        #expect(record.baseURL == "http://127.0.0.1:8000/v1")
        #expect(record.host == "127.0.0.1")
        #expect(record.port == 8000)
        #expect(record.processID == 4242)
        #expect(record.version == "0.9.7")
        #expect(record.updatedAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(record.hasBearerToken)
    }

    @Test("the documented empty object means no live endpoint")
    func emptyObjectIsNone() throws {
        #expect(try LocalEndpointParser.parse(Data("{}".utf8)) == nil)
    }

    @Test("malformed and out-of-bound payloads are rejected")
    func invalidPayloads() {
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(Data("not json".utf8))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(baseURL: "ftp://127.0.0.1:8000"))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(baseURL: ""))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(baseURL: "http://user:pass@127.0.0.1:8000/v1"))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(baseURL: "http://127.0.0.1:8000/v1?api_key=secret"))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(baseURL: "http://127.0.0.1:9000/v1"))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(baseURL: "http://127.0.0.1/v1"))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(port: 0))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(port: 70_000))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(pid: 0))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(payload(host: ""))
        }
        #expect(throws: LocalEndpointParseError.invalidPayload) {
            _ = try LocalEndpointParser.parse(Data(String(repeating: "a", count: 65_537).utf8))
        }
    }

    @Test("an authentication-disabled record is surfaced honestly")
    func missingTokenIsFlagged() throws {
        let record = try #require(try LocalEndpointParser.parse(payload(apiKey: "")))
        #expect(!record.hasBearerToken)
    }

    @Test("the bearer token never appears in the record's printed description")
    func descriptionRedactsToken() throws {
        let record = try #require(try LocalEndpointParser.parse(payload(apiKey: "synthetic-token-value")))
        let printed = String(describing: record)
        #expect(!printed.contains("synthetic-token-value"))
        #expect(printed.contains("baseURL"))
        let reflected = String(reflecting: record)
        #expect(!reflected.contains("synthetic-token-value"))
        #expect(!record.customMirror.children.contains { $0.label == "apiKey" })
        var explicitlyUsedToken: String?
        record.withBearerToken { explicitlyUsedToken = $0 }
        #expect(explicitlyUsedToken == "synthetic-token-value")
    }

    @Test("the provider token file is read only through the explicit callback")
    func readsProtectedTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalEndpointTokenFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenURL = directory.appendingPathComponent("local_token")
        try Data("dk-local-synthetic-token\n".utf8).write(to: tokenURL)
        #expect(chmod(tokenURL.path, 0o600) == 0)

        var receivedToken: String?
        let found = LocalEndpointTokenFile(fileURL: tokenURL).withBearerToken {
            receivedToken = $0
        }
        #expect(found)
        #expect(receivedToken == "dk-local-synthetic-token")
    }

    @Test("the provider token reader accepts a custom bearer token in its protected file")
    func readsCustomBearerToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalEndpointCustomToken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenURL = directory.appendingPathComponent("local_token")
        let token = "client-custom-bearer-token-12345"
        try Data(token.utf8).write(to: tokenURL)
        #expect(chmod(tokenURL.path, 0o600) == 0)

        var receivedToken: String?
        let found = LocalEndpointTokenFile(fileURL: tokenURL).withBearerToken {
            receivedToken = $0
        }
        #expect(found)
        #expect(receivedToken == token)
    }

    @Test("saving a bearer token uses the CLI's protected token-file format")
    func savesBearerToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalEndpointSaveToken-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenURL = directory.appendingPathComponent("local_token")
        let tokenFile = LocalEndpointTokenFile(fileURL: tokenURL)
        let token = "client-custom-bearer-token-12345"
        try tokenFile.saveBearerToken(token)

        let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var receivedToken: String?
        #expect(tokenFile.withBearerToken { receivedToken = $0 })
        #expect(receivedToken == token)
    }

    @Test("invalid bearer tokens do not replace the current CLI token")
    func rejectsInvalidBearerToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalEndpointRejectToken-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenFile = LocalEndpointTokenFile(fileURL: directory.appendingPathComponent("local_token"))
        let currentToken = "dk-local-existing-token-123456789"
        try tokenFile.saveBearerToken(currentToken)
        for invalidToken in ["too short", "invalid=middle-padding-token"] {
            #expect(throws: LocalEndpointTokenFileError.invalidToken) {
                try tokenFile.saveBearerToken(invalidToken)
            }
        }

        var receivedToken: String?
        #expect(tokenFile.withBearerToken { receivedToken = $0 })
        #expect(receivedToken == currentToken)
    }

    @Test("the provider token reader rejects loose permissions and symlinks")
    func rejectsInsecureTokenFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalEndpointTokenFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenURL = directory.appendingPathComponent("local_token")
        try Data("dk-local-synthetic-token".utf8).write(to: tokenURL)
        #expect(chmod(tokenURL.path, 0o644) == 0)
        #expect(!LocalEndpointTokenFile(fileURL: tokenURL).withBearerToken { _ in
            Issue.record("Insecure permissions must not expose the token")
        })

        let protectedURL = directory.appendingPathComponent("protected_token")
        try Data("dk-local-synthetic-token".utf8).write(to: protectedURL)
        #expect(chmod(protectedURL.path, 0o600) == 0)
        let symlinkURL = directory.appendingPathComponent("token_link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: protectedURL)
        #expect(!LocalEndpointTokenFile(fileURL: symlinkURL).withBearerToken { _ in
            Issue.record("Symlink targets must not expose the token")
        })
    }

    @Test("the client maps nonzero exit and empty output to no live endpoint")
    func clientMapsAbsence() async throws {
        let runner = EndpointRunnerFake(results: [
            .failure(ProcessRunnerError.nonzeroExit(code: 1, message: "no local server")),
        ])
        let client = LocalEndpointClient(
            policy: endpointPolicy,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            testOnlyExecutable: URL(fileURLWithPath: "/test/bin/darkbloom")
        )
        let availability = await client.fetch()
        #expect(availability == .none(LocalEndpointClient.noLiveEndpointReason))
        let invocation = await runner.invocations.first
        #expect(invocation?.command.arguments == ["local", "--json"])
        #expect(invocation?.timeout == DarkbloomSourcePolicy.localEndpointTimeout)
        #expect(invocation?.outputLimit == DarkbloomSourcePolicy.localEndpointOutputByteLimit)
    }

    @Test("the client returns a live record without exposing stderr")
    func clientMapsLiveRecord() async throws {
        let runner = EndpointRunnerFake(results: [
            .success(CommandResult(
                exitCode: 0,
                standardOutput: payload(),
                standardError: Data()
            )),
        ])
        let client = LocalEndpointClient(
            policy: endpointPolicy,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            testOnlyExecutable: URL(fileURLWithPath: "/test/bin/darkbloom")
        )
        let availability = await client.fetch()
        guard case .live(let record) = availability else {
            Issue.record("expected a live record")
            return
        }
        #expect(record.processID == 4242)
    }

    private var endpointPolicy: DarkbloomSourcePolicy {
        DarkbloomSourcePolicy(
            homeDirectory: URL(fileURLWithPath: "/test/home"),
            environmentPath: "/test/home/.darkbloom/bin"
        )
    }
}

private actor EndpointRunnerFake: ProcessExecuting {
    enum Outcome: Sendable {
        case success(CommandResult)
        case failure(Error)
    }

    struct Call: Sendable {
        let command: ProcessCommand
        let timeout: Duration
        let outputLimit: Int
    }

    private var results: [Outcome]
    private(set) var invocations: [Call] = []

    init(results: [Outcome]) {
        self.results = results
    }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        invocations.append(Call(command: command, timeout: timeout, outputLimit: outputLimit))
        guard let next = results.first else {
            throw ProcessRunnerError.nonzeroExit(code: 1, message: "exhausted")
        }
        results.removeFirst()
        switch next {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
