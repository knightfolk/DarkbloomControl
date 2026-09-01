# Darkbloom Menu Bar Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a native macOS menu-bar popover that continuously displays every source-grounded field exposed by the local Darkbloom CLI, schema-1 state files, and logs without accessing credentials, writing Darkbloom state, or opening a network connection.

**Architecture:** Extend the existing `DarkbloomTelemetry` Swift library into a strict read-only acquisition and normalization boundary, then feed immutable snapshots from an actor-owned polling service into a main-actor SwiftUI store. The `DarkbloomMonitor` executable renders the approved 420-point structured `MenuBarExtra` popover and keeps every direct, derived, stale, and unavailable value distinguishable.

**Tech Stack:** Swift 6.0, Swift Package Manager, macOS 14+, Foundation, SwiftUI, AppKit, Swift Testing; no third-party packages.

**Spec:** `docs/superpowers/specs/2026-08-31-darkbloom-menu-bar-monitor-design.md`

## Global Constraints

- Target macOS 14 or newer and preserve Swift 6 strict concurrency.
- Keep `DarkbloomTelemetry` independent of SwiftUI and AppKit.
- Use only Foundation, SwiftUI, AppKit, and the macOS `/usr/bin/log` executable.
- Read only `daemon-state.json`, `loaded-models.json`, the final 128 KiB of `provider.log`, unified log subsystem `dev.darkbloom.provider`, and fixed `darkbloom status` output.
- Never open `auth_token` or `provider.toml`; never follow a path printed by CLI output.
- Never execute an arbitrary Darkbloom subcommand. The only Darkbloom argument array is exactly `["status"]`.
- Cap finite child-process output at 256 KiB and terminate a timed-out child after three seconds.
- Do not import `Network`, call `URLSession`, open sockets, or add a network entitlement.
- Do not write under `~/.darkbloom` or `~/.config/darkbloom`.
- Retain at most 100 deduplicated lifecycle/warning/error events.
- Poll state and loaded models every two seconds, the legacy log every five seconds, and CLI status every 30 seconds.
- Label token rate, uptime, state age, and trust age as derived; show a reason for every unavailable value.
- Do not sign, notarize, publish, deploy, push, or modify the installed Darkbloom provider.

## File Map

### Telemetry library

- `Sources/DarkbloomTelemetry/TelemetryModels.swift`: direct source models and log-event metadata.
- `Sources/DarkbloomTelemetry/Availability.swift`: source availability, freshness, and derived-duration values.
- `Sources/DarkbloomTelemetry/StateParsers.swift`: schema-checked state and loaded-model decoding.
- `Sources/DarkbloomTelemetry/StatusParser.swift`: independent parsing of every observed `darkbloom status` field.
- `Sources/DarkbloomTelemetry/TelemetryDeriver.swift`: restart-safe counter rates and clock-skew-safe durations.
- `Sources/DarkbloomTelemetry/SourcePolicy.swift`: the complete allowlist of local paths, CLI candidates, commands, byte limits, and polling intervals.
- `Sources/DarkbloomTelemetry/ProcessRunner.swift`: capped, timed finite command execution and owned unified-log streaming.
- `Sources/DarkbloomTelemetry/LocalTelemetrySource.swift`: read-only file and fixed-command acquisition.
- `Sources/DarkbloomTelemetry/LogParsers.swift`: legacy and unified-log normalization.
- `Sources/DarkbloomTelemetry/EventBuffer.swift`: newest-first deduplication and 100-event retention.
- `Sources/DarkbloomTelemetry/TelemetrySnapshot.swift`: immutable UI-facing aggregate and menu presentation status.
- `Sources/DarkbloomTelemetry/TelemetryService.swift`: actor-owned refresh state, polling tasks, last-good preservation, and snapshot stream.
- `Sources/DarkbloomTelemetry/TelemetryFormatting.swift`: deterministic user-facing value and unavailable formatting.

### Menu-bar executable

- Delete `Sources/DarkbloomMonitor/main.swift`.
- `Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift`: accessory application lifecycle and `MenuBarExtra` scene.
- `Sources/DarkbloomMonitor/MonitorStore.swift`: main-actor subscription, manual refresh, and cancellation.
- `Sources/DarkbloomMonitor/MenuBarLabel.swift`: source-grounded icon state and accessibility label.
- `Sources/DarkbloomMonitor/MonitorPopover.swift`: 420-point scroll container and section ordering.
- `Sources/DarkbloomMonitor/Components/StatusBadge.swift`: text-plus-color trust status.
- `Sources/DarkbloomMonitor/Components/MetricCard.swift`: primary metric display with provenance/unavailable copy.
- `Sources/DarkbloomMonitor/Components/SlotCard.swift`: KV and MTP details including explicit MTP-reason gap.
- `Sources/DarkbloomMonitor/Components/EventRow.swift`: literal bounded event rendering.
- `Sources/DarkbloomMonitor/Components/AdvancedSection.swift`: complete status-only/corroborating fields and acquisition diagnostics.

### Tests and fixtures

- Keep `Tests/DarkbloomTelemetryTests/TelemetryTests.swift` as the observed-contract regression suite.
- Add focused test files beside it: `ContractHardeningTests.swift`, `SourcePolicyTests.swift`, `ProcessRunnerTests.swift`, `UnifiedLogTests.swift`, `TelemetryServiceTests.swift`, `TelemetryFormattingTests.swift`, and `MonitorPresentationTests.swift`.
- Add `Tests/DarkbloomTelemetryTests/Fixtures/unified-log-private.jsonl`, `unified-log-message.jsonl`, and `status-partial.txt`.

---

### Task 1: Harden the Schema Contract and Derivations

**Files:**
- Create: `Sources/DarkbloomTelemetry/Availability.swift`
- Modify: `Sources/DarkbloomTelemetry/StateParsers.swift`
- Modify: `Sources/DarkbloomTelemetry/TelemetryDeriver.swift`
- Test: `Tests/DarkbloomTelemetryTests/ContractHardeningTests.swift`
- Create: `Tests/DarkbloomTelemetryTests/Fixtures/status-partial.txt`

**Interfaces:**
- Consumes: existing `DaemonState`, `LoadedModelsState`, and `TokenRate` types.
- Produces: `SourceAvailability<Value>`, `DerivedDuration`, `TelemetryContractError`, schema-checked `DaemonStateParser.parse(_:)`, schema-checked `LoadedModelsParser.parse(_:)`, `TelemetryDeriver.uptime(state:now:)`, `snapshotAge(state:now:)`, and `trustAge(state:now:)`.

