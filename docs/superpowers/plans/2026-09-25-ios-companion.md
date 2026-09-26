# iOS Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The main project task owns integration and final verification; use bounded native workers only where work is independent.

**Goal:** Build a cryptographically paired iPhone companion for LAN/remote monitoring, supported settings, provider start/stop/restart, and Mac Control quit/reopen/relaunch while a user-scoped helper remains available.

**Architecture:** An opt-in per-user helper owns collection, histories, device trust, and centralized provider policy. Mac UI uses authenticated XPC; iPhone uses pinned TLS 1.3 with per-device authentication over LAN or a proven Tailscale route. A typed portable protocol isolates iOS from the existing Mac CLI/filesystem code.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Network/Security/CryptoKit, AVFoundation, SQLite, ServiceManagement, existing official CLI adapters; candidate swift-certificates 1.21.0 and pinned libtailscale/TailscaleKit subject to feasibility.

**Spec:** [2026-09-25-ios-companion-design.md](../specs/2026-09-25-ios-companion-design.md). Read its current version before implementation; this plan does not freeze an evolving review draft.

**Evaluation:** [Embedded Tailscale feasibility report](../../research/2026-09-25-embedded-tailscale-feasibility.md), with checked artifact hashes and test scope. Use its final findings instead of treating candidate pins as release-approved dependencies.

**Status:** Research/implementation proposal at `codex/models-window-grid` / `14991f8`. The user confirmed the product scope and embedded-Tailscale evaluation, not every proposed protocol value or implementation phase. This planning assignment authorizes no product implementation, real provider mutation, migration, publication, or tailnet changes. Preserve concurrent documentation/spike work.

## Global Constraints

- Retain macOS 14; proposed iOS floor is 17. Candidate swift-certificates 1.21.0 requires Swift tools 6.1; record the toolchain decision after the spike, without silently raising OS floors.
- TLS 1.3; ALPN `darkbloom-companion/1`; P-256 device identities; canonical DER SPKI SHA-256 pins; explicit client authentication; no accept-all trust, TLS resumption, or early data.
- Phone transport and approval keys are separate, device-only and non-synchronizing; command approval requires device-owner authentication. No production software-key fallback without a new explicit decision.
- Proposed certificate lifetime 90 days; same-key renewal; replacement key requires local pairing. Certificate wall time and host-monotonic command/invitation deadlines are distinct.
- QR `dc-pair:1:`: 256-bit secret, 120-second invitation, at most 2 KiB, one invitation/pending approval, at most five valid-secret attempts; approval occurs locally on Mac.
- Capabilities: `monitor.read`, `provider.lifecycle`, `provider.settings`, `app.lifecycle`; revocation affects existing sessions and prepared commands.
- Proposed prepared-command expiry 60 seconds; signed exact host-issued JSON bytes, domain separated and length prefixed; no `confirmed: true` authorization shortcut. Bind runtime epoch, invalidate unaccepted preparations on helper restart, and use a host clock that includes sleep; accepted drain duration is independent.
- Four-byte big-endian framing; frame maximum 256 KiB; command/preparation maximum 16 KiB; maximum JSON depth 16; 256 models; 168 hourly history buckets per page.
- Eight phones; eight authenticated sessions; one stream per phone; newest-one snapshot buffer; eight aggregate pending TLS/bootstrap connections; 10-second handshake/partial-frame deadline.
- Ten authenticated requests/second per phone, burst 20; five control proposals/minute; one provider mutation at a time, with busy rejection instead of an unbounded queue.
- Audit retention 30 days/10,000 resolved records; unresolved operations are separately retained until reconciliation or explicit local resolution.
- Proposed ports 49443 normal/49444 temporary bootstrap; `_dccompanion._tcp`; explicit LAN/tailnet addresses, no automatic public forwarding/Funnel/wildcard bind.
- Native stop remains `darkbloom stop --timeout 600` with 630-second runner bound; no automatic force kill; save and apply/restart are separate.
- No provider/CLI credentials, raw config, logs, database files, account/provider identifiers, or inference bearer tokens reach the phone.
- Inference hosting stays separate. Exposure increases, authentication disablement and token operations remain local-only; remote download/delete and arbitrary shell/config operations are outside v1.
- Keep one telemetry/history writer and one provider mutation owner; production/Beta histories and identities stay isolated, while mutation ownership spans the same canonical provider/user.
- External Tailscale remains the accepted fallback if embedding fails. A read-only milestone is not completion of the requested product.
- Values labeled proposed are candidate test constants, not evidence of user approval; update both spec and tests when security/feasibility review changes them.

## Review Focus

- A delayed approval after device revocation, changed activity, or config replacement must not dispatch; Task 7 pins preparation revalidation.
- Two app channels or a transient XPC outage must not create two collectors/controllers; Tasks 5–6 pin ownership and handoff.
- Lost command responses and helper crashes must not replay an external side effect; Task 7 pins journal recovery and uncertain outcomes.
- Phone clock jumps, host sleep and route changes must not make old metrics fresh or silently change identity; Tasks 2, 9–10 pin these cases.
- App replacement/update while a remote quit/reopen is pending must preserve drafts and target the verified channel; Tasks 11–12 pin lifecycle leases and bundle identity.

## Ownership and File Map

