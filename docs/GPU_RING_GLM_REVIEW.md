# GPU Ring — GLM-5.3 Implementation & Review Summary

Branch `codex/fan-gpu-controls`, baseline `f9b65d1`. Scope: a thin whole-Mac GPU
utilization ring around the menu-bar model-family logo, tinted by GPU die
temperature. No fan control, no provider/config/credential changes, no CLI
helper installation, no commits/releases.

## What was implemented

| File | Change |
| --- | --- |
| `Sources/DarkbloomTelemetry/MenuBarGPURing.swift` (new) | Pure presentation model: utilization validation/freshness, temperature selection, configurable tint thresholds, accessibility text. |
| `Sources/DarkbloomMonitor/MonitorStore.swift` | Owns one lifecycle `SystemGPUUsageStore` (`gpuUsage`), starts it in `start()`, stops it in `stop()`, and exposes `menuGPURing(now:thresholds:)`. Energy settings now read through an injectable narrow `energyPreferences: UserDefaults` (default `.standard`), and `EnergyRecorder` is injectable so tests never touch the production energy history file. |
| `Sources/DarkbloomMonitor/MenuBarLabel.swift` | New `MenuBarGPURingView` (track + arc + shrunken inner logo keeping its provider-health tint); `MenuBarLabel` takes `ring:` and merges ring detail into the VoiceOver label and tooltip. |
| `Sources/DarkbloomMonitor/StatusItemController.swift` | `StatusItemRootView` observes the shared sampler and passes `store.menuGPURing()` to the label. |
| `Sources/DarkbloomMonitor/Dashboard/ProviderResourcesView.swift` | Reuses `store.gpuUsage` instead of a dashboard-scoped `@StateObject` sampler. |
| `Tests/DarkbloomTelemetryTests/MenuBarGPURingTests.swift` (new) | See "Test coverage". |

### Behavior rules

- **Utilization is whole-Mac.** Sourced from the existing IOKit
  `IOAccelerator` sampler (`SystemGPUUsageStore`, 3 s cadence, no CLI calls).
  The accessibility label and tooltip both say "Whole-Mac GPU use N percent"
  so the ring can't be misread as per-model usage.
