import DarkbloomTelemetry
import SwiftUI

/// Read-only Mac-wide CPU and provider-reported GPU resource context.
struct ProviderResourcesView: View {
    @ObservedObject var store: MonitorStore
    @StateObject private var cpuUsage = SystemCPUUsageStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider resources")
                .font(.title3.bold())

            HStack(alignment: .top, spacing: 12) {
                cpuMetric
                gpuMemoryMetric
            }

            if let extras = store.providerExtras {
                ProviderThermalView(store: extras)
            }

            Text("GPU engine utilization is not reported by the provider. GPU memory and sensor temperature are shown instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-resources")
        .task { cpuUsage.start() }
        .onDisappear { cpuUsage.stop() }
    }

    private var cpuMetric: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Mac CPU", systemImage: "cpu")
                .font(.callout.weight(.medium))
            if let percentage = currentCPUPercentage {
                Text(percentage.formatted(.number.precision(.fractionLength(0))) + "%")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: percentage, total: 100)
                    .tint(.blue)
                    .accessibilityLabel("Mac-wide CPU utilization")
                    .accessibilityValue("\(percentage.formatted(.number.precision(.fractionLength(0)))) percent")
            } else {
                Text("Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("System-wide")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cpuAccessibilityLabel)
    }

    @ViewBuilder
    private var gpuMemoryMetric: some View {
        switch store.snapshot.state {
        case .available(let state, _):
            gpuMemoryCard(state, stale: HealthPresentation.daemonWarning(store.snapshot.state, at: Date()) != nil)
        case .stale(let state, _, _):
            gpuMemoryCard(state, stale: true)
        case .unavailable:
            EmptyView()
        }
    }

    private func gpuMemoryCard(_ state: DaemonState, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("GPU memory", systemImage: "memorychip")
                    .font(.callout.weight(.medium))
                if stale {
                    Text("Last report")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Text("\(state.capacity.gpuMemoryActiveGB.formatted(.number.precision(.fractionLength(1)))) GB active")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text("\(state.capacity.gpuMemoryCacheGB.formatted(.number.precision(.fractionLength(1)))) GB cached")
                .font(.callout)
                .monospacedDigit()
            Text("Provider-reported allocations")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GPU memory, \(state.capacity.gpuMemoryActiveGB.formatted(.number.precision(.fractionLength(1)))) gigabytes active, \(state.capacity.gpuMemoryCacheGB.formatted(.number.precision(.fractionLength(1)))) gigabytes cached\(stale ? ", last report" : "")")
    }

    private var currentCPUPercentage: Double? {
        guard let sampledAt = cpuUsage.sampledAt else { return nil }
        let age = Date().timeIntervalSince(sampledAt)
        guard age.isFinite, (0...10).contains(age) else { return nil }
        return cpuUsage.percentage
    }

    private var cpuAccessibilityLabel: String {
        guard let percentage = currentCPUPercentage else { return "Mac-wide CPU utilization is being measured" }
        return "Mac-wide CPU utilization, \(percentage.formatted(.number.precision(.fractionLength(0)))) percent"
    }
}
