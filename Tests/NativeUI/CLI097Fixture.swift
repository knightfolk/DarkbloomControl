// Opt-in native presentation fixture. All settings writes stay in this actor.
import AppKit
import DarkbloomTelemetry
import SwiftUI

private actor FixtureExtras: ProviderExtrasProviding {
    private var minutes = 0
    private var mtp = false
    func refresh() async -> ProviderExtrasSnapshot {
        let now = Date()
        let idle = ProviderIdlePolicy(idleTimeoutMinutes: minutes, policy: "always_ready", summary: minutes == 0 ? "Always ready (models stay loaded)" : "Free after \(minutes) minutes idle", pinned: true)
        let features = [
            ProviderBetaFeature(id: "mtp", title: "Multi-token prediction", state: mtp ? .on : .auto, enabled: mtp ? true : nil, requiresRestart: true, summary: "Automatic for eligible models; can reduce generation latency."),
            ProviderBetaFeature(id: "gemma-weighted-r1", title: "Gemma weighted R1", state: .on, enabled: true, requiresRestart: true, summary: "Weighted drafting for supported Gemma models."),
            ProviderBetaFeature(id: "future-feature", title: "Future feature", state: .off, enabled: false, requiresRestart: true, summary: "An unknown CLI feature remains read-only.")
        ]
        return ProviderExtrasSnapshot(capturedAt: now,
            idlePolicy: .available(value: idle, capturedAt: now),
            betaFeatures: .available(value: features, capturedAt: now),
            fanStatus: .unavailable(reason: "Fixture: no sensors"),
            autoUpdateStatus: .available(value: ProviderAutoUpdateStatus(enabled: true), capturedAt: now))
    }
    func saveIdle(minutes: Int) async throws { self.minutes = minutes }
    func setBeta(id: String, enabled: Bool) async throws { if id == "mtp" { mtp = enabled } }
}

@main struct CLI097Fixture: App {
    @StateObject private var store = ProviderExtrasStore(client: FixtureExtras())
    var body: some Scene {
        WindowGroup("CLI 0.9.7 Settings — Synthetic Review") {
            VStack(alignment: .leading) {
                Text("Synthetic review · no provider changes").font(.headline).padding()
                Form {
                    ProviderAdvancedSettingsView(store: store) { _, operation in
                        do { try await operation(); return true } catch { return false }
                    }
                    Section("Runtime explanation") {
                        SlotCard(slot: ModelSlot(model: "Example Qwen", mtpEnabled: true, mtpActive: false, mtpReason: "config_disabled", kvBackend: "contiguous", requestedKVBackend: "paged", kvFallbackReason: "kernel_preflight"))
                    }
                }.formStyle(.grouped)
            }
            .frame(minWidth: 650, minHeight: 650)
            .task { await store.refresh() }
        }
    }
}
