# Provider stats, history, and charts — phased plan for Darkbloom Control

Companion to [DARKBLOOM_099_FLASH_AUDIT.md](DARKBLOOM_099_FLASH_AUDIT.md) (capability
evidence and pinned source links for every upstream surface named here) and to
[research/STAT_ATTRIBUTION_REVIEW.md](research/STAT_ATTRIBUTION_REVIEW.md) (the
attribution finding that shapes Phases 1–2). Planning document only: no code was
changed and no authenticated or mutating call was made while producing it.

Reviewed against official Darkbloom `b6f9574` (console-ui + coordinator +
provider-swift) and Darkbloom Control `f9b65d1`, 2026-09-25 (America/Phoenix).
Current app test baseline: **728 tests / 93 suites** (root-provided; the 540/70
figure in docs/CLI_097_VERIFICATION.md predates later suites).

## 1. Current app architecture (inspected first)

Persistence (Sources/DarkbloomTelemetry):

- `EarningsDatabase.swift` — SQLite (WAL, `synchronous=NORMAL`, 2 s busy timeout)
  with UTC-hour rollups: `earnings_hourly (hour_start, model, amount_micro_usd,
  jobs, prompt_tokens, completion_tokens, PK(hour_start, model))`,
  `account_hourly (hour_start PK, captured_at, lifetime/available/withdrawable
  micro-USD, lifetime_count)`, `rewards_hourly`, `collection_state
  (singleton=1, last_earning_id)` as a **single watermark** (no account/provider
  dimension), and `earnings_coverage (singleton=1, coverage_start)` bounding what
  recorded history claims (:165–215, 800–930).
- `AccountEarnings.swift` — `AccountEarning` already decodes **earning id,
  provider id, provider key**, model, amount, tokens, created_at (the endpoint is
  provider-aware; our storage currently is not — the attribution review's core
  finding).
- `ModelProfitability.swift` — `servingAverages` divides **account-level**
  model earnings by this Mac's observed model-active time;
  `MonitorStore.refreshModelServingProfitability` wires it. Consequence (review
  §"Consequences"): with multiple owned Macs, per-model account earnings include
  other machines, so dividing by this Mac's activity yields a *derived, mixed-
  attribution* rate, not a measured per-Mac rate; net profit additionally uses
  *estimated* electricity allocation.
- `ActivitySeries.swift` — UTC-hour display buckets with explicit coverage:
  `recorded | unavailable | boundaryUncertain`; averages restricted to hours that
  actually have ledger rows.
- `EventBuffer.swift` — bounded in-memory ring (≤100 events, ≤128 KiB payload).
- Public collectors (catalog 30 min, pricing 15 min, capacity 60 s visible /
  300 s hidden, cache-status 60 s, network-series 5 min) with 256 KiB body caps,
  exponential backoff + ≤20 % jitter, per-source failure caps — contract in
  docs/PUBLIC_API_CONTRACT.md.
- `AuthenticatedEarningsClient.swift` — `GET /v1/provider/account-earnings` with
  `~/.darkbloom/auth_token` (provider device token).
- `StateParsers.swift` — daemon-state + loaded-models parsing incl. per-slot
  `mtp_enabled/mtp_active/mtp_inactive_reason`, kv backend, load errors. The app
  does **not** poll local HTTP `/metrics` today.
- `SystemGPUUsageStore.swift` — whole-Mac GPU sampling; no per-model attribution
  exists anywhere upstream (audit §1.5).

Charts today: `ActivityChartData.swift` renders hourly earnings/activity;
`NetworkSeries.swift` renders the public 24 h network history. There is no
longer-horizon store than the hourly tables, and **no continuous vitals history**.

## 2. Upstream bounds that shape this design (all source-verified)

