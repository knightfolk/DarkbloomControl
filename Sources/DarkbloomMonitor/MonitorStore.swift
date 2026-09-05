import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var energy: EnergyRecordingSnapshot?
    @Published private(set) var energyEarnings: EnergyEarnings?
    private var energyEarningsDay: Date?

    var currentEnergyReading: EnergyReading? {
        guard UserDefaults.standard.bool(forKey: "electricity.enabled"),
              ElectricityCost.rate(UserDefaults.standard.string(forKey: "electricity.usdPerKWh") ?? "") != nil,
              let reading = energy?.reading,
              (0...30).contains(Date().timeIntervalSince(reading.date)) else { return nil }
        return reading
    }

    var currentEnergyEarnings: EnergyEarnings? {
        guard UserDefaults.standard.bool(forKey: "electricity.enabled"),
              ElectricityCost.rate(UserDefaults.standard.string(forKey: "electricity.usdPerKWh") ?? "") != nil,
              energyEarningsDay == Calendar.current.startOfDay(for: Date()) else { return nil }
        return energyEarnings
    }
    private var energyTask: Task<Void, Never>?
    private let energyRecorder = EnergyRecorder(file: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Darkbloom Monitor/energy-history.json"))
    static let earningsPollingInterval: Duration = .seconds(600)
    private(set) var dashboardVisible = false
    private var networkPollingPolicy = NetworkPollingPolicy()

    @Published private(set) var snapshot: TelemetrySnapshot
    @Published private(set) var thermalState: SystemThermalState
    @Published private(set) var earnings: EarningsPresentationValue
    @Published private(set) var todayEarnings: ObservedEarningsWindow?
    @Published private(set) var earningsPerHourUSD: Double?
    @Published private(set) var weekEarnings: CalendarWeekEarningsSummary?
    @Published private(set) var observedUptime: ObservedUptimeValue
    @Published private(set) var jobSummary: SourceAvailability<JobCompletionSummary>
    @Published private(set) var averageTokenRate: TokenRate
    @Published private(set) var modelTokenRateAverages: [ModelTokenRateAverage]
    @Published private(set) var modelEarnings: [ModelEarnings]
    @Published private(set) var modelWorkEarnings: [ModelWorkEarnings] = []
    @Published private(set) var networkCapacity: SourceAvailability<NetworkCapacitySnapshot>
    @Published private(set) var publicCatalog: SourceAvailability<PublicCatalogSnapshot> = .unavailable(reason: "Waiting for public catalog")
    @Published private(set) var publicPricing: SourceAvailability<PublicPricingSnapshot> = .unavailable(reason: "Waiting for customer pricing")
    @Published private(set) var networkSeries: SourceAvailability<NetworkSeriesSnapshot> = .unavailable(reason: "Open the dashboard to load network history")
    @Published private(set) var activityRevision: UInt64 = 0

    private let service: TelemetryService
    private let earningsClient: any AccountEarningsFetching
    private let uptimeRecorder: (any ObservedUptimeRecording)?
    private let tokenRateRecorder: (any ModelTokenRateRecording)?
    private let networkCapacityClient: (any NetworkCapacityFetching)?
    private let publicCatalogClient: (any PublicCatalogFetching)?
    private var publicCatalogPollingTask: Task<Void, Never>?
    private var publicCatalogRefreshing = false
    private var publicCatalogFailures = 0
    private let publicPricingClient: (any PublicPricingFetching)?
    private var publicPricingPollingTask: Task<Void, Never>?
    private var publicPricingRefreshing = false
    private var publicPricingFailures = 0
    private let networkSeriesClient: (any NetworkSeriesFetching)?
    private var networkSeriesPollingTask: Task<Void, Never>?
    private var networkSeriesRefreshing = false
    private var networkSeriesFailures = 0
    private var nextNetworkSeriesAttempt = Date.distantPast
    private let now: @Sendable () -> Date
    private let publicPollingSleep: @Sendable (TimeInterval) async throws -> Void
    private let publicPollingJitter: @Sendable () -> Double
    private var tokenRateAccumulator = ActiveTokenRateAccumulator()
    private var observationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var earningsPollingTask: Task<Void, Never>?
    private var networkCapacityPollingTask: Task<Void, Never>?
    private var earningsRefreshTask: Task<AccountRefreshState, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    private var networkCapacityRefreshGeneration = 0
    private var latestNetworkCapacityCapturedAt: Date?
    private var hasStarted = false

    init(
        service: TelemetryService,
        initial: TelemetrySnapshot,
        earningsClient: any AccountEarningsFetching = AuthenticatedEarningsClient(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ),
        uptimeRecorder: (any ObservedUptimeRecording)? = nil,
        tokenRateRecorder: (any ModelTokenRateRecording)? = nil,
        networkCapacityClient: (any NetworkCapacityFetching)? = nil,
        publicCatalogClient: (any PublicCatalogFetching)? = nil,
        publicPricingClient: (any PublicPricingFetching)? = nil,
        networkSeriesClient: (any NetworkSeriesFetching)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        publicPollingSleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        publicPollingJitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.2) }
    ) {
        self.service = service
        self.earningsClient = earningsClient
        self.uptimeRecorder = uptimeRecorder
        self.tokenRateRecorder = tokenRateRecorder
        self.networkCapacityClient = networkCapacityClient
        self.publicCatalogClient = publicCatalogClient
        self.publicPricingClient = publicPricingClient
        self.networkSeriesClient = networkSeriesClient
        self.now = now
        self.publicPollingSleep = publicPollingSleep
        self.publicPollingJitter = publicPollingJitter
        snapshot = initial
        thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        earnings = .unavailable(reason: "Waiting for authenticated account earnings")
        todayEarnings = nil
        earningsPerHourUSD = nil
        weekEarnings = nil
        observedUptime = uptimeRecorder == nil
            ? .unavailable(reason: "Local observed-uptime storage unavailable")
            : .warming(observedSeconds: 0)
        jobSummary = .unavailable(reason: "Waiting for completed-job history")
        averageTokenRate = .unavailable(reason: "Waiting for active inference samples")
        modelTokenRateAverages = []
        modelEarnings = []
        networkCapacity = .unavailable(reason: "Waiting for network model demand")
    }

    func start() {
        guard !hasStarted, shutdownTask == nil else { return }
        hasStarted = true
        observeThermalState()
        energyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: "electricity.enabled")
                let rate = ElectricityCost.rate(UserDefaults.standard.string(forKey: "electricity.usdPerKWh") ?? "")
                let result = await self.energyRecorder.sample(enabled: enabled, rate: rate, now: Date())
                guard !Task.isCancelled else { return }
                self.energy = enabled ? result : nil
                self.energyEarnings = nil
                if enabled, result.issue == nil, !result.intervals.isEmpty {
                    let sampleTime = Date()
                    let calendar = Calendar.current
                    if let day = calendar.dateInterval(of: .day, for: sampleTime) {
                        do {
                            if let buckets = try await self.earningsClient.activity(in: day, unit: .hour, calendar: calendar) {
                                guard !Task.isCancelled else { return }
                                self.energyEarnings = EnergyEarnings.matching(buckets: buckets,
                                    energy: result.intervals, day: day, now: sampleTime)
                                self.energyEarningsDay = day.start
                            }
                        } catch {
                            self.energyEarnings = nil
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }

        earningsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEarnings()
                do {
                    try await Task.sleep(for: Self.earningsPollingInterval)
                } catch {
                    return
                }
            }
        }

        startNetworkCapacityPolling()
        if dashboardVisible { startNetworkSeriesPolling() }
        if publicPricingClient != nil {
            publicPricingPollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshPublicPricing()
                    guard let self else { return }
                    let delay = PublicPollingBackoff.delay(base: 900, cap: 21_600, failures: self.publicPricingFailures, jitter: self.publicPollingJitter())
                    do { try await self.publicPollingSleep(delay) }
                    catch { return }
                }
            }
        }
        if publicCatalogClient != nil {
            publicCatalogPollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshPublicCatalog()
                    guard let self else { return }
                    let delay = PublicPollingBackoff.delay(base: 1_800, cap: 21_600, failures: self.publicCatalogFailures, jitter: self.publicPollingJitter())
                    do { try await self.publicPollingSleep(delay) }
                    catch { return }
                }
            }
        }

        observationTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await service.snapshots()
            await service.start()

            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                await self.accept(snapshot)
                await self.recordObservedUptime(from: snapshot)
            }
        }
    }

    func refresh() {
        guard shutdownTask == nil, refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            async let refreshed = service.refreshNow()
            async let earningsRefresh: Void = refreshEarnings()
            async let networkRefresh: Void = refreshNetworkCapacity()
            let snapshot = await refreshed
            await earningsRefresh
            await networkRefresh
            guard !Task.isCancelled, shutdownTask == nil else { return }
            await self.accept(snapshot)
        }
    }

    func activity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar, model: String? = nil) async throws -> [ActivityBucket]? {
        try await earningsClient.modelActivity(in: range, unit: unit, calendar: calendar, model: model)
    }

    func activityModels(in range: DateInterval) async throws -> [String] {
        try await earningsClient.activityModels(in: range)
    }

    func activityTokenRates(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar, model: String) async throws -> [ModelRateBucket]? {
        try await tokenRateRecorder?.history(in: range, unit: unit, calendar: calendar, model: model)
    }

    func refreshTelemetryImmediately() async {
        guard shutdownTask == nil else { return }

        // The first read drains any refresh that began before a provider command.
        // The second read is therefore guaranteed to begin after that command.
        _ = await service.refreshNow()
        guard !Task.isCancelled, shutdownTask == nil else { return }
        let refreshed = await service.refreshNow()
        guard !Task.isCancelled, shutdownTask == nil else { return }
        await accept(refreshed)
    }

    func refreshEarnings() async {
        if let earningsRefreshTask {
            let refresh = await earningsRefreshTask.value
            earnings = refresh.earnings
            todayEarnings = refresh.todayEarnings
            weekEarnings = refresh.weekEarnings
            modelEarnings = refresh.modelEarnings
            modelWorkEarnings = refresh.modelWorkEarnings
            earningsPerHourUSD = refresh.todayEarnings.flatMap {
                EarningsHourlyRate.derive(
                    microUSD: $0.microUSD,
                    observedSeconds: $0.observedSeconds
                )
            }
            jobSummary = refresh.jobSummary
            return
        }

        let client = earningsClient
        let previousEarnings = earnings
        let previousJobSummary = jobSummary
        let previousModelEarnings = modelEarnings
        let refreshedAt = now()
        let calendar = Calendar.current
        let task = Task<AccountRefreshState, Never> {
            let refreshedEarnings: EarningsPresentationValue
            do {
                let value = try await client.fetch(now: refreshedAt)
                switch value {
                case .available, .observed, .day:
                    refreshedEarnings = value
                case .stale(let microUSD, let reason):
                    refreshedEarnings = .stale(microUSD: microUSD, reason: reason)
                case .unavailable(let reason):
                    refreshedEarnings = Self.staleOrUnavailable(
                        previous: previousEarnings,
                        reason: reason
                    )
                }
            } catch {
                refreshedEarnings = Self.staleOrUnavailable(
                    previous: previousEarnings,
                    reason: error.localizedDescription
                )
            }

            let refreshedJobSummary: SourceAvailability<JobCompletionSummary>
            do {
                if let summary = try await client.jobCompletionSummary(
                    now: refreshedAt,
                    calendar: calendar
                ) {
                    refreshedJobSummary = .available(value: summary, capturedAt: refreshedAt)
                } else {
                    refreshedJobSummary = Self.staleOrUnavailable(
                        previous: previousJobSummary,
                        reason: "Local completed-job history is unavailable"
                    )
                }
            } catch {
                refreshedJobSummary = Self.staleOrUnavailable(
                    previous: previousJobSummary,
                    reason: error.localizedDescription
                )
            }
            let refreshedTodayEarnings: ObservedEarningsWindow?
            let refreshedWeekEarnings: CalendarWeekEarningsSummary?
            let refreshedModelEarnings = (try? await client.modelEarnings(
                since: refreshedAt.addingTimeInterval(-7 * 86_400)
            )) ?? previousModelEarnings
            var refreshedModelWork: [ModelWorkEarnings] = []
            switch refreshedEarnings {
            case .available, .observed, .day:
                refreshedModelWork = (try? await client.modelWorkEarnings(
                    in: DateInterval(start: calendar.startOfDay(for: refreshedAt), end: refreshedAt),
                    calendar: calendar)) ?? []
                refreshedTodayEarnings = try? await client.todayEarningsSummary(
                    now: refreshedAt,
                    calendar: calendar
                )
                refreshedWeekEarnings = try? await client.weekEarningsSummary(
                    now: refreshedAt,
                    calendar: calendar
                )
            case .stale, .unavailable:
                refreshedTodayEarnings = nil
                refreshedWeekEarnings = nil
            }
            return AccountRefreshState(
                earnings: refreshedEarnings,
                jobSummary: refreshedJobSummary,
                todayEarnings: refreshedTodayEarnings,
                weekEarnings: refreshedWeekEarnings,
                modelEarnings: refreshedModelEarnings,
                modelWorkEarnings: refreshedModelWork
            )
        }
        earningsRefreshTask = task
        let refresh = await task.value
        earnings = refresh.earnings
        todayEarnings = refresh.todayEarnings
        weekEarnings = refresh.weekEarnings
        modelEarnings = refresh.modelEarnings
        modelWorkEarnings = refresh.modelWorkEarnings
        earningsPerHourUSD = refresh.todayEarnings.flatMap {
            EarningsHourlyRate.derive(
                microUSD: $0.microUSD,
                observedSeconds: $0.observedSeconds
            )
        }
        jobSummary = refresh.jobSummary
        earningsRefreshTask = nil
        // Invalidate local history queries even if the displayed account total
        // is unchanged: ingestion may have filled older buckets or rewards.
        activityRevision &+= 1
    }

    func setDashboardVisible(_ visible: Bool) {
        guard dashboardVisible != visible else { return }
        dashboardVisible = visible
        let previousSeries = networkSeriesPollingTask
        previousSeries?.cancel()
        if visible, hasStarted, shutdownTask == nil {
            startNetworkSeriesPolling(after: previousSeries)
        }
        // Wake a stale source on open, but never bypass failure backoff by
        // repeatedly opening the dashboard. Keep a single owned polling task.
        if visible, hasStarted, shutdownTask == nil, networkPollingPolicy.failures == 0,
           networkCapacity.value?.isFresh(at: now()) != true {
            let previous = networkCapacityPollingTask
            previous?.cancel()
            startNetworkCapacityPolling(after: previous)
        }
    }

    private func startNetworkCapacityPolling(after previous: Task<Void, Never>? = nil) {
        guard networkCapacityClient != nil else { return }
        networkCapacityPollingTask = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                await self?.refreshNetworkCapacity()
                guard let delay = self?.networkPollingPolicy.delay(
                    dashboardVisible: self?.dashboardVisible ?? false,
                    jitter: self?.publicPollingJitter() ?? 0
                ) else { return }
                guard let sleep = self?.publicPollingSleep else { return }
                do { try await sleep(delay) }
                catch { return }
            }
        }
    }

    private func startNetworkSeriesPolling(after previous: Task<Void, Never>? = nil) {
        guard networkSeriesClient != nil else { return }
        networkSeriesPollingTask = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let delay = self.map({ max(0, $0.nextNetworkSeriesAttempt.timeIntervalSince($0.now())) }) else { return }
                if delay > 0 {
                    guard let sleep = self?.publicPollingSleep else { return }
                    do { try await sleep(delay) }
                    catch { return }
                }
                guard !Task.isCancelled, self?.dashboardVisible == true else { return }
                await self?.refreshNetworkSeries()
            }
        }
    }

    func refreshNetworkSeries() async {
        guard let networkSeriesClient, dashboardVisible, !networkSeriesRefreshing, shutdownTask == nil, !Task.isCancelled else { return }
        networkSeriesRefreshing = true
        nextNetworkSeriesAttempt = now().addingTimeInterval(300)
        defer { networkSeriesRefreshing = false }
        do {
            let value = try await networkSeriesClient.fetch(at: now())
            guard !Task.isCancelled, shutdownTask == nil, dashboardVisible else { return }
            let age = now().timeIntervalSince(value.updatedAt)
            guard age.isFinite, age >= -60, age <= 900 else { throw NetworkSeriesError.invalidSeries }
            networkSeries = .available(value: value, capturedAt: value.capturedAt)
            networkSeriesFailures = 0
            nextNetworkSeriesAttempt = now().addingTimeInterval(300)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, shutdownTask == nil, dashboardVisible else { return }
            networkSeriesFailures = min(4, networkSeriesFailures + 1)
            nextNetworkSeriesAttempt = now().addingTimeInterval(PublicPollingBackoff.delay(base: 300, cap: 3_600, failures: networkSeriesFailures, jitter: publicPollingJitter()))
            if let value = networkSeries.value {
                networkSeries = .stale(value: value, capturedAt: value.capturedAt, reason: "Network history refresh failed")
            } else {
                networkSeries = .unavailable(reason: "Network history is unavailable")
            }
        }
    }

    func refreshNetworkCapacity() async {
        guard let networkCapacityClient else { return }
        networkCapacityRefreshGeneration &+= 1
        let refreshGeneration = networkCapacityRefreshGeneration
        let capturedAt = now()
        do {
            let value = try await networkCapacityClient.fetch(at: capturedAt)
            guard !Task.isCancelled,
                  shutdownTask == nil,
                  refreshGeneration == networkCapacityRefreshGeneration
            else { return }
            guard value.isFresh(at: now()) else {
                markNetworkCapacityRefreshFailed()
                return
            }
            guard latestNetworkCapacityCapturedAt.map({ value.capturedAt >= $0 }) ?? true else {
                return
            }
            networkCapacity = .available(value: value, capturedAt: value.capturedAt)
            latestNetworkCapacityCapturedAt = value.capturedAt
            networkPollingPolicy.succeeded()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, shutdownTask == nil else { return }
            guard refreshGeneration == networkCapacityRefreshGeneration else { return }
            markNetworkCapacityRefreshFailed()
        }
    }

    func refreshPublicCatalog() async {
        guard let publicCatalogClient, !publicCatalogRefreshing, shutdownTask == nil, !Task.isCancelled else { return }
        publicCatalogRefreshing = true
        defer { publicCatalogRefreshing = false }
        do {
            let value = try await publicCatalogClient.fetch(at: now())
            guard !Task.isCancelled, shutdownTask == nil else { return }
            let age = now().timeIntervalSince(value.capturedAt)
            guard age.isFinite, age >= 0, age <= 1_800 else { throw PublicCatalogError.invalidCatalog }
            publicCatalog = .available(value: value, capturedAt: value.capturedAt)
            publicCatalogFailures = 0
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, shutdownTask == nil else { return }
            publicCatalogFailures = min(4, publicCatalogFailures + 1)
            if let value = publicCatalog.value {
                publicCatalog = .stale(value: value, capturedAt: value.capturedAt, reason: "Public catalog refresh failed")
            } else {
                publicCatalog = .unavailable(reason: "Public catalog is unavailable")
            }
        }
    }

    func refreshPublicPricing() async {
        guard let publicPricingClient, !publicPricingRefreshing, shutdownTask == nil, !Task.isCancelled else { return }
        publicPricingRefreshing = true
        defer { publicPricingRefreshing = false }
        do {
            let value = try await publicPricingClient.fetch(at: now())
            guard !Task.isCancelled, shutdownTask == nil else { return }
            let age = now().timeIntervalSince(value.capturedAt)
            guard age.isFinite, age >= 0, age <= 900 else { throw PublicPricingError.invalidPricing }
            publicPricing = .available(value: value, capturedAt: value.capturedAt)
            publicPricingFailures = 0
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, shutdownTask == nil else { return }
            publicPricingFailures = min(5, publicPricingFailures + 1)
            if let value = publicPricing.value {
                publicPricing = .stale(value: value, capturedAt: value.capturedAt, reason: "Customer pricing refresh failed")
            } else {
                publicPricing = .unavailable(reason: "Customer pricing is unavailable")
            }
        }
    }

    var currentTodayEarnings: ObservedEarningsWindow? {
        guard case .day = EarningsPresentationValue.calendarDay(todayEarnings, now: now(), calendar: .current) else { return nil }
        return todayEarnings
    }

    var currentWeekEarnings: CalendarWeekEarningsSummary? {
        guard weekEarnings?.isCurrent(at: now(), calendar: .current) == true else { return nil }
        return weekEarnings
    }

    var currentJobSummary: JobCompletionSummary? {
        guard case .available(let value, _) = jobSummary,
              value.isCurrent(at: now(), calendar: .current) else { return nil }
        return value
    }

    var currentModelTokenRateAverages: [ModelTokenRateAverage] {
        CalendarTokenRates.current(modelTokenRateAverages, at: now(), calendar: .current)
    }

    var currentDayAverageTokenRate: Double? {
        CalendarTokenRates.weightedAverage(currentModelTokenRateAverages)
    }

    func menuPresentation(mode: MenuBarDisplayMode) -> MenuBarPresentation {
        MenuBarPresentation.make(
            snapshot: snapshot,
            thermal: thermalState,
            earnings: .calendarDay(todayEarnings, now: now(), calendar: .current),
            mode: mode,
            activeModelAverage: currentModelTokenRateAverages.first {
                $0.model == snapshot.state.value?.currentModel
            }?.tokensPerSecond
        )
    }

    func stop() async {
        energyTask?.cancel()
        await energyTask?.value
        energyTask = nil
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        let observationTask = observationTask
        let refreshTask = refreshTask
        observationTask?.cancel()
        refreshTask?.cancel()
        earningsPollingTask?.cancel()
        networkCapacityPollingTask?.cancel()
        publicCatalogPollingTask?.cancel()
        publicPricingPollingTask?.cancel()
        networkSeriesPollingTask?.cancel()
        earningsRefreshTask?.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }

        let service = service
        let earningsPollingTask = earningsPollingTask
        let earningsRefreshTask = earningsRefreshTask
        let networkCapacityPollingTask = networkCapacityPollingTask
        let publicCatalogPollingTask = publicCatalogPollingTask
        let publicPricingPollingTask = publicPricingPollingTask
        let networkSeriesPollingTask = networkSeriesPollingTask
        let shutdownTask = Task {
            await service.stop()
            await observationTask?.value
            await refreshTask?.value
            await earningsPollingTask?.value
            await networkCapacityPollingTask?.value
            await publicCatalogPollingTask?.value
            await publicPricingPollingTask?.value
            await networkSeriesPollingTask?.value
            _ = await earningsRefreshTask?.value
        }
        self.shutdownTask = shutdownTask
        await shutdownTask.value
        self.observationTask = nil
        self.refreshTask = nil
        self.earningsPollingTask = nil
        self.earningsRefreshTask = nil
        self.networkCapacityPollingTask = nil
        self.publicCatalogPollingTask = nil
        self.publicPricingPollingTask = nil
        self.networkSeriesPollingTask = nil
    }

    func quit() async {
        await stop()
        NSApplication.shared.terminate(nil)
    }

    private func observeThermalState() {
        thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    private func accept(_ snapshot: TelemetrySnapshot) async {
        if let state = snapshot.state.value {
            tokenRateAccumulator.record(
                snapshot.tokenRate,
                processIdentity: state.processIdentity,
                writtenAt: state.writtenAt
            )
            averageTokenRate = tokenRateAccumulator.value

            if let tokenRateRecorder {
                if case .available(let tokensPerSecond, _) = snapshot.tokenRate {
                    try? await tokenRateRecorder.record(
                        model: state.currentModel,
                        tokensPerSecond: tokensPerSecond,
                        capturedAt: snapshot.capturedAt,
                        processIdentity: state.processIdentity,
                        writtenAt: state.writtenAt
                    )
                }
                if let averages = try? await tokenRateRecorder.averages(
                    from: Calendar.current.startOfDay(for: snapshot.capturedAt),
                    through: snapshot.capturedAt
                ) {
                    modelTokenRateAverages = averages
                    let sampleCount = averages.reduce(0) { $0 + $1.sampleCount }
                    if sampleCount > 0 {
                        let weightedTotal = averages.reduce(0.0) {
                            $0 + ($1.tokensPerSecond * Double($1.sampleCount))
                        }
                        averageTokenRate = .available(
                            tokensPerSecond: weightedTotal / Double(sampleCount),
                            label: "today's average"
                        )
                    } else {
                        averageTokenRate = .unavailable(
                            reason: "No measured token rates today"
                        )
                    }
                }
            }
        }
        self.snapshot = snapshot
    }

    private func recordObservedUptime(from snapshot: TelemetrySnapshot) async {
        guard let uptimeRecorder else { return }
        do {
            observedUptime = try await uptimeRecorder.record(
                status: snapshot.menuStatus,
                at: snapshot.capturedAt
            )
        } catch {
            observedUptime = .unavailable(reason: error.localizedDescription)
        }
    }

    private func markNetworkCapacityRefreshFailed() {
        networkPollingPolicy.failed()
        switch networkCapacity {
        case .available(let value, let previousAt),
             .stale(let value, let previousAt, _):
            networkCapacity = .stale(
                value: value,
                capturedAt: previousAt,
                reason: "Network demand refresh failed"
            )
        case .unavailable:
            networkCapacity = .unavailable(reason: "Network demand is unavailable")
        }
    }

    private static func staleOrUnavailable(
        previous: EarningsPresentationValue,
        reason: String
    ) -> EarningsPresentationValue {
        switch previous {
        case .available(let microUSD), .stale(let microUSD, _):
            .stale(microUSD: microUSD, reason: reason)
        case .observed, .day:
            .unavailable(reason: reason)
        case .unavailable:
            .unavailable(reason: reason)
        }
    }

    private static func staleOrUnavailable(
        previous: SourceAvailability<JobCompletionSummary>,
        reason: String
    ) -> SourceAvailability<JobCompletionSummary> {
        switch previous {
        case .available(let value, let capturedAt), .stale(let value, let capturedAt, _):
            .stale(value: value, capturedAt: capturedAt, reason: reason)
        case .unavailable:
            .unavailable(reason: reason)
        }
    }
}

private struct AccountRefreshState: Sendable {
    let earnings: EarningsPresentationValue
    let jobSummary: SourceAvailability<JobCompletionSummary>
    let todayEarnings: ObservedEarningsWindow?
    let weekEarnings: CalendarWeekEarningsSummary?
    let modelEarnings: [ModelEarnings]
    let modelWorkEarnings: [ModelWorkEarnings]
}
