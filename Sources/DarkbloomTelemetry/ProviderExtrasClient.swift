import Foundation

public protocol ProviderExtrasProviding: Sendable {
    func refresh() async -> ProviderExtrasSnapshot
    func saveIdle(minutes: Int) async throws
    func setBeta(id: String, enabled: Bool) async throws
}

public enum ProviderExtrasCommand {
    public static func idleStatus(executable: URL, config: URL) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: ["idle", "status", "--json", "--config", config.path]
        )
    }

    public static func betaList(executable: URL, config: URL) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: ["beta", "list", "--json", "--config", config.path]
        )
    }

    public static func fanStatus(executable: URL) -> ProcessCommand {
        ProcessCommand(executable: executable, arguments: ["fan", "status", "--json"])
    }

    public static func autoUpdateStatus(executable: URL, config: URL) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: ["autoupdate", "status", "--config", config.path]
        )
    }

    public static func saveIdle(
        executable: URL,
        config: URL,
        minutes: Int
    ) -> ProcessCommand {
        if minutes == 0 {
            return ProcessCommand(
                executable: executable,
                arguments: ["idle", "keep-loaded", "--config", config.path]
            )
        }
        return ProcessCommand(
            executable: executable,
            arguments: [
                "idle", "unload-after", String(minutes), "--config", config.path,
            ]
        )
    }

    public static func setBeta(
        executable: URL,
        config: URL,
        id: String,
        enabled: Bool
    ) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: [
                "beta", enabled ? "enable" : "disable", id, "--config", config.path,
            ]
        )
    }
}

/// Reads the structured diagnostics added by the official Darkbloom CLI. The
/// process runner is injected so the app can use the bounded runner in
/// production and deterministic fixtures in tests.
public struct ProviderExtrasClient: ProviderExtrasProviding, Sendable {
    public static let allowedBetaFeatureIDs: Set<String> = [
        "gemma-prefill-layer18",
        "gemma-weighted-r1",
        "mtp",
    ]

    public let policy: DarkbloomSourcePolicy
    private let runner: any ProcessExecuting
    private let now: @Sendable () -> Date
    private let testOnlyExecutable: URL?

    public init(
        policy: DarkbloomSourcePolicy,
        runner: any ProcessExecuting = CappedProcessRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policy = policy
        self.runner = runner
        self.now = now
        self.testOnlyExecutable = nil
    }

