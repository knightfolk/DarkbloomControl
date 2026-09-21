import DarkbloomTelemetry
import Foundation
import SwiftUI

/// A parent-owned serial mutation closure used by settings surfaces. The
/// closure receives a stable label for logging/coordination and a single
/// operation that may call the extras client. It returns false when the parent
/// refuses or cannot confirm the operation.
typealias ProviderExtrasMutationExecutor = @MainActor @Sendable (
    _ label: String,
    _ operation: @escaping @Sendable () async throws -> Void
) async -> Bool

@MainActor
final class ProviderExtrasStore: ObservableObject {
    @Published private(set) var snapshot: ProviderExtrasSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var mutationInFlight = false
    @Published private(set) var errorMessage: String?

    private let client: any ProviderExtrasProviding
    private let pollingInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    /// Production initializer. It resolves only the approved Darkbloom CLI
    /// candidates from the shared source policy and performs read-only polling
    /// until a caller explicitly invokes a mutation method.
    init(
        policy: DarkbloomSourcePolicy = .currentUser,
        runner: any ProcessExecuting = CappedProcessRunner(),
        pollingInterval: Duration = .seconds(30)
    ) {
        self.client = ProviderExtrasClient(policy: policy, runner: runner)
        self.pollingInterval = pollingInterval
    }

    init(
        client: any ProviderExtrasProviding,
        pollingInterval: Duration = .seconds(30)
    ) {
        self.client = client
        self.pollingInterval = pollingInterval
    }

    func refresh() async {
        await refresh(force: false)
    }

    private func refresh(force: Bool) async {
        if let previous = refreshTask {
            if force { previous.cancel() }
            await previous.value
            if !force { return }
        }
        let client = self.client
        isRefreshing = true
        errorMessage = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let task = Task { @MainActor [weak self] in
            let refreshed = await client.refresh()
            guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
            self.snapshot = Self.merge(refreshed, with: self.snapshot)
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if refreshGeneration == generation {
            refreshTask = nil
            isRefreshing = false
        }
    }

    /// Begin explicit read-only polling. No setting is written by this loop.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.pollingInterval)
                } catch {
                    return
                }
                await self.refresh()
            }
        }
    }

    func stop() async {
        let polling = pollingTask
        polling?.cancel()
        let refresh = refreshTask
        refresh?.cancel()
        await polling?.value
        await refresh?.value
        pollingTask = nil
        refreshTask = nil
        isRefreshing = false
    }

    func saveIdle(minutes: Int) async throws {
        guard !mutationInFlight else {
            throw ProviderExtrasMutationError.mutationInProgress
        }
        mutationInFlight = true
        errorMessage = nil
        defer { mutationInFlight = false }
        do {
            try await client.saveIdle(minutes: minutes)
            await refresh(force: true)
        } catch let error as ProviderExtrasMutationError {
            errorMessage = error.userMessage
            throw error
        } catch {
            errorMessage = ProviderExtrasMutationError.commandFailed.userMessage
            throw ProviderExtrasMutationError.commandFailed
        }
    }

    func setBeta(id: String, enabled: Bool) async throws {
        guard !mutationInFlight else {
            throw ProviderExtrasMutationError.mutationInProgress
        }
        mutationInFlight = true
        errorMessage = nil
        defer { mutationInFlight = false }
        do {
            try await client.setBeta(id: id, enabled: enabled)
            await refresh(force: true)
        } catch let error as ProviderExtrasMutationError {
            errorMessage = error.userMessage
            throw error
        } catch {
            errorMessage = ProviderExtrasMutationError.commandFailed.userMessage
            throw ProviderExtrasMutationError.commandFailed
        }
    }

    private static func merge(
        _ refreshed: ProviderExtrasSnapshot,
        with previous: ProviderExtrasSnapshot?
    ) -> ProviderExtrasSnapshot {
        ProviderExtrasSnapshot(
            capturedAt: refreshed.capturedAt,
            idlePolicy: retainLastGood(
                refreshed.idlePolicy,
                previous: previous?.idlePolicy,
                reason: "Darkbloom idle policy refresh failed"
            ),
            betaFeatures: retainLastGood(
                refreshed.betaFeatures,
                previous: previous?.betaFeatures,
                reason: "Darkbloom beta feature refresh failed"
            ),
            fanStatus: retainLastGood(
                refreshed.fanStatus,
                previous: previous?.fanStatus,
                reason: "Darkbloom fan status refresh failed"
            ),
            autoUpdateStatus: mergeOptional(
                refreshed.autoUpdateStatus,
                previous: previous?.autoUpdateStatus,
                reason: "Darkbloom automatic-update status refresh failed"
            )
        )
    }

    private static func mergeOptional<Value>(
        _ refreshed: SourceAvailability<Value>?,
        previous: SourceAvailability<Value>?,
        reason: String
    ) -> SourceAvailability<Value>? where Value: Equatable & Sendable {
        guard let refreshed else {
            return stale(previous: previous, reason: reason)
        }
        return retainLastGood(refreshed, previous: previous, reason: reason)
    }

    private static func retainLastGood<Value>(
        _ refreshed: SourceAvailability<Value>,
        previous: SourceAvailability<Value>?,
        reason: String
    ) -> SourceAvailability<Value> where Value: Equatable & Sendable {
        guard case .unavailable = refreshed else { return refreshed }
        return stale(previous: previous, reason: reason) ?? refreshed
    }

    private static func stale<Value>(
        previous: SourceAvailability<Value>?,
        reason: String
    ) -> SourceAvailability<Value>? where Value: Equatable & Sendable {
        guard let previous else { return nil }
        switch previous {
        case .available(let value, let capturedAt), .stale(let value, let capturedAt, _):
            return .stale(value: value, capturedAt: capturedAt, reason: reason)
        case .unavailable:
            return nil
        }
    }
}