One integrator owns `Package.swift`, `Package.resolved`, composition changes, signing configuration and final verification. Workers own one task's new files/tests; do not concurrently edit existing stores or the package manifest. Each implementation task ends with a focused reviewed local commit, never an implied push/release.

| Target/path | Responsibility and dependencies |
|---|---|
| `Sources/DarkbloomCompanionProtocol/` | Portable Codable DTOs, typed messages, limits, framing; Foundation only. |
| `Sources/DarkbloomCompanionSecurity/` | Portable Apple-platform keys/certificates, trust and signature verification; protocol plus Security/CryptoKit and reviewed certificate dependency. |
| `Sources/DarkbloomCompanionTransport/` | Portable route abstraction and bounded native TLS sessions; protocol/security, Network framework; no CLI access. |
| `Sources/DarkbloomHostRuntime/` | Mac-only acquisition, history ownership, settings adapters, command policy/journal; existing `DarkbloomTelemetry` plus protocol. |
| `Sources/DarkbloomCompanionHost/` | Mac-only device registry, pairing, sessions, listener and authenticated XPC server; runtime/protocol/security/transport. |
| `Sources/DarkbloomCompanionHelper/` | New Mac executable composition and process lifetime; host/runtime, no AppKit UI or Sparkle. |
| `Sources/DarkbloomMonitor/Companion/` | Mac registration, XPC client, pairing/devices UI and lifecycle endpoint. Existing stores become clients in companion mode. |
| `Apps/DarkbloomCompanion/` | Separate Xcode iOS app and test targets; only portable products; no existing Mac executable/telemetry dependency. |
| `Tests/DarkbloomCompanion{Protocol,Security,Transport,Host}Tests/` | Matching unit/integration suites; temporary fixtures, fake clock/runner, no live provider/config. |
| `Tests/DarkbloomHostRuntimeTests/` | Single-writer handoff, adapters, policy and journal tests. |
| `tools/companion-spike/`, `docs/evidence/ios-companion/` | Isolated feasibility harness and sanitized evidence; never ship test identities or real secrets. |

Runtime fallback uses the same `HostMonitoringService`/policy implementation in-process only when companion is explicitly disabled and ownership is acquired. Preserve the existing `DarkbloomTelemetry` target rather than broadly moving every source to iOS.

## Verification Conventions and Dependency Order

Use an isolated checkout for implementation. Read existing instructions and status first; preserve dirty work. Tasks 1–5 constitute the first feasibility gate, using synthetic state/fake commands only. Stop there before Tasks 6–12 unless their implementation has been explicitly scoped. Each task's test step comes before its implementation; verify an expected failure once, then the passing behavior. No implementation function bodies are prescribed here.

Required Mac regression commands remain `swift test` and `swift build -c release` (`README.md:218–226`). Run focused suites per task; run the complete suite/build at integration gates, not repeatedly without a new reason. Packaging tests: `python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'`. Always check actual discovered test count; zero is not success.

Create shared Xcode scheme `DarkbloomCompanion` with app/unit/UI tests. Discover simulator IDs with `xcrun simctl list devices available`, set `COMPANION_SIMULATOR_ID` to the intended device, then use:

