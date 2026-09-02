# Darkbloom Monitor

A native macOS menu-bar monitor and narrowly scoped provider-control surface
for a local Darkbloom provider. It presents live provider state in a compact
400-by-600-point SwiftUI popover, reads authenticated account earnings, and
keeps provider changes behind explicit, bounded actions.

## Requirements

- macOS 14 or newer.
- Swift 6 through Xcode or the Swift toolchain.
- A local Darkbloom installation for live data. The telemetry contract was
  inventoried and revalidated against Darkbloom 0.8.15 on 2026-08-31.

The app remains usable when Darkbloom is missing or stopped: affected fields
show `Unavailable` with a reason instead of invented defaults.

## Run

From a terminal:

```bash
swift test
swift run DarkbloomMonitor
```

From Xcode, open `Package.swift`, select the `DarkbloomMonitor` executable
scheme, and run it. The app appears only in the menu bar; it has no Dock icon or
main/document window. It retains a monitor-owned, resizable Settings `NSWindow`
when Settings is opened.

## What the popover shows

The popover is an infographic dashboard with four large values: current
tokens per second, the active-session token-rate average, jobs completed today,
and the average jobs per day across the prior seven complete calendar days.
The average remains an em dash until local history proves that it covers the
full period.

Model capsules are green while actively processing, yellow when loaded but
idle, and gray when available but unloaded. The first control row retains
Settings, which opens the monitor-owned Settings window, and a door icon that
stops the monitor cleanly. The second row provides Start, Stop, and Restart
provider controls. Settings contains General and Models tabs; Models separates
My Catalog from Available models, and keeps download/delete separate from
enable/disable and preload choices. Detailed telemetry remains collected and
tested without being rendered as a diagnostic wall.

The complete field inventory and known gaps are documented in
[`docs/TELEMETRY_CONTRACT.md`](docs/TELEMETRY_CONTRACT.md).

## Telemetry sources and cadence

| Source | Use | Cadence or lifetime |
|---|---|---|
| `~/.darkbloom/daemon-state.json` | Provider, model, slot, memory, process, trust, and counters | Every 2 seconds |
| `~/.darkbloom/loaded-models.json` | Loaded-model list | Every 2 seconds |
| Final 128 KiB of `~/.darkbloom/provider.log` | Bounded legacy events | Every 5 seconds |
| Local `/usr/bin/log stream` for subsystem `dev.darkbloom.provider` | Unified lifecycle/warning/error events | App lifetime |
| `darkbloom status` | CLI-only configuration and hardware detail | Every 30 seconds |
| `ProcessInfo.thermalState` | Native macOS thermal pressure | On launch and each system notification |
| Authenticated account earnings API | Recent earning records and account balances | Every 10 minutes |
| Public 24-hour earnings leaderboard | Exact server-computed rolling account total when the account is ranked | Every 10 minutes |

These are periodic telemetry reads, not a complete list of the monitor's
separate bounded provider-control, config, or authenticated-earnings surfaces.
The state and loaded-model polls are independent, so a slow source does not
delay the other. Recent events are deduplicated, sorted newest first, and capped
at 100 even though they are no longer displayed in the compact popover.

## Derivations and freshness

Token rate is a polling-window estimate, never a direct Darkbloom metric. For
two samples with the same process identity and increasing `written_at`, it is:

```text
(new.tokens_generated - old.tokens_generated)
------------------------------------------------
       (new.written_at - old.written_at)
```

Only a positive token delta produces a current rate. Unique positive samples
also feed the active-session average; repeated publications of the same state
sample do not skew it. Before a second sample, after a process change, when time
does not advance, when the counter moves backward, or when the polling window
has no token progress, the dashboard uses a compact em dash or `Idle` rather
than diagnostic prose.

- Structured state is fresh through 10 seconds, based on its embedded
  `written_at` value.
- Loaded-model state is fresh through 10 seconds, based on its embedded
  `updated_at` value.
- CLI status is fresh through 60 seconds, based on the last successful local
  acquisition.
- A failed refresh retains the last good value as stale and shows the failure
  reason. A source with no last good value is unavailable.

The menu-bar logo remains green for routable/nominal, yellow for routable/fair,
orange for routable/serious, and red whenever routing is blocked or cannot be
confirmed. Inside the popover, the logo follows the leading model state and all
model capsules expose their status in accessibility labels and help text, so
color is not the only signal.

## Provider-control and safety boundary

The monitor has a deliberately narrow management allowlist:

- uses the fixed telemetry sources listed above for periodic polling;
- reads and may change only top-level `enabled_models` and `preload_models` in
  the fixed `~/.config/darkbloom/provider.toml`; it preserves unrelated TOML
  bytes and comments when a save completes with the observed source revision;
- invokes only `darkbloom status`, `models catalog`, `models list`, `models
  download`, `models remove`, `start`, `stop`, and `restart`, using an
  executable plus separate arguments rather than a shell;
- creates a UUID-named sibling candidate while saving configuration and keeps
  one fixed `provider.toml.darkbloom-monitor-backup` backup;
- opens `~/.darkbloom/auth_token` only to authenticate the fixed account-
  earnings GET request; the token is held in memory and is never displayed,
  logged, or persisted;
- ignores `attestation_public_key` and unknown state fields;
- sends read-only GET requests only to
  `api.darkbloom.dev/v1/provider/account-earnings` and
  `api.darkbloom.dev/v1/leaderboard`;
