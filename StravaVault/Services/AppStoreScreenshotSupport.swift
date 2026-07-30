import CoreLocation
import Foundation
import MapKit
import UserNotifications

enum AppStoreScreenshotShot: String {
    case routeLibrary = "route-library"
    case mapBrowseSanFrancisco = "map-browse-san-francisco"
    case sortOrder = "sort-order"
    case routeFullScreenMap = "route-full-screen-map"
    case routeDetailsWeather = "route-details-weather"
    case liveTracking = "live-tracking"
}

struct AppStoreTrackingPreviewState {
    let phase: RouteTrackingPhase
    let trackingMode: RouteTrackingLocationMode
    let currentLocation: CLLocation
    let progress: RouteTrackingProgress
    let traversedRouteCoordinates: [CLLocationCoordinate2D]
    let breadcrumbCoordinates: [CLLocationCoordinate2D]
    let recordedDistanceMeters: Double
    let elapsedTime: TimeInterval
    let instantaneousSpeedMetersPerSecond: Double?
    let averageSpeedMetersPerSecond: Double?
    let lastUpdatedAt: Date
    let notificationAuthorizationStatus: UNAuthorizationStatus
}

enum AppStoreScreenshotSupport {
    private static let shotFlagPrefix = "--app-store-shot="
    private static let preferredFiftyKDistanceMeters = 50_000.0
    private static let preferredFiftyKToleranceMeters = 5_500.0
    private static let preferredShowcaseRadiusMeters = 120_000.0
    private static let routeKeywordWeights: [(String, Int)] = [
        ("presidio", 60),
        ("marin", 55),
        ("sausalito", 50),
        ("tam", 46),
        ("muir", 42),
        ("sutro", 38),
        ("san francisco", 34),
        ("sf", 28)
    ]
    private static let retiredShowcaseRouteNameTokens = [
        "rani gravel option"
    ]
    private static let sanFranciscoReference = CLLocation(latitude: 37.7909, longitude: -122.4339)

    static var requestedShot: AppStoreScreenshotShot? {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix(shotFlagPrefix) else {
                continue
            }

            let rawValue = String(argument.dropFirst(shotFlagPrefix.count))
            return AppStoreScreenshotShot(rawValue: rawValue)
        }

