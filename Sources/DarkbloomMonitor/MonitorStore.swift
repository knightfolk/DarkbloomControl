import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot: TelemetrySnapshot

    private let service: TelemetryService
    private var observationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var hasStarted = false

    init(service: TelemetryService, initial: TelemetrySnapshot) {
        self.service = service
        snapshot = initial
    }

    func start() {
        guard !hasStarted, shutdownTask == nil else { return }
        hasStarted = true

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
            let refreshed = await service.refreshNow()
            guard !Task.isCancelled, shutdownTask == nil else { return }
            snapshot = refreshed
        }
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

        let service = service
        let shutdownTask = Task {
            await service.stop()
            await observationTask?.value
            await refreshTask?.value
        }
        self.shutdownTask = shutdownTask
        await shutdownTask.value
        self.observationTask = nil
        self.refreshTask = nil
    }

    func quit() async {
        await stop()
        NSApplication.shared.terminate(nil)
    }
}
