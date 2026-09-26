# Local identity and transport checkpoint

Research base: `ada1bb6`. Implementation branch: `codex/companion-transport-spike`. This checkpoint contains only the isolated [prototype](../../../tools/companion-spike/README.md) and documentation. The product package, running provider, settings, histories and real tailnets were not changed.

## Decision

Continue the companion's native TLS/device-identity work over LAN and external Tailscale. **Do not promote the embedded C adapter.** Its repeated-connection regression intermittently loses an entire request, including after several attempted ownership fixes. The checked-in failing regression and candidate history make that conclusion reproducible. This does not establish that embedding is impossible; it means this candidate has not earned adoption.

Task 1 remains incomplete. QR enrollment, hardware-backed keys, a signed persistent Mac helper, real phone↔Mac traffic and WAN behavior are not implemented or proven here. The fake runner changes memory only; successful fake start/stop does not authorize or prove real provider/app control.

## Independently verified native proof

| Check | Result and scope |
|---|---|
| Root app baseline | Suite reports 654 tests in 87 suites passing, with two opt-in live checks skipped. Existing app source is unchanged. |
| Root release and packaging | `swift build -c release --jobs 4` passes; all 16 packaging tests pass. |
| Mac standalone package | 12 identity tests plus 11 transport tests pass. |
| Mac direct mTLS harness | All 13 assertions pass on the final native source, including authentication rejection, fake operations and shutdown. |
| iOS 26.5 Simulator | 11 identity tests and 11 transport tests pass; one additional Keychain absence test explicitly skips because the generated test host lacks the required entitlement. |
| iOS device / simulator library builds | Compile with deployment target iOS 17. No physical-device runtime claim. |
| Platform metadata | Mac harness reports minimum macOS 14; arm64 device `SpikeTLS.o` reports iOS 17. These are build metadata, not minimum-OS execution tests. |

The native tests exercise self-signed P256 identity creation/signing; canonical SPKI pins; wrong pins/roles, expiry, malformed/extra certificate chains and certificate profiles; missing/unpaired client certificates; revocation; a 128 KiB payload; frame size/partial-frame deadlines; stalled handshakes/reads, cancellation; eight-session admission and concurrent idempotent stop. TLS requires version 1.3, explicit peer authentication and the expected ALPN; resumption/tickets are disabled. Pin tests record real trust decisions. The integration harness verifies a healthy route before rejection probes and again afterward; timeouts cannot qualify as authentication rejection.

The iOS run found an incorrect test assumption: `SecKeyCopyAttributes` can report `kSecAttrIsPermanent=true` for a software key created with permanence disabled. Apple's [published Security implementation](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/sec/Security/SecKey.m#L110-L145) fills that attribute independently of actual storage; its creation path controls storage separately. We replaced the attribute assertion with exact synthetic application-tag/public-label lookups, while retaining native signing verification. Mac lookups pass before/after identity release. A bounded entitled Simulator probe also reported `errSecItemNotFound`; the normal unentitled iOS suite keeps this proof explicitly skipped. No broad Keychain enumeration or key deletion occurred. This does not replace the later production Keychain/Secure Enclave work.

## Embedded evidence and its limits

An early local mTLS integration completed all 14 assertions: healthy route, host-pin/client-identity rejection, no fake operation from rejected peers, authenticated traffic, large payload, fake start/stop, revocation and graceful shutdown. That binary used an earlier guarded-descriptor candidate. Subsequent repeated-connection testing invalidated any claim that this was a reliable embedded transport.

The final candidate uses the pinned libtailscale revision `59d4bb82744915815178e0f0776d60026a397ee7`, updated `tailscale.com v1.102.4`, Go 1.26.6, and the checked-in source patch/overlays. Codex rebuilt from those inputs and independently ran the complete race suite: **eight behavioral cases passed, the reconnect case failed, and the process-only entry point skipped**. At connection 1 the host read 0 bytes instead of 8,192 with EOF; the suite exited 1 in 42.832 seconds. The full verifier therefore stopped before integration, as intended. The native 13-assertion harness above was run independently afterward. Final embedded integration was not rerun to chase a passing result.

