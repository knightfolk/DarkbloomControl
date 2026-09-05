# Mega-app progress audit

For the current phase-by-phase status and next checkpoint, read
[MEGA_APP_STATUS.md](MEGA_APP_STATUS.md). Entries below are chronological and
early descriptions are superseded by later implementation evidence.

Evidence checkpoint: 2026-09-04. This is a working-tree audit, not a release or full-goal completion claim.

## Verified baseline

- The native popup and retained Settings window exist in `StatusItemController.swift`.
- App-menu Settings now forwards to that retained window rather than constructing a second settings root. Live inspection showed the Models page, one selected slot, and Qwen 3.8 Loaded without a stale-state warning.
- The latest verification ran 438 tests across 28 suites, a release build, and `git diff --check` successfully. This proves the tested baseline, not the unimplemented phases below.
- Provider processes were not restarted for the Settings routing change.

## Remaining scope against the integration plan

| Checkpoint | Current evidence | Remaining proof or implementation |
| --- | --- | --- |
| Dashboard shell | DashboardWindowController and Overview now exist; shared MonitorStore, sidebar and Open Dashboard routes are wired | Cross-launch restoration and broader accessibility/state-matrix proof remain; dedicated sections below are unfinished |
| Calendar Activity | Local ledger query and Activity chart/table now implemented; Today, This Week and single-date filters | Rendered chart verification, selected date ranges, per-model series, refresh-on-ingest and stronger coverage proof |
| Network/Opportunity | NetworkCapacity source and tests exist | Dedicated dashboard presentation and complete planned source/contract coverage; no income guarantees from capacity |
| Models/operations | Model manager and lifecycle controls exist | Dashboard integration and requirement-by-requirement operation reconciliation audit |
| Live switching | UI includes a Coming Soon gate | Supported signed provider capability and safe runtime verification; do not bypass the gate or interrupt customer inference |
| Fleet/Energy | No dedicated implementation established | Remain optional and gated by the plan's identity, permission and source contracts |
| Packaging | SingleInstanceGuard and tests exist | Exact artifact signing/notarization, upgrade and Gatekeeper proof; no publication authorized by this audit |

## Next implementation checkpoint

Continue Phase 1 verification, then implement calendar Activity from the existing database. The shell now uses the existing MonitorStore and provider-control store without independent polling. Do not change provider configuration, restart the provider, or duplicate model-control state. Sidebar sections other than Overview explicitly report unfinished development; Models links to the existing Settings window.

Verify window reuse, close/reopen, minimum size, restoration, keyboard access, shared telemetry updates and normal-scale rendering. Retain the compact popup and existing Settings route. Preserve the current dirty worktree; this audit does not authorize a commit, push or release.

### Shell verification update

- 439 tests across 29 suites pass, including retained-window close/reopen behavior; release build passes.
- Live app-menu Open Dashboard and Shift-Command-D open the retained dashboard. Close/reopen retained CGWindow ID 1122 and its resized 800 x 600 frame.
- Inspected full-size and 800 x 600 screenshots: adaptive cards reflow, content scrolls, and no horizontal clipping was visible. The compact popup still fits its Dashboard, Settings and Quit controls.
- Overview showed live Qwen 3.8 Loaded/idle, observed throughput samples and completed jobs. Earnings were unavailable in this runtime snapshot and correctly omitted, so populated earnings rendering still needs fixture/live proof.
- The provider PIDs remained 70543 and 70553 throughout monitor relaunches. No provider restart or configuration change was performed.
- Cross-launch frame/selection restoration, comprehensive VoiceOver behavior, and populated earnings layouts remain unverified. Do not claim the whole shell acceptance matrix or mega-app goal complete.

### Cross-launch check: outstanding defect

The next live check selected Activity and recorded the dashboard AX frame at position (1420, 220), size 800 x 600. After terminating only the monitor and launching the same release binary, Open Dashboard reported position (4173, 100), size 800 x 612. Thus within-process reuse is proven but cross-launch frame restoration is not correct in this multi-display environment. Investigate frame persistence/restoration ordering and screen-coordinate handling before marking Phase 1 complete. The provider processes remained 70543 and 70553. No Activity implementation has been claimed from this verification work.

Further investigation: the initial controller-restoration regression test incorrectly retained the old window's autosave registration. Releasing that registration to simulate process exit makes the new-controller frame restoration test pass without changing restoration logic. The live 800 x 600 request was also below the toolbar-equipped window's effective minimum outer height. A valid-size cross-process check is still needed; do not treat the initial test failure as proof of a production root cause.

### Activity foundation and background testing

- `ActivitySeries.swift` now generates bounded local-calendar hour/day intervals. Tests prove 23/25-hour DST days preserve unique dates and continuous boundaries, partial ranges clip correctly, and oversized requests fail rather than truncate.
- Ledger query integration and chart views are not yet implemented. Preserve separate work and reward totals and explicit coverage when adding them.
- Existing persistence uses UTC-hour aggregates. A local range cutting a UTC-hour bucket cannot be apportioned exactly from that data. The query/presentation contract must explicitly mark boundary uncertainty rather than invent prorated earnings.
- Dashboard window tests now present behind other apps, without application activation.
- All nine launch-created Terminal processes were closed. The current monitor is launched through the temporary launchd job `com.darkbloom.monitor.codex-review`, with logs in `/tmp/darkbloom-monitor-review.log` and `/tmp/darkbloom-monitor-review-error.log`. Manage that exact job for future review launches; do not return to `open` on a raw executable, which launched Terminal instances. The provider was not restarted.

### Activity ledger/chart implementation

`EarningsDatabase.activity` now queries local hourly work/reward aggregates separately, including jobs and prompt/completion token counts. It does not request network data. The AccountEarningsFetching boundary and MonitorStore expose this query to ActivityView. The page provides Today, This Week, a selected date, a separate work/rewards chart, and a keyboard-accessible table with coverage labels. Refresh history only rereads local storage.

The new database test proves reward separation, work-only job/token counts, missing-hour gaps, and rejection of a partially overlapping UTC hour. Full verification: 444 tests in 30 suites pass, release build passes, and diff whitespace checks pass. No visual/runtime claim is made yet for the new Activity page; the running app has not been replaced with this build.

Remaining: rendered chart/table inspection, range selection beyond one date, automatic query invalidation after ingestion, per-model series, and explicit complete-coverage evidence. Current `recorded` coverage is a lower bound; empty buckets remain unknown even when older metadata suggests coverage, because that metadata does not prove uninterrupted historical ingestion. This is not completion of Phase 2.

### Activity refresh and rendered verification

Completed local-query invalidation via `MonitorStore.activityRevision` after each earnings acquisition, including unchanged headline totals. Activity's keyed task cancels superseded queries; cancelled responses are not applied. A regression test proves unchanged totals still invalidate history.

Inspected the populated background-window screenshot `/tmp/darkbloom-activity-window.png`. This exposed a collapsed table and incorrect mark geometry, both corrected. The final render shows stacked work/reward rectangles spanning the bucket interval, a readable period selector, a scrolling history table, and an unknown hour represented by a gap and unavailable table values. These are synthetic fixture values, not customer earnings. Render evidence can be regenerated with `DARKBLOOM_RENDER_EVIDENCE=1 swift test --filter ActivityViewTests`; normal tests do not invoke screen capture.

