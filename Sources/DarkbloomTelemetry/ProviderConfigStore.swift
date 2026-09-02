import CryptoKit
import Darwin
import Foundation

public struct ProviderConfigDraft: Equatable, Sendable {
    public let sourceRevision: String
    public let original: ProviderModelSelection
    public var selection: ProviderModelSelection
    fileprivate let sourceFileState: ProviderConfigFileState?

    public var hasChanges: Bool { selection != original }

    public init(
        sourceRevision: String,
        original: ProviderModelSelection,
        selection: ProviderModelSelection
    ) {
        self.sourceRevision = sourceRevision
        self.original = original
        self.selection = selection
        self.sourceFileState = nil
    }

    fileprivate init(document: ProviderConfigDocument, sourceFileState: ProviderConfigFileState) {
        self.sourceRevision = document.revision
        self.original = document.selection
        self.selection = document.selection
        self.sourceFileState = sourceFileState
    }

    public func withSelection(_ selection: ProviderModelSelection) -> Self {
        var draft = self
        draft.selection = selection
        return draft
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceRevision == rhs.sourceRevision
            && lhs.original == rhs.original
            && lhs.selection == rhs.selection
    }
}

public struct ProviderConfigSaveResult: Equatable, Sendable {
    public let draft: ProviderConfigDraft
    public let restartRequired: Bool

    public init(draft: ProviderConfigDraft, restartRequired: Bool) {
        self.draft = draft
        self.restartRequired = restartRequired
    }
}

public protocol ProviderConfigManaging: Sendable {
    func load() async throws -> ProviderConfigDraft
    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult
}

struct ProviderConfigStoreHooks: Sendable {
    let afterFinalSnapshot: @Sendable () throws -> Void
    let afterSwap: @Sendable () throws -> Void
    let removeCandidate: (@Sendable (URL) throws -> Void)?
    let preserveMetadata: (@Sendable (URL, URL) throws -> Void)?

    static let live = Self(
        afterFinalSnapshot: {},
        afterSwap: {},
        removeCandidate: nil,
        preserveMetadata: nil
    )
}

struct ProviderConfigLockPolicy: Sendable {
    let maxAttempts: Int
    let retryDelay: Duration

    static let live = Self(maxAttempts: 20, retryDelay: .milliseconds(10))
}

