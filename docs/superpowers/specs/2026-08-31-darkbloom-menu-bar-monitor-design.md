# Darkbloom Menu Bar Monitor Design

## Purpose

Build a native macOS menu-bar app that reports every useful real-time field
actually exposed by the locally installed Darkbloom 0.8.15 CLI, schema-1 state
files, and logs. The app is a read-only observer: it does not change Darkbloom
configuration, manage the provider, access credentials, or communicate over the
network.

The chosen presentation is Option A: a structured SwiftUI popover. The popover
keeps high-signal provider state visible at a glance while retaining a complete,
source-grounded details view.

## Platform and Packaging

- Swift 6 package, macOS 14 or newer.
- `DarkbloomTelemetry` library target for acquisition, parsing, normalization,
  provenance, freshness, and derivation.
- `DarkbloomMonitor` executable target using SwiftUI and AppKit lifecycle APIs.
- `MenuBarExtra` with `.window` style; no Dock icon and no ordinary app window.
- No third-party dependencies, network entitlements, login item, updater, or
  telemetry of the monitor itself.

The package must build and run from Xcode and with:

```bash
swift test
swift run DarkbloomMonitor
```

## Read-Only Source Policy

The monitor may read only these local sources:

1. `~/.darkbloom/daemon-state.json`, every two seconds.
2. `~/.darkbloom/loaded-models.json`, every two seconds.
3. `~/.darkbloom/provider.log`, every five seconds, reading at most the final
   128 KiB per poll.
4. `/usr/bin/log stream` for subsystem `dev.darkbloom.provider`, consuming JSON
   lines and retaining only a bounded event buffer. The stream is local and is
   terminated when the monitor exits.
5. The installed Darkbloom executable with exactly the argument `status`, every
   30 seconds and with a three-second timeout. Executable discovery checks
   `~/.darkbloom/bin/darkbloom`, the bundled app executable, then `PATH`.

The process runner exposes fixed `status` and unified-log operations rather than
an arbitrary command interface. Captured standard output and error are capped
at 256 KiB per invocation.

The monitor must never:

- Open `~/.darkbloom/auth_token`.
- Open or parse `provider.toml`.
- Execute `darkbloom local`, `verify`, `doctor`, `models catalog`, `update`, or
  any start/stop/restart/account/device command.
- Follow config paths printed by `darkbloom status`.
- Read model weights, model configuration, cache databases, or recovery files.
- Open sockets, make HTTP requests, or use a network framework.
- Write into `~/.darkbloom`, `~/.config/darkbloom`, or their descendants.

The state field `attestation_public_key` is intentionally ignored. It is public
material, but it has no monitoring purpose and is outside the normalized model.

## Normalized Snapshot

The UI receives one immutable `TelemetrySnapshot`. Each source-backed group
includes its capture time and availability (`available`, `stale`, or
`unavailable(reason)`). A successful source refresh replaces only that source's
group. A failed refresh preserves the last good values as stale and records the
new reason; a missing source with no previous value is unavailable.

### State fields

- Darkbloom version.
- Current model.
- Warm models.
- Inference active.
- Provider PID and process start identity.
- Provider start timestamp.
- Trust level, online status, coordinator reason, and trust receipt timestamp.
- Total memory, active GPU memory, and GPU cache memory in GiB.
- Requests served, tokens generated, and usage gaps.
- State write timestamp.
- Every slot's model, effective KV backend, requested KV backend, MTP enabled,
  and MTP active values.
- MTP reason as explicitly unavailable because schema 1 exposes no such field.

### Loaded-model fields

- Loaded model list.
- Loaded-model file update timestamp.

Loaded and warm models remain separate concepts and separate UI rows.

### Status fields

- CLI version, provider name, config path, coordinator URL, and backend port.
- Configured model selection, idle timeout, beta features, and auto-restart
  posture.
- Hardware summary, inference memory allowance, and local boot checks.
- Schedule, enabled-model filter, and local MLX model count.
- Daemon summary, status-reported trust and reason, warm models, most recently
  used model, request/token counters, state age, and slot posture.

