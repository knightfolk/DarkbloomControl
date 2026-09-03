# Live Model Warming Design

Date: 2026-09-03
Status: User-approved interaction design; implementation pending

## Goal

Allow a user who serves several enabled models with fewer resident model slots to choose which enabled model is warm now, without restarting the Darkbloom provider for each switch.

For the current one-slot configuration, selecting **Make Warm** on an unloaded enabled model should ask the running provider to load that model and allow the provider to evict the current idle resident model. The action must not alter the saved enabled or preload selections.

## Model-state contract

The feature preserves five separate concepts:

- **Catalog model:** supported by the Darkbloom coordinator.
- **Downloaded model:** present in the local model cache and shown in My Catalog.
- **Enabled model:** included in the saved provider configuration and passed as an exact repeated `--model` argument when the provider starts.
- **Preloaded model:** an enabled model selected to become warm during provider startup.
- **Warm model:** currently resident in a live provider slot.

All locally downloaded models do not automatically become enabled. All coordinator catalog models do not need to be downloaded. The provider should start with every saved enabled model as eligible to serve, while `max_model_slots` controls how many may be resident at once.

**Make Warm** is a one-time runtime action. It does not enable, download, preload, delete, or restart anything. Preload remains the separate persistent startup preference.

## Verified CLI and runtime constraints

The design targets the installed Darkbloom CLI 0.8.15 behavior observed on 2026-09-03:

- `darkbloom start` accepts repeated exact `--model` arguments and `--local-endpoint`.
- `--local-endpoint` exposes an authenticated loopback OpenAI-compatible endpoint alongside coordinator serving.
- `darkbloom local --json` reads `~/.darkbloom/local.json`, whose current community-observed shape includes `base_url` and `api_key`.
- The CLI does not expose a supported `models load`, `models unload`, `models warm`, or `models activate` command.
- The provider implements lazy model loading and idle-model eviction for inference requests.
- Live state exposes `inference_active`, `current_model`, `warm_models`, slot models, and `process_identity` through the existing daemon and loaded-model sources.

The current provider was launched with four exact `--model` arguments and `max_model_slots = 1`, but without `--local-endpoint`; `~/.darkbloom/local.json` is absent. Therefore the running provider needs one explicit stop/start transition to enable local live switching. Once enabled, subsequent Make Warm actions do not restart the provider.

## Approaches considered

### Authenticated unified local endpoint — selected

Start the provider with `--local-endpoint`, then send a minimal authenticated local inference request for the selected exact model. This uses the same running provider and its native lazy-load/eviction behavior.

Benefits:

- no provider restart per model switch;
- no coordinator routing dependency;
- no user account API key;
- no remote request charge;
- exact target model;
- direct reconciliation against local state.

Costs:

- one initial provider stop/start is required to install the endpoint into the launch-agent arguments;
- a tiny synthetic inference is generated because CLI 0.8.15 has no load-only command;
- the request may wait or fail while every resident model is actively serving.

### Coordinator-routed pinned request — rejected

A public chat-completion request can attempt to target a particular machine. This depends on user API credentials, remote coordinator behavior, undocumented or changing machine-routing semantics, and possibly billable inference. It is not appropriate for routine local model control.

### Rewrite preload and restart — fallback only

Changing `preload_models` and restarting should load a selected model reliably, but it interrupts provider service and conflates runtime selection with the next-start preference. It remains a manual fallback, not the Make Warm implementation.

## Provider start behavior

App-managed Start continues to resolve every saved enabled selector to one exact downloaded catalog model and passes each as a repeated `--model` argument. It also adds `--local-endpoint` while retaining authenticated loopback defaults. It never adds `--no-auth`, never binds a non-loopback address, and never uses `--all`.

The app does not silently restart a provider that is already running without the endpoint. In that state, model rows show that live switching requires one setup transition and offer **Enable Live Switching…**. That action:

1. refreshes provider activity;
2. presents the normal customer-impact warning if inference is active or cannot be verified;
3. on confirmation, performs an app-owned Stop followed by an exact app-managed Start with `--local-endpoint`;
4. waits for a new process identity and fresh endpoint discovery;
5. reports complete, partial, uncertain, or failed setup explicitly.

The setup transition is never described as a normal model switch. If Stop succeeds but Start fails, the app must report that the provider is stopped and offer the existing Start recovery action.

## Local endpoint discovery and security

Add `~/.darkbloom/local.json` as a narrowly approved control source, not general telemetry.

The discovery reader must:

