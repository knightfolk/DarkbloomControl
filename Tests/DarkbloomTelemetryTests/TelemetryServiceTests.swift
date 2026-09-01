import Foundation
import Darwin
import Testing
@testable import DarkbloomTelemetry

@Suite("Telemetry snapshot service")
struct TelemetryServiceTests {
    @Test("production status acquisition completes from the main-actor launch context")
    @MainActor
    func productionStatusAcquiresFromMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-monitor-main-actor-\(UUID().uuidString)")
        let executable = root
            .appendingPathComponent(".darkbloom/bin/darkbloom")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("#!/bin/sh\nprintf 'darkbloom 0.8.15\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let source = LocalTelemetrySource(
            policy: DarkbloomSourcePolicy(homeDirectory: root, environmentPath: ""),
            runner: CappedProcessRunner()
        )
        let status = try await source.readStatus()

        #expect(status.version == "0.8.15")
    }

    @Test("successful refresh emits every source and first-sample rate gap")
    func emitsCompleteSnapshot() async throws {
        let source = ScriptedTelemetrySource.successful(
            state: sample(tokens: 10, writtenAt: 1_000)
        )
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_001) }
        )

        let snapshot = await service.refreshNow()

        #expect(snapshot.state.value?.currentModel == "model")
        #expect(snapshot.loadedModels.value?.models == ["model"])
        #expect(snapshot.status.value?.version == "0.8.15")
        #expect(snapshot.eventFeed.value?.events == [])
        #expect(snapshot.tokenRate == .unavailable(
            reason: "Waiting for a second telemetry sample"
        ))
        #expect(snapshot.menuStatus == .online)
    }

    @Test("active rate is not retained without new token telemetry")
    func doesNotRetainMeasuredRateWhileActive() async {
        let source = ScriptedTelemetrySource(states: [
            .success(sample(tokens: 100, writtenAt: 1_000)),
            .success(sample(tokens: 160, writtenAt: 1_004)),
            .success(sample(tokens: 160, writtenAt: 1_006)),
        ])
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_006) }
        )

        _ = await service.refreshNow()
        let measured = await service.refreshNow()
        let heartbeat = await service.refreshNow()

        #expect(measured.tokenRate == .available(tokensPerSecond: 15, label: "derived"))
        #expect(heartbeat.tokenRate == .unavailable(
            reason: "Waiting for completed token telemetry"
        ))
        #expect(MenuBarPresentation.make(
            snapshot: heartbeat,
            thermal: .nominal,
            earnings: .available(microUSD: 2_900_000),
            mode: .automatic
        ).metricText == "$2.90/24h")
    }

    @Test("completed work uses the full observed active window")
    func derivesCompletedWorkRate() async {
        let source = ScriptedTelemetrySource(states: [
            .success(sample(tokens: 100, writtenAt: 998, inferenceActive: false)),
            .success(sample(tokens: 100, writtenAt: 1_000)),
            .success(sample(tokens: 100, writtenAt: 1_002)),
            .success(sample(tokens: 160, writtenAt: 1_004, inferenceActive: false)),
            .success(sample(tokens: 160, writtenAt: 1_006, inferenceActive: false)),
        ])
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_006) }
        )

        _ = await service.refreshNow()
        _ = await service.refreshNow()
        _ = await service.refreshNow()
        let completed = await service.refreshNow()
        let nextIdle = await service.refreshNow()

        #expect(completed.tokenRate == .available(tokensPerSecond: 15, label: "derived"))
        #expect(MenuBarPresentation.make(
            snapshot: completed,
            thermal: .nominal,
            earnings: .available(microUSD: 0),
            mode: .automatic
        ).metricText == "15.0 tok/s")
        #expect(nextIdle.tokenRate == .unavailable(reason: "Waiting for activity"))
    }

    @Test("failed refresh preserves last good value and capture time as stale")
    func preservesLastGoodState() async throws {
        let clock = LockedNow(1_001)
        let source = ScriptedTelemetrySource(states: [
            .success(sample(tokens: 10, writtenAt: 1_000)),
            .failure(TestError.readFailed),
        ])
        let service = TelemetryService(source: source, now: clock.read)

        _ = await service.refreshNow()
        clock.set(1_100)
        let second = await service.refreshNow()

        guard case .stale(let state, let capturedAt, let reason) = second.state else {
            Issue.record("Expected stale state")
            return
        }
        #expect(state.stats.tokensGenerated == 10)
        #expect(capturedAt == Date(timeIntervalSince1970: 1_001))
        #expect(reason.contains("readFailed"))
    }

    @Test("restart discards the previous rate sample")
    func resetsRateOnRestart() async {
        let source = ScriptedTelemetrySource(states: [
            .success(sample(tokens: 100, writtenAt: 1_000, pid: 42)),
            .success(sample(tokens: 10, writtenAt: 1_004, pid: 43)),
        ])
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_005) }
        )

        _ = await service.refreshNow()
        let second = await service.refreshNow()

        #expect(second.tokenRate == .unavailable(
            reason: "Provider process changed between samples"
        ))
    }

    @Test("manual refresh never overlaps a source read")
    func preventsOverlap() async {
        let source = BlockingTelemetrySource()
        let service = TelemetryService(source: source)

        async let first = service.refreshNow()
        async let second = service.refreshNow()
        _ = await (first, second)

        #expect(await source.maximumConcurrentReads == 1)
    }

    @Test("structured and loaded freshness use embedded Darkbloom timestamps")
    func usesCanonicalFreshnessTimestamps() async {
        let source = ScriptedTelemetrySource.successful(
            state: sample(tokens: 10, writtenAt: 990),
            loadedModels: loadedModels(updatedAt: 989)
        )
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let snapshot = await service.refreshNow()

        guard case .available = snapshot.state else {
            Issue.record("Expected state exactly 10 seconds old to remain fresh")
            return
        }
        guard case .stale(_, let capturedAt, _) = snapshot.loadedModels else {
            Issue.record("Expected loaded models older than 10 seconds to be stale")
            return
        }
        #expect(capturedAt == Date(timeIntervalSince1970: 1_000))
        #expect(snapshot.menuStatus == .online)
    }

    @Test("stale structured state cannot appear fresh from local capture time")
    func doesNotRefreshOldStructuredStateLocally() async {
        let source = ScriptedTelemetrySource.successful(
            state: sample(tokens: 10, writtenAt: 989)
        )
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let snapshot = await service.refreshNow()

        guard case .stale = snapshot.state else {
            Issue.record("Expected state older than 10 seconds to be stale")
            return
        }
        #expect(snapshot.menuStatus == .stale)
    }

    @Test("status freshness uses its last successful acquisition time")
    func usesStatusAcquisitionTime() async throws {
        let clock = LockedNow(1_000)
        let source = ScriptedTelemetrySource.successful(
            state: sample(tokens: 10, writtenAt: 1_000)
        )
        let service = TelemetryService(source: source, now: clock.read)

        _ = await service.refreshNow()
        clock.set(1_061)
        await service.ingestUnifiedEvent(event(timestamp: 1_061, message: "Connected"))
        let stream = await service.snapshots()
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())

        guard case .stale(_, let capturedAt, _) = snapshot.status else {
            Issue.record("Expected status older than 60 seconds to be stale")
            return
        }
        #expect(capturedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("literal offline trust overrides freshness presentation")
    func mapsLiteralOfflineTrust() async {
        let source = ScriptedTelemetrySource.successful(
            state: sample(tokens: 10, writtenAt: 900, trustStatus: "offline")
        )
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let snapshot = await service.refreshNow()

        #expect(snapshot.menuStatus == .offline)
    }

    @Test("source failures remain independent and replace their diagnostic")
    func isolatesFailuresAndReplacesDiagnostic() async {
        let clock = LockedNow(1_000)
        let source = ScriptedTelemetrySource(states: [
            .failure(TestError.readFailed),
            .failure(TestError.readFailedAgain),
        ])
        let service = TelemetryService(source: source, now: clock.read)

        let first = await service.refreshNow()
        clock.set(1_001)
        let second = await service.refreshNow()

        #expect(first.loadedModels.value?.models == ["model"])
        #expect(first.status.value?.version == "0.8.15")
        #expect(first.diagnostics.filter { $0.id == "daemon-state" }.count == 1)
        #expect(second.diagnostics.filter { $0.id == "daemon-state" }.count == 1)
        #expect(second.diagnostics.first { $0.id == "daemon-state" }?.message.contains(
            "readFailedAgain"
        ) == true)
        #expect(second.diagnostics.first { $0.id == "daemon-state" }?.occurredAt ==
            Date(timeIntervalSince1970: 1_001))
    }

    @Test("snapshot subscribers receive current state and finish on stop")
    func streamsCurrentSnapshotAndFinishes() async throws {
        let service = TelemetryService(source: ScriptedTelemetrySource.successful())
        let stream = await service.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initial = try #require(await iterator.next())
        #expect(initial.menuStatus == .unavailable)

        await service.stop()
        #expect(await iterator.next() == nil)
    }

    @Test("stop cancels the active cycle before later source reads begin")
    func stopPreventsLaterReads() async {
        let source = CancellationTelemetrySource()
        let service = TelemetryService(source: source)
        let refresh = Task { await service.refreshNow() }

        await source.waitUntilStateReadStarts()
        await service.stop()
        _ = await refresh.value

        #expect(await source.stateWasCancelled)
        #expect(await source.loadedModelCalls == 0)
        #expect(await source.statusCalls == 0)
        #expect(await source.legacyEventCalls == 0)
    }

    @Test("slow state polling does not block loaded-model polling")
    func pollsStateAndLoadedModelsIndependently() async {
        let source = SlowStateTelemetrySource()
        let service = TelemetryService(source: source)

        await service.start()
        await source.waitUntilStateReadStarts()
        let loadedModelsStarted = await eventually {
            await source.loadedModelCalls > 0
        }
        await source.releaseStateRead()
        await service.stop()

        #expect(loadedModelsStarted)
    }

    @Test("freshness heartbeat publishes canonical timestamp transitions")
    func publishesFreshnessOnlyTransition() async {
        let clock = LockedNow(1_000)
        let source = ScriptedTelemetrySource.successful(
            state: sample(tokens: 10, writtenAt: 1_000),
            loadedModels: loadedModels(updatedAt: 1_000)
        )
        let (ticks, tickContinuation) = AsyncStream<Void>.makeStream()
        let service = TelemetryService(
            source: source,
            now: clock.read,
            testOnlyFreshnessTicks: ticks
        )

        _ = await service.refreshNow()
        await service.start()
        let pollersReady = await eventually {
            let stateCalls = await source.stateCalls
            let loadedModelCalls = await source.loadedModelCalls
            let statusCalls = await source.statusCalls
            let legacyEventCalls = await source.legacyEventCalls
            return stateCalls >= 2 && loadedModelCalls >= 2
                && statusCalls >= 2 && legacyEventCalls >= 2
        }
        let stream = await service.snapshots()
        clock.set(1_011)
        tickContinuation.yield()
        let staleSnapshot = await firstSnapshot(in: stream) { snapshot in
            guard case .stale = snapshot.state,
                  case .stale = snapshot.loadedModels else { return false }
            return snapshot.menuStatus == .stale
        }
        await service.stop()

        #expect(pollersReady)
        #expect(staleSnapshot != nil)
        if case .stale(_, let capturedAt, _) = staleSnapshot?.state {
            #expect(capturedAt == Date(timeIntervalSince1970: 1_000))
        } else {
            Issue.record("Expected stale state with its successful acquisition time")
        }
    }

    @Test("normal unified-stream EOF publishes a stable termination diagnostic")
    func reportsUnifiedStreamEOF() async {
        let unifiedEvent = event(timestamp: 1_000, message: "Connected")
        let unifiedEvents = AsyncThrowingStream<LogEvent, Error> { continuation in
            continuation.yield(unifiedEvent)
            continuation.finish()
        }
        let service = TelemetryService(
            source: ScriptedTelemetrySource.successful(),
            now: { Date(timeIntervalSince1970: 1_000) },
            unifiedEvents: unifiedEvents
        )
        let stream = await service.snapshots()

        await service.start()
        let endedSnapshot = await firstSnapshot(in: stream) { snapshot in
            snapshot.diagnostics.contains {
                $0.id == "unified-events"
                    && $0.message == "Unified log stream ended unexpectedly"
            }
        }
        await service.stop()

        #expect(endedSnapshot?.eventFeed.value?.events.map(\.message) == ["Connected"])
        guard case .stale(_, let capturedAt, let reason) = endedSnapshot?.eventFeed else {
            Issue.record("Expected the last unified event feed to become stale")
            return
        }
        #expect(capturedAt == Date(timeIntervalSince1970: 1_000))
        #expect(reason.contains("Unified log stream ended unexpectedly"))
    }

    @Test("stop waits for unified iterator cleanup acknowledgment")
    func stopWaitsForUnifiedIteratorCleanup() async {
        let probe = BlockingUnifiedIterator()
        let unifiedEvents = AsyncThrowingStream<LogEvent, Error>(unfolding: {
            try await probe.next()
        })
        let service = TelemetryService(
            source: ScriptedTelemetrySource.successful(),
            unifiedEvents: unifiedEvents
        )
        let stopReturned = LockedFlag()

        await service.start()
        await probe.waitUntilStarted()
        let stopTask = Task {
            await service.stop()
            stopReturned.set()
        }
        await probe.waitUntilCancelled()

        let returnedBeforeCleanup = await eventually {
            stopReturned.read()
        }
        #expect(!returnedBeforeCleanup)

        await probe.releaseCleanup()
        await stopTask.value
        #expect(stopReturned.read())
    }

    @Test("stop awaits finite acquisition cleanup and coalesces concurrent callers")
    func stopAwaitsFiniteAcquisitionCleanup() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-monitor-service-\(UUID().uuidString).pid")
        try Data().write(to: pidFile)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let source = ResistantStatusTelemetrySource(pidFile: pidFile)
        let service = TelemetryService(source: source)
        await service.start()
        await source.waitUntilStatusStarts()
        guard let pid = await waitForPID(at: pidFile) else {
            Issue.record("The finite status child did not publish its PID")
            await service.stop()
            return
        }

        let firstReturned = LockedFlag()
        let secondReturned = LockedFlag()
        let firstStop = Task {
            await service.stop()
            firstReturned.set()
        }
        await Task.yield()
        let secondStop = Task {
            await service.stop()
            secondReturned.set()
        }

        let firstReturnedWhileActive = await eventually(timeout: .milliseconds(500)) {
            guard firstReturned.read() else { return false }
            return !(await source.statusFinished)
        }
        let secondReturnedWhileActive = await eventually(timeout: .milliseconds(500)) {
            guard secondReturned.read() else { return false }
            return !(await source.statusFinished)
        }

        if processExists(pid), !(await source.statusFinished) {
            kill(pid, SIGKILL)
        }
        await firstStop.value
        await secondStop.value
        await service.stop()
        await service.stop()

        #expect(!firstReturnedWhileActive)
        #expect(!secondReturnedWhileActive)
        #expect(await source.statusFinished)
        #expect(!processExists(pid))
    }

    @Test("stop awaits a finite manual refresh cleanup")
    func stopAwaitsManualFiniteAcquisitionCleanup() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-monitor-manual-service-\(UUID().uuidString).pid")
        try Data().write(to: pidFile)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let source = ResistantStatusTelemetrySource(pidFile: pidFile)
        let service = TelemetryService(source: source)
        let refreshTask = Task { await service.refreshNow() }
        await source.waitUntilStatusStarts()
        guard let pid = await waitForPID(at: pidFile) else {
            Issue.record("The finite manual-refresh child did not publish its PID")
            await service.stop()
            _ = await refreshTask.value
            return
        }

        let stopReturned = LockedFlag()
        let stopTask = Task {
            await service.stop()
            stopReturned.set()
        }
        let returnedWhileActive = await eventually(timeout: .milliseconds(500)) {
            guard stopReturned.read() else { return false }
            return !(await source.statusFinished)
        }

        if processExists(pid), !(await source.statusFinished) {
            kill(pid, SIGKILL)
        }
        await stopTask.value
        _ = await refreshTask.value

        #expect(!returnedWhileActive)
        #expect(await source.statusFinished)
        #expect(!processExists(pid))
    }

    private func sample(
        tokens: Int64,
        writtenAt: TimeInterval,
        pid: Int32 = 42,
        trustStatus: String = "online",
        inferenceActive: Bool = true
    ) -> DaemonState {
        DaemonState(
            schema: 1,
            version: "0.8.15",
            currentModel: "model",
            warmModels: ["model"],
            stats: .init(tokensGenerated: tokens, requestsServed: 1, usageGaps: 0),
            trust: .init(
                level: "hardware",
                status: trustStatus,
                reason: "same_binary",
                receivedAt: writtenAt
            ),
            capacity: .init(
                totalMemoryGB: 64,
                gpuMemoryActiveGB: 10,
                gpuMemoryCacheGB: 1
            ),
            slots: [],
            inferenceActive: inferenceActive,
            startedAt: writtenAt - 100,
            writtenAt: writtenAt,
            pid: pid,
            processIdentity: .init(
                pid: pid,
                startTimeMicros: Int64(pid) * 1_000_000
            )
        )
    }

    private func loadedModels(updatedAt: TimeInterval) -> LoadedModelsState {
        .init(schema: 1, models: ["model"], updatedAt: updatedAt)
    }

    private func event(timestamp: TimeInterval, message: String) -> LogEvent {
        .init(
            timestamp: Date(timeIntervalSince1970: timestamp),
            severity: .info,
            category: "coordinator",
            message: message,
            source: .unified,
            processID: 42,
            processImage: "darkbloom"
        )
    }

    private func waitForPID(at url: URL) async -> Int32? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if let value = try? String(contentsOf: url),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func processExists(_ pid: Int32) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}