- [ ] **Step 1: Write failing schema and derivation tests**

Create `ContractHardeningTests.swift` with literal expectations for unsupported schemas, every token-rate branch, and negative time deltas:

```swift
import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Contract hardening")
struct ContractHardeningTests {
    @Test("schema 2 state is rejected instead of partially decoded")
    func rejectsUnknownStateSchema() throws {
        let data = Data("{\"schema\":2}".utf8)
        #expect(throws: TelemetryContractError.unsupportedSchema(
            source: "daemon-state.json", found: 2, supported: 1
        )) {
            try DaemonStateParser.parse(data)
        }
    }

    @Test("loaded-model schema mismatch names its source")
    func rejectsUnknownLoadedModelsSchema() throws {
        let data = Data("{\"schema\":7}".utf8)
        #expect(throws: TelemetryContractError.unsupportedSchema(
            source: "loaded-models.json", found: 7, supported: 1
        )) {
            try LoadedModelsParser.parse(data)
        }
    }

    @Test(arguments: [
        (1_000.0, 1_000.0, TokenRate.unavailable(reason: "State timestamp did not advance")),
        (1_000.0, 999.0, TokenRate.unavailable(reason: "State timestamp did not advance")),
    ])
    func rejectsNonAdvancingStateTime(previous: Double, current: Double, expected: TokenRate) {
        #expect(TelemetryDeriver.tokenRate(
            previous: sample(tokens: 10, writtenAt: previous),
            current: sample(tokens: 20, writtenAt: current)
        ) == expected)
    }

    @Test("backwards token counter is unavailable")
    func rejectsBackwardsCounter() {
        #expect(TelemetryDeriver.tokenRate(
            previous: sample(tokens: 20, writtenAt: 1_000),
            current: sample(tokens: 10, writtenAt: 1_004)
        ) == .unavailable(reason: "Token counter moved backwards"))
    }

    @Test("first sample is unavailable")
    func waitsForSecondSample() {
        #expect(TelemetryDeriver.tokenRate(
            previous: nil,
            current: sample(tokens: 10, writtenAt: 1_004)
        ) == .unavailable(reason: "Waiting for a second telemetry sample"))
    }

    @Test("clock skew never becomes a zero duration")
    func rejectsClockSkew() {
        let state = sample(tokens: 10, writtenAt: 2_000, startedAt: 2_100, trustAt: 2_200)
        #expect(TelemetryDeriver.uptime(state: state, now: 2_050) ==
            .unavailable(reason: "Provider start time is in the future"))
        #expect(TelemetryDeriver.snapshotAge(state: state, now: 1_999) ==
            .unavailable(reason: "State write time is in the future"))
        #expect(TelemetryDeriver.trustAge(state: state, now: 2_199) ==
            .unavailable(reason: "Trust receipt time is in the future"))
    }

    @Test("one malformed status value does not erase unrelated fields")
    func isolatesMalformedStatusField() throws {
        let url = try #require(Bundle.module.url(
            forResource: "status-partial", withExtension: "txt", subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: url)
        let status = StatusParser.parse(String(decoding: data, as: UTF8.self))
        #expect(status.providerName == "darkbloom-test")
        #expect(status.backendPort == nil)
        #expect(status.trust == "hardware / online")
    }
}
```

The `status-partial.txt` fixture contains exactly:

```text
darkbloom 0.8.15
Provider: darkbloom-test
Backend port: not-a-number
Trust: hardware / online
```

Put the `sample(...)` builder in a private extension in the same test file. It must create a complete real `DaemonState`, use a fixed `ProcessIdentity(pid: 42, startTimeMicros: 900_000_000)`, and accept explicit `startedAt` and `trustAt` overrides.

- [ ] **Step 2: Run the new tests and verify red**

Run:

```bash
swift test --filter ContractHardeningTests
```

Expected: compilation fails because `TelemetryContractError`, `SourceAvailability`, `DerivedDuration`, and `trustAge` do not exist, and the current parsers do not preflight schema values.

- [ ] **Step 3: Add availability and schema preflight implementations**

Create `Availability.swift`:

```swift
import Foundation

public enum SourceAvailability<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(value: Value, capturedAt: Date)
    case stale(value: Value, capturedAt: Date, reason: String)
    case unavailable(reason: String)
}

public enum DerivedDuration: Equatable, Sendable {
    case available(seconds: TimeInterval, label: String)
    case unavailable(reason: String)
}

public enum TelemetryContractError: Error, Equatable, Sendable {
    case unsupportedSchema(source: String, found: Int, supported: Int)
}
```

In `StateParsers.swift`, decode only the schema discriminator first and reject every value other than 1 before decoding the complete DTO:

```swift
private struct SchemaEnvelope: Decodable { let schema: Int }

private static func requireSchema1(_ data: Data, source: String) throws {
    let found = try JSONDecoder().decode(SchemaEnvelope.self, from: data).schema
    guard found == 1 else {
        throw TelemetryContractError.unsupportedSchema(
            source: source, found: found, supported: 1
        )
    }
}
```

