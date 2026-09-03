# Darkbloom Monitor

Darkbloom Monitor is a native macOS menu-bar companion for a local Darkbloom
provider. It turns provider telemetry into a compact infographic popup and
keeps model and lifecycle controls behind explicit safety checks.

> **Alpha software:** Alpha 1 is a source release. It does not yet include a
> signed or notarized `.app` bundle.

## Highlights

- Live menu-bar status with current throughput while inference is active
- A 400-by-600-point popup designed for quick scanning rather than diagnostic
  walls of text
- Current and calendar-day average token throughput, including a per-model
  breakdown once more than one model has measured samples
- Calendar-day earnings, average earnings per observed hour, and a local
  calendar-week total
- Completed jobs today and the prior seven-day daily average when enough local
  history exists
- Green active, yellow loaded-idle, and gray available-model pills that remain
  visible during idle periods
- Start, Stop, and Restart controls with customer-impact confirmation when work
  is active or activity cannot be verified
- Model catalog management with separate Download, Delete, Enable, and Preload
  actions
- A resizable Settings window for display preferences and provider model
  configuration

The status item favors current `tok/s` while inference is active and recent
earnings while idle. Unavailable values are omitted or shown with a compact
neutral state; the monitor does not manufacture values from unrelated counters.

## Requirements

- macOS 14 or newer
- Swift 6 through Xcode or the Swift toolchain
- A local Darkbloom installation for live provider data and controls
- `darkbloom login` for authenticated earnings

The telemetry and command contracts were last validated against Darkbloom
0.8.15. The monitor remains usable when Darkbloom is missing or stopped, but
affected live values and actions will be unavailable.

## Build and run

```bash
git clone https://github.com/knightfolk/DarkbloomCLIMenuBarMonitor.git
cd DarkbloomCLIMenuBarMonitor
swift test
swift run DarkbloomMonitor
```

For a release build:

```bash
swift build -c release
./.build/release/DarkbloomMonitor
```

You can also open `Package.swift` in Xcode and run the `DarkbloomMonitor`
scheme. The app appears only in the menu bar and intentionally has no Dock icon
or document window.

## What it reads and stores

The monitor reads bounded local telemetry from:

- `~/.darkbloom/daemon-state.json`
- `~/.darkbloom/loaded-models.json`
- a bounded tail of `~/.darkbloom/provider.log`
- the local unified log for Darkbloom lifecycle, warning, and error events
- `darkbloom status`
- macOS thermal state
- authenticated Darkbloom account earnings and the public earnings leaderboard

It stores compact, user-only SQLite histories under:

```text
~/Library/Application Support/Darkbloom Monitor/
```

Those databases contain hourly earnings aggregates, changed balance samples,
observed uptime, and measured model token rates. They do not store the auth
token, account ID, provider key, prompts, responses, or per-job content.

Current throughput is derived only from positive token/time deltas belonging to
the same provider process and model. Calendar earnings include both inference
work and rewards. When retained data does not cover the entire current week,
the popup says **Observed this week** instead of presenting a partial value as a
complete weekly total.

## Provider controls and safety

The monitor may change only the top-level `enabled_models` and
`preload_models` arrays in `~/.config/darkbloom/provider.toml`. It preserves
unrelated TOML bytes and comments, validates a candidate file, uses bounded
locking and revision checks, and keeps one backup before atomic replacement.

It invokes a narrow allowlist of Darkbloom commands without a shell:

- `status`
- `models catalog`, `models list`, `models download`, and `models remove`
- `start`, `stop`, and `restart`

Starting passes the saved enabled models as repeated `--model` arguments so the
CLI model picker is bypassed. Saving model choices does not silently restart the
provider. Download/Delete and Enable/Preload remain independent operations.

Stop and Restart can interrupt customer work. The app checks current activity
and requires an explicit override when work is active or the check is unknown.
Delete is blocked when fresh residency evidence cannot prove removal is safe.

## Alpha 1 limitations

- No signed or notarized app bundle is included yet; build and run from source.
- Earnings and model-rate history begin when this monitor collects it. Partial
  weekly coverage is labeled explicitly.
- A per-model throughput breakdown appears only after at least two models have
  valid measured samples for the current local calendar day.
- Darkbloom CLI output and APIs may evolve after the validated 0.8.15 contract.
- Provider actions affect the local provider and may affect customer jobs; read
  confirmation dialogs before proceeding.

## Documentation

- [Telemetry contract](docs/TELEMETRY_CONTRACT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Presentation research](docs/PRESENTATION_OPTIONS.md)

## Development

Run the complete test suite and production build before submitting changes:

```bash
swift test
swift build -c release
```

The package targets macOS 14 and uses SwiftUI, AppKit, Swift Testing, and
SQLite3.
