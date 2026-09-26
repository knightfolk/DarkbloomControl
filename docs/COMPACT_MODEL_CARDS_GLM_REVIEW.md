# Compact grouped model cards — GLM implementation review

Branch `codex/fan-gpu-controls` (base `f9b65d1`), worktree
`/Users/kevink/.codex/worktrees/darkbloom-fan-gpu/DarkbloomCLIMenuBarMonitor`.
Implemented under the compact-card file ownership:
`Sources/DarkbloomMonitor/ModelManagerView.swift`,
`Tests/DarkbloomTelemetryTests/ModelCardSummaryRenderingTests.swift`,
`Tests/DarkbloomTelemetryTests/ModelManagerPresentationTests.swift`,
new `Tests/DarkbloomTelemetryTests/ModelGroupingTests.swift`, and this report.
No other source files were edited; the GPU worker's in-flight
`MonitorStore.swift`/`StatusItemController.swift`/`ProviderResourcesView.swift`
changes were preserved untouched.

## What changed

### Two collapsible groups replace the tab/picker layout
- The "On this Mac / Available / Capacity" segmented picker is gone. The model
  list is now exactly two disclosure groups — **Enabled** and **Available** —
  each with a count badge and a one-line subtitle, plus a separate collapsed
  **Provider capacity** disclosure (settings, not a model group) and the
  existing catalog-notices disclosure.
- `ModelGrouping.partition(myCatalog:available:search:isEnabled:)` merges and
  dedupes the catalog, applies search to both groups, and partitions by the
  staged draft via the existing `isEffectivelyEnabled`, so unsaved
  enable/disable changes move cards between groups immediately. An
  undownloaded model that is staged-enabled honestly appears in Enabled.
  Available contains downloaded-but-disabled **and** undownloaded models
  (downloaded first); there is no separate "Not downloaded" section. All
  local-only (`myCatalog`) entries are preserved.
- Collapsed state persists in app-scoped defaults:
  `models.group-collapse.v2.enabled` / `.available` / `.capacity`
  (Enabled/Available default expanded, capacity collapsed). While a search is
  active, groups with matches render expanded so results are visible.
- Real hosting controls are unchanged in behavior: staged enable/preload
  toggles, delete gates (sheet only), download/cancel flow with progress,
  draft footer (Refresh / Discard / Save / validation), and all existing
  accessibility identifiers (`model.<id>.card/.enable/.preload/.delete/
  .download/.metadata`, `models.save`).

### Compact card redesign (~half the footprint)
- Previous card face alone was a fixed 336pt block inside a ~530pt card with
  large ghost icons and an always-open controls block. The compact card is
  now: identity row (family logo or capability SF symbol, name, vendor ·
  type · size line, residency pill) → three inline stats → Runtime what-if
  row → one controls row. `ModelCardLayout.estimatedCardHeight` is 268pt and
  rendered cards measure ~250–300pt including controls (`rendersCompactCard`
  asserts 150–330pt at both 300pt and 400pt widths).
- **Grid**: two bounded columns. `columnCount = width ≥ 2*300+14 ? 2 : 1`
  (threshold 614pt content width; 613 → 1, 614 → 2), and
  `cardWidth = min(400, available/columns)`, i.e. a ~300pt floor and 400pt
  ceiling with 14pt spacing, left-aligned with the group header. In the
  1280pt manager fixture (1240pt content; the live app also has a sidebar) the grid renders two 400pt columns;
  wide windows keep bounded cards rather than stretching them.
- **Stats row**: each stat is icon + value on one line, unit caption under
  the value (so full money amounts like `$1.20`/`$11.88` never truncate at
  300pt), then a label caption. Downloaded cards show measured speed,
  network demand, and the derived earnings rate; slots without history are
  filled with catalog facts (minimum RAM, capabilities) rather than dashes,
  and a single caption explains what is still learning. A demand tile is
  omitted entirely when no fresh network reading exists. Undownloaded cards
  show download size, demand (when fresh), and minimum RAM.
- **Identity/logos**: bundled family logos (Qwen/Google/OpenAI/NVIDIA/PrismML)
  tinted with the vendor accent; models without a bundled logo use a
  capability SF symbol — the Darkbloom app mark is no longer borrowed as a
  vendor identity.
