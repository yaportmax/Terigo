import CoreLocation
import CryptoKit
import Foundation
import Observation
import SwiftData

enum ActivitiesPageTab: String, CaseIterable, Identifiable {
    case activities
    case forecast
    case training
    case explorer
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activities:
            return "Activities"
        case .forecast:
            return "Forecast"
        case .training:
            return "Training"
        case .explorer:
            return "Explorer"
        case .stats:
            return "Stats"
        }
    }

    var symbolName: String {
        switch self {
        case .activities:
            return "figure.run"
        case .forecast:
            return "gauge.with.dots.needle.50percent"
        case .training:
            return "waveform.path.ecg"
        case .explorer:
            return "map"
        case .stats:
            return "chart.bar.xaxis"
        }
    }
}

enum ActivitySortOption: String, CaseIterable, Identifiable {
    case startDate
    case updatedAt
    case name
    case distance
    case climb
    case movingTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startDate:
            return "Date"
        case .updatedAt:
            return "Updated"
        case .name:
            return "Name"
        case .distance:
            return "Distance"
        case .climb:
            return "Climb"
        case .movingTime:
            return "Time"
        }
    }

    var symbolName: String {
        switch self {
        case .startDate:
            return "calendar"
        case .updatedAt:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .name:
            return "textformat.abc"
        case .distance:
            return "ruler"
        case .climb:
            return "mountain.2"
        case .movingTime:
            return "clock"
        }
    }
}

struct ActivitySortCriterion: Identifiable, Equatable {
    let id: UUID
    var option: ActivitySortOption
    var direction: RouteSortDirection

    init(
        id: UUID = UUID(),
        option: ActivitySortOption,
        direction: RouteSortDirection
    ) {
        self.id = id
        self.option = option
        self.direction = direction
    }

    static var defaultCriterion: ActivitySortCriterion {
        ActivitySortCriterion(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            option: .startDate,
            direction: .descending
        )
    }
}

enum ActivityPrivacyFilter: String, CaseIterable, Identifiable {
    case all
    case `public`
    case `private`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Any"
        case .public:
            return "Public"
        case .private:
            return "Private"
        }
    }
}

@MainActor
@Observable
final class ActivitiesModel {
    struct ActivityListSummarySnapshot: Equatable {
        let activityCount: Int
        let distanceMeters: Double
        let newCoverageMeters: Double
    }

    struct AnalyticsBlockingState: Equatable {
        let title: String
        let message: String
        let completedCount: Int?
        let totalCount: Int?

        var progressLabel: String? {
            guard let completedCount, let totalCount, totalCount > 0 else {
                return nil
            }

            return "\(completedCount) of \(totalCount) workouts ready"
        }
    }

    private struct PreparedForecastComputationResult {
        let requestToken: String
        let sports: [RouteSportKind]
        let presets: [ActivityForecastPreset]
        let presetSnapshots: [String: ActivityForecastSnapshot]
        let snapshot: ActivityForecastSnapshot?
    }

    private struct PreparedTrainingComputationResult {
        let requestToken: String
        let sports: [RouteSportKind]
        let snapshot: ActivityTrainingSnapshot?
        let curves: [String: ActivityBestEffortCurveSnapshot]
        let bestEffortCurve: ActivityBestEffortCurveSnapshot?
    }

    private enum AppConfiguration {
        static func value(for key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmed ?? ""
        }

        static var clientID: String {
            value(for: "RouteVaultStravaClientID")
        }

        static var clientSecret: String? {
            value(for: "RouteVaultStravaClientSecret").nilIfEmpty
        }

        static var authBrokerBaseURLString: String? {
            value(for: "RouteVaultStravaAuthBrokerURL").nilIfEmpty
        }

        static var redirectScheme: String {
            value(for: "RouteVaultRedirectScheme").nilIfEmpty ?? "routevault"
        }

        static var redirectHost: String {
            value(for: "RouteVaultRedirectHost").nilIfEmpty ?? "localhost"
        }
    }

    @ObservationIgnored private let credentialStore = StravaCredentialStore()
    @ObservationIgnored private let apiService = StravaAPIService()
    @ObservationIgnored private let authCoordinator = StravaAuthSessionCoordinator()
    @ObservationIgnored private let gpxImportService = GPXImportService()
    @ObservationIgnored private let locationResolver = ActivityLocationMetadataResolver()
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var cachedFilteredActivitiesSignature: Int?
    @ObservationIgnored private var cachedFilteredActivitiesQuery = ""
    @ObservationIgnored private var cachedFilteredActivities: [ActivityRecord] = []
    @ObservationIgnored private var cachedActivityListSummarySignature: Int?
    @ObservationIgnored private var cachedActivityListSummary: ActivityListSummarySnapshot?
    @ObservationIgnored private var cachedCoverageSignature: Int?
    @ObservationIgnored private var cachedCoverageComputation: ActivityCoverageComputation?
    @ObservationIgnored private var cachedCoverageInputSignature: Int?
    @ObservationIgnored private var cachedCoverageInputs: [ActivityCoverageInput] = []
    @ObservationIgnored private var cachedForecastSignature: Int?
    @ObservationIgnored private var cachedForecastInputSignature: Int?
    @ObservationIgnored private var cachedForecastInputs: [ActivityForecastInput] = []
    @ObservationIgnored private var cachedForecastSports: [RouteSportKind] = []
    @ObservationIgnored private var cachedForecastSnapshots: [String: ActivityForecastSnapshot] = [:]
    @ObservationIgnored private var forecastPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var forecastPreparationWorkerTask: Task<PreparedForecastComputationResult?, Never>?
    @ObservationIgnored private var forecastPreparationToken = ""
    @ObservationIgnored private var trainingPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var trainingPreparationWorkerTask: Task<PreparedTrainingComputationResult?, Never>?
    @ObservationIgnored private var trainingPreparationToken = ""
    @ObservationIgnored private var activeIndexingRequestSignature: Int?
    @ObservationIgnored private var rateLimitResumeTask: Task<Void, Never>?
    @ObservationIgnored private var cachedTrainingSignature: Int?
    @ObservationIgnored private var cachedTrainingSnapshot: ActivityTrainingSnapshot?
    @ObservationIgnored private var cachedTrainingCurves: [String: ActivityBestEffortCurveSnapshot] = [:]
    @ObservationIgnored private var sessionInvalidationObserver: NSObjectProtocol?
    @ObservationIgnored private var coverageRefreshTask: Task<Void, Never>?

    var selectedTab: ActivitiesPageTab = .activities
    var query = ""
    var isConnecting = false
    var isSyncing = false
    var isIndexingDetails = false
    var indexedActivityCount = 0
    var totalActivityIndexCount = 0
    var activityDetailRateLimitResetAt: Date?
    var isImportingLocalActivities = false
    var isUploading = false
    var isPreparingForecast = false
    var isPreparingTraining = false
    var errorMessage: String?
    var statusMessage: String?
    private(set) var session: StravaSession?
    private(set) var preparedForecastSports: [RouteSportKind] = []
    private(set) var preparedForecastSnapshot: ActivityForecastSnapshot?
    private(set) var preparedForecastPresets: [ActivityForecastPreset] = []
    private(set) var preparedForecastPresetSnapshots: [String: ActivityForecastSnapshot] = [:]
    private(set) var preparedTrainingSports: [RouteSportKind] = []
    private(set) var preparedTrainingSnapshot: ActivityTrainingSnapshot?
    private(set) var preparedTrainingBestEffortCurve: ActivityBestEffortCurveSnapshot?
    private(set) var preparedTrainingBestEffortCurves: [String: ActivityBestEffortCurveSnapshot] = [:]
    var selectedSports: Set<RouteSportKind> = []
    var selectedSources: Set<ActivitySourceKind> = []
    var privacyFilter: ActivityPrivacyFilter = .all
    var minimumDistanceMeters: Double?
    var maximumDistanceMeters: Double?
    var minimumClimbMeters: Double?
    var maximumClimbMeters: Double?
    var sortCriteria: [ActivitySortCriterion] = [.defaultCriterion]

    @ObservationIgnored private var didPrimeActivities = false

