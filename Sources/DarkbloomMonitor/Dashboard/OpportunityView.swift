import DarkbloomTelemetry
import SwiftUI

struct OpportunityView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?
    @State private var showsHistory = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $showsHistory) {
                Text("Model demand").tag(false)
                Text("Network history").tag(true)
            }
            .pickerStyle(.segmented)
            .padding([.top, .horizontal], 24)
            if showsHistory {
                NetworkHistoryView(source: store.networkSeries).padding(24)
            } else {
                OpportunityModelListView(store: store, controlStore: controlStore)
            }
        }
    }
}

private struct OpportunityModelListView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?
    @State private var search = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(alignment: .leading, spacing: 16) {
                Text("Opportunity").font(.largeTitle.bold())
                Text("Network demand, not an earnings forecast")
                    .foregroundStyle(.secondary)
                if let controlStore {
                    OpportunityCatalogControls(controlStore: controlStore)
                }
                if let catalog = store.publicCatalog.value {
                    let stale = publicCatalogIsStale(at: context.date)
                    HStack {
                        Text(stale ? "Public metadata · stale" : "Public metadata")
                        Spacer()
                        Text(catalog.capturedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
                }
                if let pricing = store.publicPricing.value {
                    let stale = pricingIsStale(at: context.date)
                    HStack {
                        Text(stale ? "Customer prices · stale" : "Customer prices · not provider payout")
                        Spacer()
                        Text(pricing.capturedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
                }
                TextField("Find a model", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter network models")
                if let capacity = store.networkCapacity.value {
                    let stale = PopupNetworkDemandPresentation.freshness(of: store.networkCapacity, at: context.date) != .current
                    HStack {
                        Label(stale ? "Stale network snapshot" : "Current network snapshot",
                              systemImage: stale ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(stale ? Color.orange : Color.secondary)
                        Spacer()
                        Text(capacity.capturedAt, style: .relative).monospacedDigit()
                    }
                    .font(.callout)
                    if stale {
                        Text("These are last-known values. Wait for a successful refresh before using them to choose a model.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(capacity.models.filter {
                                search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)
                            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }) { model in
                                if let controlStore {
                                    OpportunityLocalModelCard(model: model, controlStore: controlStore, metadata: publicModel(model.id), price: store.publicPricing.value?.price(for: model.id), metadataIsCurrent: !publicCatalogIsStale(at: context.date))
                                } else {
                                    OpportunityModelCard(model: model, local: nil, metadata: publicModel(model.id), price: store.publicPricing.value?.price(for: model.id), metadataIsCurrent: !publicCatalogIsStale(at: context.date))
                                }
                            }
                        }
                    }
                    Text("Models are listed alphabetically. Demand bands use active requests per warm provider; any queued work is marked urgent. Customer pricing and expected provider income are not inferred from these counts.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Network demand unavailable", systemImage: "network",
                                           description: Text("The existing network collector has not returned a usable snapshot. Local monitoring continues independently."))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func publicModel(_ id: String) -> CatalogModel? {
        store.publicCatalog.value?.models.first { $0.id == id }
    }

    private func publicCatalogIsStale(at date: Date) -> Bool {
        guard case .available(let catalog, _) = store.publicCatalog else { return true }
        let age = date.timeIntervalSince(catalog.capturedAt)
        return !age.isFinite || age < 0 || age > 1_800
    }

    private func pricingIsStale(at date: Date) -> Bool {
        guard case .available(let pricing, _) = store.publicPricing else { return true }
        let age = date.timeIntervalSince(pricing.capturedAt)
        return !age.isFinite || age < 0 || age > 900
    }
}

struct OpportunityCatalogControls: View {
    @ObservedObject var controlStore: ProviderControlStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if controlStore.operation == .refreshing {
                    Text("Refreshing local catalog…")
                } else if let snapshot = controlStore.snapshot {
                    Text("Local catalog snapshot: \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Local catalog unavailable")
                }
                Spacer()
                Button {
                    Task { await refreshCatalog() }
                } label: {
                    Label("Refresh catalog", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh local catalog")
                .disabled(controlStore.operation != .idle || controlStore.pendingConfirmation != nil)
            }
            if controlStore.errorMessage != nil {
                Text("Local controls could not refresh. Last-known catalog details may be outdated; retry when the CLI is responding.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    func refreshCatalog() async {
        await controlStore.refreshPreservingDraft()
    }
}

private struct OpportunityLocalModelCard: View {
    let model: NetworkModelCapacity
    @ObservedObject var controlStore: ProviderControlStore
    let metadata: CatalogModel?
    let price: CustomerModelPrice?
    let metadataIsCurrent: Bool

    var body: some View {
        let inventory = controlStore.snapshot?.inventory
        let local = ((inventory?.myCatalog ?? []) + (inventory?.available ?? []))
            .first { $0.catalogID == model.id }
        OpportunityModelCard(model: model, local: local, metadata: metadata, price: price, metadataIsCurrent: metadataIsCurrent)
    }
}

struct OpportunityModelCard: View {
    let model: NetworkModelCapacity
    let local: ModelInventoryItem?
    var metadata: CatalogModel? = nil
    var price: CustomerModelPrice? = nil
    var metadataIsCurrent = false
    var installedMemoryBytes = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.id).font(.headline).textSelection(.enabled)
            HStack {
                Text(model.demandBand.rawValue.capitalized + " demand")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                Text(model.canAccept ? "Network accepting requests" : "Network not accepting requests")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), alignment: .leading)], alignment: .leading, spacing: 10) {
                metric("Active", model.activeRequests)
                metric("Queued", model.queuedRequests)
                metric("Warm providers", model.warmProviders)
                metric("Routable", model.routableProviders)
            }
            if let pressure = model.demandPerWarmProvider {
                Text("\(pressure.formatted(.number.precision(.fractionLength(2)))) active + queued requests per warm provider")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OpportunityFactorsView(model: model)
            if let metadata {
                Text("Public catalog: \(metadata.minimumRAMGB) GB minimum RAM · \(metadata.sizeGB.formatted(.number.precision(.fractionLength(1)))) GB model size")
                    .font(.caption).foregroundStyle(.secondary)
                ramFit
            }
            if let price {
                Text("Customer USD / 1M tokens: \(price.inputUSDPerMillion.formatted(.number.precision(.fractionLength(2...6)))) input · \(price.outputUSDPerMillion.formatted(.number.precision(.fractionLength(2...6)))) output")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let local {
                Text("Catalog snapshot: \(local.isDownloaded ? "downloaded" : "not downloaded") · \(local.isEnabled ? "enabled" : "disabled") · \(local.minimumRAMGB) GB minimum RAM")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Local catalog match unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var ramFit: some View {
        let fit = CatalogRAMFit.evaluate(modelID: model.id, metadata: metadata,
                                        metadataIsCurrent: metadataIsCurrent, installedMemoryBytes: installedMemoryBytes)
        let installed = (Double(installedMemoryBytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(0...1)))
        VStack(alignment: .leading, spacing: 4) {
            switch fit {
            case .minimumMet:
                Label("\(installed) GiB installed RAM · meets catalog minimum", systemImage: "memorychip")
            case .belowMinimum:
                Label("\(installed) GiB installed RAM · below catalog minimum", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .unavailable:
                Text("RAM check unavailable · needs current matching metadata")
            }
            Text("This does not establish free memory, slot availability or hardware-feature compatibility. Swap is not counted.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct OpportunityFactorsView: View {
    let model: NetworkModelCapacity

    var body: some View {
        let factors = OpportunityFactors(
            activeRequests: model.activeRequests, queuedRequests: model.queuedRequests,
            routableProviders: model.routableProviders, warmProviders: model.warmProviders,
            queueLimit: model.queueLimit
        )
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .topLeading)],
                      alignment: .leading, spacing: 10) {
                factor("Demand pressure", value: factors.demandPressure.formatted(.number.precision(.fractionLength(2))),
                       formula: "(active + queued) ÷ max(routable, 1)")
                factor("Warm scarcity", value: factors.warmScarcity.formatted(.percent.precision(.fractionLength(0))),
                       formula: "1 − warm ÷ max(routable, 1)")
                factor("Queue pressure", value: factors.queuePressure.formatted(.percent.precision(.fractionLength(0))),
                       formula: "queued ÷ max(queue limit, 1)")
            }
            if model.routableProviders == 0 || model.queueLimit == 0 {
                Text("Zero denominators use 1. These ratios do not establish available capacity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if factors.warmScarcity < 0 {
                Text("Warm count exceeds routable count; provider populations are inconsistent for this ratio.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func factor(_ title: String, value: String, formula: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption.weight(.medium))
            Text(formula).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