private enum TestError: Error, Sendable {
    case readFailed
    case readFailedAgain
}

private actor ScriptedTelemetrySource: TelemetrySource {
    private var states: [Result<DaemonState, TestError>]
    private var loadedModelResults: [Result<LoadedModelsState, TestError>]
    private var statuses: [Result<StatusSnapshot, TestError>]
    private var legacyEvents: [Result<[LogEvent], TestError>]

    private(set) var stateCalls = 0
    private(set) var loadedModelCalls = 0
    private(set) var statusCalls = 0
    private(set) var legacyEventCalls = 0

    init(
        states: [Result<DaemonState, TestError>] = [],
        loadedModels: [Result<LoadedModelsState, TestError>] = [],
        statuses: [Result<StatusSnapshot, TestError>] = [],
        legacyEvents: [Result<[LogEvent], TestError>] = []
    ) {
        self.states = states.isEmpty ? Self.repeated(.success(Self.defaultState)) : states
        loadedModelResults = loadedModels.isEmpty
            ? Self.repeated(.success(Self.defaultLoadedModels))
            : loadedModels
        self.statuses = statuses.isEmpty
            ? Self.repeated(.success(Self.defaultStatus))
            : statuses
        self.legacyEvents = legacyEvents.isEmpty ? Self.repeated(.success([])) : legacyEvents
    }

    static func successful(
        state: DaemonState = defaultState,
        loadedModels: LoadedModelsState = defaultLoadedModels
    ) -> ScriptedTelemetrySource {
        ScriptedTelemetrySource(
            states: repeated(.success(state)),
            loadedModels: repeated(.success(loadedModels)),
            statuses: repeated(.success(defaultStatus)),
            legacyEvents: repeated(.success([]))
        )
    }

    func readDaemonState() async throws -> DaemonState {
        stateCalls += 1
        return try states.removeFirst().get()
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        loadedModelCalls += 1
        return try loadedModelResults.removeFirst().get()
    }

    func readStatus() async throws -> StatusSnapshot {
        statusCalls += 1
        return try statuses.removeFirst().get()
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] {
        legacyEventCalls += 1
        return Array(try legacyEvents.removeFirst().get().prefix(limit))
    }

    private static func repeated<Value>(_ result: Result<Value, TestError>) -> [Result<Value, TestError>] {
        Array(repeating: result, count: 20)
    }

    private static let defaultState = DaemonState(
        schema: 1,
        version: "0.8.15",
        currentModel: "model",
        warmModels: ["model"],
        stats: .init(tokensGenerated: 10, requestsServed: 1, usageGaps: 0),
        trust: .init(
            level: "hardware",
            status: "online",
            reason: "same_binary",
            receivedAt: 1_000
        ),
        capacity: .init(totalMemoryGB: 64, gpuMemoryActiveGB: 10, gpuMemoryCacheGB: 1),
        slots: [],
        inferenceActive: true,
        startedAt: 900,
        writtenAt: 1_000,
        pid: 42,
        processIdentity: .init(pid: 42, startTimeMicros: 42_000_000)
    )

    private static let defaultLoadedModels = LoadedModelsState(
        schema: 1,
        models: ["model"],
        updatedAt: 1_000
    )

    private static var defaultStatus: StatusSnapshot {
        var status = StatusSnapshot()
        status.version = "0.8.15"
        return status
    }
}