    init(
        policy: DarkbloomSourcePolicy,
        runner: any ProcessExecuting,
        now: @escaping @Sendable () -> Date,
        testOnlyExecutable: URL
    ) {
        self.policy = policy
        self.runner = runner
        self.now = now
        self.testOnlyExecutable = testOnlyExecutable
    }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        runner: any ProcessExecuting = CappedProcessRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            policy: DarkbloomSourcePolicy(
                homeDirectory: homeDirectory,
                environmentPath: environmentPath
            ),
            runner: runner,
            now: now
        )
    }

    public func refresh() async -> ProviderExtrasSnapshot {
        let capturedAt = now()
        guard capturedAt.timeIntervalSince1970.isFinite else {
            return unavailableSnapshot(capturedAt: Date())
        }

        guard let executable = resolveExecutable() else {
            return ProviderExtrasSnapshot(
                capturedAt: capturedAt,
                idlePolicy: .unavailable(reason: "Darkbloom idle policy is unavailable"),
                betaFeatures: .unavailable(reason: "Darkbloom beta features are unavailable"),
                fanStatus: .unavailable(reason: "Darkbloom fan status is unavailable"),
                autoUpdateStatus: nil
            )
        }

        async let idle = readIdle(executable: executable, capturedAt: capturedAt)
        async let beta = readBeta(executable: executable, capturedAt: capturedAt)
        async let fan = readFan(executable: executable, capturedAt: capturedAt)
        async let autoUpdate = readAutoUpdate(executable: executable, capturedAt: capturedAt)

        return await ProviderExtrasSnapshot(
            capturedAt: capturedAt,
            idlePolicy: idle,
            betaFeatures: beta,
            fanStatus: fan,
            autoUpdateStatus: autoUpdate
        )
    }

    public func saveIdle(minutes: Int) async throws {
        guard ProviderIdlePolicy.isValid(minutes: minutes) else {
            throw ProviderExtrasMutationError.invalidIdleMinutes
        }
        guard let executable = resolveExecutable() else {
            throw ProviderExtrasMutationError.executableUnavailable
        }
        let command = ProviderExtrasCommand.saveIdle(
            executable: executable,
            config: policy.providerConfig,
            minutes: minutes
        )
        try await runMutation(command)
    }

    public func setBeta(id: String, enabled: Bool) async throws {
        let canonicalID = id.lowercased()
        guard canonicalID == id,
              Self.allowedBetaFeatureIDs.contains(canonicalID),
              canonicalID.unicodeScalars.allSatisfy({
                      ($0.value >= 97 && $0.value <= 122)
                          || ($0.value >= 48 && $0.value <= 57)
                      || $0.value == 45
              })
        else {
            throw ProviderExtrasMutationError.unsupportedBetaFeature
        }
        guard let executable = resolveExecutable() else {
            throw ProviderExtrasMutationError.executableUnavailable
        }
        let command = ProviderExtrasCommand.setBeta(
            executable: executable,
            config: policy.providerConfig,
            id: canonicalID,
            enabled: enabled
        )
        try await runMutation(command)
    }

    private func resolveExecutable() -> URL? {
        if let testOnlyExecutable { return testOnlyExecutable }
        return policy.cliCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func readIdle(
        executable: URL,
        capturedAt: Date
    ) async -> SourceAvailability<ProviderIdlePolicy> {
        do {
            let result = try await run(
                ProviderExtrasCommand.idleStatus(
                    executable: executable,
                    config: policy.providerConfig
                )
            )
            guard result.exitCode == 0 else { throw ProviderExtrasParseError.invalidPayload }
            let value = try ProviderExtrasParser.parseIdle(result.standardOutput)
            return .available(value: value, capturedAt: capturedAt)
        } catch {
            return .unavailable(reason: "Darkbloom idle policy is unavailable")
        }
    }

    private func readBeta(
        executable: URL,
        capturedAt: Date
    ) async -> SourceAvailability<[ProviderBetaFeature]> {
        do {
            let result = try await run(
                ProviderExtrasCommand.betaList(
                    executable: executable,
                    config: policy.providerConfig
                )
            )
            guard result.exitCode == 0 else { throw ProviderExtrasParseError.invalidPayload }
            let value = try ProviderExtrasParser.parseBeta(result.standardOutput)
            return .available(value: value, capturedAt: capturedAt)
        } catch {
            return .unavailable(reason: "Darkbloom beta features are unavailable")
        }
    }

    private func readFan(
        executable: URL,
        capturedAt: Date
    ) async -> SourceAvailability<ProviderFanStatus> {
        do {
            let result = try await run(
                ProviderExtrasCommand.fanStatus(executable: executable)
            )
            guard result.exitCode == 0 else { throw ProviderExtrasParseError.invalidPayload }
            let value = try ProviderExtrasParser.parseFan(result.standardOutput)
            guard value.helperIsFresh(at: capturedAt) else {
                if !value.diagnostic.gpuTemperatures.isEmpty || !value.diagnostic.fans.isEmpty {
                    return .available(value: value.withoutHelper(), capturedAt: capturedAt)
                }
                return .stale(
                    value: value,
                    capturedAt: capturedAt,
                    reason: "Darkbloom fan helper status is stale"
                )
            }
            return .available(value: value, capturedAt: capturedAt)
        } catch {
            return .unavailable(reason: "Darkbloom fan status is unavailable")
        }
    }

    private func readAutoUpdate(
        executable: URL,
        capturedAt: Date
    ) async -> SourceAvailability<ProviderAutoUpdateStatus>? {
        do {
            let result = try await run(
                ProviderExtrasCommand.autoUpdateStatus(
                    executable: executable,
                    config: policy.providerConfig
                )
            )
            guard result.exitCode == 0 else { return nil }
            guard let text = String(data: result.standardOutput, encoding: .utf8),
                  let value = ProviderExtrasParser.parseAutoUpdate(text)
            else {
                return nil
            }
            return .available(value: value, capturedAt: capturedAt)
        } catch {
            // This command is plain text and is optional across CLI versions.
            return nil
        }
    }

    private func run(_ command: ProcessCommand) async throws -> CommandResult {
        try await runner.run(
            command,
            timeout: DarkbloomSourcePolicy.processTimeout,
            outputLimit: DarkbloomSourcePolicy.processOutputByteLimit,
            onOutput: nil
        )
    }

    private func runMutation(_ command: ProcessCommand) async throws {
        do {
            let result = try await runner.run(
                command,
                timeout: DarkbloomSourcePolicy.processTimeout,
                outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
                onOutput: nil
            )
            guard result.exitCode == 0 else {
                throw ProviderExtrasMutationError.commandFailed
            }
        } catch let error as ProviderExtrasMutationError {
            throw error
        } catch {
            // ProcessRunnerError can retain stderr; deliberately map it to a
            // fixed message before anything reaches UI or logs.
            throw ProviderExtrasMutationError.commandFailed
        }
    }

    private func unavailableSnapshot(capturedAt: Date) -> ProviderExtrasSnapshot {
        ProviderExtrasSnapshot(
            capturedAt: capturedAt,
            idlePolicy: .unavailable(reason: "Darkbloom idle policy is unavailable"),
            betaFeatures: .unavailable(reason: "Darkbloom beta features are unavailable"),
            fanStatus: .unavailable(reason: "Darkbloom fan status is unavailable"),
            autoUpdateStatus: nil
        )
    }
}

