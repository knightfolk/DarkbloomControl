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
   exposes typed shell-free commands for the allowlisted official Darkbloom
   operations and the local `/usr/bin/log stream` predicate. The monitor does
   not discover or call private provider-control endpoints.
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
   publication. `ProviderControlService` owns only the official CLI's
   catalog/list/download/remove and start/stop/restart operations;
   `ProviderControlStore` serializes their UI state. A config save reports
   restart-required rather than restarting the provider itself. The official
   CLI does not provide a supported monitor-side warm, retire, or live-switch
   operation.

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
    own official-CLI snapshot. The popup withholds model pills unless the
    official telemetry model sources are fresh.
12. `PublicNetworkCapacityClient` polls the fixed public per-model capacity
   endpoint every 30 seconds. Its last-good value is retained for display but
   is actionable only while fresh; `MonitorStore` rejects older overlapping
   responses. Network demand is context for model selection, never a local
   job-progress or earnings measurement. It is informational only: it does not
   authorize or trigger local model loading, unloading, or switching.

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

public model capacity --> PublicNetworkCapacityClient --> MonitorStore
                                                               |
                                                               v
                                                  demand rows / opportunity context
```

## Ownership and cancellation

Only one acquisition per source can be active. Periodic and manual refreshes
join an existing per-source task rather than overlap it. `ProviderControlStore`
owns the current official-CLI operation and cancels it when the monitor is
closing. Provider lifecycle completion is reconciled with fresh official
telemetry; the monitor does not attempt a separate residency mutation or
private control request.

The user-facing Quit path awaits `MonitorStore.stop()` before asking AppKit to
terminate the monitor. Shutdown cancels polling and freshness tasks, cancels
and awaits the unified-log iterator, closes its pipes, terminates only the
monitor-owned `/usr/bin/log` child, and finishes snapshot subscribers. The
AppDelegate termination callback cancels the current control task, then starts
`MonitorStore.stop()` asynchronously; that callback is not a guarantee that an
in-flight provider command or reconciliation will finish before the process
exits. No shutdown path targets the Darkbloom provider process; only an explicit
Stop or Restart action can do that.

## Trust and privacy boundaries

The provider surface is an exact allowlist: the fixed `provider.toml` (only
`enabled_models`, `preload_models`, and `max_model_slots`),
catalog/list/status, download/remove/start/stop/restart, a UUID-named sibling
candidate, one fixed backup, the documented local-endpoint start flags, the
`local --json` standalone discovery read, and the provider-owned local token
file for an explicit copy action. No other config field may change; credentials,
account commands, launchd internals, direct cache mutation, remote coordinator
mutation, private provider-control routes, and arbitrary local HTTP routes
remain forbidden — the monitor configures the provider's own official endpoint
through documented start flags and never opens a listening socket itself. The
chat feature (see the chat routing section below) is an outbound HTTP client
only: it connects to the user's own hosting endpoint or one fixed public host
and never listens. Production
commands use the official executable and argument values directly, never a
shell. Paths printed by `darkbloom status` are inert display strings and are
never followed. The monitor reads `auth_token` only for the fixed authenticated
account-earnings GET; it is never logged, displayed, or persisted. The state
`attestation_public_key` and unknown fields are ignored. Log messages are
untrusted literal text without link activation or command execution; a
unified-log `<private>` value becomes an explicit privacy-redaction
placeholder.

Hosting settings (September 24, 2026) apply the official CLI's unified
local-endpoint mode — `--local-endpoint`, `--port`, and `--bind` appended to
the existing non-interactive start command — as monitor-owned application
preferences persisted in user defaults, never as `provider.toml` fields. The
default is no endpoint with a loopback bind; any non-loopback bind requires
an explicit confirmation dialog before the start command runs, and the
documented LAN warning (no TLS, no rate limiting, bearer token stays on) is
shown at selection time. `--no-auth` does not exist in the command mapping,
so bearer-token authentication cannot be disabled through the monitor.
Standalone `--local` direct mode is refused by the control service by
construction: the official CLI runs it as an unsupervised foreground process
this app's bounded finite runner cannot own or terminate, so the settings
surface represents it as unavailable with a fixed reason instead of
pretending to supervise it. The same saved hosting flags are re-applied by
every monitor-initiated start/restart so a later restart cannot silently drop
the endpoint from the new provider registration. Unified mode displays the
configured URL (and active private LAN addresses for a wildcard bind) instead
of using standalone discovery. It reads the provider-owned
`~/.darkbloom/local_token` only after the user chooses Copy, validates
ownership and restrictive file permissions, and does not follow symlinks.
Standalone discovery details come from `darkbloom local --json` only on
explicit demand. A bearer token is never displayed, logged, or persisted.
Hosting is gated on a CLI version the app has
verified against the official provider CLI reference (0.9.7); older or
unknown CLI versions show hosting as unavailable rather than dispatching
unverified flags.

Networking has three fixed public HTTPS GET paths on `api.darkbloom.dev`:
authenticated account earnings, the public 24-hour leaderboard, and public
per-model capacity. SQLite keeps separate hourly inference-work and online-
reward aggregates plus balances with user-only permissions; it excludes
account IDs, provider keys, and credential material. The source policy does not
offer an arbitrary command interface.

## Chat routing trust boundary (September 24, 2026, unreleased worktree)

The Chat tab (dashboard) and the separate resizable pop-out chat window share
one in-memory `ChatStore`, so both show the same conversation. The transcript
is transient in-memory state: it is discarded on quit and never written to
any store. The only chat credential kept anywhere is the consumer API key,
which is intentionally stored in the macOS Keychain and nowhere else. This
section is the authoritative description of the chat trust boundary. It
exists only on the `codex/chat-routing` worktree and is unreleased.

Every conversation is bound to one destination at creation and the route is
immutable for its lifetime: **Local endpoint (this Mac)** — the user's own
hosting endpoint exactly as configured in Hosting settings (unified mode URL
plus the provider-owned `dk-local-` token file; unified mode has no discovery
record and `darkbloom local --json` does not discover it), falling back to the
documented standalone discovery record — or **Darkbloom network (paid)** —
one fixed HTTPS host, `api.darkbloom.dev`. Switching routes requires an
explicit New Chat, which starts an empty transcript; text written under one
route can never be sent to the other, in either direction, and no fallback
ever occurs. Composer drafts are owned by the conversation they were typed
in (`ChatDraftPolicy`): a route change discards the draft before it can be
delivered, even in the window before SwiftUI state settles.

The two routes use three distinct credential domains that are never
substituted for one another: the provider device token (earnings reads only),
the local endpoint token (`dk-local-`, file-permission validated), and the
**consumer API key**, which exists only in the macOS Keychain
(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), is never written to
defaults, files, or logs, and is never used for the local route. Network
model verification is credential-scoped: replacing or removing the key drops
the verified network model list, the selection from it, and the balance, and
in-flight reads started under an older key are discarded through a credential
generation counter, including mid-preflight paid sends.

Both routes speak the OpenAI-compatible contract (`POST /v1/chat/completions`,
authenticated `GET /v1/models`); the network adds
`GET /v1/payments/balance` (`balance_micro_usd` ledger) and reuses the public
`/v1/pricing` snapshot. All chat traffic goes through one ephemeral session
with no cookies, credential storage, or caching, and a delegate that rejects
every redirect. Requests are built only from fixed URLs or the app's own
validated hosting configuration (never user text), bodies are bounded before
sending (256 KiB request, 256 KiB model lists, 1 MiB completions), responses
are streamed against hard byte ceilings, and the send pipeline checks
cancellation at its bounded await points. Error surfaces are fixed local
strings: a response body's
free-text `error.message` is never displayed (it could echo credentials or
prompt text); only whitelisted machine `error.code` tokens refine 403/404
semantics.

Local sends require a recent authenticated `/v1/models` verification, which
is also the reachability check; if the local endpoint is unavailable the send
stops with a fixed reason and the user must choose — the store never reroutes
to the paid network. The local banner calls the route local without claiming
it is costless: the local engine is shared with fleet serving work.

Network sends fail closed through an ordered gate before any paid request:
the conversation's explicit paid-route acknowledgement (per conversation,
in memory, restating that this Mac is not used and every request is paid), a
stored consumer key, a fresh pricing snapshot that lists the selected model
(the send-time gate re-fetches pricing when stale and re-validates the
returned snapshot's freshness), and a fresh,
authoritative balance read above zero — a stale ledger snapshot blocks even
when the fetch succeeds. A positive balance is never presented as a
guarantee: the network reserves against each request's upper bound and
decides sufficiency itself, so an HTTP 402 (`insufficient_funds` or
`insufficient_quota`, even with an oversized or malformed error body) is
recorded as the network's authoritative decision with no retry. Every
assistant response retains route/model/time provenance (the served model
when the response names one), and the network banner always states the
non-guarantee, showing balance and selected-model price as status lines —
including explicit "unavailable" states while those reads are pending or
have failed, never a manufactured value.

The first version is non-streaming with full cancellation (an honest
cancelled state notes the request may already have been delivered); a
duplicate send while one is in flight is ignored. Conversation state is
transient: quitting the app discards it, and nothing about chat reaches
SQLite or diagnostics.

Download/Delete, Enable/Disable, and Preload/Unpreload are independent.
Start passes saved enabled models as repeated official CLI `--model` arguments
when supported by the installed release, bypassing the interactive picker.
Changing which model is resident requires the provider's supported
configuration/startup path; the monitor does not perform live warming or
unloading.
Stop and Restart check provider activity, but that read may be unknown and can
change before the command runs. Active or unknown activity therefore requires a
user's explicit destructive override; this is a customer-impact warning, not an
atomic no-interruption guarantee.

The official `max_model_slots` setting controls provider capacity after the
normal configuration/restart path applies it. The second slot is not a monitor-
reserved staging slot, and the monitor does not load a target first, retire an
idle resident, or evict a model to make room. Public demand remains useful as
read-only opportunity context, but it cannot authorize a local residency
change.

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
only fixed safe categories for config and lifecycle failures. Raw or
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
dashboard separates Models into On this Mac, Available, and Capacity views.
Compact model cards keep download/delete independent from enable/startup-load
settings. Capacity exposes concurrent-request and resident-model limits; all
changes share the staged draft and the validated configuration save path.
Refresh preserves edits; Discard edits explicitly reloads the saved settings.
Model presentation is derived from the enabled-model filter plus loaded, warm,
slot, and current-model state. Green
means active, yellow means loaded but idle, and gray means available but
unloaded. No Warm or live-switch action is presented because the official CLI
does not expose the required operator API. `StatusItemController` owns an
in-process Settings window whose SwiftUI view owns the persisted menu-bar
metric picker, avoiding delegation to another registered app bundle.
Diagnostic telemetry remains in the library and tests rather than being
exposed through disclosure groups.

## Failure and freshness model

Source availability is `available`, `stale(last good value, reason)`, or
`unavailable(reason)`. One source failing cannot erase another. Structured state
turns stale after 10 seconds using `written_at`; a loaded-model read turns stale
10 seconds after its acquisition if polling stops or fails. Its `updated_at`
may remain old while residency is unchanged. CLI status turns stale after 60
seconds using acquisition time. Process identity
changes reset token-rate history immediately. Unified-stream termination and
finite-source errors become stable, source-specific diagnostics.

Public capacity is polled every 30 seconds and remains useful for display only
while fresh, with no more than five seconds of future skew. An older overlapping
response is discarded. Local model state is authoritative only from fresh
official telemetry and official CLI results; the monitor does not infer
residency changes from public demand or unsupported private control APIs.

## CLI 0.9.7 integration (September 21, 2026)

The retained dashboard is now the shared resizable window for Overview, Models, Network, Health, and Settings. New optional daemon fields preserve schema-1 compatibility: advertised models, coordinator identity, authorization summary, KV fallback and MTP explanations, and normalized load failures. Authorization retains only bounded status and presence flags, never session/machine ID values. ProviderVerification checks the live kernel process identity, coordinator, timestamps, protocol and expiry before showing current verification guidance.

ProviderExtrasClient uses bounded shell-free official CLI commands for idle policy, beta flags, fan diagnostics, and update posture. MonitorStore owns its 30-second read-only polling loop and joins cancellation during shutdown. ProviderExtrasStore retains independent source states and serializes its refreshes. Explicit idle and allowlisted beta writes pass through ProviderControlStore's shared mutation gate, are blocked by staged model changes or pending confirmations, and refresh settings and model controls afterward. They never automatically restart the provider. No helper installation, fan override, enrollment, or autoupdate mutation is exposed.

ProviderSelectionComparison and the dashboard separate saved enabled models, the daemon's advertised set, and current residency. When supported advertised models differ, Restart presents the saved set it will apply, rechecks before dispatch, and asks again if that comparison changed. The CLI/service still performs its own fresh preflight; the UI does not claim an atomic transaction against noncooperating external config writers.

NetworkCacheStore owns a visibility-scoped public cache-health request independent of the existing public data sources. This aggregate network state never drives local model switching or claims local cache gains. See PUBLIC_API_CONTRACT.md for cadence and validation.


### Native graceful stop and provider activity

Stop uses the CLI's native graceful drain directly instead of polling for idle in the app. The CLI pauses new admission, drains accepted requests, and waits for usage acknowledgement before stopping. The app allows 600 seconds for that CLI drain plus a 30-second process margin; it never passes force or uninstall flags. If the CLI's drain deadline expires, the provider remains draining and the UI reports the exact remaining count from daemon state so Stop can be selected again. Older schema-1 state remains supported.

While serving, the daemon exposes only a Boolean inference-active signal, not an exact running-request count. The provider panel therefore displays `1+` while active and zero while idle; it shows the exact remaining accepted requests during native drain. GPU utilization is a best-effort whole-Mac IOAccelerator reading when the hardware publishes it, and is not attributed to the provider. Provider-reported GPU allocations remain a separate metric.
