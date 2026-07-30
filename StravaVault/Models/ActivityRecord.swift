import CoreLocation
import Foundation
import SwiftData

enum ActivitySourceKind: String, Codable, CaseIterable {
    case strava
    case local
}

@Model
final class ActivityRecord {
    @Attribute(.unique) var activityKey: String
    var stravaActivityID: Int?
    var sourceRawValue: String
    var name: String
    var activityDescription: String
    var sportTypeRawValue: String
    var legacyTypeRawValue: String
    var distanceMeters: Double
    var movingTime: Double
    var elapsedTime: Double
    var elevationGainMeters: Double
    var averageSpeedMetersPerSecond: Double
    var hasHeartrate: Bool = false
    var averageHeartRateBpm: Double?
    var maxHeartRateBpm: Double?
    var isPrivate: Bool
    var startDate: Date
    var updatedAt: Date?
    var syncedAt: Date
    var city: String
    var state: String
    var country: String
    var startRegionName: String?
    var startParkName: String?
    var startCountyName: String?
    var startLatitude: Double?
    var startLongitude: Double?
    var endLatitude: Double?
    var endLongitude: Double?
    var mapSummaryPolyline: String
    var activityDetailPolyline: String?
    var elevationProfileBlob: String?
    var detailIndexedAt: Date?
    var coverageIndexedAt: Date?
    var newCoverageMeters: Double
    var lastUploadID: Int?
    var lastUploadStatus: String?
    var uploadedActivityID: Int?
    var uploadedAt: Date?
    var externalUploadID: String?
    var effortAnalysisVersion: Int = 0
    var effortAnalysisBlob: String?
    var effortAnalysisComputedAt: Date?
    @Transient private var cachedActivityGeometryPolyline: String?
    @Transient private var cachedActivityCoordinates: [CLLocationCoordinate2D] = []
    @Transient private var cachedSimplifiedGeometryPolyline: String?
    @Transient private var cachedSimplifiedCoordinateLimit = 0
    @Transient private var cachedSimplifiedCoordinates: [CLLocationCoordinate2D] = []
    @Transient private var cachedElevationProfileBlob: String?
    @Transient private var cachedElevationProfileSamples: [RouteElevationSample] = []
    @Transient private var cachedDisplayLocationSignature: String?
    @Transient private var cachedDisplayLocationValue = ""
    @Transient private var cachedStartAddressSignature: String?
    @Transient private var cachedStartAddressValue: String?
    @Transient private var cachedSearchHaystackSignature: String?
    @Transient private var cachedSearchHaystackValue = ""
    @Transient private var cachedEffortAnalysisBlob: String?
    @Transient private var cachedEffortAnalysisValue: ActivityEffortAnalysis?

    init(remote activity: StravaActivitySummaryPayload, syncedAt: Date) {
        activityKey = "strava-\(activity.id)"
        stravaActivityID = activity.id
        sourceRawValue = ActivitySourceKind.strava.rawValue
        name = activity.name.trimmed.nilIfEmpty ?? "Untitled Activity"
        activityDescription = activity.description?.trimmed ?? ""
        sportTypeRawValue = activity.sportType?.trimmed ?? ""
        legacyTypeRawValue = activity.type?.trimmed ?? ""
        distanceMeters = activity.distance
        movingTime = activity.movingTime ?? 0
        elapsedTime = activity.elapsedTime ?? 0
        elevationGainMeters = activity.totalElevationGain ?? 0
        averageSpeedMetersPerSecond = activity.averageSpeed ?? 0
        hasHeartrate = activity.hasHeartrate ?? false
        averageHeartRateBpm = activity.averageHeartrate
        maxHeartRateBpm = activity.maxHeartrate
        isPrivate = activity.private ?? false
        startDate = activity.startDate ?? syncedAt
        updatedAt = activity.startDate ?? syncedAt
        self.syncedAt = syncedAt
        city = activity.locationCity?.trimmed ?? ""
        state = activity.locationState?.trimmed ?? ""
        country = activity.locationCountry?.trimmed ?? ""
        startRegionName = nil
        startParkName = nil
        startCountyName = nil
        startLatitude = activity.startLatlng?.first
        startLongitude = activity.startLatlng?.dropFirst().first
        endLatitude = activity.endLatlng?.first
        endLongitude = activity.endLatlng?.dropFirst().first
        mapSummaryPolyline = activity.map?.summaryPolyline?.trimmed ?? ""
        activityDetailPolyline = nil
        elevationProfileBlob = nil
        detailIndexedAt = nil
        coverageIndexedAt = nil
        newCoverageMeters = 0
        lastUploadID = nil
        lastUploadStatus = nil
        uploadedActivityID = nil
        uploadedAt = nil
        externalUploadID = nil
        effortAnalysisVersion = 0
        effortAnalysisBlob = nil
        effortAnalysisComputedAt = nil
    }

