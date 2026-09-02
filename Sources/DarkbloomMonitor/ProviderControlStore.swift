import DarkbloomTelemetry
import Foundation
import SwiftUI

enum ProviderOperation: Equatable {
    case idle
    case refreshing
    case saving
    case downloading(String)
    case deleting(String)
    case lifecycle(ProviderLifecycleAction)
}

enum LifecycleConfirmation: Equatable {
    case stop(ProviderActivityRisk)
    case restart(ProviderActivityRisk)

    var action: ProviderLifecycleAction {
        switch self {
        case .stop: .stop
        case .restart: .restart
        }
    }

    var risk: ProviderActivityRisk {
        switch self {
        case .stop(let risk), .restart(let risk): risk
        }
    }
}

@MainActor
final class ProviderControlStore: ObservableObject {
    @Published private(set) var snapshot: ProviderControlSnapshot?
    @Published private(set) var draft: ProviderConfigDraft?
    @Published private(set) var operation: ProviderOperation = .idle
    @Published private(set) var pendingConfirmation: LifecycleConfirmation?
    @Published private(set) var restartRequired = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestDownloadProgressLine: String?

    private let controller: any ProviderControlling
    private let diagnosticSanitizer: UserDiagnosticSanitizer
    private let refreshTelemetry: @MainActor @Sendable () async -> Void
    private var currentTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0

    init(
        controller: any ProviderControlling,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        refreshTelemetry: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.controller = controller
        diagnosticSanitizer = UserDiagnosticSanitizer(homeDirectory: homeDirectory)
        self.refreshTelemetry = refreshTelemetry
    }

    var canSave: Bool {
        guard operation == .idle, let draft, draft.hasChanges else { return false }
        return draftValidationMessage == nil
    }

    func canDownload(_ modelID: String) -> Bool {
        guard operation == .idle, hasFreshModelSources, let snapshot else { return false }
        return snapshot.inventory.available.contains {
            $0.catalogID == modelID && $0.issue == nil
        }
    }

    func sanitizedDiagnostic(_ value: String) -> String {
        diagnosticSanitizer.sanitize(value)
    }

    var draftValidationMessage: String? {
        guard let draft else { return "Provider configuration is unavailable" }
        guard let snapshot else { return "Model inventory is unavailable" }
        guard snapshot.sources.catalog == .fresh else {
            return "Refresh the model catalog before changing provider settings"
        }
        guard snapshot.sources.localModels == .fresh else {
            return "Refresh local models before changing provider settings"
        }

        let enabled = Set(draft.selection.enabled)
        if let modelID = draft.selection.preloaded.first(where: { !enabled.contains($0) }) {
            return "Enable '\(Self.safeIdentifier(modelID))' or remove it from preload"
        }

        let validSelectors = Set(snapshot.inventory.myCatalog.flatMap { item in
            [item.catalogID, item.configuredSelector].compactMap { $0 }
        })
        if let modelID = (draft.selection.enabled + draft.selection.preloaded).first(where: {
            !validSelectors.contains($0)
        }) {
            return "Downloaded model '\(Self.safeIdentifier(modelID))' is unavailable"
        }
        return nil
    }

    private var hasFreshModelSources: Bool {
        guard let sources = snapshot?.sources else { return false }
        return sources.catalog == .fresh && sources.localModels == .fresh
    }