private actor BlockingTelemetrySource: TelemetrySource {
    private var concurrentReads = 0
    private(set) var maximumConcurrentReads = 0

    func readDaemonState() async throws -> DaemonState {
        await block()
        return ScriptedTelemetrySource.defaultStateForBlocking
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        await block()
        return .init(schema: 1, models: ["model"], updatedAt: Date().timeIntervalSince1970)
    }

    func readStatus() async throws -> StatusSnapshot {
        await block()
        var status = StatusSnapshot()
        status.version = "0.8.15"
        return status
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] {
        await block()
        return []
    }

    private func block() async {
        concurrentReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, concurrentReads)
        try? await Task.sleep(for: .milliseconds(20))
        concurrentReads -= 1
    }
}

private actor CancellationTelemetrySource: TelemetrySource {
    private var stateStarted = false
    private var stateStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stateWasCancelled = false
    private(set) var loadedModelCalls = 0
    private(set) var statusCalls = 0
    private(set) var legacyEventCalls = 0

    func readDaemonState() async throws -> DaemonState {
        stateStarted = true
        let waiters = stateStartWaiters
        stateStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        do {
            try await Task.sleep(for: .seconds(30))
            return ScriptedTelemetrySource.defaultStateForBlocking
        } catch {
            stateWasCancelled = true
            throw error
        }
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        loadedModelCalls += 1
        return .init(schema: 1, models: ["model"], updatedAt: 1_000)
    }

    func readStatus() async throws -> StatusSnapshot {
        statusCalls += 1
        return StatusSnapshot()
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] {
        legacyEventCalls += 1
        return []
    }

    func waitUntilStateReadStarts() async {
        guard !stateStarted else { return }
        await withCheckedContinuation { continuation in
            stateStartWaiters.append(continuation)
        }
    }
}