```sh
xcodebuild -project Apps/DarkbloomCompanion/DarkbloomCompanion.xcodeproj -scheme DarkbloomCompanion -destination "platform=iOS Simulator,id=$COMPANION_SIMULATOR_ID" test
xcodebuild -project Apps/DarkbloomCompanion/DarkbloomCompanion.xcodeproj -scheme DarkbloomCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Unsigned builds establish compile coverage only. Physical-device identity, Keychain, local-network permission, QR, cellular, suspension and signed helper behavior require separately recorded hands-on proof.

| Integration gate | Prerequisite and decision |
|---|---|
| A: Transport candidate | Task 1; choose embedded C adapter or external-client fallback before dependency promotion. |
| B: Synthetic secure helper | Tasks 2–5; physical pairing/mTLS/revocation and helper survival, then required implementation stop. |
| C: One host runtime | Task 6 after B; fixtures first, then explicitly scoped real storage ownership handoff. |
| D: Safe controls | Tasks 7–8 after C; fake runner/crash tests before separately scoped provider mutations. |
| E: Native experience | Task 9 follows protocol/security; fixture UI work can overlap C/D but real controls wait for D. |
| F: Remote/app lifecycle | Tasks 10–11 consume B/D/E; run physical routing and exact app targeting proof. |
| G: Release readiness | Task 12 after all earlier gates; approvals/publication remain separate. |

Task 2 defines the complete shared DTO vocabulary before client/server implementation:

- `ControlProposal` is a typed action plus request UUID, expected revision and bounded arguments; it never contains executable or filesystem paths.
- `SignedApproval` contains command UUID, exact retained host payload bytes and signature; the session principal supplies device identity independently.
- `HistoryQuery` contains bounded period/cursor/model selector; `HistoryPage` contains aggregate observations, host time-zone ID, coverage and optional next cursor.
- `RuntimeStates` separately names provider, Mac app, helper and connection observations; `OperationStatus` carries accepted/mutating/reconciling/draining/succeeded/failed/outcomeUncertain states.
- `AppSettingsPatch` is the electricity estimate/rate subset; hosting is a distinct typed patch whose exposure policy is evaluated on the host.
- `PairedHost`, `PeerRouteHints` and `RouteCandidate` contain only public identity/address metadata; persist pins/keys through the security layer, not defaults.
- `PairingInvitation`, `EnrollmentProof`, `PendingEnrollment` and `PairedDevice` have separate bootstrap/public representations; never accidentally encode the host's secret registry record.

Each task's new public API needs a compile-time consumer fixture before its checkpoint. Keep test-only software identities, fake clocks, CLI harnesses and registry rollback injection out of release products.

---

### Task 1: Resolve the embedded transport and native identity feasibility

**Owner/files:** Feasibility worker owns `tools/companion-spike/README.md`, `build-frameworks.sh`, `TLSBridgeHarness.swift`, `SpikePhone/`, `SpikeHost/`, and `docs/evidence/ios-companion/feasibility.md`; no production source edits.
**Consumes:** Spec sections 3/5; candidate libtailscale revision `59d4bb82744915815178e0f0776d60026a397ee7`, certificate tag `1.21.0`; record resolved transitive revisions/Go version instead of assuming the candidate is current/safe.
**Produces:** A go/no-go matrix for Mac 14/iOS 17, device/simulator/Mac frameworks, native `SecIdentity` handshake, and a bounded inner-TLS byte bridge; exact dependency/toolchain decision for Task 3.

**Observed during planning:** The spike built Mac arm64, iOS device arm64, and simulator arm64/x86_64 archives/frameworks; Mach-O reports minimum macOS 14/iOS 17. Upstream `TestConn` and a reverse-traffic extension passed against synthetic local control/DERP, with cleanup checks. The supplied Swift listener/incoming APIs nevertheless declare macOS 15/iOS 18 availability, with asymmetric send-only/receive-only wrappers. `TailscaleNode.down()` calls `tailscale_up()` at this pin. Use a bounded C API file-descriptor adapter and audit shutdown/resume. The pinned Tailscale `v1.94.1` is behind current releases/security fixes and is not approved for shipment. Native mTLS bridging, signed hardware, WAN and minimum-OS runtime behavior remain unproven; preserve that distinction.

- [ ] Record clean baseline, license/dependency constraints and source hashes in evidence; update/review the underlying Tailscale dependency and applicable bulletins before promotion. Read pinned build instructions before issuing commands.
- [ ] Add named harness assertions `nativeIdentityRoundTrip`, `wrongSPKIRejected`, `missingClientCertificateRejected`, and `bridgeCannotDialArbitraryDestination`; verify deliberate wrong identities fail before the positive path.
- [ ] Build all required XCFramework slices from pinned source with the documented script; inspect architecture/platform metadata using `xcrun vtool -show-build` and record actual minimum OS requirements.
- [ ] Prove `SecKey → certificate → Keychain SecIdentity → Network.framework TLS` using hardware keys on physical devices; run the harness with no provider credentials and synthetic telemetry.
- [ ] Exercise full-duplex C API `dial`/`listen` descriptors through a single-destination loopback bridge carrying encrypted TLS bytes; prove raw loopback traffic still requires mTLS, bounded buffers, cancellation and half-close behavior. Add `adapterStopClosesOwnedDescriptorsAndNode`, descriptor lifetime/ownership and concurrent shutdown tests; there is no C `tailscale_down` export. Do not adopt the unmodified Swift stream wrappers.
- [ ] Add `blockedLoginAndDialActuallyTerminate` and `authURLNeverEntersLocalOrUploadedLogs`. At the tested pin, `Logf` suppression leaves `UserLogf` and its authorization-URL output intact, and Swift cancellation does not cancel an unbounded Go context. Resolve through updated upstream APIs or narrow reviewed Go/C changes; preserve source patches in the dependency manifest. Test initial login using in-memory status `AuthURL` before requiring a loopback HTTP/IPN bus.
- [ ] Record interactive node authorization/revocation, foreground resume, Wi-Fi/cellular transition, direct/relay fallback, memory/reconnect/network measurements and unresolved physical-device gaps. Obtain user participation where device login/approval is required; do not invent success from a simulator.
- [ ] Run the recorded harness entry commands from `tools/companion-spike/README.md`; expected result is a per-case pass/fail/blocked matrix with artifact hashes, not a universal green claim. Preserve a failed candidate as evidence.
- [ ] Review embedding against external-client fallback; stop for a concrete compatibility/product decision if embedding raises the OS floor, needs unsupported security exceptions, or cannot carry native mTLS. Checkpoint only the bounded harness/evidence.

### Task 2: Establish the portable wire contract and bounds

**Files:** Create `Sources/DarkbloomCompanionProtocol/{Messages,CompanionSnapshot,SettingsContract,CommandContract,ProtocolLimits,FrameCodec}.swift`; matching `Tests/DarkbloomCompanionProtocolTests/{FrameCodec,Contract,SnapshotPrivacy}Tests.swift`; integrator updates package products/tests.
**Interfaces:** `FrameDecoder.append(_ bytes: Data) throws -> [Envelope]`; `FrameEncoder.encode(_ envelope: Envelope) throws -> Data`; `CompanionSnapshot(hostID: UUID, runtimeEpoch: UUID, sequence: UInt64, generatedAt: Date, observations: [MetricObservation], models: [ModelSummary], states: RuntimeStates)`.
**Shared types:** `Envelope` carries major/type/request UUID/typed payload; `MetricObservation` carries optional value/unit/scope/provenance/source timestamp/source age/availability/safe reason; `SettingsSnapshot`, `SettingsPatch`, `PreparedCommand`, `OperationStatus`, `Capability`, and `ControlProposal` are closed DTO enums/structs, not raw dictionaries.

- [ ] Add `rejectsOversizedAndPartialFrames`, `rejectsDuplicateSecurityKeysAndDepth17`, `rejectsUnknownMajorAndCommand`, `omitsSecretCanaries`, `boundsModelsAndHistoryPage`, and `preservesStaleCaptureTime` with spec limits and no secrets in encoded bytes.
- [ ] Run `swift test --filter DarkbloomCompanionProtocolTests`; confirm each new assertion fails for its missing behavior, then implement DTOs and bounded framing. Decode duplicate-sensitive keys before lossy dictionary materialization.
- [ ] Define exact message cases for enrollment, monitor subscription/history, settings draft/patch/save, prepare/confirm/operation query, device management and typed safe error responses; bootstrap accepts enrollment cases only.
- [ ] Define command `requestID`, opaque draft/revision, signed-payload byte field and operation identifiers; add golden protocol fixtures and major-version rejection, allowing additive optional observation fields only under the documented version rule.
- [ ] Re-run the focused suite; assert no failed tests, no arbitrary class decoding, newest-one stream semantics covered by transport integration later. Commit protocol/schema fixtures as one checkpoint.

### Task 3: Implement device identity and native trust

**Files:** Create `Sources/DarkbloomCompanionSecurity/{DeviceIdentityStore,CertificateProfile,PeerTrustEvaluator,CommandApprovalKey,IdentityRecovery}.swift`; `Sources/DarkbloomCompanionTransport/{TLSConfiguration,SecureSession,TransportConnection}.swift`; security/transport tests. Integrator pins approved dependencies and tools version in `Package.swift`/`Package.resolved`.
**Interfaces:** `DeviceIdentityStore.loadOrCreate(role: DeviceRole, namespace: String) async throws -> DeviceIdentity`; `PeerTrustEvaluator.evaluate(_ trust: SecTrust, expected: PeerIdentity, role: DeviceRole, now: Date) throws`; `CommandApprovalKey.sign(_ payload: Data, reason: String) async throws -> Data`; `SecureSession.messages() -> AsyncThrowingStream<Envelope, Error>`.
**Boundary:** `PeerIdentity` contains stable device ID, SPKI pin and expected role; `DeviceIdentity` retains private Security references locally. `TransportConnection` is a bounded byte stream with `send(_:)`, `receive()`, `close()`; network routes never supply authorization.

- [ ] Add `rejectsWrongRoleExpiredOrMalformedCertificate`, `rejectsMissingClientCertificate`, `rejectsChangedKeyOnRenewal`, `requiresOwnerAuthenticationForApprovalOnly`, `missingKeyRequiresRecovery`, and `revokedIdentityCannotResumeSession`.
- [ ] Run `swift test --filter 'DarkbloomCompanion(Security|Transport)Tests'` to establish failures; implement validated peer-specific trust, canonical SPKI pinning, explicit client authentication, TLS 1.3/ALPN, no early data/resumption.
- [ ] Implement device-only Keychain access groups/namespaces and safe same-key certificate renewal. Simulator-only software keys must be impossible in a production configuration; corrupt existing identity fails closed rather than silently regenerating.
- [ ] Test certificate wall-clock validity independently from injected monotonic invitation/command clocks; log only fixed safe reasons, never certificate private material or secrets.
- [ ] Re-run focused suites plus device identity harness; record real phone unlock and host first-unlock/lock behavior. Commit only after dependency and native-identity proof match the chosen deployment floors.

### Task 4: Pair devices and enforce live capabilities

**Files:** Create `Sources/DarkbloomCompanionHost/{PairingCoordinator,DeviceRegistry,SessionRegistry,CompanionListener}.swift`; `Tests/DarkbloomCompanionHostTests/{Pairing,Revocation,SessionLimits}Tests.swift`; Mac fixture QR view and iOS fixture scanner under spike directories.
**Interfaces:** `PairingCoordinator.beginInvitation() async throws -> PairingInvitation`; `submit(_ proof: EnrollmentProof) async throws -> PendingEnrollment`; `approve(_ id: UUID, capabilities: Set<Capability>) async throws -> PairedDevice`; `DeviceRegistry.revoke(_ deviceID: UUID) async throws`; `authorize(deviceID: UUID, capability: Capability, policyEpoch: UInt64) async throws`.
**Consumes:** Task 2 bounded invitation/proof DTOs; Task 3 pinned bootstrap TLS, identity proof and authenticated normal sessions. Enrollment proof binds invitation, fresh nonce and both phone public keys.

- [ ] Add `wrongPinNeverSendsSecret`, `bootstrapCannotReadOrControl`, `expiresAt120SecondsDespiteClockChange`, `onlyOneConcurrentApprovalWins`, `fifthAttemptClosesInvitation`, `lostFinalResponseReconnectsWithoutReuse`, and `revocationClosesStreamAndInvalidatesPreparation`.
- [ ] Add `registryRollbackEpochMismatchFailsClosed` and `resourceCapsBeforeAuthentication`; verify eight pending connections and 10-second incomplete-handshake deadline are aggregate bounds, not per-untrusted-name allowances.
- [ ] Run `swift test --filter DarkbloomCompanionHostTests`; implement single-use enrollment, local approval/comparison transcript, persistent device capabilities and Keychain-bound policy epoch reconciliation.
- [ ] Implement normal-listener authorization on every message/publication, per-phone limits and bounded newest-one subscription; revocation cancels session access immediately and reports recovery on registry corruption.
- [ ] Re-run tests and physical QR fixture proof; check cancellation, replacement QR, helper restart and no persisted/logged secret or QR image. Commit pairing/session checkpoint.

### Task 5: Prove opt-in helper, authenticated XPC and ownership with fixtures

**Files:** Create `Sources/DarkbloomCompanionHelper/CompanionHelperMain.swift`, `Sources/DarkbloomCompanionHost/{CompanionXPCProtocol,CompanionXPCServer,PeerCodeRequirement}.swift`, `Sources/DarkbloomHostRuntime/{RuntimeOwnership,ProviderMutationOwnership}.swift`, `Sources/DarkbloomMonitor/Companion/{CompanionRegistrationStore,CompanionXPCClient}.swift`, `Resources/LaunchAgents/dev.darkbloom.monitor.companion.plist`; helper/ownership tests; modify package and fixture packaging only.
**Interfaces:** `RuntimeOwnership.acquire(namespace: String) throws -> OwnershipLease`; `ProviderMutationOwnership.acquire(provider: CanonicalProviderIdentity) throws -> OwnershipLease`; `CompanionXPCProtocol.exchange(_ message: Data, reply: @escaping (Data) -> Void)` uses Task 2 bounds/types; `CompanionRegistrationStore.enable() async throws -> RegistrationState`.
**Boundary:** XPC validates exact signed team/bundle/channel and user on both peers before decoding or dispatch; never trust PID/name alone. Production and Beta use distinct agent/XPC/storage names; provider mutation lock identity is shared for the same canonical provider.

- [ ] Add `wrongSignedPeerOrChannelRejected`, `secondRuntimeOwnerRejected`, `betaCannotClaimProductionProvider`, `deniedRegistrationStaysDisabled`, and `xpcLossDoesNotStartFallbackCollector`; first run `swift test --filter 'DarkbloomCompanionHostTests|DarkbloomHostRuntimeTests'` to establish failures.
- [ ] Implement registration state/approval UX, typed fixture XPC, process-held locks and signed helper fixture. Use synthetic monitoring and a fake command runner exclusively.
- [ ] Prove helper remains reachable when the fixture Mac UI exits, restarts safely after an intentional fixture crash, and unregisters only its own service; record signed identity and agent status.
- [ ] Run protocol/security/host suites, full existing `swift test`, `swift build -c release`, and signed LAN/embedded-device fixture proof. Inspect actual rendered pairing UI.
- [ ] **First required implementation stop:** present identities/mTLS/QR/revocation, signed helper survival and embedded/fallback verdict. List physical proof gaps. Stop before real provider mutations, histories/preferences migration or publication. Commit this verified synthetic milestone only.

### Task 6: Extract host monitoring and migrate one writer

**Files:** Create `Sources/DarkbloomHostRuntime/{HostMonitoringService,HostSnapshotProjector,HostPreferencesStore,RuntimeHandoff,HostResourceSampler}.swift`; `Tests/DarkbloomHostRuntimeTests/{Monitoring,Handoff,HistoryMigration}Tests.swift`. Modify `DarkbloomMonitorApp.swift`, `MonitorStore.swift`, `MonitorApplicationIdentity.swift`, `Dashboard/ProviderResourcesView.swift`, CPU/GPU stores and energy/history composition, scoped to ownership delegation.
**Interfaces:** `HostMonitoringService.start() async throws`, `stopAndFlush() async throws`, `snapshots() -> AsyncStream<CompanionSnapshot>`, `history(_ query: HistoryQuery) async throws -> HistoryPage`; `RuntimeHandoff.enableHelper() async throws -> RuntimeOwner`, `disableHelper() async throws -> RuntimeOwner`; `HostPreferencesStore.apply(_ patch: AppSettingsPatch, expectedRevision: String) async throws -> SettingsSnapshot`.
**Consumes:** Locks/XPC from Task 5; existing `TelemetryService`, database actors, earnings client, extras and resource samplers. Phone never imports or instantiates those adapters.

- [ ] Add `handoffClosesWritersBeforeReadiness`, `failedHandoffNeverDualCollects`, `historyValuesCoverageAndTimezonePreserved`, `helperUsesParentPreferencesNamespace`, `gpuUnavailableIsOmitted`, `accountEarningsNeverLabeledLocalMeasuredIncome`, and `twoSubscribersDoNotDoubleRecord`.
- [ ] Run `swift test --filter DarkbloomHostRuntimeTests` for expected failures; implement host collection/projection with original cadence, coverage, provenance and whole-Mac CPU/GPU scope. Optional collection follows subscriptions/settings without polling CLI per request.
- [ ] Move canonical collection preferences and CPU/GPU sampling out of view lifetime; snapshot generation must include earnings/model summaries without exposing account identifiers or raw diagnostics.
- [ ] Implement explicit quiesce/flush/close/release/acquire/readiness handshake. Keep existing files and backwards-compatible schemas; do not copy a live database or start fallback on ambiguous XPC failure.
- [ ] Verify migration with temp copies/fixtures before an explicitly authorized live handoff. Re-run focused tests, full Mac suite/build and visible Mac dashboard regression; commit extraction/migration with rollback evidence.

### Task 7: Centralize policy, command approval and durable operations

**Files:** Create `Sources/DarkbloomHostRuntime/{ProviderCommandCoordinator,PreparedCommandStore,OperationJournal,CommandRecovery,EditLeaseRegistry}.swift`; `Tests/DarkbloomHostRuntimeTests/{CommandPolicy,OperationJournal,EditLease}Tests.swift`; modify `ProviderControlStore.swift` and helper dispatch to use coordinator.
**Interfaces:** `prepare(_ proposal: ControlProposal, principal: Principal) async throws -> PreparedCommand`; `confirm(_ approval: SignedApproval, principal: Principal) async throws -> OperationStatus`; `operation(_ id: UUID, principal: Principal) async throws -> OperationStatus`; `reconcilePending() async`; `Principal` is verified local XPC identity or enrolled phone identity, never request-supplied.
**Contract:** `PreparedCommand` retains exact signed payload bytes/nonce/revision/risks/policy epoch/deadline; `OperationJournal` uniquely keys `(deviceID, requestID)` and command ID, stores dispatch intent before external side effect, and tracks unresolved work separately from retention-limited audit.

- [ ] Add `changedRiskRequiresNewPreparation`, `revokedCapabilityBeforeDispatchRejected`, `modifiedSignedBytesRejected`, `expiredApprovalRejected`, `sleepAndHelperRestartInvalidateOldPreparation`, `duplicateLostResponseReturnsSameOperation`, `sameIDChangedPayloadRejected`, and `crashAfterDispatchIntentNeverAutomaticallyReruns`.
- [ ] Add `dirtyMacDraftBlocksRemoteWrite`, `conflictingPhoneDraftPreservesBoth`, `manualFileReplacementConflicts`, and `auditRetentionPreservesUnresolvedOperations`; run `swift test --filter DarkbloomHostRuntimeTests` to verify failures.
- [ ] Implement capability/policy/freshness revalidation inside one mutation coordinator; local UI cannot bypass it. Separate app lifecycle lane from provider mutation lane; return busy rather than queueing arbitrary work.
- [ ] Persist operation acceptance/intent/result with crash-consistent transactions. Phone disconnect/UI exit detaches observers only; accepted work survives. Post-restart reconciliation uses authoritative observations and can report outcome uncertain.
- [ ] Implement opaque helper-owned draft handles retaining original `ProviderConfigDraft.sourceFileState`; apply typed patches to those objects, never reconstructed wire drafts. Conflict resolution requires a new revision/explicit user decision.
- [ ] Re-run policy/journal fault-injection tests and existing config/control cancellation tests; commit coordinator only after stale approval, replay and crash cases have concrete assertions.

### Task 8: Route supported options and provider lifecycle through host policy

**Files:** Create `Sources/DarkbloomHostRuntime/{ProviderSettingsAdapter,ProviderLifecycleAdapter,HostingExposurePolicy}.swift`; `Tests/DarkbloomHostRuntimeTests/{SettingsAdapter,LifecycleAdapter,HostingExposure}Tests.swift`; modify `ProviderControlService.swift`, `ProviderExtrasStore.swift`, `HostingSettingsStore.swift`, `ProviderControlStore.swift` to remove authoritative UI-only gates while preserving presentation.
**Interfaces:** `ProviderSettingsAdapter.snapshot() async throws -> SettingsSnapshot`; `apply(_ patch: SettingsPatch, to draftID: UUID, expectedRevision: String) async throws -> SettingsSnapshot`; `ProviderLifecycleAdapter.execute(_ action: ProviderLifecycleAction, context: AuthorizedCommandContext) async -> OperationStatus`. Only Task 7 constructs `AuthorizedCommandContext`.
**Supported settings:** Model enable/preload, positive slots, concurrency 1...24, idle 0...10080, three existing beta flags with capability/tri-state support, electricity settings, and exposure-nonincreasing remote hosting changes.

- [ ] Add `preloadRequiresEnabled`, `preservesValidLargeSlotValue`, `rejectsConcurrency25AndIdle10081`, `betaAutoNotConvertedToFalse`, `remoteCannotIncreaseHostingExposureOrReadToken`, and `saveDoesNotImplicitlyRestart`.
- [ ] Add `stopUses600SecondNativeDrainAnd630Bound`, `zeroRemainingAwaitingUsageNotStopped`, `startupRequiresFreshProviderEvidence`, `timeoutReconcilesRatherThanForceKills`, and `extrasAndLifecycleCannotOverlap`; run the focused runtime suite for failures.
- [ ] Reuse official CLI/config adapters and existing transactional file validation. Promote hosting version/interface checks and active-work/model-comparison policy into host authority; keep tokens/config text exclusively host-side.
- [ ] Move UI error-path reconciliation/startup observation into host lifecycle adapter; preserve start/restart semantics, drain outcomes and explicit uncertain results. No generic command execution, downloads/deletes, reserve/fan setters or updater commands.
- [ ] Re-run focused tests and existing control/config/extras/hosting suites. Exercise fixture CLI end-to-end before separately authorized real-provider idle/active drain proof; commit supported controls with remaining live-proof limits stated.

### Task 9: Build the iPhone monitoring, settings and operation experience

**Files:** Create `Apps/DarkbloomCompanion/DarkbloomCompanion.xcodeproj/project.pbxproj`, shared `DarkbloomCompanion.xcscheme`, `App/{CompanionApp,CompanionStore,PairedHostStore}.swift`, `Pairing/PairingScannerView.swift`, `Views/{HostsView,OverviewView,ModelsView,SettingsView,OperationView,CommandConfirmationView,HostDetailView}.swift`, `Resources/{Info.plist,Assets.xcassets}`, unit/UI test files and entitlements.
**Interfaces:** `CompanionStore.connect(to hostID: UUID) async`, `disconnect() async`, `submit(_ proposal: ControlProposal) async throws -> PreparedCommand`, `approve(_ prepared: PreparedCommand) async throws -> OperationStatus`; connection uses Task 3 sessions and Task 10 routing.
**Consumes:** Task 2 DTOs/availability; no host credential, filesystem, raw CLI or native Mac target imports. Views display exact verified command payload and sign those retained bytes after device-owner authentication.

- [ ] Add `clockJumpCannotFreshenSnapshot`, `backgroundResumesWithNewSnapshot`, `deniedCameraAndLANPermissionRecover`, `confirmationShowsExactSignedAction`, `lostReplyQueriesOperationWithoutRetry`, and `unavailableMetricsOmittedButErrorsActionable`.
- [ ] Add UI checks for separate provider/app/helper/connection states, saved-versus-applied settings, active/draining/uncertain operations, beta auto state, Dynamic Type/VoiceOver and unavailable control reasons.
- [ ] Run the iOS unit/UI scheme to establish failures; implement fixture-backed layouts and connection lifecycle, scanner-only enrollment and Keychain-backed paired-host metadata. No arbitrary externally supplied deep-link enrollment.
- [ ] Implement foreground refresh and background stream suspension; do not promise persistent background dashboards/push alerts. Bind settings drafts/conflicts and operation approval to their actual host/device identities.
- [ ] Run both Xcode commands above; inspect rendered iPhone and iPad-compatible layout as applicable at large text sizes, then physical-device QR/owner-auth proof. Review visual design before calling UI accepted; commit the native client milestone.

### Task 10: Integrate the chosen LAN and Tailscale routes

**Files:** Create `Sources/DarkbloomCompanionTransport/{CompanionRoute,RouteResolver,DirectLANRoute,EmbeddedTailscaleRoute,TLSLoopbackBridge,RouteRecovery}.swift`, transport tests; `Apps/DarkbloomCompanion/Views/ConnectivityView.swift`; Mac connectivity settings; approved vendored framework/build manifest only if Task 1 passes.
**Interfaces:** `CompanionRoute.connect(to peer: PeerRouteHints) async throws -> TransportConnection`; `RouteResolver.resolve(_ host: PairedHost) async throws -> [RouteCandidate]`; `RouteRecovery.events() -> AsyncStream<RouteState>`. Route selection never alters Task 3 enrolled pin or capabilities.
**Decision:** Promote embedded route only with physical proof; external-client mode connects to configured tailnet addresses using the same mTLS/session path. No product-owned relay is introduced.

- [ ] Add `spoofedBonjourCannotReplacePin`, `selectedInterfaceLossStopsListener`, `ipv6AndDHCPChangePreserveIdentity`, `bridgeBoundsBackpressureAndDestination`, `revokedTailnetNodeDoesNotReenroll`, and `resumeDoesNotRepeatCommand`.
- [ ] Run `swift test --filter DarkbloomCompanionTransportTests` to verify failures; implement bounded direct/embedded adapters, authenticated route-hint updates and explicit connection states. Never broaden a missing interface to wildcard exposure.
- [ ] Add declared Bonjour/camera/local-network explanations and precise registration/connectivity recovery copy. Embedded node state is private, excluded from backup/logs; enrollment remains interactive with no bundled reusable auth key.
- [ ] Re-run tests plus real phone LAN-to-cellular, relay fallback, IPv6, sleep/lock and background-resume matrix. Record external VPN conflict separately from embedded node authorization failure.
- [ ] Stop promotion if security equivalence or target floors fail; keep accepted external-Tailscale fallback and publish a truthful limitation in local docs. Checkpoint transport, pinned build provenance and measured behavior.

### Task 11: Implement safe Mac app lifecycle and companion settings

**Files:** Create `Sources/DarkbloomHostRuntime/{MacAppLifecycleCoordinator,RegisteredAppIdentity}.swift`; `Sources/DarkbloomMonitor/Companion/{MacLifecycleEndpoint,CompanionSettingsView,PairedDevicesView,PairingQRCodeView}.swift`; lifecycle/identity tests; modify `DarkbloomMonitorApp.swift`, `MonitorStore.swift`, `StatusItemController.swift`, `ControlAppUpdater.swift` integration only.
**Interfaces:** `MacAppLifecycleCoordinator.prepare(_ action: AppLifecycleAction) async throws -> AppLifecycleReadiness`; `execute(_ action: AppLifecycleAction, context: AuthorizedCommandContext) async -> OperationStatus`; `MacLifecycleEndpoint.requestQuit(expectedInstance: UUID, expectedLeaseRevision: UInt64) async -> QuitDecision`.
**Boundary:** Open uses verified containing bundle URL/exact channel; quit/relaunch uses authenticated registered instance, matching readiness revision, clean drafts, no pending local confirmation/updater conflict. No process-name/PID-only trust, force kill or caller-selected path.

- [ ] Add `dirtyDraftRefusesQuit`, `changedLeaseAfterPreparationRefusesQuit`, `unresponsiveAppIsNotKilled`, `betaRequestCannotTargetProduction`, `bundleReplacementRequiresRevalidation`, and `quitDuringProviderDrainKeepsHelperOperationAlive`.
- [ ] Run `swift test --filter DarkbloomHostRuntimeTests` for failures; implement separate journaled app lane and acknowledged UI detachment, then exact-bundle reopen/readiness reconciliation.
- [ ] Replace app termination cancellation of helper-owned work with subscription detachment; preserve local in-process mode shutdown semantics. Integrate updater readiness/version compatibility without silently unregistering active helper work.
- [ ] Implement Mac helper registration/approval states, QR local approval, device capability removal/revocation, and local-only exposure/token settings; inspect actual rendered Mac UI.
- [ ] Re-run Mac tests/build and signed fixture remote quit/reopen during long fake drain; only then perform approved live app lifecycle proof after establishing draft safety. Commit lifecycle/settings integration.

### Task 12: Package, recover, and verify the complete product

**Files:** Modify `tools/package_app.py`, existing packaging tests, `docs/{RELEASING,REVIEW_LAUNCH,ARCHITECTURE,TELEMETRY_CONTRACT}.md`; create `docs/COMPANION_OPERATIONS.md`, `Tests/DarkbloomCompanionHostTests/RecoveryTests.swift`, `.github/workflows/companion.yml`, helper signing/entitlement inputs and sanitized evidence checklist under `docs/evidence/ios-companion/`.
**Produces:** Reproducible local signed Beta/helper artifact identity, pinned dependency inventory, CI Mac/iOS compile/test lanes, version-compatible update/rollback procedure and a complete acceptance matrix. iOS TestFlight/App Store and Mac Sparkle publication remain separate release actions.

- [ ] Add `bundleContainsOnlyIntendedHelperAndAgent`, `helperSigningRequirementMatchesChannel`, `incompatibleHelperVersionDisablesControls`, `rollbackWaitsForOwnershipRelease`, `corruptOrRolledBackRegistryRequiresRepair`, and `uninstallDoesNotStopProviderOrEraseHistory`.
- [ ] Run new packaging/recovery assertions for expected failures; extend assembly and inside-out signing verification for helper/agent/frameworks. Include all shipped resources in manifest and retain separate Beta/prod namespace/code requirements.
- [ ] Define helper update compatibility handshake and active-operation handling; an old UI must fail clearly rather than bypassing helper policy. Test helper disabled in System Settings, missing key, expired certificate, agent restart and app-bundle relocation/replacement.
- [ ] Add CI exact toolchain/target matrix and simulator fixtures without live credentials; retain full `swift test`, release build and Python packaging tests, plus iOS simulator/device compile coverage and fuzz/resource-bound regressions.
- [ ] Run acceptance matrix: real LAN/cellular pairing/revocation, control signature/replay attacks, fresh startup and graceful drain, competing drafts, external config edit, one history writer, app quit/reopen, large text/accessibility, update recovery. Record each artifact/OS/device/result and unresolved gap.
- [ ] Review source and outside-model findings independently; correct substantive issues, then rerun affected tests. No physical device, security or control proof may be replaced by a successful build.
- [ ] Commit coherent verified implementation checkpoints and present release readiness/remaining blockers. Do not publish, push, enroll production tailnets or enable the production helper merely because checks passed.

## Rollback and Handoff

1. Disable new remote admissions and invalidate pending prepared commands; do not pretend an accepted provider action can be undone by disconnecting.
2. Finish or reconcile accepted operations, preserve journal/uncertain outcomes and establish no active storage writer before ownership changes.
3. Unregister only the verified owned helper; confirm process-held lock release. Never delete the lock or kill unrelated provider/Control processes to force progress.
4. Reacquire runtime ownership in the explicit companion-disabled app mode; use preserved original history/preferences schemas. If ownership or identity is uncertain, stop and offer local repair without dual collection.
5. Keep provider configuration and history intact; do not restore point-in-time copies over live writers. A pre-helper app downgrade is unsafe while a helper still owns runtime/commands.

At every handoff include branch/commit, changed files, dependency pins, exact artifact identity, passed commands, physical proof and gaps, active helper/listener/operation state, and next permitted task. The first implementation handoff ends at Task 5; subsequent tasks need their own concrete execution scope. Final completion includes all requested controls and a reachable helper, not merely read-only status or a successful embedded framework build.
