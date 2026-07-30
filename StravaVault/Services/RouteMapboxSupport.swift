import CoreLocation
import Foundation
import MapKit
import MapboxMaps
import UIKit

enum RouteVaultMapboxConfiguration {
    private static let plistKeys = [
        "RouteVaultMapboxPublicToken",
        "MBXAccessToken"
    ]

    static var publicToken: String {
        for key in plistKeys {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return trimmed
            }
        }

        return ""
    }

    static func configure() {
        let token = publicToken
        guard !token.isEmpty else {
            return
        }

        if MapboxOptions.accessToken != token {
            MapboxOptions.accessToken = token
        }

        if MapboxMapsOptions.tileStore == nil {
            MapboxMapsOptions.tileStore = .default
        }
    }
}

struct RouteOfflineMapMetadata: Codable {
    struct CoverageBounds: Codable, Equatable {
        let minimumLatitude: Double
        let maximumLatitude: Double
        let minimumLongitude: Double
        let maximumLongitude: Double

        init(
            minimumLatitude: Double,
            maximumLatitude: Double,
            minimumLongitude: Double,
            maximumLongitude: Double
        ) {
            self.minimumLatitude = minimumLatitude
            self.maximumLatitude = maximumLatitude
            self.minimumLongitude = minimumLongitude
            self.maximumLongitude = maximumLongitude
        }

        init(region: MKCoordinateRegion) {
            let halfLatitudeDelta = region.span.latitudeDelta / 2
            let halfLongitudeDelta = region.span.longitudeDelta / 2
            self.init(
                minimumLatitude: region.center.latitude - halfLatitudeDelta,
                maximumLatitude: region.center.latitude + halfLatitudeDelta,
                minimumLongitude: region.center.longitude - halfLongitudeDelta,
                maximumLongitude: region.center.longitude + halfLongitudeDelta
            )
        }

        var areaEstimate: Double {
            max(maximumLatitude - minimumLatitude, 0) * max(maximumLongitude - minimumLongitude, 0)
        }

        func contains(_ other: CoverageBounds, paddingDegrees: Double = 0.0005) -> Bool {
            minimumLatitude <= (other.minimumLatitude + paddingDegrees) &&
                maximumLatitude >= (other.maximumLatitude - paddingDegrees) &&
                minimumLongitude <= (other.minimumLongitude + paddingDegrees) &&
                maximumLongitude >= (other.maximumLongitude - paddingDegrees)
        }
    }

    let tileRegionID: String
    let styleRawValue: String
    let downloadedAt: Date
    let approximateByteCount: Int64?
    let styleURIStrings: [String]
    let includesTerrainDEM: Bool
    let geometryKind: String
    let coverageBounds: CoverageBounds?
    let metadataVersion: Int

    init(
        tileRegionID: String,
        styleRawValue: String,
        downloadedAt: Date,
        approximateByteCount: Int64?,
        styleURIStrings: [String] = [],
        includesTerrainDEM: Bool = false,
        geometryKind: String = "unknown",
        coverageBounds: CoverageBounds? = nil,
        metadataVersion: Int = 4
    ) {
        self.tileRegionID = tileRegionID
        self.styleRawValue = styleRawValue
        self.downloadedAt = downloadedAt
        self.approximateByteCount = approximateByteCount
        self.styleURIStrings = styleURIStrings
        self.includesTerrainDEM = includesTerrainDEM
        self.geometryKind = geometryKind
        self.coverageBounds = coverageBounds
        self.metadataVersion = metadataVersion
    }

    private enum CodingKeys: String, CodingKey {
        case tileRegionID
        case styleRawValue
        case downloadedAt
        case approximateByteCount
        case styleURIStrings
        case includesTerrainDEM
        case geometryKind
        case coverageBounds
        case metadataVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tileRegionID = try container.decode(String.self, forKey: .tileRegionID)
        styleRawValue = try container.decode(String.self, forKey: .styleRawValue)
        downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
        approximateByteCount = try container.decodeIfPresent(Int64.self, forKey: .approximateByteCount)
        styleURIStrings = try container.decodeIfPresent([String].self, forKey: .styleURIStrings) ?? []
        includesTerrainDEM = try container.decodeIfPresent(Bool.self, forKey: .includesTerrainDEM) ?? false
        geometryKind = try container.decodeIfPresent(String.self, forKey: .geometryKind) ?? "unknown"
        coverageBounds = try container.decodeIfPresent(CoverageBounds.self, forKey: .coverageBounds)
        metadataVersion = try container.decodeIfPresent(Int.self, forKey: .metadataVersion) ?? 1
    }
}

