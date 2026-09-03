# Live Model Warming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user make any saved-enabled, downloaded model warm in the running provider without restarting it for each switch.

**Architecture:** App-managed Start enables Darkbloom's authenticated unified loopback endpoint while continuing to pass every enabled model as an exact repeated `--model` argument. A secure discovery reader and bounded local warmup client send one exact one-token request, while `ProviderControlService` serializes the mutation and confirms success from fresh daemon/loaded-model evidence. SwiftUI adds a separate Make Warm action and customer-impact/eviction confirmation without changing Enable or Preload.

**Tech Stack:** Swift 6, Swift Testing, Foundation `URLSession`, AppKit/SwiftUI, existing `DarkbloomTelemetry` and `DarkbloomMonitor` targets.

**Spec:** `docs/superpowers/specs/2026-09-03-live-model-warming-design.md`

## Global Constraints

- Target the locally verified Darkbloom CLI 0.8.15 contract.
- Preserve every existing uncommitted lifecycle and startup fix in the shared checkout.
- Do not invoke a shell, `start --all`, `--no-auth`, a non-loopback bind, or a coordinator warmup request.
- Make Warm must not edit Enable or Preload, stop/restart the provider, or kill active inference.
- Every saved enabled model remains an exact repeated `--model` startup argument.
- Credentials remain request-scoped and never enter logs, UI strings, fixtures, `UserDefaults`, or SQLite.
- Success requires fresh daemon/loaded-model evidence containing the target model.
- Automated tests never mutate the real provider, local endpoint, launch agent, or provider configuration.
- Work in the current checkout because the existing uncommitted source changes overlap the feature; stage only feature-owned paths when committing.

---

### Task 1: App-managed Start enables the unified loopback endpoint

**Files:**
- Modify: `Sources/DarkbloomTelemetry/SourcePolicy.swift`
- Modify: `Tests/DarkbloomTelemetryTests/DarkbloomCommandTests.swift`
- Modify: `Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift`

**Interfaces:**
- Produces: `DarkbloomSourcePolicy.localEndpointDiscovery: URL`
- Produces: `DarkbloomSourcePolicy.localEndpointDiscoveryByteLimit == 16_384`
- Changes: `DarkbloomCommand.start(executable:config:models:)` appends `--local-endpoint`

- [ ] **Step 1: Write failing command and policy tests**

Add assertions equivalent to:

```swift
#expect(DarkbloomCommand.start(
    executable: executable,
    config: config,
    models: ["gemma", "qwen"]
).arguments == [
    "start", "--config", config.path,
    "--model", "gemma", "--model", "qwen",
    "--local-endpoint",
])
#expect(policy.localEndpointDiscovery.lastPathComponent == "local.json")
#expect(DarkbloomSourcePolicy.localEndpointDiscoveryByteLimit == 16_384)
```

Retain assertions that `--all` and `--no-auth` are absent.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter DarkbloomCommandTests
swift test --filter SourcePolicyTests
```

Expected: the new start-argument and discovery-path assertions fail because neither exists yet.

- [ ] **Step 3: Implement the minimal policy change**

Add `localEndpointDiscovery` beneath the existing `~/.darkbloom` root and append `--local-endpoint` after all repeated exact models. Do not add a bind, port override, `--all`, or `--no-auth`.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the two focused commands from Step 2. Expected: pass.

### Task 2: Secure local endpoint discovery

**Files:**
- Create: `Sources/DarkbloomTelemetry/LocalEndpointDiscovery.swift`
- Create: `Tests/DarkbloomTelemetryTests/LocalEndpointDiscoveryTests.swift`

**Interfaces:**
- Produces: `LocalEndpointDiscovery(baseURL: URL, apiKey: String, evidenceAt: Date)`
- Produces: `LocalEndpointDiscoveryError` with fixed, non-secret cases
- Produces: protocol `LocalEndpointDiscoveryReading`
- Produces: `LocalEndpointDiscoveryReader(url:fileManager:now:)`
- Consumes: provider `startedAt` and `processIdentity` as freshness context

- [ ] **Step 1: Write failing decoder and security tests**

Cover these concrete cases with temporary files:

```swift
let body = #"{"base_url":"http://127.0.0.1:8100/v1","api_key":"fixture-secret"}"#
```

Assert a private `0600`, current-user, regular file decodes. Assert rejection of:

- missing/empty key;
- HTTPS or a non-loopback HTTP host;
- URL user info, fragment, or query;
- malformed/oversized JSON;
- symlink and directory;
- group/world permission bits;
- wrong owner when simulated through an injected metadata reader;
- modification time older than `startedAt - 5 seconds` or in the future beyond one second.

Assert every `LocalizedError` description is fixed text and does not contain `fixture-secret`.

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
swift test --filter LocalEndpointDiscoveryTests
```