    init(
        localName: String,
        description: String,
        sportKind: RouteSportKind,
        coordinates: [CLLocationCoordinate2D],
        elevationSamples: [RouteElevationSample],
        startDate: Date,
        movingTime: Double,
        elapsedTime: Double,
        distanceMeters: Double,
        elevationGainMeters: Double,
        averageSpeedMetersPerSecond: Double,
        locationDetails: RouteStartLocationDetails
    ) {
        let identifier = UUID().uuidString.lowercased()
        activityKey = "local-\(identifier)"
        stravaActivityID = nil
        sourceRawValue = ActivitySourceKind.local.rawValue
        name = localName.trimmed.nilIfEmpty ?? "Recorded Activity"
        activityDescription = description.trimmed
        sportTypeRawValue = sportKind.stravaUploadSportType
        legacyTypeRawValue = sportKind.title
        self.distanceMeters = distanceMeters
        self.movingTime = movingTime
        self.elapsedTime = elapsedTime
        self.elevationGainMeters = elevationGainMeters
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        hasHeartrate = false
        averageHeartRateBpm = nil
        maxHeartRateBpm = nil
        isPrivate = true
        self.startDate = startDate
        updatedAt = startDate
        syncedAt = startDate
        city = locationDetails.cityName.trimmed
        state = locationDetails.stateName.trimmed
        country = locationDetails.countryName.trimmed
        startRegionName = locationDetails.regionName.trimmed.nilIfEmpty
        startParkName = locationDetails.parkName.trimmed.nilIfEmpty
        startCountyName = locationDetails.countyName.trimmed.nilIfEmpty
        startLatitude = coordinates.first?.latitude
        startLongitude = coordinates.first?.longitude
        endLatitude = coordinates.last?.latitude
        endLongitude = coordinates.last?.longitude
        let encodedPolyline = RoutePolylineCodec.encode(coordinates)
        mapSummaryPolyline = encodedPolyline
        activityDetailPolyline = encodedPolyline
        elevationProfileBlob = ActivityElevationProfileCodec.encode(elevationSamples)
        detailIndexedAt = startDate
        coverageIndexedAt = nil
        newCoverageMeters = 0
        lastUploadID = nil
        lastUploadStatus = nil
        uploadedActivityID = nil
        uploadedAt = nil
        externalUploadID = nil
        effortAnalysisVersion = 0
        effortAnalysisBlob = nil
        effortAnalysisComputedAt = nil
    }

    var sourceKind: ActivitySourceKind {
        ActivitySourceKind(rawValue: sourceRawValue) ?? .strava
    }

    var coordinates: [CLLocationCoordinate2D] {
        let polyline = activityGeometryPolyline
        if cachedActivityGeometryPolyline == polyline {
            return cachedActivityCoordinates
        }

        let decodedCoordinates = RoutePolylineCodec.decode(polyline)
        cachedActivityGeometryPolyline = polyline
        cachedActivityCoordinates = decodedCoordinates

        if cachedSimplifiedGeometryPolyline != polyline {
            cachedSimplifiedGeometryPolyline = nil
            cachedSimplifiedCoordinateLimit = 0
            cachedSimplifiedCoordinates = []
        }

        return decodedCoordinates
    }

    var activityGeometryPolyline: String {
        activityDetailPolyline?.trimmed.nilIfEmpty ?? mapSummaryPolyline
    }

    var startCoordinate: CLLocationCoordinate2D? {
        if let latitude = startLatitude, let longitude = startLongitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        return RoutePolylineCodec.firstCoordinate(in: activityGeometryPolyline)
    }

