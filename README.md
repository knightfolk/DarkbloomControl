# Darkbloom Control

<img src="assets/brand/dc-app-icon.svg" width="96" alt="Darkbloom Control DC icon">

Darkbloom Control is a native macOS menu-bar companion for a local Darkbloom
provider. It turns provider telemetry into a compact infographic popup and
keeps model and lifecycle controls behind explicit safety checks.

**v1.0** brings a clearer dashboard, Darkbloom 0.9.7 support, staged capacity
settings, and Stop when idle. Previously named Darkbloom Monitor.

## Download

Download the Apple Silicon build from [Releases](https://github.com/knightfolk/DarkbloomControl/releases/latest),
unzip it, move **Darkbloom Control.app** to Applications, then open it.
Quit an older monitor copy before launching the new one. macOS may still ask
for first-launch confirmation or permission to read your external model drive.
The v1.0 Apple Silicon app is Developer ID–signed, notarized by Apple, and
includes a stapled notarization ticket. Gatekeeper verification passed on the
release bundle; no Gatekeeper-disable or quarantine-removal workaround is needed.

## Highlights

- Menu-bar activity status with clearly labeled model-average throughput
- A compact, content-sized popup with short model pills and inline statistics
- Calendar-day average token throughput, including a per-model
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
- Models organized into On this Mac, Available, and Capacity, with search and expandable details
- Concurrency and resident-model limits staged together with model selections
- Stop when idle with fresh activity checks, a visible pending state, and cancellation
- Opportunity cards with readable names, RAM checks, demand badges, and workload counts
- Separate network-history charts with technical details available on demand
- Saved versus advertised model selection, with an explicit restart warning when they differ
- Model hardware/runtime requirements, quantization, and context/output limits
- GPU temperature and fan readings from the official read-only CLI diagnostics
- Idle-memory policy and advanced beta settings, with explicit restart-required feedback
- Fresh verification diagnostics for legacy and App Attest authorization
- Network maintenance and aggregate cache-health reporting
- One resizable dashboard and Settings window
- Qwen, OpenAI/GPT-OSS and Google/Gemma menu-bar icons during observed activity
- Opt-in estimated adapter power, a saved USD/kWh electricity rate, and earnings
  after electricity for matching measurement periods

During inference, the status item shows the model's daily rate labeled `avg`, or
`Working` when no average exists. These are not realtime measurements. The popup
also labels this working/average fallback. Earnings remain the idle fallback.
Unavailable values are omitted or shown with a compact
neutral state; the monitor does not manufacture values from unrelated counters.

## Screenshots

Settings from an earlier local review build. Values vary by provider.

![Electricity and menu-bar settings](docs/screenshots/settings.png)

## Requirements

- macOS 14 or newer
- Apple Silicon for the downloadable build; Swift 6 through Xcode for source builds
- The official, unmodified Darkbloom CLI for provider data and controls
- `darkbloom login` for authenticated earnings

The telemetry and command contracts cover Darkbloom 0.8.15 through 0.9.7,
with optional fields and source failures handled independently. The monitor remains usable when Darkbloom is missing or stopped, but
affected live values and actions will be unavailable.

## Build and run

```bash
git clone https://github.com/knightfolk/DarkbloomControl.git
cd DarkbloomControl
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
by default. Open Dashboard from its popup to access the resizable app window.

Each launch claims one user-scoped kernel lock before creating a status item.
A duplicate build using this same lock exits only the new process and does not
terminate the lock owner. Older builds predating this guard may still run beside
it. Rebuilding also does not replace an already-running process, even when its
executable path matches. See [the safe review-launch procedure](docs/REVIEW_LAUNCH.md).

## What it reads and stores

The monitor reads bounded local telemetry from:

- `~/.darkbloom/daemon-state.json`
- `~/.darkbloom/loaded-models.json`
- a bounded tail of `~/.darkbloom/provider.log`
- the local unified log for Darkbloom lifecycle, warning, and error events
- `darkbloom status`
- macOS thermal state
- authenticated Darkbloom account earnings and the public earnings leaderboard
- the public per-model network-capacity endpoint

The monitor does not use custom provider-control endpoints or require a patched
CLI. Model configuration changes take effect through the official CLI lifecycle.

It stores compact, user-only SQLite histories under:

```text
~/Library/Application Support/Darkbloom Monitor/
```

Those databases contain hourly earnings aggregates, changed balance samples,
observed uptime, and measured model token rates. They do not store the auth
token, account ID, provider key, prompts, responses, or per-job content.

Historical throughput is derived from positive token/time deltas belonging to
the same provider process and model. These completion counters are not a live
streaming rate. Calendar earnings include both inference
work and rewards. When retained data does not cover the entire current week,
the popup says **Observed this week** instead of presenting a partial value as a
complete weekly total.

## Provider controls and safety

Download, Delete, Enable and Preload are separate operations. Saved model
selection is passed explicitly at startup to bypass the CLI picker. App Restart also
applies the saved selection; it can differ from the models the daemon currently
advertises. The comparison is shown separately from loaded models and unsaved edits. Saving
configuration does not silently restart the provider.

**Models → Capacity** controls simultaneous requests per model engine (1–8)
and how many models the provider may keep in memory. The CLI 0.9.7 defaults are
4 requests and 3 resident models. Existing per-model concurrency overrides are
preserved and may differ from the global setting. Actual capacity depends on memory.
Changes remain staged until **Save Changes**; **Refresh** preserves edits and
**Discard edits** reloads saved values. These settings use the official provider configuration. Manual live warming, staged replacement and
automatic demand-based switching are not supported by this app.

Stop and Restart require a customer-impact override when work is active or
activity is unknown. Delete requires fresh residency evidence. Quitting the
monitor stops its own work, not the provider.

**Stop when idle**, in the menu-bar popup, queues a stop until fresh activity
reports no running work, then checks again before dispatching the normal CLI
stop. Unknown or stale activity never counts as idle. Cancel the request at any
time while waiting. Keep the monitor open: queued stops are not saved across
app quits. New work may arrive while it waits; after dispatch, the CLI performs
its normal bounded graceful shutdown. No automatic restart is queued.

Idle-memory and beta controls use official CLI commands and require a restart to
apply. They share the model/lifecycle action gate and cannot overwrite a staged
model draft. Fan monitoring is read-only; this app does not install or configure
the privileged fan helper. Verification guidance never removes enrollment.

After saving model configuration, restart the provider to apply it. The monitor
does not claim to verify the applied runtime configuration through private APIs.

## Limitations

- Consult the release notes for signing and notarization status of each artifact.
- Electricity is estimated whole-Mac DC adapter input, not wall power or
  Darkbloom-only consumption. Missing readings leave gaps; only fully matched
  earnings hours contribute to earnings after electricity.
- Earnings and model-rate history begin when this monitor collects it. Partial
  weekly coverage is labeled explicitly.
- A per-model throughput breakdown appears only after at least two models have
  valid measured samples for the current local calendar day.
- CLI output and APIs may evolve after the validated 0.9.7 contract. Older CLI versions omit unsupported diagnostics.
- Only the official CLI is supported; do not install a custom provider branch
  to enable monitor features. Live streaming throughput and protected model
  switching are not available.
- Provider actions affect the local provider and may affect customer jobs; read
  confirmation dialogs before proceeding.

## Documentation

- [Telemetry contract](docs/TELEMETRY_CONTRACT.md)
- [Public API contract](docs/PUBLIC_API_CONTRACT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Electricity estimates and model icons](docs/ELECTRICITY_AND_MODEL_ICONS.md)
- [Presentation research](docs/PRESENTATION_OPTIONS.md)

## Development

Run the complete test suite and production build before submitting changes:

```bash
swift test
swift build -c release
```

The package targets macOS 14 and uses SwiftUI, AppKit, Swift Testing, and
SQLite3.
## Local review bundle assembly

After `swift build -c release`, assemble without launching or overwriting an
existing output (replace the absolute paths with your checkout paths):

```sh
python3 tools/package_app.py \
  --executable /absolute/checkout/.build/arm64-apple-macosx/release/DarkbloomMonitor \
  --resources /absolute/checkout/.build/arm64-apple-macosx/release/DarkbloomMonitor_DarkbloomMonitor.bundle \
  --output /absolute/checkout/.build/new-local-review \
  --version 1.0.0 --build-number 100
```

The new directory contains `Darkbloom Control.app` and a SHA-256 file manifest.
Version/build values are labels, not release provenance. This tool does not
launch, register, install, distribution-sign, notarize, or publish the app.
The manifest is not an SBOM or reproducible-build proof. Keep live relaunch,
unsaved-settings safety, upgrade testing and distribution approval separate.

See [release signing and notarization](docs/RELEASING.md) for distribution packaging.

## Upgrade from Darkbloom Monitor

Quit the old monitor before opening Darkbloom Control. Quitting the monitor
does not stop the official provider CLI. Keep only one installed app copy in
your chosen Applications folder; do not leave the old app as a second login item.

The bundle identifier, internal executable/resource names, settings keys,
history folder (`Library/Application Support/Darkbloom Monitor`), and
single-instance lock are intentionally unchanged. Existing settings and
history carry over without a migration. Swift package commands still use the
internal `DarkbloomMonitor` target name. The Git history and old release notes
retain the original project name for traceability.

See [Branding](docs/BRANDING.md) for editable icon sources and packaging details.
