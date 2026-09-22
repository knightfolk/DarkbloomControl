import DarkbloomTelemetry
import SwiftUI

/// Compact read-only temperature and fan readings from the official CLI.
struct ProviderThermalView: View {
    @ObservedObject var store: ProviderExtrasStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Group {
                switch store.snapshot?.fanStatus {
                case .available(let status, let capturedAt):
                    content(
                        status: status.helperIsFresh(at: context.date) ? status : status.withoutHelper(),
                        stale: !Self.isFresh(capturedAt: capturedAt, at: context.date) || (!status.helperIsFresh(at: context.date) && status.diagnostic.fans.isEmpty && status.diagnostic.gpuTemperatures.isEmpty)
                    )
                case .stale(let status, _, _):
                    content(status: status, stale: true)
                case .unavailable, nil:
                    Label("Fan telemetry unavailable", systemImage: "thermometer.medium")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func content(status: ProviderFanStatus, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Thermals", systemImage: "thermometer.medium")
                    .font(.headline)
                if stale {
                    Text("Stale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if status.diagnostic.supported {
                    Text("Live")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                if let temperature = status.displayedTemperatureCelsius {
                    Label(Self.temperature(temperature), systemImage: "flame")
                        .monospacedDigit()
                }
                ForEach(status.displayedFans) { fan in
                    if let rpm = fan.actualRPM {
                        Label("Fan \(fan.index + 1) \(Self.rpm(rpm))", systemImage: "wind")
                            .monospacedDigit()
                    }
                }
                if status.displayedTemperatureCelsius == nil && status.displayedFans.isEmpty {
                    Text(status.diagnostic.supported ? "Waiting for sensor readings" : "Unsupported hardware")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Text(Self.posture(status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func temperature(_ value: Double) -> String {
        String(format: "%.1f °C", value)
    }

    private static func rpm(_ value: Double) -> String {
        String(format: "%.0f RPM", value)
    }

    private static func isFresh(capturedAt: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && age >= 0 && age <= ProviderExtrasSnapshot.maximumSourceAge
    }

    private static func posture(_ status: ProviderFanStatus) -> String {
        guard status.loaded else {
            return "Darkbloom fan helper is not loaded."
        }
        guard let helper = status.helper else {
            return "Darkbloom fan helper status is unavailable."
        }
        return helper.providerActive
            ? "Fan helper is active while the provider is serving."
            : "Fan helper is waiting for provider activity."
    }
}

/// Settings sections for the new CLI idle-memory and beta-feature controls.
/// Writes are always routed through the parent-provided serial mutation gate.
struct ProviderAdvancedSettingsView: View {
    @ObservedObject var store: ProviderExtrasStore
    let performMutation: ProviderExtrasMutationExecutor

    @State private var idleMinutesText = ""
    @State private var idleDraftDirty = false
    @State private var idleSaveInFlight = false
    @State private var betaSaveIDs: Set<String> = []
    @State private var feedback: String?

    init(
        store: ProviderExtrasStore,
        performMutation: @escaping ProviderExtrasMutationExecutor
    ) {
        self.store = store
        self.performMutation = performMutation
    }

    var body: some View {
        Group {
            Section("Provider · Memory when idle") {
                idleSection
            }
            Section("Provider · Experimental features") {
                betaSection
            }
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { syncIdleDraft() }
        .onChange(of: store.snapshot?.idlePolicy) { _, _ in
            // Refreshes are read-only, and must not overwrite a value the user
            // is currently editing in the idle field.
            syncIdleDraft()
        }
    }

    @ViewBuilder
    private var idleSection: some View {
        switch store.snapshot?.idlePolicy {
        case .available(let policy, _), .stale(let policy, _, _):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Saved idle policy").font(.headline)
                    Spacer()
                    SettingsStateBadge(policy.idleTimeoutMinutes == 0
                        ? "No idle timeout" : "After \(policy.idleTimeoutMinutes) min")
                }
                Text("Controls timed unloading only. Models can still unload to make room for other work.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Unload after")
                    TextField("Minutes", text: idleTextBinding)
                        .labelsHidden()
                        .accessibilityLabel("Idle minutes")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
                    Text("minutes").foregroundStyle(.secondary)
                    Button(idleSaveInFlight ? "Saving…" : "Save") { saveIdle() }
                        .disabled(!canSaveIdle)
                }
                Text(idleDraftDirty ? "Unsaved change · Enter 0 to disable timed unloading, or 1–10,080 minutes." : "Enter 0 to disable timed unloading, or 1–10,080 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Saved configuration · Applies on restart. The running value is not reported by the CLI.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if case .stale = store.snapshot?.idlePolicy {
                    Text("Refresh before saving this setting.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .unavailable, nil:
            Text("Unable to read the saved idle policy. Refresh to try again.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var betaSection: some View {
        switch store.snapshot?.betaFeatures {
        case .available(let features, _), .stale(let features, _, _):
            Text("Saved choices, not proof a feature is active. Automatic depends on the model and runtime support.")
                .font(.callout).foregroundStyle(.secondary)
            if features.isEmpty {
                Text("No configurable beta features are available in this build.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(features) { feature in
                    betaRow(feature)
                }
                if case .stale = store.snapshot?.betaFeatures {
                    Text("Refresh before changing beta settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .unavailable, nil:
            Text("Unable to read experimental feature settings. Refresh to try again.")
                .foregroundStyle(.secondary)
        }
    }

    private func betaRow(_ feature: ProviderBetaFeature) -> some View {
        let saving = betaSaveIDs.contains(feature.id)
        let sourceIsFresh = isFresh(store.snapshot?.betaFeatures)
        let canChange = sourceIsFresh
            && ProviderExtrasClient.allowedBetaFeatureIDs.contains(feature.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.body.weight(.medium))
                DisclosureGroup("What this does") {
                    Text(feature.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if feature.requiresRestart {
                    Text("Changes apply on restart")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                SettingsStateBadge(saving ? "Saving…" : feature.stateLabel)
                if !sourceIsFresh {
                    Text("Last known value").font(.caption).foregroundStyle(.orange)
                }
                if canChange {
                    Menu("Change…") {
                        Button("Enable") { setBeta(feature, enabled: true) }
                            .disabled(feature.state == .on)
                        Button("Disable") { setBeta(feature, enabled: false) }
                            .disabled(feature.state == .off)
                    }
                    .disabled(store.mutationInFlight || saving)
                    .accessibilityLabel("Change \(feature.title), saved \(feature.stateLabel)")
                } else {
                    Text(sourceIsFresh ? "Read-only" : "Needs refresh")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canSaveIdle: Bool {
        guard !idleSaveInFlight,
              !store.mutationInFlight,
              idleDraftDirty,
              let minutes = Int(idleMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProviderIdlePolicy.isValid(minutes: minutes),
              isFresh(store.snapshot?.idlePolicy)
        else { return false }
        guard case .available = store.snapshot?.idlePolicy else { return false }
        return true
    }

    private func syncIdleDraft() {
        guard !idleDraftDirty,
              case .available(let policy, _) = store.snapshot?.idlePolicy
        else { return }
        idleMinutesText = String(policy.idleTimeoutMinutes)
        idleDraftDirty = false
    }

    private var idleTextBinding: Binding<String> {
        Binding(
            get: { idleMinutesText },
            set: {
                idleMinutesText = $0
                idleDraftDirty = true
            }
        )
    }

    private func isFresh<Value>(
        _ source: SourceAvailability<Value>?,
        now: Date = Date()
    ) -> Bool where Value: Equatable & Sendable {
        guard case .available(_, let capturedAt) = source else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && age >= 0 && age <= ProviderExtrasSnapshot.maximumSourceAge
    }

    private func saveIdle() {
        guard canSaveIdle else { feedback = "Refresh before saving this setting."; return }
        guard let minutes = Int(idleMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProviderIdlePolicy.isValid(minutes: minutes)
        else {
            feedback = "Choose 0–10,080 minutes."
            return
        }
        idleSaveInFlight = true
        Task { @MainActor in
            let succeeded = await performMutation("idle memory policy") {
                try await store.saveIdle(minutes: minutes)
            }
            idleSaveInFlight = false
            if succeeded {
                idleDraftDirty = false
                syncIdleDraft()
                feedback = "Saved. Restart Darkbloom to apply the idle policy."
            } else {
                feedback = store.errorMessage ?? "The idle policy was not saved."
            }
        }
    }

    private func setBeta(_ feature: ProviderBetaFeature, enabled: Bool) {
        guard !betaSaveIDs.contains(feature.id), !store.mutationInFlight,
              isFresh(store.snapshot?.betaFeatures),
              ProviderExtrasClient.allowedBetaFeatureIDs.contains(feature.id) else { return }
        betaSaveIDs.insert(feature.id)
        Task { @MainActor in
            let succeeded = await performMutation("beta \(feature.id)") {
                try await store.setBeta(id: feature.id, enabled: enabled)
            }
            betaSaveIDs.remove(feature.id)
            feedback = succeeded
                ? (feature.requiresRestart
                    ? "Saved \(feature.title). Restart Darkbloom to apply it."
                    : "Saved \(feature.title).")
                : (store.errorMessage ?? "The beta setting was not saved.")
        }
    }
}

/// Text remains the primary state cue, including automatic and unknown states.
struct SettingsStateBadge: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }
}