Call it from each public parser with the exact source filename. Change the three duration functions to return `DerivedDuration`; successful values use label `"derived"`, and negative values return the exact reasons asserted above.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter ContractHardeningTests
swift test
```

Expected: the new suite passes and the existing eight observed-contract tests remain green.

- [ ] **Step 5: Commit the contract hardening**

```bash
git add Sources/DarkbloomTelemetry/Availability.swift Sources/DarkbloomTelemetry/StateParsers.swift Sources/DarkbloomTelemetry/TelemetryDeriver.swift Tests/DarkbloomTelemetryTests/ContractHardeningTests.swift Tests/DarkbloomTelemetryTests/TelemetryTests.swift Tests/DarkbloomTelemetryTests/Fixtures/status-partial.txt
git commit -m "feat: harden darkbloom telemetry contract"
```

---

### Task 2: Enforce the Local Read-Only Source Policy

**Files:**
- Create: `Sources/DarkbloomTelemetry/SourcePolicy.swift`
- Create: `Sources/DarkbloomTelemetry/ProcessRunner.swift`
- Create: `Sources/DarkbloomTelemetry/LocalTelemetrySource.swift`
- Test: `Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift`
- Test: `Tests/DarkbloomTelemetryTests/ProcessRunnerTests.swift`

**Interfaces:**
- Consumes: `DaemonStateParser`, `LoadedModelsParser`, `StatusParser`, `BoundedFileTail`, and `LegacyLogParser`.
- Produces: `DarkbloomSourcePolicy`, fixed `ReadOnlyCommand`, `CommandResult`, `ProcessRunnerError`, `CappedProcessRunner.run(_:timeout:outputLimit:)`, `TelemetrySource` protocol, and `LocalTelemetrySource`.

- [ ] **Step 1: Write failing source-policy tests**

Create `SourcePolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Read-only source policy")
struct SourcePolicyTests {
    @Test("only approved Darkbloom files are readable")
    func allowlistsFiles() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let policy = DarkbloomSourcePolicy(homeDirectory: home, environmentPath: "/usr/bin:/bin")
        #expect(policy.daemonState.path == "/Users/example/.darkbloom/daemon-state.json")
        #expect(policy.loadedModels.path == "/Users/example/.darkbloom/loaded-models.json")
        #expect(policy.legacyLog.path == "/Users/example/.darkbloom/provider.log")
        #expect(policy.allowedFiles == [policy.daemonState, policy.loadedModels, policy.legacyLog])
        #expect(!policy.allowedFiles.map(\.lastPathComponent).contains("auth_token"))
        #expect(!policy.allowedFiles.map(\.lastPathComponent).contains("provider.toml"))
    }

    @Test("the only Darkbloom command is status")
    func fixesStatusArguments() {
        let executable = URL(fileURLWithPath: "/Users/example/.darkbloom/bin/darkbloom")
        let command = ReadOnlyCommand.darkbloomStatus(executable: executable)
        #expect(command.executable == executable)
        #expect(command.arguments == ["status"])
    }

    @Test("polling and byte bounds match the approved design")
    func fixesBounds() {
        #expect(DarkbloomSourcePolicy.stateInterval == .seconds(2))
        #expect(DarkbloomSourcePolicy.logInterval == .seconds(5))
        #expect(DarkbloomSourcePolicy.statusInterval == .seconds(30))
        #expect(DarkbloomSourcePolicy.legacyLogByteLimit == 131_072)
        #expect(DarkbloomSourcePolicy.processOutputByteLimit == 262_144)
        #expect(DarkbloomSourcePolicy.processTimeout == .seconds(3))
    }
}
```

- [ ] **Step 2: Write failing capped-process tests**

Create `ProcessRunnerTests.swift` with real local child processes:

```swift
import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Capped process runner")
struct ProcessRunnerTests {
    @Test("captures a finite process result")
    func capturesOutput() async throws {
        let result = try await CappedProcessRunner().run(
            .testOnly(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["darkbloom 0.8.15"]),
            timeout: .seconds(3),
            outputLimit: 256
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == Data("darkbloom 0.8.15".utf8))
        #expect(result.standardError.isEmpty)
    }

    @Test("terminates output beyond the cap")
    func capsOutput() async {
        await #expect(throws: ProcessRunnerError.outputLimitExceeded(limit: 8)) {
            try await CappedProcessRunner().run(
                .testOnly(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["123456789"]),
                timeout: .seconds(3),
                outputLimit: 8
            )
        }
    }

    @Test("terminates an owned timed-out child")
    func timesOut() async {
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await CappedProcessRunner().run(
                .testOnly(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"]),
                timeout: .milliseconds(50),
                outputLimit: 256
            )
        }
    }
}
```

Keep `ReadOnlyCommand.testOnly` internal so production callers outside the module can construct only `.darkbloomStatus` and `.unifiedLogStream`.

- [ ] **Step 3: Run policy and runner tests and verify red**

```bash
swift test --filter SourcePolicyTests
swift test --filter ProcessRunnerTests
```

Expected: compilation fails because the policy, command, runner, result, and error types do not exist.

- [ ] **Step 4: Implement the fixed source policy and runner**

Define these public values in `SourcePolicy.swift`:

```swift
public struct DarkbloomSourcePolicy: Equatable, Sendable {
    public static let stateInterval: Duration = .seconds(2)
    public static let logInterval: Duration = .seconds(5)
    public static let statusInterval: Duration = .seconds(30)
    public static let legacyLogByteLimit = 128 * 1_024
    public static let processOutputByteLimit = 256 * 1_024
    public static let processTimeout: Duration = .seconds(3)

    public let daemonState: URL
    public let loadedModels: URL
    public let legacyLog: URL
    public let cliCandidates: [URL]
    public var allowedFiles: [URL] { [daemonState, loadedModels, legacyLog] }

    public init(homeDirectory: URL, environmentPath: String) {
        let root = homeDirectory.appendingPathComponent(".darkbloom", isDirectory: true)
        daemonState = root.appendingPathComponent("daemon-state.json")
        loadedModels = root.appendingPathComponent("loaded-models.json")
        legacyLog = root.appendingPathComponent("provider.log")
        cliCandidates = [
            root.appendingPathComponent("bin/darkbloom"),
            root.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom"),
        ] + environmentPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("darkbloom")
        }
    }
}
```

Implement `CappedProcessRunner` with `Process`, separate stdout/stderr pipes, concurrent draining, a `Task.sleep(for:)` timeout race, and termination of only its own child. Return:

```swift
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded(limit: Int)
    case nonzeroExit(code: Int32, message: String)
}
```

Declare `public init() {}` on `CappedProcessRunner`; keep its lower-level process
construction private so callers cannot bypass `ReadOnlyCommand`.

The runner must check the combined stdout/stderr byte count on every chunk, terminate the child on overflow or timeout, close all handles, and await termination before returning.

- [ ] **Step 5: Implement the local source adapter**

Create `LocalTelemetrySource.swift` with this boundary:

```swift
public protocol TelemetrySource: Sendable {
    func readDaemonState() async throws -> DaemonState
    func readLoadedModels() async throws -> LoadedModelsState
    func readStatus() async throws -> StatusSnapshot
    func readLegacyEvents(limit: Int) async throws -> [LogEvent]
}

public struct LocalTelemetrySource: TelemetrySource, Sendable {
    public let policy: DarkbloomSourcePolicy
    public let runner: CappedProcessRunner

    public init(policy: DarkbloomSourcePolicy, runner: CappedProcessRunner) {
        self.policy = policy
        self.runner = runner
    }