- never changes other configuration fields, credentials, account commands,
  launchd internals, or model-cache files directly.

Starting passes each enabled model through a repeated `--model` argument, so
the CLI picker is bypassed. Saving a changed enable/preload selection stages and
validates a candidate before publication, then reports that a provider restart
is required; a save itself does not restart the provider. Download/Delete and
Enable/Preload remain independent states, so one action does not silently
perform another.

Configuration publication uses bounded advisory locking, revision checks, and
atomic replacement. The locks coordinate only writers that cooperate by
reopening and revalidating the config path after contention. A noncooperating
writer that retains an open descriptor cannot be serialized by this monitor;
when external change or recovery certainty is lost, the save is rejected or
reports recovery and preserves the visible versions rather than claiming an
unconditional safe publication.

Provider safety decisions use the daemon and loaded-model timestamps only when
they are finite, no more than ten seconds old, and not in the future. A stale,
future, invalid, or unavailable activity read becomes unknown and therefore
requires the Stop/Restart override; Delete is blocked before a remove command
when residency is not fresh. Save and Download independently reread the model
catalog and local-model list without stale fallback immediately before acting.
Save requires every requested selector to resolve unambiguously to a downloaded
catalog model; Download requires a fresh Available entry. These checks are at
the service boundary, not just in the visible controls.

The Settings UI carries typed source freshness and eligibility state, so it can
disable Save and Available-row Download before dispatch. After a successful
lifecycle command, it requests an immediate telemetry/status refresh and then
refreshes model controls. Popup model pills fail closed: if either model source
is unavailable or the provider-control residency state is not fresh, the popup
shows `Model state unavailable` rather than guessing an unloaded state.

User-visible control diagnostics are bounded and redact the configured home
path and credential-shaped values. Fixed, safe error categories remain distinct
for conditions such as changed settings, busy configuration, rejected
candidates, and blocked model actions. Raw or unbounded CLI output is never
presented. During a current download only, the Settings view may show at most
one latest progress line from stdout or stderr; its input is bounded to 4,096
bytes per line and sanitized before display.

Model-row actions include target-specific accessibility labels and hints,
including disabled or cancellation effects. Lifecycle controls provide their
own labels, help text, and identifiers; customer-impact information is supplied
by the explicit Stop/Restart confirmation alert rather than a lifecycle hint.

Stop and Restart can interrupt customer work. The monitor checks activity, but
that check can be unavailable or become stale between checking and execution.
When activity is active or unknown, the UI requires an explicit destructive
override before it issues either command. That warning is not a guarantee that
no customer job will be interrupted. Delete has its own confirmation and removes
downloaded model data; it does not disable or unload a model implicitly.

Hourly inference-work aggregates, hourly online/base rewards, and changed
account balance samples are stored at
`~/Library/Application Support/Darkbloom Monitor/earnings.sqlite3` with user-
only permissions. Ten-minute overlapping pages are deduplicated with one
earning-ID high-water mark, and unchanged polls write no history. The database
stores no auth token, account ID, provider key, prompt text, response text, or
per-job rows. Darkbloom entries whose model is `base_reward` never increment
inference job or token totals; they are retained in the separate reward series.
Its compact hourly schema supports charts, model comparisons, combined earnings,
withdrawable/pending settlement calculations, and payout reconciliation.

Unified logging can redact message text as `<private>`. The monitor preserves
the event timestamp, severity, category, and process metadata and displays
`Message unavailable (privacy redacted)`; it does not attempt to recover the
hidden text. Log text is rendered literally and never activated as a link or
command.

## Troubleshooting

### Darkbloom CLI unavailable

Discovery tries `~/.darkbloom/bin/darkbloom`, the bundled Darkbloom app
executable, then the concrete entries in `PATH`. Install or restore the local
CLI at one of those locations and relaunch the monitor. The monitor does not
download or repair Darkbloom.

### State or loaded models unavailable

Confirm the provider is running and that `~/.darkbloom/daemon-state.json` and
`~/.darkbloom/loaded-models.json` exist and are readable by your user. A schema
other than 1 is rejected explicitly rather than partially decoded. The compact
dashboard shows an em dash for unavailable values. To start a stopped provider,
save at least one enabled model and use Start. Stop and Restart require an
explicit confirmation when customer activity is active or cannot be confirmed.

### Logs unavailable or stale

The legacy file may be absent before Darkbloom writes it. Unified logging may
redact messages or its local stream may end. Historical qualifying events remain
bounded internally but are intentionally omitted from the dashboard. Relaunch
only this monitor to create a new unified-log stream.

### Token rate unavailable

An idle provider normally reports `No token progress in the polling window`.
Generate no traffic solely to make this value appear: a rate is shown only when
the ordinary two-second samples observe a positive same-process counter delta.

### Rolling earnings unavailable

Run `darkbloom login` if the authenticated request is rejected. Darkbloom caps
recent account history at 1,000 records; the monitor never labels that partial
history as a complete 24-hour total. It uses Darkbloom's public 24-hour aggregate
when the authenticated account can be matched to a ranked pseudonym, while the
local hourly database builds a durable chart and payout history over time.

### Seven-day job average unavailable

The dashboard shows an em dash until account history reaches the start of all
seven prior complete calendar days. Today’s job count remains available while
that local coverage accumulates; the monitor never presents missing history as
a zero average.
