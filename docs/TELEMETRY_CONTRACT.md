# Darkbloom 0.8.15 Local Telemetry Contract

Inventory captured locally on 2026-08-31 and revalidated against a fresh,
read-only Darkbloom 0.8.15 run the same day. The stock telemetry schema remained
1 and the field inventory below did not change. This contract describes the
official CLI and its published local telemetry only. Private provider-control
routes, custom CLI branches, and unsigned provider builds are outside the
supported application boundary and are not required for any feature described
here. No credential value is reproduced here, and no network diagnostic was
invoked.

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
source fields. `updated_at` records the last residency change, not a heartbeat;
a successful read supplies freshness. The mutation timestamp must still be
finite, not future-dated, and no older than the current daemon's `started_at`.

## `darkbloom status`

Observed direct text fields, revalidated in the live 0.8.15 output: CLI version,
provider name, config path,
coordinator URL, backend port, configured model selection, idle timeout, beta
feature states, watchdog/auto-restart posture, hardware summary, inference
memory allowance, local boot checks, schedule, enabled model filter, local MLX
model count, daemon running/PID/uptime, trust/status/reason, warm models, most
recently used model, requests/tokens, state age, and per-slot KV/MTP posture.

The monitor's CLI provider-control surface is limited to the official
`status`, `models catalog`, `models list`, `models download`, `models remove`,
`start`, `stop`, and `restart` commands. It uses the fixed
`~/.config/darkbloom/provider.toml`, and config saves may alter only top-level
`enabled_models`, `preload_models`, and `max_model_slots`. A save uses a
UUID-named candidate beside that file and maintains one fixed backup; it reports
restart-required rather than restarting automatically. App-managed Start and
Restart pass every exact saved enabled model using the official CLI's repeated
`--model` arguments when supported by the installed release, so the interactive
picker is not required.

The official CLI has no supported monitor-side operator API for loading,
retiring, or switching a resident model. Therefore live model switching,
automatic demand-based switching, and load-first/two-slot staging are not part
of this contract. A one- or two-model `max_model_slots` setting remains an
official provider configuration choice, applied through the normal save and
restart/start path; the second slot is not a monitor-controlled staging slot.
Public capacity demand remains a read-only network signal and never authorizes
a local residency mutation.

## Public model-capacity extension

The monitor separately polls
`GET https://api.darkbloom.dev/v1/models/capacity` every 30 seconds. Each model row
may expose readiness, acceptance, routable/warm/running/cold provider counts,
active and queued request counts, queue limit, aggregate tokens/second,
estimated TTFT, and token-budget fields. Demand bands are derived from queued
work and active requests per warm provider: queued work or active work with no
warm provider is urgent; otherwise pressure of at least 1, 0.5, or 0.1 is
urgent, high, or moderate, and lower pressure is low.

The last successful sample may remain visible as stale, but it is actionable
only for 120 seconds and with no more than five seconds of future skew. An
older overlapping response cannot replace a newer accepted sample. Rows are
filtered to enabled local models. These are aggregate network-demand signals,
not provider earnings, local job progress, or per-request throughput.

## Official CLI model and slot boundary

The saved `max_model_slots` value is an official provider configuration choice
and selects the provider's one- or two-model capacity after the normal
configuration and restart/start path applies it. The second slot is not a
monitor-reserved staging slot. The monitor does not load a target first, retire
an idle resident, evict a model, or otherwise mutate residency through a private
API. A model switch that requires a different resident model must use the
official CLI/provider lifecycle supported by the installed release.

Consequently, the monitor does not expose manual Warm, automatic demand-based
switching, load-first staging, or live resident switching. Network demand stays
available as read-only context for the user, but it is never treated as
permission to change local model state. Current resident/active/idle state is
reported only from fresh official telemetry and official CLI results.

Config publication uses revision checks, bounded advisory locks, and atomic
replacement. The locks coordinate only cooperating writers that reopen and
revalidate the path; a noncooperating writer that retains an open descriptor is
outside that guarantee. Detected external changes reject the save. When recovery
cannot establish a safe outcome, the store preserves visible versions and
reports the bounded recovery failure instead of claiming a completed save.

