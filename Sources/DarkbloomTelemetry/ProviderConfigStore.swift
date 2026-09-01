import CryptoKit
import Darwin
import Foundation

public struct ProviderConfigDraft: Equatable, Sendable {
    public let sourceRevision: String
    public let original: ProviderModelSelection
    public var selection: ProviderModelSelection

    public var hasChanges: Bool { selection != original }

    public init(
        sourceRevision: String,
        original: ProviderModelSelection,
        selection: ProviderModelSelection
    ) {
        self.sourceRevision = sourceRevision
        self.original = original
        self.selection = selection
    }

    public func withSelection(_ selection: ProviderModelSelection) -> Self {
        var draft = self
        draft.selection = selection
        return draft
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

    private let configURL: URL
    private let executable: URL
    private let runner: any ProcessExecuting
    private let fileManager: FileManager

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
    }

    public func load() async throws -> ProviderConfigDraft {
        let document = try readDocument()
        return ProviderConfigDraft(
            sourceRevision: document.revision,
            original: document.selection,
            selection: document.selection
        )
    }

    public func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        guard draft.hasChanges else {
            return ProviderConfigSaveResult(draft: try await load(), restartRequired: false)
        }

        let current = try readDocument()
        guard current.revision == draft.sourceRevision else {
            throw ProviderConfigError.changedExternally
        }

        let candidateData = try current.rendering(draft.selection)
        let mode = try readMode()
        let candidateURL = uniqueSibling(named: "candidate")
        let backupCandidateURL = uniqueSibling(named: "backup-candidate")
        defer {
            try? fileManager.removeItem(at: candidateURL)
            try? fileManager.removeItem(at: backupCandidateURL)
        }

        try createFile(at: candidateURL, data: candidateData, mode: mode)
        try await validate(candidateURL)

        // Stage the exact last-known-good bytes before the final revision check.
        // This file remains invisible to consumers until its atomic rename below.
        try createFile(at: backupCandidateURL, data: current.data, mode: mode)

        let latestData = try readData()
        guard Self.revision(of: latestData) == draft.sourceRevision else {
            throw ProviderConfigError.changedExternally
        }

        let backupURL = configURL.appendingPathExtension("darkbloom-monitor-backup")
        try atomicReplace(backupCandidateURL, at: backupURL)
        try atomicReplace(candidateURL, at: configURL)

        return ProviderConfigSaveResult(draft: try await load(), restartRequired: true)
    }

    private func readDocument() throws -> ProviderConfigDocument {
        try ProviderConfigDocument(data: readData())
    }

    private func readData() throws -> Data {
        do {
            return try Data(contentsOf: configURL, options: [.mappedIfSafe])
        } catch {
            throw Self.readFailure
        }
    }

    private func readMode() throws -> Int {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
            guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
                throw Self.saveFailure
            }
            return mode
        } catch let error as ProviderConfigError {
            throw error
        } catch {
            throw Self.saveFailure
        }
    }

    private func createFile(at url: URL, data: Data, mode: Int) throws {
        let created = fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: mode]
        )
        guard created else { throw Self.saveFailure }

        do {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: url)
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

    private func uniqueSibling(named purpose: String) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent(
            ".\(configURL.lastPathComponent).darkbloom-monitor-\(purpose)-\(UUID().uuidString)"
        )
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

    private static func revision(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
