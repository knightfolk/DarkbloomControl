import Foundation
import Darwin
import Testing
@testable import DarkbloomTelemetry

@Suite("Unified and bounded events")
struct UnifiedLogTests {
    @Test("privacy-redacted unified message keeps real metadata")
    func parsesPrivateMessage() throws {
        let line = try fixtureLine("unified-log-private")
        let event = try #require(UnifiedLogParser.parse(line: line))
        #expect(event.severity == .error)
        #expect(event.category == "loop")
        #expect(event.message == "Message unavailable (privacy redacted)")
        #expect(event.processID == 10004)
        #expect(event.processImage == "/Users/example/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom")
        #expect(event.source == .unified)
    }

    @Test("exposed lifecycle info retains its message")
    func parsesExposedMessage() throws {
        let line = try fixtureLine("unified-log-message")
        let event = try #require(UnifiedLogParser.parse(line: line))
        #expect(event.severity == .info)
        #expect(event.category == "coordinator")
        #expect(event.message == "Connected to coordinator")
        #expect(event.processID == 10004)
        #expect(event.source == .unified)
    }

    @Test("non-lifecycle info is filtered")
    func filtersNoise() throws {
        let line = Data("{\"timestamp\":\"2026-08-31 17:45:00.000000-0700\",\"messageType\":\"Info\",\"category\":\"metrics\",\"eventMessage\":\"heartbeat\"}".utf8)
        #expect(UnifiedLogParser.parse(line: line) == nil)
    }

    @Test("lifecycle prefixes inside larger words are filtered")
    func filtersLifecyclePrefixNoise() {
        for message in ["loadingFactor sampled", "connectedness metric"] {
            #expect(UnifiedLogParser.parse(line: unifiedLine(message: message)) == nil)
        }
    }

    @Test("buffer deduplicates and retains newest 100")
    func boundsBuffer() {
        var buffer = EventBuffer(capacity: 100)
        let events = (0..<110).map { index in
            LogEvent(timestamp: Date(timeIntervalSince1970: Double(index)), severity: .warning,
                     category: "test", message: "event \(index)", source: .legacy,
                     processID: nil, processImage: nil)
        }
        buffer.insert(events + [events[109]])
        #expect(buffer.events.count == 100)
        #expect(buffer.events.first?.message == "event 109")
        #expect(buffer.events.last?.message == "event 10")
    }

    @Test("buffer enforces the global 100-event maximum")
    func clampsOversizedCapacity() {
        var buffer = EventBuffer(capacity: 1_000)
        buffer.insert((0..<101).map { index in
            LogEvent(timestamp: Date(timeIntervalSince1970: Double(index)), severity: .warning,
                     category: "test", message: "event \(index)", source: .legacy,
                     processID: nil, processImage: nil)
        })

        #expect(buffer.events.count == 100)
        #expect(buffer.events.first?.message == "event 100")
        #expect(buffer.events.last?.message == "event 1")
    }

