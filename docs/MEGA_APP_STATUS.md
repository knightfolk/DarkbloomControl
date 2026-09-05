# Current mega-app status — September 4, 2026

This is a current implementation/gap index, not a completion or release claim.
The full scope remains in MEGA_APP_INTEGRATION_PLAN.md, with the unified-window
and protected-warming specifications superseding the older conflicting text.
MEGA_APP_PROGRESS_AUDIT.md retains chronological evidence, including superseded
early descriptions. Do not use an early entry there as current status.

| Area | Authoritative implementation/evidence | Still required or unproven |
| --- | --- | --- |
| 0: contracts | TELEMETRY_CONTRACT.md, PUBLIC_API_CONTRACT.md; independent typed public clients; inline degraded fixtures and transport tests; four live public endpoints decoded September 4 | Planned standalone PublicAPI fixture directory/decoding artifact is absent; full field-to-source audit, full-client cancellation and adverse live transport cases remain. Attribution notice is conditional on actual licensed code reuse. |
| 1: shell | DashboardWindowController, DashboardRootView, shared MonitorStore; one retained window for Settings/Dashboard; isolated reuse, restoration, draft and light/dark minimum-size cases | Live current-build gear/Command-comma, keyboard/VoiceOver, cross-process multi-display restoration and complete state matrix. |
| 2: Activity | ActivitySeries, ActivityQuery, ActivityView and local SQLite queries; calendar date range, exact model filter, separate rewards, table summaries and explicit gaps | Full live ledger reconciliation/coverage, boundary behavior and accessibility verification. UTC-hour aggregates cannot precisely split partial local-hour boundaries. Projection is not enabled. |
| 3: Opportunity | Separate capacity/catalog/pricing/series sources, backoff+jitter, total resource limit, loopback tests and live successful HTTPS smoke test; raw factors and RAM-minimum comparison | Every recommendation's complete factors/ages and full compatibility proof; a balanced profitability score is not established. Conditional requests need upstream support verification. Demand-first observations are not profit forecasts. |
| 4: operations | Shared Models editor with My Catalog/Available, separate controls, metadata, demand/pricing/performance/work context; Health/Logs, redaction preview/export, bounded retention and measured churn optimization | Verified log model attribution/filter; manual doctor contract; broader hardware/competing-service context; native export failure/keyboard cases and full privacy/state audit. Work earnings are explicitly partial, not complete realized payout coverage. |
| 5: lifecycle/warming | ProviderControlStore/Service reconciliation and safety tests; protected warmup gate, hysteresis and cooldown | Signed provider support for protected warming and safe runtime proof. Keep Coming Soon; do not revive the superseded eviction-capable request path or interrupt customer work. |
| 6: Fleet | Deliberately not enabled | Stable ownership/identity contract before implementation; remote control excluded from the first dashboard release. |
| 7: Energy | Nonprivileged thermal/provider-memory context | Energy is opt-in and not implemented: supported sensor, tariff, coverage, retention and cost integration remain conditional work. No helper/privilege installation authorized. |
| 8: packaging | Kernel single-instance guard/tests; REVIEW_LAUNCH.md records exact-artifact review procedure | Repeatable bundle assembly and CI, one canonical bundle identity, safe old-build detection/activation, upgrade/migration/rollback proof, signing/notarization, checksums/provenance/SBOM and clean-account Gatekeeper acceptance. No current publication authority. |

## Current runtime and pending user choices

- Superseding provider choice, September 4 at 18:02 Phoenix: user rejected
  increasing the memory cap and requested one slot, all downloaded supported
  models except OSS, and Qwen 3.8 as the sole startup preload. Exact enabled
  IDs are `EigenLabs/Qwen3.8-27B-4bit-mtp`, `gemma-4-26b-qat-4bit`,
  `qwen3-vl-30b-a3b-instruct`, `qwen3.5-35b-a3b`, and
  `qwen3.6-35b-a3b-vl-mtp-mxfp8`. Qwen 9B remains excluded under the earlier
  removal request. Unrelated downloaded audio models are not in the serving
  catalog and were not enabled. Config backup is
  `~/.config/darkbloom/provider.toml.before-single-slot-20260904`.
  CLI start completed with those five explicit selectors after an idle check;
  live PID 82572 and daemon timestamp 1788570179.898396 confirm all five
  advertised and Qwen 3.8 alone warm. Config `max_model_slots=1` and sole
  Qwen preload verified. No memory override was applied. Simultaneously warm
  Gemma and Qwen is no longer the requested runtime acceptance criterion.

- Historical two-slot experiment, September 4, 17:56 Phoenix: PID 78962 ran with
  Qwen 3.8 and Gemma launch selectors. The canonical provider config enables
  and preloads both with two slots. Fresh daemon telemetry reports no warm
  models and a Gemma load error: 22.4 GB available versus 23.9 GB required.
  These are error-time memory figures, not a current free-memory measurement.
  Local CLI source resolves the canonical config by default, so omission of
  `--config` alone is not evidence that settings were ignored. Its admission
  failure text can say all models are serving when no eviction candidate is
  found; that wording must not override `inference_active=false` telemetry.
  No additional restart, memory-safety override, or unrelated app termination
  was performed during this check. Both-model runtime acceptance remains open.
  Follow-up telemetry at Unix 1788569791 reports Qwen warm and inference active
  under the same live PID: service recovered for Qwen without intervention.
  Preserve that customer work; Gemma simultaneously warm remains unverified.

- Latest inspected monitor: PID 58793, launched at 15:45:41. Its executable
  mapping predates the rebuilt release even though the path matches. A live lock
  descriptor was observed; lsof also warned about an unrelated inaccessible
  Time Machine mount, so broad process inspection was not claimed exhaustive.
- Provider configuration remains outside current UI work. Do not restart it for
  a monitor-only update or assume absence of a customer job.
- Replacing the monitor is paused until unsaved-settings safety is established.
  Native inventory has not exposed the raw SwiftPM monitor; do not retry an
  app-name lookup, which previously launched an obsolete registered fixture.
- Qwen 9B was removed from the cache into its exact Trash location. Permanent
  deletion still needs the pending at-action confirmation; never empty unrelated
  Trash items. The separate synthetic Documents export cleanup exception also
  remains recorded in the task history and needs exact-target revalidation.

## Verification boundary

Latest full regression run reports 531 tests in 55 suites passing, including the
appearance cases; the opt-in live-public smoke test is explicitly skipped in this
run (/tmp/packaging-preflight-tests.log). Four live public endpoint cases passed
separately when opted in. Release build after the latest production change and
the current whitespace check pass. These do not substitute for the remaining
live UI, multi-day performance, migration or release gates.

Packaging preflight recorded checkout HEAD 6945b6492fb0c1f521d0a723e3153a5f71b9f914
with substantial uncommitted work. The existing release executable SHA-256 was
026f4950988e11144842e7d87febc9982e3fbe7b69e9de0510a279dce662d5d8.
This fingerprints that local file only; it is not a released artifact or a claim
that the dirty sources are represented by HEAD. Isolated-worktree consent is
pending before executing the packaging plan.

## Next safe implementation checkpoint

Create a repeatable local app-bundle assembly path and artifact manifest, with
tests for executable/resources/identity placement. Do not launch, register,
publish or sign as a distributor during assembly. Preserve the current running
monitor and provider. CI authoring may follow locally; pushing workflows or
publishing artifacts requires separate authority. Once draft safety is answered,
use the exact built artifact for a scoped monitor-only relaunch and native review.
