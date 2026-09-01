import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Provider config store")
struct ProviderConfigStoreTests {
    @Test("load returns a clean draft from the exact source revision")
    func loadsDraft() async throws {
        let harness = try ConfigStoreHarness.make(mode: 0o600)
        defer { harness.cleanup() }

        let draft = try await harness.store.load()

        #expect(draft.original == ProviderModelSelection(enabled: ["old-model"], preloaded: []))
        #expect(draft.selection == draft.original)
        #expect(!draft.hasChanges)
        #expect(draft.sourceRevision == (try ProviderConfigDocument(data: harness.originalData)).revision)
    }

    @Test("save validates, replaces the backup, preserves permissions, and atomically replaces the config")
    func savesValidatedCandidate() async throws {
        let harness = try ConfigStoreHarness.make(mode: 0o600, backupData: Data("stale-backup".utf8))
        defer { harness.cleanup() }
        let originalFileNumber = try fileNumber(harness.configURL)
        let draft = try await harness.store.load()

        let saved = try await harness.store.save(draft.withSelection(
            ProviderModelSelection(enabled: ["gemma-4-26b-qat-4bit"], preloaded: [])
        ))

        #expect(saved.restartRequired)
        #expect(!saved.draft.hasChanges)
        #expect(saved.draft.original == ProviderModelSelection(enabled: ["gemma-4-26b-qat-4bit"], preloaded: []))
        #expect(try Data(contentsOf: harness.backupURL) == harness.originalData)
        #expect(try fileMode(harness.configURL) == 0o600)
        #expect(try fileNumber(harness.configURL) != originalFileNumber)

        let invocations = await harness.executor.invocations
        let validation = try #require(invocations.first)
        #expect(invocations.count == 1)
        #expect(validation.command.executable == harness.executableURL)
        #expect(Array(validation.command.arguments.prefix(2)) == ["status", "--config"])
        #expect(validation.timeout == DarkbloomSourcePolicy.processTimeout)
        #expect(validation.outputLimit == DarkbloomSourcePolicy.processOutputByteLimit)
        let candidatePath = try #require(validation.command.arguments.dropFirst(2).first)
        let candidateURL = URL(fileURLWithPath: candidatePath)
        #expect(candidateURL.deletingLastPathComponent() == harness.directory)
        #expect(candidateURL != harness.configURL)
        #expect(validation.candidateMode == 0o600)
        let savedData = try Data(contentsOf: harness.configURL)
        #expect(validation.candidateData == savedData)
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("an external write during validation rejects save before backup or replacement")
    func rejectsRaceAfterValidation() async throws {
        let externalData = Data("enabled_models=[]\npreload_models=[]\n# external\n".utf8)
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            backupData: Data("existing-last-known-good".utf8),
            externalWriteDuringValidation: externalData
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        await #expect(throws: ProviderConfigError.changedExternally) {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }

        #expect(try Data(contentsOf: harness.configURL) == externalData)
        #expect(try Data(contentsOf: harness.backupURL) == Data("existing-last-known-good".utf8))
        let candidateURL = try #require(await harness.executor.validatedCandidateURL)
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("a pre-existing external change is rejected without validation or backup")
    func rejectsExternalChangeBeforeValidation() async throws {
        let harness = try ConfigStoreHarness.make(mode: 0o600)
        defer { harness.cleanup() }
        let draft = try await harness.store.load()
        let externalData = Data("enabled_models=[]\npreload_models=[]\n# external\n".utf8)
        try externalData.write(to: harness.configURL)

        await #expect(throws: ProviderConfigError.changedExternally) {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }

        #expect(try Data(contentsOf: harness.configURL) == externalData)
        #expect(!FileManager.default.fileExists(atPath: harness.backupURL.path))
        #expect(await harness.executor.invocations.isEmpty)
    }

    @Test("nonzero validation preserves files, removes the candidate, and exposes one safe error")
    func rejectsInvalidCandidate() async throws {
        let sensitive = "/Users/private/.config/darkbloom/provider.toml bearer=secret-value"
        let harness = try ConfigStoreHarness.make(
            mode: 0o640,
            backupData: Data("existing-backup".utf8),
            behavior: .nonzero(stderr: sensitive)
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        await #expect(throws: ProviderConfigError.validationFailed("Darkbloom rejected the candidate configuration")) {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }

        #expect(try Data(contentsOf: harness.configURL) == harness.originalData)
        #expect(try Data(contentsOf: harness.backupURL) == Data("existing-backup".utf8))
        let candidateURL = try #require(await harness.executor.validatedCandidateURL)
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("executor errors are collapsed without disclosing paths or credentials")
    func redactsExecutorErrors() async throws {
        let sensitive = "/Users/private/.config/darkbloom/provider.toml api_token=secret-value"
        let harness = try ConfigStoreHarness.make(mode: 0o600, behavior: .throwing(message: sensitive))
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        do {
            _ = try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
            Issue.record("Expected candidate validation to fail")
        } catch {
            #expect(error as? ProviderConfigError == .validationFailed("Darkbloom rejected the candidate configuration"))
            #expect(!String(describing: error).contains("/Users/private"))
            #expect(!String(describing: error).contains("secret-value"))
        }

        let candidateURL = try #require(await harness.executor.validatedCandidateURL)
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
        #expect(try Data(contentsOf: harness.configURL) == harness.originalData)
        #expect(!FileManager.default.fileExists(atPath: harness.backupURL.path))
    }

    @Test("saving an unchanged draft performs no validation or file mutation")
    func savesNoChangesAsNoOp() async throws {
        let harness = try ConfigStoreHarness.make(mode: 0o600)
        defer { harness.cleanup() }
        let draft = try await harness.store.load()
        let originalFileNumber = try fileNumber(harness.configURL)

        let saved = try await harness.store.save(draft)

        #expect(!saved.restartRequired)
        #expect(!saved.draft.hasChanges)
        #expect(saved.draft.sourceRevision == draft.sourceRevision)
        #expect(await harness.executor.invocations.isEmpty)
        #expect(try Data(contentsOf: harness.configURL) == harness.originalData)
        #expect(try fileNumber(harness.configURL) == originalFileNumber)
        #expect(!FileManager.default.fileExists(atPath: harness.backupURL.path))
    }
}

private struct ConfigStoreHarness: Sendable {
    let directory: URL
    let configURL: URL
    let backupURL: URL
    let executableURL: URL
    let originalData: Data
    let executor: FakeConfigExecutor
    let store: LocalProviderConfigStore

    static func make(
        mode: Int,
        backupData: Data? = nil,
        behavior: FakeConfigExecutor.Behavior = .succeed,
        externalWriteDuringValidation: Data? = nil
    ) throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarkbloomConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let configURL = directory.appendingPathComponent("provider.toml")
        let backupURL = directory.appendingPathComponent("provider.toml.darkbloom-monitor-backup")
        let executableURL = directory.appendingPathComponent("darkbloom-fake")
        let originalData = Data("""
        # provider fixture
        private_token = "never-display-this"
        enabled_models = ["old-model"]
        preload_models = []
        [beta]
        unrelated = true

        """.utf8)
        try originalData.write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: configURL.path)
        if let backupData {
            try backupData.write(to: backupURL)
        }

        let hook: (@Sendable (ProcessCommand) throws -> Void)?
        if let externalWriteDuringValidation {
            hook = { _ in try externalWriteDuringValidation.write(to: configURL) }
        } else {
            hook = nil
        }
        let executor = FakeConfigExecutor(behavior: behavior, hook: hook)
        return Self(
            directory: directory,
            configURL: configURL,
            backupURL: backupURL,
            executableURL: executableURL,
            originalData: originalData,
            executor: executor,
            store: LocalProviderConfigStore(
                configURL: configURL,
                executable: executableURL,
                runner: executor
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor FakeConfigExecutor: ProcessExecuting {
    enum Behavior: Sendable {
        case succeed
        case nonzero(stderr: String)
        case throwing(message: String)
    }

    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration
        let outputLimit: Int
        let candidateData: Data?
        let candidateMode: Int?
    }

    private(set) var invocations: [Invocation] = []
    private let behavior: Behavior
    private let hook: (@Sendable (ProcessCommand) throws -> Void)?

    init(behavior: Behavior, hook: (@Sendable (ProcessCommand) throws -> Void)?) {
        self.behavior = behavior
        self.hook = hook
    }

    var validatedCandidateURL: URL? {
        invocations.last.flatMap { invocation in
            guard invocation.command.arguments.count >= 3 else { return nil }
            return URL(fileURLWithPath: invocation.command.arguments[2])
        }
    }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        let candidateURL = command.arguments.count >= 3
            ? URL(fileURLWithPath: command.arguments[2])
            : nil
        invocations.append(Invocation(
            command: command,
            timeout: timeout,
            outputLimit: outputLimit,
            candidateData: candidateURL.flatMap { try? Data(contentsOf: $0) },
            candidateMode: candidateURL.flatMap { try? fileMode($0) }
        ))
        try hook?(command)

        switch behavior {
        case .succeed:
            return CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
        case .nonzero(let stderr):
            return CommandResult(exitCode: 2, standardOutput: Data(), standardError: Data(stderr.utf8))
        case .throwing(let message):
            throw FakeExecutorError(message: message)
        }
    }
}

private struct FakeExecutorError: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func fileNumber(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}
