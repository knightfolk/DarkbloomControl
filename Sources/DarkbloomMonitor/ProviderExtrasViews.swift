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
            Section("Memory when idle") {
                idleSection
            }
            Section("Beta features") {
                betaSection
            }
            Section("Automatic updates") {
                autoUpdateSection
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
                Text(policy.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Idle minutes")
                    TextField("Minutes", text: idleTextBinding)
                        .labelsHidden()
                        .accessibilityLabel("Idle minutes")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
                    Button("Save") { saveIdle() }
                        .disabled(!canSaveIdle)
                }
                Text("0 keeps models loaded; 1–10,080 unloads after that many idle minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Changes apply after Darkbloom restarts.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if case .stale = store.snapshot?.idlePolicy {
                    Text("Refresh before saving this setting.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .unavailable, nil:
            Text("Idle-memory policy is unavailable from this Darkbloom CLI.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var betaSection: some View {
        switch store.snapshot?.betaFeatures {
        case .available(let features, _), .stale(let features, _, _):
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
            Text("Beta features are unavailable from this Darkbloom CLI.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var autoUpdateSection: some View {
        switch store.snapshot?.autoUpdateStatus {
        case .available(let status, _):
            Label(
                status.enabled ? "Automatic updates enabled" : "Automatic updates disabled",
                systemImage: status.enabled ? "arrow.down.circle" : "pause.circle"
            )
        case .stale(let status, _, _):
            Label(
                status.enabled ? "Automatic updates enabled (stale)" : "Automatic updates disabled (stale)",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .unavailable, nil:
            Text("Automatic-update status is unavailable from this Darkbloom CLI.")
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
                Text(feature.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feature.stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if feature.requiresRestart {
                    Text("Restart required after a change.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if canChange {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Enable") { setBeta(feature, enabled: true) }
                        .disabled(store.mutationInFlight || saving)
                    Button("Disable") { setBeta(feature, enabled: false) }
                        .disabled(store.mutationInFlight || saving)
                }
                .buttonStyle(.borderless)
            } else {
                Text("Read-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                ? "Saved \(feature.title). Restart Darkbloom to apply it."
                : (store.errorMessage ?? "The beta setting was not saved.")
        }
    }
}
