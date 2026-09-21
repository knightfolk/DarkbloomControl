import DarkbloomTelemetry
import SwiftUI

/// Presentation order is a demand comparison, never an earnings recommendation.
enum OpportunityPresentation {
    static func ordered(_ models: [NetworkModelCapacity]) -> [NetworkModelCapacity] {
        models.sorted {
            let left = $0.ready && $0.canAccept, right = $1.ready && $1.canAccept
            if left != right { return left }
            if $0.queuedRequests != $1.queuedRequests { return $0.queuedRequests > $1.queuedRequests }
            let a = $0.demandPerWarmProvider ?? ($0.activeRequests > 0 ? .infinity : 0)
            let b = $1.demandPerWarmProvider ?? ($1.activeRequests > 0 ? .infinity : 0)
            if a != b { return a > b }
            return $0.id < $1.id
        }
    }

    static func demand(_ model: NetworkModelCapacity) -> String {
        guard model.ready && model.canAccept else { return "Not accepting" }
        if model.queuedRequests > 0 { return "Work waiting" }
        switch model.demandBand {
        case .urgent, .high: return "Busy"
        case .moderate: return "Steady"
        case .low: return "Quiet"
        }
    }

    static func name(_ model: NetworkModelCapacity, metadata: CatalogModel?) -> String {
        guard let metadata, metadata.id == model.id, !metadata.displayName.isEmpty else { return model.id }
        return metadata.displayName
    }
}

struct OpportunityView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Opportunity").font(.largeTitle.bold())
                Text("See where the work is. Compare models for your Mac.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Picker("View", selection: $showsHistory) {
                Text("Models").tag(false)
                Text("Network activity").tag(true)
            }.pickerStyle(.segmented)
            if showsHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        NetworkHistoryView(source: store.networkSeries)
                        DisclosureGroup("Network infrastructure") {
                            NetworkCacheView(isVisible: store.dashboardVisible)
                                .padding(.top, 8)
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                OpportunityModelListView(store: store, controlStore: controlStore)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OpportunityModelListView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?
    @State private var search = ""
    @State private var refreshing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Find a model", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter network models")
                    Button {
                        refreshing = true
                        Task {
                            await store.refreshNetworkCapacity()
                            await store.refreshPublicCatalog()
                            refreshing = false
                        }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(refreshing)
                }
                if let capacity = store.networkCapacity.value {
                    let current = PopupNetworkDemandPresentation.freshness(of: store.networkCapacity, at: context.date) == .current
                    HStack(spacing: 6) {
                        Circle().fill(current ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(current ? "Live network" : "Last known demand")
                        Text("·")
                        Text(capacity.capturedAt, style: .relative)
                        Spacer()
                        Text("Demand first")
                    }.font(.callout).foregroundStyle(.secondary)
                    if !current {
                        Label("Data is out of date. Refresh before choosing a model.", systemImage: "clock")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if capacity.isDraining {
                        ContentUnavailableView(current ? "Network maintenance" : "Last reported: maintenance",
                            systemImage: "wrench.and.screwdriver", description: Text("Model capacity is temporarily withdrawn."))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                let models = OpportunityPresentation.ordered(capacity.models).filter { model in
                                    search.isEmpty || model.id.localizedCaseInsensitiveContains(search)
                                        || OpportunityPresentation.name(model, metadata: metadata(model.id)).localizedCaseInsensitiveContains(search)
                                }
                                if models.isEmpty {
                                    ContentUnavailableView(search.isEmpty ? "No models reported" : "No matching models",
                                        systemImage: "magnifyingglass", description: Text("Try a different search or refresh the network."))
                                }
                                ForEach(models) { model in
                                    if let controlStore {
                                        OpportunityLocalModelCard(model: model, controlStore: controlStore,
                                            metadata: metadata(model.id), price: store.publicPricing.value?.price(for: model.id),
                                            metadataIsCurrent: catalogCurrent(context.date), priceIsCurrent: pricingCurrent(context.date), networkIsCurrent: current)
                                    } else {
                                        OpportunityModelCard(model: model, local: nil, metadata: metadata(model.id),
                                            price: store.publicPricing.value?.price(for: model.id), metadataIsCurrent: catalogCurrent(context.date),
                                            priceIsCurrent: pricingCurrent(context.date), networkIsCurrent: current)
                                    }
                                }
                                DisclosureGroup("How to read this") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Work waiting comes first, then requests per loaded provider. These are network-wide signals, not a prediction of your earnings.")
                                        Text("RAM compares installed memory with the catalog minimum. It does not confirm free memory or runtime compatibility.")
                                        if let controlStore { OpportunityCatalogControls(controlStore: controlStore) }
                                        if let catalog = store.publicCatalog.value {
                                            Text("Model details last read \(catalog.capturedAt.formatted(date: .omitted, time: .shortened))\(catalogCurrent(context.date) ? "" : " · stale")")
                                        }
                                    }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                                }.padding(.top, 6)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Waiting for network demand", systemImage: "network",
                        description: Text("Your local provider continues independently. Try Refresh to check again."))
                }
            }
        }
    }

    private func metadata(_ id: String) -> CatalogModel? { store.publicCatalog.value?.models.first { $0.id == id } }
    private func catalogCurrent(_ date: Date) -> Bool {
        guard case .available(let value, _) = store.publicCatalog else { return false }
        return (0...1800).contains(date.timeIntervalSince(value.capturedAt))
    }
    private func pricingCurrent(_ date: Date) -> Bool {
        guard case .available(let value, _) = store.publicPricing else { return false }
        return (0...900).contains(date.timeIntervalSince(value.capturedAt))
    }
}

