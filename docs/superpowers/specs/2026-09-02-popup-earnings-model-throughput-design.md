# Popup Earnings and Model Throughput Design

## Goal

Keep the Darkbloom menu popup compact while adding truthful calendar earnings, earnings per hour, and average token throughput by model, while ensuring model-state pills remain visible during idle periods.

## Data rules

- Both metrics use today in the Mac's current local calendar and reset at local midnight.
- Weekly earnings use the Mac's current local calendar week. Complete retained history is labeled `This week`; an incomplete but proven bucket window is labeled `Observed this week`.
- Earnings per hour is today's locally observed lifetime-earnings delta divided by its real observation duration in hours. Zero-duration, negative, stale, or unavailable earnings do not produce a rate.
- A token-rate sample is recorded only when the daemon exposes a non-empty current model and the derived rate is finite and positive.
- Token deltas may not cross a daemon process change, timestamp rollback, counter rollback, or model change.
- Token samples are stored locally in a compact SQLite database with model, capture time, process identity, daemon write time, and measured rate. Duplicate daemon samples are ignored and samples from earlier calendar dates are pruned after the date changes.
- A model average is the arithmetic mean of valid measured samples captured since local midnight. It is not inferred from job counts, earnings, capacity, or token totals.
- The popup shows the model breakdown only when at least two models have valid samples. With zero or one observed model it retains the single aggregate average card. Unavailable values are omitted rather than labeled with explanatory placeholder text.
- Read-only model pills derive from the continuously refreshed telemetry snapshot, not the settings control snapshot's 10-second mutation-safety timeout.
- Fresh daemon state may show an active model in green. Stale last-good daemon state is shown only when current status confirms the provider is running, and any formerly active model is demoted to loaded-idle yellow. A confirmed stopped provider, or configured models without residency evidence, shows enabled models as available gray.

## Popup layout

- Throughput keeps the large `Current` card.
- When fewer than two models have history, the second card is `Today's average` when available.
- When two or more models have history, a compact `Today's average by model` panel replaces the aggregate card. Each row has a concise model label and a right-aligned `tok/sec` value.
- Add an `Earnings` section with `Today` and `Average/hour` cards plus a full-width calendar-week total when available.
- Completed jobs and model-state pills remain below these metrics.
- The popup stays 400 points wide and scrolls vertically inside its existing 600-point viewport if content exceeds the available height.

## Verification

- Unit tests cover hourly-rate math, complete and partial calendar-week totals, missing/stale data, cross-model delta rejection, sample deduplication/pruning, per-model aggregation, the two-model display threshold, and stable model-state evidence precedence.
- Existing tests and a release build must pass.
- Launch the release app and inspect the popup at normal scale. Verify spacing, clipping, hierarchy, model labels, and metric readability.