enum RouteMapLineStyle {
    static let outlineColor = UIColor.white.withAlphaComponent(0.98)
    static let fillColor = UIColor(red: 1.0, green: 0.64, blue: 0.18, alpha: 1.0)
    static let outlineWidth: CGFloat = 5.4
    static let fillWidth: CGFloat = 3.35
    static let unpavedDashPattern: [Double] = [2.2, 1.6]
}

struct RouteDirectionArrowPlacement: Sendable {
    let coordinate: CLLocationCoordinate2D
    let bearing: CLLocationDirection
}

enum RouteDirectionArrowEmphasis {
    case standard
    case tracking
}

enum RouteDirectionArrowStyle {
    static func glyphAccentColor(for emphasis: RouteDirectionArrowEmphasis) -> UIColor {
        switch emphasis {
        case .standard:
            return RouteMapLineStyle.fillColor.withAlphaComponent(0.98)
        case .tracking:
            return UIColor(red: 1.0, green: 0.72, blue: 0.26, alpha: 1.0)
        }
    }

    static func shadowColor(for emphasis: RouteDirectionArrowEmphasis) -> UIColor {
        switch emphasis {
        case .standard:
            return UIColor.black.withAlphaComponent(0.48)
        case .tracking:
            return UIColor.black.withAlphaComponent(0.58)
        }
    }

    static func minimumRouteDistanceMeters(for emphasis: RouteDirectionArrowEmphasis) -> CLLocationDistance {
        switch emphasis {
        case .standard:
            return 220
        case .tracking:
            return 140
        }
    }

    static func preferredSpacingMeters(for emphasis: RouteDirectionArrowEmphasis) -> CLLocationDistance {
        switch emphasis {
        case .standard:
            return 700
        case .tracking:
            return 500
        }
    }

    static func minimumSpacingMeters(for emphasis: RouteDirectionArrowEmphasis) -> CLLocationDistance {
        switch emphasis {
        case .standard:
            return 210
        case .tracking:
            return 150
        }
    }

    static func minimumEdgeInsetMeters(for emphasis: RouteDirectionArrowEmphasis) -> CLLocationDistance {
        switch emphasis {
        case .standard:
            return 84
        case .tracking:
            return 60
        }
    }

    static func maximumArrowCount(for emphasis: RouteDirectionArrowEmphasis) -> Int {
        switch emphasis {
        case .standard:
            return 10
        case .tracking:
            return 14
        }
    }

    static func imageSize(for emphasis: RouteDirectionArrowEmphasis) -> CGSize {
        switch emphasis {
        case .standard:
            return CGSize(width: 14, height: 14)
        case .tracking:
            return CGSize(width: 18, height: 18)
        }
    }

    static func targetVisibleArrowCount(
        for zoomLevel: CGFloat,
        emphasis: RouteDirectionArrowEmphasis
    ) -> Int {
        switch emphasis {
        case .standard:
            switch zoomLevel {
            case ..<7.2:
                return 1
            case ..<9.2:
                return 2
            default:
                return 3
            }
        case .tracking:
            switch zoomLevel {
            case ..<9.4:
                return 2
            default:
                return 3
            }
        }
    }

    static func viewportSamplingSpacingMeters(
        for zoomLevel: CGFloat,
        emphasis: RouteDirectionArrowEmphasis
    ) -> CLLocationDistance {
        switch emphasis {
        case .standard:
            switch zoomLevel {
            case ..<7.2:
                return 460
            case ..<9.2:
                return 320
            case ..<11.0:
                return 220
            default:
                return 150
            }
        case .tracking:
            switch zoomLevel {
            case ..<9.4:
                return 260
            case ..<11.0:
                return 180
            default:
                return 120
            }
        }
    }