    @Test("stream yields normalized qualifying lines")
    func streamsEvents() async throws {
        let privateLine = String(decoding: try fixtureLine("unified-log-private"), as: UTF8.self)
        let messageLine = String(decoding: try fixtureLine("unified-log-message"), as: UTF8.self)
        let streamer = UnifiedLogStreamer(testOnlyCommand: .testOnly(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [privateLine + messageLine]
        ))

        var events: [LogEvent] = []
        for try await event in streamer.events() {
            events.append(event)
        }

        #expect(events.map(\.message) == [
            "Message unavailable (privacy redacted)",
            "Connected to coordinator",
        ])
    }

    @Test("paused stream retains only the newest 100 unique events")
    func boundsPendingStreamEvents() async throws {
        let lines = (0..<110).map { index in
            String(decoding: unifiedLine(
                timestamp: index,
                severity: "Error",
                message: "event \(index)"
            ), as: UTF8.self)
        }
        let recorder = UnifiedLogCleanupRecorder()
        let streamer = UnifiedLogStreamer(
            testOnlyCommand: .testOnly(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [lines.joined() + lines[109]]
            ),
            testOnlyCleanupObserver: recorder.record
        )

        let stream = streamer.events()
        _ = try #require(await recorder.wait())
        var events: [LogEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 100)
        #expect(Set(events.map(\.message)).count == 100)
        #expect(events.first?.message == "event 109")
        #expect(events.last?.message == "event 10")
    }

    @Test("stream assembles a JSON line across fragmented reads")
    func assemblesFragmentedLine() async throws {
        let line = String(decoding: unifiedLine(message: "Connected after fragments"), as: UTF8.self)
        let streamer = UnifiedLogStreamer(
            testOnlyCommand: .testOnly(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [line]
            ),
            testOnlyReadChunkLimit: 7
        )

        var events: [LogEvent] = []
        for try await event in streamer.events() {
            events.append(event)
        }
        #expect(events.map(\.message) == ["Connected after fragments"])
    }

    @Test("oversized line is discarded without losing the next record")
    func recoversAfterOversizedLine() async throws {
        let line = String(decoding: unifiedLine(message: "Connected after oversized line"), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let streamer = UnifiedLogStreamer(testOnlyCommand: .testOnly(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: [
                "-v", "line=\(line)",
                "BEGIN { for (i = 0; i < 262145; i++) printf \"x\"; printf \"\\n%s\\n\", line }",
            ]
        ))

        var events: [LogEvent] = []
        for try await event in streamer.events() {
            events.append(event)
        }
        #expect(events.map(\.message) == ["Connected after oversized line"])
    }

    @Test("stderr is drained and never surfaced")
    func drainsStandardError() async {
        let streamer = UnifiedLogStreamer(testOnlyCommand: .testOnly(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: [
                "BEGIN { for (i = 0; i < 70000; i++) printf \"secret\" > \"/dev/stderr\"; exit 7 }",
            ]
        ))

        do {
            for try await _ in streamer.events() {}
            Issue.record("Expected the owned child process to exit nonzero")
        } catch let error as ProcessRunnerError {
            #expect(error == .nonzeroExit(code: 7, message: "Unified log stream exited"))
            #expect(!String(describing: error).contains("secret"))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test("consumer cancellation terminates the owned child and closes its handles")
    func cancelsAndCleansUp() async throws {
        let recorder = UnifiedLogCleanupRecorder()
        let streamer = UnifiedLogStreamer(
            testOnlyCommand: .testOnly(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"]
            ),
            testOnlyCleanupObserver: recorder.record
        )
        let stream = streamer.events()
        let nextEvent = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        await Task.yield()
        nextEvent.cancel()
        do {
            let event = try await nextEvent.value
            #expect(event == nil)
        } catch is CancellationError {
            // AsyncThrowingStream may propagate cancellation after iteration begins.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let state = try #require(await recorder.wait())
        #expect(state.terminationRequested)
        #expect(state.terminationHandlerCleared)
        #expect(state.standardOutputHandlerCleared)
        #expect(state.standardErrorHandlerCleared)
        #expect(state.standardOutputReadHandleClosed)
        #expect(state.standardErrorReadHandleClosed)
        #expect(state.standardOutputWriteHandleClosed)
        #expect(state.standardErrorWriteHandleClosed)
        let processExited = await waitForProcessExit(state.processID)
        #expect(processExited)
    }

    @Test("consumer cancellation returns only after an owned resistant child exits")
    func cancellationAwaitsOwnedChildExit() async throws {
        let line = String(decoding: unifiedLine(message: "Connected before cancellation"), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let recorder = UnifiedLogCleanupRecorder()
        let streamer = UnifiedLogStreamer(
            testOnlyCommand: .testOnly(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; printf '%s\\n' \"$1\"; while :; do :; done",
                    "sh",
                    line,
                ]
            ),
            testOnlyCleanupObserver: recorder.record
        )
        let stream = streamer.events()
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let nextEvent = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            readyContinuation.yield()
            return try await iterator.next()
        }
        var readyIterator = ready.makeAsyncIterator()
        _ = await readyIterator.next()

        nextEvent.cancel()
        do {
            _ = try await nextEvent.value
            Issue.record("Expected stream iteration cancellation")
        } catch is CancellationError {
            // Expected after the owned child is reaped.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let state = try #require(await recorder.wait())
        defer {
            if processExists(state.processID) {
                kill(state.processID, SIGKILL)
            }
        }
        #expect(!processExists(state.processID))
    }

    private func fixtureLine(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func unifiedLine(
        timestamp: Int = 0,
        severity: String = "Info",
        category: String = "test",
        message: String
    ) -> Data {
        let secondsSinceMidnight = 17 * 3_600 + 45 * 60 + timestamp
        let hour = secondsSinceMidnight / 3_600
        let minute = secondsSinceMidnight / 60 % 60
        let second = secondsSinceMidnight % 60
        let time = String(format: "%02d:%02d:%02d", hour, minute, second)
        return Data("{\"timestamp\":\"2026-08-31 \(time).000000-0700\",\"messageType\":\"\(severity)\",\"category\":\"\(category)\",\"eventMessage\":\"\(message)\"}\n".utf8)
    }

    private func waitForProcessExit(_ processID: Int32) async -> Bool {
        for _ in 0..<100 {
            if !processExists(processID) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !processExists(processID)
    }

    private func processExists(_ processID: Int32) -> Bool {
        errno = 0
        if kill(processID, 0) == 0 { return true }
        return errno != ESRCH
    }
}

private final class UnifiedLogCleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var state: UnifiedLogStreamCleanupState?

    func record(_ state: UnifiedLogStreamCleanupState) {
        lock.withLock {
            self.state = state
        }
        semaphore.signal()
    }

    func wait() async -> UnifiedLogStreamCleanupState? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard self.semaphore.wait(timeout: .now() + 2) == .success else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.lock.withLock { self.state })
            }
        }
    }
}