Verification: 446 tests across 31 suites pass; release build and whitespace check pass. No Terminal launch or provider restart was performed. Range selection, per-model series, full-coverage persistence, narrow-layout coverage and live Activity verification remain open.

### Inclusive calendar date ranges

Activity now offers From/Through dates on a separate filter row. The query includes the final selected day and uses daily buckets, capped at 366 calendar days. Invalid/reversed ranges produce an explanatory error rather than a crash or a silent swap. A regression test verifies that March 7–9, 2026 in New York spans 71 hours, ends at March 10 midnight, rejects reversed dates and enforces the limit. Full suite: 447 tests in 31 suites pass; release build and whitespace check pass.

Remaining visual proof includes the new date controls at minimum dashboard width. Per-model series, full-coverage persistence, midnight rollover while Activity remains open, and live Activity verification remain unfinished. The running review app has not been relaunched for this source change.

### Per-model ledger filtering

Added exact model filtering to the Activity ledger query, exposed through the shared client/store and a range-specific model picker. Base rewards are excluded from model-specific queries and explicitly labelled excluded in the table. Tests verify exact matching (not prefix matching), no-data behavior, reward exclusion, and range-specific model discovery. Full suite remains 447 tests across 31 suites, all passing; release build and whitespace check pass.

Coverage investigation confirmed that existing earliest-timestamp metadata is insufficient to prove uninterrupted history. No new complete-coverage claims or zero-filling were introduced. Per-model throughput series, stronger coverage persistence, filter/minimum-size visual checks, midnight rollover and live Activity verification remain open. The running review app is unchanged by this source/build checkpoint.

### Attributed throughput history

Found and removed query-driven deletion in ModelTokenRateDatabase. Reading today's averages no longer deletes yesterday's samples. Retention now occurs on writes, bounded to 31 days relative to the newest stored observation; previously deleted samples cannot be reconstructed. This increases future retained history without changing the arithmetic sample-mean definition.

Added exact-model calendar history with average, sampled min/max and count, leaving empty buckets unavailable. Activity's model-specific table displays average tok/sec instead of account rewards; accessible detail includes sample range and count. Tests cover non-destructive reads, retention, exact attribution, sampled peaks, gaps and protocol dispatch. Full suite: 450 tests across 31 suites pass; release build and whitespace check pass. Filtered/narrow visual proof and live Activity verification remain required. No running provider or database was modified by these fixture tests.

### Live Activity review at narrow width

Launched the current release through the same temporary background job; no Terminal process was created. Inspected real Today earnings/rewards, exact Qwen filtering with sampled throughput, and the inclusive date-range controls. The first 800-pixel-wide filtered table overflowed horizontally; corrected column widths and shortened the coverage label to Recorded. Also hid the irrelevant rewards legend when filtering to one model.

The final live screenshot `/tmp/darkbloom-activity-final-live.png` shows every table column including Coverage, with no horizontal scrolling needed at an 800 x 760 outer window. It shows Qwen work earnings, observed tok/sec, jobs, and unknown gaps. The date-range controls were separately inspected at the same width. Cross-launch width/height and Activity sidebar selection were retained; position restoration across display configurations is not comprehensively proven.

Fresh verification: 450 tests in 31 suites pass, release build and whitespace check pass. Running monitor PID 9366; provider PIDs remained 70543 and 70553. No provider restart or model/config change occurred. Remaining Activity requirements include midnight rollover, stronger complete-coverage tracking, query-race regression proof and minimum-height/date-filter combination review. Other dashboard phases remain unfinished.

### Calendar rollover and immutable query identity

Activity now uses a minute-aligned UI timeline and a typed ActivityQuery. The key includes resolved calendar interval, unit, calendar/timezone, exact optional model, ledger revision and manual refresh ID. It only invalidates the local query when those inputs change; ordinary minute ticks do not add network polling. Today/This Week advance at calendar boundaries, while selected historical dates remain fixed. All async reads use captured query inputs rather than mutable view state, and cancellation is checked before resetting presentation as well as before applying results.

Tests verify midnight rollover, fixed historical ranges, configured week boundaries and the distinction between no model filter and a literal model named all. Full suite: 452 tests in 32 suites pass; release build and whitespace check pass. The running review app has not yet been relaunched for this change. Delayed-response race injection and complete-coverage tracking remain unproven; other planned dashboard phases remain open.

### Opportunity capacity view

Added the Opportunity sidebar page using the existing shared capacity snapshot, without another network polling task. It shows alphabetically ordered/searchable model cards with active/queued requests, warm/routable provider counts, demand per warm provider, and separately labelled local catalog snapshot information. Data age and failed-refresh staleness remain visible; the page explicitly disclaims earnings forecasts and explains demand-band inputs.

Inspected a synthetic HTTP-429-after-success render at 570 pixels wide: counts remain visible, the stale warning is prominent, and model metrics fit. The render fixture exercises real MonitorStore refresh/degradation behavior and opens behind other apps; no Terminal is used. Full Phase 3 is not complete: source-specific catalog/pricing/network-series clients, cadence/backoff work, stronger compatibility evidence, recommendation factors and live Opportunity verification remain open.

### Shared capacity cadence and backoff

Replaced unconditional 30-second capacity polling with a policy: 60 seconds for an open dashboard, 300 seconds when closed/minimized, and 30 seconds when automatic switching is explicitly enabled. Failures exponentially back off with bounded positive jitter to a 900-second cap; valid acquisitions reset failures. Closing changes the next sleep calculation, so one already-scheduled request may occur at the previous cadence. Reopening stale data wakes the collector only outside failure backoff. A replacement polling task awaits its cancelled predecessor, preserving the shutdown ownership chain.

Dashboard lifecycle delegates update visibility, and tests verify open/close state as well as cadence, failure growth, cap and reset. Automatic-switch evaluation keeps its independent 30-second local evaluation cadence. Full verification: 455 tests in 34 suites pass; release build and whitespace check pass. These source changes have not yet been relaunched into the review app. Long-duration cadence observations and preference-change wakeup behavior remain to be checked.

### Capacity streaming byte limit

Replaced capacity's whole-body download followed by a size check with a streaming reader. It checks HTTP status and declared length before collecting, enforces the 256 KiB bound during iteration, checks cancellation, and cancels the URLSession task on exit. A counted async source proves it stops at cap + 1 bytes, accepts an exactly capped body, and consumes no bytes when already cancelled. Release build passes; full suite now has 457 passing tests across 34 suites. Live transport/cadence observation and the remaining public-source integrations are still open. The running monitor/provider were untouched in this checkpoint.

### Live Opportunity transport review

Rebuilt the current release successfully and replaced only the exact review launchd job. Monitor PID 67187 is running; provider PIDs 70543 and 70553 are unchanged, and no Terminal processes were created. Inspected `/tmp/darkbloom-opportunity-live.png` at the restored 800-pixel outer width: the streaming collector returned a current snapshot (15 seconds old), with readable active/queued/warm/routable metrics and demand labels. This proves live acquisition and rendering, not long-duration polling behavior or profit forecasting.

The live cards report `Local catalog match unavailable`, including Qwen 3.8. The next investigation is whether the shared provider-control snapshot is acquired on this route and whether exact catalog identifiers match; do not present this as proof the model is absent. Pricing, full compatibility/recommendation evidence, Models and Health dashboard integration, and other plan requirements remain unfinished.