- `GET /v1/provider/account-earnings`
  ([billing_handlers.go L684ff](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/billing_handlers.go#L684)):
  `limit` default **50**, capped **1000**; **no pagination cursor** — a single
  most-recent-N query; `history_limit` echoes the bound; server read-cache
  **20 s** keyed `account-earnings:{account}:{limit}`. Implication: older-than-
  window events are **not re-fetchable** once they scroll past `limit`; local
  ingestion must keep up (bounded, frequent-while-running collection), and any
  gap is permanent for raw rows. Do not claim backfill beyond what this bound
  allows; `GET /v1/payments/usage`'s lookback/page behavior is **not yet
  established** — measure it before relying on it for pruning or backfill.
- Money surfaces are three distinct series that must never be merged:
  **consumer spend** (`/v1/payments/usage` — this account as a *customer*),
  **provider earnings, account-wide** (`account-earnings` — all linked Macs),
  and **this Mac** (only local telemetry: daemon-state slots, whole-Mac GPU,
  power). The console likewise keeps account earnings off machine cards
  (audit §9, CardEarningsRow.tsx:1–4).
- TTFT-style latency exists upstream as **measured** timing telemetry
  (`observed_prefill_tps`, `model_load_time_ms`, reputation
  `avg_response_time_ms` = real TTFT — all Privy-only surfaces; audit §1.3/§9).
  **Never derive "TTFT" or latency from earnings-hour averages** — earnings
  hours carry no timing semantics. Until a measured source is available, show
  no latency stat at all rather than a derived one.
- MTP **counters** exist only on local `/metrics` (cumulative **per slot
  lifetime**); daemon-state carries posture but no counters (audit §2.2).
  Differencing counters requires slot-lifetime epoch/reset detection.
- Heavy endpoints (`/v1/stats` 1.45 MB, `/v1/providers/attestation` 972 KB,
  `/v1/network/totals` probe-timed-out) must not be polled by the app; even the
  official console fronts stats with a server-side snapshot cache (audit §9).

## 3. Global invariants for every stat and chart

Provenance — every persisted/displayed value is tagged exactly one of:

- `measured` — read from an authoritative source at observation time (ledger
  events, daemon-state slots, whole-Mac GPU/power samples, `/metrics` counters).
- `derived` — arithmetic over measured rows in our own DB (hourly sums,
  acceptance ratios). Mixed-attribution arithmetic (account earnings ÷ this
  Mac's hours) stays `derived` **and** carries an explicit attribution label.
- `estimated` — forward-looking (the per-card what-if, §6 Phase 5); never
  rendered in the same visual register as actuals.

Units, epochs, gaps:

- Money: integer micro-USD end-to-end; Decimal conversion only at render.
- Buckets: **UTC hour** rollup grain; display may bucket up, never silently
  below. Rolling 24 h/7 d windows (where a source defines them) are labeled as
  such and distinguished from UTC calendar aggregates.
- Gaps are gaps: missing stays `unavailable`/`boundaryUncertain`; a zero is data
  only when a source returned it (existing `ActivitySeries` rules).
- Freshness: charts carry `snapshot_at` (source stamp when available) and
  `fetched_at`; stale renders show age (console provenance pattern,
  useNetworkStats.ts:63–67).

Dedup and isolation (attribution review §"Required plan updates"):

- Ingest events idempotently by **(account_scope, event_id)** before deriving
  rollups. Handle late/out-of-order events (upsert, not skip) and account
  switches (scope every row; a switch must never mix ledgers).
- Keep consumer spend, account earnings totals, per-provider totals, per-model
  totals, and rewards as **distinct series**; reconcile sums against the
  authoritative account totals while tracking missing coverage explicitly.
- Do not manufacture provider IDs during migration (review item 1/4).

Retention — bounded, explicit, non-destructive:

- Raw event rows: keep a **bounded ring per account** (proposal: newest
  10 000 earning events + newest 10 000 usage events; the time span depends
  on traffic and must be shown, never assumed to cover a full day). Pruning
  deletes strictly outside the newest-N window by `created_at`, in the same
  transaction as rollup updates, in bounded maintenance batches during collection.
  Startup-only pruning would not bound storage in a long-running app.
- Hourly rollups: `earnings_hourly` grows **24 × (distinct models that hour
  earned) rows/day**, not 24 rows/day — a 6-model box adds ~144 rows/day.
  Bound with a **daily rollup** after 30 days (`*_daily` keyed
  `(day_start, model)`), pruning hourly detail past 30 days. Cap per-account
  retained history at **400 days**, plus explicit account/provider/model cardinality
  and database-byte limits. Days alone do not bound arbitrary series counts.
- No migration may silently drop data: schema version bump migrates existing
  hourly tables to **account-level legacy coverage** (labeled, no fabricated
  provider IDs), preserving current rows as-is.
- Unverified claims stay explicit: nothing here assumes any upstream backfill
  or reconstruction; pruning is final for raw rows (§2 bound above).

## 4. Data sources available to the app (auth class + role)

| Source | Auth | Role in this plan |
| --- | --- | --- |
| `/v1/payments/usage` | consumer key **or** provider token | **consumer spend** raw events (separate table; never `earnings_hourly`). Page/lookback bound: unestablished — measure first |
| `/v1/provider/account-earnings` | consumer key or provider token | **provider earnings, account-wide**; bound: ≤1000 most recent, no cursor, 20 s server cache (§2) |
| `/v1/key` | **an actual consumer API key** (provider token → 404, audit §1.2) | spend-cap/reset/RPM-ITPM-OTPM/allow-list display; surface hidden when only a provider token exists |
| Daemon-state + loaded-models files | none (local) | **this Mac** posture/vitals: slots (MTP/KV), warm/advertised, thermal, memory, capacity, load errors |
| Local `GET /metrics` | local bearer or none | **this Mac** cumulative MTP counters (needs epoch/reset detection); separate safe collector, Phase 2 |
| `/v1/models/capacity`, `/v1/network/series` | none | demand context for forecast/expansion, existing cadences |
| `/v1/me/providers`, `/v1/me/summary` | **Privy interactive only** | out of scope for the app without a browser login flow (audit §1.3); measured latency lives here — absent that, no latency stats |

## 5. Collection lifecycle (corrects dashboard-coupled sampling)

Vitals/counter history is **owned by the app's run lifecycle**, not by window
visibility: a small lifecycle-owned sampler runs while Darkbloom Control is
running, at a modest cadence (proposal: 60 s) with power awareness (pause on
battery + no serving activity; never run while the provider is mid-restart).
Rendering pauses when the dashboard is hidden — **collection must not**: a hidden
dashboard must not silently stop history or the menu-bar GPU sampler. Public
collectors keep their existing visibility rules (they are cheap-to-recover);
history samplers are not, because `account-earnings` cannot backfill (§2).

## 6. Phased plan (concrete schema, files, tests, boundaries)

### Phase 1 — provider-aware earning events + consumer-spend events

Schema (migration `v2`, additive):

```sql
CREATE TABLE earning_events (
  account_scope TEXT NOT NULL, earning_id INTEGER NOT NULL,
  provider_id TEXT, provider_key TEXT,
  model TEXT NOT NULL, amount_micro_usd INTEGER NOT NULL,
  prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL,
  completed_at REAL NOT NULL, ingested_at REAL NOT NULL,
  PRIMARY KEY (account_scope, earning_id));
CREATE INDEX earning_events_completed ON earning_events (completed_at);
CREATE TABLE usage_events (            -- consumer spend; separate series
  account_scope TEXT NOT NULL, job_id TEXT NOT NULL,
  model TEXT NOT NULL, cost_micro_usd INTEGER NOT NULL,
  prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL,
  requested_at REAL NOT NULL, ingested_at REAL NOT NULL,
  PRIMARY KEY (account_scope, job_id));
```

Files: new `UsageClient.swift` (`/v1/payments/usage`); extend
`EarningsDatabase.swift` (events + bounded pruning + daily rollups); ingestion in
`MonitorStore` beside the existing earnings poll; UI in the existing activity
chart + a per-request detail list (console payout-table shape).

Boundary handling: overlapping pages (refetch same window) → idempotent upsert;
late events older than the watermark → upsert within an open retained interval;
events before its finalization boundary create an explicit coverage warning.
Do not invent a missed-event count when an API gap reveals no event identities; account switch →
new `account_scope`, previous rows remain but are excluded; summary reconciliation
compares stored sums vs authoritative `total_micro_usd` and reports drift + the
coverage start. Poll cadence respects the 20 s server cache (≥30 s locally) and
the ≤1000/no-cursor bound (§2).

Tests: parser fixtures; duplicate/out-of-order/late events; account-switch
isolation; pruning keeps newest-N and never touches rollups; drift
reconciliation; consumer spend never appears in earnings series (schema-level
assertion).

Acceptance: reopening after 24 h shows identical rollups (idempotent ingest);
forced API failure keeps last-good with stale badge; drift report explains any
gap instead of hiding it.

### Phase 2 — this-Mac vitals + measured timing/MTP counters

- Lifecycle-owned sampler (§5) writing an in-memory ring + `vitals_hourly
  (hour_start, metric, min, avg, max, samples)`; sources: daemon-state slots
  (posture), whole-Mac GPU, thermal. Provenance `measured (whole Mac)` /
  `measured (this slot)`.
- New safe `LocalMetricsCollector` for `/metrics` only when a discovered local
  endpoint exists (uses the Phase-0 discovery fix in the audit's P0): parse
  `mtp_*` counters with **slot-lifetime epochs** — a counter decrease or a
  posture transition (slot unload/load in daemon-state) starts a new epoch;
  rates are only computed within an epoch. Never diff across epochs.
- Charts: 24 h posture timeline (MTP active/inactive reasons, load errors), GPU
  utilization labeled "whole Mac — no per-model attribution".
- **No latency stat until a measured source exists** (§2); this phase adds none
  unless the Privy surfaces become reachable.

Tests: rollup math vs fixtures; epoch reset detection (counter regression,
posture flip, process restart); sampler keeps running with dashboard hidden
(lifecycle test); power-aware pause; stale daemon-state (`writtenAt` window).

Acceptance: 24 h view reproduces fixtures exactly; hidden-dashboard collection
continues; no cross-epoch MTP rate is ever rendered.

### Phase 3 — key constraints surface (needs a real consumer API key)

`GET /v1/key` display: spend cap vs window, reset time, RPM/ITPM/OTPM, model
allow-list. The surface is hidden unless the user has stored a consumer API key
(provider token 404s — audit §1.2). Tests: parser fixtures incl. absent limits;
"no key" state; UI never fabricates zero limits.

### Phase 4 — bounded history charts (7 d / 30 d / 400 d)

Daily rollups (§3 retention) render 7 d/30 d/400 d views: actual earnings
(measured+derived, account-wide label), spend (separate color + label), tokens by
model, MTP acceptance ratio within epochs (derived), demand overlay from
`/v1/models/capacity`. Money and tokens never share an axis; estimated overlays
hatched/dashed. Tests: bucket-up sum invariance (24 h vs 7 d totals agree for the
same window); UTC rendering; partial-coverage rendering from coverage metadata.

### Phase 5 — per-card what-if forecast (independent, all cards)

Matches the actual implementation direction (attribution review; anchors:
`ModelProfitability.servingAverages`, `ModelRunForecast.calculate`,
`MonitorStore.refreshModelServingProfitability`):

- Every model card (not only Enabled) gets an independent **0–100 % active-hours
  slider**; the estimate is `active_hours_fraction × day × history-derived
  serving gross/net rate` for that card, optionally annotated with **measured**
  tok/s for a token figure. Gross uses the card's serving history; net subtracts
  **estimated** electricity allocation.
- Attribution honesty: until Phase 1–2 provider-aware collection lands, rates
  derived from account earnings carry a standing disclosure
  ("account-level attribution; assumes this Mac's share") — the review's
  requirement 3/5. Consumer public **prices are not provider payouts**: price
  alone must never produce a revenue figure; no `price × runtime` math.
- The forecast never writes settings, changes residency, or feeds the GPU ring
  or any scheduler.

Tests: pure-function math over (rate, fraction) with integer micro-USD;
disclosure presence when attribution is account-mixed; no side effects from
slider interaction; estimate visually distinct from actuals.

### Explicit non-goals

- Privy-only fleet surfaces (`/v1/me/providers`, `/v1/me/summary`) — need an
  interactive console login; no cookie/token borrowing.
- Polling `/v1/stats`, `/v1/providers/attestation`, `/v1/network/totals` (§2).
- Custom warm/protected endpoints (superseded spec), fan mutations, scheduler
  behavior for the forecast.

## 7. Meaningful tests and acceptance (cross-phase)

Existing suites (728/93) stay green. New suites per phase as listed above, plus:
integer-safe sums (no Double money), transactional ingest under simulated
concurrent writes, migration round-trip (v1 DB → v2 legacy coverage, rows
preserved verbatim), and a loopback test asserting the usage client's
request shape and bounded body handling mirror the public collectors' contract
(docs/PUBLIC_API_CONTRACT.md transport rules).


## 8. Codex review: ingestion and migration requirements

These requirements refine the proposed schema before implementation:

- Keep unknown provider identity nullable. Use the verified account ID as the
  account scope; never use a token, a token hash, or a guessed local-machine ID.
  Store only the provider identifier needed for attribution; provider public keys
  need a demonstrated mapping purpose before retaining them.
- Deduplication must survive raw-event pruning. Maintain an account-scoped
  finalized-time boundary and durable compact event identities within the open
  late-arrival window. A repeated API response containing a pruned event must
  never add it to a rollup again. At a finalization boundary, reconcile raw events,
  rollups, and coverage atomically; older unrecognized events require explicit
  correction/coverage handling, not an unconditional additive upsert.
- An event correction must subtract its previous contribution before applying
  the new one, or recompute the affected open bucket. `INSERT OR REPLACE` alone
  does not make incremental aggregates idempotent. Missing usage job IDs cannot
  be deduplicated by a guessed timestamp identity; retain only a source-supported
  identity or mark that feed unavailable for persisted per-request totals.
- Add distinct tables/typed queries for account, provider, provider-model,
  reward, and consumer-spend rollups. Every new money-series key includes
  `account_scope`; provider-level keys also include verified `provider_id`.
  Account-wide legacy buckets stay in their original tables with unknown provider
  attribution. Prevent overlap with newly ingested data through an explicit
  migration cutover timestamp and coverage segments; do not sum both copies.
- Vitals rollups carry process identity, source timestamps, units, coverage
  duration, and sample count. Compute time-weighted averages for irregular
  sampling. MTP rates require a verified continuous process/slot epoch: an unload
  and reload between samples can reset a counter to a larger value, so a simple
  counter-decrease check is insufficient. If continuity cannot be established,
  display the current counter only and leave the rate unavailable.
- Add bounded request timeouts/body sizes, no redirects for bearer requests,
  strict loopback discovery validation, and response-account validation before
  persistence. Reuse the existing safe local endpoint transport policy.
- Required regression cases: repeat a pruned event; correct an existing event;
  missing provider/job identity; account switch during an in-flight response;
  overlapping legacy/new coverage; unobserved slot reload; prolonged app uptime;
  byte/cardinality limit; interrupted migration and rollback. Preserve the
  original database and verify schema/version before enabling a migration.

Implementation order: first build the attribution migration and ingestion tests,
then add collectors, then charts. The next implementation checkpoint is a
fixture-verified additive migration and account/provider query API, before UI
adoption or deletion of historical rows. The current branch contains this plan,
not the new history database or chart implementation.
