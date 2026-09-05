# Architecture Notes

## Target structure

The Swift 6 package has two targets:

- `DarkbloomTelemetry` is UI-independent. It owns fixed source policy,
  acquisition, parsing, normalization, freshness, derivation, authenticated
  earnings reads, compact SQLite persistence, diagnostics, the narrow provider
  control service, and the immutable values consumed by the app.
- `DarkbloomMonitor` owns the AppKit/SwiftUI lifecycle and presentation. It is
  an accessory application built around an `NSStatusItem` and `NSPopover`, with
  SwiftUI content hosted inside the popover and a retained, resizable Settings
  `NSWindow`. It has no Dock icon or main/document window.

The telemetry library does not import SwiftUI or AppKit, and the views never
read a file or launch a process directly.

## Implemented data flow

1. `DarkbloomSourcePolicy` resolves only the approved home-directory files,
   including the fixed provider config path, fixes all byte/time limits, and
   exposes typed shell-free commands for the allowlisted Darkbloom operations
   and the local `/usr/bin/log stream` predicate. `LocalEndpointDiscovery` is a
   separate, bounded control-source reader for `~/.darkbloom/local.json`; it
   does not become part of the telemetry file allowlist.
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
   Daemon freshness uses Darkbloom's embedded `written_at`. Loaded-model and
   status freshness use successful acquisition time; loaded-model `updated_at`
   is a residency-change marker and is checked against the current daemon start.
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
   top-level `enabled_models`, `preload_models`, and `max_model_slots`,
   validates a UUID-named sibling candidate, and retains one fixed backup after
   publication. `ProviderControlService` owns catalog/list/download/remove,
   start/stop/restart, and capability-probed protected model load/retire
   operations; `ProviderControlStore` serializes their UI state. A config save
   reports restart-required rather than restarting the provider itself.

   Its revision checks, bounded advisory locks, and atomic replacement
   coordinate cooperating writers only. A noncooperating writer that keeps an
   open descriptor can still race publication. On an observed external change
   or lost recovery certainty, the store rejects the save or preserves the
   visible versions; it does not claim unconditional serialization or success.
10. `ProviderControlService` requires a finite, current daemon heartbeat and a
    successful loaded-model acquisition. The loaded-model mutation timestamp
    must be finite, not in the future, and not predate the daemon start. Save
    and Download reread model sources without stale fallback
    at the service boundary; Delete additionally requires fresh residency
    before it can construct a remove command. Typed source states reach the UI
    for control gating, while sanitized diagnostics preserve only fixed safe
    error distinctions. Settings does not relabel an unchanged successful
    snapshot as stale on a view timer; the destructive service performs the
    authoritative fresh preflight again when Delete is actually requested.
11. After a successful lifecycle command, `ProviderControlStore` awaits an
    immediate `MonitorStore` telemetry/status refresh before refreshing its
    own provider-control snapshot. The popup withholds model pills unless both
    telemetry model sources and provider-control residency sources are fresh.
12. `ProviderWarmupPolicy` is the shared fail-closed gate for manual and
   automatic Warm operations. It requires a unique downloaded saved-enabled
   target, fresh catalog/local-model/daemon/loaded evidence, a current loopback
   discovery record, an applied live slot cap, and the protected provider
   capability. One-slot switching retires only idle residents before loading;
   two-slot switching loads into an available slot before requesting exact idle
   retirement of the previous model.
13. `PublicNetworkCapacityClient` polls the fixed public per-model capacity
    endpoint every 30 seconds. Its last-good value is retained for display but
    is actionable only while fresh; `MonitorStore` rejects older overlapping
    responses. Network demand is context for model selection, never a local
    job-progress or earnings measurement.

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
                              NSStatusItem --> NSPopover --> SwiftUI MonitorPopover

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