- **Controls row**: downloaded cards use compact checkboxes (`ModelOptionToggle`
  checkbox variant; the expanded Manage sheet keeps switches — fixed-size
  switches crowded the card's action into a sliver in narrow columns) plus a
  fixed-size **Manage** button. Undownloaded cards keep a prominent
  vendor-tinted **Download** button plus a fixed-size **Details** button
  opening the same sheet, so details/forecast assumptions are reachable from
  every card (`ModelManagerPresentation.compactEntryActionLabel`).
- **Muting**: undownloaded cards mute informational content at 0.62 opacity
  with a lighter card background while the Download action stays fully
  opaque and enabled whenever allowed. No color-only meaning anywhere
  (demand always pairs its tinted shield with text).

### Independent what-if runtime (per user steering)
- Every compact card has a 0–100% Runtime slider (step 5) and a one-line
  estimate. It is explicitly an **independent what-if** — not a schedule,
  not bound to a real scheduler, and with **no shared 100% cap across
  models**; each model can explore the full range alone. Values persist per
  model in `models.what-if-runtime-v1` (sanitized on restore: 0–100, bounded
  ids, ≤128 entries — covered by `ModelGroupingTests`).
- The old shared-budget machinery (`maximumRunPercent`/`totalRunPercent` and
  the `models.daily-serving-schedule-v1` storage) was removed from the card
  UI. Note: previously saved schedule values under the old key are now
  orphaned/ignored — an intentional semantic change, flagged here.
- Estimate honesty: at 0% it states "0% runtime · estimated $0/day"; with
  calibrated data it shows the derived net/gross per day labeled "what-if,
  not actual"; with only measured speed it shows a tokens/day estimate and
  "earnings unmeasured"; with nothing it states the absence. No fabricated
  rates. Verified strings in `ModelManagerPresentationTests`.
- The expanded Manage sheet keeps full details: metric tiles, opportunity
  grade, the richer estimate breakdown, and the assumptions caption.

### Earnings attribution (per docs/research/STAT_ATTRIBUTION_REVIEW.md)
Earnings history is account-level (may include other machines) divided by
this Mac's locally observed active hours — a derived rate, not income
measured on this Mac. The card therefore labels the stat **"Derived rate"**
with unit `gross/hr` (help text explains account-level attribution), the
sheet tile is "Earnings per active hour … net derived from account earnings
minus estimated power", and the what-if assumptions disclose that the
scenario *assumes this Mac produced the account earnings recorded for this
model* until provider-aware tracking ships. Nothing is called "measured"
except locally sampled speed.

## Tests

Focused run (Swift Testing, `swift test --filter
"ModelGroupingTests|ModelCardSummaryRenderingTests|ModelManagerPresentationTests"`):
**34 tests / 3 suites, all passing** (`TEST_EXIT=0` on the final layout).

- `ModelGroupingTests` (new, 8 tests): partition into exactly two groups,
  staged-draft transitions, undownloaded-staged-enabled honesty, search
  across both groups by name/id, dedupe, downloaded-first Available order,
  collapse-key format, and `decodeRuntime` sanitization.
- `ModelCardSummaryRenderingTests` (rewritten): two-column boundary math
  (613/614, 680/1060/1240/1440), bounded card width (333 @680, 400 ceiling,
  260 shrink case), compact-card height assertions at 300/400pt with real
  `DownloadedModelRow` checkboxes and the real fixed-size entry button,
  `compactEntryActionLabel` Manage/Details contract, controls-row layout
  sanity, and (under `DARKBLOOM_RENDER_EVIDENCE=1`) windowed, settled
  snapshots of the real `ModelManagerView` with a synthetic no-provider
  controller at 640/1280/1480 plus a dedicated four-card 2×2 render.
- `ModelManagerPresentationTests` (updated): the shared-budget test was
  replaced by `runHoursPerDay` checks and what-if estimate-line coverage
  (zero/net/gross/tokens-only/absence + attribution-disclosure strings). All
  row-presentation, deletion-gate, download-gate, and sanitizer tests are
  unchanged and passing.

## Render evidence (DARKBLOOM_RENDER_EVIDENCE=1, native bitmap scale, dark mode)

- `/tmp/darkbloom-model-card-300.png`, `/tmp/darkbloom-model-card-400.png` —
  bounded card widths; full money (`$1.20`, `$11.88/day`), unit-under-value
  stats, checkboxes, Manage readable. (Earlier `-350`/`-440` files are from
  the superseded 3-column iteration and retained only as history.)
- `/tmp/darkbloom-models-2x2-1280.png` — four cards in two 2-column rows
  (2 enabled, 1 downloaded-disabled, 1 undownloaded) at the native window
  width; verified no truncation, correct muting, Download+Details on the
  undownloaded card.
- `/tmp/darkbloom-models-grouped-640.png` / `-1280.png` / `-1480.png` —
  narrow (single column), default (two 400pt columns), wide (bounded
  two-column) real-view renders with a six-model fixture including partial
  telemetry (measured speed on one model, calibrated earnings on another,
  sub-2-hour learning state on a third, fresh demand on three).
  (`-720`/`-1100` are from the superseded iteration.)
- Note: evidence renders put the view in a temporary `NSWindow` and drain
  the main run loop for ~0.6s before capture; `ImageRenderer` alone leaves
  the `TimelineView`+`GeometryReader` content blank.

## Remaining risks / notes

1. **Full suite not run here** — root runs final integration (baseline
   728/93). Other suites reference only unchanged symbols
   (`ModelManagerPresentation.availableRow`, `ModelRowPresentation.make`).
2. **Attribution is labeled, not fixed**: account-level earnings attribution
   and derived-net semantics remain until provider-aware storage lands
   (see `docs/research/STAT_ATTRIBUTION_REVIEW.md` plan).
3. **Old schedule defaults orphaned**: `models.daily-serving-schedule-v1`
   is no longer read; what-if runtime lives under
   `models.what-if-runtime-v1`.
4. Very wide windows show intentional empty space right of the bounded
   400pt columns (left-aligned per approval); long catalogs scroll inside
   the group area (evidence viewports crop at 1000pt height by design).
5. While a search is active, groups with matches are forced expanded;
   collapsing during an active search takes effect after the search clears
   (persisted state is always written).
6. `Tests/NativeUI/ModelsFixture.swift` (not owned) still compiles unchanged
   against the new view (`ModelManagerView(store:)` signature preserved).