    var endCoordinate: CLLocationCoordinate2D? {
        if let latitude = endLatitude, let longitude = endLongitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        return coordinates.last
    }

    var displayLocation: String {
        let signature = [
            startParkName?.trimmed ?? "",
            city.trimmed,
            normalizedStateDisplayName,
            country.trimmed
        ]
        .joined(separator: "\u{1F}")

        if cachedDisplayLocationSignature == signature {
            return cachedDisplayLocationValue
        }

        let value = [startParkName?.trimmed.nilIfEmpty, city.trimmed.nilIfEmpty, normalizedStateDisplayName.nilIfEmpty, country.trimmed.nilIfEmpty]
            .compactMap { $0 }
            .joined(separator: ", ")

        cachedDisplayLocationSignature = signature
        cachedDisplayLocationValue = value
        return value
    }

    var startAddressText: String? {
        let signature = [
            startParkName?.trimmed ?? "",
            startRegionName?.trimmed ?? "",
            startCountyName?.trimmed ?? "",
            city.trimmed,
            normalizedStateDisplayName,
            country.trimmed
        ]
        .joined(separator: "\u{1F}")

        if cachedStartAddressSignature == signature {
            return cachedStartAddressValue
        }

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
        .filter { component in
            let token = component.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return !token.isEmpty && seen.insert(token).inserted
        }

        let value = components.isEmpty ? nil : components.joined(separator: ", ")
        cachedStartAddressSignature = signature
        cachedStartAddressValue = value
        return value
    }

    var sportKind: RouteSportKind {
        RouteSportKind.fromActivity(
            sportTypeRawValue: sportTypeRawValue,
            legacyTypeRawValue: legacyTypeRawValue,
            title: name
        )
    }

    var sportDisplayName: String {
        sportKind.title
    }

    var sportSymbolName: String {
        sportKind.symbolName
    }

    var normalizedSearchHaystack: String {
        let signature = [
            name,
            activityDescription,
            displayLocation,
            startAddressText ?? "",
            city,
            normalizedStateDisplayName,
            country,
            sportDisplayName
        ]
        .joined(separator: "\u{1F}")

        if cachedSearchHaystackSignature == signature {
            return cachedSearchHaystackValue
        }

        let haystack = [
            name,
            activityDescription,
            displayLocation,
            startAddressText ?? "",
            city,
            normalizedStateDisplayName,
            country,
            sportDisplayName
        ]
        .joined(separator: " ")
        .routeLocationToken

        cachedSearchHaystackSignature = signature
        cachedSearchHaystackValue = haystack
        return haystack
    }

    var effortAnalysis: ActivityEffortAnalysis? {
        let blob = effortAnalysisBlob?.trimmed.nilIfEmpty
        guard cachedEffortAnalysisBlob != blob else {
            return cachedEffortAnalysisValue
        }

        let decoded = ActivityEffortAnalysisCodec.decode(blob)
        cachedEffortAnalysisBlob = blob
        cachedEffortAnalysisValue = decoded
        return decoded
    }

    var hasEffortAnalysis: Bool {
        effortAnalysis != nil
    }

    var effortAnalysisIsCurrent: Bool {
        guard let effortAnalysis, let effortAnalysisComputedAt else {
            return false
        }

        return effortAnalysis.version == ActivityEffortAnalysisVersion.current &&
            effortAnalysisComputedAt >= syncedAt
    }

    var effortAnalysisHeartRateSummary: ActivityEffortHeartRateSummary? {
        effortAnalysis?.heartRate
    }

    var effortAnalysisTemperatureSummary: ActivityEffortTemperatureSummary? {
        effortAnalysis?.temperature
    }

    var hasDetailedGeometry: Bool {
        activityDetailPolyline?.trimmed.nilIfEmpty != nil
    }

    var elevationSamples: [RouteElevationSample] {
        let normalizedBlob = elevationProfileBlob?.trimmed.nilIfEmpty
        guard normalizedBlob != cachedElevationProfileBlob else {
            return cachedElevationProfileSamples
        }

        let decodedSamples = ActivityElevationProfileCodec.decode(normalizedBlob)
        cachedElevationProfileBlob = normalizedBlob
        cachedElevationProfileSamples = decodedSamples
        return decodedSamples
    }

    var normalizedStateDisplayName: String {
        RouteStateNormalizer.expandedName(for: state)
    }