struct OpportunityCatalogControls: View {
    @ObservedObject var controlStore: ProviderControlStore
    var body: some View {
        HStack {
            Text(controlStore.errorMessage == nil ? "Local model details" : "Local details need a refresh")
            Spacer()
            Button("Refresh local catalog") { Task { await refreshCatalog() } }
                .disabled(controlStore.operation != .idle || controlStore.pendingConfirmation != nil)
        }
    }
    func refreshCatalog() async { await controlStore.refreshPreservingDraft() }
}

private struct OpportunityLocalModelCard: View {
    let model: NetworkModelCapacity
    @ObservedObject var controlStore: ProviderControlStore
    let metadata: CatalogModel?
    let price: CustomerModelPrice?
    let metadataIsCurrent: Bool
    let priceIsCurrent: Bool
    let networkIsCurrent: Bool
    var body: some View {
        let inventory = controlStore.snapshot?.inventory
        let local = ((inventory?.myCatalog ?? []) + (inventory?.available ?? [])).first { $0.catalogID == model.id }
        OpportunityModelCard(model: model, local: local, metadata: metadata, price: price,
            metadataIsCurrent: metadataIsCurrent, priceIsCurrent: priceIsCurrent, networkIsCurrent: networkIsCurrent)
    }
}

struct OpportunityModelCard: View {
    let model: NetworkModelCapacity
    let local: ModelInventoryItem?
    var metadata: CatalogModel? = nil
    var price: CustomerModelPrice? = nil
    var metadataIsCurrent = false
    var priceIsCurrent = false
    var networkIsCurrent = true
    var installedMemoryBytes = ProcessInfo.processInfo.physicalMemory

    private var tint: Color {
        guard networkIsCurrent, model.ready, model.canAccept else { return .secondary }
        return model.queuedRequests > 0 ? .orange : (model.demandBand == .low ? .secondary : .green)
    }
    private var ramFit: CatalogRAMFit {
        CatalogRAMFit.evaluate(modelID: model.id, metadata: metadata, metadataIsCurrent: metadataIsCurrent,
            installedMemoryBytes: installedMemoryBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(OpportunityPresentation.name(model, metadata: metadata)).font(.headline).textSelection(.enabled)
                    fitLabel.font(.callout)
                }
                Spacer(minLength: 4)
                Text(OpportunityPresentation.demand(model))
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(tint.opacity(0.10), in: Capsule())
            }
            HStack(spacing: 16) {
                metric("In progress", model.activeRequests)
                metric("Waiting", model.queuedRequests)
                metric("Providers loaded", model.warmProviders)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.id).font(.callout).textSelection(.enabled)
                    if let metadata {
                        Text("\(metadata.sizeGB.formatted(.number.precision(.fractionLength(1)))) GB download · \(metadata.minimumRAMGB) GB minimum RAM\(metadataIsCurrent ? "" : " · last known")")
                        if let requirements = metadata.requiredProviderCapabilities, !requirements.isEmpty {
                            Text("Requires " + requirements.map {
                                $0 == "apple_m5" ? "Apple M5" : ($0 == "mlx_nax" ? "MLX NAX" : $0)
                            }.joined(separator: ", ") + ". Runtime support is not verified.")
                        }
                    }
                    if let local {
                        Text("Last catalog check: \(local.isDownloaded ? "downloaded" : "not downloaded") · \(local.isEnabled ? "enabled" : "not enabled")")
                    }
                    Text("\(model.routableProviders) routable providers · \(model.canAccept && model.ready ? "accepting requests" : "not accepting requests")")
                    if let pressure = model.demandPerWarmProvider {
                        Text("\(pressure.formatted(.number.precision(.fractionLength(2)))) active or waiting requests per loaded provider")
                    }
                    if let price {
                        Text("Customer price per million tokens\(priceIsCurrent ? "" : " · last known")")
                            .fontWeight(.medium)
                        Text("$\(price.inputUSDPerMillion.formatted()) input · $\(price.outputUSDPerMillion.formatted()) output")
                        Text("Customer prices are not your provider payout.")
                    }
                    Text("RAM minimum is one check, not a guarantee that this model can run alongside your current models.")
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var fitLabel: some View {
        switch ramFit {
        case .minimumMet:
            if metadata?.requiredProviderCapabilities?.isEmpty == false {
                Label("RAM meets minimum · check runtime", systemImage: "memorychip").foregroundStyle(.secondary)
            } else {
                Label("RAM meets minimum", systemImage: "memorychip").foregroundStyle(.secondary)
            }
        case .belowMinimum:
            Label("Needs more RAM", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .unavailable:
            Label("RAM check unavailable", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
