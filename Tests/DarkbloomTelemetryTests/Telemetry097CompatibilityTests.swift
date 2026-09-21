import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Darkbloom 0.9.7 telemetry compatibility")
struct Telemetry097CompatibilityTests {
    @Test("decodes advertised set, coordinator, authorization presence, and bounded slot failures")
    func decodesCurrentStateAdditions() throws {
        let data = Data(#"""
        {
          "schema": 1,
          "version": "0.9.7",
          "current_model": "Bonsai",
          "warm_models": ["Bonsai"],
          "advertised_models": ["Bonsai", "Qwen"],
          "coordinator_url": "wss://api.darkbloom.dev/ws/provider",
          "stats": {"tokens_generated": 4, "requests_served": 1, "usage_gaps": 0},
          "trust": {
            "trust_level": "hardware",
            "status": "online",
            "reason": "same_binary",
            "received_at": 995,
            "authorization": {
              "protocol": 1,
              "app_attest_available": true,
              "path": "app_attest",
              "expires_at": 1001,
              "mdm_removal_ready": false,
              "reason": "customer prose is not a UI code",
              "session_id": "private-session",
              "machine_id": "private-machine"
            }
          },
          "capacity": {"total_memory_gb": 64, "gpu_memory_active_gb": 1, "gpu_memory_cache_gb": 0},
          "slots": [
            {
              "model": "Bonsai",
              "mtp_active": false,
              "mtp_enabled": true,
              "mtp_inactive_reason": "config_disabled",
              "kv_backend": "contiguous",
              "kv_backend_requested": "paged",
              "kv_backend_fallback_reason": "kernel_preflight: private detail"
            },
            {
              "model": "Qwen",
              "load_error": "Insufficient memory at /Users/private/path"
            }
          ],
          "last_model_load_error": {
            "model": "Qwen",
            "message": "Insufficient memory at /Users/private/path",
            "at": 994
          },
          "inference_active": false,
          "started_at": 900,
          "written_at": 995,
          "pid": 42,
          "process_identity": {"pid": 42, "start_time_micros": 1234}
        }
        """#.utf8)

        let state = try DaemonStateParser.parse(data)
        #expect(state.advertisedModels == ["Bonsai", "Qwen"])
        #expect(state.coordinatorURL == "wss://api.darkbloom.dev/ws/provider")
        #expect(state.trust.authorization?.protocolVersion == 1)
        #expect(state.trust.authorization?.sessionIDPresent == true)
        #expect(state.trust.authorization?.machineIDPresent == true)
        #expect(state.trust.authorization?.reason == "unknown")
        #expect(state.slots == [ModelSlot(
            model: "Bonsai",
            mtpEnabled: true,
            mtpActive: false,
            mtpReason: "config_disabled",
            kvBackend: "contiguous",
            requestedKVBackend: "paged",
            kvFallbackReason: "kernel_preflight"
        )])
        #expect(state.modelLoadFailures == [ModelLoadFailure(
            model: "Qwen",
            code: .insufficientMemory,
            occurredAt: 994
        )])
    }

    @Test("status parser accepts current idle and authorization output without identifiers")
    func parsesCurrentStatusOutput() {
        let status = StatusParser.parse("""
        darkbloom 0.9.7
        Memory when idle: keep loaded
        Authorization: Serving through legacy verification
          → Keep the Darkbloom MDM profile.
          → customer-specific coordinator prose must not be retained
          → MACHINE ID: private-machine
        """)

        #expect(status.memoryWhenIdle == "keep loaded")
        #expect(status.authorization == "Serving through legacy verification")
        #expect(status.authorizationAdvice == ["Keep the Darkbloom MDM profile."])
    }

    @Test("verification requires fresh state, matching process and coordinator, and a complete lease")
    func evaluatesAuthorizationReadiness() {
        let state = sampleState()
        let now = Date(timeIntervalSince1970: 1_000)
        let verified = ProviderVerification.evaluate(
            state: state,
            expectedCoordinator: "https://api.darkbloom.dev",
            now: now,
            liveProcessIdentity: state.processIdentity
        )
        #expect(verified.state == .verified)
        #expect(verified.title == "App Attest verified")
        #expect(verified.detail.contains("session") == false)
        #expect(verified.detail.contains("machine") == false)

        let staleState = state.replacing(writtenAt: 989)
        #expect(ProviderVerification.evaluate(
            state: staleState,
            expectedCoordinator: "https://api.darkbloom.dev",
            now: now,
            liveProcessIdentity: state.processIdentity
        ).state == .stale)

        let wrongProcess = ProviderVerification.evaluate(
            state: state,
            expectedCoordinator: "https://api.darkbloom.dev",
            now: now,
            liveProcessIdentity: ProcessIdentity(pid: 43, startTimeMicros: 1234)
        )
        #expect(wrongProcess.state == .wrongProcess)

        let expired = state.replacing(authorization: ProviderAuthorizationStatus(
            protocolVersion: 1,
            appAttestAvailable: true,
            path: "app_attest",
            expiresAt: 999,
            sessionIDPresent: true,
            machineIDPresent: true
        ))
        #expect(ProviderVerification.evaluate(
            state: expired,
            expectedCoordinator: "https://api.darkbloom.dev",
            now: now,
            liveProcessIdentity: state.processIdentity
        ).state == .expired)
    }

    @Test("legacy hardware trust remains distinguishable from unconfirmed App Attest")
    func identifiesLegacyTrust() {
        let state = sampleState().replacing(authorization: .some(nil))
        let result = ProviderVerification.evaluate(
            state: state,
            expectedCoordinator: "wss://api.darkbloom.dev/ws/provider",
            now: Date(timeIntervalSince1970: 1_000),
            liveProcessIdentity: state.processIdentity
        )
        #expect(result.state == .legacy)
    }

    @Test("malformed coordinator values never self-match")
    func rejectsMalformedCoordinator() {
        let state = sampleState().replacing(coordinatorURL: "not a URL")
        let result = ProviderVerification.evaluate(
            state: state,
            expectedCoordinator: "not a URL",
            now: Date(timeIntervalSince1970: 1_000),
            liveProcessIdentity: state.processIdentity
        )
        #expect(result.state == .wrongCoordinator)
        #expect(result.coordinatorMatches == false)
    }

    private func sampleState() -> DaemonState {
        DaemonState(
            schema: 1,
            version: "0.9.7",
            currentModel: "Bonsai",
            warmModels: ["Bonsai"],
            stats: ProviderStats(tokensGenerated: 1, requestsServed: 1, usageGaps: 0),
            trust: TrustState(
                level: "hardware",
                status: "online",
                reason: "same_binary",
                receivedAt: 995,
                authorization: ProviderAuthorizationStatus(
                    protocolVersion: 1,
                    appAttestAvailable: true,
                    path: "app_attest",
                    expiresAt: 1_001,
                    sessionIDPresent: true,
                    machineIDPresent: true
                )
            ),
            capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 1, gpuMemoryCacheGB: 0),
            slots: [],
            inferenceActive: false,
            startedAt: 900,
            writtenAt: 995,
            pid: 42,
            processIdentity: ProcessIdentity(pid: 42, startTimeMicros: 1234),
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider"
        )
    }
}

private extension DaemonState {
    func replacing(
        writtenAt: TimeInterval? = nil,
        authorization: ProviderAuthorizationStatus?? = nil,
        coordinatorURL: String? = nil
    ) -> DaemonState {
        let newAuthorization: ProviderAuthorizationStatus?
        if let authorization {
            newAuthorization = authorization
        } else {
            newAuthorization = trust.authorization
        }
        return DaemonState(
            schema: schema,
            version: version,
            currentModel: currentModel,
            warmModels: warmModels,
            stats: stats,
            trust: TrustState(
                level: trust.level,
                status: trust.status,
                reason: trust.reason,
                receivedAt: trust.receivedAt,
                authorization: newAuthorization
            ),
            capacity: capacity,
            slots: slots,
            inferenceActive: inferenceActive,
            startedAt: startedAt,
            writtenAt: writtenAt ?? self.writtenAt,
            pid: pid,
            processIdentity: processIdentity,
            advertisedModels: advertisedModels,
            coordinatorURL: coordinatorURL ?? self.coordinatorURL,
            modelLoadFailures: modelLoadFailures
        )
    }
}