    static func viewportPaddingFraction(for emphasis: RouteDirectionArrowEmphasis) -> Double {
        switch emphasis {
        case .standard:
            return 0.08
        case .tracking:
            return 0.12
        }
    }
}

enum RouteDirectionArrowRenderer {
    static func placements(
        for coordinates: [CLLocationCoordinate2D],
        emphasis: RouteDirectionArrowEmphasis = .standard
    ) -> [RouteDirectionArrowPlacement] {
        placements(
            for: coordinates,
            minimumRouteDistance: RouteDirectionArrowStyle.minimumRouteDistanceMeters(for: emphasis),
            preferredSpacing: RouteDirectionArrowStyle.preferredSpacingMeters(for: emphasis),
            minimumSpacing: RouteDirectionArrowStyle.minimumSpacingMeters(for: emphasis),
            minimumEdgeInset: RouteDirectionArrowStyle.minimumEdgeInsetMeters(for: emphasis),
            maximumArrowCount: RouteDirectionArrowStyle.maximumArrowCount(for: emphasis)
        )
    }

    private static func placements(
        for coordinates: [CLLocationCoordinate2D],
        minimumRouteDistance: CLLocationDistance,
        preferredSpacing: CLLocationDistance,
        minimumSpacing: CLLocationDistance,
        minimumEdgeInset: CLLocationDistance,
        maximumArrowCount: Int
    ) -> [RouteDirectionArrowPlacement] {
        guard coordinates.count > 1 else {
            return []
        }

        let segmentDistances = zip(coordinates, coordinates.dropFirst()).map { start, end in
            CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        let totalDistance = segmentDistances.reduce(0, +)
        guard totalDistance >= minimumRouteDistance else {
            return []
        }

        let edgeInset = min(
            max(minimumEdgeInset, totalDistance * 0.08),
            totalDistance * 0.22
        )
        let usableDistance = totalDistance - (edgeInset * 2)
        guard usableDistance >= minimumSpacing else {
            return []
        }

        let rawArrowCount = Int((usableDistance / preferredSpacing).rounded())
        let arrowCount = max(1, min(maximumArrowCount, rawArrowCount))
        let spacing = usableDistance / Double(arrowCount + 1)
        guard spacing >= minimumSpacing * 0.8 else {
            return []
        }

        var placements: [RouteDirectionArrowPlacement] = []
        var cumulativeDistance: CLLocationDistance = 0
        var targetDistance = edgeInset + spacing

        for (index, segmentDistance) in segmentDistances.enumerated() {
            guard segmentDistance > 0.5 else {
                cumulativeDistance += segmentDistance
                continue
            }

            let segmentStart = coordinates[index]
            let segmentEnd = coordinates[index + 1]
            let segmentBearing = bearing(from: segmentStart, to: segmentEnd)

            while targetDistance < cumulativeDistance + segmentDistance,
                  placements.count < arrowCount {
                let progress = (targetDistance - cumulativeDistance) / segmentDistance
                placements.append(
                    RouteDirectionArrowPlacement(
                        coordinate: interpolatedCoordinate(
                            from: segmentStart,
                            to: segmentEnd,
                            progress: progress
                        ),
                        bearing: segmentBearing
                    )
                )
                targetDistance += spacing
            }

            cumulativeDistance += segmentDistance
        }

        return placements
    }

    static func annotations(
        for coordinates: [CLLocationCoordinate2D],
        imageNamePrefix: String,
        zoomLevel: CGFloat? = nil,
        visibleBounds: CoordinateBounds? = nil,
        emphasis: RouteDirectionArrowEmphasis = .standard
    ) -> [PointAnnotation] {
        let selectedPlacements: [RouteDirectionArrowPlacement]
        if let zoomLevel, let visibleBounds {
            let denseSpacing = RouteDirectionArrowStyle.viewportSamplingSpacingMeters(
                for: zoomLevel,
                emphasis: emphasis
            )
            let densePlacements = placements(
                for: coordinates,
                minimumRouteDistance: 0,
                preferredSpacing: denseSpacing,
                minimumSpacing: max(60, denseSpacing * 0.45),
                minimumEdgeInset: min(RouteDirectionArrowStyle.minimumEdgeInsetMeters(for: emphasis), denseSpacing * 0.4),
                maximumArrowCount: 64
            )
            let visiblePlacements = densePlacements.filter {
                coordinate(
                    $0.coordinate,
                    isWithin: visibleBounds,
                    paddingFraction: RouteDirectionArrowStyle.viewportPaddingFraction(for: emphasis)
                )
            }
            selectedPlacements = sampledPlacements(
                from: visiblePlacements,
                targetCount: RouteDirectionArrowStyle.targetVisibleArrowCount(
                    for: zoomLevel,
                    emphasis: emphasis
                )
            )
        } else {
            selectedPlacements = placements(for: coordinates, emphasis: emphasis)
        }

        return selectedPlacements.enumerated().map { index, placement in
            var annotation = PointAnnotation(coordinate: placement.coordinate)
            annotation.iconAnchor = .center
            annotation.image = .init(
                image: arrowImage(for: placement.bearing, emphasis: emphasis),
                name: "\(imageNamePrefix)-\(emphasis)-\(index)-\(Int(placement.bearing.rounded()))"
            )
            if let zoomLevel {
                annotation.iconSize = zoomScaledIconSize(for: zoomLevel, emphasis: emphasis)
            }
            return annotation
        }
    }

    private static func sampledPlacements(
        from placements: [RouteDirectionArrowPlacement],
        targetCount: Int
    ) -> [RouteDirectionArrowPlacement] {
        guard placements.count > targetCount, targetCount > 0 else {
            return placements
        }

        var sampled: [RouteDirectionArrowPlacement] = []
        var usedIndices = Set<Int>()
        let denominator = Double(targetCount + 1)
        let maxIndex = placements.count - 1

        for position in 0..<targetCount {
            let rawIndex = ((Double(position + 1) * Double(placements.count + 1)) / denominator) - 1
            let index = min(max(Int(rawIndex.rounded()), 0), maxIndex)
            if usedIndices.insert(index).inserted {
                sampled.append(placements[index])
            }
        }

        if sampled.count == targetCount {
            return sampled
        }

        for (index, placement) in placements.enumerated() where !usedIndices.contains(index) {
            sampled.append(placement)
            if sampled.count == targetCount {
                break
            }
        }

        return sampled
    }

    private static func coordinate(
        _ coordinate: CLLocationCoordinate2D,
        isWithin bounds: CoordinateBounds,
        paddingFraction: Double
    ) -> Bool {
        let south = min(bounds.southwest.latitude, bounds.northeast.latitude)
        let north = max(bounds.southwest.latitude, bounds.northeast.latitude)
        let latitudePadding = max(0.0006, (north - south) * paddingFraction)
        guard coordinate.latitude >= south - latitudePadding,
              coordinate.latitude <= north + latitudePadding else {
            return false
        }

        let west = bounds.southwest.longitude
        let east = bounds.northeast.longitude
        let longitudePadding = max(0.0006, longitudeSpan(from: west, to: east) * paddingFraction)

        if west <= east {
            return coordinate.longitude >= west - longitudePadding &&
                coordinate.longitude <= east + longitudePadding
        }

        return coordinate.longitude >= west - longitudePadding ||
            coordinate.longitude <= east + longitudePadding
    }

    private static func longitudeSpan(
        from west: CLLocationDegrees,
        to east: CLLocationDegrees
    ) -> CLLocationDegrees {
        if west <= east {
            return east - west
        }

        return (180 - west) + (east + 180)
    }

    private static func zoomScaledIconSize(
        for zoomLevel: CGFloat,
        emphasis: RouteDirectionArrowEmphasis
    ) -> Double {
        switch zoomLevel {
        case ..<7.2:
            return emphasis == .tracking ? 0.78 : 0.64
        case ..<9.0:
            return emphasis == .tracking ? 0.88 : 0.76
        case ..<10.5:
            return emphasis == .tracking ? 0.98 : 0.88
        case ..<12.0:
            return emphasis == .tracking ? 1.06 : 0.98
        case ..<13.5:
            return emphasis == .tracking ? 1.14 : 1.06
        default:
            return emphasis == .tracking ? 1.22 : 1.14
        }
    }

    private static func interpolatedCoordinate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        progress: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + ((end.latitude - start.latitude) * progress),
            longitude: start.longitude + ((end.longitude - start.longitude) * progress)
        )
    }

    private static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let startLatitude = start.latitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(endLatitude)
        let x = (cos(startLatitude) * sin(endLatitude))
            - (sin(startLatitude) * cos(endLatitude) * cos(deltaLongitude))
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private static func arrowImage(
        for bearing: CLLocationDirection,
        emphasis: RouteDirectionArrowEmphasis
    ) -> UIImage {
        let imageSize = RouteDirectionArrowStyle.imageSize(for: emphasis)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: imageSize)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let scale = imageSize.width / 18

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }

            context.cgContext.translateBy(x: center.x, y: center.y)
            context.cgContext.rotate(by: bearing * .pi / 180)
            context.cgContext.translateBy(x: -center.x, y: -center.y)

            let chevronPath = UIBezierPath()
            chevronPath.move(to: point(3.9, 12.1))
            chevronPath.addLine(to: point(9.0, 5.7))
            chevronPath.addLine(to: point(14.1, 12.1))
            chevronPath.lineCapStyle = .round
            chevronPath.lineJoinStyle = .round

            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 0.8 * scale),
                blur: emphasis == .tracking ? 1.55 * scale : 1.0 * scale,
                color: RouteDirectionArrowStyle.shadowColor(for: emphasis).cgColor
            )
            UIColor.white.withAlphaComponent(emphasis == .tracking ? 0.98 : 0.92).setStroke()
            chevronPath.lineWidth = emphasis == .tracking ? 4.0 * scale : 3.15 * scale
            chevronPath.stroke()

            RouteDirectionArrowStyle.glyphAccentColor(for: emphasis).setStroke()
            chevronPath.lineWidth = emphasis == .tracking ? 2.2 * scale : 1.7 * scale
            chevronPath.stroke()
        }
    }
}

