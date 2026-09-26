# Synthetic embedded Tailscale bridge — blocked feasibility candidate

**Embedded promotion is BLOCKED.** Repeated C-descriptor connections under Go's race instrumentation can lose an entire 8 KiB request: the phone-side relay reports 8,192 bytes forwarded while the host-side relay receives zero-byte EOF. Individual synthetic byte tests and a native mTLS integration run passed on earlier candidates; they did not establish repeated-connection correctness. Keep the failing regression and use the external-client fallback decision gate. This directory is test-only and does not change the shipping app.

## Scope and process interface

Two libtailscale C API nodes use in-process synthetic control and localhost DERP/STUN:

`native TLS client → private loopback TCP → tailscale_dial fd → synthetic tailnet → tailscale_accept fd → fixed 127.0.0.1 native TLS server`

The bridge treats bytes as opaque. No provider operations, real tailnet enrollment, persistent app state or Keychain operations exist here. The parent native harness owns TLS identity/authentication assertions. Client bytes cannot select a destination.

```sh
# Repository root. All generated source, binaries and state stay in ignored .build.
tools/companion-spike/tailscale/build.sh
SPIKE_TARGET_PORT=12345 tools/companion-spike/tailscale/run.sh
```

The process writes exactly one stdout readiness line `{"port":N}`. Hold stdin open; EOF, SIGINT or SIGTERM initiates cleanup. Diagnostic/test output goes to stderr. `SPIKE_TARGET_PORT` accepts only an integer from 1 through 65535, always at `127.0.0.1`; the tailnet service port is fixed at 49443. Node state uses temporary directories and Go test cleanup.

`build.sh` archives exactly libtailscale `59d4bb82744915815178e0f0776d60026a397ee7`, applies the checked-in patch/overlays/lock files, verifies modules, and compiles the fixture. Set `LIBTAILSCALE_SOURCE` to reuse an existing Git checkout; uncommitted source is ignored. Otherwise it clones the official repository into `.build/libtailscale-upstream`. Every build starts in fresh staging and preserves the prior generated directory under `.build/companion-spike-previous.*/source`. Failed stages are retained for diagnosis. Do not run simultaneous builds.

## Reproduce the failure

```sh
(cd .build/companion-spike && GOTOOLCHAIN=auto GOFLAGS=-p=4 GOMAXPROCS=4 TS_NO_LOGS_NO_SUPPORT=true go test -race -run '^TestSpikeRepeatedConnectionsPreserveDescriptorOwnership$' -count=1 -v -timeout 45s .)
```

The test alternates eight abrupt client abandonments with sixteen complete half-close echoes on one node pair. It retains its original 30-second total and 3-second per-connection bounds. On failure it cancels relay work, closes the target listener **before** waiting for its server goroutine, and checks ownership cleanup. Diagnostic experiments with 10-second per-connection bounds still failed by zero-byte EOF, so extending timeouts did not resolve the defect.

The final exact-source focused race reproduction failed at connection 1 with zero-byte EOF in 5.581 seconds (one top-level case and its nested fixture failed). Codex then rebuilt from the checked-in inputs and independently reproduced the same failure in the complete race suite: eight behavioral cases passed, the reconnect case failed, and the process-only entry point skipped. The complete suite terminated in 42.832 seconds; this was not a timeout. Its raw log is `tools/companion-spike/.build/verification.ZXCj5Y/bridge-race-tests.log`. Portable source hashes and sanitized results are in the [checkpoint evidence](../../../docs/evidence/ios-companion/2026-09-25-transport-prototype.md).

Following GLM review, the cleanup test now proves a complete acknowledged round trip before cancellation. Codex rebuilt and reran the complete race suite: seven behavioral cases passed, including that stronger test; stalled-session recovery and repeated connections failed at their request deadlines (reconnect again returned 0/8,192 bytes at connection 1). The final run exited 1 in 50.648 seconds without reaching the global watchdog. Its log is `tools/companion-spike/.build/verification.WtBGUy/bridge-race-tests.log`. The C adapter itself was unchanged from the earlier EOF reproduction.

Other reproducible entry points:

```sh
(cd .build/companion-spike && GOTOOLCHAIN=auto GOFLAGS=-p=4 GOMAXPROCS=4 TS_NO_LOGS_NO_SUPPORT=true go test -run '^TestSpike' -count=1 -v -timeout 90s .)
(cd .build/companion-spike && GOTOOLCHAIN=auto GOFLAGS=-p=4 GOMAXPROCS=4 TS_NO_LOGS_NO_SUPPORT=true go test -race -run '^TestSpike' -count=1 -v -timeout 90s .)
python3 tools/companion-spike/tailscale/process_smoke.py
```

There are nine top-level behavioral cases plus seven nested fixture cases. `TestSpikeProcess` is skipped unless a native target port is supplied. The original seven cases cover full duplex/half-close, blocked login cancellation, AuthURL capture, fixed destination rejection, blocked dial cancellation, active teardown, and both logger sinks. Added cases cover a stalled first session followed by another client, and repeated descriptor reuse. A passing single invocation is not sufficient evidence to dismiss the churn failure.