public actor LocalProviderConfigStore: ProviderConfigManaging {
    private static let validationFailure = ProviderConfigError.validationFailed(
        "Darkbloom rejected the candidate configuration"
    )
    private static let readFailure = ProviderConfigError.validationFailed(
        "Could not read the provider configuration"
    )
    private static let saveFailure = ProviderConfigError.validationFailed(
        "Could not save the provider configuration"
    )
    private static let recoveryFailure = ProviderConfigError.validationFailed(
        "Provider configuration changed during recovery; recovery data was preserved beside it"
    )
    private static let metadataFailure = ProviderConfigError.validationFailed(
        "Could not preserve provider configuration security metadata"
    )
    private static let busyFailure = ProviderConfigError.validationFailed(
        "Provider configuration is busy; try again"
    )

    private let configURL: URL
    private let executable: URL
    private let runner: any ProcessExecuting
    private let fileManager: FileManager
    private let hooks: ProviderConfigStoreHooks
    private let lockPolicy: ProviderConfigLockPolicy

    public init(
        configURL: URL,
        executable: URL,
        runner: any ProcessExecuting,
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.executable = executable
        self.runner = runner
        self.fileManager = fileManager
        self.hooks = .live
        self.lockPolicy = .live
    }

    init(
        configURL: URL,
        executable: URL,
        runner: any ProcessExecuting,
        fileManager: FileManager,
        hooks: ProviderConfigStoreHooks,
        lockPolicy: ProviderConfigLockPolicy
    ) {
        self.configURL = configURL
        self.executable = executable
        self.runner = runner
        self.fileManager = fileManager
        self.hooks = hooks
        self.lockPolicy = lockPolicy
    }

    public func load() async throws -> ProviderConfigDraft {
        let source = try await readLockedSnapshot(lockFlag: O_SHLOCK)
        let document = try ProviderConfigDocument(data: source.data)
        return ProviderConfigDraft(document: document, sourceFileState: source.state)
    }

    public func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        guard draft.hasChanges else {
            return ProviderConfigSaveResult(draft: try await load(), restartRequired: false)
        }

        guard let expectedState = draft.sourceFileState else {
            throw ProviderConfigError.changedExternally
        }
        let currentSnapshot = try await readLockedSnapshot(lockFlag: O_SHLOCK)
        guard currentSnapshot.state == expectedState else {
            throw ProviderConfigError.changedExternally
        }
        let current = try ProviderConfigDocument(data: currentSnapshot.data)

        let candidateData = try current.rendering(draft.selection)
        let mode = expectedState.permissions
        let candidateURL = uniqueSibling(named: "candidate")
        var candidateNeedsCleanup = false
        do {
            try createFile(
                at: candidateURL,
                data: candidateData,
                mode: mode,
                candidateNeedsCleanup: &candidateNeedsCleanup
            )
            try preserveSecurityMetadata(
                from: configURL,
                to: candidateURL,
                expectedState: expectedState
            )
            try await validate(candidateURL)
            try await publish(
                candidateURL,
                expectedState: expectedState,
                candidateNeedsCleanup: &candidateNeedsCleanup
            )
        } catch {
            if candidateNeedsCleanup {
                try cleanupCandidate(candidateURL)
            }
            throw error
        }

        return ProviderConfigSaveResult(
            draft: try await loadAfterCompletedPublication(),
            restartRequired: true
        )
    }

    /// Publication is irreversible once `publish` returns. Keep the bounded
    /// readback independent from caller cancellation so a published config is
    /// never reported as an unperformed save.
    private func loadAfterCompletedPublication() async throws -> ProviderConfigDraft {
        let store = self
        let readback = Task.detached(priority: Task.currentPriority) {
            try await store.load()
        }
        return try await readback.value
    }

    private func readLockedSnapshot(lockFlag: Int32) async throws -> ProviderConfigFileSnapshot {
        let descriptor = try await openLockedDescriptor(at: configURL, lockFlag: lockFlag)
        defer { Darwin.close(descriptor) }
        return try snapshot(descriptor: descriptor)
    }

    private func readSnapshot(at url: URL) throws -> ProviderConfigFileSnapshot {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw Self.readFailure }
        defer { Darwin.close(descriptor) }

        return try snapshot(descriptor: descriptor)
    }

    private func snapshot(descriptor: Int32) throws -> ProviderConfigFileSnapshot {
        do {
            var before = Darwin.stat()
            guard Darwin.fstat(descriptor, &before) == 0 else { throw Self.readFailure }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            var after = Darwin.stat()
            guard Darwin.fstat(descriptor, &after) == 0 else { throw Self.readFailure }
            let beforeState = ProviderConfigFileState(stat: before, data: data)
            let afterState = ProviderConfigFileState(stat: after, data: data)
            guard beforeState == afterState, after.st_size == data.count else {
                throw ProviderConfigError.changedExternally
            }
            return ProviderConfigFileSnapshot(data: data, state: afterState)
        } catch let error as ProviderConfigError {
            throw error
        } catch {
            throw Self.readFailure
        }
    }

    private func publish(
        _ candidateURL: URL,
        expectedState: ProviderConfigFileState,
        candidateNeedsCleanup: inout Bool
    ) async throws {
        // Publication uses the strongest local-filesystem primitive available on
        // the macOS 14 target. Before RENAME_SWAP, bounded O_EXLOCK descriptors
        // are acquired in one canonical order: current config inode, then private
        // candidate inode. If either is busy, every acquired descriptor is closed
        // before the bounded retry sleep. The locks follow their inodes across the
        // swap, protecting both the newly published config and the displaced file
        // until verification and atomic backup publication finish.
        //
        // Advisory locking cannot protect against noncooperating descriptor writes.
        // A cooperating writer that retries after a blocked open must resolve the
        // config path again (and revalidate identity) rather than write through a
        // descriptor that may now name the displaced inode. Recovery still checks
        // our published inode and preserves both visible files if certainty is lost.
        let descriptors = try await openPublicationDescriptors(candidateURL: candidateURL)
        defer {
            Darwin.close(descriptors.candidate)
            Darwin.close(descriptors.config)
        }

        let finalState = try snapshot(descriptor: descriptors.config).state
        guard finalState == expectedState else {
            throw ProviderConfigError.changedExternally
        }
        let candidateState = try snapshot(descriptor: descriptors.candidate).state

        do {
            try hooks.afterFinalSnapshot()
        } catch {
            throw Self.saveFailure
        }

        try atomicSwap(candidateURL, configURL)

        do {
            try hooks.afterSwap()
        } catch {
            try preserveOrRollback(
                candidateURL,
                candidateState: candidateState,
                candidateNeedsCleanup: &candidateNeedsCleanup
            )
            throw Self.saveFailure
        }

        let displacedState: ProviderConfigFileState
        do {
            displacedState = try readSnapshot(at: candidateURL).state
        } catch {
            try preserveOrRollback(
                candidateURL,
                candidateState: candidateState,
                candidateNeedsCleanup: &candidateNeedsCleanup
            )
            throw Self.readFailure
        }

        guard displacedState.matchesAcrossRename(expectedState) else {
            try preserveOrRollback(
                candidateURL,
                candidateState: candidateState,
                candidateNeedsCleanup: &candidateNeedsCleanup
            )
            throw ProviderConfigError.changedExternally
        }

        let backupURL = configURL.appendingPathExtension("darkbloom-monitor-backup")
        do {
            try atomicReplace(candidateURL, at: backupURL)
            candidateNeedsCleanup = false
        } catch {
            try preserveOrRollback(
                candidateURL,
                candidateState: candidateState,
                candidateNeedsCleanup: &candidateNeedsCleanup
            )
            throw Self.saveFailure
        }
    }

    private func preserveOrRollback(
        _ candidateURL: URL,
        candidateState: ProviderConfigFileState,
        candidateNeedsCleanup: inout Bool
    ) throws {
        do {
            let publishedState = try readSnapshot(at: configURL).state
            guard publishedState.matchesAcrossRename(candidateState) else {
                candidateNeedsCleanup = false
                throw Self.recoveryFailure
            }
            try atomicSwap(candidateURL, configURL)
            let restoredCandidate = try readSnapshot(at: candidateURL).state
            guard restoredCandidate.matchesAcrossRename(candidateState) else {
                candidateNeedsCleanup = false
                throw Self.recoveryFailure
            }
        } catch {
            candidateNeedsCleanup = false
            throw Self.recoveryFailure
        }
    }

    private func createFile(
        at url: URL,
        data: Data,
        mode: Int,
        candidateNeedsCleanup: inout Bool
    ) throws {
        let created = fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: mode]
        )
        guard created else { throw Self.saveFailure }
        candidateNeedsCleanup = true

        do {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            throw Self.saveFailure
        }
    }

    private func validate(_ candidateURL: URL) async throws {
        do {
            let result = try await runner.run(
                DarkbloomCommand.status(executable: executable, config: candidateURL),
                timeout: DarkbloomSourcePolicy.processTimeout,
                outputLimit: DarkbloomSourcePolicy.processOutputByteLimit,
                onOutput: nil
            )
            guard result.exitCode == 0 else { throw Self.validationFailure }
        } catch {
            throw Self.validationFailure
        }
    }

    private func preserveSecurityMetadata(
        from sourceURL: URL,
        to candidateURL: URL,
        expectedState: ProviderConfigFileState
    ) throws {
        do {
            if let preserveMetadata = hooks.preserveMetadata {
                try preserveMetadata(sourceURL, candidateURL)
            } else {
                let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
                    candidateURL.withUnsafeFileSystemRepresentation { candidatePath in
                        guard let sourcePath, let candidatePath else { return Int32(-1) }
                        return Darwin.copyfile(
                            sourcePath,
                            candidatePath,
                            nil,
                            copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
                        )
                    }
                }
                guard result == 0 else { throw Self.metadataFailure }
            }

            let candidateState = try readSnapshot(at: candidateURL).state
            guard candidateState.hasSameSecurityMetadata(as: expectedState) else {
                throw Self.metadataFailure
            }
        } catch {
            throw Self.metadataFailure
        }
    }

    private func uniqueSibling(named purpose: String) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent(
            ".\(configURL.lastPathComponent).darkbloom-monitor-\(purpose)-\(UUID().uuidString)"
        )
    }

    private func openLockedDescriptor(at url: URL, lockFlag: Int32) async throws -> Int32 {
        guard lockPolicy.maxAttempts > 0 else { throw Self.busyFailure }

        for attempt in 1...lockPolicy.maxAttempts {
            try Task.checkCancellation()
            if let descriptor = try tryOpenLockedDescriptor(at: url, lockFlag: lockFlag) {
                return descriptor
            }
            try await waitBeforeLockRetry(attempt: attempt)
        }

        throw Self.busyFailure
    }

    private func openPublicationDescriptors(
        candidateURL: URL
    ) async throws -> (config: Int32, candidate: Int32) {
        guard lockPolicy.maxAttempts > 0 else { throw Self.busyFailure }

        for attempt in 1...lockPolicy.maxAttempts {
            try Task.checkCancellation()
            guard let configDescriptor = try tryOpenLockedDescriptor(
                at: configURL,
                lockFlag: O_EXLOCK
            ) else {
                try await waitBeforeLockRetry(attempt: attempt)
                continue
            }

            do {
                try Task.checkCancellation()
                if let candidateDescriptor = try tryOpenLockedDescriptor(
                    at: candidateURL,
                    lockFlag: O_EXLOCK
                ) {
                    do {
                        try Task.checkCancellation()
                        return (configDescriptor, candidateDescriptor)
                    } catch {
                        Darwin.close(candidateDescriptor)
                        throw error
                    }
                }
            } catch {
                Darwin.close(configDescriptor)
                throw error
            }

            // Never retain the first lock while waiting for the second. This keeps
            // the config-then-candidate order deadlock-free for every retry.
            Darwin.close(configDescriptor)
            try await waitBeforeLockRetry(attempt: attempt)
        }

        throw Self.busyFailure
    }

    private func tryOpenLockedDescriptor(at url: URL, lockFlag: Int32) throws -> Int32? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | lockFlag
            )
        }
        if descriptor >= 0 { return descriptor }

        let lockError = errno
        guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
            throw Self.readFailure
        }
        return nil
    }

    private func waitBeforeLockRetry(attempt: Int) async throws {
        guard attempt < lockPolicy.maxAttempts else {
            throw Self.busyFailure
        }
        try await Task.sleep(for: lockPolicy.retryDelay)
    }

    private func atomicReplace(_ source: URL, at destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw Self.saveFailure }
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else { return Int32(-1) }
                return Darwin.renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else { throw Self.saveFailure }
    }

    private func cleanupCandidate(_ candidateURL: URL) throws {
        do {
            if let removeCandidate = hooks.removeCandidate {
                try removeCandidate(candidateURL)
            } else {
                try fileManager.removeItem(at: candidateURL)
            }
        } catch {
            throw ProviderConfigError.validationFailed(
                "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration"
            )
        }
    }

}