public enum ProviderExtrasParser {
    public static func parseIdle(_ data: Data) throws -> ProviderIdlePolicy {
        guard data.count <= 256 * 1_024 else { throw ProviderExtrasParseError.invalidPayload }
        do {
            let payload = try JSONDecoder().decode(IdlePayload.self, from: data)
            guard let minutes = Int(exactly: payload.idleTimeoutMins),
                  ProviderIdlePolicy.isValid(minutes: minutes),
                  Self.validText(payload.policy, maximumLength: 32),
                  Self.validText(payload.summary, maximumLength: 512)
            else { throw ProviderExtrasParseError.invalidValue }
            return ProviderIdlePolicy(
                idleTimeoutMinutes: minutes,
                policy: payload.policy,
                summary: payload.summary,
                pinned: payload.pinned
            )
        } catch let error as ProviderExtrasParseError {
            throw error
        } catch {
            throw ProviderExtrasParseError.invalidPayload
        }
    }

    public static func parseBeta(_ data: Data) throws -> [ProviderBetaFeature] {
        guard data.count <= 256 * 1_024 else { throw ProviderExtrasParseError.invalidPayload }
        do {
            let payload = try JSONDecoder().decode([BetaPayload].self, from: data)
            guard payload.count <= 64 else { throw ProviderExtrasParseError.invalidValue }
            var seenIDs = Set<String>()
            return try payload.map { item in
                guard Self.validIdentifier(item.id),
                      seenIDs.insert(item.id).inserted,
                      Self.validText(item.title, maximumLength: 160),
                      Self.validText(item.summary, maximumLength: 512),
                      let state = ProviderBetaFeatureState(rawValue: item.state.lowercased())
                else { throw ProviderExtrasParseError.invalidValue }
                if let enabled = item.enabled,
                   state == .auto || enabled != (state == .on) {
                    throw ProviderExtrasParseError.invalidValue
                }
                return ProviderBetaFeature(
                    id: item.id,
                    title: item.title,
                    state: state,
                    enabled: item.enabled,
                    requiresRestart: item.requiresRestart,
                    summary: item.summary
                )
            }
        } catch let error as ProviderExtrasParseError {
            throw error
        } catch {
            throw ProviderExtrasParseError.invalidPayload
        }
    }

