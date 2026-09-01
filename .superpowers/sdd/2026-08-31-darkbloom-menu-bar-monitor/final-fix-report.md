# Final Fix Report: Bounded Finite Process Shutdown

- Base SHA: `ae0b23031e21602483addcaf683d927e5fa04379`
- Fix commit SHA: `0080c8be286097795f9990b2cce6949022781589`
- Fix commit: `fix: bound finite telemetry process shutdown`

## Scope

This round closes the final-review process-lifecycle blocker and the three
minor contract gaps. It keeps the existing source allowlist, three-second
production timeout, freshness rulings, provider process, and UI lifecycle
contract unchanged.

## RED evidence

- Against the pre-fix `ae0b230` implementation, the TERM-resistant finite
  timeout regression did not complete within its one-second bound. The outer
  cancellation regression also did not complete and observed a nonzero-exit
  result instead of `CancellationError`.
- The pre-fix service stop returned while the controlled finite status source
  was still active; both concurrent stop callers could therefore return before
  acquisition cleanup.
- The new pipe-close cleanup assertion first produced the expected compile RED:
  `ProcessCleanupState` had no read/write-handle fields. The missing fields were
  then implemented and the test turned GREEN.
- The baseline parser returned malformed slot-posture text as `stateAge`, and
  the baseline token-rate subtraction could trap at `Int64` extremes. The new
  hardening tests capture those failures and the non-finite arithmetic cases.

## GREEN implementation and ownership reasoning

`CappedProcessRunner` now wraps the entire launch/wait path in a task
cancellation handler. Cancellation is recorded before launch when necessary and
is rechecked after process completion; caller cancellation therefore remains a
`CancellationError`, while a timeout remains `ProcessRunnerError.timedOut` when
the caller did not cancel.

`ProcessSession.didLaunch()` captures the `Process` identifier only after
`process.run()` succeeds. Every termination path is serialized by the session
lock, sends `Process.terminate()` (SIGTERM) to that owned `Process`, waits a
250-millisecond monotonic grace period, and sends SIGKILL only when the same
captured PID is still reported as running by that same `Process` object. It then
calls `waitUntilExit()` and marks the session terminated. No PID discovery,
process-group signalling, provider signalling, or arbitrary-PID cleanup was
added.

The parent closes its unused stdout/stderr write handles immediately after
launch. Reader accounting is idempotent and lock guarded. Normal readers get a
short drain window; if an inherited descendant keeps a pipe open, the session
finishes its reader accounting after 250 milliseconds so a finite acquisition
cannot wait forever for EOF. Cleanup clears both readability handlers and the
termination handler and closes both read and write handles. Combined stdout and
stderr bytes are checked under one lock against the single configured cap.

`TelemetryService.stop()` now marks the actor stopped, cancels all polling,
refresh, manual-refresh, freshness, and unified-stream tasks, finishes snapshot
continuations, and coalesces callers onto one shutdown task. That task awaits
every captured polling/refresh/manual task and the unified iterator before
returning. Repeated calls after completion and concurrent calls during cleanup
are safe.

The unified stream's owned-child fallback now also checks its captured PID
before SIGKILL and uses the same monotonic grace interval. Its existing
end-to-end cancellation test continues to require handler/handle cleanup and
confirmed child exit.

## Contract fixes

- `StatusParser` extracts `stateAge` only from the expected `state written `
  posture shape; malformed and incomplete posture text remains unavailable.
- `TelemetryDeriver` uses `subtractingReportingOverflow`, rejects non-finite or
  non-positive elapsed time, and rejects non-finite derived output with stable
  unavailable reasons. Int64-extreme and non-finite timestamp tests cover the
  guards.
- Both unified-log fixture tests explicitly assert that the parsed timestamp is
  non-nil.

## Live-status diagnosis

The unlocked GUI harness that showed repeated status timeouts was built from
the pre-fix `ae0b230` runner. That runner left the parent pipe write ends open
until its reader wait completed. A finite `darkbloom status` child could exit
while the GUI-side runner remained waiting for pipe completion, which explains
the GUI-only timeout/stale path even though the direct shell command and a
live-runner probe completed in approximately 1.8–2.2 seconds. The old harness
also showed the extra finite-runner pipe descriptors during the stuck path.

An instrumented baseline copy completed the same production status path in
about 1.90 seconds, establishing that the documented three-second timeout is
feasible. The fixed production `LocalTelemetrySource` launch path, including
the `@MainActor` app context, completed in the controller's live probe in about
1.85–1.99 seconds. The permanent deterministic tests
`productionStatusAcquiresFromMainActor`, `closesHandlesAfterFiniteCompletion`,
and `boundsReaderCleanupAfterOwnedExit` protect this diagnosis and the pipe
lifecycle. The three-second timeout was not lengthened.

The controller also verified the footer Quit action by direct button click:
the harness and its owned `/usr/bin/log` child exited in under one second while
Darkbloom provider PID 10004 remained running. The earlier keyboard Return
attempt is not treated as a defect. Existing service-plus-real-stream shutdown
coverage remains in `stopWaitsForUnifiedIteratorCleanup` and
`cancelsAndCleansUp`.

## Files changed

- `Sources/DarkbloomTelemetry/ProcessRunner.swift`
- `Sources/DarkbloomTelemetry/StatusParser.swift`
- `Sources/DarkbloomTelemetry/TelemetryDeriver.swift`
- `Sources/DarkbloomTelemetry/TelemetryService.swift`
- `Tests/DarkbloomTelemetryTests/ContractHardeningTests.swift`
- `Tests/DarkbloomTelemetryTests/ProcessRunnerTests.swift`
- `Tests/DarkbloomTelemetryTests/TelemetryServiceTests.swift`
- `Tests/DarkbloomTelemetryTests/UnifiedLogTests.swift`

## Verification

- `swift test --filter ProcessRunnerTests`: 9 tests passed, including
  TERM-resistant timeout, outer cancellation, global cap, all-handle cleanup,
  and inherited-pipe bounded cleanup.
- `swift test --filter 'TelemetryServiceTests|ContractHardeningTests|UnifiedLogTests'`:
  44 tests in 3 suites passed.
- Three repeated focused race runs covering process runner, service stop, and
  unified cancellation: all passed (14 tests per run).
- `swift test`: 76 tests in 8 suites passed, 0 failures.
- `swift build`: completed without warnings.
- `git -c core.fsmonitor=false diff --check`: clean before staging.
- Cached diff check before the fix commit: clean.
- Static privacy/source-boundary scan: no `URLSession`, Network framework,
  socket API, `auth_token`, `provider.toml`, or forbidden Darkbloom command; file
  reads remain policy-resolved and process launches remain in
  `ProcessRunner.swift`.
- Exact verification launches 22260/42258 and recorded children 22531/42510
  were intentionally stopped and confirmed absent. Baseline harness 8331/8332
  and provider 10004 were preserved.

## Self-review and remaining gaps

The implementation does not read credentials/configuration, open network
sockets, write under Darkbloom state directories, or change provider state. It
does not alter the embedded-timestamp freshness rulings or manufacture token
traffic. Positive token-rate rendering was not observed naturally during the
bounded live windows, so no positive-rate claim is made. The optional redesign
of arbitrary library-client deinitialization was not expanded; the concrete
service and owned-process shutdown paths are awaited and covered.

The bounded 250-millisecond reader grace intentionally prioritizes returning a
finite acquisition over waiting for an unrelated descendant's inherited pipe;
the direct owned child is always reaped before the runner returns.
