import Foundation
import CoreLocation
import Observation
import SwiftData

struct DeletedRouteTombstone: Codable, Equatable, Hashable, Identifiable {
    let stravaRouteID: Int
    let name: String
    let deletedAt: Date

    var id: Int { stravaRouteID }
}

@MainActor
@Observable
final class RouteLibraryModel {
    private struct RouteFilterCacheKey: Hashable {
        let routesSignature: Int
        let filterSignature: Int
        let includesDistanceFilter: Bool
        let includesClimbFilter: Bool
    }

    private struct RouteSortCacheKey: Hashable {
        let filterKey: RouteFilterCacheKey
        let sortSignature: Int
    }

    private struct ListNameCacheKey: Hashable {
        let listsSignature: Int
        let routesSignature: Int
    }

    private struct DashboardMetricsCacheKey: Hashable {
        let allRoutesSignature: Int
        let visibleRoutesSignature: Int
    }

    private struct StartDistanceCacheKey: Hashable {
        let routeID: Int
        let latitudeKey: Int
        let longitudeKey: Int
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

    private enum Defaults {
        static let startRadiusMiles = 25.0
    }

    private enum DeletedRouteStore {
        static let defaultsKey = "deletedStravaRouteTombstones"

        static func load() -> [DeletedRouteTombstone] {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let routes = try? JSONDecoder().decode([DeletedRouteTombstone].self, from: data) else {
                return []
            }

            return routes.sorted { $0.deletedAt > $1.deletedAt }
        }

        static func save(_ routes: [DeletedRouteTombstone]) {
            guard let data = try? JSONEncoder().encode(routes) else {
                return
            }

            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private enum LegacyListMigrationStore {
        static let defaultsKey = "didMigrateLegacyRouteLists"

        static var didCompleteMigration: Bool {
            get { UserDefaults.standard.bool(forKey: defaultsKey) }
            set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
        }
    }

    @ObservationIgnored private let credentialStore = StravaCredentialStore()
    @ObservationIgnored private let apiService = StravaAPIService()
    @ObservationIgnored private let authCoordinator = StravaAuthSessionCoordinator()
    @ObservationIgnored private let gpxImportService = GPXImportService()
    @ObservationIgnored private let offlineAssetService = RouteOfflineAssetService()
    @ObservationIgnored private let locationMetadataResolver = RouteLocationMetadataResolver()
    @ObservationIgnored private var locationIndexTask: Task<Void, Never>?
    @ObservationIgnored private var sessionInvalidationObserver: NSObjectProtocol?
    @ObservationIgnored private var cachedFilteredRoutesKey: RouteSortCacheKey?
    @ObservationIgnored private var cachedFilteredRoutes: [RouteRecord] = []
    @ObservationIgnored private var cachedNonDistanceRoutesKey: RouteFilterCacheKey?
    @ObservationIgnored private var cachedNonDistanceRoutes: [RouteRecord] = []
    @ObservationIgnored private var cachedNonClimbRoutesKey: RouteFilterCacheKey?
    @ObservationIgnored private var cachedNonClimbRoutes: [RouteRecord] = []
    @ObservationIgnored private var cachedAvailableListNamesKey: ListNameCacheKey?
    @ObservationIgnored private var cachedAvailableListNames: [String] = []
    @ObservationIgnored private var cachedDashboardMetricsKey: DashboardMetricsCacheKey?
    @ObservationIgnored private var cachedDashboardMetrics: [DashboardMetric] = []
    @ObservationIgnored private var cachedStartDistanceSignature: Int?
    @ObservationIgnored private var cachedStartDistances: [StartDistanceCacheKey: Double?] = [:]

    var query = ""
    var sortCriteria: [RouteSortCriterion] = [.defaultCriterion]
    var selectedMovements: Set<RouteMovementFilter> = [.all]
    var selectedSports: Set<RouteSportFilter> = [.all]
    var selectedDistance: RouteDistanceFilter = .all
    var selectedDistanceMinimumMiles: Double?
    var selectedDistanceMaximumMiles: Double?
    var selectedClimbMinimumFeet: Double?
    var selectedClimbMaximumFeet: Double?
    var selectedClimb: RouteClimbFilter = .all
    var selectedSurfaceFilters: Set<RouteSurfaceFilter> = [.all]
    var selectedCollections: Set<String> = []
    var showOnlyOfflineRoutes = false
    var selectedStartLocationName = ""
    var selectedStartLocationLatitude: Double?
    var selectedStartLocationLongitude: Double?
    var selectedStartLocationRadiusMiles = Defaults.startRadiusMiles
    var selectedStartFilterMode: RouteStartFilterMode = .none
    var selectedStartTextFilters: [String] = []
    var selectedStartRegionName = ""
    var selectedStartParkName = ""
    var selectedStartCountyName = ""
    var selectedStartCityName = ""
    var selectedStartStateName = ""
    var selectedStartCountryName = ""
    var selectedRoute: RouteRecord?
    var deletedRoutes: [DeletedRouteTombstone] = []
    var isConnecting = false
    var isSyncing = false
    var syncedRouteDownloadCount = 0
    var totalRouteDownloadCount = 0
    var isSyncRouteTotalEstimated = false
    var isImportingGPX = false
    var isIndexingStartLocations = false
    var indexedStartLocationCount = 0
    var totalStartLocationIndexCount = 0
    var errorMessage: String?
    var statusMessage: String?
    var lastImportSummary: ImportSummary?
    private(set) var session: StravaSession?

    @ObservationIgnored private var didAttemptInitialSync = false
    @ObservationIgnored private var didAttemptLegacyListMigration = false

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
    }

    var selectedSort: RouteSortOption {
        get { sortCriteria.first?.option ?? RouteSortCriterion.defaultCriterion.option }
        set {
            var criteria = normalizedSortCriteria(from: sortCriteria)
            criteria[0].option = newValue
            criteria[0].direction = defaultSortDirection(for: newValue, current: criteria[0].direction)
            sortCriteria = normalizedSortCriteria(from: criteria)
        }
    }

    var selectedSortDirection: RouteSortDirection {
        get { sortCriteria.first?.direction ?? RouteSortCriterion.defaultCriterion.direction }
        set {
            var criteria = normalizedSortCriteria(from: sortCriteria)
            criteria[0].direction = newValue
            sortCriteria = normalizedSortCriteria(from: criteria)
        }
    }

    var usesStartProximitySort: Bool {
        normalizedSortCriteria(from: sortCriteria).contains { $0.option == .startProximity }
    }

    var isConfigured: Bool {
        true
    }

    var isConnected: Bool {
        session != nil
    }

