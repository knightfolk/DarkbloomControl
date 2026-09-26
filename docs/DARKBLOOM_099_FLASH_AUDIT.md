# Darkbloom v0.9.9 capability audit vs Darkbloom Control

Audit date: 2026-09-25 (America/Phoenix). Read-only audit; no source, test, or config
files were modified, no model inference was run, no credentials or private telemetry
were inspected, nothing was installed, no processes were restarted, nothing was
committed, and no authenticated endpoint was probed.

Primary author of this file: the Flash audit pass. Final review: Codex.

## 0. Environment verification (stop conditions checked)

| Item | Expected | Verified |
| --- | --- | --- |
| App worktree | `/Users/kevink/.codex/worktrees/darkbloom-fan-gpu/DarkbloomCLIMenuBarMonitor` | yes |
| Branch | `codex/fan-gpu-controls` | yes (`git rev-parse --abbrev-ref HEAD`) |
| Base HEAD | `f9b65d1` ("release: publish v1.6.0 Sparkle feed") | yes (`f9b65d19c257a643f94ec7e4e5a594c4c8cbc809`) |
| Upstream snapshot | `/private/tmp/darkbloom-upstream-20260925` at `b6f9574ed40a5e1f8b8fb288224ea3de88d1be98` | yes; HEAD = "Add bounded App Attest failure diagnostics for v0.9.9 (#1184)" |
| `libs/mlx-swift-lm` submodule | `6f3d171fb7270ba18fb2432ab4f4aab5ed4b6114` | yes (`git submodule status` = `6f3d171…`); `libs/mlx` and `libs/mlx-swift` are present but uninitialized (`-` status) and were not needed |
| Public probe evidence | `/private/tmp/darkbloom-public-probe-20260925.json`, copied by root to `docs/research/darkbloom-099-public-probes.json` | both read |

Live vs source: everything below is **source-verified at the pinned commit** unless
explicitly marked **live-verified (root probe)**. The root probe hit only public,
unauthenticated endpoints (health, readyz, stats, attestation, runtime manifest,
api/version, releases/latest, status page). `api/version` reported **0.9.9**
(live-verified). The coordinator's own fallback floor is also `0.9.9`
([server.go L162](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L162)).
The upstream CLI reference docs remain labeled 0.9.7-era and are stale; this audit
reads source, not docs.

## 1. Coordinator HTTP surface

`routes()` is [server.go L2638–2930](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2638).
A complete machine-checked inventory of all **115 routes** (60 GET, 40 POST,
9 DELETE, 1 PATCH, 5 PUT; 41 under `/v1/admin/`), each with method, path,
registration line, and pinned source URL, is saved at
[docs/research/darkbloom-099-routes.json](research/darkbloom-099-routes.json).

Auth middleware, all in `server.go`:

- `requireAuth`
  ([L3214](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L3214))
  accepts, in order: Privy JWT (token starts `eyJ`), admin key (constant-time
  compare), consumer API key (cached 60 s, L72–74), then **provider device-login
  token** (the CLI's `~/.darkbloom/auth_token`; `store.GetProviderToken`,
  account-scoped, deliberately never cached — L3291–3299).
- `requirePrivyAuth`
  ([L3340](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L3340))
  accepts Privy JWTs only; API keys get 403 "requires an interactive session".
- `rateLimitFinancial` wraps balance-mutating routes; admin handlers authorize
  internally via `requireAdminKey`/`isAdminAuthorized` (admin key **or** Privy
  admin email).