The candidate retains failing reconnect coverage rather than hiding it behind timeouts. See [candidate history and exact reproduction commands](../../../tools/companion-spike/tailscale/README.md) and the [portable evidence manifest](2026-09-25-transport-prototype.json). Successful isolated cancellation, logging or one-shot transfer tests do not override failed transport integrity.

After GLM's review, Codex strengthened the active-cleanup test to require an acknowledged round trip before cancellation, and rebuilt from source again. That final race run passed **seven** behavioral cases, including the stronger cleanup test, and failed **two**: stalled-session recovery and repeated connections (again 0/8,192 bytes at connection 1, this time ending at the per-request deadline). The suite exited 1 in 50.648 seconds; it did not hit its global watchdog. The C adapter implementation was unchanged between the EOF and timeout reproductions. Both results remain evidence against promotion; neither is replaced by the other.

The failure is localized only as far as the observed data path: the phone adapter writes the full 8,192-byte request, but the host sees zero-byte EOF and a later internal write hits a broken pipe. Root cause is unresolved. Registry keys, half-close behavior, descriptor pinning, managed Unix sockets and descriptor-transfer framing were investigated. Do not describe those changes as a completed fix.

No real Tailscale credentials or provider secrets enter the fixture. Control/DERP/STUN and node state are synthetic and temporary. Local log-sink suppression and upload disabling have separate tests/configuration; no claim is made of exhaustive outbound packet capture. Updated iOS C archives and real auth/resume/network-path behavior remain separate gates.

## Review and next stop

Native workers implemented bounded files; Codex integrated and independently ran verification. GLM-5.3 completed a read-only ZCode review under the local `friday-routing` skill. The model inspected earlier Swift/fixture snapshots and the final C patch; source changed during its review. It ran no tests, made no edits, and did not independently verify the final run evidence. Codex checked its findings against the final files; this is not a comprehensive production security audit.

| GLM finding | Codex disposition |
|---|---|
| Negative auth assertions could count a dead route as rejection in the earlier harness. | Already addressed by a healthy baseline in both route modes, trust-decision observations, and another healthy request afterward. Codex additionally excluded POSIX timeout/cancellation/unreachable errors and DNS failures. The final direct harness passes all 13 assertions. The historical embedded 14-assertion run had the baseline/trust observations, but is not final-adapter qualification. |
| Full cleanup on a copy error could explain the lost-byte symptom. | Retained as a diagnostic hypothesis, not an established cause. Closing both directions on a real stream error is deliberate failure handling; future tracing must identify the first error/close rather than suppressing it to force a pass. |
| The patch uses an unchecked `CloseWrite` interface assertion. | No reachable mismatch established for the current `AF_LOCAL` stream socketpair, whose `net.FileConn` result is a Unix connection. Retained as a robustness item for a future portable adapter; this blocked experiment is not promoted. |
| Active-cleanup test ignored its initial write result. | Fixed more strongly: verify complete request and acknowledged end-to-end reply before cancel; close the target listener before joining its goroutine on failures. The strengthened test passes in the final race run. |
| Native child watchdog differs from standalone script documentation. | Documented separately: 120 seconds in the native harness, 200 seconds in `run.sh`, plus the parent's readiness/termination bounds. |
| The upstream listener registry still uses integer descriptors. | Valid remaining lifecycle-audit target before listener recreation/production use; this fixture has one listener at a time and joins cleanup between cases. No claim that this is the demonstrated reconnect root cause. |
| Mid-debug source/binary drift invalidates broad success claims. | Resolved for this checkpoint by two fresh builds from the checked-in patch/overlays, exact patch reapplication comparison, final source/binary/log hashes, and explicit historical-vs-final results. The final result remains failed. |

Clock-skew policy, hardware keys, signed persistence, minimum-OS/device/WAN execution, listener recreation and dependency/security review remain production gates. The current software-key and one-hour certificate fixtures are explicitly synthetic.

The next implementation step is a signed synthetic iPhone/Mac identity-and-pairing harness over LAN/external Tailscale, preserving the application SPKI/mTLS boundary. Do not wire real options, CLI lifecycle, app lifecycle or histories until the later policy/helper gates in the implementation plan. The existing planning stop before live provider mutations remains in effect.