    init() {
        sessionInvalidationObserver = NotificationCenter.default.addObserver(
            forName: StravaSessionNotifications.didInvalidate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.session = nil
            }
        }
        loadPersistedState()
        if AppUITestSupport.shouldUseStubSession {
            session = AppUITestSupport.makeStubSession()
        }
    }

    deinit {
        if let sessionInvalidationObserver {
            NotificationCenter.default.removeObserver(sessionInvalidationObserver)
        }
        indexingTask?.cancel()
        coverageRefreshTask?.cancel()
        forecastPreparationTask?.cancel()
        forecastPreparationWorkerTask?.cancel()
        trainingPreparationTask?.cancel()
        trainingPreparationWorkerTask?.cancel()
    }

    var credentialsDraft: StravaAppCredentials {
        StravaAppCredentials(
            clientID: AppConfiguration.clientID,
            clientSecret: AppConfiguration.clientSecret,
            redirectScheme: AppConfiguration.redirectScheme,
            redirectHost: AppConfiguration.redirectHost,
            authBrokerBaseURLString: AppConfiguration.authBrokerBaseURLString
        )
    }

    var isConnected: Bool {
        session != nil
    }

    var canSyncActivities: Bool {
        session?.hasActivityReadAccess == true
    }

    var canUploadActivities: Bool {
        session?.hasActivityWriteAccess == true
    }

    var isAnalyticsHydrating: Bool {
        isSyncing || isImportingLocalActivities || isIndexingDetails
    }

    var requiresReconnectForActivities: Bool {
        session != nil && !canSyncActivities
    }

    var requiresReconnectForUploads: Bool {
        session != nil && !canUploadActivities
    }

    #if DEBUG
    func installTestSession(_ session: StravaSession?) {
        self.session = session
    }
    #endif

    func prime(using context: ModelContext, existingActivities: [ActivityRecord]) async {
        guard !didPrimeActivities else {
            return
        }

        didPrimeActivities = true

        guard session != nil else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            return
        }

        await validatePersistedSessionIfNeeded()

        guard session != nil else {
            return
        }

        if existingActivities.isEmpty {
            await syncActivities(using: context)
        }
    }

    func connect() async {
        guard !isConnecting else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "Reviewer demo mode is using seeded local activities. Exit demo mode from Account settings to connect a real Strava account."
            return
        }

        do {
            let credentials = credentialsDraft
            try apiService.validate(credentials: credentials)
            try credentialStore.save(credentials: credentials)

            isConnecting = true
            errorMessage = nil
            statusMessage = nil

            let state = UUID().uuidString
            let authorizationURL = apiService.authorizationURL(credentials: credentials, state: state)
            let callbackURL = try await authCoordinator.authenticate(using: authorizationURL, callbackScheme: credentials.redirectScheme)
            let callback = try apiService.parseCallback(callbackURL, expectedState: state)
            let session = try await apiService.exchangeCode(callback.authorizationCode, credentials: credentials, acceptedScopes: callback.acceptedScopes)
            try credentialStore.save(session: session)

            self.session = session
            statusMessage = "Connected as \(session.athlete.displayName). Activity sync and uploads are ready."
            errorMessage = nil
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            if shouldSuppressErrorBanner(for: error) {
                errorMessage = nil
            } else {
                errorMessage = displayMessage(for: error)
            }
        }

        isConnecting = false
    }

    func disconnect() {
        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "Reviewer demo mode stays signed in locally. Exit demo mode from Account settings when you want to reconnect Strava."
            return
        }

        do {
            try credentialStore.clearSession()
            session = nil
            statusMessage = "Disconnected from Strava."
            errorMessage = nil
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }
    }

    func filteredActivities(from activities: [ActivityRecord]) -> [ActivityRecord] {
        let normalizedQuery = query.normalizedSearchText
        let queryTerms = normalizedQuery.split(separator: " ").map(String.init)
        let signature = filteredActivitiesSignature(for: activities)
        if cachedFilteredActivitiesSignature == signature,
           cachedFilteredActivitiesQuery == normalizedQuery {
            return cachedFilteredActivities
        }

        let filtered = activities
            .filter { activity in
                guard !normalizedQuery.isEmpty else {
                    return matchesActivityFilters(activity)
                }
                let haystack = activity.normalizedSearchHaystack
                return queryTerms.allSatisfy { haystack.contains($0) } && matchesActivityFilters(activity)
            }
            .sorted(by: compareActivities)

        cachedFilteredActivitiesSignature = signature
        cachedFilteredActivitiesQuery = normalizedQuery
        cachedFilteredActivities = filtered
        return filtered
    }

    func coverageSnapshot(from activities: [ActivityRecord]) -> ActivityCoverageSnapshot {
        coverageComputation(from: activities).snapshot
    }

    func activityListSummary(from activities: [ActivityRecord]) -> ActivityListSummarySnapshot {
        let signature = filteredActivitiesSignature(for: activities)
        if cachedActivityListSummarySignature == signature,
           let cachedActivityListSummary {
            return cachedActivityListSummary
        }

        let summary = ActivityListSummarySnapshot(
            activityCount: activities.count,
            distanceMeters: activities.reduce(0) { $0 + $1.distanceMeters },
            newCoverageMeters: activities.reduce(0) { $0 + $1.newCoverageMeters }
        )

        cachedActivityListSummarySignature = signature
        cachedActivityListSummary = summary
        return summary
    }

    func availableForecastSports(from activities: [ActivityRecord]) -> [RouteSportKind] {
        let signature = forecastSignature(for: activities)
        if cachedForecastSignature != signature {
            cachedForecastSignature = signature
            cachedForecastSports = ActivityForecastSupport.availableSports(from: forecastInputs(from: activities))
            cachedForecastSnapshots = [:]
        }

        return cachedForecastSports
    }

    var hasActiveFilters: Bool {
        !selectedSports.isEmpty
            || !selectedSources.isEmpty
            || privacyFilter != .all
            || minimumDistanceMeters != nil
            || maximumDistanceMeters != nil
            || minimumClimbMeters != nil
            || maximumClimbMeters != nil
    }

    var hasCustomSortCriteria: Bool {
        sortCriteria.count != 1
            || sortCriteria.first?.option != ActivitySortCriterion.defaultCriterion.option
            || sortCriteria.first?.direction != ActivitySortCriterion.defaultCriterion.direction
    }

    func resetFilters() {
        selectedSports = []
        selectedSources = []
        privacyFilter = .all
        minimumDistanceMeters = nil
        maximumDistanceMeters = nil
        minimumClimbMeters = nil
        maximumClimbMeters = nil
    }

    func resetSort() {
        sortCriteria = [.defaultCriterion]
    }

    func addSortCriterion(_ option: ActivitySortOption) {
        guard !sortCriteria.contains(where: { $0.option == option }) else {
            return
        }
        sortCriteria.append(ActivitySortCriterion(option: option, direction: .descending))
    }

    func updateSortCriterion(_ criterionID: UUID, option: ActivitySortOption) {
        guard let index = sortCriteria.firstIndex(where: { $0.id == criterionID }) else {
            return
        }
        sortCriteria[index].option = option
    }

    func updateSortCriterion(_ criterionID: UUID, direction: RouteSortDirection) {
        guard let index = sortCriteria.firstIndex(where: { $0.id == criterionID }) else {
            return
        }
        sortCriteria[index].direction = direction
    }

    func moveSortCriterion(_ criterionID: UUID, by offset: Int) {
        guard let index = sortCriteria.firstIndex(where: { $0.id == criterionID }) else {
            return
        }
        let destination = index + offset
        guard sortCriteria.indices.contains(destination) else {
            return
        }
        let criterion = sortCriteria.remove(at: index)
        sortCriteria.insert(criterion, at: destination)
    }

    func removeSortCriterion(_ criterionID: UUID) {
        guard sortCriteria.count > 1 else {
            return
        }
        sortCriteria.removeAll { $0.id == criterionID }
    }

    func forecastSnapshot(
        from activities: [ActivityRecord],
        sportKind: RouteSportKind,
        targetDistanceMeters: Double
    ) -> ActivityForecastSnapshot? {
        let signature = forecastSignature(for: activities)
        if cachedForecastSignature != signature {
            cachedForecastSignature = signature
            cachedForecastSports = ActivityForecastSupport.availableSports(from: forecastInputs(from: activities))
            cachedForecastSnapshots = [:]
        }

        let roundedDistanceMeters = Int(targetDistanceMeters.rounded())
        let cacheKey = "\(sportKind.rawValue)|\(roundedDistanceMeters)"
        if let cachedSnapshot = cachedForecastSnapshots[cacheKey] {
            return cachedSnapshot
        }

        let snapshot = ActivityForecastSupport.forecast(
            for: sportKind,
            targetDistanceMeters: targetDistanceMeters,
            activities: forecastInputs(from: activities)
        )
        if let snapshot {
            cachedForecastSnapshots[cacheKey] = snapshot
        }
        return snapshot
    }

    func forecastPreparationID(
        from activities: [ActivityRecord],
        selectedSportRawValue: String,
        targetDistanceMeters: Double?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(forecastSignature(for: activities))
        hasher.combine(selectedSportRawValue)
        hasher.combine(Int((targetDistanceMeters ?? -1).rounded()))
        return hasher.finalize()
    }

    func prepareForecastData(
        from activities: [ActivityRecord],
        selectedSportRawValue: String,
        targetDistanceMeters: Double?
    ) async {
        let inputs = forecastInputs(from: activities)
        let signature = forecastSignature(for: activities)
        let roundedDistanceMeters = Int((targetDistanceMeters ?? -1).rounded())
        let requestToken = "\(signature)|\(selectedSportRawValue)|\(roundedDistanceMeters)"

        if forecastPreparationToken == requestToken,
           !preparedForecastSports.isEmpty || !inputs.isEmpty {
            return
        }

        forecastPreparationTask?.cancel()
        forecastPreparationWorkerTask?.cancel()
        forecastPreparationToken = requestToken
        isPreparingForecast = true
        preparedForecastSnapshot = nil
        preparedForecastPresets = []
        preparedForecastPresetSnapshots = [:]

        let worker = Task.detached(priority: .utility) { () -> PreparedForecastComputationResult? in
            guard !Task.isCancelled else {
                return nil
            }
            let sports = ActivityForecastSupport.availableSports(from: inputs)
            let resolvedSport = sports.first(where: { $0.rawValue == selectedSportRawValue }) ?? sports.first
            let presets = resolvedSport == .run ? ActivityForecastSupport.roadRacePresets() : []
            var presetSnapshots: [String: ActivityForecastSnapshot] = [:]
            if let resolvedSport {
                for preset in presets {
                    guard !Task.isCancelled else {
                        return nil
                    }
                    if let snapshot = ActivityForecastSupport.forecast(
                        for: resolvedSport,
                        targetDistanceMeters: preset.distanceMeters,
                        activities: inputs
                    ) {
                        let cacheKey = "\(resolvedSport.rawValue)|\(Int(preset.distanceMeters.rounded()))"
                        presetSnapshots[cacheKey] = snapshot
                    }
                }
            }
            let snapshot: ActivityForecastSnapshot?
            if let resolvedSport, let targetDistanceMeters, targetDistanceMeters >= 500 {
                let cacheKey = "\(resolvedSport.rawValue)|\(Int(targetDistanceMeters.rounded()))"
                snapshot = presetSnapshots[cacheKey] ?? ActivityForecastSupport.forecast(
                    for: resolvedSport,
                    targetDistanceMeters: targetDistanceMeters,
                    activities: inputs
                )
            } else {
                snapshot = nil
            }

            guard !Task.isCancelled else {
                return nil
            }

            return PreparedForecastComputationResult(
                requestToken: requestToken,
                sports: sports,
                presets: presets,
                presetSnapshots: presetSnapshots,
                snapshot: snapshot
            )
        }
        forecastPreparationWorkerTask = worker

        forecastPreparationTask = Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self,
                  !Task.isCancelled,
                  self.forecastPreparationToken == requestToken else {
                return
            }

            guard let result else {
                self.isPreparingForecast = false
                return
            }

            self.preparedForecastSports = result.sports
            self.preparedForecastPresets = result.presets
            self.preparedForecastPresetSnapshots = result.presetSnapshots
            for (cacheKey, snapshot) in result.presetSnapshots {
                self.cachedForecastSnapshots[cacheKey] = snapshot
            }
            self.preparedForecastSnapshot = result.snapshot
            self.isPreparingForecast = false
        }

        await forecastPreparationTask?.value
    }

    func trainingPreparationID(
        from activities: [ActivityRecord],
        selectedSportRawValue: String
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(forecastSignature(for: activities))
        hasher.combine(selectedSportRawValue)
        return hasher.finalize()
    }

    func prepareTrainingData(
        from activities: [ActivityRecord],
        selectedSportRawValue: String
    ) async {
        let inputs = forecastInputs(from: activities)
        let signature = forecastSignature(for: activities)
        let requestToken = "\(signature)|\(selectedSportRawValue)"

        if trainingPreparationToken == requestToken,
           preparedTrainingSnapshot != nil || inputs.isEmpty {
            return
        }

        trainingPreparationTask?.cancel()
        trainingPreparationWorkerTask?.cancel()
        trainingPreparationToken = requestToken
        isPreparingTraining = true
        preparedTrainingSnapshot = nil
        preparedTrainingBestEffortCurve = nil
        preparedTrainingBestEffortCurves = [:]

        let worker = Task.detached(priority: .utility) { () -> PreparedTrainingComputationResult? in
            guard !Task.isCancelled else {
                return nil
            }
            let snapshot = inputs.isEmpty ? nil : ActivityTrainingInsightsSupport.snapshot(from: inputs)
            let sports = snapshot?.sportMix.map(\.sportKind) ?? []
            let resolvedSport = sports.first(where: { $0.rawValue == selectedSportRawValue }) ?? sports.first
            var curves: [String: ActivityBestEffortCurveSnapshot] = [:]
            for sport in sports {
                guard !Task.isCancelled else {
                    return nil
                }
                if let curve = ActivityTrainingInsightsSupport.bestEffortCurve(from: inputs, sportKind: sport) {
                    curves[sport.rawValue] = curve
                }
            }
            let bestEffortCurve = resolvedSport.flatMap { curves[$0.rawValue] }

            guard !Task.isCancelled else {
                return nil
            }

            return PreparedTrainingComputationResult(
                requestToken: requestToken,
                sports: sports,
                snapshot: snapshot,
                curves: curves,
                bestEffortCurve: bestEffortCurve
            )
        }
        trainingPreparationWorkerTask = worker

        trainingPreparationTask = Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self,
                  !Task.isCancelled,
                  self.trainingPreparationToken == requestToken else {
                return
            }

            guard let result else {
                self.isPreparingTraining = false
                return
            }

            self.preparedTrainingSports = result.sports
            self.preparedTrainingSnapshot = result.snapshot
            self.preparedTrainingBestEffortCurves = result.curves
            self.preparedTrainingBestEffortCurve = result.bestEffortCurve
            self.isPreparingTraining = false
        }

        await trainingPreparationTask?.value
    }

    func trainingSnapshot(from activities: [ActivityRecord]) -> ActivityTrainingSnapshot {
        let signature = forecastSignature(for: activities)
        if cachedTrainingSignature == signature, let cachedTrainingSnapshot {
            return cachedTrainingSnapshot
        }

        let snapshot = ActivityTrainingInsightsSupport.snapshot(from: forecastInputs(from: activities))
        cachedTrainingSignature = signature
        cachedTrainingSnapshot = snapshot
        cachedTrainingCurves = [:]
        return snapshot
    }

    func bestEffortCurve(from activities: [ActivityRecord], sportKind: RouteSportKind) -> ActivityBestEffortCurveSnapshot? {
        let signature = forecastSignature(for: activities)
        if cachedTrainingSignature != signature {
            cachedTrainingSignature = signature
            cachedTrainingSnapshot = ActivityTrainingInsightsSupport.snapshot(from: forecastInputs(from: activities))
            cachedTrainingCurves = [:]
        }

        if let cachedCurve = cachedTrainingCurves[sportKind.rawValue] {
            return cachedCurve
        }

        let curve = ActivityTrainingInsightsSupport.bestEffortCurve(from: forecastInputs(from: activities), sportKind: sportKind)
        if let curve {
            cachedTrainingCurves[sportKind.rawValue] = curve
        }
        return curve
    }

    func ensureIndexedActivityDetails(using context: ModelContext, activities: [ActivityRecord]) {
        clearExpiredActivityDetailRateLimit()
        guard activityDetailRateLimitResetAt == nil else {
            return
        }

        let needsIndexing = activities.contains { activity in
            guard activity.sourceKind == .strava else {
                return false
            }

            return !activity.hasDetailedGeometry
                || activity.elevationProfileBlob?.trimmed.nilIfEmpty == nil
                || shouldResolveLocationDetails(for: activity)
                || !activity.effortAnalysisIsCurrent
                || activity.coverageIndexedAt == nil
        }

        guard needsIndexing else {
            return
        }

        scheduleIndexingIfNeeded(using: context, activities: activities, delay: .milliseconds(250))
    }

    func ensureAnalyticsHydration(using context: ModelContext, activities: [ActivityRecord]) {
        clearExpiredActivityDetailRateLimit()
        guard !isIndexingDetails else {
            return
        }

        guard !isSyncing, !isImportingLocalActivities else {
            return
        }

        guard activityDetailRateLimitResetAt == nil else {
            return
        }

        guard pendingAnalyticsHydrationCount(in: activities) > 0 else {
            return
        }

        guard let session, session.hasActivityReadAccess else {
            return
        }

        scheduleIndexingIfNeeded(using: context, activities: activities, delay: .zero)
    }

    func analyticsBlockingState(for activities: [ActivityRecord]) -> AnalyticsBlockingState? {
        if isSyncing {
            return AnalyticsBlockingState(
                title: "Syncing Activity History",
                message: "Pulling your latest workouts from Strava before forecast and training analysis update.",
                completedCount: nil,
                totalCount: nil
            )
        }

        if isImportingLocalActivities {
            return AnalyticsBlockingState(
                title: "Importing Activities",
                message: "Bringing local workout files into the activity library before analytics refresh.",
                completedCount: nil,
                totalCount: nil
            )
        }

        let pendingCount = pendingAnalyticsHydrationCount(in: activities)
        let canHydrate = session?.hasActivityReadAccess == true
        if let resetAt = activityDetailRateLimitResetAt, resetAt > .now, pendingCount > 0 {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return AnalyticsBlockingState(
                title: "Workout Sync Paused",
                message: "Strava rate limits were reached. Sync will resume after \(formatter.string(from: resetAt)).",
                completedCount: nil,
                totalCount: nil
            )
        }

        if isIndexingDetails {
            let resolvedTotal = max(totalActivityIndexCount, pendingCount)
            let resolvedCompleted = min(indexedActivityCount, resolvedTotal)
            return AnalyticsBlockingState(
                title: "Syncing Workout Details",
                message: "Fetching route streams, elevation, and effort analysis so forecast and training can use complete workout data.",
                completedCount: resolvedTotal > 0 ? resolvedCompleted : nil,
                totalCount: resolvedTotal > 0 ? resolvedTotal : nil
            )
        }

        if pendingCount > 0 && canHydrate {
            return AnalyticsBlockingState(
                title: "Preparing Workout Sync",
                message: "Queueing workout-detail sync so forecast and training can use complete data.",
                completedCount: nil,
                totalCount: nil
            )
        }

        return nil
    }

    func analyticsBlockingSignature(for activities: [ActivityRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(isSyncing)
        hasher.combine(isImportingLocalActivities)
        hasher.combine(isIndexingDetails)
        hasher.combine(indexedActivityCount)
        hasher.combine(totalActivityIndexCount)
        hasher.combine(pendingAnalyticsHydrationCount(in: activities))
        hasher.combine(session?.hasActivityReadAccess == true)
        return hasher.finalize()
    }

    func cancelActivityIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        rateLimitResumeTask?.cancel()
        rateLimitResumeTask = nil
        activeIndexingRequestSignature = nil
        isIndexingDetails = false
        indexedActivityCount = 0
        totalActivityIndexCount = 0
    }

    func syncActivities(using context: ModelContext) async {
        guard !isSyncing else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "Reviewer demo mode already includes seeded activities."
            return
        }

        guard let session else {
            errorMessage = "Connect Strava before syncing activities."
            return
        }

        guard session.hasActivityReadAccess else {
            errorMessage = "Reconnect Strava and grant activity access before syncing activities."
            return
        }

        do {
            isSyncing = true
            errorMessage = nil
            statusMessage = nil

            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            var activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)

            do {
                let summaries = try await apiService.fetchAllActivities(accessToken: activeSession.accessToken)
                let summary = try importActivities(summaries, into: context)
                try credentialStore.save(session: activeSession)
                self.session = activeSession
                statusMessage = summary
            } catch StravaAPIService.APIError.unauthorized {
                activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials, forceRefresh: true)
                let summaries = try await apiService.fetchAllActivities(accessToken: activeSession.accessToken)
                let summary = try importActivities(summaries, into: context)
                try credentialStore.save(session: activeSession)
                self.session = activeSession
                statusMessage = summary
            }
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }

        isSyncing = false
    }

    func refreshActivityDetail(_ activity: ActivityRecord, using context: ModelContext) async {
        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "\(activity.name) is already using local demo data."
            return
        }

        guard let session else {
            errorMessage = "Connect Strava before refreshing activities."
            return
        }

        guard let activityID = activity.stravaActivityID else {
            return
        }

        guard session.hasActivityReadAccess else {
            errorMessage = "Reconnect Strava and grant activity access before refreshing activities."
            return
        }

        do {
            errorMessage = nil
            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            let activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            try credentialStore.save(session: activeSession)
            self.session = activeSession

            let payload = try await fetchRemoteDetailPayload(
                for: activity,
                activityID: activityID,
                accessToken: activeSession.accessToken,
                shouldFetchLocationDetails: true
            )

            activity.applyStreams(payload.streams, indexedAt: .now)
            let effortAnalysis = await ActivityEffortAnalysisService.analyze(
                activity: activity,
                detailedActivity: nil,
                streams: payload.streams
            )
            activity.applyEffortAnalysis(effortAnalysis)
            applyResolvedLocationDetails(payload.locationDetails, to: activity)

            try context.save()
            refreshEffortAnalyses(using: context)
            scheduleCoverageRefresh(using: context)
            statusMessage = "Refreshed \(activity.name)."
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }
    }

    func saveActivityAsRoute(_ activity: ActivityRecord, using context: ModelContext) {
        do {
            let routeID = stableLocalRouteID(for: activity)
            let importedRoute = activity.asImportedRoute(routeID: routeID)
            let routes = try context.fetch(FetchDescriptor<RouteRecord>())

            if let existingRoute = routes.first(where: { $0.stravaRouteID == routeID }) {
                existingRoute.apply(importedGPX: importedRoute, syncedAt: .now)
            } else {
                context.insert(RouteRecord(importedGPX: importedRoute, syncedAt: .now))
            }

            try context.save()
            statusMessage = "Saved \(activity.name) to your route library."
            errorMessage = nil
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }
    }

    func importLocalActivities(from urls: [URL], using context: ModelContext) async {
        guard !isImportingLocalActivities else {
            return
        }

        let files = Array(Set(urls)).sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else {
            return
        }

        isImportingLocalActivities = true
        errorMessage = nil
        statusMessage = nil

        do {
            var insertedCount = 0
            var updatedCount = 0
            var failures: [String] = []
            let existingActivities = try context.fetch(FetchDescriptor<ActivityRecord>())

            for url in files {
                do {
                    let importedRoute = try await gpxImportService.importRoute(from: url)
                    let activity = makeLocalActivity(from: importedRoute)

                    if let existing = existingActivities.first(where: {
                        $0.sourceKind == .local &&
                        $0.name.routeLocationToken == activity.name.routeLocationToken &&
                        abs($0.startDate.timeIntervalSince(activity.startDate)) < 60 &&
                        $0.activityGeometryPolyline.routeLocationToken == activity.activityGeometryPolyline.routeLocationToken
                    }) {
                        apply(localActivity: activity, to: existing)
                        updatedCount += 1
                    } else {
                        context.insert(activity)
                        insertedCount += 1
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(displayMessage(for: error))")
                }
            }

            if insertedCount > 0 || updatedCount > 0 {
                try context.save()
                scheduleCoverageRefresh(using: context)
                statusMessage = "Imported \(insertedCount + updatedCount) local activit\(insertedCount + updatedCount == 1 ? "y" : "ies")."
            }

            if !failures.isEmpty {
                errorMessage = failures.count == 1 ? failures[0] : "\(failures.count) activity files could not be imported. \(failures[0])"
            }
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }

        isImportingLocalActivities = false
    }

    func uploadActivity(_ activity: ActivityRecord, using context: ModelContext) async {
        guard !isUploading else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "Activity upload is disabled in reviewer demo mode."
            return
        }

        guard let session else {
            errorMessage = "Connect Strava before uploading activities."
            return
        }

        guard session.hasActivityWriteAccess else {
            errorMessage = "Reconnect Strava and grant activity upload access before uploading activities."
            return
        }

        do {
            isUploading = true
            errorMessage = nil

            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            let activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            try credentialStore.save(session: activeSession)
            self.session = activeSession

            let fileData = try activity.exportGPXData()
            let externalID = "\(activity.activityKey)-\(Int(Date().timeIntervalSince1970))"
            let uploadPayload = try await apiService.uploadActivityGPX(
                fileData: fileData,
                fileName: "\(activity.name.replacingOccurrences(of: " ", with: "-")).gpx",
                name: activity.name,
                description: activity.activityDescription.trimmed.nilIfEmpty,
                sportType: uploadSportType(for: activity.sportKind),
                accessToken: activeSession.accessToken,
                externalID: externalID
            )

            activity.markUploadStarted(uploadID: uploadPayload.numericID, externalID: externalID)
            activity.applyUploadStatus(uploadPayload)
            try context.save()

            if let uploadID = uploadPayload.numericID {
                let finalStatus = try await pollUploadStatus(
                    uploadID: uploadID,
                    session: activeSession,
                    credentials: credentials
                )
                activity.applyUploadStatus(finalStatus)
                try context.save()
            }

            if let uploadedActivityID = activity.uploadedActivityID {
                statusMessage = "Uploaded \(activity.name) to Strava as activity \(uploadedActivityID)."
            } else {
                statusMessage = activity.lastUploadStatus?.trimmed.nilIfEmpty ?? "Uploaded activity to Strava."
            }
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }

        isUploading = false
    }

    private struct ActivityRemoteDetailPayload {
        let streams: StravaActivityStreamsPayload
        let locationDetails: RouteStartLocationDetails?
    }

    private func fetchRemoteDetailPayload(
        for activity: ActivityRecord,
        activityID: Int,
        accessToken: String,
        shouldFetchLocationDetails: Bool
    ) async throws -> ActivityRemoteDetailPayload {
        let streams = try await apiService.fetchActivityStreams(activityID: activityID, accessToken: accessToken)

        let locationDetails: RouteStartLocationDetails?
        if shouldFetchLocationDetails,
           let coordinate = resolvedStartCoordinate(
                from: streams,
                fallback: activity.startCoordinate
           ) {
            locationDetails = try await locationResolver.details(
                for: coordinate,
                fallbackName: activity.displayLocation.nilIfEmpty ?? activity.name
            )
        } else {
            locationDetails = nil
        }

        return ActivityRemoteDetailPayload(
            streams: streams,
            locationDetails: locationDetails
        )
    }

    private func shouldResolveLocationDetails(for activity: ActivityRecord) -> Bool {
        activity.startRegionName?.trimmed.nilIfEmpty == nil
            || activity.startParkName?.trimmed.nilIfEmpty == nil
            || activity.startCountyName?.trimmed.nilIfEmpty == nil
            || activity.city.trimmed.nilIfEmpty == nil
            || activity.state.trimmed.nilIfEmpty == nil
            || activity.country.trimmed.nilIfEmpty == nil
    }

    private func applyResolvedLocationDetails(_ details: RouteStartLocationDetails?, to activity: ActivityRecord) {
        guard let details else {
            return
        }

        activity.startRegionName = details.regionName.trimmed.nilIfEmpty
        activity.startParkName = details.parkName.trimmed.nilIfEmpty
        activity.startCountyName = details.countyName.trimmed.nilIfEmpty
        activity.city = details.cityName.trimmed.nilIfEmpty ?? activity.city
        activity.state = details.stateName.trimmed.nilIfEmpty ?? activity.state
        activity.country = details.countryName.trimmed.nilIfEmpty ?? activity.country
    }

    private func resolvedStartCoordinate(
        from streams: StravaActivityStreamsPayload,
        fallback: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        if let firstPair = streams.latlng?.data.first,
           firstPair.count >= 2 {
            return CLLocationCoordinate2D(latitude: firstPair[0], longitude: firstPair[1])
        }

        return fallback
    }

    private func scheduleCoverageRefresh(using context: ModelContext, activities: [ActivityRecord]? = nil) {
        let sourceActivities = activities ?? (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? []
        let inputs = coverageInputs(from: sourceActivities)
        let signature = coverageSignature(for: inputs)

        coverageRefreshTask?.cancel()

        guard !inputs.isEmpty else {
            cachedCoverageSignature = signature
            cachedCoverageComputation = ActivityCoverageSupport.compute(from: inputs)
            return
        }

        coverageRefreshTask = Task(priority: .utility) { @MainActor [inputs, signature] in
            let computation = await Task.detached(priority: .utility) {
                ActivityCoverageSupport.compute(from: inputs)
            }.value

            guard !Task.isCancelled else {
                return
            }

            applyCoverageComputation(computation, expectedSignature: signature, using: context)
        }
    }

    private func applyCoverageComputation(
        _ computation: ActivityCoverageComputation,
        expectedSignature: Int,
        using context: ModelContext
    ) {
        let activities = (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? []
        let currentInputs = coverageInputs(from: activities)
        let currentSignature = coverageSignature(for: currentInputs)

        guard currentSignature == expectedSignature else {
            scheduleCoverageRefresh(using: context, activities: activities)
            return
        }

        cachedCoverageSignature = currentSignature
        cachedCoverageComputation = computation

        var didChange = false
        for activity in activities {
            let newCoverage = computation.newCoverageByActivityKey[activity.activityKey] ?? 0
            if abs(activity.newCoverageMeters - newCoverage) > 0.5 || activity.coverageIndexedAt == nil {
                activity.newCoverageMeters = newCoverage
                activity.coverageIndexedAt = .now
                didChange = true
            }
        }

        if didChange {
            try? context.save()
        }
    }

    private func loadPersistedState() {
        let credentials = credentialsDraft
        if let storedCredentials = try? credentialStore.loadCredentials() {
            if storedCredentials != credentials {
                try? credentialStore.save(credentials: credentials)
            }
        } else {
            try? credentialStore.save(credentials: credentials)
        }

        if AppUITestSupport.shouldUseStubSession {
            session = AppUITestSupport.makeStubSession()
        } else if let session = try? credentialStore.loadSession() {
            self.session = session
        }
    }

    private func validatePersistedSessionIfNeeded() async {
        guard !AppUITestSupport.shouldUseStubSession else {
            return
        }

        guard let session else {
            return
        }

        do {
            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            let refreshedSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            self.session = refreshedSession
            try credentialStore.save(session: refreshedSession)
        } catch {
            guard shouldInvalidateSession(for: error) else {
                return
            }

            invalidateSession()
            errorMessage = displayMessage(for: error)
        }
    }

    private func importActivities(_ summaries: [StravaActivitySummaryPayload], into context: ModelContext) throws -> String {
        let syncedAt = Date()
        let existingActivities = try context.fetch(FetchDescriptor<ActivityRecord>())
        let indexedActivities = Dictionary(uniqueKeysWithValues: existingActivities.map { ($0.activityKey, $0) })

        var insertedCount = 0
        var updatedCount = 0

        for summary in summaries {
            let key = "strava-\(summary.id)"
            if let existing = indexedActivities[key] {
                existing.applySummary(summary, syncedAt: syncedAt)
                updatedCount += 1
            } else {
                context.insert(ActivityRecord(remote: summary, syncedAt: syncedAt))
                insertedCount += 1
            }
        }

        try context.save()
        return "Synced \(summaries.count) activit\(summaries.count == 1 ? "y" : "ies"). \(insertedCount) new, \(updatedCount) refreshed."
    }

    private func scheduleIndexingIfNeeded(
        using context: ModelContext,
        activities: [ActivityRecord],
        delay: Duration
    ) {
        let requestSignature = analyticsHydrationRequestSignature(for: activities)
        if activeIndexingRequestSignature == requestSignature {
            return
        }

        indexingTask?.cancel()
        activeIndexingRequestSignature = requestSignature
        indexingTask = Task { @MainActor [weak self] in
            defer {
                if let self {
                    if self.activeIndexingRequestSignature == requestSignature {
                        self.activeIndexingRequestSignature = nil
                    }
                    self.indexingTask = nil
                }
            }

            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else {
                return
            }

            let latestActivities: [ActivityRecord]
            do {
                latestActivities = try context.fetch(FetchDescriptor<ActivityRecord>())
            } catch {
                latestActivities = activities
            }

            await self.indexMissingDetailsIfNeeded(using: context, activities: latestActivities)
        }
    }

    private func indexMissingDetailsIfNeeded(using context: ModelContext, activities: [ActivityRecord]) async {
        clearExpiredActivityDetailRateLimit()
        guard !isIndexingDetails else {
            return
        }

        guard activityDetailRateLimitResetAt == nil else {
            return
        }

        let coverageNeedsRefresh = activities.contains { $0.coverageIndexedAt == nil }
        let candidates = activities
            .filter { activity in
                guard activity.sourceKind == .strava else {
                    return false
                }

                return !activity.hasDetailedGeometry
                    || activity.elevationProfileBlob?.trimmed.nilIfEmpty == nil
                    || shouldResolveLocationDetails(for: activity)
                    || !activity.effortAnalysisIsCurrent
            }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.activityKey < rhs.activityKey
                }

                return lhs.startDate > rhs.startDate
            }

        guard !candidates.isEmpty else {
            if coverageNeedsRefresh {
                scheduleCoverageRefresh(using: context, activities: activities)
            }
            indexedActivityCount = 0
            totalActivityIndexCount = 0
            return
        }

        guard let session, session.hasActivityReadAccess else {
            return
        }

        do {
            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            var activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            try credentialStore.save(session: activeSession)
            self.session = activeSession

            isIndexingDetails = true
            totalActivityIndexCount = candidates.count
            indexedActivityCount = 0
            defer {
                isIndexingDetails = false
            }

            var processedCount = 0
            var didPauseForRateLimit = false

            detailLoop: for activity in candidates {
                if Task.isCancelled {
                    break
                }

                guard let activityID = activity.stravaActivityID else {
                    processedCount += 1
                    indexedActivityCount = processedCount
                    await Task.yield()
                    continue
                }

                do {
                    let needsRemoteDetail = !activity.hasDetailedGeometry || activity.elevationProfileBlob?.trimmed.nilIfEmpty == nil
                    let needsEffortAnalysis = !activity.effortAnalysisIsCurrent
                    let needsLocationDetails = shouldResolveLocationDetails(for: activity)

                    if needsRemoteDetail || needsEffortAnalysis {
                        let payload = try await fetchRemoteDetailPayload(
                            for: activity,
                            activityID: activityID,
                            accessToken: activeSession.accessToken,
                            shouldFetchLocationDetails: needsLocationDetails
                        )
                        activity.applyStreams(payload.streams, indexedAt: .now)
                        let effortAnalysis = await ActivityEffortAnalysisService.analyze(
                            activity: activity,
                            detailedActivity: nil,
                            streams: payload.streams
                        )
                        activity.applyEffortAnalysis(effortAnalysis)
                        applyResolvedLocationDetails(payload.locationDetails, to: activity)
                    } else if needsLocationDetails,
                              let coordinate = activity.startCoordinate {
                        let details = try await locationResolver.details(
                            for: coordinate,
                            fallbackName: activity.displayLocation.nilIfEmpty ?? activity.name
                        )
                        applyResolvedLocationDetails(details, to: activity)
                    }
                } catch let apiError as StravaAPIService.APIError {
                    switch apiError {
                    case .unauthorized:
                        activeSession = try await apiService.refreshedSessionIfNeeded(activeSession, credentials: credentials, forceRefresh: true)
                        try credentialStore.save(session: activeSession)
                        self.session = activeSession
                    case let .rateLimited(message, retryAfter):
                        activityDetailRateLimitResetAt = retryAfter
                        statusMessage = message
                        errorMessage = nil
                        didPauseForRateLimit = true
                        break detailLoop
                    default:
                        errorMessage = displayMessage(for: apiError)
                    }
                } catch {
                    errorMessage = displayMessage(for: error)
                }

                processedCount += 1
                indexedActivityCount = processedCount

                if processedCount.isMultiple(of: 24) {
                    try context.save()
                }

                await Task.yield()
            }

            indexedActivityCount = processedCount
            if didPauseForRateLimit {
                try context.save()
                scheduleRateLimitResume(using: context)
                return
            }
            refreshEffortAnalyses(using: context, activities: activities)
            try context.save()
            if coverageNeedsRefresh {
                scheduleCoverageRefresh(using: context)
            }
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }
    }

    private func coverageComputation(from activities: [ActivityRecord]) -> ActivityCoverageComputation {
        let inputs = coverageInputs(from: activities)
        let signature = coverageSignature(for: inputs)
        if let cachedCoverageComputation, cachedCoverageSignature == signature {
            return cachedCoverageComputation
        }

        let computation = ActivityCoverageSupport.compute(from: inputs)
        cachedCoverageSignature = signature
        cachedCoverageComputation = computation
        return computation
    }

    private func coverageInputs(from activities: [ActivityRecord]) -> [ActivityCoverageInput] {
        let signature = coverageSignature(for: activities)
        if cachedCoverageInputSignature == signature {
            return cachedCoverageInputs
        }

        let inputs = activities.map(ActivityCoverageInput.init)
        cachedCoverageInputSignature = signature
        cachedCoverageInputs = inputs
        return inputs
    }

    private func pendingAnalyticsHydrationCount(in activities: [ActivityRecord]) -> Int {
        activities.reduce(into: 0) { count, activity in
            if requiresAnalyticsHydration(for: activity) {
                count += 1
            }
        }
    }

    private func clearExpiredActivityDetailRateLimit() {
        guard let resetAt = activityDetailRateLimitResetAt else {
            return
        }

        if resetAt <= .now {
            activityDetailRateLimitResetAt = nil
            rateLimitResumeTask?.cancel()
            rateLimitResumeTask = nil
        }
    }

    private func scheduleRateLimitResume(using context: ModelContext) {
        rateLimitResumeTask?.cancel()

        guard let resetAt = activityDetailRateLimitResetAt, resetAt > .now else {
            activityDetailRateLimitResetAt = nil
            rateLimitResumeTask = nil
            return
        }

        rateLimitResumeTask = Task { @MainActor [weak self] in
            let waitInterval = max(resetAt.timeIntervalSinceNow, 0)
            if waitInterval > 0 {
                try? await Task.sleep(for: .seconds(waitInterval))
            }

            guard let self, !Task.isCancelled else {
                return
            }

            self.activityDetailRateLimitResetAt = nil
            self.rateLimitResumeTask = nil

            let activities = (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? []
            self.ensureAnalyticsHydration(using: context, activities: activities)
        }
    }

    func analyticsReadinessSignature(for activities: [ActivityRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(isSyncing)
        hasher.combine(isImportingLocalActivities)
        hasher.combine(isIndexingDetails)
        hasher.combine(pendingAnalyticsHydrationCount(in: activities) > 0)
        hasher.combine(session?.hasActivityReadAccess == true)
        hasher.combine(activityDetailRateLimitResetAt?.timeIntervalSinceReferenceDate ?? 0)
        return hasher.finalize()
    }

    private func requiresAnalyticsHydration(for activity: ActivityRecord) -> Bool {
        guard activity.sourceKind == .strava else {
            return false
        }

        return !activity.hasDetailedGeometry
            || activity.elevationProfileBlob?.trimmed.nilIfEmpty == nil
            || !activity.effortAnalysisIsCurrent
    }

    private func analyticsHydrationRequestSignature(for activities: [ActivityRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(activities.count)
        for activity in activities where requiresAnalyticsHydration(for: activity) {
            hasher.combine(activity.activityKey)
            hasher.combine(activity.syncedAt.timeIntervalSinceReferenceDate)
            hasher.combine(activity.detailIndexedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.effortAnalysisComputedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.elevationProfileBlob?.isEmpty == false)
            hasher.combine(activity.activityDetailPolyline?.isEmpty == false)
        }
        hasher.combine(session?.hasActivityReadAccess == true)
        return hasher.finalize()
    }

    private func forecastInputs(from activities: [ActivityRecord]) -> [ActivityForecastInput] {
        let signature = forecastSignature(for: activities)
        if cachedForecastInputSignature == signature {
            return cachedForecastInputs
        }

        let inputs = activities.map(ActivityForecastInput.init)
        cachedForecastInputSignature = signature
        cachedForecastInputs = inputs
        return inputs
    }

    private func coverageSignature(for activities: [ActivityRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(activities.count)

        for activity in activities {
            hasher.combine(activity.activityKey)
            hasher.combine(activity.startDate.timeIntervalSinceReferenceDate)
            hasher.combine(activity.distanceMeters)
            hasher.combine(activity.elevationGainMeters)
            hasher.combine(activity.syncedAt.timeIntervalSinceReferenceDate)
            hasher.combine(activity.updatedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.detailIndexedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.coverageIndexedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.city)
            hasher.combine(activity.state)
            hasher.combine(activity.country)
            hasher.combine(activity.startParkName ?? "")
            hasher.combine(activity.startRegionName ?? "")
            hasher.combine(activity.startCountyName ?? "")
        }

        return hasher.finalize()
    }

    private func coverageSignature(for activities: [ActivityCoverageInput]) -> Int {
        var hasher = Hasher()
        hasher.combine(activities.count)

        for activity in activities {
            hasher.combine(activity.activityKey)
            hasher.combine(activity.startDate.timeIntervalSinceReferenceDate)
            hasher.combine(activity.distanceMeters)
            hasher.combine(activity.elevationGainMeters)
            hasher.combine(activity.city)
            hasher.combine(activity.normalizedStateDisplayName)
            hasher.combine(activity.country)
            hasher.combine(activity.startParkName ?? "")
            hasher.combine(activity.displayLocation)
        }

        return hasher.finalize()
    }

    private func forecastSignature(for activities: [ActivityRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(activities.count)

        for activity in activities {
            hasher.combine(activity.activityKey)
            hasher.combine(activity.name)
            hasher.combine(activity.startDate.timeIntervalSinceReferenceDate)
            hasher.combine(activity.distanceMeters)
            hasher.combine(activity.movingTime)
            hasher.combine(activity.elapsedTime)
            hasher.combine(activity.elevationGainMeters)
            hasher.combine(activity.averageSpeedMetersPerSecond)
            hasher.combine(activity.sportTypeRawValue)
            hasher.combine(activity.legacyTypeRawValue)
            hasher.combine(activity.hasHeartrate)
            hasher.combine(activity.averageHeartRateBpm ?? 0)
            hasher.combine(activity.maxHeartRateBpm ?? 0)
            hasher.combine(activity.updatedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.syncedAt.timeIntervalSinceReferenceDate)
            hasher.combine(activity.detailIndexedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.effortAnalysisVersion)
            hasher.combine(activity.effortAnalysisComputedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.effortAnalysisBlob ?? "")
            hasher.combine(activity.elevationProfileBlob?.count ?? 0)
            hasher.combine(activity.city)
            hasher.combine(activity.state)
            hasher.combine(activity.country)
            hasher.combine(activity.startParkName ?? "")
            hasher.combine(activity.startRegionName ?? "")
            hasher.combine(activity.startCountyName ?? "")
        }

        return hasher.finalize()
    }

    private func refreshEffortAnalyses(using context: ModelContext, activities: [ActivityRecord]? = nil) {
        let sourceActivities = activities ?? (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? []
        let refreshedAnalyses = ActivityEffortAnalysisService.refreshedAnalyses(for: sourceActivities)
        guard !refreshedAnalyses.isEmpty else {
            return
        }

        for activity in sourceActivities {
            guard let analysis = refreshedAnalyses[activity.activityKey] else {
                continue
            }
            activity.applyEffortAnalysis(analysis)
        }
    }

    private func filteredActivitiesSignature(for activities: [ActivityRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(activities.count)
        hasher.combine(selectedSports.map(\.rawValue).sorted().joined(separator: "|"))
        hasher.combine(selectedSources.map(\.rawValue).sorted().joined(separator: "|"))
        hasher.combine(privacyFilter.rawValue)
        hasher.combine(minimumDistanceMeters ?? -1)
        hasher.combine(maximumDistanceMeters ?? -1)
        hasher.combine(minimumClimbMeters ?? -1)
        hasher.combine(maximumClimbMeters ?? -1)
        hasher.combine(sortCriteria.map { "\($0.option.rawValue):\($0.direction.rawValue)" }.joined(separator: "|"))

        for activity in activities {
            hasher.combine(activity.activityKey)
            hasher.combine(activity.name)
            hasher.combine(activity.activityDescription)
            hasher.combine(activity.startDate.timeIntervalSinceReferenceDate)
            hasher.combine(activity.updatedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.syncedAt.timeIntervalSinceReferenceDate)
            hasher.combine(activity.city)
            hasher.combine(activity.state)
            hasher.combine(activity.country)
            hasher.combine(activity.startParkName ?? "")
            hasher.combine(activity.startRegionName ?? "")
            hasher.combine(activity.startCountyName ?? "")
            hasher.combine(activity.sportTypeRawValue)
            hasher.combine(activity.legacyTypeRawValue)
            hasher.combine(activity.distanceMeters)
            hasher.combine(activity.elevationGainMeters)
            hasher.combine(activity.movingTime)
            hasher.combine(activity.elapsedTime)
            hasher.combine(activity.isPrivate)
            hasher.combine(activity.sourceRawValue)
        }

        return hasher.finalize()
    }

    private func matchesActivityFilters(_ activity: ActivityRecord) -> Bool {
        if !selectedSports.isEmpty && !selectedSports.contains(activity.sportKind) {
            return false
        }

        if !selectedSources.isEmpty && !selectedSources.contains(activity.sourceKind) {
            return false
        }

        switch privacyFilter {
        case .all:
            break
        case .public:
            guard !activity.isPrivate else { return false }
        case .private:
            guard activity.isPrivate else { return false }
        }

        if let minimumDistanceMeters, activity.distanceMeters < minimumDistanceMeters {
            return false
        }

        if let maximumDistanceMeters, activity.distanceMeters > maximumDistanceMeters {
            return false
        }

        if let minimumClimbMeters, activity.elevationGainMeters < minimumClimbMeters {
            return false
        }

        if let maximumClimbMeters, activity.elevationGainMeters > maximumClimbMeters {
            return false
        }

        return true
    }

    private func compareActivities(_ lhs: ActivityRecord, _ rhs: ActivityRecord) -> Bool {
        for criterion in sortCriteria {
            let comparison = compare(lhs, rhs, using: criterion)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }

        return lhs.startDate > rhs.startDate
    }

    private func compare(
        _ lhs: ActivityRecord,
        _ rhs: ActivityRecord,
        using criterion: ActivitySortCriterion
    ) -> ComparisonResult {
        let base: ComparisonResult

        switch criterion.option {
        case .startDate:
            base = compare(lhs.startDate, rhs.startDate)
        case .updatedAt:
            base = compare(lhs.updatedAt ?? lhs.syncedAt, rhs.updatedAt ?? rhs.syncedAt)
        case .name:
            base = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .distance:
            base = compare(lhs.distanceMeters, rhs.distanceMeters)
        case .climb:
            base = compare(lhs.elevationGainMeters, rhs.elevationGainMeters)
        case .movingTime:
            base = compare(max(lhs.movingTime, lhs.elapsedTime), max(rhs.movingTime, rhs.elapsedTime))
        }

        switch criterion.direction {
        case .descending:
            return base == .orderedAscending ? .orderedDescending : base == .orderedDescending ? .orderedAscending : .orderedSame
        case .ascending:
            return base
        }
    }

    private func compare(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compare(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func makeLocalActivity(from importedRoute: ImportedGPXRoute) -> ActivityRecord {
        let coordinates = RoutePolylineCodec.decode(importedRoute.summaryPolyline)
        let sportKind = RouteSportKind.fromImportedActivity(
            routeType: importedRoute.routeType,
            routeSubType: importedRoute.routeSubType,
            title: importedRoute.name
        )
        let startedAt = importedRoute.createdAt ?? importedRoute.updatedAt ?? .now
        let averageSpeed = importedRoute.estimatedMovingTime > 0
            ? importedRoute.distanceMeters / importedRoute.estimatedMovingTime
            : 0

        return ActivityRecord(
            localName: importedRoute.name,
            description: importedRoute.description,
            sportKind: sportKind,
            coordinates: coordinates,
            elevationSamples: importedRoute.elevationSamples,
            startDate: startedAt,
            movingTime: importedRoute.estimatedMovingTime,
            elapsedTime: importedRoute.estimatedMovingTime,
            distanceMeters: importedRoute.distanceMeters,
            elevationGainMeters: importedRoute.elevationGainMeters,
            averageSpeedMetersPerSecond: averageSpeed,
            locationDetails: RouteStartLocationDetails(
                referenceName: importedRoute.name,
                regionName: importedRoute.regionName,
                parkName: importedRoute.parkName,
                countyName: importedRoute.countyName,
                cityName: importedRoute.city,
                stateName: importedRoute.state,
                countryName: importedRoute.country
            )
        )
    }

    private func apply(localActivity: ActivityRecord, to existing: ActivityRecord) {
        existing.name = localActivity.name
        existing.activityDescription = localActivity.activityDescription
        existing.sportTypeRawValue = localActivity.sportTypeRawValue
        existing.legacyTypeRawValue = localActivity.legacyTypeRawValue
        existing.distanceMeters = localActivity.distanceMeters
        existing.movingTime = localActivity.movingTime
        existing.elapsedTime = localActivity.elapsedTime
        existing.elevationGainMeters = localActivity.elevationGainMeters
        existing.averageSpeedMetersPerSecond = localActivity.averageSpeedMetersPerSecond
        existing.startDate = localActivity.startDate
        existing.updatedAt = localActivity.updatedAt
        existing.syncedAt = .now
        existing.city = localActivity.city
        existing.state = localActivity.state
        existing.country = localActivity.country
        existing.startRegionName = localActivity.startRegionName
        existing.startParkName = localActivity.startParkName
        existing.startCountyName = localActivity.startCountyName
        existing.startLatitude = localActivity.startLatitude
        existing.startLongitude = localActivity.startLongitude
        existing.endLatitude = localActivity.endLatitude
        existing.endLongitude = localActivity.endLongitude
        existing.mapSummaryPolyline = localActivity.mapSummaryPolyline
        existing.activityDetailPolyline = localActivity.activityDetailPolyline
        existing.elevationProfileBlob = localActivity.elevationProfileBlob
        existing.detailIndexedAt = localActivity.detailIndexedAt
    }

    private func stableLocalRouteID(for activity: ActivityRecord) -> Int {
        if let stravaActivityID = activity.stravaActivityID {
            return -(900_000_000 + stravaActivityID)
        }

        let digest = SHA256.hash(data: Data(activity.activityKey.utf8))
        let rawValue = digest.prefix(8).reduce(UInt64(0)) { partialResult, byte in
            (partialResult << 8) | UInt64(byte)
        }
        let boundedValue = Int(rawValue & UInt64(Int.max))
        return -max(1, boundedValue)
    }

    private func uploadSportType(for sportKind: RouteSportKind) -> String {
        switch sportKind {
        case .ride:
            return "Ride"
        case .mountainBike:
            return "MountainBikeRide"
        case .mixedRide:
            return "Ride"
        case .gravelRide:
            return "GravelRide"
        case .cyclocross:
            return "Ride"
        case .run:
            return "Run"
        case .trailRun:
            return "TrailRun"
        case .walk:
            return "Walk"
        case .hike:
            return "Hike"
        case .snowshoe:
            return "Snowshoe"
        case .ski:
            return "NordicSki"
        case .wheelchair:
            return "Wheelchair"
        case .other:
            return "Workout"
        }
    }

    private func pollUploadStatus(
        uploadID: Int,
        session: StravaSession,
        credentials: StravaAppCredentials
    ) async throws -> StravaUploadPayload {
        var activeSession = session

        for _ in 0..<18 {
            try await Task.sleep(for: .seconds(2))

            do {
                let payload = try await apiService.fetchUploadStatus(uploadID: uploadID, accessToken: activeSession.accessToken)
                let normalizedStatus = payload.status.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()

                if payload.activityID != nil ||
                    payload.error?.trimmed.nilIfEmpty != nil ||
                    normalizedStatus.contains("ready") ||
                    normalizedStatus.contains("complete") ||
                    normalizedStatus.contains("uploaded") {
                    return payload
                }
            } catch StravaAPIService.APIError.unauthorized {
                activeSession = try await apiService.refreshedSessionIfNeeded(activeSession, credentials: credentials, forceRefresh: true)
                try credentialStore.save(session: activeSession)
                self.session = activeSession
            }
        }

        return try await apiService.fetchUploadStatus(uploadID: uploadID, accessToken: activeSession.accessToken)
    }

    private func displayMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private func shouldInvalidateSession(for error: Error) -> Bool {
        guard let apiError = error as? StravaAPIService.APIError else {
            return false
        }

        return apiError.requiresSessionReset
    }

    private func invalidateSession() {
        session = nil
        try? credentialStore.clearSession()
    }

    private func shouldSuppressErrorBanner(for error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let apiError = error as? StravaAPIService.APIError, case .cancelled = apiError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}

private extension String {
    var normalizedSearchText: String {
        routeLocationToken
    }
}

private struct CachedActivityLocationDetails: Codable {
    let regionName: String
    let parkName: String
    let countyName: String
    let cityName: String
    let stateName: String
    let countryName: String

    init(details: RouteStartLocationDetails) {
        regionName = details.regionName.trimmed
        parkName = details.parkName.trimmed
        countyName = details.countyName.trimmed
        cityName = details.cityName.trimmed
        stateName = details.stateName.trimmed
        countryName = details.countryName.trimmed
    }

    func asRouteStartLocationDetails(fallbackName: String) -> RouteStartLocationDetails {
        let resolvedFallback = fallbackName.trimmed.nilIfEmpty ?? "Activity Start"
        let referenceName = [
            parkName.trimmed.nilIfEmpty,
            cityName.trimmed.nilIfEmpty,
            stateName.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
        .nilIfEmpty ?? resolvedFallback

        return RouteStartLocationDetails(
            referenceName: referenceName,
            regionName: regionName,
            parkName: parkName,
            countyName: countyName,
            cityName: cityName,
            stateName: stateName,
            countryName: countryName
        )
    }
}

private actor ActivityLocationMetadataResolver {
    private enum CacheStore {
        static let defaultsKey = "activityLocationMetadataCache"

        static func load() -> [String: CachedActivityLocationDetails] {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode([String: CachedActivityLocationDetails].self, from: data) else {
                return [:]
            }

            return decoded
        }

        static func save(_ cache: [String: CachedActivityLocationDetails]) {
            guard let data = try? JSONEncoder().encode(cache) else {
                return
            }

            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private var cache = CacheStore.load()

    func details(for coordinate: CLLocationCoordinate2D, fallbackName: String) async throws -> RouteStartLocationDetails {
        let latitude = (coordinate.latitude * 1_000).rounded() / 1_000
        let longitude = (coordinate.longitude * 1_000).rounded() / 1_000
        let key = "\(latitude),\(longitude)"

        if let cachedDetails = cache[key] {
            return cachedDetails.asRouteStartLocationDetails(fallbackName: fallbackName)
        }

        let placemark = try await reverseGeocode(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
        let details = placemark?.routeStartLocationDetails(
            preferredName: nil,
            fallbackName: fallbackName.trimmed.nilIfEmpty ?? coordinate.formattedLabel
        ) ?? RouteStartLocationDetails(
            referenceName: fallbackName.trimmed.nilIfEmpty ?? coordinate.formattedLabel,
            regionName: "",
            parkName: "",
            countyName: "",
            cityName: "",
            stateName: "",
            countryName: ""
        )

        cache[key] = CachedActivityLocationDetails(details: details)
        CacheStore.save(cache)
        return details
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> [CLPlacemark] {
        let geocoder = CLGeocoder()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLPlacemark], Error>) in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: placemarks ?? [])
            }
        }
    }
}

private extension RouteSportKind {
    static func fromImportedActivity(routeType: Int, routeSubType: Int, title: String) -> RouteSportKind {
        let normalizedTitle = title.normalizedSearchText

        switch (routeType, routeSubType) {
        case (1, 1):
            return .ride
        case (1, 2):
            return .mountainBike
        case (1, 3):
            return .cyclocross
        case (1, 5):
            return .mixedRide
        case (2, 4), (5, 4), (5, 5):
            return .trailRun
        case (2, _), (5, _):
            return title.normalizedSearchText.contains("trail") ? .trailRun : .run
        case (4, 4), (4, 5):
            return .hike
        case (4, _):
            return .walk
        default:
            if normalizedTitle.contains("trailrun") || (normalizedTitle.contains("trail") && normalizedTitle.contains("run")) {
                return .trailRun
            }
            if normalizedTitle.contains("hike") {
                return .hike
            }
            if normalizedTitle.contains("walk") {
                return .walk
            }
            if normalizedTitle.contains("gravel") {
                return .gravelRide
            }
            if normalizedTitle.contains("bike") || normalizedTitle.contains("ride") {
                return .ride
            }
            if normalizedTitle.contains("run") {
                return .run
            }

            return .other
        }
    }
}