    public static func parseFan(_ data: Data) throws -> ProviderFanStatus {
        guard data.count <= 256 * 1_024 else { throw ProviderExtrasParseError.invalidPayload }
        do {
            let payload = try JSONDecoder().decode(FanPayload.self, from: data)
            guard Self.validText(payload.capability, maximumLength: 96),
                  Self.validText(payload.diagnostic.chip, maximumLength: 96)
            else { throw ProviderExtrasParseError.invalidValue }
            let helper = try payload.helper.map(Self.makeHelper)
            let diagnostic = try makeDiagnostic(payload.diagnostic)
            return ProviderFanStatus(
                capability: payload.capability,
                installed: payload.installed,
                loaded: payload.loaded,
                helper: helper,
                diagnostic: diagnostic,
                helperErrorPresent: payload.helperError != nil,
                diagnosticErrorPresent: payload.diagnostic.error != nil
            )
        } catch let error as ProviderExtrasParseError {
            throw error
        } catch {
            throw ProviderExtrasParseError.invalidPayload
        }
    }

    public static func parseAutoUpdate(_ text: String) -> ProviderAutoUpdateStatus? {
        for line in text.split(whereSeparator: \.isNewline) {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalized == "auto-update is enabled" {
                return ProviderAutoUpdateStatus(enabled: true)
            }
            if normalized == "auto-update is disabled" {
                return ProviderAutoUpdateStatus(enabled: false)
            }
        }
        return nil
    }

    private static func makeHelper(_ payload: FanHelperPayload) throws -> ProviderFanHelperStatus {
        guard Self.validText(payload.mode, maximumLength: 64),
              Self.validText(payload.chip, maximumLength: 96),
              Self.validTemperature(payload.triggerTemperatureC),
              Self.validTemperature(payload.releaseTemperatureC),
              payload.releaseTemperatureC <= payload.triggerTemperatureC,
              Self.validPercent(payload.speedPercent),
              payload.updatedAt.value.timeIntervalSinceReferenceDate.isFinite,
              payload.fans.count <= 64
        else { throw ProviderExtrasParseError.invalidValue }
        if let temperature = payload.gpuTemperatureC,
           !Self.validTemperature(temperature) {
            throw ProviderExtrasParseError.invalidValue
        }
        return ProviderFanHelperStatus(
            enabled: payload.enabled,
            providerActive: payload.providerActive,
            mode: payload.mode,
            chip: payload.chip,
            gpuTemperatureCelsius: payload.gpuTemperatureC,
            triggerTemperatureCelsius: payload.triggerTemperatureC,
            releaseTemperatureCelsius: payload.releaseTemperatureC,
            speedPercent: payload.speedPercent,
            fans: try makeUniqueFans(payload.fans),
            updatedAt: payload.updatedAt.value
        )
    }

    private static func makeDiagnostic(_ payload: FanDiagnosticPayload) throws -> ProviderFanDiagnostic {
        guard payload.gpuTemperatures.count <= 128, payload.fans.count <= 64 else {
            throw ProviderExtrasParseError.invalidValue
        }
        return ProviderFanDiagnostic(
            chip: payload.chip,
            supported: payload.supported,
            gpuTemperatures: try payload.gpuTemperatures.map(makeTemperature),
            fans: try makeUniqueFans(payload.fans)
        )
    }

    private static func makeUniqueFans(_ payload: [FanReadingPayload]) throws -> [ProviderFanReading] {
        var seenIndexes = Set<Int>()
        return try payload.map { item in
            guard seenIndexes.insert(item.index).inserted else {
                throw ProviderExtrasParseError.invalidValue
            }
            return try makeFan(item)
        }
    }