Expected: compile failure because the discovery types do not exist.

- [ ] **Step 3: Implement decoding and file validation**

Use `URLResourceValues` to reject symbolic/non-regular resources and an injected metadata closure for owner, mode, size, and modification time. Decode only:

```swift
private struct Record: Decodable {
    let baseURL: URL
    let apiKey: String
    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
    }
}
```

Accept only exact loopback hosts and request-scoped credentials. Avoid conforming the discovery value to `CustomStringConvertible`.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the command from Step 2. Expected: pass with no credential value in output.

### Task 3: Bounded no-redirect model warmup request

**Files:**
- Create: `Sources/DarkbloomTelemetry/ModelWarmupClient.swift`
- Create: `Tests/DarkbloomTelemetryTests/ModelWarmupClientTests.swift`

**Interfaces:**
- Produces: `ModelWarmupRequest.make(discovery:modelID:) -> URLRequest`
- Produces: protocol `ModelWarmupRequesting`
- Produces: `ModelWarmupClient(session:)`
- Produces: `ModelWarmupResponseUsage(promptTokens:completionTokens:)`
- Produces: fixed `ModelWarmupClientError` cases

- [ ] **Step 1: Write failing request-contract tests**

Assert the request:

- targets `baseURL.appending(path: "chat/completions")`;
- uses `POST`, `Content-Type: application/json`, and `Authorization: Bearer <key>`;
- encodes exact `model`, one fixed message, `stream: false`, and `max_tokens: 1` through `JSONEncoder`;
- has a bounded timeout;
- has no credential-bearing textual description.

Use a test `URLProtocol` to assert 2xx success, 401/403, 409/429 busy, 500, redirect rejection, cancellation, invalid response, and a response larger than 64 KiB. Response errors must expose only status/category, never the body or request headers.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter ModelWarmupClientTests
```

Expected: compile failure because the request/client types do not exist.

- [ ] **Step 3: Implement the minimal client**

Use an ephemeral session configuration. Install a task delegate whose redirect callback completes with `nil`. Consume response bytes with a 65,536-byte ceiling and cancel when the next byte would exceed it. Parse optional OpenAI `usage.prompt_tokens` and `usage.completion_tokens`; never require usage for success.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the command from Step 2. Expected: pass.

### Task 4: Service preflight, serialization, request, and authoritative reconciliation

**Files:**
- Modify: `Sources/DarkbloomTelemetry/ProviderControlService.swift`
- Modify: `Tests/DarkbloomTelemetryTests/ProviderControlServiceTests.swift`

**Interfaces:**
- Adds: `ProviderControlError.warmupBlocked(String)` with allowlisted fixed messages
- Adds to `ProviderControlling`: `performWarmup(_ modelID:onPhase:) async throws -> ProviderMutationCompletion`
- Injects: `endpointReader: any LocalEndpointDiscoveryReading`
- Injects: `warmupClient: any ModelWarmupRequesting`

- [ ] **Step 1: Write failing service tests**

Extend the existing harness with fake discovery and warmup actors. Prove:

- exact downloaded saved-enabled target invokes one request;
- staged-but-unsaved Enable does not qualify;
- disabled, unavailable, ambiguous, already-warm, stopped/stale-daemon, and stale-loaded states fail before a request;
- refresh preflight uses fresh catalog/local/daemon/loaded evidence;
- target becoming warm during preflight returns refreshed success without a request;
- HTTP success with target absent after refresh does not report success;
- request timeout followed by target warm reports refreshed success;
- request timeout plus unavailable reconciliation reports `outcomeUncertain`;
- warmup serializes against Save, Download, Delete, Start, Stop, and Restart;
- cancellation cancels only the warmup task and releases serialization;
- saved configuration is byte-identical before and after every warmup result.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter ProviderControlServiceTests
```