    func refresh() async {
        guard let generation = begin(.refreshing) else { return }
        let controller = self.controller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await controller.refresh()
                try Task.checkCancellation()
                accept(refreshed)
            } catch is CancellationError {
                // Cancellation is an intentional state transition, not a user-facing failure.
            } catch {
                errorMessage = "Could not refresh model controls."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func setEnabled(_ enabled: Bool, modelID: String) {
        guard var draft else { return }
        Self.setMembership(enabled, modelID: modelID, in: &draft.selection.enabled)
        self.draft = draft
    }

    func setPreloaded(_ preloaded: Bool, modelID: String) {
        guard var draft else { return }
        Self.setMembership(preloaded, modelID: modelID, in: &draft.selection.preloaded)
        self.draft = draft
    }

    func save() async {
        guard canSave, let draftToSave = draft,
              let generation = begin(.saving)
        else { return }
        let controller = self.controller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await controller.save(draftToSave)
                try Task.checkCancellation()
                draft = result.draft
                restartRequired = restartRequired || result.restartRequired
                if let snapshot {
                    self.snapshot = ProviderControlSnapshot(
                        inventory: snapshot.inventory,
                        draft: result.draft,
                        capturedAt: snapshot.capturedAt,
                        sources: snapshot.sources
                    )
                }
                do {
                    let refreshed = try await controller.refresh()
                    try Task.checkCancellation()
                    accept(refreshed)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    errorMessage = "Settings were saved, but model controls could not refresh."
                }
            } catch is CancellationError {
                // The service owns rollback and publication boundaries.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: "save")
            } catch let error as ProviderConfigError {
                errorMessage = configErrorMessage(error)
            } catch {
                errorMessage = "Could not save provider settings."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func download(_ modelID: String) async {
        guard let generation = begin(.downloading(modelID)) else { return }
        latestDownloadProgressLine = nil
        let controller = self.controller
        let progress = DownloadProgressAccumulator(sanitizer: diagnosticSanitizer)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await controller.download(modelID) { [weak self] chunk in
                    guard let line = progress.accept(chunk) else { return }
                    Task { @MainActor [weak self] in
                        guard self?.operation == .downloading(modelID) else { return }
                        self?.latestDownloadProgressLine = line
                    }
                }
                try Task.checkCancellation()
                latestDownloadProgressLine = progress.latestLine
                let refreshed = try await controller.refresh()
                try Task.checkCancellation()
                accept(refreshed, preserving: draft)
            } catch is CancellationError {
                // Cancellation is surfaced by returning to idle.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: "download")
            } catch {
                errorMessage = "Could not download '\(Self.safeIdentifier(modelID))'."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func delete(_ modelID: String) async {
        guard let generation = begin(.deleting(modelID)) else { return }
        let controller = self.controller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await controller.delete(modelID)
                try Task.checkCancellation()
                let refreshed = try await controller.refresh()
                try Task.checkCancellation()
                accept(refreshed, preserving: draft)
            } catch is CancellationError {
                // Cancellation is surfaced by returning to idle.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: "delete")
            } catch {
                errorMessage = "Could not delete '\(Self.safeIdentifier(modelID))'."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func request(_ action: ProviderLifecycleAction) async {
        pendingConfirmation = nil
        guard let generation = begin(.lifecycle(action)) else { return }
        let controller = self.controller
        let savedEnabledModels = draft?.original.enabled ?? snapshot?.draft.original.enabled ?? []
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if action == .start {
                    try await executeLifecycle(action, enabledModels: savedEnabledModels)
                } else {
                    let firstRisk = await controller.activityRisk()
                    try Task.checkCancellation()
                    if firstRisk == .idle {
                        let finalRisk = await controller.activityRisk()
                        try Task.checkCancellation()
                        if finalRisk == .idle {
                            try await executeLifecycle(action, enabledModels: savedEnabledModels)
                        } else {
                            pendingConfirmation = Self.confirmation(action: action, risk: finalRisk)
                        }
                    } else {
                        pendingConfirmation = Self.confirmation(action: action, risk: firstRisk)
                    }
                }
            } catch is CancellationError {
                // Cancellation leaves authoritative state unchanged.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: action.rawValue)
            } catch {
                errorMessage = "Could not \(action.rawValue) the provider."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func confirmPendingLifecycle() async {
        guard let confirmation = pendingConfirmation,
              let generation = begin(.lifecycle(confirmation.action))
        else { return }
        let action = confirmation.action
        let controller = self.controller
        let savedEnabledModels = draft?.original.enabled ?? snapshot?.draft.original.enabled ?? []
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let finalRisk = await controller.activityRisk()
                try Task.checkCancellation()
                pendingConfirmation = Self.confirmation(action: action, risk: finalRisk)
                pendingConfirmation = nil
                try await executeLifecycle(action, enabledModels: savedEnabledModels)
            } catch is CancellationError {
                // Cancellation leaves authoritative state unchanged.
            } catch let error as ProviderControlError {
                pendingConfirmation = nil
                errorMessage = controlErrorMessage(error, action: action.rawValue)
            } catch {
                pendingConfirmation = nil
                errorMessage = "Could not \(action.rawValue) the provider."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func cancelPendingLifecycle() {
        pendingConfirmation = nil
    }

    func cancelCurrentOperation() {
        currentTask?.cancel()
    }

    private func executeLifecycle(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        do {
            try await controller.execute(action, enabledModels: enabledModels)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let commandError = error
            do {
                try await reconcileLifecycleState()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The lifecycle command's outcome is the primary user-facing
                // failure. Reconciliation is best-effort after that attempt.
            }
            throw commandError
        }
        if action == .start || action == .restart {
            restartRequired = false
        }
        try await reconcileLifecycleState()
    }

    private func reconcileLifecycleState() async throws {
        await refreshTelemetry()
        try Task.checkCancellation()
        let refreshed = try await controller.refresh()
        try Task.checkCancellation()
        accept(refreshed, preserving: draft)
    }

    private func begin(_ newOperation: ProviderOperation) -> UInt64? {
        guard operation == .idle else { return nil }
        operationGeneration &+= 1
        operation = newOperation
        errorMessage = nil
        return operationGeneration
    }

    private func finish(_ generation: UInt64) {
        guard operationGeneration == generation else { return }
        currentTask = nil
        operation = .idle
    }

    private func awaitTask(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func accept(
        _ refreshed: ProviderControlSnapshot,
        preserving stagedDraft: ProviderConfigDraft? = nil
    ) {
        snapshot = refreshed
        draft = stagedDraft ?? refreshed.draft
    }

    private static func setMembership(
        _ included: Bool,
        modelID: String,
        in values: inout [String]
    ) {
        if included {
            if !values.contains(modelID) {
                values.append(modelID)
            }
        } else {
            values.removeAll { $0 == modelID }
        }
    }

    private static func confirmation(
        action: ProviderLifecycleAction,
        risk: ProviderActivityRisk
    ) -> LifecycleConfirmation? {
        switch (action, risk) {
        case (.stop, .active), (.stop, .unknown): .stop(risk)
        case (.restart, .active), (.restart, .unknown): .restart(risk)
        case (_, .idle), (.start, _): nil
        }
    }

    private func controlErrorMessage(
        _ error: ProviderControlError,
        action: String
    ) -> String {
        switch error {
        case .commandAlreadyRunning:
            "Another provider action is already running."
        case .executableUnavailable:
            "The Darkbloom command is unavailable."
        case .noEnabledModels:
            "Start requires at least one saved enabled model."
        case .inventoryUnavailable(let reason):
            Self.safeInventoryDiagnostics.contains(reason)
                ? diagnosticSanitizer.sanitize(reason)
                : "Model inventory is unavailable."
        case .deleteBlocked(let reason):
            Self.safeDeleteDiagnostics.contains(reason)
                ? diagnosticSanitizer.sanitize(reason)
                : "The model cannot be deleted safely."
        case .invalidOutput:
            "Darkbloom returned an invalid response while trying to \(action)."
        }
    }

    private func configErrorMessage(_ error: ProviderConfigError) -> String {
        switch error {
        case .changedExternally:
            "Provider settings changed outside the app. Reload and try again."
        case .preloadRequiresEnabled(let modelID):
            "Enable '\(Self.safeIdentifier(modelID))' or remove it from preload."
        case .validationFailed(let reason):
            configValidationMessage(reason)
        case .invalidUTF8, .missingArray, .duplicateArray, .malformedArray,
             .nonStringValue, .duplicateModel:
            "Provider settings could not be read safely."
        }
    }

    private func configValidationMessage(_ reason: String) -> String {
        let message: String
        switch reason {
        case "Darkbloom rejected the candidate configuration":
            message = "Darkbloom rejected the provider settings."
        case "Could not read the provider configuration":
            message = "Could not read the provider configuration."
        case "Could not save the provider configuration":
            message = "Could not save the provider configuration."
        case "Provider configuration changed during recovery; recovery data was preserved beside it":
            message = "Provider configuration changed during recovery; recovery data was preserved beside it."
        case "Could not preserve provider configuration security metadata":
            message = "Could not preserve provider configuration security metadata."
        case "Provider configuration is busy; try again":
            message = "Provider configuration is busy; try again."
        case "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration":
            message = "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration."
        default:
            message = "Could not save provider settings."
        }
        return diagnosticSanitizer.sanitize(message)
    }

    private static let safeInventoryDiagnostics: Set<String> = [
        "The requested model is not a fresh available catalog entry",
        "Saved model selection is not an unambiguous downloaded catalog model",
        "Model catalog is unavailable",
        "Local model list is unavailable",
    ]

    private static let safeDeleteDiagnostics: Set<String> = {
        let fixed = [
            "The local model identity is ambiguous",
            "Disable the model and save before deleting it",
            "Remove the model from preload and save before deleting it",
            "The local model could not be matched safely",
            "The active model cannot be deleted",
            "A loaded model cannot be deleted",
        ]
        let residency = [
            "Provider activity is unavailable",
            "Provider activity timestamp is invalid",
            "Provider activity is stale",
            "Provider activity timestamp is in the future",
            "Loaded model state is unavailable",
            "Loaded model state timestamp is invalid",
            "Loaded model state is stale",
            "Loaded model state timestamp is in the future",
        ].map { "\($0); deletion was not attempted" }
        return Set(fixed + residency)
    }()

    private static func safeIdentifier(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed))
        return String(sanitized.prefix(80))
    }
}

private final class UserDiagnosticSanitizer: @unchecked Sendable {
    private static let maximumLength = 200
    private let homePath: String

    init(homeDirectory: URL) {
        homePath = Self.normalizedForMatching(homeDirectory.standardizedFileURL.path)
    }

    func sanitize(_ value: String) -> String {
        var result = Self.normalizedForMatching(value)
        if homePath != "/" && !homePath.isEmpty {
            result = result.replacingOccurrences(of: homePath, with: "~")
        }
        result = Self.replacing(
            pattern: #"(?i)Authorization\s*:\s*Bearer\s+[^\s,;]+"#,
            in: result,
            with: "Authorization: <redacted>"
        )
        result = Self.replacing(
            pattern: #"(?i)\b(access[_ -]?token|refresh[_ -]?token|auth(?:orization)?[_ -]?token|token|api[_ -]?key|password|secret)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            in: result,
            with: "$1=<redacted>"
        )
        result = Self.normalizedForMatching(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(result.prefix(Self.maximumLength))
    }

    private static func normalizedForMatching(_ value: String) -> String {
        var normalized = value.precomposedStringWithCanonicalMapping
        // Collapse obfuscating controls while retaining ANSI delimiters long
        // enough to remove the entire sequence, including its visible payload.
        normalized = String(normalized.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                || $0.value == 0x07
                || $0.value == 0x1B
        })
        let ansiPatterns = [
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#,
            #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            #"\x1B[@-_]"#,
        ]
        for pattern in ansiPatterns {
            normalized = replacing(
                pattern: pattern,
                in: normalized,
                with: ""
            )
        }
        return String(normalized.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
    }

    private static func replacing(
        pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}

private final class DownloadProgressAccumulator: @unchecked Sendable {
    private struct StreamState {
        var line = Data()
        var isTruncated = false
        var lastUpdate: UInt64 = 0

        mutating func accept(
            _ data: Data,
            maximumLineBytes: Int,
            sanitizer: UserDiagnosticSanitizer
        ) -> String? {
            var latestCompletedLine: String?
            for byte in data {
                if byte == 0x0A || byte == 0x0D {
                    if !isTruncated,
                       let candidate = Self.sanitized(line, using: sanitizer) {
                        latestCompletedLine = candidate
                    }
                    line.removeAll(keepingCapacity: true)
                    isTruncated = false
                } else if !isTruncated {
                    if line.count < maximumLineBytes {
                        line.append(byte)
                    } else {
                        // Never retain a suffix after losing its identifying
                        // prefix: the entire logical line becomes unrenderable.
                        line.removeAll(keepingCapacity: false)
                        isTruncated = true
                    }
                }
            }
            return latestCompletedLine
        }

        func sanitizedIncompleteLine(
            using sanitizer: UserDiagnosticSanitizer
        ) -> String? {
            guard !isTruncated else { return nil }
            return Self.sanitized(line, using: sanitizer)
        }

        private static func sanitized(
            _ data: Data,
            using sanitizer: UserDiagnosticSanitizer
        ) -> String? {
            guard !data.isEmpty else { return nil }
            let value = sanitizer.sanitize(String(decoding: data, as: UTF8.self))
            return value.isEmpty ? nil : value
        }
    }

    private struct StoredLine {
        let sequence: UInt64
        let value: String
    }

    private static let maximumLineBytes = 4_096
    private let lock = NSLock()
    private let sanitizer: UserDiagnosticSanitizer
    private var standardOutput = StreamState()
    private var standardError = StreamState()
    private var storedLatestLine: StoredLine?
    private var sequence: UInt64 = 0

    init(sanitizer: UserDiagnosticSanitizer) {
        self.sanitizer = sanitizer
    }

    var latestLine: String? {
        lock.withLock {
            var candidates = [StoredLine]()
            if let storedLatestLine {
                candidates.append(storedLatestLine)
            }
            if let value = standardOutput.sanitizedIncompleteLine(using: sanitizer) {
                candidates.append(StoredLine(
                    sequence: standardOutput.lastUpdate,
                    value: value
                ))
            }
            if let value = standardError.sanitizedIncompleteLine(using: sanitizer) {
                candidates.append(StoredLine(
                    sequence: standardError.lastUpdate,
                    value: value
                ))
            }
            return candidates.max { $0.sequence < $1.sequence }?.value
        }
    }

    func accept(_ chunk: ProcessOutputChunk) -> String? {
        lock.withLock {
            sequence &+= 1
            let completed: String?
            switch chunk.destination {
            case .standardOutput:
                standardOutput.lastUpdate = sequence
                completed = standardOutput.accept(
                    chunk.data,
                    maximumLineBytes: Self.maximumLineBytes,
                    sanitizer: sanitizer
                )
            case .standardError:
                standardError.lastUpdate = sequence
                completed = standardError.accept(
                    chunk.data,
                    maximumLineBytes: Self.maximumLineBytes,
                    sanitizer: sanitizer
                )
            }
            if let completed {
                storedLatestLine = StoredLine(sequence: sequence, value: completed)
            }
            return completed
        }
    }
}