enum RouteMapStyleReadabilityTuning {
    private static let trailLabelLayerIDs: Set<String> = [
        "path-pedestrian-label"
    ]

    private static let trailLineLayerIDs: Set<String> = [
        "tunnel-path-case",
        "tunnel-pedestrian-case",
        "tunnel-path-trail",
        "tunnel-path",
        "tunnel-pedestrian",
        "tunnel-path-cycleway-piste",
        "road-path-bg",
        "road-path-case",
        "road-pedestrian-case",
        "road-path-trail",
        "road-path",
        "road-pedestrian",
        "road-path-cycleway-piste",
        "bridge-path-case",
        "bridge-pedestrian-case",
        "bridge-path-trail",
        "bridge-path",
        "bridge-pedestrian",
        "bridge-path-cycleway-piste"
    ]

    static func apply(to mapboxMap: MapboxMap, usesStandardDarkStyle: Bool = false) {
        for layer in mapboxMap.allLayerIdentifiers {
            let layerID = layer.id.lowercased()

            switch layer.type {
            case .symbol where shouldTuneTrailLabels(layerID):
                applyTrailLabelTuning(
                    to: mapboxMap,
                    layerID: layer.id,
                    usesStandardDarkStyle: usesStandardDarkStyle
                )
            case .line where shouldTuneTrailLines(layerID):
                applyTrailLineTuning(
                    to: mapboxMap,
                    layerID: layer.id,
                    usesStandardDarkStyle: usesStandardDarkStyle
                )
            default:
                break
            }
        }
    }