    public func readDaemonState() async throws -> DaemonState
    public func readLoadedModels() async throws -> LoadedModelsState
    public func readStatus() async throws -> StatusSnapshot
    public func readLegacyEvents(limit: Int) async throws -> [LogEvent]
}
```

Read files only through the three policy URLs. For each JSON file, retry decoding once after `Task.sleep(for: .milliseconds(100))`. Resolve the first executable candidate that is executable, run exactly `.darkbloomStatus(executable:)`, reject nonzero exit, and parse stdout as UTF-8. Tail the legacy log with `BoundedFileTail.read` and the approved 128 KiB limit.

- [ ] **Step 6: Run focused, full, and static safety checks**

```bash
swift test --filter SourcePolicyTests
swift test --filter ProcessRunnerTests
swift test
rg -n 'auth_token|provider\.toml|URLSession|import Network|NWConnection' Sources
```

Expected: all tests pass. The only `auth_token` and `provider.toml` hits, if any, are human documentation; there are no such reads in `Sources` and no network APIs.

- [ ] **Step 7: Commit the read-only acquisition boundary**

```bash
git add Sources/DarkbloomTelemetry/SourcePolicy.swift Sources/DarkbloomTelemetry/ProcessRunner.swift Sources/DarkbloomTelemetry/LocalTelemetrySource.swift Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift Tests/DarkbloomTelemetryTests/ProcessRunnerTests.swift
git commit -m "feat: add read-only darkbloom telemetry sources"
```

---

### Task 3: Normalize Unified Logs and Bound Recent Events

**Files:**
- Modify: `Sources/DarkbloomTelemetry/TelemetryModels.swift`
- Modify: `Sources/DarkbloomTelemetry/LogParsers.swift`
- Create: `Sources/DarkbloomTelemetry/EventBuffer.swift`
- Modify: `Sources/DarkbloomTelemetry/ProcessRunner.swift`
- Create: `Tests/DarkbloomTelemetryTests/Fixtures/unified-log-private.jsonl`
- Create: `Tests/DarkbloomTelemetryTests/Fixtures/unified-log-message.jsonl`
- Test: `Tests/DarkbloomTelemetryTests/UnifiedLogTests.swift`

**Interfaces:**
- Consumes: `LogSeverity`, `LogEvent`, fixed `.unifiedLogStream`, and existing legacy parsing.
- Produces: expanded `LogEvent`, `LogSource`, `UnifiedLogParser.parse(line:)`, `EventBuffer`, and `UnifiedLogStreamer.events()`.

- [ ] **Step 1: Add literal unified-log fixtures and failing tests**

Use one JSON object per line. The private fixture must include `timestamp`, `messageType: "Error"`, `category: "loop"`, `processID: 10004`, `processImagePath`, and `eventMessage: "<private>"`. The exposed fixture uses `messageType: "Info"`, category `coordinator`, and event message `"Connected to coordinator"`.

Create `UnifiedLogTests.swift`:

```swift
import Foundation
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

    @Test("non-lifecycle info is filtered")
    func filtersNoise() throws {
        let line = Data("{\"timestamp\":\"2026-08-31 17:45:00.000000-0700\",\"messageType\":\"Info\",\"category\":\"metrics\",\"eventMessage\":\"heartbeat\"}".utf8)
        #expect(UnifiedLogParser.parse(line: line) == nil)
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
}
```

- [ ] **Step 2: Run the unified-log suite and verify red**

```bash
swift test --filter UnifiedLogTests
```

Expected: compilation fails because the unified parser, source metadata, buffer, and expanded initializer do not exist.

- [ ] **Step 3: Expand events and implement parsing/deduplication**

Add to `TelemetryModels.swift`:

```swift
public enum LogSource: String, Equatable, Sendable { case legacy, unified }

public struct LogEvent: Equatable, Sendable {
    public let timestamp: Date?
    public let severity: LogSeverity
    public let category: String
    public let message: String
    public let source: LogSource
    public let processID: Int32?
    public let processImage: String?
}
```

Update legacy parsing to set `.legacy` and nil process metadata. In `UnifiedLogParser`, decode only the observed JSON keys, map `Debug/Info/Notice/Default` to `.info` or `.notice`, map `Error/Fault` to `.error`, and use the redacted placeholder only when the message is exactly `<private>`. Keep warning/error/fault regardless of message; retain info/notice only when the same lifecycle keyword predicate used by the legacy parser matches.

Implement `EventBuffer` as a value type. Its deduplication key is timestamp, severity, category, and message; it sorts nil timestamps after real timestamps and returns newest first.

- [ ] **Step 4: Add the owned unified-log stream**

Implement `UnifiedLogStreamer.events()` as `AsyncThrowingStream<LogEvent, Error>`. It launches only:

```text
/usr/bin/log stream --style json --level info --predicate subsystem == "dev.darkbloom.provider"
```

Expose `public init() {}` and the public `events()` method; keep the underlying
`Process` and pipe handlers private to the streamer.

Read stdout incrementally by newline, cap each individual line at 256 KiB, parse it, and yield qualifying events. Drain stderr without displaying arbitrary content beyond the same cap. Stream cancellation terminates only the owned `/usr/bin/log` process and closes its handles.

- [ ] **Step 5: Run focused and full tests**

```bash
swift test --filter UnifiedLogTests
swift test
```

Expected: private and exposed records normalize correctly, noise is filtered, duplicates collapse, the buffer contains exactly the newest 100, and all existing legacy tests pass after their expected `LogEvent` metadata is updated.

- [ ] **Step 6: Commit the bounded event pipeline**

```bash
git add Sources/DarkbloomTelemetry/TelemetryModels.swift Sources/DarkbloomTelemetry/LogParsers.swift Sources/DarkbloomTelemetry/EventBuffer.swift Sources/DarkbloomTelemetry/ProcessRunner.swift Tests/DarkbloomTelemetryTests/UnifiedLogTests.swift Tests/DarkbloomTelemetryTests/TelemetryTests.swift Tests/DarkbloomTelemetryTests/Fixtures/unified-log-private.jsonl Tests/DarkbloomTelemetryTests/Fixtures/unified-log-message.jsonl
git commit -m "feat: normalize bounded darkbloom events"
```

---

### Task 4: Aggregate Fresh, Stale, and Unavailable Snapshots

**Files:**
- Create: `Sources/DarkbloomTelemetry/TelemetrySnapshot.swift`
- Create: `Sources/DarkbloomTelemetry/TelemetryService.swift`
- Test: `Tests/DarkbloomTelemetryTests/TelemetryServiceTests.swift`

**Interfaces:**
- Consumes: `TelemetrySource`, `UnifiedLogStreamer`, `EventBuffer`, `SourceAvailability`, `TelemetryDeriver`, and policy intervals.
- Produces: `EventFeed`, `AcquisitionDiagnostic`, `MenuPresentationStatus`, immutable `TelemetrySnapshot`, and actor `TelemetryService` with `snapshots()`, `start()`, `refreshNow()`, `ingestUnifiedEvent(_:)`, and `stop()`.

- [ ] **Step 1: Write failing snapshot-service tests with a controllable source**

Create an actor `ScriptedTelemetrySource` inside the test file. Give it arrays of `Result` values for state, loaded models, status, and legacy events, and increment call counters on every read. Add tests:

```swift
@Test("successful refresh emits every source and first-sample rate gap")
func emitsCompleteSnapshot() async throws {
    let source = ScriptedTelemetrySource.successful(state: sample(tokens: 10, writtenAt: 1_000))
    let service = TelemetryService(source: source, now: { Date(timeIntervalSince1970: 1_001) })
    let snapshot = await service.refreshNow()
    #expect(snapshot.state.value?.currentModel == "model")
    #expect(snapshot.loadedModels.value?.models == ["model"])
    #expect(snapshot.status.value?.version == "0.8.15")
    #expect(snapshot.tokenRate == .unavailable(reason: "Waiting for a second telemetry sample"))
}