Expected: compile failures for the new protocol operation and injected dependencies.

- [ ] **Step 3: Implement the minimal service flow**

Inside one `beginCommand`/`endCommand` scope:

1. call `refresh(... allowStaleModelSources: false, requireFreshResidency: true)`;
2. resolve exactly one row by catalog ID;
3. require downloaded, saved-enabled, unloaded, and issue-free state;
4. return the preflight snapshot if already warm;
5. read discovery against the fresh daemon start context;
6. send one request;
7. reconcile in a cancellation-shielded task;
8. return `.refreshed` only when the target is active or loaded-idle;
9. return `.outcomeUncertain` when request dispatch may have occurred but state cannot confirm;
10. throw a fixed blocker when fresh state proves the target is still unloaded.

Do not change the draft or call lifecycle commands.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the command from Step 2. Expected: pass.

### Task 5: Pure Make Warm row presentation

**Files:**
- Modify: `Sources/DarkbloomMonitor/ProviderControlStore.swift`
- Modify: `Sources/DarkbloomMonitor/ModelManagerView.swift`
- Modify: `Tests/DarkbloomTelemetryTests/ModelManagerPresentationTests.swift`

**Interfaces:**
- Adds: `ProviderOperation.warming(String)`
- Adds: `ModelRowPresentation.warmAction: ModelActionPresentation?`
- Adds: `ModelWarmupConfirmation(modelID:displayName:residentModels:risk:)`
- Adds: `ModelWarmupConfirmationPresentation.make(_:)`

- [ ] **Step 1: Write failing presentation tests**

Assert:

- a saved-enabled, downloaded, unloaded row offers “Make Model Name warm”;
- active and loaded-idle rows do not offer the action;
- disabled and staged-only enabled rows say “Enable and save this model first”;
- unsaved changes, stale sources, endpoint unavailable, and another operation disable the action with exact help;
- `.warming("model-id")` changes the row to “Making Model Name warm…”;
- confirmation names resident model(s) and warns correctly for active and unknown risk;
- the warm action remains separate from Enable, Preload, and Delete.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter ModelManagerPresentationTests
```

Expected: compile failure because the warm presentation does not exist.

- [ ] **Step 3: Implement pure presentation state**

Add the new presentation value without placing network or file logic in SwiftUI. Use the snapshot's saved `draft.original` and fresh local/daemon/loaded source states. Endpoint recovery copy must say that the next app-managed Stop/Start enables switching; do not imply `darkbloom restart` changes launch arguments.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the command from Step 2. Expected: pass.

### Task 6: Store warning flow and model-row interaction

**Files:**
- Modify: `Sources/DarkbloomMonitor/ProviderControlStore.swift`
- Modify: `Sources/DarkbloomMonitor/ModelManagerView.swift`
- Modify: `Tests/DarkbloomTelemetryTests/ProviderControlStoreTests.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift`

**Interfaces:**
- Adds: `ProviderControlStore.requestWarmup(_:)`
- Adds: `ProviderControlStore.confirmPendingWarmup()`
- Adds: `ProviderControlStore.cancelPendingWarmup()`
- Publishes: `pendingWarmupConfirmation` and fixed progress/error text

- [ ] **Step 1: Write failing store interaction tests**

Use fake controllers to prove:

- idle target with no resident model executes after a second activity read;
- any resident model produces an eviction confirmation even when idle;
- active and unknown risk produce warning confirmation but remain executable;
- Cancel sends no request;
- confirmation performs a final activity read and updates warning if risk changed;
- success accepts the reconciled snapshot while preserving draft identity;
- uncertain/failure outcomes use bounded fixed diagnostics;
- operation stays `.warming(modelID)` through authoritative reconciliation;
- unrelated lifecycle confirmation behavior remains unchanged.

- [ ] **Step 2: Run focused store tests and confirm RED**

Run:

```bash
swift test --filter ProviderControlStoreTests
```

Expected: compile failure because warmup store methods do not exist.

- [ ] **Step 3: Implement store coordination**

Mirror the existing lifecycle two-read confirmation discipline. Confirmation authorizes only `performWarmup`; it never calls Stop/Start/Restart. Map service blockers to fixed model-specific copy through the existing sanitizer.

- [ ] **Step 4: Add the model-row button and alert**

Render a bordered small flame/temperature icon plus “Make Warm” text where the row has space. During `.warming(modelID)`, show a small progress indicator and “Loading model…”. Attach an accessibility identifier `model.<catalog-id>.make-warm` and use a binding-backed alert with cancellation semantics equivalent to lifecycle alerts.

- [ ] **Step 5: Run store, presentation, and layout tests**

Run:

```bash
swift test --filter ProviderControlStoreTests
swift test --filter ModelManagerPresentationTests
swift test --filter MonitorPopoverLayoutTests
```

Expected: pass.

### Task 7: Full verification and controlled live proof

**Files:**
- Modify only if evidence requires: telemetry exclusion/disclosure code and its focused tests
- Update: `docs/TELEMETRY_CONTRACT.md`
- Update: `README.md`

**Interfaces:**
- Documents: unified local endpoint, synthetic request, and source/metric limitations

- [ ] **Step 1: Run static and automated verification**

Run:

```bash
swift test
swift build -c release
git diff --check
rg -n 'api_key|Authorization|Bearer' Sources Tests docs
```

Inspect every credential hit and prove it is a field name, redaction rule, or placeholder—not a value.

- [ ] **Step 2: Build and launch the exact app artifact**

Use the repository's current build/launch procedure. Stop only this project's prior app process, launch the new build, and verify there is one menu-bar instance.

- [ ] **Step 3: Enable the endpoint with an idle controlled transition**

Read fresh `inference_active`. If active, wait and re-check; do not interrupt a job for verification. Once idle, use the app's Stop then Start controls. Verify the new launch-agent command contains every enabled exact model and `--local-endpoint`, and excludes `--all`/`--no-auth`.

- [ ] **Step 4: Characterize the synthetic counter effect**

Capture only non-secret before/after values for process identity, current/warm models, requests served, and generated tokens. Make one nonresident enabled model warm. Confirm:

- process identity is unchanged;
- target becomes warm;
- the previous idle resident is evicted when the one slot is full;
- Enable and Preload are unchanged;
- the account earnings source records no customer earnings for the local request;
- any daemon counter delta is either exactly excluded by implementation or disclosed in UI/docs.

Never print `local.json` or its credential.

- [ ] **Step 5: Visually inspect normal-scale UI**

Capture Settings/Models at normal display scale. Verify Make Warm is visually distinct from Enable, Preload, and Delete; progress and warnings are readable; no horizontal overflow or oversized row appears.

- [ ] **Step 6: Re-run full verification after live characterization changes**

Run `swift test`, `swift build -c release`, `git diff --check`, and a scoped status/diff review again. Expected: all pass; only intended files changed; existing unrelated user work remains preserved.

- [ ] **Step 7: Commit scoped implementation**

Stage only the live-warming implementation, its tests, and documentation. Do not push without separate authorization.