- **0 % is an empty track, 100 % a complete ring** (`progress = utilization/100`,
  arc starts at 12 o'clock). Missing, non-finite, out-of-range (0…100), stale
  (> 10 s, matching the dashboard panel's window), or future-dated utilization
  renders **no ring at all** — never a fabricated 0 % or 100 % arc.
- **Tint from fresh temperature only:** green < 70 °C, yellow 70..<85 °C,
  red ≥ 85 °C — presentation constants in `MenuBarGPURing.Thresholds`
  (injectable, default `.standard`), *not* Apple hardware safety limits.
  Missing/stale temperature ⇒ neutral gray arc (ring still shows utilization).
- **Temperature selection:** helper journal temperature when the helper entry
  is fresh (≤ 15 s, `ProviderFanStatus.helperIsFresh`); otherwise the hottest
  valid sensor from the same-command diagnostic; the whole fan source must be
  `.available` and ≤ 45 s old (`ProviderExtrasSnapshot.maximumSourceAge`).
  Sensors are re-validated against the official CLI's plausibility range
  **10…125 °C** (`FanHardware.plausibleTemperatureRange`,
  upstream `FanHardware.swift:236`). Stale readings are never extended because
  the UI re-rendered — a `.stale` fan source yields neutral.
- **One lifecycle-owned sampler:** `MonitorStore` owns it; it runs with no
  dashboard open (verified by regression test), `start()` is idempotent, and
  `stop()` clears state and performs no further reads. Temperature piggybacks
  on the existing 30 s `ProviderExtrasStore` polling loop — zero added CLI
  traffic for the ring.
- **Stable footprint:** the logo container keeps its 16×18 frame inside the
  96×18 label, so the status item stays 104 pt wide whether or not the ring is
  shown; uptime/metric behavior and the provider-health tint on the inner logo
  are untouched. When GPU data is missing the label renders exactly as before.

## Upstream research (read-only, v0.9.9 @ b6f9574)

- The fan helper's own `gpuTemperatureC` is the **hottest** discovered GPU
  sensor (`FanDaemon.swift:210`: `temperatures.map(\.celsius).max()`). The
  diagnostic JSON lists sensors in per-chip catalog order (`FanHardware.swift`
  `GPUTemperatureCatalog`, e.g. 10 keys on M4), so consumers must reduce it
  themselves — our diagnostic fallback uses `max()` to match helper semantics.
- Fan policy: speed clamped **60…90 %** (`FanPolicy.swift:4-5`), single
  trigger/release step (release = trigger − 5 °C, default 45/40), **no curves**.
  Enabling installs a narrowly scoped **root launchd helper**
  (`FanServiceManager.swift`: `geteuid() == 0` guard at line 332);
  `darkbloom fan status|diagnose` are read-only and unprivileged.
- The CLI exposes **no whole-Mac GPU utilization** anywhere; IOKit remains the
  right source for the ring (already in-repo).

### Fan integration suggestions (not implemented; scope decision pending)

1. Keep read-only surfaces on the existing 30 s extras poll; it is cheap
   enough for status/diagnostic JSON, and the ring already reuses it.
2. If fan control lands, model it after `ProviderExtrasStore`'s serial
   mutation gate: `darkbloom fan enable/configure/disable` require root, so
   expect an authorization prompt (or documented sudo step) — never route
   mutations through the status poller.
3. Mirror the helper's hysteresis vocabulary (trigger/release/speed %) in any
   UI draft and client-side validate 60…90 % / plausible temperatures before
   invoking the CLI, exactly like `FanPolicy` does, so bad drafts never reach
   the privileged path.
4. Architecture concern (minor): helper `updatedAt` freshness is only as good
   as the helper daemon writing its journal; our 15 s window mirrors
   `ProviderFanStatus.maximumHelperAge`, but a wedged helper silently degrades
   the ring to diagnostic temperature with no user-visible hint. If that matters
   later, surface "helper stale" like `ProviderThermalView` does.

## Test coverage (`MenuBarGPURingTests.swift`)

- 0/50/100 ⇒ progress 0/0.5/1; NaN/±∞/−0.5/100.5/nil utilization ⇒ no ring;
  sampledAt nil ⇒ no ring.
- Freshness: −10 s boundary accepted; −10.01 s and +2 s (future) rejected.
- Tint boundaries (standard and custom thresholds): 69.9/70/84.9/85 and
  59.9/60/74.9/75; neutral for missing/`.unavailable`/`.stale` fan source,
  45.01 s-old capture, and implausible temps 9.9 °C / 125.1 °C / NaN
  (both plausibility extremes exercised); mixed sensors [9.9, 71, 130] ⇒ 71.
- Selection: fresh helper (58 °C) beats hotter diagnostic; stale helper
  (> 15 s) falls back to hottest diagnostic sensor [50, 72] ⇒ 72 ⇒ yellow;
  stale helper with no sensors ⇒ neutral.
- Accessibility text: exact strings naming whole-Mac scope, integer percent,
  temperature only when present.
- Store composition: `menuGPURing()` reflects the injected sampler + extras
  fan status, and a sampler that starts returning nil clears the ring (no
  stale extension). One wall-clock time base for the whole scenario.
- Lifecycle regression (fully isolated): synthetic `AccountEarningsFetching`
  stub (never the live `AuthenticatedEarningsClient`), a temporary
  `UserDefaults` suite for `electricity.*` via the new `energyPreferences`
  injection, and an `EnergyRecorder` pointed at a throwaway temp file — no
  user defaults mutation, no production energy history. Asserts `start()`
  samples with no dashboard/window; repeated `start()` neither duplicates nor
  restarts the task (immediate-read counting with a 1 h cadence);
  `await stop()` clears state and reads nothing further.
- Rendering: label footprint exactly 96×18 with ring nil/0/50/100; status
  item stays 104 pt with a live ring; a native bitmap render asserts arc
  geometry (half ring covers east, not west) and real tint pixels
  (red/yellow/gray-track classification), plus an env-gated PNG capture
  (`DARKBLOOM_RENDER_EVIDENCE=1` → `/tmp/darkbloom-gpu-ring.png`) for human
  review of logo readability.

## Test execution status

- `swift build --target DarkbloomTelemetry` — passed (narrow proof while the
  app target was mid-rewrite by the concurrent card task).
- `DARKBLOOM_RENDER_EVIDENCE=1 swift test --filter MenuBarGPURingTests` —
  **exit 0, 12/12 tests passed** (full log preserved at
  `/tmp/gpu-ring-test.log`). This run compiled the whole package
  (telemetry + app + test targets), proving the implementation builds
  alongside the card task's current sources.
- Native render evidence written to `/tmp/darkbloom-gpu-ring.png` (strip of
  five full `MenuBarLabel`s: missing / 0 % green / 50 % yellow / 100 % red /
  42 % neutral). Deterministic pixel assertions in `nativeArcRender` verify
  arc geometry (half ring covers east, not west; zero leaves only track) and
  real tint pixels via `cacheDisplay` bitmaps; the PNG is for human review.
  Note: an external vision-model pass misread the strip (claimed a red ring
  in the "missing" row and six rows in a five-row render); the in-test
  assertions and the footprint tests contradict that — a nil ring never
  constructs a `Circle` at all — so it was treated as a vision artifact, not
  a defect. Codex's visual gate should confirm from the PNG directly.
- Full-suite regression run (baseline 728 tests / 93 suites) intentionally
  left to the coordinated integration pass to avoid racing the card worker's
  own focused suite and in-flight edits.

## Remaining limitations

- On GPUs whose `IOAccelerator` "Device Utilization %" is unpublished, the
  ring never appears (by design); the label silently falls back to the
  ring-less rendering rather than explaining why.
- Utilization is an average across GPU accelerators and is genuinely
  system-wide — during other apps' GPU work the ring will read high with no
  Darkbloom inference at all. The tooltip says so, but the glyph alone cannot.
- Temperature freshness is bounded by the 30 s extras poll; between polls the
  arc color can lag up to ~45 s behind a fast thermal change, and the tint is
  per-render only as fresh as `helperIsFresh` allows.
- The ring shows no animation by choice (menu-bar re-render cost); the
  dashboard's animated ring is unchanged.
- Dark/light appearance relies on system dynamic colors (label/system*); the
  1 pt arc has not been verified under increased-contrast accessibility
  settings.
- `menuGPURing()` recomputes per TimelineView tick (1 s); it is cheap pure
  arithmetic over already-published values, but a memoization could be added
  if profiling ever shows it matters.
