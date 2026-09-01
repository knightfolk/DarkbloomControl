# Darkbloom Monitor

A native, read-only macOS menu-bar monitor for a locally running Darkbloom
provider. It presents live provider state in a 420-point SwiftUI popover without
provider controls, network access, or credential access.

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

The selected presentation is a single, bounded, scrollable popover with these
sections in order: header, primary metrics, models and slots, memory and process,
trust, recent events, Advanced, and the footer. Loaded and warm models are kept
separate. Advanced contains CLI-only corroborating fields, inert source paths,
source timestamps, and acquisition diagnostics.

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

The state and loaded-model polls are independent, so a slow source does not
delay the other. `Refresh Now` requests a non-overlapping refresh of all finite
sources. Recent events are deduplicated, sorted newest first, and capped at 100.

## Derivations and freshness

Token rate is a polling-window estimate, never a direct Darkbloom metric. For
two samples with the same process identity and increasing `written_at`, it is:

```text
(new.tokens_generated - old.tokens_generated)
------------------------------------------------
       (new.written_at - old.written_at)
```

Only a positive token delta produces `N.N tok/s · derived`. Before a second
sample, after a process change, when time does not advance, when the counter
moves backward, or when the polling window has no token progress, the row says
`Unavailable` and gives the specific reason. Uptime, state age, and trust age
are also labeled `derived`.

- Structured state is fresh through 10 seconds, based on its embedded
  `written_at` value.
- Loaded-model state is fresh through 10 seconds, based on its embedded
  `updated_at` value.
- CLI status is fresh through 60 seconds, based on the last successful local
  acquisition.
- A failed refresh retains the last good value as stale and shows the failure
  reason. A source with no last good value is unavailable.

The menu-bar status is green for fresh state whose direct trust status is
`online`, red for direct `offline`, amber for stale or another reported trust
status, and gray when structured state is unavailable. Text and accessibility
labels expose the status without relying on color.

## Privacy and safety boundary

The monitor:

- reads only the five local sources listed above;
- runs Darkbloom with exactly the `status` argument and treats reported paths as
  inert display text;
- never opens `~/.darkbloom/auth_token`, `provider.toml`, model weights, caches,
  or recovery files;
- ignores `attestation_public_key` and unknown state fields;
- never executes `darkbloom local`, `verify`, `doctor`, update, account, device,
  or provider-management commands;
- has no provider start, stop, restart, model-selection, or configuration
  controls;
- imports no network framework, opens no socket, and sends no telemetry;
- never writes under `~/.darkbloom` or `~/.config/darkbloom`.

Unified logging can redact message text as `<private>`. The monitor preserves
the event timestamp, severity, category, and process metadata and displays
`Message unavailable (privacy redacted)`; it does not attempt to recover the
hidden text. Log text is rendered literally and never activated as a link or
command.

## Troubleshooting

### Darkbloom CLI unavailable

Open Advanced to see the executable candidate location categories. Discovery
tries `~/.darkbloom/bin/darkbloom`, the bundled Darkbloom app executable, then
the concrete entries in `PATH`.
Install or restore the local CLI at one of those locations and use `Refresh Now`.
The monitor does not download or repair Darkbloom.

### State or loaded models unavailable

Confirm the provider is running and that `~/.darkbloom/daemon-state.json` and
`~/.darkbloom/loaded-models.json` exist and are readable by your user. A schema
other than 1 is rejected explicitly rather than partially decoded. Advanced
shows the acquisition reason and timestamp. The monitor never starts or restarts
the provider.

### Logs unavailable or stale

The legacy file may be absent before Darkbloom writes it. Unified logging may
redact messages or its local stream may end. Advanced reports legacy-read and
unified-stream health separately; historical qualifying events remain bounded
and visible when available. Use `Refresh Now` to retry finite sources or relaunch
only this monitor to create a new unified-log stream.

### Token rate unavailable

An idle provider normally reports `No token progress in the polling window`.
Generate no traffic solely to make this value appear: a rate is shown only when
the ordinary two-second samples observe a positive same-process counter delta.