private struct ProviderConfigFileSnapshot: Sendable {
    let data: Data
    let state: ProviderConfigFileState
}

private struct ProviderConfigFileState: Equatable, Sendable {
    let revision: String
    let device: UInt64
    let inode: UInt64
    let permissions: Int
    let owner: UInt32
    let group: UInt32
    let linkCount: UInt16
    let size: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
    let flags: UInt32
    let generation: UInt32

    init(stat value: Darwin.stat, data: Data) {
        revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        permissions = Int(value.st_mode & 0o7777)
        owner = value.st_uid
        group = value.st_gid
        linkCount = value.st_nlink
        size = value.st_size
        modificationSeconds = value.st_mtimespec.tv_sec
        modificationNanoseconds = value.st_mtimespec.tv_nsec
        changeSeconds = value.st_ctimespec.tv_sec
        changeNanoseconds = value.st_ctimespec.tv_nsec
        flags = value.st_flags
        generation = value.st_gen
    }

    /// `renameatx_np(..., RENAME_SWAP)` changes inode change-time even though
    /// it does not change the file's contents or security attributes.
    func matchesAcrossRename(_ other: Self) -> Bool {
        revision == other.revision
            && device == other.device
            && inode == other.inode
            && permissions == other.permissions
            && owner == other.owner
            && group == other.group
            && linkCount == other.linkCount
            && size == other.size
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
            && flags == other.flags
            && generation == other.generation
    }

    func hasSameSecurityMetadata(as other: Self) -> Bool {
        permissions == other.permissions
            && owner == other.owner
            && group == other.group
            && flags == other.flags
    }
}
