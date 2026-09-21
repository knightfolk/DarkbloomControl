# Public data contract

This describes the current app implementation, not an upstream service guarantee. It was checked against the collectors and MonitorStore on 2026-09-04. No live endpoint availability check was performed for this document. Authenticated account earnings, local daemon state, provider configuration and model control are separate contracts in TELEMETRY_CONTRACT.md.

## Source matrix

All paths below use `https://api.darkbloom.dev`.

| GET path | Meaning | Successful polling interval | Failure cap |
| --- | --- | --- | --- |
| `/v1/models/catalog` | Public model metadata; not installed/enabled/warm state | 30 minutes | 6 hours |
| `/v1/pricing` | Customer token prices; not provider payout | 15 minutes | 6 hours |
| `/v1/models/capacity` | Per-model network routing pressure and capacity | 60 seconds with dashboard visible; 300 seconds hidden | 15 minutes |
| `/v1/cache/status` | Aggregate network cache routing/planner health; not local cache performance | 60 seconds while Network history is visible | 16 minutes |
| `/v1/network/series?window=24h` | Network-wide request and token history; not model-attributed or local work | 5 minutes, dashboard visible only | 1 hour |

Collectors are independent. A pricing failure must not erase capacity or local telemetry. Failure retries use exponential backoff with nonnegative jitter bounded to 20%, limited by each source's cap. Successful requests restore the normal cadence. History retains its next-attempt deadline across dashboard close/reopen; hiding the dashboard cancels its polling task. Store shutdown cancels and joins owned tasks.

## Transport and privacy

- GET with `Accept: application/json`; the request builders add no authorization header, provider identifier, prompts or local logs.
- Request and default public-session resource timeouts are configured to 15 seconds. The resource limit bounds an incomplete response independently of the per-request idle timeout. A real loopback byte-stream test with a 30-second request timeout terminated at about 15.6 seconds under the resource limit. Scheduling adds tolerance; this is not a hard real-time guarantee or proof of production DNS/TLS/proxy timing.
- HTTP response must be 2xx. Non-HTTP responses, decoding failures and invalid payloads fail the refresh.
- Bodies are limited to 256 KiB by declared length and streamed-byte count; an unknown length is still bounded during streaming. The URLSession byte task is canceled when the fetch scope exits.
- Requests bypass local and remote URL caching. Last-good snapshots are retained in app memory; these collectors do not implement persistent disk caching, ETags or conditional requests.
- All public clients default to one dedicated ephemeral public session, with cookie storage, automatic cookies, credential storage and URL caching disabled. Its delegate rejects every redirect, including same-origin redirects, leaving the 3xx response for the client's HTTP-status rejection. Explicitly injected sessions remain caller-controlled and may not provide these guarantees. Tests inspect the actual default session configuration, exercise the redirect delegate, and use a synthetic loopback HTTP server to verify no redirect follow-up or server-cookie replay. This is not a production HTTPS or packet-capture audit.

## Payload validation

Catalog expects `{ "models": [...] }`, decoded using CatalogModel. It accepts at most 128 unique exact model IDs, each nonblank and at most 512 UTF-8 bytes. Catalog size must be finite and nonnegative; minimum RAM must be nonnegative. Catalog size is an estimate, not a local disk measurement. Minimum installed RAM is not free memory or permission to stage a second model.

Pricing expects `{ "prices": [...] }` with `model`, `input_price` and `output_price`. Prices are nonnegative Int64 micro-USD per million tokens. Divide by 1,000,000 using Decimal to display USD per million tokens. For example, 220000 means $0.2200 per million tokens, not per token. IDs are unique, nonblank, at most 512 UTF-8 bytes, with at most 128 records. Lookup is exact; unknown models receive no guessed fallback price.

Capacity expects `{ "models": [...] }`. Records contain `id`, `ready`, `can_accept`, provider counts (`routable_providers`, `warm_providers`, `running_providers`, `cold_providers`), `active_requests`, `queued_requests`, `queue_limit`, `aggregate_tps`, `estimated_ttft_ms`, `token_budget_remaining` and `token_budget_total`. IDs must be nonblank and unique; numeric values are nonnegative, TPS finite, remaining budget no larger than total. Like catalog/pricing, the parser accepts at most 128 records and IDs up to 512 UTF-8 bytes; the network client's body cap additionally bounds transport. Network warm-provider counts do not establish that this Mac has a model loaded.

History expects `window: "24h"`, positive `bucket_seconds` no larger than 86400, ISO-8601 `start_at`, `end_at`, `updated_at`, and `time_series`. End minus start must equal 86400 seconds; updated time cannot precede end. At most 288 buckets are accepted. Each bucket has `timestamp`, nonnegative Int64 `requests`, `prompt_tokens`, `completion_tokens`; timestamps must be strictly ordered, unique, grid-aligned, and the entire bucket must fit in the window. Missing buckets remain gaps, not fabricated zeros. The parser accepts the supplied valid bucket width rather than assuming a fixed 30-minute width.

