import DarkbloomTelemetry
import SwiftUI

enum HealthPresentation {
    static func daemonWarning(_ source: SourceAvailability<DaemonState>, at now: Date) -> String? {
        switch source {
        case .unavailable(let reason):
            return "Daemon details unavailable — \(reason)"
        case .stale(_, _, let reason):
            return "Last-known daemon details — \(reason)"
        case .available(let state, _):
            let age = now.timeIntervalSince1970 - state.writtenAt
            guard age.isFinite, age >= 0, age <= 10 else {
                return "Last-known daemon details — state timestamp is not current."
            }
            return nil
        }
    }

    static func daemonRows(_ state: DaemonState?) -> [DisplayRow] {
        guard let state else { return [] }
        return [
            DisplayRow(label: "Process PID", value: String(state.processIdentity.pid)),
            DisplayRow(label: "Process start identity (µs)", value: String(state.processIdentity.startTimeMicros)),
            DisplayRow(label: "CLI version · daemon", value: state.version),
            DisplayRow(label: "Trust", value: "\(state.trust.status) · \(state.trust.level)"),
            DisplayRow(label: "Inference", value: state.inferenceActive ? "Active" : "Idle"),
            DisplayRow(label: "Reported slots", value: String(state.slots.count)),
            DisplayRow(label: "GPU active memory", value: "\(state.capacity.gpuMemoryActiveGB.formatted(.number.precision(.fractionLength(1)))) GB"),
            DisplayRow(label: "GPU cache memory", value: "\(state.capacity.gpuMemoryCacheGB.formatted(.number.precision(.fractionLength(1)))) GB"),
        ]
    }

    static func statusRows(_ status: SourceAvailability<StatusSnapshot>) -> [DisplayRow] {
        switch status {
        case .available(let value, _), .stale(let value, _, _):
            value.advancedRows
        case .unavailable(let reason):
            [DisplayRow(label: "CLI status", value: TelemetryFormatting.unavailable(reason))]
        }
    }
}

struct AdvancedSection: View {
    let snapshot: TelemetrySnapshot
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced telemetry")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    advancedGroup("CLI status", rows: statusRows)
                    advancedGroup("Source policy", rows: sourcePathRows)
                    advancedGroup("Source timestamps", rows: timestampRows)
                    diagnosticsGroup
                }
                .transition(.opacity)
            }
        }
    }

    private var statusRows: [DisplayRow] {
        HealthPresentation.statusRows(snapshot.status)
    }

    private var sourcePathRows: [DisplayRow] {
        let baseRows = [
            DisplayRow(label: "Daemon state", value: "~/.darkbloom/daemon-state.json"),
            DisplayRow(label: "Loaded models", value: "~/.darkbloom/loaded-models.json"),
            DisplayRow(label: "Legacy events", value: "~/.darkbloom/provider.log (final 128 KiB)"),
            DisplayRow(label: "Unified events", value: "subsystem dev.darkbloom.provider"),
            DisplayRow(label: "CLI operation", value: "darkbloom status"),
        ]
        let candidateRows = zip(
            ["CLI candidate · home", "CLI candidate · bundled app", "CLI candidate · PATH"],
            DarkbloomSourcePolicy.cliCandidateDescriptions
        ).map { DisplayRow(label: $0.0, value: $0.1) }
        return baseRows + candidateRows
    }

    private var timestampRows: [DisplayRow] {
        var rows = [
            DisplayRow(label: "Snapshot captured", value: TelemetryFormatting.timestamp(snapshot.capturedAt)),
            DisplayRow(label: "State availability", value: availabilityText(snapshot.state)),
            DisplayRow(label: "State written", value: stateWrittenText),
            DisplayRow(label: "State acquired", value: capturedAtText(snapshot.state)),
            DisplayRow(label: "Loaded-model availability", value: availabilityText(snapshot.loadedModels)),
            DisplayRow(label: "Loaded-model updated", value: loadedModelsUpdatedText),
            DisplayRow(label: "Loaded-model acquired", value: capturedAtText(snapshot.loadedModels)),
            DisplayRow(label: "CLI status availability", value: availabilityText(snapshot.status)),
            DisplayRow(label: "CLI status acquired", value: capturedAtText(snapshot.status)),
            DisplayRow(label: "Event availability", value: availabilityText(snapshot.eventFeed)),
        ]

        if let feed = snapshot.eventFeed.value {
            rows.append(DisplayRow(
                label: "Legacy log read",
                value: feed.legacyReadAt.map(TelemetryFormatting.timestamp)
                    ?? TelemetryFormatting.unavailable("no successful legacy log read")
            ))
            rows.append(DisplayRow(
                label: "Unified log activity",
                value: feed.unifiedActivityAt.map(TelemetryFormatting.timestamp)
                    ?? TelemetryFormatting.unavailable("no qualifying unified log activity")
            ))
        } else {
            let reason = unavailableReason(snapshot.eventFeed)
            rows.append(DisplayRow(label: "Legacy log read", value: TelemetryFormatting.unavailable(reason)))
            rows.append(DisplayRow(label: "Unified log activity", value: TelemetryFormatting.unavailable(reason)))
        }
        return rows
    }

    private var stateWrittenText: String {
        guard let state = snapshot.state.value else {
            return TelemetryFormatting.unavailable(unavailableReason(snapshot.state))
        }
        return TelemetryFormatting.timestamp(Date(timeIntervalSince1970: state.writtenAt))
    }

    private var loadedModelsUpdatedText: String {
        guard let models = snapshot.loadedModels.value else {
            return TelemetryFormatting.unavailable(unavailableReason(snapshot.loadedModels))
        }
        return TelemetryFormatting.timestamp(Date(timeIntervalSince1970: models.updatedAt))
    }

    @ViewBuilder
    private func advancedGroup(_ title: String, rows: [DisplayRow]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(rows) { row in
                displayRow(row)
            }
        }
    }

    private var diagnosticsGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Acquisition diagnostics")
                .font(.subheadline.weight(.semibold))
            if snapshot.diagnostics.isEmpty {
                Text("None reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(snapshot.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    displayRow(DisplayRow(
                        label: diagnostic.source,
                        value: "\(TelemetryFormatting.timestamp(diagnostic.occurredAt)) · \(diagnostic.message)"
                    ))
                }
            }
        }
    }

    private func displayRow(_ row: DisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(row.value)
                .font(.caption)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help(row.value)
        }
        .accessibilityElement(children: .combine)
    }

    private func capturedAtText<Value>(_ availability: SourceAvailability<Value>) -> String
    where Value: Equatable & Sendable {
        switch availability {
        case .available(_, let capturedAt), .stale(_, let capturedAt, _):
            TelemetryFormatting.timestamp(capturedAt)
        case .unavailable(let reason):
            TelemetryFormatting.unavailable(reason)
        }
    }

    private func availabilityText<Value>(_ availability: SourceAvailability<Value>) -> String
    where Value: Equatable & Sendable {
        switch availability {
        case .available:
            "Available"
        case .stale(_, _, let reason):
            "Stale — \(reason)"
        case .unavailable(let reason):
            TelemetryFormatting.unavailable(reason)
        }
    }

    private func unavailableReason<Value>(_ availability: SourceAvailability<Value>) -> String
    where Value: Equatable & Sendable {
        guard case .unavailable(let reason) = availability else {
            return "source value unavailable"
        }
        return reason
    }
}
