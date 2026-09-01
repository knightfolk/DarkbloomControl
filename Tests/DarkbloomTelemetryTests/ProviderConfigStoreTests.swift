import Darwin
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

    @Test("publishes only after applying source security metadata to the candidate")
    func preservesSourceSecurityMetadata() async throws {
        let metadataRecorder = MetadataRecorder()
        let harness = try ConfigStoreHarness.make(
            mode: 0o640,
            metadataRecorder: metadataRecorder
        )
        defer { harness.cleanup() }
        let sourceOwner = try fileOwner(harness.configURL)
        let sourceGroup = try fileGroup(harness.configURL)
        let draft = try await harness.store.load()

        _ = try await harness.store.save(draft.withSelection(
            ProviderModelSelection(enabled: ["new-model"], preloaded: [])
        ))

        let application = try #require(metadataRecorder.application)
        #expect(application.source == harness.configURL)
        #expect(application.candidate.deletingLastPathComponent() == harness.directory)
        #expect(try fileMode(harness.configURL) == 0o640)
        #expect(try fileOwner(harness.configURL) == sourceOwner)
        #expect(try fileGroup(harness.configURL) == sourceGroup)
    }

    @Test("metadata preservation failure rejects publication with a safe error")
    func rejectsMetadataPreservationFailure() async throws {
        let metadataRecorder = MetadataRecorder(failure: "/Users/private/provider.toml acl=secret-value")
        let existingBackup = Data("existing-backup".utf8)
        let harness = try ConfigStoreHarness.make(
            mode: 0o640,
            backupData: existingBackup,
            metadataRecorder: metadataRecorder
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        do {
            _ = try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
            Issue.record("Expected metadata preservation to fail")
        } catch {
            #expect(error as? ProviderConfigError == .validationFailed(
                "Could not preserve provider configuration security metadata"
            ))
            #expect(!String(describing: error).contains("/Users/private"))
            #expect(!String(describing: error).contains("secret-value"))
        }

        let application = try #require(metadataRecorder.application)
        #expect(!FileManager.default.fileExists(atPath: application.candidate.path))
        #expect(try Data(contentsOf: harness.configURL) == harness.originalData)
        #expect(try Data(contentsOf: harness.backupURL) == existingBackup)
        #expect(await harness.executor.invocations.isEmpty)
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

    @Test("a permissions-only change during validation is an external conflict")
    func rejectsPermissionsChangeDuringValidation() async throws {
        let harness = try ConfigStoreHarness.make(
            mode: 0o644,
            backupData: Data("existing-last-known-good".utf8),
            chmodDuringValidation: 0o600
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        await #expect(throws: ProviderConfigError.changedExternally) {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }

        #expect(try Data(contentsOf: harness.configURL) == harness.originalData)
        #expect(try fileMode(harness.configURL) == 0o600)
        #expect(try Data(contentsOf: harness.backupURL) == Data("existing-last-known-good".utf8))
        let candidateURL = try #require(await harness.executor.validatedCandidateURL)
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("an external write after the final snapshot is restored and rejected")
    func rejectsMutationAtPublicationBoundary() async throws {
        let externalData = Data("enabled_models=[]\npreload_models=[]\n# last-window external edit\n".utf8)
        let existingBackup = Data("existing-last-known-good".utf8)
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            backupData: existingBackup,
            externalWriteAfterFinalSnapshot: externalData
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        await #expect(throws: ProviderConfigError.changedExternally) {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }

        #expect(try Data(contentsOf: harness.configURL) == externalData)
        #expect(try Data(contentsOf: harness.backupURL) == existingBackup)
        let candidateURL = try #require(await harness.executor.validatedCandidateURL)
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("a cooperating writer waiting before swap cannot edit either inode during publication")
    func blocksWaitingWriterAcrossSwap() async throws {
        let writer = CooperatingConfigWriter(
            data: Data("enabled_models=[]\npreload_models=[]\n# waiting writer\n".utf8)
        )
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            cooperatingWriterBeforeSwap: writer,
            cooperatingWriterAfterSwap: writer
        )
        defer { harness.cleanup() }
        let selection = ProviderModelSelection(enabled: ["new-model"], preloaded: [])
        let expectedConfig = try ProviderConfigDocument(data: harness.originalData).rendering(selection)
        let draft = try await harness.store.load()

        _ = try await harness.store.save(draft.withSelection(selection))

        #expect(writer.attempts == [.blocked, .blocked])
        #expect(try Data(contentsOf: harness.configURL) == expectedConfig)
        #expect(try Data(contentsOf: harness.backupURL) == harness.originalData)
    }

    @Test("a cooperating writer started after swap cannot edit the newly published inode")
    func blocksWriterStartedAfterSwap() async throws {
        let writer = CooperatingConfigWriter(
            data: Data("enabled_models=[]\npreload_models=[]\n# post-swap writer\n".utf8)
        )
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            cooperatingWriterAfterSwap: writer
        )
        defer { harness.cleanup() }
        let selection = ProviderModelSelection(enabled: ["new-model"], preloaded: [])
        let expectedConfig = try ProviderConfigDocument(data: harness.originalData).rendering(selection)
        let draft = try await harness.store.load()

        _ = try await harness.store.save(draft.withSelection(selection))

        #expect(writer.attempts == [.blocked])
        #expect(try Data(contentsOf: harness.configURL) == expectedConfig)
        #expect(try Data(contentsOf: harness.backupURL) == harness.originalData)
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

    @Test("candidate cleanup failure is explicit, bounded, and path-redacted")
    func reportsCandidateCleanupFailure() async throws {
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            behavior: .nonzero(stderr: "validation failed"),
            candidateCleanupFailure: "/Users/private/provider.toml api_token=secret-value"
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()

        do {
            _ = try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
            Issue.record("Expected candidate cleanup to fail")
        } catch {
            #expect(error as? ProviderConfigError == .validationFailed(
                "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration"
            ))
            #expect(!String(describing: error).contains("/Users/private"))
            #expect(!String(describing: error).contains("secret-value"))
        }

        let candidateURL = try #require(await harness.executor.validatedCandidateURL)
        #expect(FileManager.default.fileExists(atPath: candidateURL.path))
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

    @Test("lock contention returns a bounded redacted busy error")
    func boundsLockContention() async throws {
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            lockPolicy: ProviderConfigLockPolicy(maxAttempts: 3, retryDelay: .milliseconds(5))
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()
        let lockDescriptor = try acquireExclusiveTestLock(harness.configURL)
        defer { Darwin.close(lockDescriptor) }
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: ProviderConfigError.validationFailed(
            "Provider configuration is busy; try again"
        )) {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }

        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await harness.executor.invocations.isEmpty)
        #expect(try Data(contentsOf: harness.configURL) == harness.originalData)
        #expect(!FileManager.default.fileExists(atPath: harness.backupURL.path))
    }

    @Test("cancellation interrupts lock retry without waiting for its bound")
    func cancelsLockContention() async throws {
        let harness = try ConfigStoreHarness.make(
            mode: 0o600,
            lockPolicy: ProviderConfigLockPolicy(maxAttempts: 100, retryDelay: .milliseconds(20))
        )
        defer { harness.cleanup() }
        let draft = try await harness.store.load()
        let lockDescriptor = try acquireExclusiveTestLock(harness.configURL)
        defer { Darwin.close(lockDescriptor) }

        let save = Task {
            try await harness.store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["new-model"], preloaded: [])
            ))
        }
        try await Task.sleep(for: .milliseconds(10))
        save.cancel()

        do {
            _ = try await save.value
            Issue.record("Expected lock retry cancellation")
        } catch is CancellationError {
            // Expected cancellation must remain distinct from a busy/file error.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await harness.executor.invocations.isEmpty)
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
        externalWriteDuringValidation: Data? = nil,
        chmodDuringValidation: Int? = nil,
        externalWriteAfterFinalSnapshot: Data? = nil,
        cooperatingWriterBeforeSwap: CooperatingConfigWriter? = nil,
        cooperatingWriterAfterSwap: CooperatingConfigWriter? = nil,
        candidateCleanupFailure: String? = nil,
        metadataRecorder: MetadataRecorder? = nil,
        lockPolicy: ProviderConfigLockPolicy = .live
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
        } else if let chmodDuringValidation {
            hook = { _ in
                try FileManager.default.setAttributes(
                    [.posixPermissions: chmodDuringValidation],
                    ofItemAtPath: configURL.path
                )
            }
        } else {
            hook = nil
        }
        let executor = FakeConfigExecutor(behavior: behavior, hook: hook)
        let cleanupHook: (@Sendable (URL) throws -> Void)?
        if let candidateCleanupFailure {
            cleanupHook = { _ in throw FakeExecutorError(message: candidateCleanupFailure) }
        } else {
            cleanupHook = nil
        }
        let metadataHook: (@Sendable (URL, URL) throws -> Void)?
        if let metadataRecorder {
            metadataHook = { source, candidate in
                try metadataRecorder.record(source: source, candidate: candidate)
            }
        } else {
            metadataHook = nil
        }
        let storeHooks = ProviderConfigStoreHooks(
            afterFinalSnapshot: {
                if let externalWriteAfterFinalSnapshot {
                    try externalWriteAfterFinalSnapshot.write(to: configURL)
                }
                try cooperatingWriterBeforeSwap?.attempt(at: configURL)
            },
            afterSwap: { try cooperatingWriterAfterSwap?.attempt(at: configURL) },
            removeCandidate: cleanupHook,
            preserveMetadata: metadataHook
        )
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
                runner: executor,
                fileManager: .default,
                hooks: storeHooks,
                lockPolicy: lockPolicy
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

