import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Telemetry snapshot service")
struct TelemetryServiceTests {
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

    private func sample(
        tokens: Int64,
        writtenAt: TimeInterval,
        pid: Int32 = 42,
        trustStatus: String = "online"
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
            inferenceActive: true,
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