    var stravaURL: URL? {
        guard let stravaActivityID else {
            return nil
        }

        return URL(string: "https://www.strava.com/activities/\(stravaActivityID)")
    }

    var isUploadedToStrava: Bool {
        uploadedActivityID != nil
    }

    func mapDisplayCoordinates(maximumPointCount: Int = 600) -> [CLLocationCoordinate2D] {
        let polyline = activityGeometryPolyline
        if cachedSimplifiedGeometryPolyline == polyline,
           cachedSimplifiedCoordinateLimit == maximumPointCount {
            return cachedSimplifiedCoordinates
        }

        let simplifiedCoordinates = RouteMapboxGeometry.simplifiedOfflineLineCoordinates(
            for: coordinates,
            maximumPointCount: maximumPointCount
        )
        cachedSimplifiedGeometryPolyline = polyline
        cachedSimplifiedCoordinateLimit = maximumPointCount
        cachedSimplifiedCoordinates = simplifiedCoordinates
        return simplifiedCoordinates
    }

    func applySummary(_ activity: StravaActivitySummaryPayload, syncedAt: Date) {
        name = activity.name.trimmed.nilIfEmpty ?? name
        activityDescription = activity.description?.trimmed ?? activityDescription
        sportTypeRawValue = activity.sportType?.trimmed ?? sportTypeRawValue
        legacyTypeRawValue = activity.type?.trimmed ?? legacyTypeRawValue
        distanceMeters = activity.distance
        movingTime = activity.movingTime ?? movingTime
        elapsedTime = activity.elapsedTime ?? elapsedTime
        elevationGainMeters = activity.totalElevationGain ?? elevationGainMeters
        averageSpeedMetersPerSecond = activity.averageSpeed ?? averageSpeedMetersPerSecond
        hasHeartrate = activity.hasHeartrate ?? hasHeartrate
        averageHeartRateBpm = activity.averageHeartrate ?? averageHeartRateBpm
        maxHeartRateBpm = activity.maxHeartrate ?? maxHeartRateBpm
        isPrivate = activity.private ?? isPrivate
        startDate = activity.startDate ?? startDate
        updatedAt = activity.startDate ?? updatedAt
        self.syncedAt = syncedAt
        city = activity.locationCity?.trimmed ?? city
        state = activity.locationState?.trimmed ?? state
        country = activity.locationCountry?.trimmed ?? country
        startLatitude = activity.startLatlng?.first ?? startLatitude
        startLongitude = activity.startLatlng?.dropFirst().first ?? startLongitude
        endLatitude = activity.endLatlng?.first ?? endLatitude
        endLongitude = activity.endLatlng?.dropFirst().first ?? endLongitude
        if let polyline = activity.map?.summaryPolyline?.trimmed.nilIfEmpty {
            mapSummaryPolyline = polyline
        }
    }

    func applyDetailedActivity(_ activity: StravaDetailedActivityPayload, syncedAt: Date) {
        name = activity.name.trimmed.nilIfEmpty ?? name
        activityDescription = activity.description?.trimmed ?? activityDescription
        sportTypeRawValue = activity.sportType?.trimmed ?? sportTypeRawValue
        legacyTypeRawValue = activity.type?.trimmed ?? legacyTypeRawValue
        distanceMeters = activity.distance
        movingTime = activity.movingTime ?? movingTime
        elapsedTime = activity.elapsedTime ?? elapsedTime
        elevationGainMeters = activity.totalElevationGain ?? elevationGainMeters
        averageSpeedMetersPerSecond = activity.averageSpeed ?? averageSpeedMetersPerSecond
        hasHeartrate = activity.hasHeartrate ?? hasHeartrate
        averageHeartRateBpm = activity.averageHeartrate ?? averageHeartRateBpm
        maxHeartRateBpm = activity.maxHeartrate ?? maxHeartRateBpm
        isPrivate = activity.private ?? isPrivate
        updatedAt = activity.updatedAt ?? updatedAt
        self.syncedAt = syncedAt
        city = activity.locationCity?.trimmed ?? city
        state = activity.locationState?.trimmed ?? state
        country = activity.locationCountry?.trimmed ?? country
        startLatitude = activity.startLatlng?.first ?? startLatitude
        startLongitude = activity.startLatlng?.dropFirst().first ?? startLongitude
        endLatitude = activity.endLatlng?.first ?? endLatitude
        endLongitude = activity.endLatlng?.dropFirst().first ?? endLongitude
        if let polyline = activity.map?.summaryPolyline?.trimmed.nilIfEmpty {
            mapSummaryPolyline = polyline
        }
    }