        return nil
    }

    static var isEnabled: Bool {
        requestedShot != nil
    }

    static var shouldHideLibraryBanners: Bool {
        isEnabled
    }

    static var sanFranciscoBrowseRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.8065, longitude: -122.4525),
            span: MKCoordinateSpan(latitudeDelta: 0.34, longitudeDelta: 0.36)
        )
    }

    static var previewSortCriteria: [RouteSortCriterion] {
        [
            RouteSortCriterion(option: .updatedAt, direction: .descending),
            RouteSortCriterion(option: .distance, direction: .descending),
            RouteSortCriterion(option: .climb, direction: .descending),
            RouteSortCriterion(option: .gradient, direction: .descending),
            RouteSortCriterion(option: .estimatedTime, direction: .descending),
            RouteSortCriterion(option: .name, direction: .ascending)
        ]
    }

    static func screenshotEligibleRoutes(from routes: [RouteRecord]) -> [RouteRecord] {
        guard isEnabled else {
            return routes
        }

        let syncedRoutes = routes.filter { !$0.isImportedFromGPX }
        let filteredSyncedRoutes = syncedRoutes.filter { route in
            let normalizedName = route.name
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return !retiredShowcaseRouteNameTokens.contains { normalizedName.contains($0) }
        }

        if !filteredSyncedRoutes.isEmpty {
            return filteredSyncedRoutes
        }

        return syncedRoutes.isEmpty ? routes : syncedRoutes
    }

    static func preferredShowcaseRoute(in routes: [RouteRecord]) -> RouteRecord? {
        let validRoutes = screenshotEligibleRoutes(from: routes).filter { !$0.routeCoordinates.isEmpty }
        guard !validRoutes.isEmpty else {
            return nil
        }

        if let requestedShot,
           [.routeFullScreenMap, .routeDetailsWeather, .liveTracking].contains(requestedShot),
           let preferredFiftyKRoute = preferredFiftyKRoute(in: validRoutes) {
            return preferredFiftyKRoute
        }

        return validRoutes.max { lhs, rhs in
            showcaseScore(for: lhs) < showcaseScore(for: rhs)
        }
    }

    static func trackingPreview(for route: RouteRecord) -> AppStoreTrackingPreviewState? {
        guard requestedShot == .liveTracking else {
            return nil
        }

        let coordinates = route.routeCoordinates
        guard coordinates.count > 4 else {
            return nil
        }

        let progressFraction = 0.38
        let progressIndex = min(
            max(Int(Double(coordinates.count - 1) * progressFraction), 1),
            coordinates.count - 2
        )
        let currentCoordinate = coordinates[progressIndex]
        let nextCoordinate = coordinates[progressIndex + 1]
        let traversedCoordinates = Array(coordinates.prefix(progressIndex + 1))
        let completedDistanceMeters = max(0, route.distanceMeters * progressFraction)
        let remainingDistanceMeters = max(0, route.distanceMeters - completedDistanceMeters)
        let averageSpeed = route.estimatedMovingTime > 0
            ? route.distanceMeters / route.estimatedMovingTime
            : max(2.8, route.distanceMeters / 3_600)
        let instantaneousSpeed = averageSpeed * 1.06
        let currentLocation = CLLocation(
            coordinate: currentCoordinate,
            altitude: 0,
            horizontalAccuracy: 6,
            verticalAccuracy: 8,
            course: course(from: currentCoordinate, to: nextCoordinate),
            speed: instantaneousSpeed,
            timestamp: .now
        )
        let progress = RouteTrackingProgress(
            userCoordinate: currentCoordinate,
            snappedCoordinate: currentCoordinate,
            currentProgressDistanceMeters: completedDistanceMeters,
            completedProgressDistanceMeters: completedDistanceMeters,
            remainingDistanceMeters: remainingDistanceMeters,
            fractionCompleted: progressFraction,
            distanceToRouteMeters: 0,
            offRouteThresholdMeters: 45,
            distanceToEndMeters: remainingDistanceMeters,
            estimatedRemainingTime: route.estimatedMovingTime > 0
                ? route.estimatedMovingTime * (1 - progressFraction)
                : nil,
            traversedRouteCoordinates: traversedCoordinates
        )

        return AppStoreTrackingPreviewState(
            phase: .tracking,
            trackingMode: .reopenOnly,
            currentLocation: currentLocation,
            progress: progress,
            traversedRouteCoordinates: traversedCoordinates,
            breadcrumbCoordinates: traversedCoordinates,
            recordedDistanceMeters: completedDistanceMeters,
            elapsedTime: completedDistanceMeters / max(averageSpeed, 0.1),
            instantaneousSpeedMetersPerSecond: instantaneousSpeed,
            averageSpeedMetersPerSecond: averageSpeed,
            lastUpdatedAt: .now,
            notificationAuthorizationStatus: .authorized
        )
    }

    static func previewElevationProfile(for route: RouteRecord) -> [RouteElevationSample] {
        guard let requestedShot,
              [.liveTracking, .routeFullScreenMap].contains(requestedShot),
              route.elevationProfile.count <= 1 else {
            return []
        }

        let coordinates = route.routeCoordinates
        guard coordinates.count > 1 else {
            return []
        }

        let totalDistanceMeters = max(route.distanceMeters, 1)
        let totalGainMeters = max(route.elevationGainMeters, 600)
        let baseAltitudeMeters = 110.0

        let segmentDistances = zip(coordinates, coordinates.dropFirst()).map { start, end in
            CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        let cumulativeDistances = segmentDistances.reduce(into: [0.0]) { partialResult, distance in
            partialResult.append(partialResult.last! + distance)
        }
        let scale = totalDistanceMeters / max(cumulativeDistances.last ?? totalDistanceMeters, 1)

        return zip(coordinates.indices, coordinates).map { index, coordinate in
            let normalizedDistance = min(totalDistanceMeters, cumulativeDistances[index] * scale)
            let progress = normalizedDistance / totalDistanceMeters
            let majorRoll = sin(progress * .pi * 1.15)
            let smallRoll = sin((progress * .pi * 5.4) + 0.55)
            let climbEnvelope = progress < 0.74
                ? progress / 0.74
                : max(0, 1 - ((progress - 0.74) / 0.26) * 0.42)
            let altitudeMeters = baseAltitudeMeters +
                (climbEnvelope * totalGainMeters * 0.58) +
                (majorRoll * totalGainMeters * 0.14) +
                (smallRoll * totalGainMeters * 0.06)

            return RouteElevationSample(
                distanceMeters: normalizedDistance,
                elevationMeters: max(baseAltitudeMeters - 18, altitudeMeters),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    private static func preferredFiftyKRoute(in routes: [RouteRecord]) -> RouteRecord? {
        let eligibleRoutes = routes.filter { route in
            abs(route.distanceMeters - preferredFiftyKDistanceMeters) <= preferredFiftyKToleranceMeters &&
                distanceFromSanFranciscoReference(for: route) <= preferredShowcaseRadiusMeters
        }

        guard !eligibleRoutes.isEmpty else {
            return nil
        }

        return eligibleRoutes.max { lhs, rhs in
            if lhs.primaryTimestamp != rhs.primaryTimestamp {
                return lhs.primaryTimestamp < rhs.primaryTimestamp
            }

            let lhsDistanceDelta = abs(lhs.distanceMeters - preferredFiftyKDistanceMeters)
            let rhsDistanceDelta = abs(rhs.distanceMeters - preferredFiftyKDistanceMeters)
            if lhsDistanceDelta != rhsDistanceDelta {
                return lhsDistanceDelta > rhsDistanceDelta
            }

            let lhsReferenceDistance = distanceFromSanFranciscoReference(for: lhs)
            let rhsReferenceDistance = distanceFromSanFranciscoReference(for: rhs)
            if lhsReferenceDistance != rhsReferenceDistance {
                return lhsReferenceDistance > rhsReferenceDistance
            }

            return lhs.elevationGainMeters < rhs.elevationGainMeters
        }
    }

    private static func showcaseScore(for route: RouteRecord) -> Double {
        let normalizedName = route.name.routeLocationToken
        let keywordWeight = routeKeywordWeights.reduce(0) { partialResult, entry in
            normalizedName.contains(entry.0) ? partialResult + entry.1 : partialResult
        }

        let locationDistanceMeters = distanceFromSanFranciscoReference(for: route)

        let proximityScore = max(0, 120_000 - locationDistanceMeters) / 1_000
        let distanceScore = min(route.distanceMeters / 1_000, 80)
        let climbScore = min(route.elevationGainMeters / 100, 40)

        return Double(keywordWeight) * 1_000 + proximityScore + distanceScore + climbScore
    }

    private static func distanceFromSanFranciscoReference(for route: RouteRecord) -> Double {
        guard let startCoordinate = route.startCoordinate else {
            return 150_000
        }

        let routeLocation = CLLocation(latitude: startCoordinate.latitude, longitude: startCoordinate.longitude)
        return sanFranciscoReference.distance(from: routeLocation)
    }

    private static func course(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> CLLocationDirection {
        let deltaLongitude = (destination.longitude - origin.longitude) * .pi / 180
        let originLatitude = origin.latitude * .pi / 180
        let destinationLatitude = destination.latitude * .pi / 180

        let y = sin(deltaLongitude) * cos(destinationLatitude)
        let x = cos(originLatitude) * sin(destinationLatitude) -
            sin(originLatitude) * cos(destinationLatitude) * cos(deltaLongitude)
        let bearing = atan2(y, x) * 180 / .pi
        return bearing >= 0 ? bearing : bearing + 360
    }
}
