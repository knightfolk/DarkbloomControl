# Darkbloom Mega App Integration Plan

Review snapshot: 2026-09-03

This document defines this project's implementation requirements. It does not authorize copying third-party code, changing the provider, publishing a build, or merging another repository.

## Official provider boundary

The monitor must use only the signed, vendor-released Darkbloom CLI installed
by the user. It must not build, install, select, or document a custom CLI
branch, patched provider executable, unsigned replacement, private
model-control endpoint, or endpoint override. Features unavailable through the
official CLI are represented as unavailable/Coming Soon. Public network demand
remains supported as read-only context and never authorizes a local residency
change.

## Executive decision

Develop the application within this repository's existing architecture.

Keep this repository as the product and architecture owner:

- one native Swift/AppKit macOS application;
- one compact menu-bar popup for immediate status and safe controls;
- one retained, resizable dashboard window for history, analysis, models, health, and diagnostics;
- `DarkbloomTelemetry` as the only layer allowed to read provider files, run commands, call APIs, or persist measurements;
- explicit freshness, provenance, coverage, and unavailable reasons for every displayed value;
- no prompt, response, reasoning, API-key, or raw job-content persistence.

Implementation priorities are native presentation, bounded telemetry, clear coverage, safe provider controls, and opt-in energy measurement.

The immediate product sequence should be:

1. Build the dashboard shell from data we already trust.
2. Add calendar activity and earnings charts from our existing database.
3. Add public network opportunity data as a separately sourced, clearly labeled view.
4. Improve models, health, logs, and lifecycle progress.
5. Gate fleet and energy behind stronger data and security contracts.
6. Harden packaging so only one current app instance can run.

## Current product baseline to preserve

Preserve the current application's foundations:

- `DarkbloomTelemetry` is UI-independent and contains source policy, bounded reads, parsing, derivation, persistence, account earnings, inventory, and provider controls.
- `DarkbloomMonitor` owns the native `NSStatusItem`, `NSPopover`, SwiftUI presentation, and retained Settings window.
- Token rate is derived only from positive counter/time deltas for the same provider process identity.
- Loaded, configured, enabled, preloaded, idle, and unavailable model states are not intentionally conflated.
- Lifecycle commands use direct process arguments rather than a shell and already have freshness/customer-impact gates.
- Hourly account and reward aggregates are stored without raw prompt or response content.
- The popup is deliberately bounded at approximately 400 × 600 rather than becoming a full dashboard.

These are invariants, not temporary implementation details. New work should extend them.

## Live API compatibility findings

The public API was probed on 2026-09-03 because the community apps disagree about endpoint shape and authentication. These results are a dated compatibility snapshot, not a permanent contract:

| Endpoint | Result | Proposed use |
| --- | --- | --- |
| [`/v1/models/catalog`](https://api.darkbloom.dev/v1/models/catalog) | Public response available | Model metadata, RAM and disk requirements, canonical IDs |
| [`/v1/pricing`](https://api.darkbloom.dev/v1/pricing) | Public response available | Customer-facing input/output prices, displayed separately from provider payout |
| [`/v1/models/capacity`](https://api.darkbloom.dev/v1/models/capacity) | Public response available | Active/queued requests, provider warmth/routability, capacity, estimated TTFT |
| [`/v1/network/series?window=24h`](https://api.darkbloom.dev/v1/network/series?window=24h) | Public half-hour series available | Network request and prompt/completion token charts |
| [`/v1/providers/attestation`](https://api.darkbloom.dev/v1/providers/attestation) | Public response available; reviewed shape lacked a stable serial field | Trust context only; not authoritative fleet ownership |
| `/v1/models` | Returned `401` without credentials | Do not use as the public model source |
| `/v1/stats` | Did not answer within a 15-second review timeout | Do not put on the interactive path; use bounded network series instead |

Before implementation, capture redacted fixtures for each accepted endpoint and document:

- exact field names and optionality;
- maximum accepted response bytes;
- request timeout;
- cache and freshness lifetime;
- authentication requirement;
- rate-limit behavior;
- handling of unknown enum values and additional fields;
- whether the value is direct, derived, estimated, or locally observed.

Customer pricing must not be converted into provider earnings. Aggregate network capacity must not be shown as a local job's progress. Public attestation must not be treated as proof that a provider belongs to this user.

## Target product architecture

### Surface 1: compact menu popup

The popup remains the glance-and-act surface. Its content budget is:

- provider health/state;
- current token rate while genuinely measured and calendar-day average token rate;
- earnings today, per observed hour, and this calendar week;
- jobs today and calendar-day average;
- compact three-state model pills: active, loaded idle, available/not loaded;
- Start, Stop, and Restart icon controls with the existing warning/confirmation behavior;
- Open Dashboard;
- Settings;
- Quit.

Do not add maps, power charts, logs, fleet tables, chat, load generation, API diagnostics, or model opportunity rankings to this surface.

### Surface 2: resizable Dashboard window

Add a single retained `NSWindowController`, owned by `StatusItemController`, with a SwiftUI sidebar and restored frame/selection. Proposed minimum size is approximately 960 × 680, but final sizing must be visually reviewed on the supported macOS versions.

Proposed sections:

1. **Overview** — provider state, current/local work, today/week earnings, jobs, model states, concise health.
2. **Activity** — hourly/calendar charts, earnings versus rewards, jobs, prompt/completion tokens, per-model rate.
3. **Opportunity** — public network demand/capacity and explainable model suitability.
4. **Models** — My Catalog, Available, enable/preload/delete, local fit, observed performance, network context.
5. **Health** — trust, provider process, memory, slots, KV/MTP, thermal state, competing local inference.
6. **Logs** — bounded, redacted events with filters and search.
7. **Fleet** — hidden or marked experimental until stable identity and authenticated data exist.
8. **Energy** — hidden until explicitly enabled and a safe sensor source is configured.

Settings remains a separate focused window rather than a giant dashboard tab. A toolbar Settings button may open it.

### Layering

```text
AppKit lifecycle
  StatusItemController
    -> compact MonitorPopover
    -> retained DashboardWindowController
    -> retained Settings window

SwiftUI presentation
  MonitorStore                  DashboardStore
        \                         /
         \---- DashboardSnapshot
                    |
DarkbloomTelemetry actors and stores
  LocalTelemetrySource
  AuthenticatedEarningsClient + EarningsDatabase
  PublicNetworkClient + NetworkCache        (new)
  SystemHealthSource                        (new, optional)
  EnergySource + EnergyDatabase             (future, opt-in)
  ProviderControlService

Bounded external inputs
  provider state/config/logs | direct CLI | account API | public API | OS metrics
```

Presentation code must never open provider files, spawn a process, call the network, or calculate business-critical earnings directly.

### Snapshot contract

Every source domain should publish a value plus evidence metadata:

```swift
struct Sourced<Value: Sendable>: Sendable {
    let value: Value?
    let capturedAt: Date?
    let freshness: Freshness
    let provenance: Provenance
    let unavailableReason: String?
    let coverage: Coverage?
}
```

`DashboardSnapshot` should compose, not erase, those source states. A local provider snapshot can be fresh while public network capacity is stale and account earnings are unavailable. The UI should show partial data rather than collapsing all three into a single error.

Suggested provenance cases:

- `providerStateFile`
- `loadedModelsFile`
- `providerConfiguration`
- `boundedProviderLog`
- `directCLIStatus`
- `accountEarningsAPI`
- `publicCatalogAPI`
- `publicPricingAPI`
- `publicCapacityAPI`
- `publicNetworkSeriesAPI`
- `osProcessInfo`
- `energySensor(name:)`
- `derived(inputs:)`

## Metric definitions

The dashboard needs stable definitions before it needs charts.

### Local throughput

- **Current tok/s:** positive token-counter delta divided by positive elapsed provider time for the same `process_identity`; unavailable after restart, rollback, no progress, or stale input.
- **Current Alpha calendar-day average tok/s:** arithmetic mean of valid positive same-process samples captured since local midnight, matching the shipped popup contract. It resets its in-memory session fallback when `process_identity` changes.
- **Current Alpha per-model average tok/s:** the same arithmetic sample mean, grouped only where model identity is known. Do not attribute an aggregate delta across concurrent unknown models.
- **Future duration-weighted migration:** sum observed generated-token deltas and divide by covered active-inference seconds only after storing interval duration explicitly, migrating the local database, and changing the label and tests together. Do not silently mix this definition with the Alpha arithmetic series or divide by wall-clock day length.

### Earnings

- **Today:** account-ledger work earnings within the user's local calendar day.
- **This week:** account-ledger work earnings from locale-configured calendar week start through now.
- **Earnings per observed hour:** covered work earnings divided by covered elapsed hours in the same selected calendar interval. Label coverage.
- **Base rewards:** always separate from work earnings.
- **Per-model dollars per million tokens:** `workEarnings / (promptTokens + completionTokens) * 1_000_000`, only when attribution and token coverage are sufficient.
- **Projection:** optional presentation-only estimate; never persisted as actual and always visually dashed/labeled.

### Opportunity

Expose components before any composite score:

- `demandPressure = (activeRequests + queuedRequests) / max(routableProviders, 1)`
- `warmScarcity = 1 - warmProviders / max(routableProviders, 1)`
- `queuePressure = queuedRequests / max(queueLimit, 1)`
- `localFit` from model minimum RAM, current free provider capacity, catalog/download state, and compatible hardware features
- customer input/output pricing as separate context only
- locally observed payout/performance as separate history only

If a composite recommendation is added later, show every factor, weight, data age, and missing component. Name it an opportunity score, not expected earnings.

### Energy

An `EnergySample` needs:

- timestamp;
- watts;
- direct versus estimated flag;
- source name;
- source confidence/health;
- optional component breakdown.

Energy is integrated using actual adjacent-sample elapsed time. Break the series when the gap exceeds a documented threshold. Never apply a baseline when the primary sensor is absent. Net earnings are calculated only across intervals where earnings and energy coverage overlap.

## Detailed implementation phases

### Phase 0 — contracts, licensing, and fixtures

Goal: prevent UI enthusiasm from outrunning source truth.

Work:

- Extend `docs/TELEMETRY_CONTRACT.md` with public catalog, pricing, capacity, and network-series sources.
- Add a source matrix covering auth, privacy, timeout, byte limit, cadence, freshness, persistence, and failure behavior.
- Capture redacted JSON fixtures from the accepted current API shapes.
- Add schema-decoding tests for missing fields, added fields, nulls, unknown enum values, malformed numbers, and oversized responses.
- Record third-party attribution in a new `THIRD_PARTY_NOTICES.md` only if MIT-licensed source is actually reused.
- Do not copy third-party source without an applicable license and required attribution.
- Decide whether model catalog and capacity values may be cached to SQLite or only retained in memory. Prefer memory plus a small last-good cache with timestamp.

Files:

- modify `docs/TELEMETRY_CONTRACT.md`
- add `docs/PUBLIC_API_CONTRACT.md`
- add `Tests/DarkbloomTelemetryTests/Fixtures/PublicAPI/*.json`
- add `Tests/DarkbloomTelemetryTests/PublicNetworkDecodingTests.swift`
- optionally add `THIRD_PARTY_NOTICES.md`

Acceptance:

- every future dashboard field maps to a named source or is explicitly unavailable;
- no credential or prompt/response field enters a fixture or database;
- current and degraded fixtures decode deterministically;
- byte/time limits are unit tested.

### Phase 1 — dashboard shell using existing trusted data

Goal: prove the two-surface architecture without adding a new data source.

Work:

- Add `DashboardWindowController` and retain one instance from `StatusItemController`.
- Add an **Open Dashboard** action to the popup and optionally the Settings toolbar.
- Add `DashboardStore` on `@MainActor`; it consumes existing `TelemetryService` snapshots and earnings presentation.
- Build sidebar navigation with Overview implemented and later tabs showing honest “Not added yet” states during development.
- Persist only window frame, selected section, and user presentation preferences.
- Make reopening focus the existing window instead of creating duplicates.
- Stop dashboard-only refresh work when the window closes, while leaving normal menu telemetry intact.

Files:

- add `Sources/DarkbloomMonitor/Dashboard/DashboardWindowController.swift`
- add `Sources/DarkbloomMonitor/Dashboard/DashboardRootView.swift`
- add `Sources/DarkbloomMonitor/Dashboard/DashboardStore.swift`
- add `Sources/DarkbloomMonitor/Dashboard/OverviewView.swift`
- modify `Sources/DarkbloomMonitor/StatusItemController.swift`
- modify `Sources/DarkbloomMonitor/MonitorPopover.swift`
- extend `Sources/DarkbloomTelemetry/DashboardPresentation.swift`

Acceptance:

- popup remains within its existing visual footprint;
- one click opens a single resizable dashboard;
- Overview matches the same underlying snapshot as the popup;
- closing/reopening restores frame and selected section;
- no new network request or process launch exists in a view;
- VoiceOver names and keyboard navigation work.

### Phase 2 — calendar Activity and earnings

Goal: turn the existing SQLite history into the most valuable dashboard page.

Work:

- Add query APIs for local calendar hour/day/week buckets, including DST boundaries.
- Return explicit coverage per bucket rather than converting missing data to zero.
- Keep work earnings, base rewards, jobs, prompt tokens, and completion tokens separately queryable.
- Add per-model series only where attribution is known.
- Build Activity charts with hover/focus details, accessible table summaries, and filters for Today, This Week, and a selected calendar date range.
- Render actuals with a solid style; if current-hour projection is enabled, render it dashed and labeled.
- Preserve peaks when downsampling and preserve gaps.

Files:

- modify `Sources/DarkbloomTelemetry/EarningsDatabase.swift`
- modify `Sources/DarkbloomTelemetry/ModelTokenRateDatabase.swift`
- add `Sources/DarkbloomTelemetry/ActivitySeries.swift`
- add `Sources/DarkbloomMonitor/Dashboard/ActivityView.swift`
- add `Sources/DarkbloomMonitor/Components/AccessibleChart.swift`
- add focused database, calendar, and presentation tests

Acceptance:

- today/week totals agree with ledger rows across midnight, DST, withdrawal, and reward cases;
- per-hour values change only when supported by a new ledger observation;
- unknown coverage renders as a gap, not `$0.00`;
- per-model tok/s and payout are absent when attribution is insufficient;
- chart information is available without pointer hover.

### Phase 3 — public Network and Opportunity

Goal: help the user decide which locally compatible models are worth enabling without promising earnings.

Work:

- Add a `PublicNetworkClient` actor using `URLSession`, strict timeouts, response byte caps, typed decoding, and cancellation.
- Keep independent last-good snapshots for catalog, pricing, capacity, and series.
- Use conditional requests when supported and exponential backoff with jitter after failure.
- Proposed starting cadences while the dashboard is open:
  - capacity: 60 seconds;
  - network series: 5 minutes;
  - pricing: 15 minutes;
  - catalog: 30 minutes.
- When the dashboard is closed, suspend series refresh and reduce or stop nonessential network refresh.
- Build Opportunity rows that show raw demand, warm/routable provider counts, queue state, local compatibility, catalog state, and source age.
- Keep public customer prices visually separated from locally realized provider rates.
- Use `/v1/network/series` for charts; do not block UI on `/v1/stats`.
- Defer a globe/map until geographic semantics, performance, and accessibility are proven.

Files:

- add `Sources/DarkbloomTelemetry/PublicNetworkClient.swift`
- add `Sources/DarkbloomTelemetry/PublicNetworkModels.swift`
- add `Sources/DarkbloomTelemetry/PublicNetworkSnapshot.swift`
- add `Sources/DarkbloomTelemetry/OpportunityDeriver.swift`
- modify `Sources/DarkbloomTelemetry/SourcePolicy.swift`
- add `Sources/DarkbloomMonitor/Dashboard/OpportunityView.swift`
- add `Sources/DarkbloomMonitor/Dashboard/NetworkView.swift`
- add fixture, cadence, backoff, cancellation, and formula tests

Acceptance:

- a 401, 429, timeout, malformed response, or schema change affects only its source card;
- last-good data is visibly stale and never relabeled fresh;
- no score is called earnings or profit;
- each recommendation exposes its factor values and source ages;
- the app performs no high-frequency public polling when the dashboard is closed.

### Phase 4 — Models, Health, and Logs

Goal: make the dashboard the operational control center while retaining the existing Settings model editor.

Models work:

- Reuse current My Catalog and Available grouping.
- Keep Enable, Preload, and Delete as separate controls with visually bound labels/toggles.
- Add catalog RAM requirement, disk size, download state, and canonical ID.
- Add network demand/pricing as contextual badges, never as local state authority.
- Add locally observed average tok/s and realized payout only with sufficient coverage.
- Preserve the local authority order: provider config and local inventory determine configured/downloaded; loaded-model and daemon state determine loaded/active.

Health work:

- Add provider process identity, last state write, CLI version, trust, memory, slots, KV/MTP state, thermal state, and recent classified errors.
- Treat `darkbloom doctor` as a manual slow diagnostic only after its exact output, timeout, and privacy behavior are contracted.
- Keep competing local inference detection informational. Never stop another process automatically.

Logs work:

- Build on the existing bounded/redacted event buffer.
- Add severity/source/model filters and in-memory search.
- Cap row count and retained bytes.
- Keep URLs and terminal-like content inert by default.
- Make export an explicit, separately confirmed action with a redaction preview.

Files:

- refactor `Sources/DarkbloomMonitor/ModelManagerView.swift` into reusable row components
- add `Sources/DarkbloomMonitor/Dashboard/ModelsView.swift`
- add `Sources/DarkbloomMonitor/Dashboard/HealthView.swift`
- add `Sources/DarkbloomMonitor/Dashboard/LogsView.swift`
- add `Sources/DarkbloomTelemetry/SystemHealthSource.swift`
- extend `Sources/DarkbloomTelemetry/EventBuffer.swift`
- extend relevant presentation and source-policy tests

Acceptance:

- model state does not disappear during a temporary network failure;
- a network result cannot mark a local model loaded or active;
- logs and process output stay within measured limits;
- private log fields remain redacted in UI and export previews;
- Health clearly distinguishes direct state, derived state, and permission-blocked state.

### Phase 5 — lifecycle progress and model residency

The official vendor CLI is the only supported provider runtime. The earlier
Phase 5 proposal for private loopback model-control routes, custom provider
branches, protected warm/retire operations, load-first staging, automatic
demand switching, and one-time endpoint setup is superseded and retained only
in the historical design files under `docs/superpowers/`. Those files are
evidence of rejected or obsolete work, not instructions to build, install, or
launch a custom CLI.

The supported scope is limited to official CLI catalog/configuration and
Start/Stop/Restart controls. Configuration may select enabled/preloaded models
and one- or two-model capacity, with fresh telemetry reconciliation and the
existing customer-impact confirmation for lifecycle actions. Public per-model
demand remains a read-only opportunity signal. It must not trigger local model
loading, unloading, residency switching, or automatic actions.

Do not add a Warm, Keep Warm, live-switch, staged-load, private endpoint, or
custom-provider fallback until the official CLI publishes a supported contract
for it and this plan is deliberately revised.

### Phase 6 — Fleet, gated

Goal: avoid manufacturing machine identity from an unstable public shape.

Do not implement remote control in the first dashboard release.

First require one of:

- an authenticated Darkbloom endpoint with stable provider ownership and machine identity semantics; or
- a locally configured set of machines with explicit user-generated IDs and a documented freshness protocol.

Until then, Fleet may show only:

- this local machine; and
- an explicitly labeled best-effort list such as “recent provider IDs seen online,” with no serial, ownership, or offline-history claim.

If remote control is later approved:

- store secrets in Keychain;
- pin known hosts or require first-use fingerprint confirmation;
- never accept arbitrary host keys;
- authorize capabilities per host;
- require the same active-job confirmation as local control;
- keep an action audit trail without storing command secrets;
- make remote failures isolated per machine.

Acceptance before Fleet leaves experimental status:

- machine identity survives provider restarts by documented contract;
- ownership/authentication is proven;
- stale and offline meanings are explicit;
- one machine's timeout cannot block the entire dashboard;
- remote host verification has a tested failure path.

### Phase 7 — Energy and advanced system metrics, opt-in

Goal: show true operating cost without expanding privileges casually.

Start non-privileged:

- `ProcessInfo.thermalState`;
- virtual-memory pressure and provider memory;
- CPU/load context where supported;
- presence of competing inference services, with absent/denied/error distinction.

For watts, prefer in order:

1. a supported user-space sensor or smart-plug adapter;
2. an explicitly installed, signed helper using `SMAppService`/XPC with one narrow fixed operation;
3. an estimated model clearly labeled and disabled by default.

Do not use setuid binaries or wildcard sudoers rules.

Tariffs:

- version 1: user-entered fixed cost and currency per kWh;
- version 2: explicit time-of-use schedule with timezone and DST behavior;
- later: opt-in regional market adapters with cache/provenance.

Persistence:

- aggregate samples into bounded intervals;
- retain source, direct/estimated status, and coverage;
- integrate using actual timestamps;
- preserve gaps;
- apply a retention policy and database size test.

Files:

- add `Sources/DarkbloomTelemetry/EnergyModels.swift`
- add `Sources/DarkbloomTelemetry/EnergySource.swift`
- add `Sources/DarkbloomTelemetry/EnergyDatabase.swift`
- add `Sources/DarkbloomTelemetry/Tariff.swift`
- add `Sources/DarkbloomMonitor/Dashboard/EnergyView.swift`
- add energy integration, gap, tariff, and persistence tests

Acceptance:

- no privilege escalation occurs simply by opening the dashboard;
- missing sensor data produces a gap, not an estimate disguised as a reading;
- energy/cost totals are reproducible from samples and tariff version;
- net earnings only use overlapping covered intervals;
- disabling Energy stops acquisition and removes stored secrets, if any.

### Phase 8 — packaging, update safety, and release proof

Goal: ensure the mega app is the only app users launch and that shipped behavior matches the tested build.

Work:

- Add CI for supported macOS/Swift combinations, unit tests, release build, and app-bundle assembly.
- Sign and notarize the `.app` and disk image; publish checksums and a machine-readable provenance/SBOM artifact.
- Verify `codesign`, notarization ticket, and Gatekeeper on the exact release artifact.
- Enforce one bundle identifier and one launch-agent/login-item definition.
- Add single-instance activation so launching another copy focuses the current app.
- Detect an older bundle/process with the same product role and show a safe explanation rather than running both.
- Test upgrade/relaunch with existing database and settings.
- Defer auto-update until a signed feed, downgrade/rollback path, and database migration policy exist.

Acceptance:

- the downloaded release hash matches the verified artifact;
- Gatekeeper accepts a clean-machine install;
- only one current process/status item remains after launch and upgrade;
- old settings/databases migrate without silently losing coverage;
- rollback behavior is documented before any irreversible schema migration.

## Polling and resource budget

Initial budget, subject to measurement:

| Source | Popup open/closed | Dashboard open | Persistence |
| --- | --- | --- | --- |
| daemon/loaded model state | existing cadence | same shared stream | existing bounded aggregates only |
| provider logs | existing bounded cadence | same shared stream | capped/redacted event buffer |
| account earnings | existing cadence | same shared stream | SQLite hourly ledger/coverage |
| public capacity | stopped or low cadence | 60 s | last-good cache only |
| public network series | stopped | 5 min | last-good cache only |
| public catalog | stopped or 30 min | 30 min | versioned cache optional |
| public pricing | stopped or 15 min | 15 min | last-good cache only |
| system health | slow/minimal | 5–15 s by cost | no raw history by default |
| energy | disabled unless opted in | source-dependent | bounded interval aggregates |

All timers should be demand-driven, cancellable, and shared. Opening two views must not double polling. Backoff state belongs to the source actor, not the view.

## Security and privacy rules

- Use Keychain for any future API or remote-host credential.
- Never store credentials in `UserDefaults`, logs, fixtures, crash text, or exported diagnostics.
- Do not store prompts, responses, reasoning, or raw job content.
- Keep process execution shell-free, allowlisted, time-bounded, and output-bounded.
- Keep loopback HTTP disabled unless a feature has no native alternative; if added later, bind narrowly and enforce an origin/auth token.
- Do not install setuid binaries or wildcard sudoers entries.
- Do not accept arbitrary SSH host keys.
- Do not activate URLs or escape sequences from provider logs.
- Redact provider/account identifiers where they are not required for user action.
- Treat remote/public content as untrusted even when returned by a Darkbloom endpoint.

## Test and verification matrix

### Source contract

- valid, partial, empty, malformed, oversized, and future-schema fixtures;
- missing/null fields and unknown enums;
- HTTP 401/403/404/429/500, timeout, cancellation, and offline state;
- last-good data aging from fresh to stale to unavailable;
- out-of-order responses cannot overwrite newer data.

### Telemetry math

- process identity change;
- counter reset, rollback, and delayed completion updates;
- same timestamp and future timestamp;
- no-progress interval remains unavailable;
- concurrent/unknown model attribution is not fabricated;
- calendar midnight, week boundary, locale week start, DST spring/fall;
- account high-water, withdrawal, base reward, history cap, and coverage gaps;
- projected versus actual values never mix in totals.

### Lifecycle

- exact model IDs passed to Start;
- no-model configuration has an explicit error, not a hidden restart fallback;
- active and unknown job warning paths;
- user confirmation, cancellation, command failure, timeout, and termination;
- provider PID/process identity change and fresh post-action reconciliation;
- partial model-load result;
- warmup skipped during inference and on stale identity.

### Energy

- irregular sample intervals;
- long gaps and sensor restart;
- missing primary sensor;
- direct versus estimated source switching;
- tariff/timezone/DST changes;
- currency is never silently converted;
- persistence retention and restart recovery.

### UI and accessibility

- compact popup size and content at idle, active, loaded-idle, stopped, stale, and partial-error states;
- model pills remain visible through unrelated source failures;
- dashboard resize, window restoration, sidebar selection, empty/loading/stale/error states;
- keyboard-only operation, VoiceOver labels, focus order, contrast, reduced motion, and text scaling;
- charts have accessible summaries and do not require hover;
- normal-scale screenshots on supported macOS appearances.

### Performance

- no public network or expensive diagnostic request on a one-second timer;
- opening multiple views does not duplicate sources;
- dashboard close cancels dashboard-only work;
- log and chart memory remains bounded during a multi-day run;
- main-thread work is measured under active telemetry churn.

### Release

- clean build and full test suite;
- signed/notarized artifact verification;
- Gatekeeper launch on a clean account;
- single-instance behavior;
- upgrade from the previous release with live settings/history;
- old-bundle detection and relaunch behavior;
- no second menu-bar item after restart/update.

## Deliberate exclusions

The following are not part of the first mega-app implementation:

- chat client or prompt-history storage;
- load generator;
- globe/map visualization;
- remote SSH control;
- automatic fan control;
- setuid or wildcard-sudo helpers;
- a local Python/web dashboard server;
- automatic restart as trust remediation;
- `darkbloom start --all`;
- hard-coded “recommended model” enums;
- per-job progress inferred from aggregate network capacity;
- provider payout inferred from customer prices;
- official job duration inferred from a polled activity boolean;
- fleet ownership inferred from public attestation;
- unbounded logs, CSV files, process output, or in-memory chat;
- auto-update before signed feed and rollback proof.

## Delivery checkpoints

Each checkpoint should be independently reviewable and revertible:

1. **Shell checkpoint:** dashboard opens once, restores, and uses existing snapshots only.
2. **Activity checkpoint:** calendar charts and coverage math pass focused database tests and visual review.
3. **Opportunity checkpoint:** live public data degrades independently and recommendations explain every factor.
4. **Operations checkpoint:** Models/Health/Logs and lifecycle progress work without weakening confirmation gates.
5. **Optional systems checkpoint:** Fleet and Energy remain feature-gated until their contracts pass security review.
6. **Release checkpoint:** the exact signed artifact passes tests, normal-scale UI review, upgrade, Gatekeeper, and single-instance checks.

Do not combine all phases into one release branch. The safest first implementation slice is Phase 0 plus Phase 1: it creates the final product shape while reusing only data that is already trusted.

## Final recommendation

This product is a native operator app with two deliberate speeds:

- a stable, minimal menu popup for what is happening now and the three lifecycle actions; and
- a richer dashboard for understanding history, opportunity, model configuration, health, and eventually true operating cost.

Telemetry provenance, lifecycle safety, calendar accounting, and the native single-process architecture remain the implementation authority.