    func applyStreams(_ streams: StravaActivityStreamsPayload, indexedAt: Date = .now) {
        if let latLngStream = streams.latlng?.data, !latLngStream.isEmpty {
            let coordinates = latLngStream.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }

            if !coordinates.isEmpty {
                activityDetailPolyline = RoutePolylineCodec.encode(coordinates)
            }
        }

        if let heartrateStream = streams.heartrate?.data, !heartrateStream.isEmpty {
            hasHeartrate = true
            if averageHeartRateBpm == nil {
                averageHeartRateBpm = heartrateStream.average
            }
            if maxHeartRateBpm == nil {
                maxHeartRateBpm = heartrateStream.max()
            }
        }

        let distances = streams.distance?.data ?? []
        let altitudes = streams.altitude?.data ?? []
        let latLngStream = streams.latlng?.data ?? []
        let count = min(distances.count, altitudes.count, latLngStream.count)
        if count > 1 {
            let samples = (0..<count).compactMap { index -> RouteElevationSample? in
                let pair = latLngStream[index]
                guard pair.count >= 2 else { return nil }
                return RouteElevationSample(
                    distanceMeters: distances[index],
                    elevationMeters: altitudes[index],
                    latitude: pair[0],
                    longitude: pair[1]
                )
            }
            elevationProfileBlob = ActivityElevationProfileCodec.encode(samples)
        }

        detailIndexedAt = indexedAt
        coverageIndexedAt = nil
    }

    func applyEffortAnalysis(_ analysis: ActivityEffortAnalysis, analyzedAt: Date = .now) {
        effortAnalysisVersion = analysis.version
        effortAnalysisBlob = ActivityEffortAnalysisCodec.encode(analysis)
        effortAnalysisComputedAt = analyzedAt
        cachedEffortAnalysisBlob = effortAnalysisBlob
        cachedEffortAnalysisValue = analysis
    }

    func markUploadStarted(uploadID: Int?, externalID: String) {
        lastUploadID = uploadID
        externalUploadID = externalID
        lastUploadStatus = "Processing"
        uploadedAt = nil
        uploadedActivityID = nil
    }

    func applyUploadStatus(_ status: StravaUploadPayload, at date: Date = .now) {
        lastUploadID = status.numericID
        externalUploadID = status.externalID ?? externalUploadID
        lastUploadStatus = status.error?.trimmed.nilIfEmpty ?? status.status
        uploadedActivityID = status.activityID
        if status.activityID != nil {
            uploadedAt = date
        }
    }

    func asImportedRoute(routeID: Int) -> ImportedGPXRoute {
        ImportedGPXRoute(
            routeID: routeID,
            name: name,
            description: activityDescription,
            distanceMeters: distanceMeters,
            elevationGainMeters: elevationGainMeters,
            elevationSamples: elevationSamples,
            estimatedMovingTime: movingTime > 0 ? movingTime : elapsedTime,
            routeType: sportKind.routeTypeMapping.type,
            routeSubType: sportKind.routeTypeMapping.subType,
            regionName: startRegionName ?? "",
            parkName: startParkName ?? "",
            countyName: startCountyName ?? "",
            city: city,
            state: state,
            country: country,
            summaryPolyline: activityGeometryPolyline,
            surfaceKind: sportKind.defaultSurfaceKind,
            createdAt: startDate,
            updatedAt: updatedAt ?? syncedAt
        )
    }

    func exportGPXData() throws -> Data {
        let coordinates = self.coordinates
        guard !coordinates.isEmpty else {
            throw ActivityRecordError.missingGeometry
        }

        let baseDate = startDate
        let totalDuration = max(elapsedTime, movingTime, Double(coordinates.count - 1))
        let timeStep = totalDuration / Double(max(coordinates.count - 1, 1))
        let elevationsByCoordinate = Dictionary(
            uniqueKeysWithValues: elevationSamples.map { sample in
                (sample.id, sample.elevationMeters)
            }
        )

        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="Terigo" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "<trk>",
            "<name>\(xmlEscaped(name))</name>"
        ]

        if let description = activityDescription.trimmed.nilIfEmpty {
            lines.append("<desc>\(xmlEscaped(description))</desc>")
        }

        lines.append("<trkseg>")

        for (index, coordinate) in coordinates.enumerated() {
            let timestamp = baseDate.addingTimeInterval(Double(index) * timeStep)
            let coordinateKey = RouteElevationSample(
                distanceMeters: 0,
                elevationMeters: 0,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ).id
            let elevationLine = elevationsByCoordinate[coordinateKey].map { "<ele>\(String(format: "%.1f", $0))</ele>" } ?? ""
            lines.append(
                """
                <trkpt lat="\(String(format: "%.6f", coordinate.latitude))" lon="\(String(format: "%.6f", coordinate.longitude))">\(elevationLine)<time>\(ISO8601DateFormatter.standard.string(from: timestamp))</time></trkpt>
                """
            )
        }

        lines.append("</trkseg>")
        lines.append("</trk>")
        lines.append("</gpx>")

        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }
}

