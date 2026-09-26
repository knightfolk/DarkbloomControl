# Earnings attribution review

Reviewed by Codex on 2026-09-25 against app base `f9b65d1` and the in-progress compact-card changes. This is a source finding, not an assertion that the current account has multiple providers.

## Existing data supports more precise tracking

`AccountEarning` already decodes an earning ID, provider ID, provider key, model, amount, input/output tokens, and completion time. The account endpoint therefore contains provider-level evidence that the current storage discards.

`EarningsDatabase.upsertHourlyEarnings` reduces these events into `(hour_start, model)` buckets. It keeps a single earning-ID watermark and does not retain account or provider dimensions. `ModelProfitability.servingAverages` then divides those account/model earnings by locally observed model-active time and estimates incremental electricity from this Mac.

## Consequences

- A model's account earnings can include other Macs. Dividing that amount by this Mac's activity does not establish this Mac's measured earning rate.
- The resulting gross-per-active-hour value is derived. Net profit additionally uses estimated electricity allocation. Neither should be labelled measured net income.
- Existing hourly buckets cannot be retrospectively attributed to a machine. Keep them as legacy account aggregates; do not manufacture provider IDs during migration.
- A singleton watermark without an account dimension needs review for account changes and late/out-of-order earning events. Retaining only events above the maximum seen ID is not a general replacement for event-ID deduplication.

## Required plan updates

1. Persist bounded, account-scoped earning events with idempotency by `(account_scope, earning_id)` before deriving hourly totals. Preserve provider/model dimensions internally; do not retain or export bearer credentials.
2. Keep account totals, per-provider totals, per-model totals, rewards, and consumer spending as distinct series. Reconcile sums against the authoritative account totals while explicitly tracking missing history.
3. Establish a verified local-provider mapping before combining provider-specific earnings with this Mac's power/activity. If the mapping is unavailable, use account labels and state the single-provider assumption for a what-if forecast.
4. Version the database and migrate old data as account-level legacy coverage. Use transactional ingestion, bounded parsing, safe integer sums, event-ID deduplication, and tests for overlapping pages, late events, account switches, provider restarts, missing coverage, and counter resets.
5. The compact-card what-if remains an independent 0–100% active-runtime scenario. Its expanded assumptions must disclose account-level earnings attribution until the provider-aware collection work is implemented.

## App source anchors

- `Sources/DarkbloomTelemetry/AccountEarnings.swift`: `AccountEarning` and `AccountEarningsResponse`.
- `Sources/DarkbloomTelemetry/EarningsDatabase.swift`: schema initialization, `upsertHourlyEarnings`, and `activityByModel`.
- `Sources/DarkbloomTelemetry/ModelProfitability.swift`: `servingAverages` and `ModelRunForecast.calculate`.
- `Sources/DarkbloomMonitor/MonitorStore.swift`: `refreshModelServingProfitability` integration.
- [Official account-earnings handler](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/billing_handlers.go#L684).

No live account data was read to establish these findings. No database migration was performed in this review.