@Test("failed refresh preserves last good value as stale")
func preservesLastGoodState() async throws {
    let source = ScriptedTelemetrySource(states: [
        .success(sample(tokens: 10, writtenAt: 1_000)),
        .failure(TestError.readFailed),
    ])
    let service = TelemetryService(source: source, now: { Date(timeIntervalSince1970: 1_001) })
    _ = await service.refreshNow()
    let second = await service.refreshNow()
    guard case .stale(let state, _, let reason) = second.state else {
        Issue.record("Expected stale state"); return
    }
    #expect(state.stats.tokensGenerated == 10)
    #expect(reason.contains("readFailed"))
}

@Test("restart discards the previous rate sample")
func resetsRateOnRestart() async {
    let source = ScriptedTelemetrySource(states: [
        .success(sample(tokens: 100, writtenAt: 1_000, pid: 42)),
        .success(sample(tokens: 10, writtenAt: 1_004, pid: 43)),
    ])
    let service = TelemetryService(source: source, now: { Date(timeIntervalSince1970: 1_005) })
    _ = await service.refreshNow()
    let second = await service.refreshNow()
    #expect(second.tokenRate == .unavailable(reason: "Provider process changed between samples"))
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
```

- [ ] **Step 2: Run service tests and verify red**

```bash
swift test --filter TelemetryServiceTests
```

Expected: compilation fails because snapshot, diagnostics, presentation status, and service types do not exist.

- [ ] **Step 3: Define the immutable snapshot**

Create these types in `TelemetrySnapshot.swift`:

```swift
public struct EventFeed: Equatable, Sendable {
    public let events: [LogEvent]
    public let legacyReadAt: Date?
    public let unifiedActivityAt: Date?
}

public struct AcquisitionDiagnostic: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let message: String
    public let occurredAt: Date
}

public enum MenuPresentationStatus: Equatable, Sendable {
    case online, stale, offline, unavailable
}

public struct TelemetrySnapshot: Equatable, Sendable {
    public let state: SourceAvailability<DaemonState>
    public let loadedModels: SourceAvailability<LoadedModelsState>
    public let status: SourceAvailability<StatusSnapshot>
    public let eventFeed: SourceAvailability<EventFeed>
    public let tokenRate: TokenRate
    public let diagnostics: [AcquisitionDiagnostic]
    public let capturedAt: Date
    public let menuStatus: MenuPresentationStatus
}
```

Add a read-only `value` computed property to `SourceAvailability`. It returns the value for available/stale and nil for unavailable. Compute menu status exactly from structured-state availability, 10-second freshness, and literal trust status as specified.

- [ ] **Step 4: Implement the actor service and independent source refreshes**

`TelemetryService` owns last good values, the previous valid state sample, `EventBuffer(capacity: 100)`, timer tasks, and at most one active refresh. Its public interface is:

```swift
public actor TelemetryService {
    public init(
        source: any TelemetrySource,
        now: @escaping @Sendable () -> Date = { Date() },
        unifiedEvents: AsyncThrowingStream<LogEvent, Error>? = nil
    )
    public func snapshots() -> AsyncStream<TelemetrySnapshot>
    public func start()
    @discardableResult public func refreshNow() async -> TelemetrySnapshot
    public func ingestUnifiedEvent(_ event: LogEvent)
    public func stop()
}
```

Refresh state and loaded models every two seconds, legacy logs every five, and status every 30. `refreshNow()` requests all four sources. Coalesce overlapping calls onto the active refresh task. Each source failure changes only that group's availability and appends or replaces a stable diagnostic ID. On a successful structured-state read, compute token rate against the immediately previous successful sample before replacing it.

The stream yields the current snapshot immediately to each subscriber, then every time a source, event, freshness state, or diagnostic changes. Finish streams during `stop()`.

- [ ] **Step 5: Run service and full tests**

```bash
swift test --filter TelemetryServiceTests
swift test
```

Expected: last-good values go stale independently, missing sources remain explicitly unavailable, manual refresh has maximum concurrency one, restart derivation is reset, and all suites pass.

- [ ] **Step 6: Commit snapshot aggregation**

```bash
git add Sources/DarkbloomTelemetry/TelemetrySnapshot.swift Sources/DarkbloomTelemetry/TelemetryService.swift Sources/DarkbloomTelemetry/Availability.swift Tests/DarkbloomTelemetryTests/TelemetryServiceTests.swift
git commit -m "feat: aggregate darkbloom telemetry snapshots"
```

---

### Task 5: Add Deterministic Display Formatting

**Files:**
- Create: `Sources/DarkbloomTelemetry/TelemetryFormatting.swift`
- Test: `Tests/DarkbloomTelemetryTests/TelemetryFormattingTests.swift`

**Interfaces:**
- Consumes: `TokenRate`, `DerivedDuration`, `SourceAvailability`, `MemoryCapacity`, and dates.
- Produces: pure `TelemetryFormatting` functions used by every SwiftUI component.

- [ ] **Step 1: Write failing literal formatting tests**

```swift
import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Telemetry formatting")
struct TelemetryFormattingTests {
    @Test("rate includes provenance")
    func formatsRate() {
        #expect(TelemetryFormatting.tokenRate(.available(tokensPerSecond: 15.04, label: "derived")) == "15.0 tok/s · derived")
        #expect(TelemetryFormatting.tokenRate(.unavailable(reason: "No token progress in the polling window")) == "Unavailable — No token progress in the polling window")
    }