Structured state wins when both state and status expose the same concept.
Status duplicates stay available under Advanced as corroborating CLI output and
must not overwrite newer structured state.

### Event fields

- Timestamp.
- Severity: info, notice, warning, or error.
- Source/category.
- Literal message when exposed.
- Process ID and process image when exposed by unified logging.
- `Message unavailable (privacy redacted)` when unified logging returns
  `<private>`.

Only lifecycle, warning, error, and fault events enter the recent-event buffer.
The buffer retains at most 100 unique events ordered newest first. Duplicate
legacy/unified records with equal timestamp, severity, category, and message are
collapsed.

## Derivations

Derivations never masquerade as direct telemetry.

### Tokens per second

The monitor compares consecutive `daemon-state.json` samples only when both
samples have the same `process_identity` and the newer `written_at` timestamp is
greater than the older timestamp:

```text
(new.tokens_generated - old.tokens_generated)
------------------------------------------------
       (new.written_at - old.written_at)
```

A positive token delta produces `N.N tok/s · derived`. Otherwise the field is
unavailable with one exact reason: waiting for a second sample, provider process
changed, state timestamp did not advance, token counter moved backwards, or no
token progress in the polling window. Zero progress is not displayed as
`0 tok/s` because that would imply measured generation.

### Time values

- Uptime is `now - started_at`, labeled derived.
- Snapshot age is `now - written_at`, labeled derived.
- Trust age is `now - trust.received_at`, labeled derived.

Negative results from clock skew are unavailable rather than clamped to zero.

### Presentation status

The menu icon does not invent an independent health score. Its color maps only
to the current state source and direct trust status:

- Green: structured state is fresh (10 seconds old or less) and trust status is
  exactly `online`.
- Amber: structured state exists but is stale, or trust status is neither
  `online` nor `offline`.
- Red: trust status is exactly `offline`.
- Gray: structured state is unavailable.

The popover always shows the underlying trust status and source age beside the
color so the mapping is inspectable.

## Popover Information Architecture

The popover has a fixed width of 420 points and a maximum content height of 680
points. It scrolls as a single surface, keeping standard macOS materials,
typography, spacing, keyboard focus, and accessibility behavior.

### Header

- Darkbloom title and current provider name.
- Direct trust status badge with status color.
- `Active` or `Idle` from `inference_active`.
- Last structured-state refresh age.

### Primary metrics

A two-column grid shows:

1. Current model.
2. Tokens/second with `derived` label or its unavailable reason.
3. Requests served.
4. Tokens generated.

Usage gaps appears immediately below. A nonzero value is emphasized but not
renamed or interpreted.

### Models and slots

- Separate comma-delimited loaded and warm model rows, with `None reported` for
  an exposed empty list and an availability reason for a missing source.
- One card per slot showing model, effective and requested KV backend, and MTP
  enabled/active status.
- MTP reason always shows `Unavailable — not exposed by Darkbloom schema 1`
  unless a future structured source explicitly provides a reason. Free-form log
  text does not become a slot reason without a documented field contract.

### Memory and process

- Memory rows show active GPU, GPU cache, and total memory values in GiB. A
  progress bar may visualize active GPU divided by total memory, with the exact
  numerator and denominator visible. Cache is not added to active memory.
- Process rows show PID, process start identity, start time, and derived uptime.
- Version appears here; status-only hardware detail remains under Advanced.

### Trust

- Trust level, status, coordinator reason, receipt time, and derived age.
- Values are displayed literally. The monitor does not make attestation or
  security claims beyond Darkbloom's strings.

### Recent events

- Newest-first list, initially showing up to 20 of the retained 100 events.
- Severity icon, timestamp, category, and up to three lines of literal message.
- `Show all` expands the full retained list in the same popover.
- Empty state distinguishes `No qualifying events in the bounded window` from
  `Logs unavailable: reason`.

### Advanced disclosure

Collapsed by default. It contains every status-only field plus status copies of
overlapping state, source paths as inert selectable text, source timestamps,
and acquisition errors. This section provides completeness without crowding the
live summary.

The footer contains `Refresh Now`, the monitor version, and `Quit`. There are no
provider-control actions.

## Availability and Freshness Rules

