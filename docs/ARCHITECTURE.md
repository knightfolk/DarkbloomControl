# Architecture Notes

## Target structure

The Swift 6 package has two targets:

- `DarkbloomTelemetry` is UI-independent. It owns fixed source policy,
  acquisition, parsing, normalization, freshness, derivation, authenticated
  earnings reads, compact SQLite persistence, diagnostics, the narrow provider
  control service, and the immutable values consumed by the app.
- `DarkbloomMonitor` owns the AppKit/SwiftUI lifecycle and presentation. It is
  an accessory application built around a window-style `MenuBarExtra`; it has no
  Dock icon or ordinary window.

The telemetry library does not import SwiftUI or AppKit, and the views never
read a file or launch a process directly.

## Implemented data flow

1. `DarkbloomSourcePolicy` resolves only the approved home-directory files,
   including the fixed provider config path, fixes all byte/time limits, and
   exposes typed shell-free commands for the allowlisted Darkbloom operations
   and the local `/usr/bin/log stream` predicate.
2. `LocalTelemetrySource` reads schema-1 state and loaded models, retries a
   transient daemon-state decode once after 100 milliseconds, reads only the
   final 128 KiB of the legacy log, and parses the fixed status result.
3. `CappedProcessRunner` is the only code that constructs `Process`. Telemetry
   `status` reads and candidate-config validation retain at most 256 KiB and
   time out after three seconds. Provider catalog/list reads use the separate
   1 MiB mutation cap and a 15-second bound; lifecycle and model removal use
   1 MiB and 30 seconds; a model download uses 1 MiB and a six-hour bound.
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
7. `AuthenticatedEarningsClient` performs a fixed-endpoint account GET every
   ten minutes, incrementally writes inference work and `base_reward` events to
   separate hourly tables plus changed hourly balance samples using one
   earning-ID high-water mark,
   and uses the public 24-hour leaderboard aggregate when the 1,000-row account
   history cap cannot cover the full window.
8. `@MainActor MonitorStore` subscribes once, observes native thermal-state
   notifications, accumulates unique positive token-rate samples for the current
   app session, publishes completed-job summaries from SQLite, coalesces account
   refresh work, and owns orderly shutdown. The views only format normalized
   data and invoke the controller-owned Settings window or orderly Quit path.
9. `LocalProviderConfigStore` reads the fixed config, permits changes only to
   top-level `enabled_models` and `preload_models`, validates a UUID-named
   sibling candidate, and retains one fixed backup after publication.
   `ProviderControlService` owns catalog/list/download/remove/start/stop/restart
   commands; `ProviderControlStore` serializes their UI state. A config save
   reports restart-required rather than restarting the provider itself.

   Its revision checks, bounded advisory locks, and atomic replacement
   coordinate cooperating writers only. A noncooperating writer that keeps an
   open descriptor can still race publication. On an observed external change
   or lost recovery certainty, the store rejects the save or preserves the
   visible versions; it does not claim unconditional serialization or success.

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

authenticated earnings --> 10-minute fixed GET --> incremental hourly SQLite aggregates
                                                   --> today + covered 7-day job metrics
                                                   --> menu presentation

fixed provider TOML --> LocalProviderConfigStore --> candidate validation --> fixed backup
                                           |
                                           v
                              ProviderControlService --> shared ProviderControlStore
                                           |
                                           v
                              Settings Models + popup lifecycle controls
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

The provider surface is an exact allowlist: the fixed `provider.toml`,
catalog/list/status, download/remove/start/stop/restart, a UUID-named sibling
candidate, and one fixed backup. No other config field may change; credentials,
account commands, launchd internals, and direct cache mutation remain forbidden.
Production commands use executable and argument values directly, never a shell.
Paths printed by `darkbloom status` are inert display strings and are never
followed. The monitor reads `auth_token` only for the fixed authenticated
account-earnings GET and never logs, displays, or persists it. The state
`attestation_public_key` and unknown fields are ignored. Log messages are
untrusted literal text without link activation or command execution; a
unified-log `<private>` value becomes an explicit privacy-redaction placeholder.

Networking is limited to two read-only HTTPS GET paths on `api.darkbloom.dev`:
authenticated account earnings and the public 24-hour leaderboard. SQLite keeps
separate hourly inference-work and online-reward aggregates plus balances with
user-only permissions; it excludes account IDs, provider keys, and credential
material. The source policy does not offer an arbitrary command interface.

Download/Delete, Enable/Disable, and Preload/Unpreload are independent. Start
passes enabled models as repeated `--model` arguments to bypass the CLI picker.
Stop and Restart check provider activity, but that read may be unknown and can
change before the command runs. Active or unknown activity therefore requires a
user's explicit destructive override; this is a customer-impact warning, not an
atomic no-interruption guarantee.

Configuration saves preserve unrelated bytes and comments only within their
observed/revalidated source revision. Bounded advisory locks require a
cooperating writer to reopen and revalidate the path after contention; they do
not serialize a noncooperating writer retaining an open descriptor. Detected
changes reject the save. If recovery cannot establish which version is current,
the store preserves visible versions and reports the bounded recovery failure
rather than representing publication as safe or complete.

## Popover presentation boundary

The 400-by-600-point popover intentionally renders current and session-average
throughput, today and covered seven-day job metrics, model-state capsules, a
labeled Settings control, an icon-only door control for Quit, and compact
Start/Stop/Restart controls. The Settings window has General and Models tabs;
the latter separates My Catalog and Available models and makes download/delete
independent from enable/preload settings.
Model presentation is derived from the enabled-model filter plus loaded, warm,
slot, and current-model state. Green
means active, yellow means loaded but idle, and gray means available but
unloaded. `StatusItemController` owns an in-process Settings window whose
SwiftUI view owns the persisted menu-bar metric picker, avoiding delegation to
another registered app bundle. Diagnostic telemetry remains in the library and
tests rather than being exposed through disclosure groups.

## Failure and freshness model

Source availability is `available`, `stale(last good value, reason)`, or
`unavailable(reason)`. One source failing cannot erase another. Structured state
and loaded models turn stale after 10 seconds using `written_at` and `updated_at`;
CLI status turns stale after 60 seconds using acquisition time. Process identity
changes reset token-rate history immediately. Unified-stream termination and
finite-source errors become stable, source-specific diagnostics.
