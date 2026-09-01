import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class MonitorStore: ObservableObject {
    static let earningsPollingInterval: Duration = .seconds(600)

    @Published private(set) var snapshot: TelemetrySnapshot
    @Published private(set) var thermalState: SystemThermalState
    @Published private(set) var earnings: EarningsPresentationValue

    private let service: TelemetryService
    private let earningsClient: any AccountEarningsFetching
    private var observationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var earningsPollingTask: Task<Void, Never>?
    private var earningsRefreshTask: Task<EarningsPresentationValue, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    private var hasStarted = false

    init(
        service: TelemetryService,
        initial: TelemetrySnapshot,
        earningsClient: any AccountEarningsFetching = AuthenticatedEarningsClient(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    ) {
        self.service = service
        self.earningsClient = earningsClient
        snapshot = initial
        thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        earnings = .unavailable(reason: "Waiting for authenticated account earnings")
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
                self.snapshot = snapshot
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
            self.snapshot = snapshot
        }
    }

    func refreshEarnings() async {
        if let earningsRefreshTask {
            earnings = await earningsRefreshTask.value
            return
        }

        let client = earningsClient
        let previous = earnings
        let task = Task<EarningsPresentationValue, Never> {
            do {
                let value = try await client.fetch(now: Date())
                switch value {
                case .available:
                    return value
                case .stale(let microUSD, let reason):
                    return .stale(microUSD: microUSD, reason: reason)
                case .unavailable(let reason):
                    return Self.staleOrUnavailable(previous: previous, reason: reason)
                }
            } catch {
                return Self.staleOrUnavailable(
                    previous: previous,
                    reason: error.localizedDescription
                )
            }
        }
        earningsRefreshTask = task
        earnings = await task.value
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
}
