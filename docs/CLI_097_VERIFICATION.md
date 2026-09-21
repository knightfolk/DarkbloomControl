# CLI 0.9.7 implementation verification — September 21, 2026

Implementation lives on `codex/cli-097-integration` in the managed `darkbloom-cli-097` worktree. The original main checkout is unchanged. No commit, push, provider restart, model mutation, enrollment change, or real idle/beta setting write was performed.

## Implemented

- Optional schema-1 advertised models, safe authorization/load/MTP/KV diagnostics, kernel-process/coordinator/freshness verification, and installed/running version comparison.
- Saved, advertised, and loaded model comparison; restart warning with a fresh recheck if the selection changed.
- Catalog runtime requirements, quantization/context/output metadata, explicit unverified capability state, and NVIDIA/Bonsai assets with source attribution.
- Read-only thermal/fan and update posture; official CLI idle/beta writes behind the existing operation gate, with staged-model protection and restart-required feedback.
- Network draining and aggregate cache/planner health, with independent source freshness and bounded transport.

## Evidence

- Final production build: `swift build -c release` passed.
- Full suite: **523 tests in 68 suites passed**. Tests include parser/privacy bounds, old/new telemetry, authorization mismatch/expiry, catalog compatibility, network response limits/failures, changed-selection confirmation, shared mutation gating and last-good extras retention.
- Native-render concurrency exposed one- and two-second test watchdogs that could expire while the main actor rendered other windows. Their guards are now ten seconds; the tests still assert exact injected-clock deadlines and real command/cancellation outcomes.
- Live read-only probe using the production telemetry/extras clients decoded CLI and daemon 0.9.7, two advertised models/two slots, three beta flags, the idle policy, temperature/two fans and update posture. Kernel process and coordinator matched. Authorization guidance was stale under the upstream ten-second readiness rule.
- Packaged native app: inspected the live thermal panel, safe load failure explanation, version/verification display, public requirements, and cache routing/planner health. No raw authorization IDs or provider error prose appeared.
- Synthetic native fixture: inspected settings at normal size; typed a 60-minute idle value, saved it to the fixture actor, verified refreshed summary and restart-required feedback, enabled MTP in the actor, and verified unknown features remain read-only. The cramped idle field found during review was corrected.
- Provider PID, process identity, and config-byte hash remained unchanged across native inspection. The synthetic fixture was quit after review.

## Resolved live-environment check

The packaged app's official CLI subprocesses time out during model discovery. A sample of the monitor-owned catalog child showed it waiting in `ModelScanner.scanAllModels` while opening the cache directory. `~/.cache/huggingface` resolves to `/Volumes/Sol/LLMS/HuggingFace-cache`. The same official read-only commands finish in under two seconds when launched from the terminal context; fan diagnostics and daemon-file reads work in the packaged app.

This suggests a launch-context/removable-volume access issue, but a permission denial was not conclusively observed. The computer-control tool refuses inspection of macOS UserNotificationCenter. The user approved the macOS access prompt. Live CLI reads recovered immediately afterward. The final packaged build was then launched and inspected: Models, expanded Nemotron metadata, saved/advertised/loaded sets, idle policy, all three beta features, update posture, and Overview populated correctly. No provider settings were changed to perform this verification. Synthetic setting-write evidence remains distinct from these live read-only checks.

Settings writes remain untested against the real provider intentionally; deterministic command tests and the native synthetic fixture exercise them without changing the user's configuration. No live model-switch/private provider API or per-request token stream was added because a supported companion contract was not established.

## Local artifacts

Final review bundle: `.build/cli097-review-final/Darkbloom Control.app`; its manifest hashes were verified after packaging. The earlier `.build/cli097-review` instance was quit after confirming no unsaved model draft. The final bundle is now running; its sole monitor process maps the final executable. Provider process identity and configuration hash remain unchanged. Both bundles are unsigned local-review artifacts, not published releases.


## Models and queued-stop follow-up

The final Models review build passed 540 tests in 70 suites and the release build. Native live review verified populated local cards and saved concurrency/resident-model values. A temporary CLI model-drive scan stall resolved by the final launch; no access-setting change was made by the agent. The isolated ModelsFixture verified staged concurrency selection, Refresh preserving edits, synthetic Save, queued-stop waiting/cancel, and dispatch after simulated work finished. Queue freshness, double idle checks, mutation exclusion and refresh overlap have regression coverage. Configuration digest and provider process identity remained unchanged throughout review. Final executable matches the packaged `.build/models-final-review/Darkbloom Control.app`. The queue requires the monitor app to remain running; the actual provider was not stopped or restarted for this review.
