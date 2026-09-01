import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class MonitorStore: ObservableObject {
    static let earningsPollingInterval: Duration = .seconds(600)

    @Published private(set) var snapshot: TelemetrySnapshot
    @Published private(set) var thermalState: SystemThermalState
    @Published private(set) var earnings: EarningsPresentationValue
    @Published private(set) var observedUptime: ObservedUptimeValue
    @Published private(set) var jobSummary: SourceAvailability<JobCompletionSummary>
    @Published private(set) var averageTokenRate: TokenRate

    private let service: TelemetryService
    private let earningsClient: any AccountEarningsFetching
    private let uptimeRecorder: (any ObservedUptimeRecording)?
    private var tokenRateAccumulator = ActiveTokenRateAccumulator()
    private var observationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var earningsPollingTask: Task<Void, Never>?
    private var earningsRefreshTask: Task<AccountRefreshState, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    private var hasStarted = false

    init(
        service: TelemetryService,
        initial: TelemetrySnapshot,
        earningsClient: any AccountEarningsFetching = AuthenticatedEarningsClient(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ),
        uptimeRecorder: (any ObservedUptimeRecording)? = nil
    ) {
        self.service = service
        self.earningsClient = earningsClient
        self.uptimeRecorder = uptimeRecorder
        snapshot = initial
        thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        earnings = .unavailable(reason: "Waiting for authenticated account earnings")
        observedUptime = uptimeRecorder == nil
            ? .unavailable(reason: "Local observed-uptime storage unavailable")
            : .warming(observedSeconds: 0)
        jobSummary = .unavailable(reason: "Waiting for completed-job history")
        averageTokenRate = .unavailable(reason: "Waiting for active inference samples")
    }

    func start() {
        guard !hasStarted, shutdownTask == nil else { return }
        hasStarted = true
        observeThermalState()

        earningsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEarnings()
                do {
                    try await Task.sleep(for: Self.earningsPollingInterval)
                } catch {
                    return
                }
            }
        }

        observationTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await service.snapshots()
            await service.start()

            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self.accept(snapshot)
                await self.recordObservedUptime(from: snapshot)
            }
        }
    }

    func refresh() {
        guard shutdownTask == nil, refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            async let refreshed = service.refreshNow()
            async let earningsRefresh: Void = refreshEarnings()
            let snapshot = await refreshed
            await earningsRefresh
            guard !Task.isCancelled, shutdownTask == nil else { return }
            self.accept(snapshot)
        }
    }

    func refreshEarnings() async {
        if let earningsRefreshTask {
            let refresh = await earningsRefreshTask.value
            earnings = refresh.earnings
            jobSummary = refresh.jobSummary
            return
        }

        let client = earningsClient
        let previousEarnings = earnings
        let previousJobSummary = jobSummary
        let refreshedAt = Date()
        let calendar = Calendar.current
        let task = Task<AccountRefreshState, Never> {
            let refreshedEarnings: EarningsPresentationValue
            do {
                let value = try await client.fetch(now: refreshedAt)
                switch value {
                case .available:
                    refreshedEarnings = value
                case .stale(let microUSD, let reason):
                    refreshedEarnings = .stale(microUSD: microUSD, reason: reason)
                case .unavailable(let reason):
                    refreshedEarnings = Self.staleOrUnavailable(
                        previous: previousEarnings,
                        reason: reason
                    )
                }
            } catch {
                refreshedEarnings = Self.staleOrUnavailable(
                    previous: previousEarnings,
                    reason: error.localizedDescription
                )
            }

            let refreshedJobSummary: SourceAvailability<JobCompletionSummary>
            do {
                if let summary = try await client.jobCompletionSummary(
                    now: refreshedAt,
                    calendar: calendar
                ) {
                    refreshedJobSummary = .available(value: summary, capturedAt: refreshedAt)
                } else {
                    refreshedJobSummary = Self.staleOrUnavailable(
                        previous: previousJobSummary,
                        reason: "Local completed-job history is unavailable"
                    )
                }
            } catch {
                refreshedJobSummary = Self.staleOrUnavailable(
                    previous: previousJobSummary,
                    reason: error.localizedDescription
                )
            }
            return AccountRefreshState(
                earnings: refreshedEarnings,
                jobSummary: refreshedJobSummary
            )
        }
        earningsRefreshTask = task
        let refresh = await task.value
        earnings = refresh.earnings
        jobSummary = refresh.jobSummary
        earningsRefreshTask = nil
    }

    func menuPresentation(mode: MenuBarDisplayMode) -> MenuBarPresentation {
        MenuBarPresentation.make(
            snapshot: snapshot,
            thermal: thermalState,
            earnings: earnings,
            mode: mode
        )
    }

    func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        let observationTask = observationTask
        let refreshTask = refreshTask
        observationTask?.cancel()
        refreshTask?.cancel()
        earningsPollingTask?.cancel()
        earningsRefreshTask?.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }

        let service = service
        let earningsPollingTask = earningsPollingTask
        let earningsRefreshTask = earningsRefreshTask
        let shutdownTask = Task {
            await service.stop()
            await observationTask?.value
            await refreshTask?.value
            await earningsPollingTask?.value
            _ = await earningsRefreshTask?.value
        }
        self.shutdownTask = shutdownTask
        await shutdownTask.value
        self.observationTask = nil
        self.refreshTask = nil
        self.earningsPollingTask = nil
        self.earningsRefreshTask = nil
    }

    func quit() async {
        await stop()
        NSApplication.shared.terminate(nil)
    }

    private func observeThermalState() {
        thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    private func accept(_ snapshot: TelemetrySnapshot) {
        if let state = snapshot.state.value {
            tokenRateAccumulator.record(
                snapshot.tokenRate,
                processIdentity: state.processIdentity,
                writtenAt: state.writtenAt
            )
            averageTokenRate = tokenRateAccumulator.value
        }
        self.snapshot = snapshot
    }

    private func recordObservedUptime(from snapshot: TelemetrySnapshot) async {
        guard let uptimeRecorder else { return }
        do {
            observedUptime = try await uptimeRecorder.record(
                status: snapshot.menuStatus,
                at: snapshot.capturedAt
            )
        } catch {
            observedUptime = .unavailable(reason: error.localizedDescription)
        }
    }

    private static func staleOrUnavailable(
        previous: EarningsPresentationValue,
        reason: String
    ) -> EarningsPresentationValue {
        switch previous {
        case .available(let microUSD), .stale(let microUSD, _):
            .stale(microUSD: microUSD, reason: reason)
        case .unavailable:
            .unavailable(reason: reason)
        }
    }

    private static func staleOrUnavailable(
        previous: SourceAvailability<JobCompletionSummary>,
        reason: String
    ) -> SourceAvailability<JobCompletionSummary> {
        switch previous {
        case .available(let value, let capturedAt), .stale(let value, let capturedAt, _):
            .stale(value: value, capturedAt: capturedAt, reason: reason)
        case .unavailable:
            .unavailable(reason: reason)
        }
    }
}

private struct AccountRefreshState: Sendable {
    let earnings: EarningsPresentationValue
    let jobSummary: SourceAvailability<JobCompletionSummary>
}