    private static func makeTemperature(_ payload: FanTemperaturePayload) throws -> ProviderFanTemperature {
        guard Self.validIdentifier(payload.key, allowUnderscore: true),
              Self.validTemperature(payload.celsius)
        else { throw ProviderExtrasParseError.invalidValue }
        return ProviderFanTemperature(key: payload.key, celsius: payload.celsius)
    }

    private static func makeFan(_ payload: FanReadingPayload) throws -> ProviderFanReading {
        guard (0..<64).contains(payload.index),
              Self.validRPM(payload.actualRPM),
              Self.validRPM(payload.targetRPM),
              Self.validRPM(payload.minimumRPM),
              Self.validRPM(payload.maximumRPM),
              Self.validText(payload.mode, maximumLength: 64)
        else { throw ProviderExtrasParseError.invalidValue }
        if let min = payload.minimumRPM, let max = payload.maximumRPM, min > max {
            throw ProviderExtrasParseError.invalidValue
        }
        return ProviderFanReading(
            index: payload.index,
            actualRPM: payload.actualRPM,
            targetRPM: payload.targetRPM,
            minimumRPM: payload.minimumRPM,
            maximumRPM: payload.maximumRPM,
            mode: payload.mode
        )
    }

    private static func validTemperature(_ value: Double) -> Bool {
        value.isFinite && (-40...150).contains(value)
    }

    private static func validRPM(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && (0...100_000).contains(value)
    }

    private static func validPercent(_ value: Double) -> Bool {
        value.isFinite && (0...100).contains(value)
    }

    private static func validIdentifier(_ value: String, allowUnderscore: Bool = false) -> Bool {
        guard !value.isEmpty, value.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar.value == 45
                || (allowUnderscore && scalar.value == 95)
        }
    }

    private static func validText(_ value: String?, maximumLength: Int) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 32 && scalar.value != 127
        }
    }

    private struct IdlePayload: Decodable {
        let idleTimeoutMins: UInt64
        let policy: String
        let summary: String
        let pinned: Bool
    }

    private struct BetaPayload: Decodable {
        let id: String
        let title: String
        let state: String
        let enabled: Bool?
        let requiresRestart: Bool
        let summary: String
    }

    private struct FanPayload: Decodable {
        let capability: String
        let installed: Bool
        let loaded: Bool
        let helper: FanHelperPayload?
        let helperError: String?
        let diagnostic: FanDiagnosticPayload
    }

    private struct FanHelperPayload: Decodable {
        let enabled: Bool
        let providerActive: Bool
        let mode: String
        let chip: String
        let gpuTemperatureC: Double?
        let triggerTemperatureC: Double
        let releaseTemperatureC: Double
        let speedPercent: Double
        let fans: [FanReadingPayload]
        let updatedAt: FlexibleDate
    }

    private struct FanDiagnosticPayload: Decodable {
        let chip: String
        let supported: Bool
        let gpuTemperatures: [FanTemperaturePayload]
        let fans: [FanReadingPayload]
        let error: String?
    }

    private struct FanTemperaturePayload: Decodable {
        let key: String
        let celsius: Double
    }

    private struct FanReadingPayload: Decodable {
        let index: Int
        let actualRPM: Double?
        let targetRPM: Double?
        let minimumRPM: Double?
        let maximumRPM: Double?
        let mode: String?
    }

    private struct FlexibleDate: Decodable {
        let value: Date

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite {
                // Foundation's default JSONEncoder Date strategy is seconds
                // since the reference date (2001-01-01), which is what the
                // CLI's printJSON helper emits.
                value = Date(timeIntervalSinceReferenceDate: seconds)
                return
            }
            if let string = try? container.decode(String.self),
               let date = ISO8601DateFormatter().date(from: string) {
                value = date
                return
            }
            throw ProviderExtrasParseError.invalidValue
        }
    }
}

public extension DarkbloomSourcePolicy {
    static var currentUser: Self {
        Self(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        )
    }
}
