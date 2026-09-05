# Live Model Control and Demand Implementation Plan

Date: 2026-09-03
Spec: `docs/superpowers/specs/2026-09-03-live-model-warming-design.md`

> SUPERSEDED historical plan — do not execute. The signed vendor-released CLI
> is the only supported provider. This plan's private model-control endpoints,
> custom provider branch, protected warm/retire operations, staged loading, and
> automatic switching are unavailable under the official-CLI boundary. It is
> retained only as historical traceability, not as instructions to build,
> install, select, or launch a custom CLI.

## Completed locally

- App-managed Start and Restart pass every exact saved enabled model and enable the authenticated loopback endpoint, avoiding both the CLI model picker and its argument-preserving restart behavior.
- Endpoint discovery validates ownership, mode, freshness, loopback URL, and bounded content.
- The legacy chat-completion warmup client sends a bounded one-token request
  and explicitly declares that it may evict a resident; the live service uses
  the protected client instead.
- Provider control serializes warm operations, blocks active inference in
  one-slot mode, permits protected two-slot staging beside an active job, and
  reconciles fresh residency.
- Provider configuration parses and atomically rewrites `max_model_slots` while preserving unrelated bytes and security metadata.
- Settings offers one-model Memory Saver and coordinator-visible Two-model capacity.
- Two-model mode exposes a configurable 8-24 GiB staging reserve, default 16 GiB.
- Two-model staging blocks when capacity is full, memory is insufficient, or the provider client cannot promise no eviction.
- The staging reserve uses live whole-system reclaimable memory as well as provider-reported capacity, so other applications are included in the safety gate.
- The two-model gate uses `min(max(0, total - gpuActive - gpuCache), systemAvailable) >= targetSize * 1.2 + reserve`; missing system-memory evidence blocks rather than guessing.
- Public per-model capacity is fetched every 30 seconds with stale-last-good behavior, a two-minute actionability limit, bounded future skew, and out-of-order response rejection.
- The popup shows compact enabled-model demand rows and a manual flame action for unloaded models.
- The provider branch `codex/protected-model-control` exposes authenticated capability, no-evict load, and exact idle-retire routes.
- The monitor explicitly probes the capability route and uses the protected client by default.
- One-slot mode retires an idle resident before loading the target.
- One-slot switching has an intentional cold-load gap; if target loading fails after retirement, fresh reconciliation reports the partial state without claiming rollback.
- Two-slot mode loads the target first and only then retires the previous model; a busy-retire response leaves the customer model resident.
- Two-slot staging can proceed beside active inference when a slot and conservative memory headroom are available.
- Coordinator-prefetched and otherwise unknown residents count toward the shared second-slot capacity, so a full resident set waits instead of evicting.
- During a coordinator hard swap, the provider derives its effective slot cap from the distinct union of advertised and resident models. Removing the superseded model from advertisement therefore does not collapse two-slot staging while that idle resident is still draining.
- Settings exposes default-off automatic demand switching with three-sample hysteresis and a 30-minute attempt cooldown that survives monitor relaunches and toggle cycling.
- Manual, automatic, and service execution share one fail-closed eligibility policy; preflight rejections do not consume the automatic cooldown.
- The popup reports preparing, safe loading/staging, idle retirement, and authoritative reconciliation as distinct compact phases.
- The popup uses fresh protected-control residency when available, falls back to fresh telemetry residency, and withholds model pills when neither source is authoritative.
- A non-busy failure while retiring the previous model after a successful two-slot load is reported as a safe partial outcome after residency reconciliation; it is not presented as a completed switch.
- Restart-required state persists across monitor relaunches and is derived from fresh provider proof of the raw Enable/Preload/hard-cap configuration and immutable launch model set; command success alone never clears it.
- Warm cancellation before provider mutation is a no-op; cancellation after a load or retire may have started still reconciles fresh state and invalidates actionable state when the outcome cannot be established.
- Orderly Quit awaits monitor-owned telemetry shutdown; app termination cancels automatic switching and the current control operation without targeting the provider process, but does not guarantee an in-flight provider request or reconciliation completes before exit.

## Local verification

- Monitor `swift test`: 434 tests in 28 suites passed.
- Monitor `swift build -c release`: passed.
- Provider `make provider-test`: 2,439 tests in 245 suites passed with the source-matched MLX metallib.
- Provider protected-control checks passed for authenticated loopback routing, admission and reservation accounting, idle-timeout protection, retirement gates, bounded lifecycle shutdown, and one/two-slot configuration.
- Provider `swift build -c release`: passed.
- `git diff --check`: passed in both working trees.
- A refreshed read-only check found nine active catalog entries and eight unique model-capacity rows with the exact bounded schema consumed by `NetworkCapacityParser`; both feeds include the newly added `Qwen3.5-9B` model.
- A refreshed read-only local inventory check found six saved enabled selectors and five locally downloaded models. The two manually selected Qwen models are both downloaded, resident, and advertised; the other saved enabled selectors remain catalog eligibility rather than proof of live residency.
- CMake 3.31.10 was installed in the isolated `/tmp/darkbloom-cmake-venv`, and Apple Metal Toolchain build 17F109 (`metal` 32023.883) was installed through Xcode. The exact nested MLX source produced metallib SHA-256 `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`.
- The source release binary SHA-256 is `fc0068077bf005759a11944ad2c78c7484acdea2aa02c791542016d0f7cda5f9`; its protected model-control route is present and was live-qualified without modifying the vendor-signed app bundle.
- A direct source-runtime qualification launched `EigenLabs/Qwen3.8-27B-4bit-mtp` and `Qwen3.5-9B` with the authenticated loopback endpoint. `GET /v1/provider/model-control` returned API version 1, two effective/configured slots, both Qwens resident and advertised, the six enabled selectors, the two preload selectors, and the exact launch set. An idempotent protected load of the already-resident `Qwen3.5-9B` returned HTTP 200 without changing either slot.
- During live qualification the coordinator continued reporting `trust_level = hardware`, `status = online`, reason `MDM verification passed`, with no active customer inference and both Qwens warm and advertised.
- The installed 0.8.16 app remains the notarized Eigen Labs build. Replacing only its executable would invalidate its Developer ID bundle signature and its APNs/keychain entitlements, so a durable installation of the new provider still requires an Eigen Labs signed release rather than an in-place unsigned mutation.
- The reboot recovered `/Volumes/Sol`; the Hugging Face cache root enumerated all 71 entries without delay. The versioned local runtime at `~/.darkbloom/local-builds/protected-model-control-fc006807` is now selected through the monitor's existing `~/.darkbloom/bin` override and runs persistently under launchd. Post-reboot proof matched launch PID and daemon PID `6523`, showed a sub-second state age, hardware trust online with MDM verification passed, both Qwens warm and advertised, two effective slots, and HTTP 200 from an idempotent protected load. The notarized Eigen Labs app bundle remains untouched as the rollback artifact.

## Remaining runtime integration

1. Commit and submit the reviewed provider branch to the Eigen Labs release pipeline so the protected endpoint can ship in a correctly signed and notarized app bundle.
2. During an idle customer window, install the signed provider release and restart it with the saved enabled model set plus its authenticated local endpoint.
3. Launch one canonical monitor instance, inspect Settings and popup at normal scale, and exercise both one-slot and protected two-slot switching without interrupting customer work.

Do not push or publish either working tree without separate user authorization. Do not replace the signed provider bundle with an unsigned local build.