## Freshness and failure semantics

Catalog and pricing capture times are client-supplied observation times, not server update times. MonitorStore rejects newly fetched catalog observations older than 1800 seconds and pricing older than 900 seconds, or observations in the future. Capacity is fresh for 120 seconds with up to 5 seconds future skew. History additionally validates the server `updated_at` age: no more than 900 seconds old or 60 seconds in the future.

A failed refresh retains any previous value as stale with its original capture time. Without a previous value, the source is unavailable. Consumers must check age as well as availability before using data for decisions; retained data is not proof of current network demand. A zero explicitly returned by a valid payload is different from missing or stale data.

Public history's 24-hour window is intentionally separate from the user's calendar-date earnings and local activity. Public customer pricing cannot be multiplied into a claimed provider earning, hourly payout or profit. Opportunity factors are explanatory network ratios, not a guaranteed ranking or income forecast. None of these endpoints authorizes interrupting jobs, unloading models, or changing local residency. The official CLI remains the only supported path for model configuration and lifecycle actions.

Opportunity presents readable model names, a RAM-minimum check, demand status, and counts for work in progress, work waiting, and providers with the model loaded. Accepting models appear first, followed by queued work and demand per loaded provider; this is a demand comparison, not an earnings recommendation. Canonical IDs, runtime requirements, local catalog state, and customer prices live in expandable details. Stale demand is explicitly identified. Network history is a separate view with hourly data and infrastructure details collapsed by default. RAM minimums do not establish runtime compatibility or available capacity.

## Verification and remaining gaps

Authoritative code: PublicCatalog.swift, PublicPricing.swift, NetworkCapacity.swift and NetworkSeries.swift in Sources/DarkbloomTelemetry; MonitorStore.swift, NetworkPollingPolicy.swift and PublicPollingBackoff.swift in Sources/DarkbloomMonitor.

PublicTransportTests exercises all four real clients through an injected URLProtocol: request properties, response-size boundaries, malformed responses, selected HTTP failures, injected timeout and pre-cancellation. Parser suites cover semantic validation. NetworkSeriesPollingTests exercises the real store's close/reopen retry deadline and shutdown; PublicPollingBackoffTests covers jitter and caps. The latest full suite passed 502 tests in 49 suites before this documentation-only addition.

Loopback coverage also confirms cancellation of the dedicated session's byte stream after body bytes have arrived, while the remainder is stalled. This is session-level evidence, not full collector lifecycle cancellation proof.

Live smoke check on September 4, 2026 at 16:30 America/Phoenix: capacity, catalog, pricing and 24-hour series all fetched and decoded through PublicHTTPSession.shared. Four cases passed in 0.333 seconds. This establishes successful HTTPS acquisition and parser compatibility at that observation, not ongoing availability or future schema stability. No response body or credentials were logged.

Repeat explicitly with `DARKBLOOM_LIVE_PUBLIC=1 swift test --filter livePublic`. The smoke test is disabled in ordinary runs so offline tests do not acquire public data.

Still unproven: full-client midstream cancellation, hard real-time deadlines, adverse production HTTPS/proxy behavior, network timing stress, and future upstream availability/schema stability. Do not infer those from one successful live check, synthetic protocol, configuration/delegate or loopback HTTP tests. See MEGA_APP_PROGRESS_AUDIT.md for the broader incomplete implementation and release gates.

## CLI 0.9.7 extension — September 21, 2026

Capacity optionally includes `draining`. Missing means the older ordinary response; true means maintenance and requires an empty model list. The UI identifies maintenance instead of presenting zero demand.

The cache client retains only `routing_mode` (`on`, `off`, `shadow`, or a fixed unknown label) and optional `sidecar.enabled`, `running`, and `ready` booleans. It uses the same isolated public transport, 256 KiB body limit and 15-second request bound. It does not retain or display request-level cache details. Cache observations expire after 120 seconds. `NetworkCacheStore` polls only while the Network history panel and dashboard are visible, cancels on disappearance, retains failures as stale, and backs off from 60 seconds to 16 minutes without jitter. Reopening starts a new visible observation loop. These semantics are separate from the older MonitorStore collectors above.

Catalog metadata now includes optional `required_provider_capabilities`, `quantization`, `max_context_length`, and `max_output_length`. Capability strings and counts, quantization, and numeric limits are validated. Missing requirements are unverified; an explicitly empty list means no additional requirements are declared. The app has no supported runtime capability evidence and does not infer `mlx_nax` from a Mac's chip name. Catalog context/output limits describe the catalog, not a promise of this Mac's usable context.

Additional coverage: NetworkMaintenanceTests, NetworkCacheStoreTests, and expanded catalog tests. Historical test totals above describe their dated runs.
