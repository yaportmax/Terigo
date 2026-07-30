import Foundation
import CoreLocation
import SwiftData

enum RouteSurfaceKind: String {
    case paved
    case trail
    case mixed

    var displayName: String {
        switch self {
        case .paved:
            return "Paved"
        case .trail:
            return "Trail"
        case .mixed:
            return "Mixed"
        }
    }
}

@Model
final class RouteRecord {
    @Attribute(.unique) var stravaRouteID: Int
    var name: String
    var routeDescription: String
    var distanceMeters: Double
    var elevationGainMeters: Double
    var estimatedMovingTime: Double
    var routeType: Int
    var routeSubType: Int
    var isPrivate: Bool
    var isStarred: Bool
    var city: String
    var state: String
    var country: String
    var startRegionName: String?
    var startParkName: String?
    var startCountyName: String?
    var mapSummaryPolyline: String
    var routeDetailPolyline: String?
    var createdAt: Date?
    var updatedAt: Date?
    var syncedAt: Date
    var startLocationIndexedAt: Date?
    var collectionName: String
    var tagsBlob: String
    var notes: String
    var isPinned: Bool
    var isArchived: Bool
    var surfaceOverrideRawValue: String?
    var elevationProfileBlob: String?
    var offlineGPXRelativePath: String?
    var offlineMapSnapshotRelativePath: String?
    var offlineDownloadedAt: Date?
    @Transient private var cachedRouteGeometryPolyline: String?
    @Transient private var cachedRouteCoordinates: [CLLocationCoordinate2D] = []
    @Transient private var cachedElevationProfileBlob: String?
    @Transient private var cachedElevationProfileSamples: [RouteElevationSample] = []
    @Transient private var cachedSearchTermsSignature: Int?
    @Transient private var cachedSearchPhraseTerms: Set<String> = []
    @Transient private var cachedSearchIndexTerms: Set<String> = []

    init(remote route: StravaRoutePayload, syncedAt: Date) {
        stravaRouteID = route.id
        name = route.name
        routeDescription = route.description ?? ""
        distanceMeters = route.distance
        elevationGainMeters = route.elevationGain ?? 0
        estimatedMovingTime = route.estimatedMovingTime ?? 0
        routeType = route.type ?? 0
        routeSubType = route.subType ?? 0
        isPrivate = route.`private` ?? false
        isStarred = route.starred ?? false
        city = route.segments?.compactMap(\.city).first ?? ""
        state = route.segments?.compactMap(\.state).first ?? ""
        country = route.segments?.compactMap(\.country).first ?? ""
        startRegionName = nil
        startParkName = nil
        startCountyName = nil
        mapSummaryPolyline = route.map?.summaryPolyline ?? ""
        routeDetailPolyline = nil
        createdAt = route.createdAt
        updatedAt = route.updatedAt
        self.syncedAt = syncedAt
        startLocationIndexedAt = nil
        collectionName = ""
        tagsBlob = ""
        notes = ""
        isPinned = false
        isArchived = false
        surfaceOverrideRawValue = nil
        elevationProfileBlob = nil
        offlineGPXRelativePath = nil
        offlineMapSnapshotRelativePath = nil
        offlineDownloadedAt = nil
    }

    init(importedGPX route: ImportedGPXRoute, syncedAt: Date) {
        stravaRouteID = route.routeID
        name = route.name
        routeDescription = route.description
        distanceMeters = route.distanceMeters
        elevationGainMeters = route.elevationGainMeters
        estimatedMovingTime = route.estimatedMovingTime
        routeType = route.routeType
        routeSubType = route.routeSubType
        isPrivate = false
        isStarred = false
        city = route.city
        state = route.state
        country = route.country
        startRegionName = route.regionName.nilIfEmpty
        startParkName = route.parkName.nilIfEmpty
        startCountyName = route.countyName.nilIfEmpty
        mapSummaryPolyline = route.summaryPolyline
        routeDetailPolyline = route.summaryPolyline
        createdAt = route.createdAt
        updatedAt = route.updatedAt
        self.syncedAt = syncedAt
        startLocationIndexedAt = syncedAt
        collectionName = ""
        tagsBlob = ""
        notes = ""
        isPinned = false
        isArchived = false
        surfaceOverrideRawValue = route.surfaceKind?.rawValue
        elevationProfileBlob = RouteElevationProfileCodec.encode(route.elevationSamples)
        offlineGPXRelativePath = nil
        offlineMapSnapshotRelativePath = nil
        offlineDownloadedAt = nil
    }