    private static func shouldTuneTrailLabels(_ layerID: String) -> Bool {
        trailLabelLayerIDs.contains(layerID)
    }

    private static func shouldTuneTrailLines(_ layerID: String) -> Bool {
        trailLineLayerIDs.contains(layerID)
    }

    private static func applyTrailLabelTuning(
        to mapboxMap: MapboxMap,
        layerID: String,
        usesStandardDarkStyle: Bool
    ) {
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "text-size",
            value: [
                "interpolate",
                ["linear"],
                ["zoom"],
                10, 9.5,
                12, 11,
                15, 13.5,
                18, 16.5
            ]
        )
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "text-halo-width",
            value: [
                "interpolate",
                ["linear"],
                ["zoom"],
                10, 1.2,
                15, 1.6,
                18, 2.0
            ]
        )
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "text-halo-blur",
            value: 0.6
        )

        guard usesStandardDarkStyle else {
            return
        }

        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "text-color",
            value: "#FFF8EC"
        )
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "text-halo-color",
            value: "#0C0A07"
        )
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "text-emissive-strength",
            value: 1.15
        )
    }

    private static func applyTrailLineTuning(
        to mapboxMap: MapboxMap,
        layerID: String,
        usesStandardDarkStyle: Bool
    ) {
        let normalizedLayerID = layerID.lowercased()
        let widthStops: [Any]

        if normalizedLayerID.contains("bg") || normalizedLayerID.contains("case") {
            widthStops = [
                "interpolate",
                ["exponential", 1.4],
                ["zoom"],
                12, 1.6,
                14, 2.4,
                15, 3.0,
                18, 8.6
            ]
        } else if normalizedLayerID.contains("trail") {
            widthStops = [
                "interpolate",
                ["exponential", 1.35],
                ["zoom"],
                12, 0.9,
                14, 1.4,
                15, 1.8,
                18, 5.1
            ]
        } else {
            widthStops = [
                "interpolate",
                ["exponential", 1.35],
                ["zoom"],
                12, 0.8,
                14, 1.25,
                15, 1.55,
                18, 4.7
            ]
        }

        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "line-width",
            value: widthStops
        )
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "line-opacity",
            value: 1.0
        )

        guard usesStandardDarkStyle else {
            return
        }

        let brightLineColor: String
        if normalizedLayerID.contains("bg") || normalizedLayerID.contains("case") {
            brightLineColor = "#E9DCC7"
        } else {
            brightLineColor = "#FFF8E8"
        }

        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "line-color",
            value: brightLineColor
        )
        setLayerPropertyIfPossible(
            on: mapboxMap,
            layerID: layerID,
            property: "line-emissive-strength",
            value: 1.05
        )
    }

    private static func setLayerPropertyIfPossible(
        on mapboxMap: MapboxMap,
        layerID: String,
        property: String,
        value: Any
    ) {
        guard mapboxMap.layerExists(withId: layerID) else {
            return
        }

        do {
            try mapboxMap.setLayerProperty(for: layerID, property: property, value: value)
        } catch {
            return
        }
    }
}