### Local catalog acquisition investigation

The startup path does request `ProviderControlStore.refresh()`, and Dashboard receives the same store from StatusItemController. Opportunity currently keeps that optional store as a plain `let`, not an observed object. Exact-ID matching cannot yet be evaluated against a fresh live catalog: the same read-only `models catalog --config … --json` command used by the service produced no output after 21 seconds, exceeding the service's 15-second catalog timeout. Terminated only that diagnostic child (PID 67474) and reaped its command session; no provider process was stopped. This supports a missing acquisition as a cause, but does not establish the underlying CLI/network reason. Next: bounded retry/error presentation preserving Settings drafts, reactive catalog observation, and tests before changing behavior. Do not fuzzy-match model identifiers to conceal missing source data.

### Opportunity catalog retry and observation

Added an observed catalog-status/retry header and observed per-model cards. Retry uses the existing bounded shared control refresh and preserves staged Settings drafts; it is disabled during operations or pending confirmations. Snapshot dates and refresh failures are shown without claiming network counts establish local model availability. Exact identifiers remain required.

The draft-preservation regression passes and was mutation-checked: replacing the handler with ordinary `refresh()` caused the expected staged-selection loss failure. The attempted in-process SwiftUI accessibility traversal could not locate children and was not retained as false UI proof. Full suite: 458 tests in 34 suites pass; release build and whitespace check pass. Relaunched only the monitor through the review launchd job (PID 68334). The live 800-pixel screenshot `/tmp/darkbloom-opportunity-retry-live.png` shows the refreshing status and disabled retry button without layout overflow. Provider PIDs 70543 and 70553 remain unchanged; no Terminal processes were created. Successful catalog acquisition, live exact-model matches, and card-update regression coverage remain open; the CLI timeout is not fixed by this UI recovery path.

### CLI timeout narrowed to model-cache filesystem access

Verified the CLI symlink resolves to the installed application executable and `--version` returns 0.8.16 immediately. A fresh direct-executable catalog command stalled as well. The one-second process sample `/tmp/darkbloom-catalog-sample.txt` shows `Models.Catalog.run -> loadRuntimeSnapshot -> ModelScanner.scanAllModels -> contentsOfDirectoryAtURL -> open`, not a pending HTTP request.

The Hugging Face cache symlink points to `/Volumes/Sol/LLMS/HuggingFace-cache`. Its hub directory metadata is readable, but a plain `ls -l` of that directory also produced no output for more than 11 seconds. Sol is mounted as local APFS; diskutil reports SMART Verified, which does not explain or rule out the directory-access stall. The underlying storage/access cause remains unproven. Stopped and reaped only diagnostic catalog PID 68530 and directory-list PID 68578. No cache links, files, mounts, provider configuration or running provider processes were changed. Remounting/repairing the shared volume would exceed this app-only investigation and could affect active models; do not attempt it without explicit direction.

### Dashboard Models route

Replaced the Models placeholder with `ModelsView`, composing the existing ModelManagerView against the same ProviderControlStore as Settings. This shares the staged draft, save/mutation safety checks, My Catalog/Available grouping, and existing capacity controls. Opening the page itself performs no acquisition and does not reset edits. Inspected `/tmp/darkbloom-dashboard-models.png`: the populated fixture fits a 570-pixel detail column, with grouped toggle labels, distinct Add/Delete controls and the unsaved-state footer visible. A hosted-view test checks that opening/layout leaves the staged draft unchanged. Full suite: 459 tests in 34 suites pass.

This is partial Phase 4 integration, not completion: canonical-ID/downloaded metadata expansion, contextual demand/pricing and attributed metrics, Health & Logs, and successful live catalog acquisition remain open. The running monitor is unchanged by this source checkpoint; no provider action or Sol modification occurred.

### Initial Health and Logs integration

Replaced the remaining Health & Logs placeholder with a segmented route. Source health reuses existing AdvancedSection diagnostics and timestamps; Logs reads the same bounded EventFeed, with intersecting severity/source filters and trimmed case-insensitive message/category search. Search does not mutate events or acquire more data. Existing EventRow keeps messages inert, selectable and redacted by the collector. Empty and stale feed states remain distinct from no filter matches.

Filter tests cover intersection, category search, default order and no matches. Inspected `/tmp/darkbloom-dashboard-logs.png`, a synthetic warning fixture at 570-pixel detail width. All 461 tests in 35 suites pass; whitespace check passes. This remains an initial integration: dedicated process/thermal/memory/slot health presentation, model attribution/filtering, byte-retention audit and explicit redaction-preview export are unfinished. Live combined-route review remains required. No provider, volume, or running-monitor change occurred in this checkpoint.

### Combined dashboard live review

Launched the current combined Models/Health/Logs build using the exact background review job, monitor PID 69961. Provider PIDs remain 70543 and 70553; no Terminal process appeared. Live Models shows the unavailable catalog safely rather than invented model rows (`/tmp/darkbloom-models-live.png`). Live Logs displays actual retained events and its search/severity/source controls within the restored 800-pixel dashboard (`/tmp/darkbloom-logs-live.png`). No save, model mutation or provider lifecycle action was invoked.

Live source health (`/tmp/darkbloom-health-live.png`) exposed repeated timeout placeholders for every CLI field. Changed the shared AdvancedSection presentation to show one source-unavailable diagnostic instead. A targeted count/reason regression was added; full suite now passes 462 tests in 36 suites. The single-diagnostic change is not yet relaunched or visually verified. Full health metrics, contextual model metadata, public pricing/series, coverage work and safe export remain unfinished; the Sol directory-access problem remains unresolved.

### Daemon-backed health summary and live proof

Added compact daemon-backed cards for process PID/start identity, CLI version, trust, inference state, reported slot count and GPU active/cache memory. No CLI command is required for these cards. They retain the daemon snapshot timestamp and overall status; memory is explicitly not free system RAM, and reported slot count is not a configured capacity limit. Advanced diagnostics now default collapsed.

All 463 tests in 36 suites pass, release build and whitespace check pass. Relaunched monitor only (PID 71072); provider PIDs 70543 and 70553 remain unchanged. `/tmp/darkbloom-health-summary-live.png` shows live online daemon data, one reported slot, and readable two-column cards at 800-pixel dashboard width. `/tmp/darkbloom-health-summary-expanded.png` verifies that the CLI timeout is now shown once, not repeated per absent field. No Terminal processes were created. Slot KV/MTP details, thermal reporting, public-source integrations and remaining plan requirements are still open.

### Public catalog client foundation

Re-probed the public catalog and pricing endpoints with bounded, unauthenticated requests; both responded in under one second while the local CLI scan remained independently problematic. The public catalog wraps its array under `models`, unlike CLI catalog output. Added PublicCatalogSnapshot/PublicCatalogClient without changing local model authority or the control-service path. The client enforces a 15-second request timeout and 256 KiB streaming limit, cancels its URLSession task on exit, and rejects HTTP failure. The decoder limits the catalog to 128 unique canonical IDs (512 UTF-8 bytes each), rejects invalid negative/nonfinite sizes or negative RAM, and accepts additive unknown fields. It uses CatalogModel's required metadata fields and makes no installation/enablement claim.