~/.darkbloom/local.json --> LocalEndpointDiscovery -- protected loopback control
public model capacity --> PublicNetworkCapacityClient --> MonitorStore
                                                               |
                                                               v
                                                  demand rows / automatic evaluator
```

## Ownership and cancellation

Only one acquisition per source can be active. Periodic and manual refreshes
join an existing per-source task rather than overlap it. `ProviderControlStore`
owns the current provider operation and cancels it when the monitor is closing.
Cancellation before a protected load or retire request is a no-op; after a
mutation may have started, the warmup path performs fresh telemetry/control
reconciliation and invalidates actionable state if that reconciliation cannot
establish the outcome.

The user-facing Quit path awaits `MonitorStore.stop()` before asking AppKit to
terminate the monitor. Shutdown cancels polling and freshness tasks, cancels
and awaits the unified-log iterator, closes its pipes, terminates only the
monitor-owned `/usr/bin/log` child, and finishes snapshot subscribers. The
AppDelegate termination callback cancels automatic switching and the current
control task, then starts `MonitorStore.stop()` asynchronously; that callback
is not a guarantee that an in-flight provider HTTP request or reconciliation
will finish before the process exits. No shutdown path targets the Darkbloom
provider process; only an explicit Stop or Restart action can do that.

## Trust and privacy boundaries

The provider surface is an exact allowlist: the fixed `provider.toml` (only
`enabled_models`, `preload_models`, and `max_model_slots`),
catalog/list/status, download/remove/start/stop/restart, a UUID-named sibling
candidate, one fixed backup, and the separately validated local endpoint
record. The protected loopback surface is limited to an authenticated
capability GET plus exact-model load-without-eviction and idle-only retire POSTs.
No other config field may change; credentials, account commands, launchd
internals, direct cache mutation, remote coordinator mutation, and arbitrary
local HTTP routes remain forbidden. Production commands use executable and
argument values directly, never a shell. Paths printed by `darkbloom status`
are inert display strings and are never followed. The monitor reads `auth_token`
only for the fixed authenticated account-earnings GET and reads the local
endpoint API key only for the bounded protected request; neither is logged,
displayed, or persisted. The state `attestation_public_key` and unknown fields
are ignored. Log messages are untrusted literal text without link activation or
command execution; a unified-log `<private>` value becomes an explicit
privacy-redaction placeholder.

Networking has three fixed public HTTPS GET paths on `api.darkbloom.dev`:
authenticated account earnings, the public 24-hour leaderboard, and public
per-model capacity. The protected model-control requests are authenticated
HTTP loopback calls discovered from the current provider run, not remote
coordinator calls. SQLite keeps separate hourly inference-work and online-
reward aggregates plus balances with user-only permissions; it excludes
account IDs, provider keys, and credential material. The source policy does not
offer an arbitrary command interface.

Download/Delete, Enable/Disable, Preload/Unpreload, and Warm are independent.
Start passes enabled models as repeated `--model` arguments to bypass the CLI
picker. Protected Warm never invokes Stop or Restart and never unloads an
active customer model.
Stop and Restart check provider activity, but that read may be unknown and can
change before the command runs. Active or unknown activity therefore requires a
user's explicit destructive override; this is a customer-impact warning, not an
atomic no-interruption guarantee.

In one-model capacity, the current idle resident retires before the target
loads, so a safe switch has a cold-load availability gap. If target loading
fails after retirement, the service reconciles fresh state and reports the
partial outcome; it does not claim an automatic rollback. In two-model
capacity, the second slot is shared with coordinator work rather than reserved
for the monitor. A coordinator-prefetched or otherwise unknown resident
consumes that slot. The target loads first beside an existing customer job, and
the previous model retires only if the provider confirms it is still idle. If
retirement is refused because work arrived, both models remain resident.

Two-model staging requires the lower of provider-derived free capacity and live
whole-system reclaimable memory to satisfy
`min(max(0, total - gpuActive - gpuCache), systemAvailable) >=
targetSize * 1.2 + reserve`, where reserve is 8-24 GiB (default 16 GiB).
Missing or stale provider/system evidence, a full slot set, insufficient
headroom, an unapplied slot-cap change, or a client that may evict causes the
operation to wait or fail closed.

For provider-control safety decisions, the daemon heartbeat must be finite, no
more than ten seconds old, and not in the future. Loaded-model evidence requires
a current successful read; its mutation timestamp must be finite, not future,
and no older than the current daemon start. Stale or future activity is unknown;
stale, future, invalid, or unavailable residency blocks Delete before a CLI
remove command. Save and Download reread catalog/local
sources without stale fallback immediately before acting, and their UI gates are
driven by typed source state rather than rendered diagnostic text. The service
still performs those validations when called outside the UI.

After lifecycle completion, the shared control store requests an immediate
telemetry/status refresh and refreshes its control snapshot. Popup model pills
are withheld when their independent freshness conditions are not satisfied.
Control diagnostics redact home paths and credential-shaped values, and expose
only fixed safe categories for config and model-control failures. Raw or
unbounded command output is not rendered, except for one latest sanitized
download-progress line from stdout or stderr with a 4,096-byte input bound.
Model-row actions carry
target-specific accessibility labels and hints. Lifecycle controls carry labels,
help text, and identifiers; their customer-impact explanation is the explicit
Stop/Restart confirmation alert.

Configuration saves preserve unrelated bytes and comments only within their
observed/revalidated source revision. Bounded advisory locks require a
cooperating writer to reopen and revalidate the path after contention; they do
not serialize a noncooperating writer retaining an open descriptor. Detected
changes reject the save. If recovery cannot establish which version is current,
the store preserves visible versions and reports the bounded recovery failure
rather than representing publication as safe or complete.

## Popover presentation boundary

The 400-by-600-point popover intentionally renders current and session-average
throughput, today and covered seven-day job metrics, model-state capsules,
enabled-model network-demand rows, a labeled Settings control, an icon-only
door control for Quit, and compact Start/Stop/Restart controls. The Settings
window has General and Models tabs; the latter separates My Catalog and
Available models, makes download/delete independent from enable/preload
settings, and exposes one- versus two-model capacity plus the two-model
headroom reserve. Automatic switching is default-off.
Model presentation is derived from the enabled-model filter plus loaded, warm,
slot, and current-model state. Green
means active, yellow means loaded but idle, and gray means available but
unloaded. A Warm action reports preparing, loading or staging, idle retirement,
and authoritative reconciliation; it distinguishes the one-slot cold-load
gap from two-slot load-before-retire behavior. `StatusItemController` owns an in-process Settings window whose
SwiftUI view owns the persisted menu-bar metric picker, avoiding delegation to
another registered app bundle. Diagnostic telemetry remains in the library and
tests rather than being exposed through disclosure groups.

## Failure and freshness model

Source availability is `available`, `stale(last good value, reason)`, or
`unavailable(reason)`. One source failing cannot erase another. Structured state
turns stale after 10 seconds using `written_at`; a loaded-model read turns stale
10 seconds after its acquisition if polling stops or fails. Its `updated_at`
may remain old while residency is unchanged. CLI status turns stale after 60
seconds using acquisition time. Process identity
changes reset token-rate history immediately. Unified-stream termination and
finite-source errors become stable, source-specific diagnostics.

Public capacity is polled every 30 seconds and remains actionable only for 120
seconds, with no more than five seconds of future skew. An older overlapping
response is discarded. Warm preflight requires fresh catalog, local-model,
daemon, and loaded-model evidence, a current loopback discovery record, a
protected capability snapshot, and a live slot cap matching the saved setting.
Unknown or unavailable system memory is insufficient for two-slot staging.
After any load or retire request, fresh local residency is authoritative:
success means the target is resident; otherwise the operation remains blocked,
failed, or outcome-uncertain rather than being presented as complete.
