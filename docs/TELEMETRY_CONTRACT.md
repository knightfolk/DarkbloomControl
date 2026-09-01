# Darkbloom 0.8.15 Local Telemetry Contract

Inventory captured locally on 2026-08-31 and revalidated against a fresh,
read-only Darkbloom 0.8.15 run the same day. The live schema remained 1 and the
field inventory below did not change. No credential file was opened and no
network diagnostic was invoked.

## `~/.darkbloom/daemon-state.json` (schema 1)

| Normalized field | Observed source field | Availability |
|---|---|---|
| Version | `version` | Direct |
| Current model | `current_model` | Direct |
| Warm models | `warm_models[]` | Direct |
| Slots | `slots[]` | Direct |
| MTP enabled | `slots[].mtp_enabled` | Direct |
| MTP active | `slots[].mtp_active` | Direct |
| MTP reason | No field observed | Explicitly unavailable; may be recoverable only from a future log message |
| KV backend | `slots[].kv_backend` | Direct |
| Requested KV backend | `slots[].kv_backend_requested` | Direct |
| Total memory | `capacity.total_memory_gb` | Direct |
| Active GPU memory | `capacity.gpu_memory_active_gb` | Direct |
| GPU cache memory | `capacity.gpu_memory_cache_gb` | Direct |
| Process ID | `pid`, corroborated by `process_identity.pid` | Direct |
| Process start identity | `process_identity.start_time_micros` | Direct |
| Start time | `started_at` | Direct |
| Uptime | `now - started_at` | Derived |
| Trust level/status/reason | `trust.trust_level`, `status`, `reason` | Direct |
| Trust receipt time | `trust.received_at` | Direct |
| Requests served | `stats.requests_served` | Direct cumulative counter |
| Tokens generated | `stats.tokens_generated` | Direct cumulative counter |
| Usage gaps | `stats.usage_gaps` | Direct cumulative counter |
| Inference active | `inference_active` | Direct |
| Snapshot age | `now - written_at` | Derived |
| Tokens/second | positive token delta / positive `written_at` delta for same process identity | Derived; unavailable before two valid samples or without token progress |

The observed file also contains `attestation_public_key`. It is deliberately
excluded from the normalized model because the monitor has no user-facing need
for attestation material.

## `~/.darkbloom/loaded-models.json` (schema 1)

`models[]` and `updated_at` are direct. “Loaded” and “warm” are retained as
separate concepts because the files expose them separately. The revalidation
confirmed that both lists can report the same model while remaining distinct
source fields.

## `darkbloom status`

Observed direct text fields, revalidated in the live 0.8.15 output: CLI version,
provider name, config path,
coordinator URL, backend port, configured model selection, idle timeout, beta
feature states, watchdog/auto-restart posture, hardware summary, inference
memory allowance, local boot checks, schedule, enabled model filter, local MLX
model count, daemon running/PID/uptime, trust/status/reason, warm models, most
recently used model, requests/tokens, state age, and per-slot KV/MTP posture.

The monitor may execute only `darkbloom status`. It will not execute `verify`,
`doctor`, `models catalog`, `update`, or other commands that can contact a
coordinator or mutate state. It will never execute `darkbloom local` because
that command prints an API key.

## Logs

The legacy `provider.log` currently exposes timestamp, severity, logger, and
message. The observed file is dominated by weight-hash lifecycle messages. The
unified log exposes timestamp, severity (`messageType`), category, process ID,
and image path, but messages were privacy-redacted as `<private>` in the
current session. The monitor can surface these real fields and must label the
message unavailable when redacted.

The live revalidation did not reveal a structured MTP-reason field or any
request-level timing/input-token fields. Those remain explicit gaps rather than
being inferred from slot booleans, log prose, or cumulative counters.

Recent events are normalized only when their source is lifecycle, warning, or
error/fault. Log input is bounded by bytes and retained event count.

## Explicit gaps

- Per-request start/end timestamps and per-request token counts were not
  observed, so exact request-level throughput and latency are unavailable.
- Prompt/input token counts were not observed.
- MTP inactive/disable reason was not present in schema 1 state. Absence is
  displayed as unavailable rather than inferred from `mtp_active`.
- CPU usage, process RSS, temperatures, power, and network throughput were not
  exposed by the inventoried Darkbloom sources. System-wide probes are outside
  the requested contract.
- Cumulative-counter tokens/second is a polling-window estimate, not an engine
  benchmark or instantaneous generation rate.

## Account earnings extension

The monitor additionally uses the fixed authenticated
`GET /v1/provider/account-earnings?limit=1000` response for lifetime earnings,
available balance, withdrawable balance, and recent per-job earning metadata.
Darkbloom caps this history at 1,000 records, so it is not automatically a full
24-hour window for a busy account. The monitor uses the server-computed public
`GET /v1/leaderboard?metric=earnings&window=24h&limit=200` row after deriving the
account's official pseudonym; if no row matches, the 24-hour value remains
unavailable rather than undercounted.

New earnings from overlapping ten-minute polls are reduced using a single
persisted earning-ID high-water mark. Inference work is stored in per-model
hourly aggregates. Entries with Darkbloom's `base_reward` model marker are
stored in a separate hourly rewards table and never increment work job or token
totals. Changed balances are stored at most once per hour; unchanged polls write
no history. Raw per-job rows, account IDs, provider keys, tokens, prompts, and
responses are not persisted. The menu's rolling 24-hour figure remains total
earnings, including work and all rewards.