    var redirectURI: String {
        credentialsDraft.redirectURI
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

    var hasActiveFilters: Bool {
        !query.trimmed.isEmpty ||
            hasCustomSortCriteria ||
            selectedMovements != [.all] ||
            selectedSports != [.all] ||
            hasCustomDistanceRange ||
            selectedDistance != .all ||
            hasCustomClimbRange ||
            selectedClimb != .all ||
            selectedSurfaceFilters != [.all] ||
            !selectedCollections.isEmpty ||
            showOnlyOfflineRoutes ||
            hasActiveStartFilter
    }

    func resetFilters() {
        query = ""
        sortCriteria = [.defaultCriterion]
        selectedMovements = [.all]
        selectedSports = [.all]
        selectedDistance = .all
        selectedDistanceMinimumMiles = nil
        selectedDistanceMaximumMiles = nil
        selectedClimb = .all
        selectedClimbMinimumFeet = nil
        selectedClimbMaximumFeet = nil
        selectedSurfaceFilters = [.all]
        selectedCollections = []
        showOnlyOfflineRoutes = false
        selectedStartTextFilters = []
        clearSelectedStartLocation()
        selectedStartLocationRadiusMiles = Defaults.startRadiusMiles
    }

    var hasSelectedStartLocation: Bool {
        selectedStartLocationCoordinate != nil
    }

    var hasCustomDistanceRange: Bool {
        selectedDistanceMinimumMiles != nil || selectedDistanceMaximumMiles != nil
    }

    var hasCustomClimbRange: Bool {
        selectedClimbMinimumFeet != nil || selectedClimbMaximumFeet != nil
    }

    var hasCustomSortCriteria: Bool {
        normalizedSortCriteria(from: sortCriteria) != [.defaultCriterion]
    }

    var showOnlyWithinStartRadius: Bool {
        get { selectedStartFilterMode == .radius }
        set { selectedStartFilterMode = newValue ? .radius : .none }
    }

    var selectedStartLocationCoordinate: CLLocationCoordinate2D? {
        guard let latitude = selectedStartLocationLatitude,
              let longitude = selectedStartLocationLongitude else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var selectedStartLocationDisplayName: String {
        selectedStartLocationName.trimmed.nilIfEmpty ?? selectedStartLocationCoordinate?.formattedLabel ?? "Map Pin"
    }

    var selectedStartLocationDetails: RouteStartLocationDetails {
        RouteStartLocationDetails(
            referenceName: selectedStartLocationDisplayName,
            regionName: selectedStartRegionName,
            parkName: selectedStartParkName,
            countyName: selectedStartCountyName,
            cityName: selectedStartCityName,
            stateName: selectedStartStateName,
            countryName: selectedStartCountryName
        )
    }

    var availableStartFilterModes: [RouteStartFilterMode] {
        guard hasSelectedStartLocation else {
            return [.none]
        }

        return selectedStartLocationDetails.availableFilterModes
    }

    var hasActiveStartFilter: Bool {
        switch selectedStartFilterMode {
        case .none:
            return false
        case .radius:
            return hasSelectedStartLocation
        case .namedAreas, .region, .park, .county, .city, .state, .country:
            return !selectedStartTextFilters.isEmpty
        }
    }

    var selectedStartFilterValue: String? {
        switch selectedStartFilterMode {
        case .none:
            return nil
        case .radius:
            return RouteDisplayFormatter.radius(selectedStartLocationRadiusMiles)
        case .namedAreas, .region, .park, .county, .city, .state, .country:
            guard !selectedStartTextFilters.isEmpty else {
                return nil
            }

            if selectedStartTextFilters.count <= 2 {
                return selectedStartTextFilters.joined(separator: ", ")
            }

            return "\(selectedStartTextFilters.prefix(2).joined(separator: ", ")) +\(selectedStartTextFilters.count - 2)"
        }
    }

    func setSelectedStartLocation(
        name: String,
        coordinate: CLLocationCoordinate2D,
        details: RouteStartLocationDetails? = nil
    ) {
        let resolvedDetails = details ?? RouteStartLocationDetails(
            referenceName: name,
            regionName: "",
            parkName: "",
            countyName: "",
            cityName: "",
            stateName: "",
            countryName: ""
        )

        selectedStartLocationName = resolvedDetails.referenceName.trimmed.nilIfEmpty ?? name.trimmed.nilIfEmpty ?? coordinate.formattedLabel
        selectedStartLocationLatitude = coordinate.latitude
        selectedStartLocationLongitude = coordinate.longitude
        selectedStartRegionName = resolvedDetails.regionName.trimmed
        selectedStartParkName = resolvedDetails.parkName.trimmed
        selectedStartCountyName = resolvedDetails.countyName.trimmed
        selectedStartCityName = resolvedDetails.cityName.trimmed
        selectedStartStateName = resolvedDetails.stateName.trimmed
        selectedStartCountryName = resolvedDetails.countryName.trimmed
        normalizeStartFilterSelection()
    }

    func setStartFilterMode(_ mode: RouteStartFilterMode) {
        switch mode {
        case .none:
            selectedStartFilterMode = .none
        case .radius:
            guard hasSelectedStartLocation else {
                selectedStartFilterMode = .none
                return
            }

            selectedStartFilterMode = .radius
        case .namedAreas, .region, .park, .county, .city, .state, .country:
            selectedStartFilterMode = .namedAreas
        }
    }

    func clearSelectedStartLocation() {
        selectedStartLocationName = ""
        selectedStartLocationLatitude = nil
        selectedStartLocationLongitude = nil
        selectedStartRegionName = ""
        selectedStartParkName = ""
        selectedStartCountyName = ""
        selectedStartCityName = ""
        selectedStartStateName = ""
        selectedStartCountryName = ""

        if selectedStartFilterMode == .radius {
            selectedStartFilterMode = .none
        }
    }

    func addStartTextFilters(from rawValue: String) {
        let candidates = rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(\.trimmed)
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else {
            return
        }

        selectedStartTextFilters = normalizedStartTextFilters(selectedStartTextFilters + candidates)

        if !selectedStartFilterMode.supportsInlineNameEntry {
            selectedStartFilterMode = .namedAreas
        }
    }

    func removeStartTextFilter(_ value: String) {
        let token = value.routeLocationToken
        selectedStartTextFilters.removeAll { $0.routeLocationToken == token }

        if selectedStartTextFilters.isEmpty,
           selectedStartFilterMode.supportsInlineNameEntry {
            selectedStartFilterMode = .none
        }
    }

    func clearStartTextFilters() {
        selectedStartTextFilters = []

        if selectedStartFilterMode.supportsInlineNameEntry {
            selectedStartFilterMode = .none
        }
    }

    func clearStartFiltering() {
        switch selectedStartFilterMode {
        case .none:
            break
        case .radius:
            selectedStartFilterMode = selectedStartTextFilters.isEmpty ? .none : .namedAreas
        case .namedAreas, .region, .park, .county, .city, .state, .country:
            clearStartTextFilters()
        }
    }

    func connect() async {
        guard !isConnecting else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "Reviewer demo mode is using seeded local routes. Exit demo mode from Account settings to connect a real Strava account."
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
            statusMessage = session.hasReadAllAccess
                ? "Connected as \(session.athlete.displayName). Private routes will sync."
                : "Connected as \(session.athlete.displayName), but `read_all` was not granted."
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
            errorMessage = displayMessage(for: error)
        }
    }

    func deleteRoute(_ route: RouteRecord, using context: ModelContext, showsStatusMessage: Bool = true) {
        let routeID = route.stravaRouteID
        let routeName = route.name.trimmed.nilIfEmpty ?? "Route \(routeID)"
        let shouldBlockStravaResync = !route.isImportedFromGPX

        do {
            if selectedRoute?.stravaRouteID == routeID {
                selectedRoute = nil
            }

            context.delete(route)
            try context.save()

            try? offlineAssetService.removeOfflineAssets(for: route)

            if showsStatusMessage, shouldBlockStravaResync {
                upsertDeletedRoute(
                    DeletedRouteTombstone(
                        stravaRouteID: routeID,
                        name: routeName,
                        deletedAt: .now
                    )
                )
                statusMessage = "Deleted \(routeName). It won’t sync from Strava again until you undelete it in Deleted Routes."
            } else if shouldBlockStravaResync {
                upsertDeletedRoute(
                    DeletedRouteTombstone(
                        stravaRouteID: routeID,
                        name: routeName,
                        deletedAt: .now
                    )
                )
            } else if showsStatusMessage {
                statusMessage = "Deleted \(routeName) from your local library."
            }

            if showsStatusMessage {
                errorMessage = nil
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func restoreDeletedRoute(_ tombstone: DeletedRouteTombstone) {
        deletedRoutes.removeAll { $0.stravaRouteID == tombstone.stravaRouteID }
        persistDeletedRoutes()
        statusMessage = "Undeleted \(tombstone.name). Sync Strava to download it again."
        errorMessage = nil
    }

    func restoreAllDeletedRoutes() {
        guard !deletedRoutes.isEmpty else {
            return
        }

        let restoredCount = deletedRoutes.count
        deletedRoutes = []
        persistDeletedRoutes()
        statusMessage = restoredCount == 1
            ? "Undeleted 1 route. Sync Strava to download it again."
            : "Undeleted \(restoredCount) routes. Sync Strava to download them again."
        errorMessage = nil
    }

    func syncRoutes(using context: ModelContext) async {
        guard !isSyncing else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            errorMessage = nil
            statusMessage = "Reviewer demo mode already includes seeded routes."
            return
        }

        guard let session else {
            errorMessage = "Connect Strava before syncing routes."
            return
        }

        do {
            isSyncing = true
            resetRouteSyncProgress()
            errorMessage = nil
            statusMessage = nil

            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            var activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            let priorRemoteRouteCount = existingRemoteRouteCount(using: context)
            if priorRemoteRouteCount > 0 {
                updateRouteSyncProgress(downloaded: 0, total: priorRemoteRouteCount, isEstimated: false)
            }

            do {
                let routes = try await apiService.fetchAllRoutes(
                    athleteID: activeSession.athlete.id,
                    accessToken: activeSession.accessToken
                ) { downloadedCount, expectedTotalCount, isEstimatedTotal in
                    await MainActor.run {
                        self.updateRouteSyncProgress(
                            downloaded: downloadedCount,
                            total: max(expectedTotalCount, priorRemoteRouteCount),
                            isEstimated: isEstimatedTotal
                        )
                    }
                }
                let summary = try importRoutes(routes, into: context)
                self.session = activeSession
                try credentialStore.save(session: activeSession)
                lastImportSummary = summary
                statusMessage = syncStatusMessage(for: summary)
                scheduleStartLocationIndexing(using: context)
            } catch StravaAPIService.APIError.unauthorized {
                activeSession = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials, forceRefresh: true)
                let routes = try await apiService.fetchAllRoutes(
                    athleteID: activeSession.athlete.id,
                    accessToken: activeSession.accessToken
                ) { downloadedCount, expectedTotalCount, isEstimatedTotal in
                    await MainActor.run {
                        self.updateRouteSyncProgress(
                            downloaded: downloadedCount,
                            total: max(expectedTotalCount, priorRemoteRouteCount),
                            isEstimated: isEstimatedTotal
                        )
                    }
                }
                let summary = try importRoutes(routes, into: context)
                self.session = activeSession
                try credentialStore.save(session: activeSession)
                lastImportSummary = summary
                statusMessage = syncStatusMessage(for: summary, afterRefresh: true)
                scheduleStartLocationIndexing(using: context)
            }
        } catch {
            if shouldInvalidateSession(for: error) {
                invalidateSession()
            }
            errorMessage = displayMessage(for: error)
        }

        isSyncing = false
        resetRouteSyncProgress()
    }

    func performInitialSyncIfNeeded(using context: ModelContext) async {
        guard !didAttemptInitialSync else {
            return
        }

        didAttemptInitialSync = true

        guard session != nil else {
            return
        }

        guard !AppUITestSupport.shouldUseStubSession else {
            return
        }

        await validatePersistedSessionIfNeeded()

        let remoteRouteCount = existingRemoteRouteCount(using: context)
        guard session != nil, remoteRouteCount == 0 else {
            return
        }

        await syncRoutes(using: context)
    }

    func scheduleStartLocationIndexing(using context: ModelContext) {
        guard !isIndexingStartLocations else {
            return
        }

        locationIndexTask?.cancel()
        locationIndexTask = Task { @MainActor [weak self] in
            await self?.indexMissingStartLocations(using: context)
        }
    }

    func importGPXFiles(from urls: [URL], using context: ModelContext) async -> RouteRecord? {
        guard !isImportingGPX else {
            return nil
        }

        let filesToImport = Array(Set(urls)).sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        guard !filesToImport.isEmpty else {
            return nil
        }

        isImportingGPX = true
        errorMessage = nil
        statusMessage = nil
        var lastImportedRoute: RouteRecord?

        do {
            let existingRoutes = try context.fetch(FetchDescriptor<RouteRecord>())
            var indexedRoutes = Dictionary(uniqueKeysWithValues: existingRoutes.map { ($0.stravaRouteID, $0) })
            let importedAt = Date()

            var insertedCount = 0
            var updatedCount = 0
            var failureMessages: [String] = []

            for url in filesToImport {
                do {
                    let importedRoute = try await gpxImportService.importRoute(from: url)

                    if let existing = indexedRoutes[importedRoute.routeID] {
                        existing.apply(importedGPX: importedRoute, syncedAt: importedAt)
                        lastImportedRoute = existing
                        updatedCount += 1
                    } else {
                        let newRoute = RouteRecord(importedGPX: importedRoute, syncedAt: importedAt)
                        context.insert(newRoute)
                        indexedRoutes[importedRoute.routeID] = newRoute
                        lastImportedRoute = newRoute
                        insertedCount += 1
                    }
                } catch {
                    let message = displayMessage(for: error)
                    failureMessages.append("\(url.lastPathComponent): \(message)")
                }
            }

            if insertedCount > 0 || updatedCount > 0 {
                try context.save()
                let totalImported = insertedCount + updatedCount
                statusMessage = "Imported \(totalImported) GPX \(totalImported == 1 ? "route" : "routes"). \(insertedCount) new, \(updatedCount) refreshed."
                scheduleStartLocationIndexing(using: context)
            }

            if !failureMessages.isEmpty {
                errorMessage = failureMessages.count == 1
                    ? failureMessages[0]
                    : "\(failureMessages.count) GPX files could not be imported. \(failureMessages[0])"
            }

            if insertedCount == 0, updatedCount == 0, failureMessages.isEmpty {
                statusMessage = "No GPX routes were imported."
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }

        isImportingGPX = false
        return lastImportedRoute
    }

    func filteredRoutes(from routes: [RouteRecord]) -> [RouteRecord] {
        let candidateRoutes = AppStoreScreenshotSupport.screenshotEligibleRoutes(from: routes)
        let filterKey = routeFilterCacheKey(
            for: candidateRoutes,
            includesDistanceFilter: true,
            includesClimbFilter: true
        )
        let sortKey = RouteSortCacheKey(
            filterKey: filterKey,
            sortSignature: sortStateSignature()
        )

        if cachedFilteredRoutesKey == sortKey {
            return cachedFilteredRoutes
        }

        let filteredRoutes = cachedRoutesMatchingFilters(
            from: candidateRoutes,
            includesDistanceFilter: true,
            includesClimbFilter: true
        )
        let criteria = normalizedSortCriteria(from: sortCriteria)
        let sortedRoutes = filteredRoutes.sorted { lhs, rhs in
            sortPredicate(lhs: lhs, rhs: rhs, criteria: criteria)
        }

        cachedFilteredRoutesKey = sortKey
        cachedFilteredRoutes = sortedRoutes
        return sortedRoutes
    }

    func routesMatchingNonDistanceFilters(from routes: [RouteRecord]) -> [RouteRecord] {
        cachedRoutesMatchingFilters(
            from: AppStoreScreenshotSupport.screenshotEligibleRoutes(from: routes),
            includesDistanceFilter: false,
            includesClimbFilter: true
        )
    }

    func routesMatchingNonClimbFilters(from routes: [RouteRecord]) -> [RouteRecord] {
        cachedRoutesMatchingFilters(
            from: AppStoreScreenshotSupport.screenshotEligibleRoutes(from: routes),
            includesDistanceFilter: true,
            includesClimbFilter: false
        )
    }

    private func routesMatchingFilters(
        from routes: [RouteRecord],
        includesDistanceFilter: Bool,
        includesClimbFilter: Bool
    ) -> [RouteRecord] {
        let normalizedQuery = query.normalizedSearchText

        return routes.filter { route in
            matchesRoute(
                route,
                normalizedQuery: normalizedQuery,
                includesDistanceFilter: includesDistanceFilter,
                includesClimbFilter: includesClimbFilter
            )
        }
    }

    private func cachedRoutesMatchingFilters(
        from routes: [RouteRecord],
        includesDistanceFilter: Bool,
        includesClimbFilter: Bool
    ) -> [RouteRecord] {
        let cacheKey = routeFilterCacheKey(
            for: routes,
            includesDistanceFilter: includesDistanceFilter,
            includesClimbFilter: includesClimbFilter
        )

        switch (includesDistanceFilter, includesClimbFilter) {
        case (false, true):
            if cachedNonDistanceRoutesKey == cacheKey {
                return cachedNonDistanceRoutes
            }
        case (true, false):
            if cachedNonClimbRoutesKey == cacheKey {
                return cachedNonClimbRoutes
            }
        default:
            break
        }

        let filteredRoutes = routesMatchingFilters(
            from: routes,
            includesDistanceFilter: includesDistanceFilter,
            includesClimbFilter: includesClimbFilter
        )

        switch (includesDistanceFilter, includesClimbFilter) {
        case (false, true):
            cachedNonDistanceRoutesKey = cacheKey
            cachedNonDistanceRoutes = filteredRoutes
        case (true, false):
            cachedNonClimbRoutesKey = cacheKey
            cachedNonClimbRoutes = filteredRoutes
        default:
            break
        }

        return filteredRoutes
    }

    func availableListNames(from lists: [RouteList], routes: [RouteRecord]) -> [String] {
        let cacheKey = ListNameCacheKey(
            listsSignature: listNameSignature(for: lists),
            routesSignature: routesSignature(for: routes)
        )

        if cachedAvailableListNamesKey == cacheKey {
            return cachedAvailableListNames
        }

        let persistedNames = lists.map(\.name)
        let routeNames = routes.flatMap(\.listNames)
        let normalizedNames = RouteRecord.normalizedLabels(persistedNames + routeNames)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        cachedAvailableListNamesKey = cacheKey
        cachedAvailableListNames = normalizedNames
        return normalizedNames
    }

    func removeSelectedTag(_ tag: String) {
        let tagToken = tag.routeLabelIdentifier
        guard !tagToken.isEmpty else {
            return
        }

        selectedCollections = Set(
            selectedCollections.filter { $0.routeLabelIdentifier != tagToken }
        )
    }

    func dashboardMetrics(allRoutes: [RouteRecord], visibleRoutes: [RouteRecord]) -> [DashboardMetric] {
        let cacheKey = DashboardMetricsCacheKey(
            allRoutesSignature: routesSignature(for: allRoutes),
            visibleRoutesSignature: routesSignature(for: visibleRoutes)
        )

        if cachedDashboardMetricsKey == cacheKey {
            return cachedDashboardMetrics
        }

        let visibleDistance = visibleRoutes.reduce(0) { $0 + $1.distanceMeters }
        let listedCount = allRoutes.filter(\.hasLists).count

        let metrics = [
            DashboardMetric(
                id: "saved",
                title: "Saved",
                value: "\(allRoutes.count)",
                caption: allRoutes.count == 1 ? "route available locally" : "routes available locally"
            ),
            DashboardMetric(
                id: "visibleDistance",
                title: "Visible Distance",
                value: RouteDisplayFormatter.distance(visibleDistance),
                caption: visibleRoutes.count == allRoutes.count ? "full library" : "filtered result"
            ),
            DashboardMetric(
                id: "lists",
                title: "In Lists",
                value: "\(listedCount)",
                caption: listedCount == 1 ? "route organized" : "routes organized"
            )
        ]

        cachedDashboardMetricsKey = cacheKey
        cachedDashboardMetrics = metrics
        return metrics
    }

    func toggleMovementSelection(_ movement: RouteMovementFilter) {
        toggleMultiSelection(movement, in: &selectedMovements, resetOption: .all)
        normalizeSportSelectionForMovement()
    }

    func toggleSportSelection(_ sport: RouteSportFilter) {
        guard isSportAvailable(sport) else {
            return
        }

        toggleMultiSelection(sport, in: &selectedSports, resetOption: .all)
    }

    func orderedSportFilters(from routes: [RouteRecord]) -> [RouteSportFilter] {
        let fallbackOrder = RouteSportFilter.allCases.filter { $0 != .all }
        let fallbackIndex = Dictionary(
            uniqueKeysWithValues: fallbackOrder.enumerated().map { index, sport in
                (sport, index)
            }
        )

        let popularityCounts = routes.reduce(into: [RouteSportFilter: Int]()) { counts, route in
            guard !route.isArchived else {
                return
            }

            let sport = RouteSportFilter(sportKind: route.sportKind)
            counts[sport, default: 0] += 1
        }

        let orderedAvailableSports = fallbackOrder
            .filter(isSportAvailable)
            .sorted { lhs, rhs in
                let leftCount = popularityCounts[lhs, default: 0]
                let rightCount = popularityCounts[rhs, default: 0]

                if leftCount == rightCount {
                    return fallbackIndex[lhs, default: .max] < fallbackIndex[rhs, default: .max]
                }

                return leftCount > rightCount
            }

        return [.all] + orderedAvailableSports
    }

    func toggleSurfaceSelection(_ surface: RouteSurfaceFilter) {
        toggleMultiSelection(surface, in: &selectedSurfaceFilters, resetOption: .all)
    }

    func toggleCollectionSelection(_ collection: String) {
        let normalizedCollection = collection.trimmed
        guard !normalizedCollection.isEmpty else {
            return
        }

        if selectedCollections.contains(normalizedCollection) {
            selectedCollections.remove(normalizedCollection)
        } else {
            selectedCollections.insert(normalizedCollection)
        }
    }

    func addSortCriterion(_ option: RouteSortOption) {
        guard !sortCriteria.contains(where: { $0.option == option }) else {
            return
        }

        sortCriteria = normalizedSortCriteria(
            from: sortCriteria + [
                RouteSortCriterion(
                    option: option,
                    direction: defaultSortDirection(for: option)
                )
            ]
        )
    }

    func updateSortCriterion(_ criterionID: RouteSortCriterion.ID, option: RouteSortOption) {
        guard let index = sortCriteria.firstIndex(where: { $0.id == criterionID }) else {
            return
        }

        guard sortCriteria[index].option == option || !sortCriteria.contains(where: { $0.option == option }) else {
            return
        }

        sortCriteria[index].option = option
        sortCriteria[index].direction = defaultSortDirection(for: option, current: sortCriteria[index].direction)
        sortCriteria = normalizedSortCriteria(from: sortCriteria)
    }

    func updateSortCriterion(_ criterionID: RouteSortCriterion.ID, direction: RouteSortDirection) {
        guard let index = sortCriteria.firstIndex(where: { $0.id == criterionID }) else {
            return
        }

        sortCriteria[index].direction = direction
        sortCriteria = normalizedSortCriteria(from: sortCriteria)
    }

    func moveSortCriterion(_ criterionID: RouteSortCriterion.ID, by offset: Int) {
        guard let index = sortCriteria.firstIndex(where: { $0.id == criterionID }) else {
            return
        }

        let targetIndex = min(
            max(index + offset, 0),
            max(sortCriteria.count - 1, 0)
        )
        guard targetIndex != index else {
            return
        }

        let criterion = sortCriteria.remove(at: index)
        sortCriteria.insert(criterion, at: targetIndex)
        sortCriteria = normalizedSortCriteria(from: sortCriteria)
    }

    func removeSortCriterion(_ criterionID: RouteSortCriterion.ID) {
        guard sortCriteria.count > 1 else {
            sortCriteria = [.defaultCriterion]
            return
        }

        sortCriteria.removeAll { $0.id == criterionID }
        sortCriteria = normalizedSortCriteria(from: sortCriteria)
    }

    func clearStartProximitySorts() {
        sortCriteria.removeAll { $0.option == .startProximity }
        sortCriteria = normalizedSortCriteria(from: sortCriteria)
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
            self.session = AppUITestSupport.makeStubSession()
        } else if let session = try? credentialStore.loadSession() {
            self.session = session
        }

        deletedRoutes = DeletedRouteStore.load()
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

    func migrateLegacyListsIfNeeded(using context: ModelContext) {
        guard !didAttemptLegacyListMigration else {
            return
        }

        didAttemptLegacyListMigration = true

        if LegacyListMigrationStore.didCompleteMigration {
            return
        }

        do {
            let routes = try context.fetch(FetchDescriptor<RouteRecord>())
            let lists = try context.fetch(FetchDescriptor<RouteList>())
            let legacyCatalogNames = RouteTagCatalog.load()
            let legacyRouteNames = routes.flatMap(\.labels)
            let legacyNames = RouteRecord.normalizedLabels(legacyCatalogNames + legacyRouteNames)

            var hasChanges = false
            var existingTokens = Set(lists.map(\.normalizedName))

            for legacyName in legacyNames {
                let token = legacyName.routeLabelIdentifier
                guard !token.isEmpty, !existingTokens.contains(token) else {
                    continue
                }

                context.insert(RouteList(name: legacyName))
                existingTokens.insert(token)
                hasChanges = true
            }

            for route in routes where !route.labels.isEmpty || !route.collectionName.trimmed.isEmpty || !route.tagsBlob.trimmed.isEmpty {
                let normalizedNames = RouteRecord.normalizedLabels(route.labels)
                if normalizedNames != route.labels || !route.collectionName.trimmed.isEmpty {
                    route.labels = normalizedNames
                    hasChanges = true
                }
            }

            if hasChanges {
                try context.save()
            }

            RouteTagCatalog.save([])
            LegacyListMigrationStore.didCompleteMigration = true
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    private func importRoutes(_ remoteRoutes: [StravaRoutePayload], into context: ModelContext) throws -> ImportSummary {
        let syncedAt = Date()
        let deletedRouteIDs = Set(deletedRoutes.map(\.stravaRouteID))
        let existingRoutes = try context.fetch(FetchDescriptor<RouteRecord>())
        let activeExistingRoutes = existingRoutes.filter { !deletedRouteIDs.contains($0.stravaRouteID) }
        let indexedRoutes = Dictionary(uniqueKeysWithValues: activeExistingRoutes.map { ($0.stravaRouteID, $0) })
        let importableRoutes = remoteRoutes.filter { !deletedRouteIDs.contains($0.id) }
        let skippedDeletedCount = remoteRoutes.count - importableRoutes.count

        var insertedCount = 0
        var updatedCount = 0

        for existingRoute in existingRoutes where deletedRouteIDs.contains(existingRoute.stravaRouteID) {
            context.delete(existingRoute)
        }

        for remoteRoute in importableRoutes {
            if let existing = indexedRoutes[remoteRoute.id] {
                existing.apply(remote: remoteRoute, syncedAt: syncedAt)
                updatedCount += 1
            } else {
                let newRoute = RouteRecord(remote: remoteRoute, syncedAt: syncedAt)
                context.insert(newRoute)
                insertedCount += 1
            }
        }

        try context.save()

        return ImportSummary(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            totalRemoteRoutes: remoteRoutes.count,
            skippedDeletedCount: skippedDeletedCount,
            finishedAt: syncedAt
        )
    }

    private func upsertDeletedRoute(_ tombstone: DeletedRouteTombstone) {
        deletedRoutes.removeAll { $0.stravaRouteID == tombstone.stravaRouteID }
        deletedRoutes.insert(tombstone, at: 0)
        deletedRoutes.sort { $0.deletedAt > $1.deletedAt }
        persistDeletedRoutes()
    }

    private func persistDeletedRoutes() {
        DeletedRouteStore.save(deletedRoutes)
    }

    private func syncStatusMessage(for summary: ImportSummary, afterRefresh: Bool = false) -> String {
        let prefix = afterRefresh ? "Synced \(summary.totalRemoteRoutes) routes after refreshing the session." : "Synced \(summary.totalRemoteRoutes) routes."
        var message = "\(prefix) \(summary.insertedCount) new, \(summary.updatedCount) refreshed."

        if summary.skippedDeletedCount > 0 {
            let noun = summary.skippedDeletedCount == 1 ? "deleted route" : "deleted routes"
            message += " \(summary.skippedDeletedCount) \(noun) stayed blocked from sync."
        }

        return message
    }

    private func existingRemoteRouteCount(using context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<RouteRecord>()
        let routes = (try? context.fetch(descriptor)) ?? []
        return routes.count { !$0.isImportedFromGPX }
    }

    private func updateRouteSyncProgress(downloaded: Int, total: Int, isEstimated: Bool) {
        syncedRouteDownloadCount = max(0, downloaded)
        totalRouteDownloadCount = max(syncedRouteDownloadCount, total)
        isSyncRouteTotalEstimated = isEstimated
    }

    private func resetRouteSyncProgress() {
        syncedRouteDownloadCount = 0
        totalRouteDownloadCount = 0
        isSyncRouteTotalEstimated = false
    }

    private func indexMissingStartLocations(using context: ModelContext) async {
        guard !isIndexingStartLocations else {
            return
        }

        do {
            let routes = try context.fetch(FetchDescriptor<RouteRecord>())
            let candidates = routes.filter(\.needsStartLocationIndexing)

            guard !candidates.isEmpty else {
                indexedStartLocationCount = 0
                totalStartLocationIndexCount = 0
                return
            }

            isIndexingStartLocations = true
            indexedStartLocationCount = 0
            totalStartLocationIndexCount = candidates.count
            defer {
                isIndexingStartLocations = false
                locationIndexTask = nil
            }

            let groupedCandidates = Dictionary(grouping: candidates) { route in
                RouteLocationCoordinateKey(coordinate: route.startCoordinate!)
            }

            var dirtyRouteCount = 0

            for (_, groupedRoutes) in groupedCandidates.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if Task.isCancelled {
                    break
                }

                guard let sampleRoute = groupedRoutes.first,
                      let coordinate = sampleRoute.startCoordinate else {
                    indexedStartLocationCount += groupedRoutes.count
                    continue
                }

                let fallbackName = sampleRoute.displayLocation.nilIfEmpty ?? sampleRoute.name

                do {
                    if let details = try await locationMetadataResolver.details(for: coordinate, fallbackName: fallbackName) {
                        let indexedAt = Date()
                        for route in groupedRoutes {
                            route.applyIndexedStartLocationDetails(details, indexedAt: indexedAt)
                        }
                        dirtyRouteCount += groupedRoutes.count
                    }
                } catch {
                    // Leave these routes eligible for a future retry without interrupting the broader indexing pass.
                }

                indexedStartLocationCount += groupedRoutes.count

                if dirtyRouteCount >= 24 {
                    try context.save()
                    dirtyRouteCount = 0
                }
            }

            if dirtyRouteCount > 0 {
                try context.save()
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    private func matchesCollections(_ route: RouteRecord) -> Bool {
        let filters = selectedCollections.map(\.trimmed).filter { !$0.isEmpty }
        guard !filters.isEmpty else {
            return true
        }

        return filters.contains { route.hasLabel($0) }
    }

    private func matchesOfflineState(_ route: RouteRecord) -> Bool {
        !showOnlyOfflineRoutes || route.hasOfflineAssets
    }

    private func matchesRoute(
        _ route: RouteRecord,
        normalizedQuery: String,
        includesDistanceFilter: Bool,
        includesClimbFilter: Bool
    ) -> Bool {
        matchesMovement(route) &&
            matchesSport(route) &&
            (!includesDistanceFilter || matchesDistance(route)) &&
            (!includesClimbFilter || matchesClimb(route)) &&
            matchesSurface(route) &&
            matchesCollections(route) &&
            matchesOfflineState(route) &&
            matchesStartLocation(route) &&
            route.matchesSearchQuery(normalizedQuery)
    }

    private func normalizeSportSelectionForMovement() {
        guard selectedMovements != [.all] else {
            return
        }

        let allowedMovements = selectedMovements.subtracting([.all])
        let filteredSports = selectedSports.filter {
            $0 == .all || allowedMovements.contains($0.movementKind)
        }

        selectedSports = filteredSports.isEmpty ? [.all] : filteredSports
    }

    private func normalizeStartFilterSelection() {
        if selectedStartFilterMode.supportsInlineNameEntry {
            selectedStartFilterMode = selectedStartTextFilters.isEmpty ? .none : .namedAreas
        }

        guard hasSelectedStartLocation else {
            if selectedStartFilterMode == .radius {
                selectedStartFilterMode = .none
            }
            return
        }

        guard selectedStartFilterMode == .radius ||
                selectedStartFilterMode.supportsInlineNameEntry ||
                availableStartFilterModes.contains(selectedStartFilterMode) else {
            selectedStartFilterMode = .none
            return
        }
    }

    private func normalizedStartTextFilters(_ rawValues: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedValues: [String] = []

        for value in rawValues {
            let trimmedValue = value.trimmed
            let token = trimmedValue.routeLocationToken

            guard !trimmedValue.isEmpty,
                  !token.isEmpty,
                  seen.insert(token).inserted else {
                continue
            }

            normalizedValues.append(trimmedValue)
        }

        return normalizedValues
    }

    private func matchesDistance(_ route: RouteRecord) -> Bool {
        let distanceMiles = route.distanceMeters * 0.000621371

        if let minimumMiles = selectedDistanceMinimumMiles,
           distanceMiles < minimumMiles {
            return false
        }

        if let maximumMiles = selectedDistanceMaximumMiles,
           distanceMiles > maximumMiles {
            return false
        }

        if hasCustomDistanceRange {
            return true
        }

        return selectedDistance.matches(route)
    }

    private func matchesClimb(_ route: RouteRecord) -> Bool {
        let climbFeet = route.elevationGainMeters * 3.28084

        if let minimumFeet = selectedClimbMinimumFeet,
           climbFeet < minimumFeet {
            return false
        }

        if let maximumFeet = selectedClimbMaximumFeet,
           climbFeet > maximumFeet {
            return false
        }

        if hasCustomClimbRange {
            return true
        }

        return selectedClimb.matches(route)
    }

    private func matchesStartLocation(_ route: RouteRecord) -> Bool {
        switch selectedStartFilterMode {
        case .none:
            return true
        case .radius:
            guard let distanceMiles = distanceFromSelectedStartLocation(to: route) else {
                return false
            }

            return distanceMiles <= selectedStartLocationRadiusMiles
        case .namedAreas, .region, .park, .county, .city, .state, .country:
            let selectedTokens = Set(
                selectedStartTextFilters
                    .map(\.routeLocationToken)
                    .filter { !$0.isEmpty }
            )

            guard !selectedTokens.isEmpty else {
                return true
            }

            return route.startLocationMatchTokens.contains { routeToken in
                selectedTokens.contains { selectedToken in
                    startLocationTokensMatch(selectedToken, routeToken: routeToken)
                }
            }
        }
    }

    private func startLocationTokensMatch(_ selectedToken: String, routeToken: String) -> Bool {
        let normalizedSelectedToken = selectedToken.routeLocationToken
        let normalizedRouteToken = routeToken.routeLocationToken

        guard !normalizedSelectedToken.isEmpty, !normalizedRouteToken.isEmpty else {
            return false
        }

        if normalizedSelectedToken == normalizedRouteToken {
            return true
        }

        return normalizedSelectedToken.contains(normalizedRouteToken) || normalizedRouteToken.contains(normalizedSelectedToken)
    }

    private func matchesMovement(_ route: RouteRecord) -> Bool {
        let filters = selectedMovements.subtracting([.all])
        return filters.isEmpty || filters.contains(route.movementKind)
    }

    private func matchesSport(_ route: RouteRecord) -> Bool {
        let filters = selectedSports.subtracting([.all])
        return filters.isEmpty || filters.contains { $0.matches(route) }
    }

    private func matchesSurface(_ route: RouteRecord) -> Bool {
        let filters = selectedSurfaceFilters.subtracting([.all])
        return filters.isEmpty || filters.contains { $0.matches(route) }
    }

    func isSportAvailable(_ sport: RouteSportFilter) -> Bool {
        let movementFilters = selectedMovements.subtracting([.all])
        return movementFilters.isEmpty || sport == .all || movementFilters.contains(sport.movementKind)
    }

    private func sortPredicate(lhs: RouteRecord, rhs: RouteRecord, criteria: [RouteSortCriterion]) -> Bool {
        for criterion in criteria {
            let decision = sortDecision(for: criterion.option, lhs: lhs, rhs: rhs)

            switch decision {
            case .before:
                return criterion.direction == .descending
            case .after:
                return criterion.direction != .descending
            case .same:
                continue
            }
        }

        return fallbackSortDecision(lhs: lhs, rhs: rhs) != .after
    }

    private func compareStartProximity(lhs: RouteRecord, rhs: RouteRecord) -> SortDecision {
        let lhsDistance = distanceFromSelectedStartLocation(to: lhs)
        let rhsDistance = distanceFromSelectedStartLocation(to: rhs)

        switch (lhsDistance, rhsDistance) {
        case let (left?, right?) where left != right:
            return left < right ? .before : .after
        case (_?, nil):
            return .before
        case (nil, _?):
            return .after
        default:
            let locationComparison = lhs.displayLocation.localizedCaseInsensitiveCompare(rhs.displayLocation)
            if locationComparison != .orderedSame {
                return locationComparison == .orderedAscending ? .before : .after
            }

            return .same
        }
    }

    func distanceFromSelectedStartLocation(to route: RouteRecord) -> Double? {
        let distanceSignature = startDistanceSignature()
        if cachedStartDistanceSignature != distanceSignature {
            cachedStartDistanceSignature = distanceSignature
            cachedStartDistances = [:]
        }

        guard let selectedLocation = selectedStartLocationCoordinate,
              let routeCoordinate = route.startCoordinate else {
            return nil
        }

        let cacheKey = StartDistanceCacheKey(
            routeID: route.stravaRouteID,
            latitudeKey: Int((routeCoordinate.latitude * 100_000).rounded()),
            longitudeKey: Int((routeCoordinate.longitude * 100_000).rounded())
        )

        if let cachedDistance = cachedStartDistances[cacheKey] {
            return cachedDistance
        }

        let distance = haversineDistanceMiles(from: selectedLocation, to: routeCoordinate)
        cachedStartDistances[cacheKey] = distance
        return distance
    }

    private func routeFilterCacheKey(
        for routes: [RouteRecord],
        includesDistanceFilter: Bool,
        includesClimbFilter: Bool
    ) -> RouteFilterCacheKey {
        RouteFilterCacheKey(
            routesSignature: routesSignature(for: routes),
            filterSignature: filterStateSignature(
                includesDistanceFilter: includesDistanceFilter,
                includesClimbFilter: includesClimbFilter
            ),
            includesDistanceFilter: includesDistanceFilter,
            includesClimbFilter: includesClimbFilter
        )
    }

    private func routesSignature(for routes: [RouteRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(routes.count)

        for route in routes {
            hasher.combine(route.libraryFilterSignature)
        }

        return hasher.finalize()
    }

    private func listNameSignature(for lists: [RouteList]) -> Int {
        var hasher = Hasher()
        hasher.combine(lists.count)

        for list in lists {
            hasher.combine(list.normalizedName)
        }

        return hasher.finalize()
    }

    private func filterStateSignature(
        includesDistanceFilter: Bool,
        includesClimbFilter: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(query.normalizedSearchText)

        for movement in selectedMovements.map(\.rawValue).sorted() {
            hasher.combine(movement)
        }

        for sport in selectedSports.map(\.rawValue).sorted() {
            hasher.combine(sport)
        }

        for surface in selectedSurfaceFilters.map(\.rawValue).sorted() {
            hasher.combine(surface)
        }

        for collection in selectedCollections.map(\.routeLabelIdentifier).sorted() {
            hasher.combine(collection)
        }

        hasher.combine(showOnlyOfflineRoutes)
        hasher.combine(selectedStartFilterMode.rawValue)

        for token in selectedStartTextFilters.map(\.routeLocationToken).sorted() {
            hasher.combine(token)
        }

        if selectedStartFilterMode == .radius {
            hasher.combine(selectedStartLocationLatitude)
            hasher.combine(selectedStartLocationLongitude)
            hasher.combine(selectedStartLocationRadiusMiles)
        }

        if includesDistanceFilter {
            hasher.combine(selectedDistance.rawValue)
            hasher.combine(selectedDistanceMinimumMiles)
            hasher.combine(selectedDistanceMaximumMiles)
        }

        if includesClimbFilter {
            hasher.combine(selectedClimb.rawValue)
            hasher.combine(selectedClimbMinimumFeet)
            hasher.combine(selectedClimbMaximumFeet)
        }

        return hasher.finalize()
    }

    private func sortStateSignature() -> Int {
        let criteria = normalizedSortCriteria(from: sortCriteria)
        var hasher = Hasher()
        hasher.combine(criteria.count)

        for criterion in criteria {
            hasher.combine(criterion.option.rawValue)
            hasher.combine(criterion.direction.rawValue)
        }

        if criteria.contains(where: { $0.option == .startProximity }) {
            hasher.combine(selectedStartLocationLatitude)
            hasher.combine(selectedStartLocationLongitude)
        }

        return hasher.finalize()
    }

    private func startDistanceSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(selectedStartLocationLatitude)
        hasher.combine(selectedStartLocationLongitude)
        return hasher.finalize()
    }

    private func haversineDistanceMiles(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> Double {
        let earthRadiusMiles = 3_958.7613
        let latitudeDelta = (destination.latitude - origin.latitude) * .pi / 180
        let longitudeDelta = (destination.longitude - origin.longitude) * .pi / 180
        let originLatitude = origin.latitude * .pi / 180
        let destinationLatitude = destination.latitude * .pi / 180

        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2) +
            cos(originLatitude) * cos(destinationLatitude) *
            sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMiles * c
    }

    private func displayMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private func shouldSuppressErrorBanner(for error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let apiError = error as? StravaAPIService.APIError {
            if case .cancelled = apiError {
                return true
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
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

    private func normalizedSortCriteria(from criteria: [RouteSortCriterion]) -> [RouteSortCriterion] {
        var seenOptions: Set<RouteSortOption> = []
        let uniqueCriteria = criteria.filter { seenOptions.insert($0.option).inserted }
        return uniqueCriteria.isEmpty ? [.defaultCriterion] : uniqueCriteria
    }

    private func defaultSortDirection(for option: RouteSortOption, current: RouteSortDirection? = nil) -> RouteSortDirection {
        if option == .name, current == nil {
            return .descending
        }

        return current ?? .descending
    }

    private func toggleMultiSelection<Option: Hashable & Equatable>(
        _ option: Option,
        in selections: inout Set<Option>,
        resetOption: Option
    ) {
        if option == resetOption {
            selections = [resetOption]
            return
        }

        selections.remove(resetOption)

        if selections.contains(option) {
            selections.remove(option)
        } else {
            selections.insert(option)
        }

        if selections.isEmpty {
            selections = [resetOption]
        }
    }

    private func sortDecision(for option: RouteSortOption, lhs: RouteRecord, rhs: RouteRecord) -> SortDecision {
        switch option {
        case .updatedAt:
            return compareDescending(lhs.primaryTimestamp, rhs.primaryTimestamp)
        case .name:
            return compareAscending(lhs.name, rhs.name)
        case .distance:
            return compareDescending(lhs.distanceMeters, rhs.distanceMeters)
        case .climb:
            return compareDescending(lhs.elevationGainMeters, rhs.elevationGainMeters)
        case .gradient:
            return compareDescending(routeGradientScore(for: lhs), routeGradientScore(for: rhs))
        case .estimatedTime:
            return compareDescending(lhs.estimatedMovingTime, rhs.estimatedMovingTime)
        case .startProximity:
            return compareStartProximity(lhs: lhs, rhs: rhs)
        }
    }

    private func routeGradientScore(for route: RouteRecord) -> Double {
        guard route.distanceMeters > 0 else {
            return 0
        }

        return route.elevationGainMeters / route.distanceMeters
    }

    private func fallbackSortDecision(lhs: RouteRecord, rhs: RouteRecord) -> SortDecision {
        let nameDecision = compareAscending(lhs.name, rhs.name)
        if nameDecision != .same {
            return nameDecision
        }

        return compareDescending(lhs.stravaRouteID, rhs.stravaRouteID)
    }

    private func compareDescending<Value: Comparable>(_ lhsValue: Value, _ rhsValue: Value) -> SortDecision {
        if lhsValue > rhsValue {
            return .before
        }

        if lhsValue < rhsValue {
            return .after
        }

        return .same
    }

    private func compareAscending(_ lhsValue: String, _ rhsValue: String) -> SortDecision {
        let comparison = lhsValue.localizedCaseInsensitiveCompare(rhsValue)
        switch comparison {
        case .orderedAscending:
            return .before
        case .orderedDescending:
            return .after
        case .orderedSame:
            return .same
        }
    }

    private enum SortDecision {
        case before
        case after
        case same
    }
}

private extension String {
    var normalizedSearchText: String {
        routeLocationToken
    }
}

private struct RouteLocationCoordinateKey: Hashable {
    let rawValue: String

    init(coordinate: CLLocationCoordinate2D) {
        let latitude = (coordinate.latitude * 1_000).rounded() / 1_000
        let longitude = (coordinate.longitude * 1_000).rounded() / 1_000
        rawValue = "\(latitude),\(longitude)"
    }
}

private struct CachedRouteLocationDetails: Codable {
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
        let resolvedFallback = fallbackName.trimmed.nilIfEmpty ?? "Pinned Start"
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

private actor RouteLocationMetadataResolver {
    private enum CacheStore {
        static let defaultsKey = "routeLocationMetadataCache"

        static func load() -> [String: CachedRouteLocationDetails] {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode([String: CachedRouteLocationDetails].self, from: data) else {
                return [:]
            }

            return decoded
        }

        static func save(_ cache: [String: CachedRouteLocationDetails]) {
            guard let data = try? JSONEncoder().encode(cache) else {
                return
            }

            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private var cache = CacheStore.load()

    func details(for coordinate: CLLocationCoordinate2D, fallbackName: String) async throws -> RouteStartLocationDetails? {
        let key = RouteLocationCoordinateKey(coordinate: coordinate).rawValue
        if let cachedDetails = cache[key] {
            return cachedDetails.asRouteStartLocationDetails(fallbackName: fallbackName)
        }

        let placemarks = try await reverseGeocode(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard let placemark = placemarks.first else {
            return nil
        }

        let details = placemark.routeStartLocationDetails(
            preferredName: nil,
            fallbackName: fallbackName.trimmed.nilIfEmpty ?? coordinate.formattedLabel
        )
        let cachedDetails = CachedRouteLocationDetails(details: details)
        cache[key] = cachedDetails
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