    @Test("durations stay compact and derived")
    func formatsDuration() {
        #expect(TelemetryFormatting.duration(.available(seconds: 3_661, label: "derived")) == "1h 1m · derived")
        #expect(TelemetryFormatting.duration(.unavailable(reason: "State write time is in the future")) == "Unavailable — State write time is in the future")
    }

    @Test("memory uses gibibyte precision without summing cache")
    func formatsMemory() {
        #expect(TelemetryFormatting.gibibytes(14.7594) == "14.76 GiB")
        #expect(TelemetryFormatting.memoryFraction(active: 14.75, total: 64) == 0.23046875)
    }

    @Test("empty exposed models differ from an unavailable source")
    func formatsModelLists() {
        #expect(TelemetryFormatting.modelList([]) == "None reported")
        #expect(TelemetryFormatting.unavailable("loaded-models.json missing") == "Unavailable — loaded-models.json missing")
    }
}
```

- [ ] **Step 2: Run formatting tests and verify red**

```bash
swift test --filter TelemetryFormattingTests
```

Expected: compilation fails because `TelemetryFormatting` does not exist.

- [ ] **Step 3: Implement locale-stable pure formatting**

Implement a public namespace with these signatures:

```swift
public enum TelemetryFormatting {
    public static func tokenRate(_ rate: TokenRate) -> String
    public static func duration(_ duration: DerivedDuration) -> String
    public static func gibibytes(_ value: Double) -> String
    public static func memoryFraction(active: Double, total: Double) -> Double?
    public static func modelList(_ models: [String]) -> String
    public static func integer(_ value: Int64) -> String
    public static func timestamp(_ date: Date?) -> String
    public static func unavailable(_ reason: String) -> String
}
```

Use `Locale(identifier: "en_US_POSIX")` for deterministic test output, clamp only the progress fraction to `0...1`, and return nil when total memory is zero or negative. Do not turn unavailable input into zero.

- [ ] **Step 4: Run focused and full tests**

```bash
swift test --filter TelemetryFormattingTests
swift test
```

Expected: every literal formatting assertion passes and no existing parser output changes.

- [ ] **Step 5: Commit formatting**

```bash
git add Sources/DarkbloomTelemetry/TelemetryFormatting.swift Tests/DarkbloomTelemetryTests/TelemetryFormattingTests.swift
git commit -m "feat: format telemetry provenance and gaps"
```

---

### Task 6: Replace the Shell with the Menu-Bar Lifecycle

**Files:**
- Delete: `Sources/DarkbloomMonitor/main.swift`
- Create: `Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift`
- Create: `Sources/DarkbloomMonitor/MonitorStore.swift`
- Create: `Sources/DarkbloomMonitor/MenuBarLabel.swift`
- Create: `Sources/DarkbloomMonitor/MonitorPopover.swift`
- Test: `Tests/DarkbloomTelemetryTests/MonitorPresentationTests.swift`

**Interfaces:**
- Consumes: `LocalTelemetrySource`, `TelemetryService`, `TelemetrySnapshot`, and `MenuPresentationStatus`.
- Produces: accessory-only `DarkbloomMonitorApp`, `MonitorStore`, menu label, and a compiling empty-state popover shell.

- [ ] **Step 1: Write failing menu-presentation tests**

Keep the presentation mapping in `DarkbloomTelemetry` so it can be tested without importing the executable target:

```swift
@Test("menu status has inspectable symbol and label")
func mapsMenuStatus() {
    #expect(MenuPresentationStatus.online.symbolName == "circle.fill")
    #expect(MenuPresentationStatus.online.accessibilityLabel == "Darkbloom online")
    #expect(MenuPresentationStatus.stale.accessibilityLabel == "Darkbloom state stale")
    #expect(MenuPresentationStatus.offline.accessibilityLabel == "Darkbloom offline")
    #expect(MenuPresentationStatus.unavailable.accessibilityLabel == "Darkbloom unavailable")
}
```

Add `symbolName` and `accessibilityLabel` extensions in `TelemetrySnapshot.swift`; color remains a SwiftUI concern.

- [ ] **Step 2: Run the presentation test and verify red**

```bash
swift test --filter MonitorPresentationTests
```

Expected: compilation fails because the presentation mapping properties do not exist.

- [ ] **Step 3: Implement `MonitorStore`**

```swift
import SwiftUI
import DarkbloomTelemetry

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot: TelemetrySnapshot
    private let service: TelemetryService
    private var observationTask: Task<Void, Never>?

    init(service: TelemetryService, initial: TelemetrySnapshot) {
        self.service = service
        snapshot = initial
    }

    func start()
    func refresh()
    func stop()
    func quit()
}
```

`start()` subscribes to `await service.snapshots()` once, assigns snapshots on the main actor, and starts the service. `refresh()` launches a single main-actor-owned task that awaits `refreshNow()`. `stop()` cancels observation and calls `service.stop()`.
`quit()` awaits `service.stop()` before calling `NSApplication.shared.terminate(nil)` so the owned unified-log child cannot be orphaned.

- [ ] **Step 4: Implement the accessory app and empty-state popover shell**

Create `DarkbloomMonitorApp.swift`:

```swift
import AppKit
import SwiftUI
import DarkbloomTelemetry

