# Compact model cards, GPU ring, and Darkbloom 0.9.9 audit

Local review checkpoint on `codex/fan-gpu-controls`, based on v1.6.0 (`f9b65d1`).
GLM-5.3 implemented the cards and GPU ring through ZCode; GLM-5.3-Flash researched
the official CLI, coordinator, local inference server, and provider console.
Codex owns integration and independent verification.

## Changes available for review

- Compact model cards in two bounded columns (300–400 pt; one column below
  614 pt of available content), with model-family graphics and readable metric summaries,
  and two collapsible catalog groups: Enabled and Available. Undownloaded models
  remain muted in Available, with Download and Details actions.
- An independent 0–100% daily-runtime what-if slider on every card. Estimates
  use observed history when available, disclose account-level attribution, and
  do not schedule work or alter provider configuration.
- A whole-Mac GPU utilization ring around the menu-bar model logo, with fresh
  GPU temperature determining green/yellow/red. Missing temperature is neutral;
  missing utilization omits the ring. Sampling continues while windows are closed.
- A source-pinned audit of Darkbloom 0.9.9, a route inventory, provider-aware
  statistics/chart migration plan, and demand-based warming feasibility findings.

## Scope still open

- Fan controls are not implemented in this checkpoint. Official Darkbloom limits
  its helper to 60–90% and one temperature trigger. True 100% and a custom curve
  require a separate privileged controller. The user was asked to choose that
  controller scope or the official limited controls; the choice is pending.
- Richer persistent statistics/charts and proactive warming are documented plans,
  not implemented capabilities. No warm-up inference was sent. Exclusive self-route
  prevents paid fallback but targets the account's machines and can evict idle
  models; it is not an atomic no-eviction warm API.
- This is a local Beta review, not a production release or a claim that the
  entire fan/statistics request is ready to merge.

## Verification

- GLM card suite: 34 tests in 3 suites passed, with real native render captures
  at 300/400 pt per card and narrow/default/wide grouped layouts. Codex inspected
  the 300 pt card and the four-card 2×2 render directly.
- Codex final integrated `swift test`: 750 tests in 95 suites passed.
- Codex final `swift build -c release`: passed.
- GPU suite includes validation/freshness, tint boundaries, 0/50/100% arc pixels,
  missing-data behavior, fixed menu-bar dimensions, and sampler lifecycle.
- `git diff --check`: passed.
- Local Beta is ad-hoc signed and verified; it has a separate bundle identifier
  and data/lock directory. Sparkle release feeds/signatures are absent.

### Local launch observation

Launching an earlier package with Launch Services (`open -n`) caused its model
list CLI child to stall while scanning the Hugging Face cache. The cache points
to the mounted Sol volume. The same packaged executable launched directly through
the review workflow loaded the complete catalog successfully. Read-only standalone
checks of the app runner, decoders, and provider refresh also passed. The cause of
the Launch Services difference was not established; do not claim it was a TCC issue.
The current review uses direct execution. Distribution launch remains a release
verification item.

### Final Beta identity


- Bundle: `/Users/kevink/.codex/worktrees/darkbloom-fan-gpu/DarkbloomCLIMenuBarMonitor/.build/review-fan-gpu-2x2-20260925/DC Beta.app`
- Identifier: `dev.darkbloom.monitor.beta`
- Local version/build: `1.6.1` / `16001`
- Executable SHA-256: `702b440447e66dbad04d0f5b353de4baec782e72925c61f85edf77f016419ca5`
- Executable inode: `179258403`
- Source hashes and bundle manifest: beside the bundle in its review output directory.

### Live native review (completed 2026-09-26 local)

- Direct-launched Beta PID 31655, mapped executable inode 179258403, and one
  live Beta lock owner match the package. Every packaged source hash matches
  the current checkout. Production PID 5089 and provider PID 4673 remain running;
  the provider configuration SHA-256 is unchanged from the pre-review snapshot.
- Open Dashboard shows all 10 live catalog models, 3 Enabled and 7 Available,
  in two bounded columns. All primary controls remain readable at normal scale.
- Gemma runtime moved from 0% to 50% (12 hours): only that model changed, the
  estimate used measured token throughput and stated earnings were unmeasured,
  and Save Changes stayed disabled. The test slider was restored to 0%.
- Collapsing Enabled exposed the four downloaded Available cards in a 2×2 grid.
  Muted undownloaded cards retained readable Download/Details buttons. Details
  opened the forecast/assumptions sheet without starting a download. The sheet
  was closed and Enabled restored to expanded.
- Native automation initially selected the app's pre-existing empty SwiftUI
  Settings scene; app menu → Open Dashboard opened the real window. This is
  distinct from the earlier Launch Services CLI scan issue.
- GPU ring visual evidence is the native rendered fixture plus pixel/layout
  tests. This checkpoint does not claim a new full-desktop menu-bar screenshot.
- No provider settings, fan settings, model downloads, or inference requests were
  changed or sent during the review.