## Candidate history and retained evidence

| Candidate/check | Observed result |
|---|---|
| Unpatched upstream | Half-close response was 0 instead of 312,036 bytes; UserLogf suppression assertion failed. |
| Initial half-close/log patch and seven tests | Normal suite passed in 3.147 s; later seven-case race run passed in 22.227 s. These lacked repeated-connection coverage. |
| Sequential one-session bridge | A stalled first half-closed session starved the next request. Added regression failed, then passed with bounded independent sessions. |
| Guarded raw-descriptor shutdown | One native mTLS integration passed, but repeated-connection race tests still produced missing data. |
| Managed Unix socket + stable registry identity, retaining read shutdown | Churn failed at connection 4. |
| Managed sockets with only write-half-close propagation | Churn failed at connection 23 despite earlier requests succeeding. |
| Same candidate plus one-byte SCM_RIGHTS stream framing | Churn failed at connection 2 with zero-byte EOF, including with the longer diagnostic request deadline. This is the retained final candidate. |

Inner-copy tracing observed the phone C adapter writing all 8,192 bytes to the tailnet while the host relay saw EOF before its C copy could write to the local socketpair; that write subsequently failed with broken pipe. This narrows the symptom to descriptor/stream lifetime behavior but does **not** establish a complete root cause. Do not present any of the attempted fixes as resolving the blocker.

Ignored `.build/companion-spike-previous.qyRXXB/source/` preserves detailed failed traces (`churn-fd-trace.log`, `managed-churn.log`, `managed-churn-no-read-close.log`, `framed-managed-churn.log`). Earlier preserved source directories contain the original negative-baseline and seven-case verification logs. Root integration evidence records native positive/negative outcomes separately; authentication rejections must never be inferred from route timeouts.

## Final candidate ownership and bounds

The checked-in patch matches the retained final source. It suppresses both `Logf` and `UserLogf` for `logfd=-1`; transfers the internal socketpair endpoint into `net.UnixConn`; keys the connection registry by stable object identity; uses `sync.Once` cleanup; propagates write-half-close only and joins both copy directions; and frames SCM_RIGHTS transfers with one data byte. Inner diagnostic FD instrumentation is absent from the reproducible patch. `SPIKE_TRACE=1` optionally emits only session IDs, directions, byte counts and EOF/error status from the outer fixture, never TLS payloads.

The overlay adds test-only C exports `SpikeUpBounded`, `SpikeDialBounded` and `SpikeCancelPending`. They admit one operation per node, cancel the actual Go context, and require the caller to join the operation before closing the node. Start happens explicitly before Up; configuration, start and close are serialized. Upstream unbounded Up/Dial exports remain unchanged and are not used here.

At most eight relay sessions are admitted; a ninth accepted client closes immediately. C dial/accept setup remains serialized. Each session has four 32 KiB relay buffers plus four 64 KiB adapter buffers; OS/Tailscale allocations are additional and this is not a measured total-memory bound. Relay lifetime is 30 seconds; Up/Dial and accept readiness are bounded at 10 seconds; native target dialing at 2 seconds. Service lifetime is 180 seconds; standalone `run.sh` has a 200-second Go-process watchdog, while the native integration harness uses a stricter 120-second child watchdog. The native parent also limits readiness to 25 seconds and graceful EOF shutdown to 5 seconds before TERM/KILL escalation of its own child. EOF during sequential node startup may wait for its bounded Up calls.

An opaque bridge cannot classify TLS failure from half-close alone. Native rejected handshakes must cancel their endpoint connections. Independent slots prevent one draining session from blocking all subsequent attempts, while session deadlines bound retained streams; they do not prove prompt handshake-failure cleanup or production lifecycle safety.

`TS_NO_LOGS_NO_SUPPORT=true` independently disables log uploads in scripts/tests. Tests set both local log sinks to discard and inspect a synthetic in-memory AuthURL/canary. This is not packet-capture proof of every possible outbound channel.

## Dependency decision and remaining gates

The official [v1.102.4 release](https://github.com/tailscale/tailscale/releases/tag/v1.102.4) was marked Latest on 2026-09-25 (released September 10). It replaces upstream v1.94.1 and raises the Go minimum from 1.25.5 to **1.26.6**. Final builds use **go1.26.6 darwin/arm64**, `GOTOOLCHAIN=auto`, `GOFLAGS=-p=4`, `GOMAXPROCS=4`; lock files capture transitive versions and `go mod verify` passes. The initial upgrade command briefly auto-selected/downloaded Go 1.26.8 before the updated module selected its minimum.

Do not promote this embedded transport. Remaining gates include reliable descriptor/connection lifetime, updated device/simulator archives, physical Secure Enclave identities, minimum-OS runtimes, real enrollment/revocation, cellular/Wi-Fi/direct/relay transitions, suspension/resume, memory/battery measurements, dependency/security review and production admission/lifecycle design. A separately verified native TLS foundation remains useful with an external Tailscale route.
