# Architecture Notes

## Target structure

The Swift 6 package has two targets:

- `DarkbloomTelemetry` is Foundation-only. It owns fixed source policy,
  acquisition, parsing, normalization, freshness, derivation, diagnostics, and
  the immutable `TelemetrySnapshot` consumed by the app.
- `DarkbloomMonitor` owns the AppKit/SwiftUI lifecycle and presentation. It is
  an accessory application built around a window-style `MenuBarExtra`; it has no
  Dock icon or ordinary window.

The telemetry library does not import SwiftUI or AppKit, and the views never
read a file or launch a process directly.

## Implemented data flow

1. `DarkbloomSourcePolicy` resolves only the approved home-directory files,
   fixes all byte/time limits, and exposes typed commands for `darkbloom status`
   and the local `/usr/bin/log stream` predicate.
2. `LocalTelemetrySource` reads schema-1 state and loaded models, retries a
   transient daemon-state decode once after 100 milliseconds, reads only the
   final 128 KiB of the legacy log, and parses the fixed status result.
3. `CappedProcessRunner` is the only code that constructs `Process`. Finite
   child output is capped at 256 KiB and times out after three seconds.
   `UnifiedLogStreamer` owns its long-lived `/usr/bin/log` child and incrementally
   frames capped JSON lines.
4. Actor-owned `TelemetryService` starts independent state, loaded-model,
   legacy-log, and status polling tasks at 2, 2, 5, and 30 seconds. A separate
   one-second freshness heartbeat publishes only availability transitions, and
   the unified stream feeds normalized events independently.
5. Each successful read replaces only its own last-good group. A failure keeps
   the group as stale with a diagnostic; a first-read failure is unavailable.
   Structured and loaded freshness use Darkbloom's embedded timestamps, while
   status freshness uses successful acquisition time.
6. The service validates process identity before deriving a rate from successive
   token counters and state-write timestamps. It retains at most 100 deduplicated
   qualifying events and publishes immutable snapshots through a buffering-newest
   async stream.
7. `@MainActor MonitorStore` subscribes once, publishes completed snapshots to
   SwiftUI, coalesces manual refresh work, and owns orderly shutdown. The views
   only format normalized data and invoke store actions.

```text
approved files -----> LocalTelemetrySource --\
darkbloom status ---> CappedProcessRunner -----+--> TelemetryService actor
/usr/bin/log stream -> UnifiedLogStreamer -----/          |
                                                           v
                                               immutable snapshots
                                                           |
                                                           v
                                                @MainActor MonitorStore
                                                           |
                                                           v
                                              SwiftUI MenuBarExtra popover
```

## Ownership and cancellation

Only one acquisition per source can be active. Periodic and manual refreshes
join an existing per-source task rather than overlap it. `MonitorStore.quit()`
awaits `TelemetryService.stop()` before asking AppKit to terminate the monitor.
Shutdown cancels polling and freshness tasks, cancels and awaits the unified-log
iterator, closes its pipes, terminates only the monitor-owned `/usr/bin/log`
child, and finishes snapshot subscribers. The Darkbloom provider process is
never targeted.

## Trust and privacy boundaries

The monitor does not read `provider.toml`, `auth_token`, model weights, caches,
or local endpoint credentials. Paths printed by `darkbloom status` are inert
display strings and are never followed. The state `attestation_public_key` and
unknown fields are ignored. Log messages are untrusted literal text without
link activation or command execution; a unified-log `<private>` value becomes
an explicit privacy-redaction placeholder.

There is no networking dependency or entitlement. The source policy does not
offer an arbitrary command interface, and the application does not expose any
provider-control action.

## Failure and freshness model

Source availability is `available`, `stale(last good value, reason)`, or
`unavailable(reason)`. One source failing cannot erase another. Structured state
and loaded models turn stale after 10 seconds using `written_at` and `updated_at`;
CLI status turns stale after 60 seconds using acquisition time. Process identity
changes reset token-rate history immediately. Unified-stream termination and
finite-source errors become stable, source-specific diagnostics.