- Structured state is fresh through 10 seconds, stale afterward, and remains
  visible with a stale label until replaced or the process identity changes.
- Loaded-model state is fresh through 10 seconds.
- CLI status is fresh through 60 seconds.
- Legacy and unified-log events retain their original timestamps; source health
  separately reports the last successful log read or stream activity.
- On process identity change, the prior token-rate sample is discarded
  immediately. Old events remain in the bounded recent-event history.
- If state JSON is read while Darkbloom is replacing it and decoding fails, the
  monitor retries once after 100 milliseconds before marking that refresh
  failed.

All unavailable copy includes a reason. The UI never substitutes `0`, `false`,
an empty string, or an empty array for a missing source.

## Concurrency and Lifecycle

An actor-owned `TelemetryService` coordinates polling and owns the last good
source values. File reads and process work execute off the main actor.
`MonitorStore` is `@MainActor` and publishes only completed snapshots to the
SwiftUI tree.

Only one poll per source may be in flight. A manual refresh requests a new poll
but does not create overlapping work. Cancellation stops timers, terminates the
owned unified-log stream, closes pipes, and leaves the Darkbloom provider
untouched.

## Error Handling

- Missing Darkbloom installation: gray icon and explicit install/source paths
  checked under Advanced.
- Provider stopped or missing state: state unavailable; status and historical
  events may still render.
- Unsupported state schema: preserve the raw schema number in the error and do
  not partially decode it as schema 1.
- Malformed status lines: known fields parse independently; missing fields are
  individually unavailable.
- Log rotation or truncation: reopen the bounded tail without replaying already
  deduplicated events.
- Unified-log privacy redaction: retain timestamp, severity, category, process
  metadata, and the explicit redacted-message placeholder.
- Command timeout or oversized output: terminate only the child process started
  by the monitor and mark that source unavailable.

Errors are local UI state. The app does not upload reports, notify external
services, or modify Darkbloom to recover.

## Accessibility and Visual Behavior

- Every status color has adjacent text and an accessibility label.
- Dynamic Type and VoiceOver reading order follow the visual section order.
- Monospaced digits are used for counters, rates, memory, PID, and time values.
- Long model names and messages wrap or truncate with a help tooltip; they do
  not widen the popover.
- Reduce Motion disables any activity transition. No continuous animation is
  required.
- Light and dark appearances use semantic system colors and materials.

## Testing and Verification

### Automated tests

- Decode complete observed schema-1 state and loaded-model fixtures.
- Reject unsupported schema values with explicit errors.
- Verify status-field parsing independently so one malformed line does not
  erase unrelated fields.
- Verify tokens/second for positive deltas and every unavailable branch.
- Verify uptime, snapshot age, and clock-skew handling.
- Verify bounded file reads, rotation/truncation behavior, event filtering,
  redaction placeholders, deduplication, and 100-event retention.
- Verify source policy exposes only fixed read-only paths and commands.
- Verify stale/available/unavailable transitions and last-good preservation.
- Verify process restart resets rate derivation.
- Verify a fixture-driven integration snapshot contains every normalized field
  and explicit gap.

### Build and runtime verification

- `swift test` passes with zero failures.
- `swift build` succeeds without warnings.
- Run against fixtures with Darkbloom unavailable to verify explicit gaps.
- Run against the live local Darkbloom provider and compare each displayed
  direct value with the current state files and `darkbloom status` output.
- Inspect the actual popover in light and dark appearance at normal macOS scale.
- Exercise scroll, disclosure, refresh, event expansion, keyboard focus,
  VoiceOver labels, and Reduce Motion.
- Confirm the monitor opens no network sockets and does not read credential or
  config contents during the observed run.

## Documentation and Handoff

The README will document installation, Xcode and command-line running, source
paths, polling cadence, privacy boundaries, exact derivations, limitations, and
troubleshooting. `TELEMETRY_CONTRACT.md` remains the source inventory, while
`ARCHITECTURE.md` is updated to match the implemented service and UI boundaries.

The project remains local. Completion does not authorize signing, notarizing,
publishing, deploying, pushing, or changing the Darkbloom installation.