    var tags: [String] {
        get {
            tagsBlob
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            tagsBlob = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
    }

    var labels: [String] {
        get {
            let combined = ([collectionName.trimmed.nilIfEmpty] + tags.map(Optional.some)).compactMap { $0 }
            return RouteRecord.normalizedLabels(combined)
        }
        set {
            collectionName = ""
            tags = RouteRecord.normalizedLabels(newValue)
        }
    }

    var hasLabels: Bool {
        !labels.isEmpty
    }

    var listNames: [String] {
        get { labels }
        set { labels = newValue }
    }

    var hasLists: Bool {
        hasLabels
    }

    var displayLocation: String {
        [startParkName?.trimmed.nilIfEmpty, city.trimmed.nilIfEmpty, normalizedStateDisplayName.nilIfEmpty, country.trimmed.nilIfEmpty]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var startAddressText: String? {
        var seen = Set<String>()
        let components = [
            startParkName?.trimmed.nilIfEmpty,
            startRegionName?.trimmed.nilIfEmpty,
            startCountyName?.trimmed.nilIfEmpty,
            city.trimmed.nilIfEmpty,
            normalizedStateDisplayName.nilIfEmpty,
            country.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .filter { value in
            let token = value.routeLocationToken
            guard !token.isEmpty, seen.insert(token).inserted else {
                return false
            }
            return true
        }

        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    var sportKind: RouteSportKind {
        if let inferredSportKind = textInferredSportKind {
            if !isImportedFromGPX, let syncedSportKind = stravaMappedSportKind {
                if inferredSportKind.shouldOverrideSyncedSportKind(syncedSportKind) {
                    return inferredSportKind
                }

                return syncedSportKind
            }

            return inferredSportKind
        }

        if !isImportedFromGPX, let syncedSportKind = stravaMappedSportKind {
            return syncedSportKind
        }

        return .other
    }

    var movementKind: RouteMovementFilter {
        sportKind.movementKind
    }

    var sportDisplayName: String {
        sportKind.title
    }

    var sportSymbolName: String {
        sportKind.symbolName
    }

    var surfaceKind: RouteSurfaceKind? {
        if let surfaceOverride = surfaceOverrideRawValue?.trimmed.nilIfEmpty,
           let storedSurfaceKind = RouteSurfaceKind(rawValue: surfaceOverride) {
            return storedSurfaceKind
        }

        let text = surfaceClassificationText
        let hasParkCue = startParkName?.trimmed.nilIfEmpty != nil
        let hasPavedCue = [
            "road",
            "paved",
            "asphalt",
            "greenway",
            "bike path",
            "cycleway",
            "sidewalk"
        ].contains(where: text.contains)
        let hasMixedCue = routeSubType == 3 ||
            routeSubType == 5 ||
            [
                "gravel",
                "mixed",
                "cyclocross",
                "fire road",
                "double track",
                "doubletrack"
            ].contains(where: text.contains)
        let hasTrailCue = routeSubType == 2 ||
            routeSubType == 4 ||
            hasParkCue ||
            [
                "trail",
                "singletrack",
                "single track",
                "trailhead",
                "wilderness",
                "preserve",
                "forest",
                "ridge",
                "summit",
                "peak",
                "canyon",
                "creek",
                "mesa",
                "pass",
                "switchback"
            ].contains(where: text.contains)
        let usesConservativeRoadFallback: Bool = {
            switch sportKind {
            case .run, .trailRun, .walk, .hike, .snowshoe:
                return true
            default:
                return false
            }
        }()

        switch routeSubType {
        case 1:
            if usesConservativeRoadFallback {
                if hasTrailCue {
                    return .trail
                }

                if hasMixedCue {
                    return .mixed
                }

                return hasPavedCue ? .paved : nil
            }

            return .paved
        case 2:
            return .trail
        case 3:
            return .mixed
        case 4:
            return .trail
        case 5:
            return .mixed
        default:
            break
        }

        if hasMixedCue {
            return .mixed
        }

        if hasTrailCue {
            return .trail
        }

        switch sportKind {
        case .mountainBike, .trailRun, .hike, .snowshoe, .ski:
            return .trail
        case .mixedRide, .gravelRide, .cyclocross:
            return .mixed
        case .ride:
            return .paved
        case .run, .walk, .wheelchair:
            return hasPavedCue ? .paved : nil
        case .other:
            return hasPavedCue ? .paved : nil
        }
    }

    var surfaceDisplayName: String? {
        surfaceKind?.displayName
    }

    var primaryTimestamp: Date {
        updatedAt ?? createdAt ?? syncedAt
    }

    var isImportedFromGPX: Bool {
        stravaRouteID < 0
    }

    var routeGeometryPolyline: String {
        routeDetailPolyline?.trimmed.nilIfEmpty ?? mapSummaryPolyline
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        let polyline = routeGeometryPolyline
        if cachedRouteGeometryPolyline == polyline {
            return cachedRouteCoordinates
        }

        let decodedCoordinates = RoutePolylineCodec.decode(polyline)
        cachedRouteGeometryPolyline = polyline
        cachedRouteCoordinates = decodedCoordinates
        return decodedCoordinates
    }

    var elevationProfile: [RouteElevationSample] {
        let normalizedBlob = elevationProfileBlob?.trimmed.nilIfEmpty

        if cachedElevationProfileBlob == normalizedBlob {
            return cachedElevationProfileSamples
        }

        let decodedSamples = RouteElevationProfileCodec.decode(normalizedBlob)
        cachedElevationProfileBlob = normalizedBlob
        cachedElevationProfileSamples = decodedSamples
        return decodedSamples
    }

    var hasElevationProfile: Bool {
        elevationProfile.count > 1
    }

    var startCoordinate: CLLocationCoordinate2D? {
        routeCoordinates.first
    }

    var endCoordinate: CLLocationCoordinate2D? {
        routeCoordinates.last
    }

    var routeURL: URL? {
        guard !isImportedFromGPX else {
            return nil
        }

        return URL(string: "https://www.strava.com/routes/\(stravaRouteID)")
    }

    var searchableText: String {
        searchKeywords.joined(separator: " ")
    }

    var searchKeywords: [String] {
        Array(searchIndexTerms).sorted()
    }

    var visibleSearchTerms: [String] {
        var seen = Set<String>()
        var terms: [String] = []

        func append(_ value: String?) {
            guard let trimmedValue = value?.trimmed.nilIfEmpty else {
                return
            }

            let token = trimmedValue.routeLocationToken
            guard !token.isEmpty, seen.insert(token).inserted else {
                return
            }

            terms.append(trimmedValue)
        }

        func append(_ values: [String]) {
            for value in values {
                append(value)
            }
        }

        append(labels)
        append(startParkName)
        append(startRegionName)
        append(startCountyName)
        append(city)
        append(normalizedStateDisplayName)
        append(country)
        append(sportDisplayName)

        return terms
    }

    func matchesSearchQuery(_ normalizedQuery: String) -> Bool {
        let query = normalizedQuery.routeLocationToken
        guard !query.isEmpty else {
            return true
        }

        let phraseTerms = searchPhraseTerms
        let indexTerms = searchIndexTerms
        let queryTerms = query.split(separator: " ").map(String.init)

        guard !queryTerms.isEmpty else {
            return true
        }

        if queryTerms.count == 1, let queryTerm = queryTerms.first {
            if indexTerms.contains(queryTerm) {
                return true
            }

            return phraseTerms.contains { phrase in
                phrase.split(separator: " ").contains(Substring(queryTerm))
            }
        }

        if phraseTerms.contains(query) || phraseTerms.contains(where: { $0.contains(query) }) {
            return true
        }

        return queryTerms.allSatisfy(indexTerms.contains)
    }

    var libraryFilterSignature: Int {
        var hasher = Hasher()
        hasher.combine(stravaRouteID)
        hasher.combine(searchTermsSignature)
        hasher.combine(distanceMeters)
        hasher.combine(elevationGainMeters)
        hasher.combine(estimatedMovingTime)
        hasher.combine(isPrivate)
        hasher.combine(surfaceOverrideRawValue ?? "")
        hasher.combine(primaryTimestamp)
        hasher.combine(syncedAt)
        hasher.combine(startLocationIndexedAt)
        hasher.combine(hasOfflineAssets)
        return hasher.finalize()
    }

    private var searchTermsSignature: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(routeDescription)
        hasher.combine(notes)
        hasher.combine(collectionName)
        hasher.combine(tagsBlob)
        hasher.combine(startParkName ?? "")
        hasher.combine(startRegionName ?? "")
        hasher.combine(startCountyName ?? "")
        hasher.combine(city)
        hasher.combine(state)
        hasher.combine(country)
        hasher.combine(routeType)
        hasher.combine(routeSubType)
        return hasher.finalize()
    }

    private var cachedSearchTermSets: (phraseTerms: Set<String>, indexTerms: Set<String>) {
        let signature = searchTermsSignature
        if cachedSearchTermsSignature == signature {
            return (cachedSearchPhraseTerms, cachedSearchIndexTerms)
        }

        let phraseTerms = buildSearchPhraseTerms()
        var indexTerms = phraseTerms

        for phrase in phraseTerms {
            for component in phrase.split(separator: " ") {
                indexTerms.insert(String(component))
            }
        }

        cachedSearchTermsSignature = signature
        cachedSearchPhraseTerms = phraseTerms
        cachedSearchIndexTerms = indexTerms
        return (phraseTerms, indexTerms)
    }

    private func buildSearchPhraseTerms() -> Set<String> {
        var terms = Set<String>()

        func add(_ value: String?) {
            guard let normalizedValue = value?.routeLocationToken,
                  !normalizedValue.isEmpty else {
                return
            }

            terms.insert(normalizedValue)
        }

        func add(_ values: [String]) {
            for value in values {
                add(value)
            }
        }

        add(name)
        add(routeDescription)
        add(notes)
        add(displayLocation)
        add(startAddressText)
        add(startRegionName)
        add(startCountyName)
        add(startParkName)
        add(city)
        add(state)
        add(normalizedStateDisplayName)
        add(country)
        add(sportDisplayName)
        add(movementKind.title)
        add(movementKind.shortTitle)
        add(startLocationMatchTokens.map { $0 })
        add(sportKind.searchAliases)

        return terms
    }

    private var surfaceClassificationText: String {
        [
            name.trimmed.nilIfEmpty,
            routeDescription.trimmed.nilIfEmpty,
            startParkName?.trimmed.nilIfEmpty,
            startRegionName?.trimmed.nilIfEmpty,
            startCountyName?.trimmed.nilIfEmpty,
            city.trimmed.nilIfEmpty,
            state.trimmed.nilIfEmpty,
            country.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .normalizedSportTokens
    }

    private var sportClassificationText: String {
        [name, routeDescription]
            .joined(separator: " ")
            .normalizedSportTokens
    }

    private var stravaMappedSportKind: RouteSportKind? {
        switch (routeType, routeSubType) {
        case (1, 1):
            return .ride
        case (1, 2), (1, 4):
            return .mountainBike
        case (1, 3):
            return .cyclocross
        case (1, 5):
            return .mixedRide
        case (1, _):
            return .ride
        case (6, 4):
            return .gravelRide
        case (6, 5):
            return .mixedRide
        case (6, _):
            return .ride
        case (5, 4), (5, 5):
            return .trailRun
        case (5, _):
            return .run
        case (4, 4), (4, 5):
            return .hike
        case (4, _):
            return .walk
        case (2, 4):
            return .trailRun
        case (2, _):
            return .run
        default:
            return nil
        }
    }

    private var textInferredSportKind: RouteSportKind? {
        let text = sportClassificationText
        let hasHikeCue = text.contains("hike") || text.contains("hiking") || text.contains("trek")
        let hasWalkCue = text.contains("walk") || text.contains("walking") || text.contains("stroll")
        let hasMountainBikeCue = text.contains("mountain bike") || text.contains(" mtb") || text.hasPrefix("mtb")
        let hasCyclocrossCue = text.contains("cyclocross")
        let hasGravelCue = text.contains("gravel")
        let hasMixedRideCue = text.contains("mixed") || text.contains("fire road") || text.contains("double track") || text.contains("doubletrack")
        let hasTrailRunCue = text.contains("trail run") || (text.contains("trail") && text.contains("run"))
        let hasRunCue = text.contains("run") || text.contains("jog")
        let hasRideCue = text.contains("ride") || text.contains("bike") || text.contains("cycling")

        if text.contains("snowshoe") {
            return .snowshoe
        }

        if text.contains("wheelchair") {
            return .wheelchair
        }

        if text.contains("ski") {
            return .ski
        }

        if hasHikeCue {
            return .hike
        }

        if hasWalkCue {
            return .walk
        }

        if hasMountainBikeCue {
            return .mountainBike
        }

        if hasCyclocrossCue {
            return .cyclocross
        }

        if hasGravelCue {
            return .gravelRide
        }

        if hasMixedRideCue {
            return .mixedRide
        }

        if hasTrailRunCue {
            return .trailRun
        }

        if hasRideCue {
            return .ride
        }

        if hasRunCue {
            return .run
        }

        return nil
    }

    func apply(remote route: StravaRoutePayload, syncedAt: Date) {
        let previousSummaryPolyline = mapSummaryPolyline
        name = route.name
        routeDescription = route.description ?? ""
        distanceMeters = route.distance
        elevationGainMeters = route.elevationGain ?? 0
        estimatedMovingTime = route.estimatedMovingTime ?? 0
        routeType = route.type ?? 0
        routeSubType = route.subType ?? 0
        isPrivate = route.`private` ?? false
        isStarred = route.starred ?? false
        city = route.segments?.compactMap(\.city).first ?? city
        state = route.segments?.compactMap(\.state).first ?? state
        country = route.segments?.compactMap(\.country).first ?? country
        mapSummaryPolyline = route.map?.summaryPolyline ?? mapSummaryPolyline
        createdAt = route.createdAt ?? createdAt
        updatedAt = route.updatedAt ?? updatedAt
        self.syncedAt = syncedAt

        if previousSummaryPolyline.routeLocationToken != mapSummaryPolyline.routeLocationToken {
            startLocationIndexedAt = nil
            startRegionName = nil
            startParkName = nil
            startCountyName = nil
        }
    }

    func apply(importedGPX route: ImportedGPXRoute, syncedAt: Date) {
        name = route.name
        routeDescription = route.description
        distanceMeters = route.distanceMeters
        elevationGainMeters = route.elevationGainMeters
        estimatedMovingTime = route.estimatedMovingTime
        routeType = route.routeType
        routeSubType = route.routeSubType
        isPrivate = false
        isStarred = false
        city = route.city
        state = route.state
        country = route.country
        startRegionName = route.regionName.nilIfEmpty
        startParkName = route.parkName.nilIfEmpty
        startCountyName = route.countyName.nilIfEmpty
        mapSummaryPolyline = route.summaryPolyline
        routeDetailPolyline = route.summaryPolyline
        createdAt = route.createdAt ?? createdAt
        updatedAt = route.updatedAt ?? updatedAt
        if let surfaceKind = route.surfaceKind {
            surfaceOverrideRawValue = surfaceKind.rawValue
        }
        elevationProfileBlob = RouteElevationProfileCodec.encode(route.elevationSamples)
        self.syncedAt = syncedAt
        startLocationIndexedAt = syncedAt
    }

    func applyImportedGeometry(_ route: ImportedGPXRoute) {
        city = route.city.trimmed.nilIfEmpty ?? city
        state = route.state.trimmed.nilIfEmpty ?? state
        country = route.country.trimmed.nilIfEmpty ?? country
        startRegionName = route.regionName.trimmed.nilIfEmpty ?? startRegionName
        startParkName = route.parkName.trimmed.nilIfEmpty ?? startParkName
        startCountyName = route.countyName.trimmed.nilIfEmpty ?? startCountyName
        if mapSummaryPolyline.trimmed.isEmpty {
            mapSummaryPolyline = route.summaryPolyline.trimmed.nilIfEmpty ?? mapSummaryPolyline
        }
        routeDetailPolyline = route.summaryPolyline.trimmed.nilIfEmpty ?? routeDetailPolyline
        if let surfaceKind = route.surfaceKind {
            surfaceOverrideRawValue = surfaceKind.rawValue
        }
        if !route.elevationSamples.isEmpty {
            elevationProfileBlob = RouteElevationProfileCodec.encode(route.elevationSamples)
        }
        startLocationIndexedAt = .now
    }

    var hasOfflineAssets: Bool {
        offlineGPXRelativePath?.trimmed.nilIfEmpty != nil ||
            offlineMapSnapshotRelativePath?.trimmed.nilIfEmpty != nil ||
            offlineDownloadedAt != nil
    }

    var needsStartLocationIndexing: Bool {
        startCoordinate != nil && startLocationIndexedAt == nil
    }

    func applyIndexedStartLocationDetails(_ details: RouteStartLocationDetails, indexedAt: Date = .now) {
        city = details.cityName.trimmed.nilIfEmpty ?? city
        state = details.stateName.trimmed.nilIfEmpty ?? state
        country = details.countryName.trimmed.nilIfEmpty ?? country
        startRegionName = details.regionName.trimmed.nilIfEmpty ?? startRegionName
        startParkName = details.parkName.trimmed.nilIfEmpty ?? startParkName
        startCountyName = details.countyName.trimmed.nilIfEmpty ?? startCountyName
        startLocationIndexedAt = indexedAt
    }

    func hasLabel(_ label: String) -> Bool {
        let token = label.routeLabelIdentifier
        guard !token.isEmpty else {
            return false
        }

        return labels.contains { $0.routeLabelIdentifier == token }
    }

    func toggledLabels(with label: String) -> [String] {
        let normalizedLabel = label.trimmed
        guard !normalizedLabel.isEmpty else {
            return labels
        }

        var updatedLabels = labels
        let token = normalizedLabel.routeLabelIdentifier

        if let existingIndex = updatedLabels.firstIndex(where: { $0.routeLabelIdentifier == token }) {
            updatedLabels.remove(at: existingIndex)
        } else {
            updatedLabels.append(normalizedLabel)
        }

        return RouteRecord.normalizedLabels(updatedLabels)
    }

    func hasList(named listName: String) -> Bool {
        hasLabel(listName)
    }

    func toggledListNames(with listName: String) -> [String] {
        toggledLabels(with: listName)
    }

    func removingList(named listName: String) -> [String] {
        let token = listName.routeLabelIdentifier
        guard !token.isEmpty else {
            return labels
        }

        return labels.filter { $0.routeLabelIdentifier != token }
    }

    func renamingList(from oldName: String, to newName: String) -> [String] {
        let oldToken = oldName.routeLabelIdentifier
        let normalizedNewName = newName.trimmed
        guard !oldToken.isEmpty, !normalizedNewName.isEmpty else {
            return labels
        }

        return RouteRecord.normalizedLabels(
            labels.map { label in
                label.routeLabelIdentifier == oldToken ? normalizedNewName : label
            }
        )
    }

    func startLocationValue(for mode: RouteStartFilterMode) -> String? {
        switch mode {
        case .none, .radius:
            return nil
        case .namedAreas:
            return nil
        case .region:
            return startRegionName?.trimmed.nilIfEmpty
        case .park:
            return startParkName?.trimmed.nilIfEmpty
        case .county:
            return startCountyName?.trimmed.nilIfEmpty
        case .city:
            return city.trimmed.nilIfEmpty
        case .state:
            return state.trimmed.nilIfEmpty
        case .country:
            return country.trimmed.nilIfEmpty
        }
    }

    var startLocationMatchTokens: Set<String> {
        Set(
            [
                startParkName?.trimmed.nilIfEmpty,
                startRegionName?.trimmed.nilIfEmpty,
                startCountyName?.trimmed.nilIfEmpty,
                city.trimmed.nilIfEmpty,
                normalizedStateDisplayName.nilIfEmpty,
                country.trimmed.nilIfEmpty
            ]
            .compactMap { $0?.routeLocationToken }
            .filter { !$0.isEmpty }
        )
    }

    private var normalizedStateDisplayName: String {
        state.expandedUSStateNameIfNeeded
    }

    private var searchPhraseTerms: Set<String> {
        cachedSearchTermSets.phraseTerms
    }

    private var searchIndexTerms: Set<String> {
        cachedSearchTermSets.indexTerms
    }

    static func normalizedLabels(_ rawLabels: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedLabels: [String] = []

        for label in rawLabels {
            let trimmedLabel = label.trimmed
            let token = trimmedLabel.routeLabelIdentifier

            guard !trimmedLabel.isEmpty,
                  !token.isEmpty,
                  seen.insert(token).inserted else {
                continue
            }

            normalizedLabels.append(trimmedLabel)
        }

        return normalizedLabels
    }

    func elevationSample(closestToDistanceMeters distanceMeters: Double?) -> RouteElevationSample? {
        guard let distanceMeters else {
            return nil
        }

        let samples = elevationProfile
        guard !samples.isEmpty else {
            return nil
        }

        guard samples.count > 1 else {
            return samples.first
        }

        var lowerIndex = 0
        var upperIndex = samples.count - 1

        while lowerIndex < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2

            if samples[middleIndex].distanceMeters < distanceMeters {
                lowerIndex = middleIndex + 1
            } else {
                upperIndex = middleIndex
            }
        }

        let upperSample = samples[lowerIndex]
        if lowerIndex == 0 {
            return upperSample
        }

        let lowerSample = samples[lowerIndex - 1]
        return abs(lowerSample.distanceMeters - distanceMeters) <= abs(upperSample.distanceMeters - distanceMeters)
            ? lowerSample
            : upperSample
    }
}

struct RouteElevationSample: Codable, Hashable, Identifiable {
    let distanceMeters: Double
    let elevationMeters: Double
    let latitude: Double
    let longitude: Double

    var id: String {
        "\(distanceMeters)-\(latitude)-\(longitude)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private enum RouteElevationProfileCodec {
    static func encode(_ samples: [RouteElevationSample]) -> String? {
        guard !samples.isEmpty else {
            return nil
        }

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(samples) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func decode(_ blob: String?) -> [RouteElevationSample] {
        guard let blob = blob?.trimmingCharacters(in: .whitespacesAndNewlines),
              !blob.isEmpty,
              let data = blob.data(using: .utf8),
              let samples = try? JSONDecoder().decode([RouteElevationSample].self, from: data) else {
            return []
        }

        return samples
    }
}

private extension String {
    var normalizedSportTokens: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private extension RouteSportKind {
    func shouldOverrideSyncedSportKind(_ syncedSportKind: RouteSportKind) -> Bool {
        switch (self, syncedSportKind) {
        case (.hike, .run), (.hike, .trailRun), (.hike, .walk),
             (.walk, .run), (.walk, .trailRun), (.walk, .hike),
             (.snowshoe, .run), (.snowshoe, .trailRun), (.snowshoe, .walk),
             (.ski, .run), (.ski, .trailRun), (.ski, .walk),
             (.wheelchair, .run), (.wheelchair, .trailRun), (.wheelchair, .walk),
             (.mountainBike, .ride), (.gravelRide, .ride), (.cyclocross, .ride),
             (.trailRun, .run):
            return true
        default:
            return false
        }
    }

    var searchAliases: [String] {
        switch self {
        case .ride:
            return ["road ride", "ride", "road cycling", "cycling"]
        case .mountainBike:
            return ["mountain bike", "mountain biking", "mtb"]
        case .mixedRide:
            return ["mixed ride", "mixed bike", "mixed cycling"]
        case .gravelRide:
            return ["gravel ride", "gravel cycling", "gravel"]
        case .cyclocross:
            return ["cyclocross", "cross", "cx"]
        case .run:
            return ["run", "running", "road run"]
        case .trailRun:
            return ["trail run", "trail running", "run", "running", "trail"]
        case .walk:
            return ["walk", "walking", "stroll"]
        case .hike:
            return ["hike", "hiking", "trek", "trekking"]
        case .snowshoe:
            return ["snowshoe", "snowshoeing"]
        case .ski:
            return ["ski", "skiing"]
        case .wheelchair:
            return ["wheelchair", "accessible"]
        case .other:
            return ["other"]
        }
    }
}

private extension String {
    var expandedUSStateNameIfNeeded: String {
        let trimmedValue = trimmed
        guard trimmedValue.count == 2 else {
            return trimmedValue
        }

        let abbreviation = trimmedValue.uppercased()
        return Self.usStateNames[abbreviation] ?? trimmedValue
    }

    static let usStateNames: [String: String] = [
        "AL": "Alabama",
        "AK": "Alaska",
        "AZ": "Arizona",
        "AR": "Arkansas",
        "CA": "California",
        "CO": "Colorado",
        "CT": "Connecticut",
        "DE": "Delaware",
        "FL": "Florida",
        "GA": "Georgia",
        "HI": "Hawaii",
        "ID": "Idaho",
        "IL": "Illinois",
        "IN": "Indiana",
        "IA": "Iowa",
        "KS": "Kansas",
        "KY": "Kentucky",
        "LA": "Louisiana",
        "ME": "Maine",
        "MD": "Maryland",
        "MA": "Massachusetts",
        "MI": "Michigan",
        "MN": "Minnesota",
        "MS": "Mississippi",
        "MO": "Missouri",
        "MT": "Montana",
        "NE": "Nebraska",
        "NV": "Nevada",
        "NH": "New Hampshire",
        "NJ": "New Jersey",
        "NM": "New Mexico",
        "NY": "New York",
        "NC": "North Carolina",
        "ND": "North Dakota",
        "OH": "Ohio",
        "OK": "Oklahoma",
        "OR": "Oregon",
        "PA": "Pennsylvania",
        "RI": "Rhode Island",
        "SC": "South Carolina",
        "SD": "South Dakota",
        "TN": "Tennessee",
        "TX": "Texas",
        "UT": "Utah",
        "VT": "Vermont",
        "VA": "Virginia",
        "WA": "Washington",
        "WV": "West Virginia",
        "WI": "Wisconsin",
        "WY": "Wyoming",
        "DC": "District of Columbia"
    ]
}
