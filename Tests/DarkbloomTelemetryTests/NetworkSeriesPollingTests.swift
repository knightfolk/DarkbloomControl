import Foundation
import Testing

@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Network history polling lifecycle", .serialized)
@MainActor
struct NetworkSeriesPollingTests {
  @Test("close cancels the timer, reopen retains backoff and stop joins pending sleep")
  func lifecycle() async throws {
    let clock = SeriesTestClock()
    let sleeper = SeriesTestSleeper()
    let client = PollingSeriesClient()
    let store = MonitorStore(
      service: TelemetryService(source: PollingUnusedSource()),
      initial: .unavailable(now: clock.now()),
      earningsClient: PollingUnusedEarnings(), networkSeriesClient: client,
      now: { clock.now() }, publicPollingSleep: { try await sleeper.sleep($0) },
      publicPollingJitter: { 0.2 }
    )
    do {
      store.start()
      #expect(await client.calls == 0)
      store.setDashboardVisible(true)
      try await expectDelay(300, sleeper: sleeper)
      #expect(await client.calls == 1)
      #expect(store.networkSeries.value != nil)

      clock.advance(300)
      await sleeper.wake()
      try await expectDelay(720, sleeper: sleeper)
      #expect(await client.calls == 2)
      guard case .stale = store.networkSeries else {
        await store.stop()
        Issue.record("Failed refresh did not retain stale data")
        return
      }
      store.setDashboardVisible(false)
      clock.advance(100)
      store.setDashboardVisible(true)
      try await expectDelay(620, sleeper: sleeper)
      #expect(await client.calls == 2)
      #expect(await sleeper.cancellations == 1)

      clock.advance(620)
      await sleeper.wake()
      try await expectDelay(300, sleeper: sleeper)
      #expect(await client.calls == 3)
      guard case .available = store.networkSeries else {
        await store.stop()
        Issue.record("Successful refresh did not restore current data")
        return
      }
      await store.stop()
      #expect(await sleeper.pendingCount == 0)
      #expect(await sleeper.cancellations == 2)
      store.setDashboardVisible(false)
      store.setDashboardVisible(true)
      #expect(await client.calls == 3)
    } catch {
      await store.stop()
      throw error
    }
  }

  private func expectDelay(_ expected: TimeInterval, sleeper: SeriesTestSleeper) async throws {
    // A bounded real-time guard catches missing timer wiring without hanging the suite.
    let actual = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
      group.addTask {
        var iterator = sleeper.requests.makeAsyncIterator()
        guard let value = await iterator.next() else { throw CancellationError() }
        return value
      }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        throw PollingTestError.timerNotRequested
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    #expect(actual == expected)
  }
}

private enum PollingTestError: Error { case timerNotRequested, unused }

private final class SeriesTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_788_566_400)
  func now() -> Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor SeriesTestSleeper {
  nonisolated let requests: AsyncStream<TimeInterval>
  private let continuation: AsyncStream<TimeInterval>.Continuation
  private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private(set) var cancellations = 0
  var pendingCount: Int { pending.count }

  init() {
    (requests, continuation) = AsyncStream.makeStream()
  }

  func sleep(_ seconds: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
        pending[id] = waiter
        continuation.yield(seconds)
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func wake() {
    let waiters = pending.values
    pending.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func cancel(_ id: UUID) {
    guard let waiter = pending.removeValue(forKey: id) else { return }
    cancellations += 1
    waiter.resume(throwing: CancellationError())
  }
}

private actor PollingSeriesClient: NetworkSeriesFetching {
  private(set) var calls = 0
  func fetch(at capturedAt: Date) async throws -> NetworkSeriesSnapshot {
    calls += 1
    if calls == 2 { throw NetworkSeriesError.httpStatus(429) }
    return NetworkSeriesSnapshot(
      buckets: [], bucketSeconds: 1800,
      startAt: capturedAt.addingTimeInterval(-86_400), endAt: capturedAt,
      updatedAt: capturedAt, capturedAt: capturedAt)
  }
}

private struct PollingUnusedEarnings: AccountEarningsFetching {
  func fetch(now: Date) async throws -> EarningsPresentationValue { .unavailable(reason: "unused") }
}

private struct PollingUnusedSource: TelemetrySource {
  func readDaemonState() async throws -> DaemonState { throw PollingTestError.unused }
  func readLoadedModels() async throws -> LoadedModelsState { throw PollingTestError.unused }
  func readStatus() async throws -> StatusSnapshot { throw PollingTestError.unused }
  func readLegacyEvents(limit: Int) async throws -> [LogEvent] { [] }
}
