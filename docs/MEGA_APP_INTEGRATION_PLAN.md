# Darkbloom Mega App Integration Plan

Review snapshot: 2026-09-03

Repositories reviewed at pinned revisions:

- [splittydev/darkbloom-dashboard](https://github.com/SplittyDev/darkbloom-dashboard/tree/87cef17b52e9ca8fb7c6d2f91d863231e7796e45) — `87cef17`, tag `v1.4.1`, MIT
- [justin-schroeder/darkbloom-monitor](https://github.com/justin-schroeder/darkbloom-monitor/tree/83fed2f3ff67806946d3d092dc40ea9724169255) — `83fed2f`, no repository license at review time
- [jordglob/darkbloom-live-stats](https://github.com/jordglob/darkbloom-live-stats/tree/59b902a31b99f968ce87a76da4abaa4de1d15048) — `59b902a`, tag `v4`, MIT

This document is an implementation plan, not authorization to copy code, change the current provider, publish a build, or merge the reviewed repositories into this one.

## Executive decision

Do not merge any of the three applications wholesale.

Keep this repository as the product and architecture owner:

- one native Swift/AppKit macOS application;
- one compact menu-bar popup for immediate status and safe controls;
- one retained, resizable dashboard window for history, analysis, models, health, and diagnostics;
- `DarkbloomTelemetry` as the only layer allowed to read provider files, run commands, call APIs, or persist measurements;
- explicit freshness, provenance, coverage, and unavailable reasons for every displayed value;
- no prompt, response, reasoning, API-key, or raw job-content persistence.

Independently implement the strongest ideas from the community projects:

| Source | Adopt | Adapt | Do not adopt |
| --- | --- | --- | --- |
| Splitty dashboard | Dashboard information architecture, demand/capacity presentation, trust explanations, operation progress UI | Rebuild as native views over our typed telemetry actors and bounded stores | Whole dependency graph, plaintext credentials, chat/load generator, permissive SSH, `start --all`, silent warmup/restart failures |
| Justin monitor | Compact visual hierarchy, hourly activity charts, chart tooltips, model metadata, release discipline | Reimplement ideas without copying code because the repository has no license | Direct lifecycle runner, fallback restart-on-start, unbounded stderr, root fan helper, inferred fleet identity |
| Jordi live stats | Power/energy concepts, per-model work-rate math, separated base rewards, distinct polling cadences | Make energy an opt-in typed subsystem with actual elapsed-time integration and safe privilege boundaries | Python HTTP bridge, browser UI, wildcard sudoers, unbounded CSV/logs, fixed-interval energy math, Sweden-specific defaults |

The immediate product sequence should be:

1. Build the dashboard shell from data we already trust.
2. Add calendar activity and earnings charts from our existing database.
3. Add public network opportunity data as a separately sourced, clearly labeled view.
4. Improve models, health, logs, and lifecycle progress.
5. Gate fleet and energy behind stronger data and security contracts.
6. Harden packaging so only one current app instance can run.

## Current product baseline to preserve

The current application already has stronger foundations than the three projects in several important areas:

- `DarkbloomTelemetry` is UI-independent and contains source policy, bounded reads, parsing, derivation, persistence, account earnings, inventory, and provider controls.
- `DarkbloomMonitor` owns the native `NSStatusItem`, `NSPopover`, SwiftUI presentation, and retained Settings window.
- Token rate is derived only from positive counter/time deltas for the same provider process identity.
- Loaded, configured, enabled, preloaded, idle, and unavailable model states are not intentionally conflated.
- Lifecycle commands use direct process arguments rather than a shell and already have freshness/customer-impact gates.
- Hourly account and reward aggregates are stored without raw prompt or response content.
- The popup is deliberately bounded at approximately 400 × 600 rather than becoming a full dashboard.

These are invariants, not temporary implementation details. New work should extend them.

## Repository deep dive

### 1. Splitty dashboard

#### What it does well

Splitty has the broadest product surface. Its macOS layout separates Overview, Network, Demand, Models, Machines, Logs, Chat, and Load Generator into a sidebar rather than crowding a menu popup. That is the right information architecture for our resizable dashboard. See its [feature inventory](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/README.md#L20-L43) and [macOS navigation](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Views/Bootstrap/Components/ContentView%2BmacOS.swift#L157-L210).

Its API controller separates data by cadence and backs off after failures instead of putting all network work on one fast timer. The approach is visible in [`APIDataController`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/Observables/APIDataController.swift#L88-L200). We should use the same principle with different implementation details: capacity may refresh quickly, network history slowly, and immutable catalog metadata only occasionally.

Its Demand view turns raw capacity fields into understandable pressure signals, including queued plus active demand per routable provider. See [`DemandTab`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Views/Tabs/DemandTab.swift#L4-L75) and the [capacity response model](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/API%20Codables/DarkbloomModelCapacity.swift#L3-L23). This is useful as an opportunity explanation, provided it is not presented as guaranteed income.

Its restart flow exposes intermediate subtasks and outcomes rather than showing a spinner with no explanation. See [`RestartController`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/Observables/RestartController.swift#L160-L291). Our lifecycle service should adopt that presentation contract while retaining our stricter execution and confirmation rules.

Its trust-level explanations and local service details are good examples of progressive-instead-of-hiding. See [`LocalServiceDetails`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Views/Components/LocalServiceDetails.swift#L5-L55).

#### What must be redesigned

The app stores sensitive settings through `UserDefaults`, including API-oriented settings that should live in Keychain or not be stored at all. The settings implementation is visible in [`Settings`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/Observables/Settings.swift#L19-L88). It does use Keychain for SSH passwords in [`SSHPasswordKeychain`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/SSHPasswordKeychain.swift#L9-L84), but host-key validation accepts any host. We should not ship remote control until known-host pinning, per-host authorization, and an audit trail exist.

Its local start path uses `start --all`. That conflicts with this app's explicit enabled/preloaded model configuration and can load unintended models. Our lifecycle service must resolve exact model IDs from the validated provider configuration and pass them directly.

Warmup has useful initial-delay and retry concepts, but uses a hard-coded model recommendation set and can swallow errors. See [`WarmupCoordinator`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/Observables/WarmupCoordinator.swift#L37-L99). Native provider preload should remain the primary mechanism. Synthetic warmup should be a separate, opt-in feature only if runtime evidence shows it is necessary.

The app has a substantial third-party graph and branch-pinned packages. That is acceptable for a broad standalone dashboard but unnecessary for this focused native app. Every new dependency here should have an explicit feature, security, update, and binary-size justification.

Its earnings snapshot logic is presentation-friendly but does not have our high-water, withdrawal, calendar coverage, and base-reward separation guarantees. See [`EarningsController`](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/DarkbloomDashboard/Logic/Observables/EarningsController.swift#L32-L117). We should retain our database as earnings authority.

The CI workflow skips UI tests, so attractive screenshots are not enough evidence for lifecycle or persistence behavior. See the [CI workflow](https://github.com/SplittyDev/darkbloom-dashboard/blob/87cef17b52e9ca8fb7c6d2f91d863231e7796e45/.github/workflows/ci.yml#L45-L69).

#### Splitty conclusion

Use Splitty as the primary dashboard UX reference and a secondary source for capacity formulas. Do not use it as the data, security, process-control, or persistence foundation.

### 2. Justin monitor

#### What it does well

Justin's app is the closest visual reference to our current product. Its compact native popup uses a clear status header, three primary metric tiles, hourly activity charts, collapsible detail, and controls. Its [README screenshots and feature list](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/README.md#L22-L108) demonstrate that hourly detail can remain readable without turning the first screen into a table.

Its activity ledger keeps a bounded multi-day history, deduplicates observations, and separates base rewards from work earnings. See [`ActivityHistory`](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomCore/ActivityHistory.swift#L52-L187). We already have a stronger SQLite foundation, but its visual grouping is worth reproducing.

Its current-hour projection progressively blends prior behavior with the observed portion of the hour. See [`RunRateProjection`](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomCore/RunRateProjection.swift#L3-L44). If we add this, it must be optional, visually differentiated from actual earnings, and never substituted for a missing observed value.

Its serving-model picker makes model RAM/download metadata visible at decision time. See [`ServingModelPickerView`](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomMenu/ServingModelPickerView.swift#L38-L243). Our Models dashboard should combine this idea with our existing My Catalog/Available distinction and separate Enable, Preload, and Delete actions.

Its release workflow runs build/test and includes signing, notarization, disk-image creation, and publication steps. See its [release workflow](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/.github/workflows/release.yml). We should adopt the delivery discipline, not assume that the presence of workflow steps proves every published artifact is notarized.

#### What must be redesigned

The repository had no license at review time. Its code and assets must not be copied. Product ideas and observed behavior may be independently implemented. The missing license is tracked in [issue 4](https://github.com/justin-schroeder/darkbloom-monitor/issues/4).

Its lifecycle control is weaker than ours: starting may fall back to restart when no model is selected, active-job confirmation is not equivalent to our customer-impact gate, and provider state reconciliation is less strict. The implementation is visible in [`AppState`](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomMenu/AppState.swift#L283-L407). We should keep our control service and adopt only its compact icon presentation.

Subprocess stderr is accumulated without a strict byte cap in the command path. See the same [`AppState` command implementation](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomMenu/AppState.swift#L449-L522). Every command and diagnostic source in our app must retain timeout and output limits.

Its warmup code claims a stronger coordinator identity relationship than the implementation can consistently prove. See [`CoordinatorAPI`](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomCore/CoordinatorAPI.swift#L314-L369). Any future local warmup endpoint must match the fresh provider PID/process identity and fail closed.

Its fleet logic assumes identity fields that the live public attestation response did not expose during this review. Fleet should therefore remain gated behind a documented, authenticated, stable identity contract rather than inferred from current public responses.

The privileged fan helper uses a setuid-root installation model. See [`FanHelper`](https://github.com/justin-schroeder/darkbloom-monitor/blob/83fed2f3ff67806946d3d092dc40ea9724169255/Sources/DarkbloomMenu/FanHelper.swift#L4-L90). This is too broad for a monitoring application and should not be adopted.

#### Justin conclusion

Use Justin as the primary compact-chart and release-process reference. Independently recreate the relevant interaction patterns. Do not copy source and do not replace our telemetry or control layers.

### 3. Jordi live stats

#### What it does well

Jordi's project is a useful prototype for a deeper operations page. It deliberately separates fast provider state, slower earnings, and power-only updates. Its architecture is summarized in the [README](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/README.md#L130-L139). We should preserve that separation inside native actors rather than running a local web server.

It calculates per-model work revenue and keeps base rewards separate. The account and earnings paths are in [`server.py`](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/dashboard/server.py#L555-L758). The useful metric is realized work earnings per million observed tokens, but only when both token coverage and earnings attribution are valid.

Its power history preserves gaps and peaks instead of smoothing every missing interval into zero. See its [energy acquisition and aggregation](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/dashboard/server.py#L941-L1194) and [downsampling](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/dashboard/server.py#L854-L878). These are valuable presentation principles.

It also surfaces system RAM, temperature/fan information, and competing local inference processes. Those can make a Health page useful, provided each is labeled direct, estimated, unavailable, or permission-blocked.

#### What must be redesigned

The project has no automated tests or CI and no locked dependency manifest. Its Python and shell implementation should be treated as an exploratory prototype, not production code.

The earnings fetch does not establish complete pagination/coverage before calculating rates. Its inference-duration estimate polls a boolean and cannot accurately account for short or concurrent jobs. We must not present that duration as authoritative.

The dashboard rereads growing CSV files and serves browser content from a loopback HTTP process. Several values flow into HTML, and state-changing routes do not have a native-app trust boundary. The route implementation is visible in [`server.py`](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/dashboard/server.py#L1197-L1307). We already have a safer native process and should not add another server.

The installer grants a wildcard `powermetrics` sudo rule. See the [sudoers template](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/launchd/darkbloom-powermetrics.sudoers.template#L1) and [installer](https://github.com/jordglob/darkbloom-live-stats/blob/59b902a31b99f968ce87a76da4abaa4de1d15048/install.sh#L56-L74). Do not adopt this privilege model.

Its energy loop uses a fixed integration interval rather than the actual time between samples and can add an estimated baseline when the primary sample is absent. This can manufacture energy consumption. Our implementation must integrate actual elapsed time and break the series across gaps.

The electricity-cost defaults are geographically specific. The app should start with a user-entered fixed currency/kWh tariff and add explicit time-of-use schedules before considering market-price adapters.

#### Jordi conclusion

Use Jordi as an idea source for an optional Energy page and richer Health diagnostics. Rebuild everything as bounded native Swift sources with no web server and no broad privilege grant.

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
- **Calendar-day average tok/s:** sum of observed generated token deltas divided by sum of covered active inference seconds within the local calendar day. Do not divide by wall-clock day length.
- **Per-model average tok/s:** same formula, grouped only where model identity is known for the covered interval. Do not attribute an aggregate delta across concurrent unknown models.

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
- Establish a hard rule that Justin's unlicensed source cannot be copied.
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

### Phase 5 — lifecycle progress and live model warming

Goal: make Start, Stop, Restart, and one-time runtime model selection transparent without weakening safeguards. The detailed approved design is in [`docs/superpowers/specs/2026-09-03-live-model-warming-design.md`](superpowers/specs/2026-09-03-live-model-warming-design.md).

Work:

- Keep active/unknown customer-impact warnings. The user may confirm and proceed; the action is not silently blocked.
- Keep exact enabled-model resolution and never replace it with `start --all`.
- Publish an operation state machine:
  - queued;
  - validation;
  - confirmation required;
  - command launched;
  - waiting for fresh process identity/state;
  - reconciling enabled/preloaded models;
  - optional warmup;
  - complete, partial, failed, cancelled, or timed out.
- Attach bounded, user-readable failure details to each subtask.
- After any action, wait for a new/fresh provider snapshot before declaring success.
- Treat provider `preload_models` as authoritative startup intent.
- Keep every saved enabled model in the exact repeated `--model` startup arguments while `max_model_slots` controls residency.
- Add `--local-endpoint` to app-managed Start, retaining authenticated loopback defaults. Never add `--no-auth`, a non-loopback bind, or `--all`.
- Add **Make Warm** to enabled, downloaded, unloaded model rows:
  - leave Enable and Preload unchanged;
  - send one bounded authenticated local `/v1/chat/completions` request for the exact model with `max_tokens: 1`;
  - let Darkbloom use a free slot or choose an idle eviction candidate;
  - warn but allow the attempt when inference is active or unknown;
  - never kill active inference or silently restart the provider;
  - confirm success only from fresh daemon and loaded-model evidence.
- When the currently running provider lacks the local endpoint, present a separate one-time **Enable Live Switching** stop/start transition using the lifecycle customer-impact warning. After setup, normal model switches do not restart.
- Treat `~/.darkbloom/local.json` as a bounded, private, current-run control source. Accept only an authenticated loopback endpoint; keep its API key request-scoped and out of logs, persistence, fixtures, and errors.
- Characterize whether the one-token local request affects daemon job/token counters. Exclude it only when exact attribution is possible; otherwise disclose the locally derived counter limitation instead of guessing.
- Only add **Keep Warm** after a live test proves preloaded models unload in a way that harms operation.
- If periodic Keep Warm is later added:
  - make it opt-in and separate from Preload;
  - bind only to a fresh loopback endpoint associated with the current provider process identity;
  - generate payloads with `JSONEncoder`;
  - use exact configured model IDs;
  - obey slot and memory capacity;
  - skip while `inference_active` or customer impact is unknown;
  - rate-limit and cap request/response bytes;
  - expose every failure.
- Do not recommend restart as a generic trust remediation without reproducing and understanding the effect locally.

Files:

- extend `Sources/DarkbloomTelemetry/ProviderControlService.swift`
- add `Sources/DarkbloomTelemetry/LocalEndpointDiscovery.swift`
- add `Sources/DarkbloomTelemetry/ModelWarmupClient.swift`
- add `Sources/DarkbloomTelemetry/ProviderOperation.swift`
- extend `Sources/DarkbloomMonitor/ProviderControlStore.swift`
- extend `Sources/DarkbloomMonitor/ModelManagerView.swift`
- extend `Sources/DarkbloomMonitor/ProviderLifecycleControls.swift`
- add `Sources/DarkbloomMonitor/Dashboard/OperationProgressView.swift`
- add state-machine and integration-style fake-runner tests

Acceptance:

- no Start/Stop/Restart success is shown from exit status alone;
- active and unknown work both require an explicit confirmation path;
- failures and partial results remain visible until dismissed or superseded;
- the final loaded/active model set is reconciled against exact configured intent;
- Make Warm leaves Enable and Preload unchanged and never restarts or kills the provider;
- an idle one-slot provider can replace its warm model using the authenticated local endpoint;
- an active or unverifiable provider warns but allows the non-destructive attempt;
- missing endpoint support is handled by a separately confirmed one-time setup transition;
- synthetic-request effects on locally derived metrics are precisely excluded or explicitly disclosed;
- periodic Keep Warm cannot run concurrently with known customer inference.

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

The strongest version of this product is not a fourth clone of one community dashboard. It is a native operator app with two deliberate speeds:

- a stable, minimal menu popup for what is happening now and the three lifecycle actions; and
- a richer dashboard for understanding history, opportunity, model configuration, health, and eventually true operating cost.

Splitty supplies the best dashboard vocabulary, Justin the best compact-chart vocabulary, and Jordi the most useful energy questions. Our existing telemetry provenance, lifecycle safety, calendar accounting, and native single-process architecture should remain the implementation authority.