enum RouteMapTerrainTuning {
    private static let terrainSourceID = "terigo-online-terrain-dem"
    private static let terrainSourceURL = "mapbox://mapbox.mapbox-terrain-dem-v1"
    private static let terrainExaggeration = 1.18

    static var offlineTilesetURI: String {
        terrainSourceURL
    }

    static func apply(
        to mapboxMap: MapboxMap,
        perspective: AppRouteMapPerspective
    ) {
        guard perspective.isThreeDimensional else {
            mapboxMap.removeTerrain()
            return
        }

        if !mapboxMap.sourceExists(withId: terrainSourceID) {
            var demSource = RasterDemSource(id: terrainSourceID)
            demSource.url = terrainSourceURL
            demSource.tileSize = 514
            demSource.maxzoom = 14

            do {
                try mapboxMap.addSource(demSource)
            } catch {
                return
            }
        }

        do {
            try mapboxMap.setTerrain(
                Terrain(sourceId: terrainSourceID)
                    .exaggeration(terrainExaggeration)
            )
        } catch { }
    }
}

extension RouteRecord {
    var prefersOutdoorsMapStyle: Bool {
        switch sportKind {
        case .trailRun, .hike, .snowshoe, .ski:
            return true
        case .run, .walk:
            return surfaceKind == .trail
        default:
            return surfaceKind == .trail
        }
    }
}