@main
struct DarkbloomMonitorApp: App {
    @StateObject private var store: MonitorStore

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = DarkbloomSourcePolicy(
            homeDirectory: home,
            environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        )
        let source = LocalTelemetrySource(policy: policy, runner: CappedProcessRunner())
        let unifiedEvents = UnifiedLogStreamer().events()
        let service = TelemetryService(source: source, unifiedEvents: unifiedEvents)
        let monitorStore = MonitorStore(service: service, initial: .unavailable(now: Date()))
        _store = StateObject(wrappedValue: monitorStore)
        Task { @MainActor in monitorStore.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(store: store)
        } label: {
            MenuBarLabel(status: store.snapshot.menuStatus)
        }
        .menuBarExtraStyle(.window)
    }
}
```

Provide `TelemetrySnapshot.unavailable(now:)` with explicit unavailable reasons for every group and the waiting-for-second-sample token rate. `MonitorPopover` initially renders the header, source-unavailable reasons, Refresh Now, and Quit in a `ScrollView` framed to width 420 and maximum height 680.

`MenuBarLabel` uses `symbolRenderingMode(.palette)` and semantic green/orange/red/secondary foreground styles. It always supplies the tested accessibility label so monochrome menu-bar rendering does not hide status meaning.

- [ ] **Step 5: Build, test, and run the menu-bar shell**

```bash
swift test --filter MonitorPresentationTests
swift test
swift build
swift run DarkbloomMonitor
```

Expected: tests and build pass without warnings; the process remains running as an accessory app, produces a menu-bar item, shows the 420-point empty/loading popover, and produces no Dock icon. Quit it through its own menu action after inspection.

- [ ] **Step 6: Commit the native lifecycle**

```bash
git add Package.swift Sources/DarkbloomMonitor Sources/DarkbloomTelemetry/TelemetrySnapshot.swift Tests/DarkbloomTelemetryTests/MonitorPresentationTests.swift
git commit -m "feat: add native darkbloom menu bar shell"
```

---

### Task 7: Build the Complete Structured Popover

**Files:**
- Modify: `Sources/DarkbloomMonitor/MonitorPopover.swift`
- Create: `Sources/DarkbloomMonitor/Components/StatusBadge.swift`
- Create: `Sources/DarkbloomMonitor/Components/MetricCard.swift`
- Create: `Sources/DarkbloomMonitor/Components/SlotCard.swift`
- Create: `Sources/DarkbloomMonitor/Components/EventRow.swift`
- Create: `Sources/DarkbloomMonitor/Components/AdvancedSection.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPresentationTests.swift`

**Interfaces:**
- Consumes: immutable snapshot groups and `TelemetryFormatting` only; views never read files or launch processes.
- Produces: the full approved header, metrics, model/slot, memory/process, trust, recent-event, Advanced, and footer UI.

- [ ] **Step 1: Add failing section-content tests**

Add pure presentation helpers to `MonitorPresentationTests.swift`:

```swift
@Test("slot reason is explicit when schema exposes none")
func formatsSlotGap() {
    let slot = ModelSlot(model: "gemma", mtpEnabled: true, mtpActive: true,
                         mtpReason: nil, kvBackend: "contiguous", requestedKVBackend: "auto")
    #expect(slot.displayMTPReason == "Unavailable — not exposed by Darkbloom schema 1")
}

@Test("event empty states distinguish no events from source failure")
func formatsEventEmptyStates() {
    #expect(EventFeed(events: [], legacyReadAt: Date(timeIntervalSince1970: 1), unifiedActivityAt: nil).emptyMessage == "No qualifying events in the bounded window")
    let unavailable: SourceAvailability<EventFeed> = .unavailable(reason: "provider.log missing")
    #expect(unavailable.eventEmptyMessage == "Logs unavailable — provider.log missing")
}

