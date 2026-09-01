import Foundation

public actor TelemetryService {
    private struct LastGood<Value: Equatable & Sendable>: Sendable {
        let value: Value
        let capturedAt: Date
    }

    private enum AcquisitionResult<Value: Equatable & Sendable>: Sendable {
        case success(Value, capturedAt: Date)
        case failure(reason: String, occurredAt: Date)
        case cancelled
    }

    private enum SourceFreshness: Equatable, Sendable {
        case available
        case stale(reason: String)
        case unavailable(reason: String)
    }

    private struct FreshnessSignature: Equatable, Sendable {
        let state: SourceFreshness
        let loadedModels: SourceFreshness
        let status: SourceFreshness
        let menuStatus: MenuPresentationStatus
    }

    private let source: any TelemetrySource
    private let now: @Sendable () -> Date
    private let unifiedEvents: AsyncThrowingStream<LogEvent, Error>?
    private let freshnessTicks: AsyncStream<Void>?

    private var lastState: LastGood<DaemonState>?
    private var lastLoadedModels: LastGood<LoadedModelsState>?
    private var lastStatus: LastGood<StatusSnapshot>?
    private var stateFailureReason: String?
    private var loadedModelsFailureReason: String?
    private var statusFailureReason: String?

    private var eventBuffer = EventBuffer(capacity: 100)
    private var legacyReadAt: Date?
    private var unifiedActivityAt: Date?
    private var legacyFailureReason: String?
    private var unifiedFailureReason: String?

    private var previousStateSample: DaemonState?
    private var tokenRate: TokenRate = .unavailable(
        reason: "Waiting for a second telemetry sample"
    )
    private var diagnosticsByID: [String: AcquisitionDiagnostic] = [:]
    private var continuations: [UUID: AsyncStream<TelemetrySnapshot>.Continuation] = [:]
    private var lastPublishedFreshness: FreshnessSignature?

    private var activeRefreshTask: Task<TelemetrySnapshot, Never>?
    private var stateRefreshTask: Task<Void, Never>?
    private var loadedModelsRefreshTask: Task<Void, Never>?
    private var statusRefreshTask: Task<Void, Never>?
    private var legacyRefreshTask: Task<Void, Never>?
    private var statePollingTask: Task<Void, Never>?
    private var loadedModelsPollingTask: Task<Void, Never>?
    private var legacyPollingTask: Task<Void, Never>?
    private var statusPollingTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var unifiedEventsTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(
        source: any TelemetrySource,
        now: @escaping @Sendable () -> Date = { Date() },
        unifiedEvents: AsyncThrowingStream<LogEvent, Error>? = nil
    ) {
        self.source = source
        self.now = now
        self.unifiedEvents = unifiedEvents
        freshnessTicks = nil
    }

    init(
        source: any TelemetrySource,
        now: @escaping @Sendable () -> Date,
        unifiedEvents: AsyncThrowingStream<LogEvent, Error>? = nil,
        testOnlyFreshnessTicks: AsyncStream<Void>
    ) {
        self.source = source
        self.now = now
        self.unifiedEvents = unifiedEvents
        freshnessTicks = testOnlyFreshnessTicks
    }

    public func snapshots() -> AsyncStream<TelemetrySnapshot> {
        let (stream, continuation) = AsyncStream<TelemetrySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(makeSnapshot(at: now()))

        guard !stopped else {
            continuation.finish()
            return stream
        }

        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        return stream
    }

    public func start() {
        guard !started, !stopped else { return }
        started = true

        statePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshState()
                do {
                    try await Task.sleep(for: DarkbloomSourcePolicy.stateInterval)
                } catch {
                    return
                }
            }
        }
        loadedModelsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLoadedModels()
                do {
                    try await Task.sleep(for: DarkbloomSourcePolicy.stateInterval)
                } catch {
                    return
                }
            }
        }
        legacyPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLegacyEvents()
                do {
                    try await Task.sleep(for: DarkbloomSourcePolicy.logInterval)
                } catch {
                    return
                }
            }
        }
        statusPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                do {
                    try await Task.sleep(for: DarkbloomSourcePolicy.statusInterval)
                } catch {
                    return
                }
            }
        }

        if let freshnessTicks {
            freshnessTask = Task { [weak self] in
                for await _ in freshnessTicks {
                    guard !Task.isCancelled else { return }
                    await self?.publishFreshnessTransitionIfChanged()
                }
            }
        } else {
            freshnessTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    await self?.publishFreshnessTransitionIfChanged()
                }
            }
        }

        if let unifiedEvents {
            unifiedEventsTask = Task { [weak self] in
                do {
                    for try await event in unifiedEvents {
                        try Task.checkCancellation()
                        await self?.ingestUnifiedEvent(event)
                    }
                    await self?.unifiedStreamEnded()
                } catch is CancellationError {
                    await self?.unifiedStreamCancelled()
                } catch {
                    await self?.unifiedStreamFailed(String(describing: error))
                }
            }
        }
    }

    @discardableResult
    public func refreshNow() async -> TelemetrySnapshot {
        guard !stopped else { return makeSnapshot(at: now()) }
        if let activeRefreshTask {
            return await activeRefreshTask.value
        }

        let fallback = makeSnapshot(at: now())
        let task = Task { [weak self] in
            guard let self else { return fallback }
            return await self.performManualRefresh()
        }
        activeRefreshTask = task
        return await task.value
    }

    public func ingestUnifiedEvent(_ event: LogEvent) {
        guard !stopped else { return }
        eventBuffer.insert([event])
        unifiedActivityAt = now()
        unifiedFailureReason = nil
        diagnosticsByID.removeValue(forKey: DiagnosticID.unifiedEvents)
        publishSnapshot()
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        started = false

        statePollingTask?.cancel()
        loadedModelsPollingTask?.cancel()
        legacyPollingTask?.cancel()
        statusPollingTask?.cancel()
        freshnessTask?.cancel()
        unifiedEventsTask?.cancel()
        activeRefreshTask?.cancel()
        stateRefreshTask?.cancel()
        loadedModelsRefreshTask?.cancel()
        statusRefreshTask?.cancel()
        legacyRefreshTask?.cancel()

        statePollingTask = nil
        loadedModelsPollingTask = nil
        legacyPollingTask = nil
        statusPollingTask = nil
        freshnessTask = nil
        unifiedEventsTask = nil
        activeRefreshTask = nil

        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func performManualRefresh() async -> TelemetrySnapshot {
        await refreshState()
        guard !stopped, !Task.isCancelled else { return finishManualRefresh() }
        await refreshLoadedModels()
        guard !stopped, !Task.isCancelled else { return finishManualRefresh() }
        await refreshStatus()
        guard !stopped, !Task.isCancelled else { return finishManualRefresh() }
        await refreshLegacyEvents()
        return finishManualRefresh()
    }

    private func finishManualRefresh() -> TelemetrySnapshot {
        let snapshot = makeSnapshot(at: now())
        activeRefreshTask = nil
        return snapshot
    }

    private func refreshState() async {
        guard !stopped, !Task.isCancelled else { return }
        if let stateRefreshTask {
            await stateRefreshTask.value
            return
        }

        let source = source
        let now = now
        let task = Task { [weak self] in
            let result: AcquisitionResult<DaemonState>
            do {
                let value = try await source.readDaemonState()
                result = .success(value, capturedAt: now())
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failure(reason: String(describing: error), occurredAt: now())
            }
            await self?.completeStateRefresh(result)
        }
        stateRefreshTask = task
        await task.value
    }

    private func refreshLoadedModels() async {
        guard !stopped, !Task.isCancelled else { return }
        if let loadedModelsRefreshTask {
            await loadedModelsRefreshTask.value
            return
        }

        let source = source
        let now = now
        let task = Task { [weak self] in
            let result: AcquisitionResult<LoadedModelsState>
            do {
                let value = try await source.readLoadedModels()
                result = .success(value, capturedAt: now())
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failure(reason: String(describing: error), occurredAt: now())
            }
            await self?.completeLoadedModelsRefresh(result)
        }
        loadedModelsRefreshTask = task
        await task.value
    }

    private func refreshStatus() async {
        guard !stopped, !Task.isCancelled else { return }
        if let statusRefreshTask {
            await statusRefreshTask.value
            return
        }

        let source = source
        let now = now
        let task = Task { [weak self] in
            let result: AcquisitionResult<StatusSnapshot>
            do {
                let value = try await source.readStatus()
                result = .success(value, capturedAt: now())
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failure(reason: String(describing: error), occurredAt: now())
            }
            await self?.completeStatusRefresh(result)
        }
        statusRefreshTask = task
        await task.value
    }

    private func refreshLegacyEvents() async {
        guard !stopped, !Task.isCancelled else { return }
        if let legacyRefreshTask {
            await legacyRefreshTask.value
            return
        }

        let source = source
        let now = now
        let task = Task { [weak self] in
            let result: AcquisitionResult<[LogEvent]>
            do {
                let value = try await source.readLegacyEvents(limit: 100)
                result = .success(value, capturedAt: now())
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failure(reason: String(describing: error), occurredAt: now())
            }
            await self?.completeLegacyRefresh(result)
        }
        legacyRefreshTask = task
        await task.value
    }

    private func completeStateRefresh(_ result: AcquisitionResult<DaemonState>) {
        stateRefreshTask = nil
        guard !stopped else { return }

        switch result {
        case .success(let state, let capturedAt):
            tokenRate = TelemetryDeriver.tokenRate(
                previous: previousStateSample,
                current: state
            )
            previousStateSample = state
            lastState = LastGood(value: state, capturedAt: capturedAt)
            stateFailureReason = nil
            diagnosticsByID.removeValue(forKey: DiagnosticID.daemonState)
        case .failure(let reason, let occurredAt):
            stateFailureReason = reason
            recordDiagnostic(
                id: DiagnosticID.daemonState,
                source: "daemon-state.json",
                message: reason,
                occurredAt: occurredAt
            )
        case .cancelled:
            return
        }
        publishSnapshot()
    }

    private func completeLoadedModelsRefresh(
        _ result: AcquisitionResult<LoadedModelsState>
    ) {
        loadedModelsRefreshTask = nil
        guard !stopped else { return }

        switch result {
        case .success(let loadedModels, let capturedAt):
            lastLoadedModels = LastGood(value: loadedModels, capturedAt: capturedAt)
            loadedModelsFailureReason = nil
            diagnosticsByID.removeValue(forKey: DiagnosticID.loadedModels)
        case .failure(let reason, let occurredAt):
            loadedModelsFailureReason = reason
            recordDiagnostic(
                id: DiagnosticID.loadedModels,
                source: "loaded-models.json",
                message: reason,
                occurredAt: occurredAt
            )
        case .cancelled:
            return
        }
        publishSnapshot()
    }

    private func completeStatusRefresh(_ result: AcquisitionResult<StatusSnapshot>) {
        statusRefreshTask = nil
        guard !stopped else { return }

        switch result {
        case .success(let status, let capturedAt):
            lastStatus = LastGood(value: status, capturedAt: capturedAt)
            statusFailureReason = nil
            diagnosticsByID.removeValue(forKey: DiagnosticID.status)
        case .failure(let reason, let occurredAt):
            statusFailureReason = reason
            recordDiagnostic(
                id: DiagnosticID.status,
                source: "darkbloom status",
                message: reason,
                occurredAt: occurredAt
            )
        case .cancelled:
            return
        }
        publishSnapshot()
    }

    private func completeLegacyRefresh(_ result: AcquisitionResult<[LogEvent]>) {
        legacyRefreshTask = nil
        guard !stopped else { return }

        switch result {
        case .success(let events, let capturedAt):
            eventBuffer.insert(events)
            legacyReadAt = capturedAt
            legacyFailureReason = nil
            diagnosticsByID.removeValue(forKey: DiagnosticID.legacyEvents)
        case .failure(let reason, let occurredAt):
            legacyFailureReason = reason
            recordDiagnostic(
                id: DiagnosticID.legacyEvents,
                source: "provider.log",
                message: reason,
                occurredAt: occurredAt
            )
        case .cancelled:
            return
        }
        publishSnapshot()
    }

    private func unifiedStreamEnded() {
        unifiedEventsTask = nil
        guard started, !stopped else { return }
        let reason = "Unified log stream ended unexpectedly"
        unifiedFailureReason = reason
        recordDiagnostic(
            id: DiagnosticID.unifiedEvents,
            source: "unified log",
            message: reason,
            occurredAt: now()
        )
        publishSnapshot()
    }

    private func unifiedStreamCancelled() {
        unifiedEventsTask = nil
    }

    private func unifiedStreamFailed(_ reason: String) {
        unifiedEventsTask = nil
        guard !stopped else { return }
        unifiedFailureReason = reason
        let occurredAt = now()
        recordDiagnostic(
            id: DiagnosticID.unifiedEvents,
            source: "unified log",
            message: reason,
            occurredAt: occurredAt
        )
        publishSnapshot()
    }

    private func recordDiagnostic(
        id: String,
        source: String,
        message: String,
        occurredAt: Date
    ) {
        diagnosticsByID[id] = AcquisitionDiagnostic(
            id: id,
            source: source,
            message: message,
            occurredAt: occurredAt
        )
    }

    private func publishSnapshot() {
        guard !stopped else { return }
        let snapshot = makeSnapshot(at: now())
        lastPublishedFreshness = freshnessSignature(for: snapshot)
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func publishFreshnessTransitionIfChanged() {
        guard !stopped else { return }
        let snapshot = makeSnapshot(at: now())
        let freshness = freshnessSignature(for: snapshot)
        guard freshness != lastPublishedFreshness else { return }
        lastPublishedFreshness = freshness
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func freshnessSignature(for snapshot: TelemetrySnapshot) -> FreshnessSignature {
        FreshnessSignature(
            state: sourceFreshness(snapshot.state),
            loadedModels: sourceFreshness(snapshot.loadedModels),
            status: sourceFreshness(snapshot.status),
            menuStatus: snapshot.menuStatus
        )
    }

    private func sourceFreshness<Value>(
        _ availability: SourceAvailability<Value>
    ) -> SourceFreshness where Value: Equatable & Sendable {
        switch availability {
        case .available:
            .available
        case .stale(_, _, let reason):
            .stale(reason: reason)
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }

    private func makeSnapshot(at capturedAt: Date) -> TelemetrySnapshot {
        let state = stateAvailability(at: capturedAt)
        return TelemetrySnapshot(
            state: state,
            loadedModels: loadedModelsAvailability(at: capturedAt),
            status: statusAvailability(at: capturedAt),
            eventFeed: eventFeedAvailability(),
            tokenRate: tokenRate,
            diagnostics: diagnosticsByID.values.sorted { $0.id < $1.id },
            capturedAt: capturedAt,
            menuStatus: MenuPresentationStatus.derive(state: state, now: capturedAt)
        )
    }

    private func stateAvailability(at now: Date) -> SourceAvailability<DaemonState> {
        guard let lastState else {
            return .unavailable(reason: stateFailureReason ?? "Daemon state has not been read")
        }
        if let stateFailureReason {
            return .stale(
                value: lastState.value,
                capturedAt: lastState.capturedAt,
                reason: stateFailureReason
            )
        }

        let age = now.timeIntervalSince1970 - lastState.value.writtenAt
        if age < 0 {
            return .stale(
                value: lastState.value,
                capturedAt: lastState.capturedAt,
                reason: "State write time is in the future"
            )
        }
        if age > 10 {
            return .stale(
                value: lastState.value,
                capturedAt: lastState.capturedAt,
                reason: "State is older than 10 seconds"
            )
        }
        return .available(value: lastState.value, capturedAt: lastState.capturedAt)
    }

    private func loadedModelsAvailability(
        at now: Date
    ) -> SourceAvailability<LoadedModelsState> {
        guard let lastLoadedModels else {
            return .unavailable(
                reason: loadedModelsFailureReason ?? "Loaded models have not been read"
            )
        }
        if let loadedModelsFailureReason {
            return .stale(
                value: lastLoadedModels.value,
                capturedAt: lastLoadedModels.capturedAt,
                reason: loadedModelsFailureReason
            )
        }

        let age = now.timeIntervalSince1970 - lastLoadedModels.value.updatedAt
        if age < 0 {
            return .stale(
                value: lastLoadedModels.value,
                capturedAt: lastLoadedModels.capturedAt,
                reason: "Loaded-model update time is in the future"
            )
        }
        if age > 10 {
            return .stale(
                value: lastLoadedModels.value,
                capturedAt: lastLoadedModels.capturedAt,
                reason: "Loaded models are older than 10 seconds"
            )
        }
        return .available(
            value: lastLoadedModels.value,
            capturedAt: lastLoadedModels.capturedAt
        )
    }

    private func statusAvailability(at now: Date) -> SourceAvailability<StatusSnapshot> {
        guard let lastStatus else {
            return .unavailable(reason: statusFailureReason ?? "Status has not been read")
        }
        if let statusFailureReason {
            return .stale(
                value: lastStatus.value,
                capturedAt: lastStatus.capturedAt,
                reason: statusFailureReason
            )
        }

        let age = now.timeIntervalSince(lastStatus.capturedAt)
        if age < 0 {
            return .stale(
                value: lastStatus.value,
                capturedAt: lastStatus.capturedAt,
                reason: "Status acquisition time is in the future"
            )
        }
        if age > 60 {
            return .stale(
                value: lastStatus.value,
                capturedAt: lastStatus.capturedAt,
                reason: "Status is older than 60 seconds"
            )
        }
        return .available(value: lastStatus.value, capturedAt: lastStatus.capturedAt)
    }

    private func eventFeedAvailability() -> SourceAvailability<EventFeed> {
        let feed = EventFeed(
            events: eventBuffer.events,
            legacyReadAt: legacyReadAt,
            unifiedActivityAt: unifiedActivityAt
        )
        let lastSuccess = [legacyReadAt, unifiedActivityAt].compactMap { $0 }.max()
        let failures = [
            legacyFailureReason.map { "Legacy events: \($0)" },
            unifiedFailureReason.map { "Unified events: \($0)" },
        ].compactMap { $0 }

        guard let lastSuccess else {
            return .unavailable(
                reason: failures.joined(separator: "; ").nilIfEmpty
                    ?? "Events have not been read"
            )
        }
        if !failures.isEmpty {
            return .stale(
                value: feed,
                capturedAt: lastSuccess,
                reason: failures.joined(separator: "; ")
            )
        }
        return .available(value: feed, capturedAt: lastSuccess)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

private enum DiagnosticID {
    static let daemonState = "daemon-state"
    static let loadedModels = "loaded-models"
    static let status = "status"
    static let legacyEvents = "legacy-events"
    static let unifiedEvents = "unified-events"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