private actor SlowStateTelemetrySource: TelemetrySource {
    private var stateStarted = false
    private var stateStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var stateReleased = false
    private var stateReleaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var loadedModelCalls = 0

    func readDaemonState() async throws -> DaemonState {
        stateStarted = true
        let waiters = stateStartWaiters
        stateStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !stateReleased {
            await withCheckedContinuation { continuation in
                stateReleaseWaiter = continuation
            }
        }
        return ScriptedTelemetrySource.defaultStateForBlocking
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        loadedModelCalls += 1
        return .init(schema: 1, models: ["model"], updatedAt: Date().timeIntervalSince1970)
    }

    func readStatus() async throws -> StatusSnapshot {
        StatusSnapshot()
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] {
        []
    }

    func waitUntilStateReadStarts() async {
        guard !stateStarted else { return }
        await withCheckedContinuation { continuation in
            stateStartWaiters.append(continuation)
        }
    }

    func releaseStateRead() {
        stateReleased = true
        stateReleaseWaiter?.resume()
        stateReleaseWaiter = nil
    }
}

private extension ScriptedTelemetrySource {
    static var defaultStateForBlocking: DaemonState {
        defaultState
    }
}

private final class LockedNow: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval

    init(_ seconds: TimeInterval) {
        self.seconds = seconds
    }

    func read() -> Date {
        lock.withLock { Date(timeIntervalSince1970: seconds) }
    }

    func set(_ seconds: TimeInterval) {
        lock.withLock { self.seconds = seconds }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func read() -> Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

private actor BlockingUnifiedIterator {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupReleased = false
    private var nextContinuation: CheckedContinuation<LogEvent?, Error>?

    func next() async throws -> LogEvent? {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nextContinuation = continuation
                finishCancellationIfReady()
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancelledWaiters.append(continuation)
        }
    }

    func releaseCleanup() {
        cleanupReleased = true
        finishCancellationIfReady()
    }

    private func recordCancellation() {
        cancelled = true
        let waiters = cancelledWaiters
        cancelledWaiters.removeAll()
        waiters.forEach { $0.resume() }
        finishCancellationIfReady()
    }

    private func finishCancellationIfReady() {
        guard cancelled, cleanupReleased, let continuation = nextContinuation else { return }
        nextContinuation = nil
        continuation.resume(throwing: CancellationError())
    }
}