- cap the file size before decoding;
- reject symlinks, non-regular files, unexpected ownership, and group/world-readable permissions;
- decode only the required `base_url` and `api_key` fields;
- reject empty credentials;
- require plain HTTP to an exact loopback host (`127.0.0.1`, `::1`, or `localhost` after a loopback resolution check);
- reject URL user information, fragments, and unexpected query parameters;
- require the discovery timestamp to be compatible with the current provider process start;
- retain the key only in the request-scoped value lifetime;
- never place the key in logs, errors, fixtures, crash descriptions, `UserDefaults`, or SQLite.

The request client uses an ephemeral `URLSession`, no persistent cookies or cache, no redirect following, bounded request and response bodies, and a dedicated timeout. Redirects are rejected because they could disclose the bearer credential.

If discovery is missing, stale, insecure, or cannot be associated with the current provider run, Make Warm is unavailable with a specific recovery explanation.

## Make Warm eligibility

A model is eligible when all of the following are true:

- the provider is known running from fresh state;
- the catalog, local inventory, provider configuration, daemon state, and loaded-model state meet the existing control freshness contract;
- the model resolves to one exact catalog ID;
- the exact model is downloaded;
- the exact model is in the saved enabled set;
- there are no unsaved model-configuration changes affecting the row;
- the model is not already warm or active;
- no conflicting provider mutation is running;
- a secure endpoint discovery record is available for the current provider run.

The action is disabled rather than guessed when identity, residency, eligibility, or endpoint state is ambiguous.

## User interaction

Each downloaded model row gains a compact **Make Warm** action with an accessible text label and tooltip. It is visually separate from the Enable and Preload switches and Delete action.

Row behavior:

- active model: action replaced by the existing Active state;
- loaded-idle model: action replaced by the existing Loaded/Warm state;
- enabled, downloaded, unloaded model: Make Warm available when the endpoint and source states are safe;
- disabled or unsaved-enabled model: action disabled with “Enable and save this model first”;
- provider stopped: action disabled with “Start the provider first”;
- endpoint not installed: show “One restart required to enable live switching” and the separate setup action;
- another mutation running: action disabled with the operation name.

For a one-slot provider, the confirmation names the selected model and the currently warm model:

> Make Qwen warm now? Gemma currently occupies the only model slot and may be unloaded.

If fresh state reports customer inference active:

> A customer job is currently using a model slot. Darkbloom may wait for it to finish or reject this switch; forcing a restart is not part of this action.

If activity is unknown:

> Darkbloom Monitor cannot confirm whether a customer job is running. The switch may delay work or be rejected.

Both warning states allow Cancel or **Try Make Warm**. Confirmation authorizes the bounded local request; it does not authorize stopping, killing, or restarting the provider.

For multi-slot providers, the confirmation states whether a free slot is currently observed. If all slots are full, it explains that Darkbloom chooses an idle eviction candidate. The app does not implement its own model eviction policy.

## Request and reconciliation flow

After eligibility and any required confirmation:

1. Re-read daemon and loaded-model state.
2. If the target became warm, finish successfully without sending a request.
3. If the safety classification worsened, present the current warning before continuing.
4. Load the secure endpoint discovery record again.
5. Build a JSON-encoded request to the local `/v1/chat/completions` route containing:
   - the exact enabled catalog model ID;
   - one fixed non-sensitive user message;
   - `stream: false`;
   - `max_tokens: 1`.
6. Mark the operation as request sent only after the HTTP task is created.
7. While the bounded request is pending, show **Waiting for model slot** when all slots are observed busy, otherwise **Loading model**.
8. On an HTTP success, refresh daemon and loaded-model state until the target is observed warm or the reconciliation deadline expires.
9. On HTTP failure or timeout, still reconcile once because the provider may have loaded the model before the client saw the result.
10. Report one of:
    - target warm;
    - provider busy/rejected;
    - request failed with bounded sanitized detail;
    - target not observed before timeout;
    - outcome uncertain because authoritative state is unavailable.

Success is based on authoritative loaded/warm state, never only on HTTP status. The app must not claim which old model was evicted until fresh state proves it.

## Active inference behavior

Make Warm never terminates a customer request. If every usable slot is actively serving, Darkbloom may queue the synthetic request or refuse to evict. The app allows the user to try after warning, but it must display the provider's actual outcome.

There is no “force immediately by killing the active model” path. Such behavior would be a lifecycle interruption and would require a different explicitly destructive design.

## Synthetic request accounting

The one-token local request may affect daemon-level inference counters even though it is not customer work. Before release, a controlled live characterization must measure whether it changes:

- provider `jobs_completed`;
- prompt/completion/generated token counters;
- current and average tok/s derivation;
- account earnings history;
- provider logs used for model attribution.

