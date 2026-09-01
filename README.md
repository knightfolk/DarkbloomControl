# Darkbloom Monitor

A native, read-only macOS menu-bar monitor for a locally running Darkbloom
provider. It presents live provider state in a compact 400-by-560-point SwiftUI
popover, reads authenticated account earnings, and never exposes provider
controls.

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
ordinary application window.

## What the popover shows

The popover is an infographic dashboard with four large values: current
tokens per second, the active-session token-rate average, jobs completed today,
and the average jobs per day across the prior seven complete calendar days.
The average remains an em dash until local history proves that it covers the
full period.

Model capsules are green while actively processing, yellow when loaded but
idle, and gray when available but unloaded. Two compact controls remain:
Settings opens the monitor-owned Settings window containing the existing
menu-bar metric picker, and a door icon stops the monitor cleanly. Detailed
telemetry remains collected and tested without being rendered as a diagnostic wall.

The complete field inventory and known gaps are documented in
[`docs/TELEMETRY_CONTRACT.md`](docs/TELEMETRY_CONTRACT.md).

## Sources and cadence

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

## Privacy and safety boundary

The monitor:

- reads only the fixed local and remote sources listed above;
- runs Darkbloom with exactly the `status` argument and treats reported paths as
  inert display text;
- opens `~/.darkbloom/auth_token` only to authenticate the fixed account-
  earnings GET request; the token is held in memory and is never displayed,
  logged, or persisted;
- never opens `provider.toml`, model weights, caches, or recovery files;
- ignores `attestation_public_key` and unknown state fields;
- never executes `darkbloom local`, `verify`, `doctor`, update, account, device,
  or provider-management commands;
- has no provider start, stop, restart, model-selection, or configuration
  controls;
- sends read-only GET requests only to
  `api.darkbloom.dev/v1/provider/account-earnings` and
  `api.darkbloom.dev/v1/leaderboard`;
- never writes under `~/.darkbloom` or `~/.config/darkbloom`.

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
dashboard shows an em dash for unavailable values. The monitor never starts or
restarts the provider.

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