extension ActivityRecord {
    var prefersOutdoorsMapStyle: Bool {
        switch sportKind {
        case .trailRun, .hike, .snowshoe, .ski, .mountainBike, .gravelRide, .cyclocross:
            return true
        case .run, .walk, .ride, .mixedRide, .wheelchair, .other:
            return false
        }
    }
}

extension AppRouteMapStyle {
    func resolvedStyle(for route: RouteRecord? = nil, colorScheme: UIUserInterfaceStyle = .unspecified) -> MapStyle {
        switch self {
        case .outdoors:
            return .outdoors
        case .standard:
            return .standard(lightPreset: .day)
        case .dark:
            return .standard(lightPreset: .dusk)
        case .hybrid:
            return .satelliteStreets
        case .satellite:
            return .satelliteStreets
        }
    }

    func resolvedStyleURI(for route: RouteRecord? = nil) -> StyleURI {
        switch self {
        case .outdoors:
            return .outdoors
        case .standard, .dark:
            return .standard
        case .hybrid:
            return .satelliteStreets
        case .satellite:
            return .satellite
        }
    }

    var offlineDescriptorStyleURIs: [StyleURI] {
        [.standard, .outdoors, .satelliteStreets, .satellite]
    }

    func usesStandardDarkReadabilityTuning(
        for route: RouteRecord? = nil,
        colorScheme: UIUserInterfaceStyle = .unspecified
    ) -> Bool {
        self == .dark
    }
}

enum RouteMapboxGeometry {
    static func coordinateBounds(
        for coordinates: [CLLocationCoordinate2D],
        minimumMeters: CLLocationDistance = 1_200,
        paddingFactor: Double = 0.18
    ) -> CoordinateBounds? {
        guard !coordinates.isEmpty else {
            return nil
        }

        var minLatitude = coordinates[0].latitude
        var maxLatitude = coordinates[0].latitude
        var minLongitude = coordinates[0].longitude
        var maxLongitude = coordinates[0].longitude

        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }

        let centerLatitude = (minLatitude + maxLatitude) / 2
        let centerLongitude = (minLongitude + maxLongitude) / 2
        let latitudeMeters = max((maxLatitude - minLatitude) * 111_000, minimumMeters)
        let longitudeMeters = max((maxLongitude - minLongitude) * longitudeMetersPerDegree(at: centerLatitude), minimumMeters)
        let paddedLatitudeMeters = latitudeMeters * (1 + paddingFactor)
        let paddedLongitudeMeters = longitudeMeters * (1 + paddingFactor)
        let latitudeDelta = degreesLatitude(for: paddedLatitudeMeters / 2)
        let longitudeDelta = degreesLongitude(for: paddedLongitudeMeters / 2, at: centerLatitude)