enum ActivityRecordError: LocalizedError {
    case missingGeometry

    var errorDescription: String? {
        switch self {
        case .missingGeometry:
            return "This activity does not have enough path data to create a route or upload file."
        }
    }
}

private enum ActivityElevationProfileCodec {
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

private enum RouteStateNormalizer {
    private static let abbreviations: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
        "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
        "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        "DC": "District of Columbia"
    ]

    static func expandedName(for value: String) -> String {
        let trimmed = value.trimmed
        guard let expanded = abbreviations[trimmed.uppercased()] else {
            return trimmed
        }

        return expanded
    }
}

extension RouteSportKind {
    static func fromActivity(
        sportTypeRawValue: String,
        legacyTypeRawValue: String,
        title: String
    ) -> RouteSportKind {
        let normalizedSportType = sportTypeRawValue.normalizedActivityToken
        let normalizedLegacyType = legacyTypeRawValue.normalizedActivityToken
        let normalizedTitle = title.normalizedActivityToken

        switch normalizedSportType {
        case "ride", "ebikeride":
            return .ride
        case "mountainbikeride", "emountainbikeride":
            return .mountainBike
        case "gravelride":
            return .gravelRide
        case "run":
            return normalizedTitle.contains("trail") ? .trailRun : .run
        case "trailrun":
            return .trailRun
        case "walk":
            return .walk
        case "hike":
            return .hike
        case "snowshoe":
            return .snowshoe
        case "nordicski", "alpineski", "backcountryski", "rollerski":
            return .ski
        case "wheelchair", "handcycle":
            return .wheelchair
        default:
            break
        }

        switch normalizedLegacyType {
        case "ride":
            return .ride
        case "run":
            return normalizedTitle.contains("trail") ? .trailRun : .run
        case "walk":
            return .walk
        case "hike":
            return .hike
        default:
            break
        }

        if normalizedTitle.contains("trail run") || normalizedTitle.contains("trailrun") {
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

        return .other
    }

    var stravaUploadSportType: String {
        switch self {
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

    var routeTypeMapping: (type: Int, subType: Int) {
        switch self {
        case .ride:
            return (1, 1)
        case .mountainBike:
            return (1, 2)
        case .mixedRide:
            return (1, 5)
        case .gravelRide:
            return (1, 3)
        case .cyclocross:
            return (1, 3)
        case .run:
            return (5, 1)
        case .trailRun:
            return (5, 4)
        case .walk:
            return (5, 6)
        case .hike:
            return (5, 3)
        case .snowshoe:
            return (5, 7)
        case .ski:
            return (5, 8)
        case .wheelchair:
            return (5, 9)
        case .other:
            return (0, 0)
        }
    }

    var defaultSurfaceKind: RouteSurfaceKind? {
        switch self {
        case .ride:
            return .paved
        case .mountainBike, .trailRun, .hike, .snowshoe:
            return .trail
        case .gravelRide, .mixedRide, .cyclocross:
            return .mixed
        default:
            return nil
        }
    }
}

private extension String {
    var normalizedActivityToken: String {
        trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
}

private func xmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