private actor ResistantStatusTelemetrySource: TelemetrySource {
    private let pidFile: URL
    private let runner = CappedProcessRunner()
    private var statusStarted = false
    private var statusStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var statusFinished = false

    init(pidFile: URL) {
        self.pidFile = pidFile
    }

    func readDaemonState() async throws -> DaemonState {
        ScriptedTelemetrySource.defaultStateForBlocking
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        .init(schema: 1, models: ["model"], updatedAt: Date().timeIntervalSince1970)
    }

    func readStatus() async throws -> StatusSnapshot {
        statusStarted = true
        let waiters = statusStartWaiters
        statusStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        defer { statusFinished = true }

        _ = try await runner.run(
            .testOnly(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '%s' \"$$\" > \"$1\"; trap '' TERM; while :; do :; done",
                    "sh",
                    pidFile.path,
                ]
            ),
            timeout: .seconds(30),
            outputLimit: 256
        )
        return StatusSnapshot()
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] {
        []
    }

    func waitUntilStatusStarts() async {
        guard !statusStarted else { return }
        await withCheckedContinuation { continuation in
            statusStartWaiters.append(continuation)
        }
    }
}

private func eventually(
    timeout: Duration = .milliseconds(100),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

private func firstSnapshot(
    in stream: AsyncStream<TelemetrySnapshot>,
    timeout: Duration = .milliseconds(100),
    matching predicate: @escaping @Sendable (TelemetrySnapshot) -> Bool
) async -> TelemetrySnapshot? {
    await withTaskGroup(of: TelemetrySnapshot?.self) { group in
        group.addTask {
            for await snapshot in stream where predicate(snapshot) {
                return snapshot
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