The app records an in-memory warm-operation interval and the response's usage fields when available. If counters can be subtracted without ambiguity, the derived local activity series excludes exactly that synthetic work. If concurrent customer work prevents exact attribution, the app does not guess: account earnings remains authoritative, and locally derived job/token views disclose that a one-request warmup may be included.

This characterization is an implementation gate, not an optional polish task.

## State and API changes

Add a model-specific runtime operation rather than overloading lifecycle:

```swift
enum ProviderOperation {
    case idle
    case refreshing
    case saving
    case downloading(modelID: String)
    case deleting(modelID: String)
    case lifecycle(ProviderLifecycleAction)
    case enablingLiveSwitching
    case warming(modelID: String)
}
```

Add focused types:

- `LocalEndpointDiscovery` — validated loopback URL and request-scoped credential;
- `LocalEndpointDiscoveryReading` — bounded secure file reader;
- `ModelWarmupRequesting` — sends one exact bounded local request;
- `ModelWarmupOutcome` — warm, busy, failed, timed out, or uncertain;
- `ModelWarmupPresentation` — row eligibility, help text, confirmation, and progress.

`ProviderControlService` remains the mutation serialization owner. It validates inventory/configuration and coordinates the warmup client, but URL/file security stays in dedicated units.

## Expected files

Production:

- modify `Sources/DarkbloomTelemetry/SourcePolicy.swift`
- add `Sources/DarkbloomTelemetry/LocalEndpointDiscovery.swift`
- add `Sources/DarkbloomTelemetry/ModelWarmupClient.swift`
- extend `Sources/DarkbloomTelemetry/ProviderControlService.swift`
- extend `Sources/DarkbloomMonitor/ProviderControlStore.swift`
- extend `Sources/DarkbloomMonitor/ModelManagerView.swift`
- extend `Sources/DarkbloomMonitor/ProviderLifecycleControls.swift` only for the one-time setup transition

Tests:

- add `Tests/DarkbloomTelemetryTests/LocalEndpointDiscoveryTests.swift`
- add `Tests/DarkbloomTelemetryTests/ModelWarmupClientTests.swift`
- extend `Tests/DarkbloomTelemetryTests/ProviderControlServiceTests.swift`
- extend `Tests/DarkbloomTelemetryTests/ModelManagerPresentationTests.swift`
- extend lifecycle and layout tests for setup/recovery presentation

## Test-first sequence

1. Exact app-managed Start arguments include every resolved enabled model plus `--local-endpoint`, never `--all` or `--no-auth`.
2. Discovery parsing accepts a private current loopback record and rejects insecure/stale/redirecting cases without exposing the key.
3. Warmup request generation uses the exact model, JSON encoding, one output token, no redirect, and strict bounds.
4. Eligibility rejects stopped, disabled, missing, ambiguous, stale, already-warm, unsaved, and conflicting-operation states.
5. Active and unknown inference create warnings but allow the bounded Try action.
6. A warm target appearing during preflight prevents the synthetic request.
7. HTTP success is not success until fresh loaded state contains the target.
8. HTTP timeout followed by a warm target reports success; timeout plus unavailable state reports uncertainty.
9. A busy provider leaves the current model untouched and reports busy without restarting.
10. Operation cancellation cancels only the app's HTTP task and never the provider.
11. UI tests verify row grouping, accessible names, progress, one-slot eviction copy, and setup recovery.
12. Controlled live characterization records counter effects before enabling the feature in a release build.

## Acceptance criteria

- Every saved enabled model remains eligible to receive coordinator work after provider startup.
- With one slot and an idle warm model, the user can select another enabled downloaded model and observe it become warm without a provider restart.
- Make Warm never edits Enable or Preload state.
- Preload still controls the preferred warm model for the next provider start.
- The action never invokes a shell, remote coordinator warmup, `start --all`, `--no-auth`, Stop, Restart, or a direct eviction command.
- Active or unknown work produces a clear warning but allows the user to try the non-destructive switch.
- An actively serving model is never killed by Make Warm.
- Success is confirmed from fresh daemon/loaded-model evidence.
- Credentials stay request-scoped and absent from logs, storage, fixtures, and errors.
- Missing local endpoint state leads to a clearly labeled one-time setup transition, not a silent restart.
- Synthetic-request effects on displayed counters are either precisely excluded or explicitly disclosed.

## Out of scope

- continuous Keep Warm scheduling;
- periodic synthetic requests;
- remote-machine warming;
- user API-key storage;
- coordinator-pinned warmup;
- manual model eviction or unloading;
- interruption of active inference;
- changing slot count, memory limits, or idle timeout;
- automatically changing the preload selection after Make Warm.