@Test("advanced status rows include every observed status property")
func includesAllStatusRows() {
    let rows = StatusSnapshot.completeFixture.advancedRows
    #expect(rows.map(\.label) == [
        "CLI version", "Provider", "Config path", "Coordinator", "Backend port",
        "Configured model", "Idle timeout", "Beta features", "Auto-restart",
        "Hardware", "Inference memory", "Local boot checks", "Schedule",
        "Enabled model filter", "Local MLX models", "Daemon", "CLI trust",
        "CLI trust reason", "CLI warm models", "Most recently used",
        "CLI requests", "CLI tokens", "CLI state age", "CLI slot posture",
    ])
}
```

Define `DisplayRow(label:value:)`, `ModelSlot.displayMTPReason`, `EventFeed.emptyMessage`, `SourceAvailability<EventFeed>.eventEmptyMessage`, and `StatusSnapshot.advancedRows` in telemetry presentation extensions. The test fixture constructs every status property with literal values.

- [ ] **Step 2: Run presentation tests and verify red**

```bash
swift test --filter MonitorPresentationTests
```

Expected: compilation fails because the display-row and explicit-gap helpers do not exist.

- [ ] **Step 3: Implement reusable components**

Use semantic SwiftUI styles and no custom drawing beyond the memory progress bar:

```swift
struct MetricCard: View {
    let title: String
    let value: String
    let detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().textSelection(.enabled)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
```

`StatusBadge` pairs text and a circle with an accessibility label. `SlotCard` shows model, effective/requested KV, MTP enabled, MTP active, and the explicit reason gap. `EventRow` shows severity symbol, timestamp, category, and a three-line literal message with tooltip. `AdvancedSection` renders every `advancedRows` entry as selectable inert text and lists source timestamps plus diagnostics.

- [ ] **Step 4: Assemble every popover section in the approved order**

`MonitorPopover` must contain, in order:

```swift
ScrollView {
    LazyVStack(alignment: .leading, spacing: 16) {
        HeaderSection(snapshot: store.snapshot)
        PrimaryMetricsSection(snapshot: store.snapshot)
        ModelsAndSlotsSection(snapshot: store.snapshot)
        MemoryAndProcessSection(snapshot: store.snapshot)
        TrustSection(snapshot: store.snapshot)
        RecentEventsSection(snapshot: store.snapshot, showAll: $showAllEvents)
        AdvancedSection(snapshot: store.snapshot, isExpanded: $advancedExpanded)
        FooterSection(refresh: store.refresh, quit: store.quit)
    }
    .padding(16)
}
.frame(width: 420)
.frame(maxHeight: 680)
```

Define `HeaderSection`, `PrimaryMetricsSection`, `ModelsAndSlotsSection`,
`MemoryAndProcessSection`, `TrustSection`, `RecentEventsSection`, and
`FooterSection` as private focused views in `MonitorPopover.swift`; the five
reusable cross-section components remain in their dedicated files listed above.

Primary metrics are a two-column `Grid`: current model, derived token rate, requests, and tokens. Usage gaps follows as its literal counter and receives orange emphasis only when greater than zero. Loaded and warm lists are separate. The memory section shows exact active/cache/total GiB and uses only `active / total` for `ProgressView`. Recent events show 20 until `Show all` is selected, then at most 100. Advanced starts collapsed.

Every unavailable branch renders `Unavailable — reason`; exposed empty model lists render `None reported`. Use `.monospacedDigit()` for counters/rates/memory/PID/time, `.textSelection(.enabled)` for paths and identifiers, semantic colors/materials, and adjacent text for every color.

- [ ] **Step 5: Add accessibility and reduced-motion behavior**

Assign combined accessibility labels to each metric and slot. Preserve visual order as reading order. Use `@Environment(\.accessibilityReduceMotion)` and suppress optional state-transition animation when true. Long model and event text must wrap or truncate within 420 points and use `.help(fullText)`.

- [ ] **Step 6: Run tests and build**

```bash
swift test --filter MonitorPresentationTests
swift test
swift build
```

Expected: all advanced labels and explicit gaps are covered, the package builds without warnings, and no source-access code appears in `Sources/DarkbloomMonitor`.

- [ ] **Step 7: Commit the complete popover**

```bash
git add Sources/DarkbloomMonitor Sources/DarkbloomTelemetry/TelemetrySnapshot.swift Tests/DarkbloomTelemetryTests/MonitorPresentationTests.swift
git commit -m "feat: render complete darkbloom popover"
```

---

### Task 8: Verify Live Behavior, Privacy Boundaries, and Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/TELEMETRY_CONTRACT.md`
- Modify: `docs/PRESENTATION_OPTIONS.md`
- Add or modify tests only when a verification gap identifies a reproducible defect.

**Interfaces:**
- Consumes: the complete executable and the live local Darkbloom 0.8.15 installation.
- Produces: verified runtime evidence, final usage/troubleshooting documentation, and a clean local repository; no publication or deployment.

- [ ] **Step 1: Run the full mechanical verification gate**

```bash
swift test
swift build
git -c core.fsmonitor=false diff --check
git -c core.fsmonitor=false status --short --branch
```

Expected: all tests pass, the build exits zero without warnings, the diff check is empty, and status lists only the documentation changes intended for this task.

- [ ] **Step 2: Audit the source boundary statically**

```bash
rg -n 'URLSession|import Network|NWConnection|NWTCP|socket\(|auth_token|provider\.toml|darkbloom local|darkbloom verify|darkbloom doctor' Sources Package.swift
rg -n 'Data\(contentsOf:|FileHandle\(forReadingFrom:' Sources/DarkbloomTelemetry
rg -n 'Process\(' Sources/DarkbloomTelemetry
```

Expected: no network API or credential/config read exists. Every file read resolves from `DarkbloomSourcePolicy`; every process launch is contained in `ProcessRunner.swift`; the only Darkbloom arguments are `["status"]`; the only other executable is `/usr/bin/log` with the fixed local stream arguments.

- [ ] **Step 3: Compare the popover with live direct sources**

Capture a fresh read-only reference immediately before opening the popover:

```bash
jq '{schema,version,current_model,warm_models,pid,capacity,slots,inference_active,started_at,written_at,stats,trust,process_identity}' ~/.darkbloom/daemon-state.json
jq '{schema,models,updated_at}' ~/.darkbloom/loaded-models.json
~/.darkbloom/bin/darkbloom status
```

Do not print `attestation_public_key`, open `auth_token`, or run `darkbloom local`. Launch `swift run DarkbloomMonitor`, open the actual menu-bar popover, and compare every direct field, loaded/warm distinction, slot value, status-only Advanced row, and unavailable MTP reason with the reference output. Confirm the derived token rate says unavailable while idle and says `derived` only after a positive same-process counter delta is observed.

- [ ] **Step 4: Inspect the actual visible app**

At normal macOS scale, inspect the popover in the current appearance, then use Xcode's environment override or a SwiftUI preview harness to inspect the opposite light/dark color scheme without changing global system settings. Check:

- 420-point width and bounded 680-point scrolling.
- Header status text remains understandable if menu-bar tint renders monochrome.
- Long model names and three-line event messages do not widen or clip the popover.
- Advanced disclosure and Show all stay within the scroll surface.
- Keyboard traversal reaches Refresh Now, Show all, Advanced, and Quit.
- VoiceOver labels state the trust/menu status and each metric's label plus value.
- Reduce Motion removes optional transitions.

If a visual defect is found, write a failing presentation/formatting test where possible, correct the smallest component, rerun `swift test` and `swift build`, and repeat the visible check.

- [ ] **Step 5: Check the running monitor has no network sockets**

With the monitor still running, identify only its executable PID and inspect it:

```bash
MONITOR_PID=$(pgrep -nx DarkbloomMonitor)
test -n "$MONITOR_PID"
lsof -nP -a -p "$MONITOR_PID" -i
```

Expected: `lsof` prints no Internet sockets for the monitor. Do not inspect or stop the Darkbloom provider process. Quit the monitor through its own footer after the check.

- [ ] **Step 6: Update the documentation to match verified behavior**

README sections must include: requirements, `swift run` and Xcode launch, source paths/cadences, field inventory link, exact token-rate formula, freshness thresholds, privacy boundary, unavailable-field semantics, unified-log privacy redaction, troubleshooting for missing CLI/state/logs, and a statement that the app has no provider controls.

Update `ARCHITECTURE.md` from planned to implemented data flow, including actor/store ownership and cancellation. Mark Option A selected in `PRESENTATION_OPTIONS.md`. Update `TELEMETRY_CONTRACT.md` only for differences proved by the live run; retain explicit gaps for request-level timing, prompt tokens, MTP reason, and non-Darkbloom system metrics.

- [ ] **Step 7: Run the final verification gate and commit**

```bash
swift test
swift build
git -c core.fsmonitor=false diff --check
git -c core.fsmonitor=false status --short --branch
git add README.md docs Sources Tests Package.swift
git -c core.fsmonitor=false diff --cached --check
git commit -m "docs: finish darkbloom monitor verification"
git -c core.fsmonitor=false status --short --branch
```

Expected: tests and build pass freshly, the staged diff is clean, the local commit succeeds, and the final worktree is clean. Report any runtime check that could not be performed as an open verification gap; do not convert a blocked visual, accessibility, file-access, or socket check into a pass.