Consequence for Darkbloom Control: routes mounted under `requireAuth` are
*reachable* with the stored provider token (account-scoped identity, no per-key
metadata), but **handlers may impose extra requirements**: `GET /v1/key` returns
404 "no key metadata" unless the caller carries a real consumer API key
([apikey_handlers.go L277–284](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/apikey_handlers.go#L277)),
and `/v1/admin/*` handlers further restrict to admin identity in-handler.
Balance, usage, account-earnings, and inference routes do work with the provider
token.

### 1.1 Public, unauthenticated reads (all live-verified where noted)

| Route | Purpose / evidence | Probe |
| --- | --- | --- |
| `GET /health` | build_commit/build_date/version/status/providers ([L2649](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2649)) | live ✓ |
| `GET /readyz` | `ready`, `inflight`, `draining` drain state ([L2657](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2657), drain.go) | live ✓ |
| `GET /v1/stats` | full platform snapshot incl. providers, models, geography, power, time_series ([L2750](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2750), stats.go) — **1.45 MB in the probe; do not poll frequently** | live ✓ |
| `GET /v1/providers/attestation` | fleet attestation feed, 972 KB ([L2744](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2744)) | live ✓ |
| `GET /v1/runtime/manifest` | accepted runtime/python/template hashes ([L2855](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2855)) | live ✓ |
| `GET /api/version` | latest provider release incl. hashes + changelog ([L2759](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2759)) — reported 0.9.9 | live ✓ |
| `GET /v1/releases/latest` | install.sh feed: version, url, hashes, active ([L2763](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2763)) | live ✓ |
| `GET /v1/models/capacity` | per-model routing pressure: routable/warm/running/cold providers, queue, TTFT estimate, token budget ([L2747](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2747)) | app uses |
| `GET /v1/models/catalog` (+`/manifest/`, `/{id}`) | public model catalog ([L2850–2852](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2850)) | app uses |
| `GET /v1/pricing` | consumer token prices ([L2807](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2807)) | app uses |
| `GET /v1/leaderboard`, `GET /v1/network/totals`, `GET /v1/network/series` | pseudonymized public aggregates ([L2754–2756](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2754)). **`/v1/network/totals?window=24h` timed out in the root probe** — avoid frequent polling | series: app uses |
| `GET /v1/encryption-key`, `GET /v1/cache/status` | sender-encryption pubkey, exact-cache health ([L2711](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2711), [L2652](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2652)) | cache/status: app uses |
| `GET /install.sh` | rendered bootstrap script ([L2641](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2641)) | – |
| `POST /v1/enroll`, `POST /v1/device/code`, `POST /v1/device/token`, `POST /v1/mdm/webhook`, `POST /v1/billing/stripe/*webhook` | unauthenticated by design (MDM/Stripe signature trust, device-flow bootstrap) ([L2740](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2740), [L2766–2767](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2766)) | – |
| `POST /v1/admin/auth/init` / `verify` | admin OTP bootstrap, no auth at init by design ([L2846–2847](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2846)) | admin |

`GET /v1/models/openrouter` ([L2703](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2703))
is **not** public: it sits behind `requireAuth` like the rest of the model
read routes.

### 1.2 Consumer key / provider-token auth (`requireAuth`)

| Route | Semantics / evidence |
| --- | --- |
| `POST /v1/chat/completions`, `POST /v1/responses`, `POST /v1/completions`, `POST /v1/messages` | inference. drainGate → requireAuth → rateLimitConsumer → sealedTransport. `/v1/responses` is the OpenAI **Responses API, active**, same handler auto-detecting input vs messages ([L2697–2700](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2697)). `X-Darkbloom-Route: self|prefer` and per-key `self_route_only` are honored here (§3) |
| `GET /v1/models`, `GET /v1/models/openrouter`, `GET /v1/models/{id…}` | model list/retrieve incl. OpenRouter-shaped feed; self-route-only keys get the alias-aware owned view ([L2701–2706](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2701)) |
| `GET /v1/key` | metadata of the **calling** key (OpenRouter parity). Requires an actual consumer API key: provider tokens have no key ID and get 404 ([apikey_handlers.go L277–284](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/apikey_handlers.go#L277)) |
| `GET /v1/payments/balance` | `{balance_micro_usd, balance_usd, withdrawable_micro_usd, withdrawable_usd}` ([consumer.go L2548](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/consumer.go#L2548)) |
| `GET /v1/payments/usage` | **CONSUMER SPEND — actual settled cost per request** (this account as a *customer*): `{job_id, model (public alias when present), prompt_tokens, completion_tokens, cost_micro_usd, timestamp}`; in-memory ledger first, persisted store fallback ([consumer.go L2565](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/consumer.go#L2565)). Not provider income — keep separate from earnings (stats plan §4) |
| `GET /v1/provider/earnings?wallet=` | legacy wallet-address earnings, no auth ([L2721](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2721)) |
| `GET /v1/provider/account-earnings` | **PROVIDER EARNINGS — account-wide** (all linked Macs): per-payout rows + totals + balances. `handleAccountEarnings` ([billing_handlers.go L684ff](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/billing_handlers.go#L684)): `limit` default **50**, capped **1000**, **no pagination cursor** (single most-recent-N query; `history_limit` echoes the bound), server read-cache **20 s** keyed `account-earnings:{account}:{limit}`. Rows carry provider ID/key, model, tokens, created_at (STAT_ATTRIBUTION_REVIEW §1) |
| `GET /v1/billing/wallet/balance`, stripe session/status/withdrawals | wallet + Stripe read-only status ([L2782–2791](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2782)) |
| Per-key model constraints | `parseInferencePrelude` enforces a per-key model allow-list before alias resolution; keys carry `limit_usd`/`limit_reset`/`rpm_limit`/`itpm_limit`/`otpm_limit`/`allowed_models`/`self_route_only` (PATCH fields in [apikey_handlers.go L333+](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/apikey_handlers.go#L333)) |

Key **management** (list/create/patch/rotate/delete, `/v1/keys*`) is Privy-only by
design — "a leaked inference key can't enumerate or mint keys" ([L2662–2675](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2662)).

### 1.3 Privy-only interactive console surface (`requirePrivyAuth`)

- `GET /v1/me/providers` — the fleet dashboard feed
  ([me_handlers.go L324](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/me_handlers.go#L324)):
  per machine `myProvider` ([L41–161](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/me_handlers.go#L41)):
  status/online/heartbeat, hardware, advertised `models`, version, trust + App
  Attest verdict with `authorization_expires_at`, runtime integrity hashes,
  challenge state, live `system_metrics` (memory pressure/cpu/thermal),
  `backend_capacity` with **per-slot** rows, `idle_unload_mins`, `warm_models`,
  `current_model`, `pending_requests`, `max_concurrency`, `prefill_tps`,
  `decode_tps`, `reputation` (incl. `avg_response_time_ms` = **real TTFT EWMA**,
  [types.ts L91–96](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/providers/types.ts#L91)),
  lifetime requests/tokens.
- `GET /v1/me/summary` — earnings KPIs (lifetime/24h/7d micro-USD + jobs,
  balances, fleet counts) ([me_handlers.go L163](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/me_handlers.go#L163)).
- `GET /v1/me/self-route-models` — alias-aware owned live-model ids for key
  allow-lists ([me_handlers.go L718](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/me_handlers.go#L718)).
- `POST /v1/me/token-promotions/claim`, `DELETE /v1/me/providers/{id}`,
  `POST /v1/device/approve`, all `/v1/keys*` CRUD + rotate, `/v1/auth/keys`,
  Stripe onboard/withdraw/dashboard/unlink/quote ([L2664–2803](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2664)).

Darkbloom Control **cannot** reach §1.3 with the CLI's stored provider token
(`auth_token` is not a Privy JWT, so `requirePrivyAuth` 403s). This is an upstream
security boundary, not a bug; the stats plan stays inside reachable surfaces.

### 1.4 Admin / internal (not app targets)

`/v1/admin/*` (pricing, users, model registry + aliases + openrouter-aliases,
releases, app-attest builds/revoke, state-export, metrics, base-rewards,
utilization, drain, routes/profiles/snapshots/rejections + exports, invite-codes,
credit/reward, log-reports), `POST /v1/releases` (scoped release key),
`POST /v1/telemetry/events` (410-retained legacy), `POST /v1/provider/log-report`
([L2813–2923](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2813)).

### 1.5 Absent / unimplemented (do not mistake for APIs)

- The routes() comment at
  [L2691–2696](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go#L2691)
  names `/v1/audio/transcriptions`, `/v1/images/generations`, `/v1/embeddings` as
  **future** examples; they are not registered. The `/v1/` catch-all returns a
  structured 404 "not implemented" (L2925–2929, L3062+).
- The **local** MLX server does expose `/v1/embeddings` routes but they return 501
  `embeddings_not_configured` unless an embedding model is configured
  ([MLXServerApplication.swift L207–229](https://github.com/Layr-Labs/mlx-swift-lm/blob/6f3d171fb7270ba18fb2432ab4f4aab5ed4b6114/Libraries/MLXLMServer/HTTP/MLXServerApplication.swift#L207)).
  No audio or image-generation routes exist locally at all.
- No coordinator route lists or manipulates a provider's resident models. Model
  control is coordinator-internal only (§4).

## 2. Local inference surface (provider-swift, 0.9.9)

Two serve modes share one HTTP stack
([LocalInferenceHTTP.swift L1–14](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift#L1)):

- `darkbloom start --local` — standalone local-only server (own slot cache).
- `darkbloom start --local-endpoint` — **unified**: one set of loaded models serves
  the public fleet and local clients together
  ([ProviderLoop+LocalEndpoint.swift L1–27](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift#L1)).

Responder stack (LocalInferenceHTTP.swift:35–44, 106–126): disconnect tracking →
bearer auth (`--no-auth` disables) → CORS (`*`) → `LocalMetricsResponder`
(GET /metrics) → 32 MiB chat-upload ceiling → upstream MLX router. Default bind
`127.0.0.1:8000`; `--bind-host` may expose to a tailnet ("still API-key gated",
StartCommand.swift:44).

### 2.1 Routes (pinned mlx-swift-lm `HTTP/MLXServerApplication.swift`)

- `GET /health`, `/v1/health` (L44–48), `GET /props` (L50), `GET /metrics` (L53),
  `GET /models`, `/v1/models` (L56–60)
- `POST /v1/chat/completions` (+`/chat/completions`, `.../batch`) (L106–108);
  `POST /v1/completions` variants (L142–144)
- `POST /v1/responses` (+`/responses`) create, `GET /v1/responses/:id`,
  `POST /v1/responses/:id/cancel` (L165–171) — **Responses API is real locally**,
  with an in-memory response store (LocalInferenceHTTP.swift:81)
- Token utilities: `POST /tokenize`, `/detokenize`, `/apply-template` (L181–192) —
  tokenizer resolved from an **already-resident slot only**
  ([ProviderLoop+LocalEndpoint.swift L168–181](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift#L168):
  `resolveTokenizerForLocal` throws `noModelLoadedForTokenization` when nothing is
  loaded and takes **no reservation**). Token utilities therefore cannot warm a model.
- `POST /v1/embeddings` variants — 501 unless configured (§1.5).

### 2.2 `GET /metrics` — provider-owned MTP + posture
([LocalMetricsResponder.swift](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Server/LocalMetricsResponder.swift))

`/metrics` = upstream `ServerMetrics.prometheusText()` body + per-resident-slot MTP
block (L153–164): `mtp_enabled` / `mtp_active` (gauges), `mtp_rounds_total` /
`mtp_tokens_proposed_total` / `mtp_tokens_accepted_total` (cumulative **per slot
lifetime** — a slot reload resets them, so scrapers must detect resets before
differencing), `mtp_inactive_reason{reason=…}` present only when MTP is not
productively running (L72–94), plus slot-posture lines. Samples come from the live
engine bridges
([ProviderLoop+LocalEndpoint.swift L192–203](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift#L192)).
The daemon-state file carries the same posture trio per slot
([DaemonStateFile.swift L54–65](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift#L54))
but **no counters**; Darkbloom Control parses the file today
(Sources/DarkbloomTelemetry/StateParsers.swift:260–300) and does not poll local
HTTP `/metrics` at all.

### 2.3 Discovery: `~/.darkbloom/local.json`

- `LocalEndpoint.Info` = `base_url`, `api_key` (`dk-local-…` or empty for
  `--no-auth`), `host`, `port`, `pid`, `version`, `updated_at`; written 0600
  atomically after **confirmed socket bind**
  ([Server/LocalEndpoint.swift L63–140](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift#L63)).
- Unified mode writes the same record **only from the authoritative bind callback**
  (`onServerRunning`), so a port collision never advertises a foreign process
  ([ProviderLoop+LocalEndpoint.swift L51–90](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift#L51));
  `stopLocalEndpoint` removes it (L93–98).
- `readLiveInfo()` treats a dead pid as "not running" (L122–134);
  `darkbloom local [--json]` prints the record
  ([LocalCommand.swift](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/darkbloom/LocalCommand.swift)).

### 2.4 Daemon-state and model surfaces

- Daemon-state JSON
  ([DaemonStateFile.swift L17–120](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift#L17)):
  schema, pid + kernel process identity, version, trust + reason, coordinator URL,
  `current_model`, `warm_models`, `advertised_models`, lifecycle/drain,
  `inference_active`, stats (requests/tokens), system (memory pressure, cpu,
  thermal), capacity (total / gpu active / gpu cache), `last_model_load_error`,
  per-slot `slots[]` (kv backend + MTP posture incl. failed-load synthetic entry),
  connectivity. Written periodically and refreshed during startup preload.
- Loaded-model persistence: `LoadedModelsStore` records the resident set after
  every load/unload (excluding shutdown); that file is the **default startup
  preload plan** (ProviderLoop+StartupPreload.swift:87–146).

## 3. Exclusive self-route
([self_route.go](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/self_route.go))

- Opt-in: `X-Darkbloom-Route: self` (exclusive) or `prefer` (owned-first with paid
  fallback), or a per-key `self_route_only` hard ceiling (L39–67). Body fields
  never influence it (L22–23).
- Exclusive = owned-only, **free**, **never falls back** to the paid fleet;
  `prefer` takes a normal reservation and settles charged only if a public machine
  served it (L24–37).
- Owner = authenticated consumer identity = `Provider.AccountID` namespace (L47–50).
  **Self does not pin this Mac**:
  [OwnedProviderSummary](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/scheduler.go#L1422)
  scans *all* providers whose `AccountID` matches — any owned machine may serve.
- Preflight error taxonomy (L80–127): no linked machine → 409 `no_linked_machine`;
  linked but offline → 503 `machine_offline` (Retry-After 30); online but
  shape-unsupported → 503 `model_capability_unsupported`; online but the model is
  not advertised → 503 `model_not_loaded` (Retry-After 15). "Serves" means
  **advertised + eligible**
  (owner rules relax only trust floor and `private_only`,
  [scheduler.go L1566–1573](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/scheduler.go#L1566);
  [model_catalog.go L172–184](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/model_catalog.go#L172)),
  **not resident/warm**.
- `private_only` providers ([ProviderConfig.swift L426–445](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift#L426))
  are excluded from public routing (GatePrivateOnly) but admitted for their owner —
  self-route is the supported way to use a private_only node.
- Aliases: `ResolveModelConstrained` resolves request names per-key/owner/self-route
  context, so an alias can resolve to different concrete builds for owner vs public
  traffic ([model_aliases.go L123–260](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/model_aliases.go#L123)).

## 4. Warming, cold load, eviction — what actually exists in 0.9.9

| Mechanism | Trigger | Operator-invokable? | Evidence |
| --- | --- | --- | --- |
| Lazy load on inference | first request (public or local) → `ensureModelLoaded` (default `allowEviction: true`) | indirect only | [ModelLoading.swift L183–320](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BModelLoading.swift#L183); [ProviderLoop+LocalEndpoint.swift L105–152](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift#L105) |
| Startup preload | daemon start: `startup_preload` (default on), `preload_models` list or persisted resident set, `startup_preload_timeout_secs` (120 s), optional self-test | **config-only, at startup** | [ProviderConfig.swift L200–333](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift#L200); StartupPreload.swift:1–233 |
| No-eviction load | `allowEviction: false` variant used by startup preload so a later candidate never evicts an earlier one | **internal only** — no HTTP/CLI surface | ModelLoading.swift:185–192, 299–310; StartupPreload.swift:271–278 |
| Coordinator `desired_models` | coordinator pushes desired builds; provider **prefetches to disk** (never loads weights, "never consumes a GPU slot") and then advertises | no (coordinator policy) | server.go:164–170; [Prefetch.swift L28–46](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BPrefetch.swift#L28) |
| Cold dispatch / `load_model` | requests **queued** with no warm provider → coordinator sends `load_model` to a cold on-disk provider; kicks on every enqueue | no (coordinator-internal, demand-driven) | [cold_dispatch.go](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/cold_dispatch.go); [registry/model_loading.go](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/model_loading.go) |
| Warm-pool telemetry | `warm_pool_tick` telemetry events | telemetry-only | [warm_pool_telemetry.go](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/warm_pool_telemetry.go) |
| Token utilities | tokenizer from resident slot | **cannot warm** | §2.1 |

**Conclusion: v0.9.9 exposes no operator runtime warm endpoint and no no-eviction
pin.** The only no-evict path is the internal startup preload; the only runtime
load triggers are an actual inference request or the coordinator's own
queued-demand planner. This independently confirms
`docs/DEMAND_PRELOADING_FINDINGS.md`, whose claims were re-verified from source.
The superseded spec
`docs/superpowers/specs/2026-09-03-live-model-warming-design.md` (Status:
SUPERSEDED, lines 3–8) described a rejected custom provider branch with private
`/v1/provider/model-control/load` endpoints; it is historical only and must not be
revived.

## 5. Fan control (official helper, source-verified)

- CLI: `darkbloom fan status|diagnose|enable|configure|disable|uninstall`
  (+ hidden DEBUG `test-lease`) —
  [FanCommand.swift L8–32](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/darkbloom/Fan/FanCommand.swift#L8).
  `enable` takes `--speed` (60–90, default 80) and `--temperature` (default 45 °C);
  release = trigger − 5 °C (L193–213, 294–300).
- Hard policy bounds: speed must be within **60…90** percent —
  [FanPolicy.swift L4–5, L52–56](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift#L4).
  Exactly **one** trigger/release pair with debounce: engage after 3 consecutive
  hot samples ≥ trigger; release after 30 consecutive samples ≤ release; forced
  restore to automatic on provider-lease loss, control failure, or bad sensors
  (L171–256). No 100 %, no curves — by upstream design.
- Service: root LaunchDaemon `/Library/LaunchDaemons/io.darkbloom.fan.plist`,
  mach service `io.darkbloom.fan` (FanServiceConfiguration.swift:97;
  FanLaunchDaemon.swift:4–10). Team ID `SLDQ2GJ6TL`; XPC peer requirement =
  `anchor apple generic and identifier … and certificate leaf[subject.OU]`
  (ad-hoc local builds fall back to identifier-only validation)
  ([FanPeerAuthentication.swift L59–85](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/DarkbloomFanService/FanPeerAuthentication.swift#L59)).
- UID pinning: root euid always allowed; non-root must match the installing UID
  **and** that account's DirectoryService GeneratedUID (FanUserIdentity.swift:24–81;
  FanPeerAuthentication.swift:14–31).
- Lease: single `providerLease` (session UUID, **15 s** expiry, renewed) —
  [FanIPC.swift L10](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift#L10);
  FanDaemon.swift:33, 112. Release, XPC session end, shutdown, and system sleep all
  **restore macOS automatic control** and clear stale leases (FanDaemon.swift:116–231).
- Darkbloom Control today is **read-only** for fans: it runs
  `darkbloom fan status --json` (Sources/DarkbloomTelemetry/ProviderExtrasClient.swift:25)
  and renders telemetry (Sources/DarkbloomMonitor/ProviderExtrasViews.swift).

**100 % / custom curves are a legitimate user request the official helper cannot
serve.** Honest options, without implementation in this branch:

1. *Stay official (current stance):* the app shows read-only fan/thermal telemetry
   and points users to `sudo darkbloom fan enable/configure` for the capped,
   signed-helper policy. Zero new attack surface.
2. *Separate custom controller:* supporting 100 % or curves requires a **new,
   separately-shipped privileged helper** with the same hardening class the
   official one demonstrates — launchd root daemon, code-signing/team-ID anchor
   requirement, UID+GeneratedUID pinning, short leases, guaranteed restoration to
   automatic on every exit path — plus its own SMC write path and safety review.
   This is a standalone product decision with real risk (SMC writes, thermal
   safety); it must not be embedded in Darkbloom Control's existing process
   context or bolted onto the official helper.

## 6. CLI command tree (official `darkbloom`, source-verified)

Root: [Darkbloom.swift L24–52](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/darkbloom/Darkbloom.swift#L24)
— `start, stop, restart, status, doctor, models, local, login, logout, benchmark,
update, verify, enroll, unenroll, logs, report, autoupdate, beta, idle, fan` are
public (**20** commands); `watchdog`
([WatchdogCommand.swift L12](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/darkbloom/WatchdogCommand.swift#L12))
and `runtime-smoke`
([RuntimeSmokeCommand.swift L11](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/darkbloom/RuntimeSmokeCommand.swift#L11))
are hidden (`shouldDisplay: false`) → **20 public + 2 hidden**.

Notable flags: `start` (StartCommand.swift:17–47): `--model` (repeatable),
`--all-models`, `--idle-minutes` (0 = keep loaded; saved to config), `--local`,
`--local-endpoint` (unified), `--port`, `--bind-host`, `--no-auth`, coordinator
URL override, drain options, TUI picker. `status` is **text-only (no `--json`)**;
`doctor` (diagnostics incl. last model-load error, trust, serving-set floor),
`verify` (install + coordinator trust state), `models
list|catalog|download|remove`, `idle status|keep-loaded|unload-after`, `beta
list|enable|disable`, `autoupdate status|…`, `update --check-only`, `local
--json`, `fan status --json`.

The app's command constructors use plain `status` (optionally `--config`),
`models catalog --config … --json`, `models list --config … --json --all`,
`models download --config … <id>`, `models remove <id> --force`,
`start --config …` with repeated `--model` and hosting flags, `local --json`,
`stop --timeout …`, and `restart --config …`
(`Sources/DarkbloomTelemetry/SourcePolicy.swift`). Extras use
`idle status --json --config …`, `beta list --json`, `fan status --json`,
`autoupdate status`, plus explicit idle/beta mutations
(`ProviderExtrasClient.swift`). Update checking uses `update --check-only --config …`
(`CLIUpdateStatus.swift`). Daemon-state JSON is a separate local-file source;
there is no `status --json` invocation. Model removal, startup loading selection,
and starting the provider are already supported app surfaces.

## 7. App coverage map (Darkbloom Control @ f9b65d1)

| Official capability | App support | Evidence |
| --- | --- | --- |
| Public catalog/pricing/capacity/cache-status/network-series | yes, with polling/backoff/validation contract | docs/PUBLIC_API_CONTRACT.md; PublicCatalog/PublicPricing/NetworkCapacity/NetworkSeries.swift |
| `/v1/leaderboard` | yes | Sources/DarkbloomTelemetry/AccountLeaderboard.swift:5 |
| `/v1/payments/balance` | yes | Sources/DarkbloomTelemetry/ConsumerBalance.swift:82 |
| `/v1/payments/usage` (consumer spend, actual per-request costs) | **no** — not called anywhere | grep over Sources |
| `/v1/provider/account-earnings` (provider token) | yes | Sources/DarkbloomTelemetry/AuthenticatedEarningsClient.swift:14, 126 |
| `/v1/key` (needs a real consumer API key) | **no** | grep; auth caveat §1.2 |
| `/v1/me/providers`, `/v1/me/summary` (Privy-only) | **no** (blocked by auth class, §1.3) | – |
| Self-route headers / per-key constraints | **no** consumer-side support in chat client | Sources/DarkbloomTelemetry/ChatClients.swift |
| Local unified chat (local.json discovery) | **partial + stale assumption**: unified mode ignores discovery and prefers saved Hosting settings; comment claims "unified mode has no discovery record" | Sources/DarkbloomMonitor/ChatLocalEndpointProvider.swift:9–11, 43–56; **superseded by 0.9.9**: local.json is written on confirmed bind (§2.3) |
| Standalone discovery | yes, via `darkbloom local --json` subprocess | Sources/DarkbloomTelemetry/LocalEndpoint.swift:297–350 |
| Daemon-state MTP/KV slot posture | yes (file parse) | Sources/DarkbloomTelemetry/StateParsers.swift:4–300 |
| Local HTTP `/metrics` Prometheus (counters) | **no** (unused; daemon-state carries posture only) | §2.2 |
| `models download` / `models remove` / driving `start` | yes | SourcePolicy.swift:94–108; HostingSettingsStore.swift:228 |
| `preload_models` editing ("Load at startup") | yes | Sources/DarkbloomTelemetry/ProviderConfigDocument.swift:44, 314; Sources/DarkbloomMonitor/ModelManagerView.swift:1747 |
| `startup_preload` master switch / `startup_preload_timeout_secs` | **no** app surface (config keys not read/written by the app) | grep ProviderConfigDocument.swift |
| Fan telemetry | read-only status | ProviderExtrasClient.swift:25; ProviderExtrasViews.swift |
| Fan mutation (enable/configure) | **none** (official CLI + sudo only; §5 for the separate-controller option) | §5 |

### Verified gaps, prioritized (useful features first, not admin-route exposure)

1. **P0 — live unified-endpoint discovery.** Prefer reading
   `~/.darkbloom/local.json` via `readLiveInfo` semantics (pid-liveness +
   `version` field) ahead of saved Hosting settings in unified mode, falling back
   to saved settings for pre-0.9.9 daemons (version-aware fallback; 0600 files
   keep the token local). Removes the stale "unified lacks discovery" claim at
   Sources/DarkbloomMonitor/ChatLocalEndpointProvider.swift:9–11.
2. **P0 — `/v1/payments/usage` actual-cost history** (consumer spend; provider
   token works; §1.2): per-request settled micro-USD + tokens + model + timestamp
   is the best raw feed for honest spend tracking; keep it a separate series from
   provider earnings (stats plan §4).
3. **P1 — `startup_preload` master/timeout awareness** (read-only display, or
   edit alongside the existing `preload_models` transaction): the honest
   alternative to the rejected custom warm endpoints (§4, §8).
4. **P1 — `/v1/key` surface, gated on having a consumer API key**: show spend
   cap/limits/reset; hide the surface entirely when only a provider token exists
   (it 404s).
5. **P2 — optional local `/metrics` scrape** for cumulative MTP counters with
   slot-lifetime reset detection (daemon-state gives posture but not counters;
   stats plan §5 Phase 2).
6. **Not recommended**: mirroring admin routes, per-model GPU attribution (GPU is
   whole-Mac; no per-model attribution exists anywhere in the stack), or shelling
   out to `sudo` fan mutations from the app (§5 covers the separate-controller
   prerequisite if 100 %/curves are wanted).

## 8. Feasibility: can exclusive self-route proactively cold-load a model?

Question: with high demand, can the app proactively warm a cold (advertised but
not resident) model via an exclusive self-route inference?

**Answer: yes, request-triggered cold load works in source — as an ordinary
self-route request, not a preload primitive.** Chain, all source-verified:

1. Self-route preflight passes when an owned, online machine **advertises** the
   model (advertised + catalog/owner + traits + liveness), regardless of residency
   (self_route.go:80–127; model_catalog.go:172–184). If no owned machine advertises
   it, preflight fails fast 503 `model_not_loaded` — self-route cannot make the
   coordinator prefetch or force a config change; the build must already be in the
   node's advertised set (config/`--model`, `--all-models`, or a coordinator
   `desired_models` disk prefetch).
2. Dispatch may select the owned machine while it is cold; the provider's inference
   path runs `ensureModelLoaded` inside the request (ModelLoading.swift:197+), so
   the request pays the cold load and is billed **free** under exclusive self-route
   (no fleet fallback, self_route.go:24–37).
3. Because "self" scopes by account ownership, the load may happen on **any** owned
   Mac, not necessarily this one. Multiple owned machines make targeting ambiguous;
   `prefer` additionally permits paid fallback (unsuitable for no-charge warming).
4. No residency guarantee: nothing pins the slot afterward — idle-unload policy
   (`idle_unload_mins`, `--idle-minutes`), later slot-cap LRU eviction
   (ModelLoading.swift:298–320), memory admission (`evictUntilAvailable`), and
   coordinator swap decisions can all unload it. Demand-side protection is
   coordinator-owned: if demand is real, requests queue and the coordinator itself
   pushes `load_model` / keeps it warm (cold_dispatch.go; model_loading.go).

**Targeting this Mac specifically:** a tiny ordinary completion against the
**unified local endpoint** (`start --local-endpoint`) takes `acquireModelForLocal`
→ the same `ensureModelLoaded` gate (ProviderLoop+LocalEndpoint.swift:105–152), so
local request-triggered load is Mac-precise and free of coordinator ambiguity — but
it is still an inference, still eviction-capable, and (in unified mode) it consumes
the same slots the fleet sees. Standalone `--local` mode has its own slot cache and
would not warm the network-serving process.

**Official no-eviction/warm endpoints: none** (§4 table). `allowEviction: false` is
internal to startup preload; token utilities cannot load; `/metrics` and
daemon-state are read-only. Any "guaranteed warm" promise would require an upstream
capability (the superseded spec's rejected private endpoints are not an option).

**Risks of an app-driven warm action:**

- *Electricity/cost:* load is real GPU work with real power draw; exclusive
  self-route avoids credit spend but not energy. Revenue is not guaranteed —
  demand may vanish before the model earns its load cost.
- *Slot churn:* with `max_model_slots` full, the load **evicts** the LRU resident
  (default path), which can drop an already-earning model. A free-slot/memory
  preflight in the app is **advisory only** — the provider takes its local
  reservation inside `acquireModelForLocal`, so an app-side check cannot be atomic
  and "never evict-to-warm" remains **best-effort until upstream exposes a
  no-eviction load capability**.
- *Ambiguity:* self-route may warm a different Mac than the one the user is
  looking at; per-Mac precision requires the unified local route.
- *Reconciliation:* an aborted request may still have completed the load
  (load-then-cancel); UI state must re-derive residency from daemon-state rather
  than from the HTTP outcome.

**Recommended opt-in policy (no implementation in this audit):** default-off;
explicit user action labeled "small inference request"; require fresh
capacity/demand evidence sustained across samples; serialize with provider
operations (no action during drain, unapplied settings, or active loads); prefer
the unified local route for Mac-precise warming; gate on free slot + memory
headroom **as a best-effort filter, documented as such**; bounded tokens/time;
cooldown; activity log; reconcile residency afterward; and request an upstream
atomic no-eviction load capability before ever promising spare-slot-only
automation. This matches and independently re-derives
`docs/DEMAND_PRELOADING_FINDINGS.md`.

## 9. Official console-ui (provider web UI) — stat surfaces worth mirroring

Snapshot `console-ui/src` (Next.js, Privy session). Key patterns:

- [providers/types.ts](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/providers/types.ts) —
  full `/v1/me/providers` + `/v1/me/summary` wire contract, incl. per-slot
  `observed_prefill_tps`, `model_load_time_ms`, `kv_backend` + inverted-absence
  `kv_backend_fallback_reason`, prefix/paged storage telemetry; reputation
  `avg_response_time_ms` documented as **real TTFT** (L33–34, 85–96).
- [useFleetData.ts](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/providers/dashboard/useFleetData.ts) —
  polls `/api/me/providers` + `/api/me/summary` every **15 s visible-only**
  (L12, 117–141), providers required / summary best-effort, prior-data retention
  on poll failure.
- `CardVitals.tsx` — thermal pips, memory pressure, CPU, concurrency dots,
  decode/prefill tok/s, GPU-memory stacked bar; honest "no live metrics" empty
  states for offline machines (L42–48).
- `CardEarningsRow.tsx` — per-machine reputation, lifetime tokens/requests, TTFT;
  explicitly keeps **account-wide earnings off machine cards** (L1–4).
- `FleetHealthStrip.tsx` — worst-state fleet verdict + money KPIs (lifetime, 24 h,
  7 d, withdrawable, "earning now") (L70–97).
- `earnings/EarningsContent.tsx` — `/api/me/earnings?limit=100` (proxy to
  `/v1/provider/account-earnings`), 30 s visible polling, per-payout table
  (model, amount, tokens in/out, time) (L74–98, 240–266).
- `api/me/*` route.ts — same-origin server proxies forwarding the Privy
  Authorization header to the coordinator.
- [useNetworkStats.ts](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/stats/useNetworkStats.ts) —
  30 s visible polling of a server-cached `/api/stats` snapshot
  (X-Stats-Cache / X-Stats-Snapshot-At / X-Stats-Fetched-At provenance headers),
  with catalog/capacity/`network/totals` as **best-effort secondaries that become
  "unknown", never "stale-current"** (L81–94). Even the official console treats
  `/v1/stats` (1.45 MB) and `network/totals` (probe: timed out) as heavy,
  cache-fronted sources.

Auth distinction (source + console behavior): `/v1/me/providers` and
`/v1/me/summary` are **Privy-only**; `/v1/provider/account-earnings` works with a
consumer key or provider token (console falls back to API key,
EarningsContent.tsx:58–66; coordinator route server.go:2723 uses `requireAuth`).
A signed-out /providers page shows login only; this audit made no authenticated
call and borrowed no cookies/tokens.

## 10. Pinned primary sources (primary set; §1–§9 inline links are the same pins)

- Coordinator routes/middleware: [server.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/server.go)
- Self-route: [self_route.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/self_route.go)
- Cold dispatch: [cold_dispatch.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/cold_dispatch.go) · [registry/model_loading.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/model_loading.go)
- Consumer money: [consumer.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/consumer.go) · [apikey_handlers.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/apikey_handlers.go) · [billing_handlers.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/billing_handlers.go)
- Fleet (Privy): [me_handlers.go @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/me_handlers.go)
- Local endpoint: [ProviderLoop+LocalEndpoint.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift) · [Server/LocalEndpoint.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift) · [LocalInferenceHTTP.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift)
- Model loading/preload: [ProviderLoop+ModelLoading.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BModelLoading.swift) · [ProviderLoop+StartupPreload.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BStartupPreload.swift)
- MLX router: [MLXServerApplication.swift @ 6f3d171](https://github.com/Layr-Labs/mlx-swift-lm/blob/6f3d171fb7270ba18fb2432ab4f4aab5ed4b6114/Libraries/MLXLMServer/HTTP/MLXServerApplication.swift)
- Fan: [FanCommand.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/darkbloom/Fan/FanCommand.swift) · [FanPolicy.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift) · [FanPeerAuthentication.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/DarkbloomFanService/FanPeerAuthentication.swift) · [FanIPC.swift @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift)
- Console-ui: [providers/types.ts @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/providers/types.ts) · [useFleetData.ts @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/providers/dashboard/useFleetData.ts) · [useNetworkStats.ts @ b6f9574](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/console-ui/src/app/stats/useNetworkStats.ts)
- Local research artifacts: [darkbloom-099-routes.json](research/darkbloom-099-routes.json) · [darkbloom-099-public-probes.json](research/darkbloom-099-public-probes.json) · [STAT_ATTRIBUTION_REVIEW.md](research/STAT_ATTRIBUTION_REVIEW.md)

## 11. Companion document

Concrete phased telemetry/history/chart work (provenance taxonomy, units, epochs,
dedup, retention, tests) lives in
[PROVIDER_STATS_AND_CHARTS_PLAN.md](PROVIDER_STATS_AND_CHARTS_PLAN.md).