Tests cover envelope decoding, canonical IDs, additive fields, duplicate IDs, wrong envelope and negative size. All 465 tests in 37 suites pass; whitespace check passes. Remaining before UI use: independent owned polling/backoff/last-good state, live Swift client transport proof and transport failure tests, full limit-edge cases and source-age presentation. Pricing was observed but not implemented or interpreted as provider payout. No process restart or volume change occurred.

### Public catalog integration and live recovery

MonitorStore now owns an independent public-catalog collector: immediate startup acquisition, 30-minute successful cadence, exponential failure delay capped at six hours, overlap exclusion, cancellation and shutdown join. It retains last-good metadata explicitly stale on failure; a regression verifies that catalog failure does not change network demand. Opportunity uses exact canonical IDs to show public minimum RAM/model size separately from local downloaded/enabled evidence, with public snapshot age and stale indication. No new per-view fetch loop or fallback mutation authority was added.

Full suite: 466 tests in 37 suites pass, release build and whitespace check pass. Launched monitor PID 72429 only; provider PIDs remain 70543 and 70553 and no Terminal process was created. `/tmp/darkbloom-public-catalog-live.png` proves live Swift public-catalog acquisition and readable source-separated metadata at 800 pixels. The local catalog also succeeded on this launch and Qwen 3.8 matched exactly as downloaded/enabled. No cache, mount, provider or model setting was changed; the prior directory-access stall's underlying cause and recovery cause remain unknown. Do not continue reporting the local catalog as currently unavailable based on the earlier failure.

Remaining public-source work includes pricing, network series, stronger cadence/cancellation/failure edge tests, optional jitter, cache policy documentation and richer compatibility/recommendation evidence. Local card refresh observation is visibly working after acquisition, but a targeted delayed-update UI regression remains open.

### Customer pricing integration