private final class MetadataRecorder: @unchecked Sendable {
    struct Application: Sendable {
        let source: URL
        let candidate: URL
    }

    private let lock = NSLock()
    private let failure: String?
    private var recordedApplication: Application?

    init(failure: String? = nil) {
        self.failure = failure
    }

    var application: Application? {
        lock.withLock { recordedApplication }
    }

    func record(source: URL, candidate: URL) throws {
        lock.withLock { recordedApplication = Application(source: source, candidate: candidate) }
        if let failure { throw FakeExecutorError(message: failure) }
    }
}

private final class CooperatingConfigWriter: @unchecked Sendable {
    enum Attempt: Equatable, Sendable {
        case blocked
        case wrote
    }

    private let lock = NSLock()
    private let data: Data
    private var recordedAttempts: [Attempt] = []

    init(data: Data) {
        self.data = data
    }

    var attempts: [Attempt] {
        lock.withLock { recordedAttempts }
    }

    func attempt(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw FakeExecutorError(message: "cooperating writer could not open config")
            }
            lock.withLock { recordedAttempts.append(.blocked) }
            return
        }
        defer { Darwin.close(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        lock.withLock { recordedAttempts.append(.wrote) }
    }
}

private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func fileNumber(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

private func fileOwner(_ url: URL) throws -> UInt32 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.ownerAccountID] as? NSNumber)?.uint32Value)
}

private func fileGroup(_ url: URL) throws -> UInt32 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value)
}

private func acquireExclusiveTestLock(_ url: URL) throws -> Int32 {
    for _ in 0..<100 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
        }
        if descriptor >= 0 { return descriptor }
        let lockError = errno
        guard lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EINTR else {
            break
        }
        usleep(1_000)
    }
    throw FakeExecutorError(message: "could not acquire bounded test lock")
}