        return CoordinateBounds(
            southwest: CLLocationCoordinate2D(latitude: centerLatitude - latitudeDelta, longitude: centerLongitude - longitudeDelta),
            northeast: CLLocationCoordinate2D(latitude: centerLatitude + latitudeDelta, longitude: centerLongitude + longitudeDelta)
        )
    }

    static func coordinateRegion(
        for coordinates: [CLLocationCoordinate2D],
        minimumMeters: CLLocationDistance = 1_200,
        paddingFactor: Double = 0.18
    ) -> MKCoordinateRegion? {
        guard let bounds = coordinateBounds(for: coordinates, minimumMeters: minimumMeters, paddingFactor: paddingFactor) else {
            return nil
        }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
                longitude: (bounds.southwest.longitude + bounds.northeast.longitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(bounds.northeast.latitude - bounds.southwest.latitude, 0.01),
                longitudeDelta: max(bounds.northeast.longitude - bounds.southwest.longitude, 0.01)
            )
        )
    }

    static func coordinateBounds(for region: MKCoordinateRegion) -> CoordinateBounds {
        CoordinateBounds(
            southwest: CLLocationCoordinate2D(
                latitude: region.center.latitude - (region.span.latitudeDelta / 2),
                longitude: region.center.longitude - (region.span.longitudeDelta / 2)
            ),
            northeast: CLLocationCoordinate2D(
                latitude: region.center.latitude + (region.span.latitudeDelta / 2),
                longitude: region.center.longitude + (region.span.longitudeDelta / 2)
            )
        )
    }

    static func coordinateRegion(for bounds: CoordinateBounds) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
                longitude: (bounds.southwest.longitude + bounds.northeast.longitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(bounds.northeast.latitude - bounds.southwest.latitude, 0.01),
                longitudeDelta: max(bounds.northeast.longitude - bounds.southwest.longitude, 0.01)
            )
        )
    }

    static func offlineGeometry(for route: RouteRecord) -> Geometry? {
        let coordinates = route.routeCoordinates
        guard !coordinates.isEmpty else {
            guard let startCoordinate = route.startCoordinate else {
                return nil
            }

            return .polygon(circlePolygon(center: startCoordinate, radiusMeters: 2_000))
        }

        return .lineString(LineString(simplifiedOfflineLineCoordinates(for: coordinates)))
    }

    static func offlineGeometryKind(for route: RouteRecord) -> String {
        route.routeCoordinates.isEmpty ? "circle" : "lineString"
    }

    static func circlePolygon(
        center: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        vertices: Int = 48
    ) -> Polygon {
        let ring = (0...vertices).map { index -> CLLocationCoordinate2D in
            let angle = (Double(index) / Double(vertices)) * Double.pi * 2
            let latitude = center.latitude + degreesLatitude(for: sin(angle) * radiusMeters)
            let longitude = center.longitude + degreesLongitude(for: cos(angle) * radiusMeters, at: center.latitude)
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        return Polygon([ring])
    }

    static func bufferedBoundingPolygon(
        for coordinates: [CLLocationCoordinate2D],
        bufferMeters: CLLocationDistance
    ) -> Polygon {
        guard let bounds = coordinateBounds(for: coordinates, minimumMeters: bufferMeters * 2, paddingFactor: 0.15) else {
            return Polygon([])
        }

        let southwest = CLLocationCoordinate2D(
            latitude: bounds.southwest.latitude - degreesLatitude(for: bufferMeters),
            longitude: bounds.southwest.longitude - degreesLongitude(for: bufferMeters, at: bounds.southwest.latitude)
        )
        let northeast = CLLocationCoordinate2D(
            latitude: bounds.northeast.latitude + degreesLatitude(for: bufferMeters),
            longitude: bounds.northeast.longitude + degreesLongitude(for: bufferMeters, at: bounds.northeast.latitude)
        )
        let southeast = CLLocationCoordinate2D(latitude: southwest.latitude, longitude: northeast.longitude)
        let northwest = CLLocationCoordinate2D(latitude: northeast.latitude, longitude: southwest.longitude)

        return Polygon([[southwest, southeast, northeast, northwest, southwest]])
    }

    static func simplifiedOfflineLineCoordinates(
        for coordinates: [CLLocationCoordinate2D],
        maximumPointCount: Int = 240
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumPointCount, maximumPointCount > 2 else {
            return coordinates
        }

        let strideSize = Double(coordinates.count - 1) / Double(maximumPointCount - 1)
        var simplified: [CLLocationCoordinate2D] = []
        simplified.reserveCapacity(maximumPointCount)

        for index in 0..<(maximumPointCount - 1) {
            let sourceIndex = min(Int((Double(index) * strideSize).rounded(.toNearestOrAwayFromZero)), coordinates.count - 1)
            simplified.append(coordinates[sourceIndex])
        }

        if let lastCoordinate = coordinates.last {
            simplified.append(lastCoordinate)
        }

        return simplified
    }

    static func longitudeMetersPerDegree(at latitude: CLLocationDegrees) -> CLLocationDistance {
        max(cos(latitude * .pi / 180), 0.2) * 111_000
    }

    static func degreesLatitude(for meters: CLLocationDistance) -> CLLocationDegrees {
        meters / 111_000
    }

    static func degreesLongitude(for meters: CLLocationDistance, at latitude: CLLocationDegrees) -> CLLocationDegrees {
        meters / longitudeMetersPerDegree(at: latitude)
    }
}