Verified the public API console identifies `/v1/pricing` units as per million tokens (https://console.darkbloom.dev/api-console, checked 2026-09-04). The live response's integer/display pairs establish micro-USD conversion: 220000 corresponds to $0.2200. Added exact Decimal customer-rate decoding, canonical matching, nonnegative/duplicate validation, 128-row/256-KiB bounds and a 15-second streaming client. Fallback prices are intentionally not assigned as model-specific rates.

The shared store now owns separate 15-minute pricing polling, exponential failure backoff capped at six hours, last-good stale state and cancellation/shutdown joining. Regression tests verify exact conversion, unknown/case-mismatched IDs, invalid rows and retained stale pricing without changing realized earnings. Opportunity labels customer USD per 1M input/output tokens and explicitly separates these from provider payout.

All 469 tests in 38 suites pass, release build and whitespace check pass. Relaunched only monitor PID 73787; provider PIDs 70543 and 70553 remain unchanged, no Terminal processes were created. `/tmp/darkbloom-pricing-live.png` proves live Swift pricing transport and readable source-separated rates at 800-pixel width. Local catalog was still refreshing at capture time; no current local-state inference was drawn. Remaining: network history, contextual recommendation logic/compatibility, transport-edge/cadence tests, other health/model details, coverage and export/release gates.

### Explicit event payload retention bound

EventBuffer previously capped rows only. It now additionally caps retained UTF-8 category/message/process-image payload at 128 KiB, with caller budgets clamped to that maximum. It keeps newest fitting whole events, preserves deduplication and never truncates a retained event. Numeric/enumerated bookkeeping remains bounded by the existing 100-row cap; this is not a claim that all process or transient parse memory is limited to 128 KiB. Disk logs are untouched. Logs help text discloses budget-based omissions.

Tests cover multi-byte Unicode accounting, newest-first retention, pop accounting, oversized metadata, zero/negative budgets and attempts to bypass the global cap. All 472 tests in 39 suites pass; whitespace check passes. This source checkpoint has not replaced the running monitor. The updated help text still needs rendered review; explicit export preview and model attribution remain unfinished.

### Network history contract and client

The live `/v1/network/series?window=24h` response provides UTC start/end/update timestamps, a 1800-second bucket width and network-wide request/prompt/completion counts. It has no model attribution. Added a separate typed 24-hour series parser and bounded streaming client, preserving missing buckets rather than inventing zeros. Validation rejects duplicate/out-of-order/off-grid timestamps, negative counts, wrong windows/ranges, excessive rows and oversized bodies. No per-model demand inference or local calendar-earnings change was introduced.

Parser tests passed. The initial full suite hit two assertions in the existing single-instance release/reacquire test; that suite passed all eight tests immediately in isolation without edits, and a fresh full rerun passed all 474 tests in 40 suites (`/tmp/network-series-recheck.log`). This is an intermittent regression signal, not proof it is fixed. Release build passed. Network-series polling, chart/table UI, live Swift transport proof, stronger temporal edge tests and the lock-test investigation remain open. No monitor/provider restart was performed.

### Deterministic lock-release regression

Reproduced a release bug by duplicating the acquired lock's open file description: closing the owner's descriptor alone left the lock held by the duplicate, and a second owner could not acquire. The test resolves only its unique temporary lock by device/inode and uses `dup`, avoiding unsupported fork of the multithreaded Swift test process. It failed before the production change and passes after it.

SingleInstanceGuard.release now explicitly unlocks before close, retrying an interrupted unlock. This covers inherited pre-exec descriptor copies while retaining the held-owner/concurrent-launch checks and without signalling another process. Nine single-instance tests and all 475 tests in 40 suites pass; whitespace check passes. The exact historical full-suite failure was not traced to a fork, so inheritance is the likely explanation, not independently proven provenance. No running monitor or provider was stopped in this checkpoint.

### Network history collector and live chart

Added dashboard-visibility-gated network-series polling with five-minute success cadence, retained next-attempt time across reopenings, failure backoff capped at one hour, cancelled predecessor joining and shutdown cancellation. Closed direct refresh is a no-op; last-good history becomes stale on failure. A regression exercises closed/open/stale state without altering local data. This is separate from calendar-based earnings.

Opportunity now switches between Model demand and Network history. History provides requests/input/output bucket charts plus exact-value tables, with network-wide scope and the API's 24-hour window labelled explicitly. Missing buckets are not filled. Inspected a narrow synthetic gap fixture and live requests/output-token charts: `/tmp/darkbloom-network-history.png`, `/tmp/darkbloom-network-history-live.png`, `/tmp/darkbloom-network-output-live.png`. Live transport returned current half-hour network buckets; all table columns fit the 800-pixel dashboard.

All 477 tests in 40 suites pass, release build and whitespace check pass. Monitor PID 36208 is the current review release; provider PIDs 70543 and 70553 are unchanged, with no Terminal processes created. Long-duration polling/backoff and rapid reopen/shutdown stress tests remain open, as do recommendation/compatibility, model/health details, coverage and export/release requirements.

### Network-window boundary validation and axis readability

Added a failing regression showing that a final on-grid bucket could extend beyond the declared window, and that an update timestamp could precede the window end. Both are now rejected. Changed chart y-axis labels from scientific notation to compact counts, preserving exact values in the table. Inspected the updated 20-million-count gap fixture at `/tmp/darkbloom-network-history.png`: the axis uses 5M/10M/15M/20M and the table shows 20,000,000. Full suite passes 478 tests in 40 suites; release build and whitespace check pass. These changes have not yet replaced the running review app.

### Explicit opportunity factors

Added the plan's demand-pressure, warm-scarcity and queue-pressure formulas as descriptive factors in network model cards. Each value shows its formula; zero denominators use the documented floor of one with an explanatory warning, overload is not capped, and inconsistent warm/routable populations remain visible rather than silently clamped. Addition converts to Double before summing to avoid Int overflow. These values do not rank models, assert local fit, predict payout or authorize switching.

Three tests failed against the initial empty implementation and pass with the formulas, covering denominator identity, zero denominators, overload, inconsistent populations and Int maxima. Full suite passes 481 tests in 41 suites; release build and whitespace check pass. Fresh/stale 570-pixel fixtures were inspected at `/tmp/darkbloom-opportunity-fresh.png` and `/tmp/darkbloom-opportunity-stale.png`; a wrapping-induced vertical alignment issue was corrected and the render test rerun. Monitor PID 36208 and provider PIDs 70543/70553 remain untouched; no Terminal process exists. This build has not replaced the running app.

The full goal remains open: local-fit/compatibility evidence, attributed local payout context, source transport/cadence hardening, remaining health/model details, coverage/export, supported protected switching and release gates are not proved complete by this checkpoint.

### Thermal and slot health integration

Health now shows the existing macOS thermal observation independently of daemon availability and reuses SlotCard for each reported model's effective/requested KV backend and MTP enabled/active/reason. No new acquisition loop or CLI call was added. A five-second presentation-only timeline keeps an explicit last-known warning visible when daemon writes exceed ten seconds, are future-dated, or the source is stale/unavailable. This does not discard retained slot data or label it current.

The freshness regression failed before implementation and passes for current/boundary/expired/future/failed/unavailable inputs. Inspected retained-slot and missing-daemon fixtures at 570 pixels (`/tmp/darkbloom-health-slots.png`, `/tmp/darkbloom-health-missing.png`); thermal remains visible without a daemon and missing MTP reason is explicit. Render tests reject unexpected source acquisition. Full suite passes 483 tests in 42 suites, release build and whitespace check pass.

Replaced only the exact background review job after verifying Settings was not open. The new monitor PID is 38419, running the current working-tree release including opportunity factors and compact network chart axes. Provider PIDs remain 70543 and 70553; no Terminal process exists, and Godot remains the foreground app after launch. No provider/model/config change or commit/push occurred. New Health visuals have fixture proof, not a fresh live dashboard capture. The broader audit gaps above remain open, including advanced system/energy acquisition and release qualification.

### Public HTTP transport matrix

Added characterization coverage through the actual four URLSession clients using per-session URLProtocol responses, with no public requests or global mutable handler. Forty-eight cases cover valid empty envelopes, JSON padded to exactly 256 KiB, declared and undeclared 256-KiB-plus-one bodies, malformed JSON, HTTP 401/403/404/429/500, injected transport timeout and pre-cancelled acquisition. The boundary assertions verify source-specific errors, exact capture-date propagation, GET/HTTPS/host/path/query/Accept, configured 15-second request timeout and absence of Authorization. A pre-cancelled fetch fails if it reaches the transport.

All existing implementations passed this matrix without production edits; this is additional proof, not a newly fixed HTTP bug. Full suite passes 489 tests in 43 suites and whitespace check passes. Monitor PID 38419 and provider PIDs 70543/70553 remain unchanged, with no Terminal process. No release rebuild is required for test-only changes.

Still unproved: actual elapsed deadline enforcement, mid-stream cancellation/reclamation, conditional caching, redirect behavior, timed backoff/jitter/reopen/shutdown stress and cross-source UI failure matrix. Injecting URLError.timedOut proves error propagation only, not a real fifteen-second timeout. The overall goal remains active.

### Deterministic history polling lifecycle

Introduced an injected sleep dependency for the four public polling loops; production still uses Task.sleep with the same calculated intervals. A controlled clock and cancellable sleeper now exercise the real MonitorStore loop rather than calling refresh directly. The test proves initial five-minute cadence, HTTP-failure backoff to ten minutes, cancellation on close, preservation of the remaining 500-second delay after reopening 100 seconds later, recovery to five minutes after success, and shutdown joining/removing the pending sleep. All fake services are isolated from local credentials, files and the network.

A deliberate temporary mutation clearing the retry deadline on reopening failed four assertions, including the observed 300-versus-500-second delay and extra request count. The mutation was removed before full verification. All 490 tests in 44 suites pass, release build and whitespace check pass. The test has bounded real-time failure guards and shuts the store down on thrown failures.

This proves the covered history lifecycle, not long-duration live scheduler behavior, in-flight transport cancellation, all public-source timers or jitter. No UI changed or runtime restart occurred: monitor PID 38419 and provider PIDs 70543/70553 remain, with no Terminal process. The latest release build is newer than the running monitor only for the sleep-injection refactor; production delay behavior is unchanged.

### Model identity, RAM and download-size provenance

Downloaded rows now show minimum RAM and explicitly label catalog size as an estimate. ModelInventoryItem additionally carries optional locally reported download bytes, populated only from a single exact-ID nonnegative local record; duplicates, mismatched case, absence and invalid sizes do not produce measured-size claims. The local report is not a fresh filesystem scan. Canonical IDs are selectable in both My Catalog and Available rows. Enable/Preload/Delete semantics and staged configuration remain unchanged.

The size-provenance test failed before builder integration and passes after it. The shared Models render at 570 pixels (`/tmp/darkbloom-dashboard-models.png`) shows catalog estimate and local bytes as separate values with grouped controls; the existing test confirms the staged draft survives rendering. All 491 tests in 44 suites, release build and whitespace check pass. No monitor/provider restart occurred (38419, 70543/70553); no Terminal process exists. These metadata changes are built but not yet live-reviewed. Contextual model demand/pricing, attributed local performance/payout, richer compatibility and the remaining full-goal gates are still open.

### Catalog RAM compatibility factor

Opportunity now compares installed physical memory against the catalog minimum only when public metadata is fresh and the canonical model ID matches exactly. It displays the installed GiB value and whether the minimum is met, below minimum or unavailable. Zero/negative/missing requirements, missing installed memory and stale/mismatched metadata cannot establish a fit result. The calculation follows the existing provider memory convention and explicitly excludes swap, current free memory, slot availability and hardware-feature compatibility; it is neither full localFit nor authority to load/switch.

Boundary tests failed before the calculation and pass at one byte below/exactly at/above the minimum, with insufficient-evidence cases. Fresh/stale fixtures were inspected at 570 pixels (`/tmp/darkbloom-opportunity-fresh.png`, `/tmp/darkbloom-opportunity-stale.png`); stale metadata removes the affirmative RAM result. All 493 tests in 45 suites, release build and whitespace check pass. Monitor/provider processes remain 38419 and 70543/70553, with no Terminal. This source checkpoint is not yet launched. Free-capacity/hardware support and the broader compatibility/recommendation, energy, export and release requirements remain open.

### Event-retention privacy correction

Export investigation found that earlier descriptions of a generally redacted event buffer were too strong: LegacyLogParser retained ordinary warning text, UnifiedLogParser only recognized macOS's `<private>` marker, and EventBuffer retained both unchanged. Synthetic credential/payload/path regressions reproduced eleven failed assertions. No actual user secrets were used in the tests.

EventPrivacy now normalizes controls, withholds whole fields bearing known credential, identity or customer-payload markers, strips URLs and replaces home paths before EventBuffer retains the event. Raw oversized events are rejected before matching, then sanitized results are also byte-budgeted. Timestamp, source, severity and PID remain available; ordinary prompt_tokens/completion_tokens counters are preserved. This is conservative known-pattern filtering, not proof that arbitrary unmarked prose contains no private data. Logs wording now says review before sharing. Source files are not edited, and export remains unimplemented pending its preview/confirmation and stronger privacy contract.

Regressions and all 496 tests in 46 suites pass; release build and whitespace check pass. Inspected `/tmp/darkbloom-dashboard-logs.png`: operational warning remains readable and the synthetic credential field is withheld. Replaced only the background review monitor after verifying no windows/drafts were open. PID 41345 now runs this current build (also including model size/identity, RAM comparison and sleep-injection changes). Provider PIDs remain 70543/70553, no Terminal process exists, and Godot is foreground. No raw logs, provider settings or jobs were changed. The full goal is not complete.

### Explicit log export preview and save wiring

Added Preview export to Logs. It captures the current filter result and source availability into immutable, re-filtered JSON bytes; opening it performs no file write. The sheet shows exact preview bytes and a privacy warning, requires the review checkbox before enabling Save JSON, then delegates location/overwrite confirmation to the native file exporter. It never reads source logs or credentials. Snapshot schema 1 includes generation/source times, source status, event rows and omission count, excluding structured process PID/image metadata. Unmarked private prose may still remain and is disclosed.

The serializer limits input retention through EventBuffer and caps final encoded JSON at 256 KiB by dropping whole oldest rows, counting omissions. Tests failed before implementation and pass for sensitive fields, stale provenance, invalid timestamps and escape-expansion size bounds. Inspected `/tmp/darkbloom-log-export-preview.png`: JSON wraps within the dialog, the review checkbox is unchecked, and Save is disabled. Full suite passes 500 tests in 48 suites; release build and whitespace check pass.

Native save/cancel/overwrite/failure round-trip behavior and filter-to-preview interaction still need end-to-end proof before calling export complete. No real logs were exported, no monitor/provider restart occurred (41345, 70543/70553), and no Terminal process exists. This export build is not yet live. Other full-goal gates remain open.

### Native export round-trip proof and cleanup exception

The Swift test helper rendered a window but exposed no accessibility windows, so two bounded opt-in attempts ended without output. Removed those temporary wait hooks. Added `Tests/NativeUI/LogExportFixture.swift` and its plist/runbook to host the unchanged production export view in a standalone synthetic-only app. The compiler defaulted to minimum macOS 28 on this macOS 27 host; explicitly targeting macOS 14 resolved the fixture-only launch issue. No production deployment target changed.

Native accessibility inspection verified Save disabled before acknowledgement, enabled afterward, a real native dialog and cancellation with an empty test directory. Selecting `/tmp/darkbloom-export-check.SOQ6qh` through Go to Folder then saving produced 546 UTF-8 bytes exactly equal to the frozen preview. An explicit overwrite prompt appeared; Cancel preserved a schema-99 sentinel edit, and Replace restored exact preview bytes. The fixture app was quit and its process exit verified. Full normal suite still passes 500 tests in 48 suites; whitespace check passes. Monitor/provider remain 41345 and 70543/70553, with no Terminal.

Cleanup exception: an earlier attempt put an absolute path in Export As; macOS converted slashes to colons and created the 546-byte synthetic file `/Users/kevink/Documents/:tmp:darkbloom-export-check.SOQ6qh:darkbloom-logs.json`. The native save callback reported success and stat confirms that exact unique fixture target. Documents listing/read/move operations stall (listing eventually reported Interrupted system call); no cause or permission denial was established. Stopped and reaped only the task-owned stalled move/AppleScript clients. Last check still showed the source file; no successful relocation was claimed. Revalidate source and `/tmp/darkbloom-export-check.SOQ6qh` before retrying cleanup because the Finder request outcome was not confirmed. No real user logs or existing user document were exported/overwritten.

Native save/cancel/replacement now have synthetic proof; failure injection and parent Logs filtering/preview interaction remain open, along with broader goal requirements. The running monitor still predates export UI.

### Parent Logs-to-preview native proof

Extended the isolated fixture with `--logs-route`, hosting the production LogsView and EventRow with two synthetic stale events. Native Source = Legacy selection reduced two rows to one; Preview export then contained exactly that legacy event, `source_status: last-known` and the original `1970-01-01T00:01:00Z` source time. Adding Severity = Error yielded no matches and disabled Preview export. Closing the sheet returned to the Logs route. No file was saved in this check.

Accessibility text-field assignment changed displayed text but not the SwiftUI binding, so it was not counted as native keyboard-search proof. The fixture did not reliably become foreground on request; further keyboard actions were avoided in favor of targeted picker actions. Actual keyboard search and native failure injection remain unverified. The fixture app was quit and its absence verified.

All 500 tests in 48 suites, release build and whitespace check pass. After confirming no monitor windows/drafts were open, replaced only the background monitor: PID 44544 runs the current export-enabled release. Provider PIDs remain 70543/70553 and no Terminal process exists. Revalidated the Documents cleanup exception: the unique 546-byte synthetic file remains at the previously recorded source path, with no confirmed relocation and no live cleanup client; no retry was launched. Full-goal requirements remain open.

### Shared public retry jitter

Catalog, pricing, history and capacity now use the same bounded exponential failure-backoff helper, with injected 0–20% jitter. Successful cadences and per-source caps remain unchanged. The history lifecycle regression first failed at 600 versus 720 seconds and 500 versus 620 seconds after reopening, then passed with the implementation connected. Helper tests cover caps and nonfinite/negative jitter; a fractional comparison uses microsecond tolerance for binary floating-point rounding.

Fresh verification: 502 tests in 49 suites passed (`/tmp/public-jitter-tests.log`), release build passed (`/tmp/public-jitter-build.log`), and `git diff --check` passed. No app/provider relaunch was performed for this change; the running app has not adopted this build. Commands ran in the background. Full-goal requirements remain open, including the standalone public API contract document and the other previously recorded proof gaps.

### Public contract and required-price validation

Added PUBLIC_API_CONTRACT.md and linked it from README. It records implementation-derived endpoint meanings, authentication/privacy boundaries, byte and request timeout limits, cadence/backoff, freshness, memory retention, payload validation and opportunity formulas. It explicitly does not claim live server verification, cookie isolation, strict wall-clock deadline or redirect hardening. This closes the missing standalone document, not all Phase 0 acceptance requirements.

Added pricing characterization cases rejecting omitted, null, string, fractional and overflowing required values, plus a valid explicit-zero case. Full suite: 504 tests in 49 suites passed (`/tmp/public-contract-full-tests.log`). No production code changed after the prior release build. No commit or push performed.

### User-requested Qwen 9B removal and provider restart

Verified provider configuration already enabled/preloaded only EigenLabs/Qwen3.8-27B-4bit-mtp with one slot. Shell cache enumeration and CLI removal stalled; both task-owned commands were stopped and reaped. Sol was mounted with SMART reported Verified; Finder could enumerate its cache without remount or repair. Exact models--Qwen3.5-9B folder was moved through Finder to /Volumes/Sol/.Trashes/501/models--Qwen3.5-9B and verified absent from the cache and present in Trash. Permanent deletion is pending explicit at-action confirmation; do not empty unrelated Trash items.

After fresh idle-state verification, the authorized stock CLI restart succeeded. New provider PIDs 49767/49775 replaced 70543/70553. A fresh daemon snapshot at Unix time 1788560854.985269 verified only Qwen 3.8 advertised and warm. This is restart/model-state proof, not proof of a new customer inference. No Terminal was opened. Monitor remains the prior process; public retry changes have not been relaunched into it.

### Models context and current runtime checkpoint

Models now receives shared network capacity and customer pricing, with exact model matching, source age and explicit stale labels. Local average token rate carries its database query interval and sample count; a query interval is not a claim of continuous observation. These read-only badges do not authorize loading or change local model state. The isolated 620-by-900 Models render was inspected at /tmp/darkbloom-model-context.png; staged configuration and the save footer remain present. This does not prove the live app or minimum-height layout.

Final verification logs /tmp/model-context-final-tests.log and /tmp/model-context-final-build.log report 516 tests in 51 suites passing and a successful release build. A subsequent git diff --check passed. The release executable was modified at 15:54:21 on September 4; monitor PID 58793 started at 15:45:41, so it does not contain this latest build. Exactly one monitor was observed, using the architecture-specific project release path. Provider PID 49767 remained unchanged. Relaunch is deferred while the user is asked about unsaved settings. Never use app-name lookup to inspect this SwiftPM app: it previously launched an obsolete registered visual-test bundle.

### Remaining realized-payout context: evidence gate

Phase 4's per-model realized payout is not implemented in Models. Current ModelEarnings contains only model, microUSD and jobs. MonitorStore requests a rolling seven-day lower bound and retains previous rows on failure; EarningsDatabase.earningsByModel has no upper bound or coverage metadata. Reusing these values as current calendar earnings would hide stale data and misstate the period. Customer pricing must not fill this gap.

Before exposing payout in Models, add an explicitly bounded calendar query with exact model attribution, query/capture provenance and coverage status; propagate failure/staleness separately from retained data. Tests must cover midnight, future rows, partial hourly boundaries, missing coverage, exact-ID mismatch and refresh failure. Show observed work earnings distinctly from account-wide rewards and customer prices, and omit unsupported full-period claims. This remains required work, not a completed feature or a reason to mark the whole goal blocked.

### Calendar model work earnings implemented

ModelWorkEarnings now carries the exact query interval, latest local account capture time, optional work amount/jobs, and counts of recorded, unknown and uncertain-boundary hours. EarningsDatabase derives it through the existing bounded, exact-model Activity query. Rewards stay excluded; no recorded rows yields nil, not zero. Partial UTC-hour boundaries are omitted and counted as uncertain, including the current incomplete hour. This is deliberately observed work, not a complete payout calculation.

AuthenticatedEarningsClient reads this context from the existing local database without a separate network request. MonitorStore acquires today's calendar interval on its existing earnings refresh, uses its injected clock, clears context after an acquisition/read failure, and shares it with Models. Labels require unique exact attribution and the current calendar date, reject future captures and age to stale after 600 seconds. They always state partial coverage; midnight removes yesterday's badge until fresh data arrives. UI state does not affect model authority or staged configuration.

Tests cover calendar query routing, failed-read clearing, exact/case-mismatched IDs, rewards exclusion, upper-bound exclusion, missing and partial hours, and database-to-client output. The rendered 620-by-900 Models fixture /tmp/darkbloom-model-context.png was inspected with the new work badge and visible fixed save footer. All 518 tests in 51 suites pass (/tmp/work-context-final-tests.log), release build passes (/tmp/work-context-release.log), and whitespace check passes. Monitor 58793 and provider 49767 remain unchanged; this source checkpoint is not live-reviewed. Full-day payout coverage, native live interaction, and the broader goal gates remain open.

### Log-origin retention correction

The model-filter contract remains unsupported: current legacy and unified parsers expose no dedicated model ID. No inference from prose or speculative field has been added. While tracing existing source filtering, a regression reproduced EventBuffer merging four different source/process origins into a single event. The Unified filter then returned no events even though three unified events had been supplied.

Deduplication now includes sanitized source, PID and process-image metadata alongside timestamp, severity, category and message. Repeated identical events still coalesce; differing origins survive within the unchanged 100-event and 128-KiB limits. The regression failed five assertions before the fix and passes afterward. All 519 tests in 51 suites pass (/tmp/log-origin-green.log), release build passes (/tmp/log-origin-build.log), and whitespace check passes. No UI layout, exports, raw logs, app process or provider process was changed. A dedicated model filter still requires a verified attribution source.

### Dedicated public HTTP session

Catalog, pricing, capacity and series now default to the same dedicated ephemeral URLSession, not URLSession.shared. Cookie storage, automatic cookie handling, credential storage and caching are disabled. PublicSessionPolicy rejects same-origin, cross-origin and downgrade redirects before follow-up; source clients already reject non-2xx status responses. Explicit session injection remains caller-controlled for tests and other callers. No authenticated earnings transport changed.

Tests exercise redirect decisions and the actual shared public session configuration. Temporarily enabling cookies caused the isolation regression to fail; the mutation was removed. Full verification: 521 tests in 52 suites pass (/tmp/public-isolation-final.log), release build passes (/tmp/public-isolation-build.log), and whitespace check passes. PUBLIC_API_CONTRACT.md now distinguishes these guarantees from still-unproven live redirect/cookie interception, strict wall-clock timeout and midstream cancellation. No app/provider relaunch or external network probe occurred.

### Public-session loopback verification

Added a synthetic HTTP server bound only to 127.0.0.1 on an ephemeral port. The real dedicated public session receives a 302 and does not request the target; subsequent requests do not replay the fixture's Set-Cookie header or send Authorization. Temporarily allowing redirects produced an unexpected 200, an extra request and the forbidden target request; all three assertions failed. The mutation was restored. Initial fixture readiness incorrectly accepted port zero and was corrected before verification.

Full suite: 522 tests in 53 suites pass (/tmp/public-loopback-final.log). The finite test process exited; its listener and connections are cancelled in teardown. Whitespace check passes. Production code is unchanged from the preceding release build after removing the deliberate mutation. This proves synthetic loopback HTTP behavior, not production HTTPS, proxies, midstream cancellation or strict wall-clock timeout. No app/provider restart, Terminal window, external network probe or user-data write occurred.

### Session midstream cancellation proof

Extended the loopback fixture to send 16 KiB of a declared 64 KiB body and then stall. The test waits for actual byte consumption before cancelling and requires cancellation, rather than timeout or successful completion, within one second. A one-byte initial fixture was buffered and could not establish body consumption; increasing the partial body resolved that fixture limitation. The focused test passed in 35 ms. All 523 tests in 53 suites pass (/tmp/public-midstream-final.log), and whitespace check passes. Only tests and documentation changed; the test process exited and its resources were cancelled.

This closes session-level midstream cancellation evidence, not full collector/client lifecycle or wall-clock timeout proof. A read-only CUA inventory still did not expose the running monitor, so it did not resolve the unsaved-draft question. No app-name lookup, app/provider relaunch or Terminal interaction was attempted.

### Weekly calendar freshness

CalendarWeekEarningsSummary now includes week start and capture time. Its current-value predicate requires the caller's current calendar week, a nonnegative amount and a capture age from zero through 600 seconds. Missing provenance, future capture, changed first weekday and previous-week values are rejected. EarningsDatabase supplies this provenance; MonitorStore exposes currentWeekEarnings, and both popup and dashboard now use that checked value through their existing presentation timers.

Tests cover the exact Monday rollover, a locale first-weekday change, the 600/601-second threshold, zero partial earnings, future/missing provenance, database propagation and suppression of retained expired store values. All 524 tests in 53 suites pass (/tmp/week-fresh-final.log), release build passes (/tmp/week-fresh-build.log), and whitespace check passes. This changes freshness, not the ledger calculation or completeness policy. No app/provider relaunch occurred; live rollover review remains open.

### Completed-job calendar freshness

JobCompletionSummary now carries its day start and capture time from the database query. Current-day presentation rejects previous-day, future, expired (over 600 seconds), undated and negative counts. MonitorStore.currentJobSummary also requires available source status; both popup and Overview use it, rather than silently displaying retained stale values. The existing calendar query/counting and historical average math are unchanged.

Midnight, capture boundaries, zero, missing provenance, database metadata and current store publication are covered. All 525 tests in 53 suites pass (/tmp/job-fresh-final.log), release build passes (/tmp/job-fresh-build.log), and whitespace check passes. No app/provider restart occurred. This is freshness evidence, not a new proof of complete ledger coverage or live visual rollover.

### Public response total-time limit

The dedicated session inherited URLSession's 604800-second resource timeout despite the 15-second request timeout. A configuration regression reproduced that gap. Resource timeout is now also 15 seconds, bounding the complete response independently of per-request idle timeout. A real loopback byte-stream test consumes 16 KiB, stalls the remainder, uses a deliberately longer 30-second request timeout, and requires timedOut before 25 seconds. It completed at 15.6 seconds focused and 15.9 seconds in the full suite; this is bounded scheduling evidence, not a hard real-time promise.

All 526 tests in 53 suites pass (/tmp/public-deadline-final.log), release build passes (/tmp/public-deadline-build.log), and whitespace check passes. Finite test/build processes exited and the loopback listener is torn down. No app/provider relaunch occurred. Production DNS/TLS/proxy behavior and complete client lifecycle cancellation remain unverified.

### Calendar-day throughput presentation

Popup and Overview now use qualified calendar-day token-rate rows and their sample-weighted aggregate for labels claiming Today. Rows require a unique exact model ID, finite positive rate/sample count, the current calendar day start and query-end age of zero through 600 seconds. Yesterday, future, undated and expired rows are omitted. A retained active-session aggregate is no longer substituted into a calendar-day card. Models' explicitly dated historical-query context remains separate, and model state pills are unchanged.

Tests cover midnight, future/expired/undated/duplicate rows, sample weighting and invalid numbers. Full suite: 528 tests in 54 suites pass (/tmp/calendar-rate-green.log); the added store suppression assertions also pass (/tmp/calendar-rate-store.log). Release build and whitespace check pass. No monitor/provider relaunch occurred; live midnight review remains open.

### Recommendation observation provenance

The popup star previously used undated rolling-seven-day ModelEarnings retained on failure. Both popup and automatic-switch coordinator now call a dated recommendation overload using shared ModelWorkEarnings and current calendar token-rate evidence. Capacity must be fresh; work tie-breakers require unique exact attribution, nonnegative work, positive jobs/recorded hours, today's interval and fresh query/capture timestamps. Invalid or stale observations are omitted rather than treated as zero. Existing demand-first ordering is preserved.

Tooltip/accessibility now describe a demand-first suggestion, not guaranteed profitability or hardware fit. Partial observed work per job is a descriptive tie-breaker; the broader balanced profitability/compatibility score is still not established. Automatic switching remains capability-gated and was not enabled. Legacy pure ranking API remains for compatibility, but live app call sites use dated evidence.

Regression cases cover fresh, stale and duplicate work plus capacity expiry. All 529 tests in 55 suites pass (/tmp/opportunity-evidence-final.log), release build passes (/tmp/opportunity-evidence-final-build.log), and whitespace check passes. No monitor/provider relaunch or configuration change occurred.

### Log-churn measured optimization

A synthetic 1000-insert benchmark found EventBuffer repeatedly sanitizing its private retained events on every insert. The buffer now sanitizes only incoming raw events; retained events remain inaccessible to external mutation, and byte budgeting/deduplication still occur on sanitized values. The long-churn test checks the 100-event/128-KiB limits throughout and the newest/oldest retained sanitized messages.

On this machine's debug test run, the same benchmark improved from 6.904 seconds (/tmp/log-churn-before.log) to 0.157 seconds (/tmp/log-churn-after.log). This is a controlled single-event insertion workload, not an overall app-speed or long-duration resident-memory claim. All 530 tests in 55 suites pass (/tmp/log-churn-final.log), release build passes (/tmp/log-churn-build.log), and whitespace check passes. No app/provider restart or raw-log mutation occurred. Main-thread profiling and a real multi-day run remain open.

### Current live public endpoint smoke check

Added an explicitly opt-in livePublic test for the four real clients using the production public session. At September 4, 2026 16:30 America/Phoenix, capacity, pricing, catalog and series all fetched and decoded successfully (four cases, 0.333 seconds; /tmp/live-public-contract.log). No credentials, provider commands or raw response-body logging were involved. This is current HTTPS/parser compatibility evidence, not ongoing availability, adverse-network coverage or schema stability.

Verified the test is skipped without DARKBLOOM_LIVE_PUBLIC=1 (/tmp/live-public-disabled.log), keeping ordinary tests offline. Whitespace check passes; production code and runtime are unchanged. PUBLIC_API_CONTRACT.md records the observation and repeat command. This closes a current successful-acquisition check without closing the wider network or release gates.
# Local packaging checkpoint — September 4, 2026

Integrated only AppResources, its tests, the MenuBarLabel resource lookup,
the Python bundle assembler and its tests from the isolated packaging worktree.
Preserved all pre-existing main edits. Main already had the two lifecycle test
expectation corrections; no wholesale test-file replacement was performed.
Full integrated Swift run reports 533 tests in 56 suites passing (the opt-in
live public test remains skipped); release build and five packaging tests pass.
Whitespace check passes. Logs: /tmp/darkbloom-packaging-integrated-tests.log
and /tmp/darkbloom-packaging-integrated-build.log.

Artifact: .build/local-review-20260904-packaging-1/DarkbloomMonitor.app
Manifest: .build/local-review-20260904-packaging-1/artifact-manifest.json
Executable SHA-256: cb81476e5dc912a3e52a64d54aaacc397c067450dbe66941d25b48a7257b32b3
All five packaged files independently hashed; executable bytes match release
input, no packaged symlinks, canonical bundle identity and LSUIElement verified.
Both production SVGs decode through NSImage from the packaged resource bundle.
This is resource decoding, not live visual or relocated-process launch proof.
Source HEAD: 6945b6492fb0c1f521d0a723e3153a5f71b9f914 with substantial dirty work;
the version/build labels do not identify a release or clean source snapshot.
No launch, registration, provider restart, distribution signing, notarization,
commit or publication performed. Manifest is not an SBOM. Live review and
distribution gates remain open.
