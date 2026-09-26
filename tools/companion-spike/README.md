# Companion transport prototype

**iOS companion: Coming soon.** This is an unreleased development prototype;
there is no companion UI or remote-control feature in the shipping macOS app.

**Checkpoint decision: native TLS is usable for the next experiment; the embedded C adapter is blocked.** Repeated connections intermittently deliver zero bytes at the host after the phone has written a complete request. A single successful mTLS run does not establish reliable transport. Keep external Tailscale as the first-release route while this candidate remains under investigation. The full verifier deliberately retains the failing regression and must not be advertised as green.

This is a standalone **test tool**, the local portion of [Task 1](../../docs/superpowers/plans/2026-09-25-ios-companion.md). It is not linked into Darkbloom Control and cannot read provider settings, telemetry, tokens or history, run the CLI, or register a helper. All keys, node states, responses and fake start/stop actions are synthetic. It listens only on loopback; this security fixture is not a LAN preview.

The experiment answers a narrow question: can Apple's native pinned mutual TLS remain intact while the encrypted bytes travel through libtailscale's userspace C descriptors?

```text
Native TLS client → loopback byte bridge → embedded C dial
                  → synthetic tailnet → embedded C accept
                  → fixed loopback destination → native TLS server
```

The Go fixture is a separate process to make its lifetime and test control server explicit. That process boundary is a harness choice, not an iOS architecture: an eventual iPhone adapter must embed the C archive in its own process and pass separate device tests. No external Tailscale app, real tailnet enrollment, system VPN, generic proxy, port forwarding or cloud deployment is involved in these tests.

## Run

Use Xcode/Swift 6.1 or newer and Go with automatic toolchain selection. The checked-in lock files fix the resolved Swift and Go dependencies. The current Go candidate requires 1.26.6. Downloads come from official Apple/Tailscale repositories and the Go module infrastructure.

From the repository root:

```sh
tools/companion-spike/verify.sh
```

The script runs the native tests, builds the fixture from the pinned source plus checked-in changes, runs Go race tests, and runs direct and embedded mTLS assertions. It exits nonzero at the first failure. Each run has a separate ignored `.build/verification.*` evidence directory. Do not run two fixture builders simultaneously. Existing generated fixture directories are preserved when rebuilding.

The known reconnect regression can fail the Go step before integration runs. Use the individual commands below to inspect the independent native proof; do not delete or skip that regression to qualify the embedded candidate.

For just the Swift tests:

```sh
swift test --package-path tools/companion-spike --jobs 4
```

For an individual integration run after building:

```sh
SPIKE_BIN_DIR="$(swift build --package-path tools/companion-spike --show-bin-path)"
"$SPIKE_BIN_DIR/TLSBridgeHarness"
"$SPIKE_BIN_DIR/TLSBridgeHarness" --bridge "$PWD/.build/companion-spike/fixture"
```

`SPIKE_TRACE=1` on the harness adds only synthetic relay direction, byte counts and status to stderr. Payloads, certificates and keys are never trace fields. Normal output contains assertion names and booleans. The fixture readiness protocol accepts only one numeric loopback target port; data sent by a client cannot select another destination. See [the C fixture notes](tailscale/README.md) for its limits, source changes and reproduction commands.

## Native security boundary

- `SpikeIdentity` creates ephemeral software P256 keys and self-signed leaf certificates, then a native `SecIdentity`. This deliberately does not satisfy the production Secure Enclave/persistence requirement.
- Trust checks a canonical DER SPKI SHA256 pin, P256/ECDSA-SHA256, self-signature, issuer/subject, validity, CA=false, digital-signature-only usage and an exclusive host/serverAuth or phone/clientAuth role. Unhandled critical extensions and extra chain elements fail closed. No system trust roots are installed or modified.
- Network.framework requires peer authentication on both ends and TLS 1.3 with ALPN `darkbloom-companion/1`. Tickets, resumption and false start are disabled; no PSK/early-data path is configured.
- Native frames have a four-byte big-endian length and a 256 KiB maximum. Header and payload share one monotonic deadline. Eight pending/authenticated native sessions are admitted; cancellation and stop close owned sessions.
- Rejection tests observe actual pin decisions and prove the route works before and after probes. A timeout/cancellation/refused route cannot satisfy the harness rejection predicate.
- Revocation rejects subsequent frames and connections and cancels existing sessions. An already-admitted synthetic transform can finish; production prepared-command revalidation, signed approval, side-effect journaling and uncertain-outcome handling are later tasks.
- The responder is a bounded synchronous synthetic transform, not an arbitrary async operation runner. Fake start/stop changes two in-memory values only. These frames are not a proposed production command API.

## Apple platform checks

The package declares macOS 14 and iOS 17. Building against current SDKs with those deployment targets checks API availability; it does not prove execution on the minimum OS.

From this directory:

```sh
xcodebuild -scheme SpikeCore -destination 'generic/platform=iOS' -derivedDataPath .build/ios-device CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.0 build
xcodebuild -scheme SpikeCore -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios-simulator CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.0 build
xcrun simctl list devices available
```

Choose an available iPhone simulator explicitly and substitute its ID:

```sh
xcodebuild -scheme DarkbloomCompanionSpike-Package -destination "platform=iOS Simulator,id=$COMPANION_SIMULATOR_ID" -derivedDataPath .build/ios-simulator -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.0 test
```

The simulator runs native identity and TLS tests, not the Mac Go subprocess. The earlier feasibility XCFrameworks used Tailscale 1.94.1; their build success does not establish device/simulator compatibility for this updated 1.102.4 candidate.

## Stop point

Task 1 is still open. Before promoting any code or pin into the product: finish the updated C archive slices, physical Secure Enclave/Keychain/native identity proof, iPhone↔Mac enrollment/revocation, actual tailnet authorization, WAN/direct/relay behavior, suspension/resume, network changes, resource measurements, dependency/security review and a production lifecycle/admission design. A physical iPhone was not connected for this checkpoint.

The next concrete implementation unit is a signed, synthetic physical-device harness using the native pinned trust boundary over LAN/external Tailscale. An embedded route must independently clear the recorded reconnect failure before it can replace that route. No provider operations or history migration should be wired into this prototype. The full companion plan remains the source of product requirements.