All other config fields, credentials, account commands, launchd internals, and
direct cache operations remain forbidden. The monitor does not execute
`darkbloom local`, `verify`, `doctor`, or update commands. It never runs a
shell to construct provider commands.

Downloaded, enabled, preloaded, resident, active, and network-demand states are
independent. Download or Delete does not implicitly enable, disable, or
preload a model. Stop and Restart can affect customer work: activity is checked,
but an unavailable or stale observation is possible and is not treated as safe.
Active or unknown activity requires an explicit user override before either
lifecycle command is issued; that confirmation cannot make the operation
atomic.

For activity and delete-residency checks, `written_at` must be finite, no more
than ten seconds old, and not in the future. Loaded-model evidence requires a
current successful read; `updated_at` must be finite, not in the future, and not
predate the current daemon's `started_at`. A stale, future, invalid, or
unavailable activity read is unknown; Delete fails closed before
constructing a remove command unless daemon and loaded-model residency are both
fresh. Save and Download each reread catalog/local sources without stale
fallback immediately before the command: saved selections must be unambiguous
downloaded catalog models, and a download target must be a fresh Available
entry. The UI receives typed source states for the corresponding gates, but the
service repeats the validation for direct callers. Settings retains the last
typed result without manufacturing a time-based catalog warning; Delete always
rereads and validates the authoritative sources before issuing a remove command.

After a successful Start, Stop, or Restart, the app requests immediate telemetry
and status reads before refreshing the provider-control snapshot. The popup
renders model pills only when the official telemetry model sources are fresh;
otherwise it states that model state is unavailable. User-facing diagnostics redact home paths and
credential-shaped text, preserve only fixed safe error categories, and do not
surface raw or unbounded command output. During a current download, the Settings
view may show one latest sanitized progress line from stdout or stderr with a
4,096-byte input bound; all other command output remains unrendered. Model-row controls identify their
targets and effects in accessibility labels and hints. Lifecycle controls have
labels, help text, and identifiers, while customer-impact detail is supplied by
the Stop/Restart confirmation alert.

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

Before retention, `EventPrivacy` withholds entire text fields with known credential,
provider/account identity, or customer-payload markers, removes terminal controls
and URLs, and replaces home-directory names. Search, tooltips and accessibility
consume the same filtered buffer. Operational `prompt_tokens`/`completion_tokens`
counters are not payload fields. Oversized raw events are rejected before filtering;
the filtered buffer remains capped at 100 events and 128 KiB of UTF-8 payload.
This is known-pattern filtering, not a guarantee that arbitrary unmarked prose is
safe to share. Export must still require a separate preview/confirmation and must
not assume the source logs were comprehensively redacted by macOS. No source log
file is modified by the monitor.

Logs export uses an immutable preview snapshot of the current filtered events.
Schema 1 JSON includes source/generation timestamps, availability, omission count
and retained event text, but no structured process ID/image fields. Final JSON is
capped at 256 KiB (including escaping), dropping whole oldest rows when needed.
Preview creation does not write a file. The review checkbox and Save JSON action
precede the native save dialog; saved bytes are the same bytes shown for review.
This remains a user-reviewed diagnostic artifact, not automatically share-safe
content or a reconstruction of omitted source history.

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

## Monitor-observed uptime extension

The menu's uptime row is a locally owned observation metric, not Darkbloom's
official provider reputation or a server-reported availability score. The
monitor records timestamped presentation states in
`~/Library/Application Support/Darkbloom Monitor/observed-uptime.sqlite3`; the
database is mode `0600` and survives app restarts.

Only explicit `.online` and `.offline` samples are classified. Stale and
unavailable samples are recorded as unknown and excluded from both numerator
and denominator. A classified sample carries forward for at most ten seconds;
longer app-off, sleep, or read-failure gaps are unobserved rather than guessed.
Within the trailing 24 hours, the displayed percentage is classified online
seconds divided by all classified seconds.

The menu bar displays `warm` until five classified minutes have accumulated.
After warm-up it displays the rounded percentage and a neutral progress bar.
The popover and accessibility text disclose classified observed coverage so a
high percentage over sparse evidence is not presented as full-day coverage.
