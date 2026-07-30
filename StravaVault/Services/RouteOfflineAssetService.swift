import CoreLocation
import Foundation
import MapKit
import MapboxMaps
import UIKit

struct RouteOfflineAssetFiles {
    let gpxRelativePath: String
    let mapSnapshotRelativePath: String?
    let downloadedAt: Date
    let approximateByteCount: Int64?
}

struct RouteOfflineDownloadSelection: Equatable {
    var includesGPX: Bool
    var mapStyles: [AppRouteMapStyle]
    var includesTerrain: Bool

    var normalizedMapStyles: [AppRouteMapStyle] {
        var seen = Set<String>()
        return mapStyles.filter { seen.insert($0.rawValue).inserted }
    }

    var primaryMapStyle: AppRouteMapStyle? {
        normalizedMapStyles.first
    }

    var hasDownloadableSelection: Bool {
        includesGPX || !normalizedMapStyles.isEmpty
    }
}

struct RouteOfflineDownloadProgress: Equatable {
    let message: String
    let fractionCompleted: Double?

    var percentageText: String? {
        guard let fractionCompleted else {
            return nil
        }

        let percentage = Int((max(0, min(1, fractionCompleted)) * 100).rounded())
        return "\(percentage)%"
    }

    var buttonLabel: String {
        guard let percentageText else {
            return message
        }

        return "Downloading… \(percentageText)"
    }
}

struct RouteOfflineAssetStatus: Equatable {
    let hasGPX: Bool
    let mapStyles: [AppRouteMapStyle]
    let includesTerrain: Bool
    let downloadedAt: Date?
    let totalBytes: Int64

    var hasConcreteAssets: Bool {
        hasGPX || !mapStyles.isEmpty || includesTerrain
    }

    var hasAnyAssets: Bool {
        hasConcreteAssets || downloadedAt != nil || totalBytes > 0
    }

    var componentLabels: [String] {
        var labels: [String] = []

        if hasGPX {
            labels.append("GPX")
        }

        labels.append(contentsOf: mapStyles.map { "\($0.title) Map" })

        if includesTerrain {
            labels.append("3D Terrain")
        }

        return labels
    }

    var summaryText: String {
        let labels = componentLabels
        guard !labels.isEmpty else {
            return hasAnyAssets ? "Saved files need refresh" : "Nothing saved offline"
        }

        return labels.joined(separator: " • ")
    }

    var shortBadgeText: String {
        let labels = componentLabels
        guard !labels.isEmpty else {
            return hasAnyAssets ? "Needs Refresh" : "Not Saved"
        }

        if labels.count == 1 {
            return labels[0]
        }

        return "\(labels.count) items saved"
    }
}

private enum RouteOfflineDownloadProgressScale {
    static let preparingGPX = 0.03
    static let importingRouteShape = 0.08
    static let gpxOnlyWrite = 0.74
    static let gpxWithMapWrite = 0.12
    static let stylePackStart = 0.16
    static let stylePackSpan = 0.14
    static let tileRegionStart = stylePackStart + stylePackSpan
    static let tileRegionSpan = 0.64
    static let reuseExistingMap = 0.94
    static let finalizing = 1.0
}

struct RouteOfflineAssetService {
    private static let previewImageCache = NSCache<NSString, UIImage>()
    private static let previewImageTaskLock = NSLock()
    private static var previewImageTasks: [String: Task<UIImage, Error>] = [:]

    private struct OfflineMetadataRecord {
        let url: URL
        let metadata: RouteOfflineMapMetadata
    }

    private struct OfflineMapMetadataResolution {
        let metadata: RouteOfflineMapMetadata
        let createdNewTileRegion: Bool
    }

    enum AssetError: LocalizedError {
        case missingRouteGeometry
        case invalidSnapshot
        case missingOfflineGeometry
        case missingOfflineMetadata
        case missingOfflineStylePack
        case missingOfflineTileRegion
        case incompleteOfflineTileRegion
        case offlineDownloadTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .missingRouteGeometry:
                return "This route does not have enough path data to build an offline file."
            case .invalidSnapshot:
                return "The map preview could not be generated."
            case .missingOfflineGeometry:
                return "This route does not have enough geometry to download an offline map area."
            case .missingOfflineMetadata:
                return "The saved offline map metadata could not be loaded."
            case .missingOfflineStylePack:
                return "The offline map style pack could not be verified after download."
            case .missingOfflineTileRegion:
                return "The offline map area could not be verified after download."
            case .incompleteOfflineTileRegion:
                return "The downloaded offline map bundle is incomplete and needs to be downloaded again."
            case let .offlineDownloadTimedOut(stage):
                return "The offline download timed out while \(stage.lowercased())."
            }
        }
    }

    private let fileManager: FileManager
    private let baseDirectoryOverride: URL?
    private let isoFormatter = ISO8601DateFormatter()
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(fileManager: FileManager = .default, baseDirectoryOverride: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryOverride = baseDirectoryOverride
        isoFormatter.formatOptions = [.withInternetDateTime]
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func exportGPXData(for route: RouteRecord) throws -> Data {
        let coordinates = route.routeCoordinates
        guard !coordinates.isEmpty else {
            throw AssetError.missingRouteGeometry
        }

        let escapedName = xmlEscaped(route.name)
        let escapedDescription = xmlEscaped(route.routeDescription)
        let createdAt = route.createdAt ?? route.updatedAt ?? route.syncedAt

        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="Terigo" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "<metadata>",
            "<name>\(escapedName)</name>",
            "<time>\(isoFormatter.string(from: createdAt))</time>",
            "</metadata>",
            "<trk>",
            "<name>\(escapedName)</name>"
        ]

        if !escapedDescription.isEmpty {
            lines.append("<desc>\(escapedDescription)</desc>")
        }

        lines.append("<trkseg>")

        let elevations = interpolatedElevations(for: route, coordinates: coordinates)

        for (index, coordinate) in coordinates.enumerated() {
            if let elevationMeters = elevations.indices.contains(index) ? elevations[index] : nil {
                lines.append(
                    String(
                        format: "<trkpt lat=\"%.6f\" lon=\"%.6f\"><ele>%.2f</ele></trkpt>",
                        coordinate.latitude,
                        coordinate.longitude,
                        elevationMeters
                    )
                )
            } else {
                lines.append(
                    String(
                        format: "<trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>",
                        coordinate.latitude,
                        coordinate.longitude
                    )
                )
            }
        }

        lines.append("</trkseg>")
        lines.append("</trk>")
        lines.append("</gpx>")

        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    private func interpolatedElevations(for route: RouteRecord, coordinates: [CLLocationCoordinate2D]) -> [Double?] {
        let samples = route.elevationProfile
        guard samples.count > 1, coordinates.count > 1 else {
            return Array(repeating: nil, count: coordinates.count)
        }

        let cumulativeDistances = coordinates.enumerated().reduce(into: [Double]()) { partialResult, item in
            let index = item.offset
            let coordinate = item.element

            if index == 0 {
                partialResult.append(0)
                return
            }

            let previous = coordinates[index - 1]
            let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            partialResult.append((partialResult.last ?? 0) + previousLocation.distance(from: currentLocation))
        }

        return cumulativeDistances.map { distanceMeters in
            interpolatedElevation(at: distanceMeters, samples: samples)
        }
    }

    private func interpolatedElevation(at distanceMeters: Double, samples: [RouteElevationSample]) -> Double? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }

        if distanceMeters <= first.distanceMeters {
            return first.elevationMeters
        }

        if distanceMeters >= last.distanceMeters {
            return last.elevationMeters
        }

        var lowerIndex = 0
        var upperIndex = samples.count - 1

        while lowerIndex < upperIndex {
            let midpoint = (lowerIndex + upperIndex) / 2
            if samples[midpoint].distanceMeters < distanceMeters {
                lowerIndex = midpoint + 1
            } else {
                upperIndex = midpoint
            }
        }

        let upperSample = samples[lowerIndex]
        let lowerSample = samples[max(lowerIndex - 1, 0)]
        let span = upperSample.distanceMeters - lowerSample.distanceMeters
        guard span > 0 else {
            return upperSample.elevationMeters
        }

        let progress = (distanceMeters - lowerSample.distanceMeters) / span
        return lowerSample.elevationMeters + ((upperSample.elevationMeters - lowerSample.elevationMeters) * progress)
    }

    func renderMapSnapshotData(for route: RouteRecord, size: CGSize = CGSize(width: 1800, height: 1200)) async throws -> Data {
        let coordinates = route.routeCoordinates
        guard !coordinates.isEmpty else {
            throw AssetError.missingRouteGeometry
        }

        let image = try await makeSnapshotImage(
            for: route,
            coordinates: coordinates,
            size: size,
            userInterfaceStyle: .dark,
            padding: UIEdgeInsets(top: 96, left: 96, bottom: 96, right: 96)
        )

        guard let data = image.pngData() else {
            throw AssetError.invalidSnapshot
        }

        return data
    }

    func previewMapImage(
        for route: RouteRecord,
        size: CGSize,
        userInterfaceStyle: UIUserInterfaceStyle
    ) async throws -> UIImage {
        let cacheKey = previewCacheKey(for: route, size: size, userInterfaceStyle: userInterfaceStyle)
        let cacheKeyString = cacheKey as String

        if let cachedImage = Self.previewImageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let coordinates = route.routeCoordinates
        guard !coordinates.isEmpty else {
            throw AssetError.missingRouteGeometry
        }

        let task = Self.previewTask(forKey: cacheKeyString) {
            Task {
                try await makeSnapshotImage(
                    for: route,
                    coordinates: coordinates,
                    size: size,
                    userInterfaceStyle: userInterfaceStyle,
                    padding: UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
                )
            }
        }

        do {
            let image = try await task.value
            Self.previewImageCache.setObject(image, forKey: cacheKey)
            Self.clearPreviewTask(forKey: cacheKeyString)
            return image
        } catch {
            Self.clearPreviewTask(forKey: cacheKeyString)
            throw error
        }
    }

    func storeOfflineAssets(
        for route: RouteRecord,
        gpxData: Data,
        mapStyle: AppRouteMapStyle = .outdoors
    ) async throws -> RouteOfflineAssetFiles {
        try await storeOfflineAssets(
            for: route,
            gpxData: gpxData,
            selection: RouteOfflineDownloadSelection(
                includesGPX: true,
                mapStyles: [mapStyle],
                includesTerrain: false
            )
        )
    }

    func storeOfflineAssets(
        for route: RouteRecord,
        gpxData: Data,
        selection: RouteOfflineDownloadSelection,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)? = nil
    ) async throws -> RouteOfflineAssetFiles {
        let normalizedMapStyles = selection.normalizedMapStyles
        let shouldPersistGPX = selection.includesGPX || !normalizedMapStyles.isEmpty

        guard shouldPersistGPX else {
            throw AssetError.missingRouteGeometry
        }

        progress?(RouteOfflineDownloadProgress(
            message: "Saving GPX",
            fractionCompleted: normalizedMapStyles.isEmpty ? RouteOfflineDownloadProgressScale.gpxOnlyWrite : RouteOfflineDownloadProgressScale.gpxWithMapWrite
        ))

        let routeDirectory = try directory(for: route)
        try ensureDirectoryExists(routeDirectory)

        let baseName = fileBaseName(for: route)
        let gpxRelativePath = route.offlineGPXRelativePath?.trimmed.nilIfEmpty ?? "\(routeDirectoryName(for: route))/\(baseName).gpx"
        let gpxURL = try absoluteURL(forRelativePath: gpxRelativePath)
        let hadExistingGPX = fileManager.fileExists(atPath: gpxURL.path)
        var newlyCreatedTileRegionID: String?
        var metadataRelativePathsToKeep: [String] = []
        var approximateByteCount: Int64?

        do {
            try gpxData.write(to: gpxURL, options: .atomic)

            if !normalizedMapStyles.isEmpty,
               let primaryMapStyle = selection.primaryMapStyle {
                let offlineMetadataResolution: OfflineMapMetadataResolution
                if AppUITestSupport.isEnabled {
                    progress?(RouteOfflineDownloadProgress(
                        message: "Preparing offline map",
                        fractionCompleted: RouteOfflineDownloadProgressScale.tileRegionStart
                    ))
                    offlineMetadataResolution = OfflineMapMetadataResolution(
                        metadata: makeUITestOfflineMetadata(
                            for: route,
                            mapStyles: normalizedMapStyles,
                            primaryMapStyle: primaryMapStyle,
                            includesTerrain: selection.includesTerrain,
                            gpxByteCount: Int64(gpxData.count)
                        ),
                        createdNewTileRegion: false
                    )
                } else {
                    offlineMetadataResolution = try await resolveOfflineMapMetadata(
                        for: route,
                        mapStyles: normalizedMapStyles,
                        primaryMapStyle: primaryMapStyle,
                        includesTerrain: selection.includesTerrain,
                        progress: progress
                    )
                }
                let offlineMetadata = offlineMetadataResolution.metadata
                if offlineMetadataResolution.createdNewTileRegion {
                    newlyCreatedTileRegionID = offlineMetadata.tileRegionID
                }

                approximateByteCount = offlineMetadata.approximateByteCount
                metadataRelativePathsToKeep = try writeOfflineMetadataFiles(
                    for: route,
                    baseName: baseName,
                    mapStyles: normalizedMapStyles,
                    metadataTemplate: offlineMetadata
                )
            }
            try removeLegacySnapshotIfNeeded(for: route)
            try removeObsoleteOfflineMetadataFiles(
                for: route,
                keepingRelativePaths: metadataRelativePathsToKeep
            )
            progress?(RouteOfflineDownloadProgress(message: "Finalizing download", fractionCompleted: RouteOfflineDownloadProgressScale.finalizing))
        } catch {
            if let newlyCreatedTileRegionID {
                removeTileRegionIfUnreferenced(newlyCreatedTileRegionID)
            }

            if !hadExistingGPX, fileManager.fileExists(atPath: gpxURL.path) {
                try? fileManager.removeItem(at: gpxURL)
            }

            throw error
        }

        return RouteOfflineAssetFiles(
            gpxRelativePath: gpxRelativePath,
            mapSnapshotRelativePath: metadataRelativePathsToKeep.first,
            downloadedAt: .now,
            approximateByteCount: approximateByteCount
        )
    }

    private func makeUITestOfflineMetadata(
        for route: RouteRecord,
        mapStyles: [AppRouteMapStyle],
        primaryMapStyle: AppRouteMapStyle,
        includesTerrain: Bool,
        gpxByteCount: Int64
    ) -> RouteOfflineMapMetadata {
        let uniqueStyleURIs = Array(
            Set(mapStyles.map { $0.resolvedStyleURI(for: route).rawValue })
        ).sorted()
        let approximateByteCount = gpxByteCount +
            (Int64(mapStyles.count) * 700_000) +
            (includesTerrain ? 320_000 : 0)

        return RouteOfflineMapMetadata(
            tileRegionID: "\(offlineTileRegionID(for: route))-ui-test",
            styleRawValue: primaryMapStyle.rawValue,
            downloadedAt: .now,
            approximateByteCount: approximateByteCount,
            styleURIStrings: uniqueStyleURIs,
            includesTerrainDEM: includesTerrain,
            geometryKind: RouteMapboxGeometry.offlineGeometryKind(for: route),
            coverageBounds: offlineCoverageBounds(for: route),
            metadataVersion: 4
        )
    }

    func storeLocalOfflineBundle(
        for route: RouteRecord,
        mapStyle: AppRouteMapStyle = .outdoors
    ) async throws -> RouteOfflineAssetFiles {
        let gpxData = try exportGPXData(for: route)
        return try await storeOfflineAssets(for: route, gpxData: gpxData, mapStyle: mapStyle)
    }

    func gpxURL(for route: RouteRecord) -> URL? {
        guard let relativePath = route.offlineGPXRelativePath?.trimmed.nilIfEmpty else {
            return nil
        }

        return try? absoluteURL(forRelativePath: relativePath)
    }

    func existingGPXData(for route: RouteRecord) -> Data? {
        guard let gpxURL = gpxURL(for: route),
              fileManager.fileExists(atPath: gpxURL.path) else {
            return nil
        }

        return try? Data(contentsOf: gpxURL)
    }

    func mapSnapshotURL(for route: RouteRecord) -> URL? {
        offlineMapAssetURL(for: route)
    }

    func mapSnapshotImage(for route: RouteRecord) -> UIImage? {
        guard let url = legacySnapshotURL(for: route),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        return UIImage(contentsOfFile: url.path)
    }

    func offlineStatus(for route: RouteRecord) -> RouteOfflineAssetStatus {
        let hasGPX = gpxURL(for: route).map { fileManager.fileExists(atPath: $0.path) } ?? false
        let mapStyles = downloadedMapStyles(for: route)
        let includesTerrain = includesOfflineTerrain(for: route)
        return RouteOfflineAssetStatus(
            hasGPX: hasGPX,
            mapStyles: mapStyles,
            includesTerrain: includesTerrain,
            downloadedAt: route.offlineDownloadedAt,
            totalBytes: totalOfflineBytes(for: route)
        )
    }

    func totalOfflineBytes(for route: RouteRecord) -> Int64 {
        let storedFileBytes = routeStoredAssetURLs(for: route)
            .reduce(into: Int64(0)) { total, url in
                total += fileSize(at: url)
            }

        guard let metadataRecord = offlineMetadataRecord(for: route) else {
            return storedFileBytes
        }

        let tileRegionOwnerURL = metadataOwnerURL(forTileRegionID: metadataRecord.metadata.tileRegionID)
        let tileRegionByteCount = sameFileLocation(tileRegionOwnerURL, metadataRecord.url) ? (metadataRecord.metadata.approximateByteCount ?? 0) : 0
        return storedFileBytes + tileRegionByteCount
    }

    func removeOfflineAssets(for route: RouteRecord) throws {
        let tileRegionIDs = Set(routeOfflineMetadataRecords(for: route).map { $0.metadata.tileRegionID })
        let routeDirectory = try directory(for: route)

        for url in routeStoredAssetURLs(for: route) {
            if fileManager.fileExists(atPath: url.path),
               !isDescendant(url, of: routeDirectory) {
                try fileManager.removeItem(at: url)
            }
        }

        if fileManager.fileExists(atPath: routeDirectory.path) {
            try fileManager.removeItem(at: routeDirectory)
        }

        for tileRegionID in tileRegionIDs {
            removeTileRegionIfUnreferenced(tileRegionID)
        }
    }

    func coordinateRegion(for routes: [RouteRecord]) -> MKCoordinateRegion? {
        let coordinates = routes.compactMap(\.startCoordinate)
        guard !coordinates.isEmpty else {
            return nil
        }

        return coordinateRegion(for: coordinates)
    }

    func coordinateRegion(for route: RouteRecord) -> MKCoordinateRegion? {
        let coordinates = route.routeCoordinates
        guard !coordinates.isEmpty else {
            return route.startCoordinate.map {
                MKCoordinateRegion(
                    center: $0,
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                )
            }
        }

        return coordinateRegion(for: coordinates)
    }

    func offlineAreaCoordinateRegion(for route: RouteRecord) -> MKCoordinateRegion? {
        let coordinates = route.routeCoordinates
        guard !coordinates.isEmpty else {
            return route.startCoordinate.map {
                MKCoordinateRegion(
                    center: $0,
                    span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
                )
            }
        }

        return coordinateRegion(for: coordinates, relativePadding: 1.05, minimumDelta: 0.08)
    }

    func offlineMetadata(for route: RouteRecord) -> RouteOfflineMapMetadata? {
        offlineMetadata(for: route, relativePath: route.offlineMapSnapshotRelativePath)
    }

    func downloadedMapStyles(for route: RouteRecord) -> [AppRouteMapStyle] {
        var seen = Set<String>()
        let styles = routeOfflineMetadataRecords(for: route)
            .compactMap { AppRouteMapStyle(rawValue: $0.metadata.styleRawValue) }
            .filter { seen.insert($0.rawValue).inserted }
        return AppRouteMapStyle.allCases.filter { styles.contains($0) }
    }

    func includesOfflineTerrain(for route: RouteRecord) -> Bool {
        routeOfflineMetadataRecords(for: route).contains { $0.metadata.includesTerrainDEM }
    }

    private func offlineMetadata(
        for route: RouteRecord,
        relativePath: String?
    ) -> RouteOfflineMapMetadata? {
        guard let url = offlineMetadataURL(for: route, relativePath: relativePath),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? jsonDecoder.decode(RouteOfflineMapMetadata.self, from: data)
    }

    private func offlineMetadataRecord(for route: RouteRecord) -> OfflineMetadataRecord? {
        if let url = offlineMetadataURL(for: route),
           let data = try? Data(contentsOf: url),
           let metadata = try? jsonDecoder.decode(RouteOfflineMapMetadata.self, from: data) {
            return OfflineMetadataRecord(url: url, metadata: metadata)
        }

        return routeOfflineMetadataRecords(for: route)
            .sorted { $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path }
            .first
    }

    private func offlineMetadataURL(for route: RouteRecord, relativePath: String? = nil) -> URL? {
        guard let relativePath = relativePath?.trimmed.nilIfEmpty,
              relativePath.lowercased().hasSuffix(".json") else {
            return nil
        }

        return try? absoluteURL(forRelativePath: relativePath)
    }

    private func legacySnapshotURL(for route: RouteRecord) -> URL? {
        guard let relativePath = route.offlineMapSnapshotRelativePath?.trimmed.nilIfEmpty,
              relativePath.lowercased().hasSuffix(".png") else {
            return nil
        }

        return try? absoluteURL(forRelativePath: relativePath)
    }

    private func offlineMapAssetURL(for route: RouteRecord) -> URL? {
        guard let relativePath = route.offlineMapSnapshotRelativePath?.trimmed.nilIfEmpty else {
            return nil
        }

        return try? absoluteURL(forRelativePath: relativePath)
    }

    private func removeLegacySnapshotIfNeeded(for route: RouteRecord) throws {
        guard let legacySnapshotURL = legacySnapshotURL(for: route),
              fileManager.fileExists(atPath: legacySnapshotURL.path) else {
            return
        }

        try fileManager.removeItem(at: legacySnapshotURL)
    }

    private func writeOfflineMetadataFiles(
        for route: RouteRecord,
        baseName: String,
        mapStyles: [AppRouteMapStyle],
        metadataTemplate: RouteOfflineMapMetadata
    ) throws -> [String] {
        var relativePaths: [String] = []

        for mapStyle in mapStyles {
            let relativePath = "\(routeDirectoryName(for: route))/\(baseName)-\(mapStyle.rawValue)-offline-mapbox.json"
            let url = try absoluteURL(forRelativePath: relativePath)
            let metadata = RouteOfflineMapMetadata(
                tileRegionID: metadataTemplate.tileRegionID,
                styleRawValue: mapStyle.rawValue,
                downloadedAt: metadataTemplate.downloadedAt,
                approximateByteCount: metadataTemplate.approximateByteCount,
                styleURIStrings: metadataTemplate.styleURIStrings,
                includesTerrainDEM: metadataTemplate.includesTerrainDEM,
                geometryKind: metadataTemplate.geometryKind,
                coverageBounds: metadataTemplate.coverageBounds,
                metadataVersion: metadataTemplate.metadataVersion
            )
            let data = try jsonEncoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            relativePaths.append(relativePath)
        }

        return relativePaths
    }

    private func removeObsoleteOfflineMetadataFiles(
        for route: RouteRecord,
        keepingRelativePaths: [String]
    ) throws {
        let keepSet = Set(
            keepingRelativePaths.map {
                (try? absoluteURL(forRelativePath: $0).standardizedFileURL.path) ?? $0
            }
        )

        for record in routeOfflineMetadataRecords(for: route) {
            let recordPath = record.url.standardizedFileURL.path
            guard !keepSet.contains(recordPath) else {
                continue
            }

            try? fileManager.removeItem(at: record.url)
            removeTileRegionIfUnreferenced(record.metadata.tileRegionID)
        }
    }

    private func makeSnapshotImage(
        for route: RouteRecord,
        coordinates: [CLLocationCoordinate2D],
        size: CGSize,
        userInterfaceStyle: UIUserInterfaceStyle,
        padding: UIEdgeInsets
    ) async throws -> UIImage {
        RouteVaultMapboxConfiguration.configure()

        let options = MapSnapshotOptions(
            size: size,
            pixelRatio: 2,
            showsLogo: false,
            showsAttribution: false
        )
        let snapshotter = Snapshotter(options: options)
        snapshotter.mapStyle = AppRouteMapStyle.defaultValue.resolvedStyle(for: route, colorScheme: userInterfaceStyle)
        snapshotter.setCamera(
            to: snapshotter.camera(
                for: coordinates,
                padding: padding,
                bearing: 0,
                pitch: 0
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            snapshotter.start(
                overlayHandler: { overlay in
                    drawRouteOverlay(
                        on: overlay,
                        route: route,
                        coordinates: coordinates
                    )
                },
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }

    private func drawRouteOverlay(
        on overlay: SnapshotOverlay,
        route: RouteRecord,
        coordinates: [CLLocationCoordinate2D]
    ) {
        let points = coordinates.map(overlay.pointForCoordinate)
        guard let firstPoint = points.first else {
            return
        }

        let context = overlay.context
        let path = UIBezierPath()
        path.move(to: firstPoint)

        for point in points.dropFirst() {
            path.addLine(to: point)
        }

        context.saveGState()

        RouteMapLineStyle.outlineColor.setStroke()
        path.lineWidth = RouteMapLineStyle.outlineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()

        RouteMapLineStyle.fillColor.setStroke()
        path.lineWidth = RouteMapLineStyle.fillWidth
        if route.surfaceKind != .paved {
            path.setLineDash([7, 5], count: 2, phase: 0)
        } else {
            path.setLineDash([], count: 0, phase: 0)
        }
        path.stroke()

        let startRect = CGRect(x: firstPoint.x - 9, y: firstPoint.y - 9, width: 18, height: 18)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: startRect)

        let innerStartRect = CGRect(x: firstPoint.x - 5, y: firstPoint.y - 5, width: 10, height: 10)
        context.setFillColor(UIColor(red: 0.78, green: 0.31, blue: 0.15, alpha: 1).cgColor)
        context.fillEllipse(in: innerStartRect)

        if let lastPoint = points.last, lastPoint != firstPoint {
            let endRect = CGRect(x: lastPoint.x - 6, y: lastPoint.y - 6, width: 12, height: 12)
            context.setFillColor(UIColor.black.withAlphaComponent(0.75).cgColor)
            context.fillEllipse(in: endRect)
        }

        context.restoreGState()
    }

    private func downloadOfflineMapRegion(
        for route: RouteRecord,
        mapStyles: [AppRouteMapStyle],
        includesTerrain: Bool,
        primaryMapStyle: AppRouteMapStyle,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)? = nil
    ) async throws -> RouteOfflineMapMetadata {
        RouteVaultMapboxConfiguration.configure()

        guard let geometry = RouteMapboxGeometry.offlineGeometry(for: route) else {
            throw AssetError.missingOfflineGeometry
        }

        let offlineManager = OfflineManager()
        let tileStore = TileStore.default
        let styleURIs = uniqueOfflineStyleURIs(for: mapStyles, route: route)

        for (styleIndex, styleURI) in styleURIs.enumerated() {
            let loadOptions = StylePackLoadOptions(
                glyphsRasterizationMode: .ideographsRasterizedLocally,
                metadata: [
                    "routeID": route.stravaRouteID,
                    "routeName": route.name
                ]
            )!

            _ = try await loadStylePack(
                styleURI,
                loadOptions: loadOptions,
                stylePackIndex: styleIndex,
                totalStylePackCount: styleURIs.count,
                offlineManager: offlineManager,
                progress: progress
            )

            _ = try await fetchStylePack(styleURI, offlineManager: offlineManager)
        }

        var descriptors = styleURIs.map {
            offlineManager.createTilesetDescriptor(
                for: TilesetDescriptorOptions(
                    styleURI: $0,
                    zoomRange: 0...18,
                    tilesets: nil
                )
            )
        }
        if includesTerrain, let terrainDescriptor = terrainTilesetDescriptor(offlineManager: offlineManager) {
            descriptors.append(terrainDescriptor)
        }
        let tileRegionID = offlineTileRegionID(for: route)
        let coverageBounds = offlineCoverageBounds(for: route)

        var approximateByteCount: Int64?
        let tileRegionLoadOptions = TileRegionLoadOptions(
            geometry: geometry,
            descriptors: descriptors,
            metadata: [
                "routeID": route.stravaRouteID,
                "routeName": route.name
            ],
            acceptExpired: true
        )!

        let tileRegionResult = try await loadTileRegion(
            tileRegionID: tileRegionID,
            loadOptions: tileRegionLoadOptions,
            tileStore: tileStore,
            includesTerrain: includesTerrain,
            progress: progress
        )
        approximateByteCount = tileRegionResult.approximateByteCount

        _ = try await fetchTileRegion(tileRegionID, tileStore: tileStore)
        let containsAllDescriptors = try await tileRegionContainsDescriptors(
            tileRegionID,
            descriptors: descriptors,
            tileStore: tileStore
        )

        guard containsAllDescriptors else {
            throw AssetError.incompleteOfflineTileRegion
        }

        return RouteOfflineMapMetadata(
            tileRegionID: tileRegionID,
            styleRawValue: primaryMapStyle.rawValue,
            downloadedAt: .now,
            approximateByteCount: approximateByteCount,
            styleURIStrings: styleURIs.map(\.rawValue),
            includesTerrainDEM: includesTerrain,
            geometryKind: RouteMapboxGeometry.offlineGeometryKind(for: route),
            coverageBounds: coverageBounds,
            metadataVersion: 4
        )
    }

    private func fetchStylePack(
        _ styleURI: StyleURI,
        offlineManager: OfflineManager
    ) async throws -> StylePack {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StylePack, Error>) in
                offlineManager.stylePack(for: styleURI) { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            throw AssetError.missingOfflineStylePack
        }
    }

    private func fetchTileRegion(
        _ tileRegionID: String,
        tileStore: TileStore
    ) async throws -> TileRegion {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TileRegion, Error>) in
                tileStore.tileRegion(forId: tileRegionID) { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            throw AssetError.missingOfflineTileRegion
        }
    }

    private func tileRegionContainsDescriptors(
        _ tileRegionID: String,
        descriptors: [TilesetDescriptor],
        tileStore: TileStore
    ) async throws -> Bool {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                tileStore.tileRegionContainsDescriptors(
                    forId: tileRegionID,
                    descriptors: descriptors
                ) { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            throw AssetError.incompleteOfflineTileRegion
        }
    }

    private func uniqueOfflineStyleURIs(
        for mapStyles: [AppRouteMapStyle],
        route: RouteRecord?
    ) -> [StyleURI] {
        var seen = Set<String>()
        return mapStyles
            .map { $0.resolvedStyleURI(for: route) }
            .filter { seen.insert($0.rawValue).inserted }
    }

    private func terrainTilesetDescriptor(offlineManager: OfflineManager) -> TilesetDescriptor? {
        offlineManager.createTilesetDescriptor(
            for: TilesetDescriptorOptions(
                styleURI: .standard,
                zoomRange: 0...14,
                tilesets: [RouteMapTerrainTuning.offlineTilesetURI]
            )
        )
    }

    private func offlineTileRegionID(for route: RouteRecord) -> String {
        "route-\(route.stravaRouteID)-offline-region"
    }

    private func resolveOfflineMapMetadata(
        for route: RouteRecord,
        mapStyle: AppRouteMapStyle
    ) async throws -> OfflineMapMetadataResolution {
        try await resolveOfflineMapMetadata(
            for: route,
            mapStyles: [mapStyle],
            primaryMapStyle: mapStyle,
            includesTerrain: false
        )
    }

    private func resolveOfflineMapMetadata(
        for route: RouteRecord,
        mapStyles: [AppRouteMapStyle],
        primaryMapStyle: AppRouteMapStyle,
        includesTerrain: Bool,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)? = nil
    ) async throws -> OfflineMapMetadataResolution {
        let normalizedMapStyles = mapStyles.isEmpty ? [primaryMapStyle] : mapStyles

        if let requestedCoverageBounds = offlineCoverageBounds(for: route),
           let reusableMetadata = try await reusableOfflineMetadata(
                containing: requestedCoverageBounds,
                mapStyles: normalizedMapStyles,
                includesTerrain: includesTerrain
           ) {
            progress?(RouteOfflineDownloadProgress(
                message: "Using saved map coverage",
                fractionCompleted: RouteOfflineDownloadProgressScale.reuseExistingMap
            ))
            return OfflineMapMetadataResolution(
                metadata: RouteOfflineMapMetadata(
                    tileRegionID: reusableMetadata.tileRegionID,
                    styleRawValue: primaryMapStyle.rawValue,
                    downloadedAt: .now,
                    approximateByteCount: reusableMetadata.approximateByteCount,
                    styleURIStrings: reusableMetadata.styleURIStrings,
                    includesTerrainDEM: reusableMetadata.includesTerrainDEM || includesTerrain,
                    geometryKind: reusableMetadata.geometryKind,
                    coverageBounds: reusableMetadata.coverageBounds,
                    metadataVersion: max(reusableMetadata.metadataVersion, 4)
                ),
                createdNewTileRegion: false
            )
        }

        return OfflineMapMetadataResolution(
            metadata: try await downloadOfflineMapRegion(
                for: route,
                mapStyles: normalizedMapStyles,
                includesTerrain: includesTerrain,
                primaryMapStyle: primaryMapStyle,
                progress: progress
            ),
            createdNewTileRegion: true
        )
    }

    private func styleDisplayName(for styleURI: StyleURI) -> String {
        switch styleURI.rawValue {
        case StyleURI.satellite.rawValue:
            return "satellite"
        case StyleURI.satelliteStreets.rawValue:
            return "hybrid"
        case StyleURI.outdoors.rawValue:
            return "outdoors"
        default:
            return "standard"
        }
    }

    private func reusableOfflineMetadata(
        containing requestedCoverageBounds: RouteOfflineMapMetadata.CoverageBounds,
        mapStyles: [AppRouteMapStyle],
        includesTerrain: Bool
    ) async throws -> RouteOfflineMapMetadata? {
        RouteVaultMapboxConfiguration.configure()
        let requiredStyleURIs = Set(uniqueOfflineStyleURIs(for: mapStyles, route: nil).map(\.rawValue))

        let candidates = allOfflineMetadataRecords()
            .filter {
                let candidateStyleURIs = Set($0.metadata.styleURIStrings)
                let hasRequiredStyles = requiredStyleURIs.isSubset(of: candidateStyleURIs)
                let hasRequiredTerrain = !includesTerrain || $0.metadata.includesTerrainDEM
                return hasRequiredStyles &&
                    hasRequiredTerrain &&
                    ($0.metadata.coverageBounds?.contains(requestedCoverageBounds) ?? false)
            }
            .sorted {
                ($0.metadata.coverageBounds?.areaEstimate ?? .greatestFiniteMagnitude) <
                    ($1.metadata.coverageBounds?.areaEstimate ?? .greatestFiniteMagnitude)
            }

        guard !candidates.isEmpty else {
            return nil
        }

        let tileStore = TileStore.default
        for candidate in candidates {
            do {
                _ = try await fetchTileRegion(candidate.metadata.tileRegionID, tileStore: tileStore)
                return candidate.metadata
            } catch {
                continue
            }
        }

        return nil
    }

    private func offlineCoverageBounds(for route: RouteRecord) -> RouteOfflineMapMetadata.CoverageBounds? {
        if let region = offlineAreaCoordinateRegion(for: route) {
            return RouteOfflineMapMetadata.CoverageBounds(region: region)
        }

        guard let coordinate = route.startCoordinate else {
            return nil
        }

        return RouteOfflineMapMetadata.CoverageBounds(
            minimumLatitude: coordinate.latitude,
            maximumLatitude: coordinate.latitude,
            minimumLongitude: coordinate.longitude,
            maximumLongitude: coordinate.longitude
        )
    }

    private func metadataOwnerURL(forTileRegionID tileRegionID: String) -> URL? {
        allOfflineMetadataRecords()
            .filter { $0.metadata.tileRegionID == tileRegionID }
            .sorted { $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path }
            .first?
            .url
    }

    private func removeTileRegionIfUnreferenced(_ tileRegionID: String) {
        guard metadataOwnerURL(forTileRegionID: tileRegionID) == nil else {
            return
        }

        TileStore.default.removeTileRegion(forId: tileRegionID)
    }

    private func allOfflineMetadataRecords() -> [OfflineMetadataRecord] {
        guard let baseDirectory = try? baseDirectory(),
              let enumerator = fileManager.enumerator(
                at: baseDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var records: [OfflineMetadataRecord] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.lowercased().hasSuffix("-offline-mapbox.json"),
                  let data = try? Data(contentsOf: url),
                  let metadata = try? jsonDecoder.decode(RouteOfflineMapMetadata.self, from: data) else {
                continue
            }

            records.append(OfflineMetadataRecord(url: url, metadata: metadata))
        }

        return records
    }

    private func routeOfflineMetadataRecords(for route: RouteRecord) -> [OfflineMetadataRecord] {
        guard let routeDirectory = try? directory(for: route) else {
            return []
        }

        let routeDirectoryPath = routeDirectory.standardizedFileURL.path
        return allOfflineMetadataRecords().filter { record in
            record.url.standardizedFileURL.path.hasPrefix(routeDirectoryPath + "/")
        }
    }

    private func routeStoredAssetURLs(for route: RouteRecord) -> [URL] {
        var seenPaths = Set<String>()
        var urls: [URL] = []

        func append(_ url: URL?) {
            guard let url else {
                return
            }

            let normalizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(normalizedPath).inserted else {
                return
            }

            urls.append(url)
        }

        append(gpxURL(for: route))
        append(offlineMapAssetURL(for: route))

        if let routeDirectory = try? directory(for: route),
           let enumerator = fileManager.enumerator(
                at: routeDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator {
                let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isRegularFile {
                    append(url)
                }
            }
        }

        return urls
    }

    private func loadStylePack(
        _ styleURI: StyleURI,
        loadOptions: StylePackLoadOptions,
        stylePackIndex: Int,
        totalStylePackCount: Int,
        offlineManager: OfflineManager,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)?
    ) async throws -> StylePack {
        let displayName = styleDisplayName(for: styleURI)
        let normalizedStylePackCount = max(totalStylePackCount, 1)
        let stylePackSpan = RouteOfflineDownloadProgressScale.stylePackSpan / Double(normalizedStylePackCount)
        let stylePackBase = RouteOfflineDownloadProgressScale.stylePackStart + (Double(stylePackIndex) * stylePackSpan)
        progress?(RouteOfflineDownloadProgress(
            message: "Downloading \(displayName) style",
            fractionCompleted: stylePackBase
        ))

        return try await withTimeout(
            seconds: 90,
            stageDescription: "downloading the \(displayName) style"
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StylePack, Error>) in
                let lock = NSLock()
                var didResume = false
                var cancelable: Cancelable?

                func resumeOnce(with result: Result<StylePack, Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else {
                        return
                    }
                    didResume = true
                    cancelable = nil
                    continuation.resume(with: result)
                }

                cancelable = offlineManager.loadStylePack(
                    for: styleURI,
                    loadOptions: loadOptions,
                    progress: { stylePackProgress in
                        let fractionCompleted: Double?
                        if stylePackProgress.requiredResourceCount > 0 {
                            fractionCompleted = Double(stylePackProgress.completedResourceCount) / Double(stylePackProgress.requiredResourceCount)
                        } else {
                            fractionCompleted = nil
                        }

                        progress?(RouteOfflineDownloadProgress(
                            message: "Downloading \(displayName) style",
                            fractionCompleted: fractionCompleted.map { stylePackBase + ($0 * stylePackSpan) }
                        ))
                    },
                    completion: { result in
                        resumeOnce(with: result)
                    }
                )
            }
        }
    }

    private func loadTileRegion(
        tileRegionID: String,
        loadOptions: TileRegionLoadOptions,
        tileStore: TileStore,
        includesTerrain: Bool,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)?
    ) async throws -> (tileRegion: TileRegion, approximateByteCount: Int64?) {
        try await withTimeout(
            seconds: 180,
            stageDescription: includesTerrain ? "downloading map tiles and 3D terrain" : "downloading map tiles"
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(tileRegion: TileRegion, approximateByteCount: Int64?), Error>) in
                let lock = NSLock()
                var didResume = false
                var cancelable: Cancelable?
                var capturedByteCount: Int64?

                func resumeOnce(with result: Result<(tileRegion: TileRegion, approximateByteCount: Int64?), Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else {
                        return
                    }
                    didResume = true
                    cancelable = nil
                    continuation.resume(with: result)
                }

                cancelable = tileStore.loadTileRegion(
                    forId: tileRegionID,
                    loadOptions: loadOptions,
                    progress: { tileProgress in
                        capturedByteCount = Int64(clamping: tileProgress.completedResourceSize)
                        let fractionCompleted: Double?
                        if tileProgress.requiredResourceCount > 0 {
                            fractionCompleted = Double(tileProgress.completedResourceCount) / Double(tileProgress.requiredResourceCount)
                        } else {
                            fractionCompleted = nil
                        }
                        let message = includesTerrain
                            ? "Downloading map + 3D terrain"
                            : "Downloading map tiles"
                        progress?(RouteOfflineDownloadProgress(
                            message: message,
                            fractionCompleted: fractionCompleted.map {
                                RouteOfflineDownloadProgressScale.tileRegionStart + ($0 * RouteOfflineDownloadProgressScale.tileRegionSpan)
                            }
                        ))
                    },
                    completion: { result in
                        resumeOnce(with: result.map { ($0, capturedByteCount) })
                    }
                )
            }
        }
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        stageDescription: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AssetError.offlineDownloadTimedOut(stageDescription)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func sameFileLocation(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return 0
        }

        return Int64(values.fileSize ?? 0)
    }

    private func coordinateRegion(
        for coordinates: [CLLocationCoordinate2D],
        relativePadding: Double = 0.2,
        minimumDelta: Double = 0.015
    ) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
            )
        }

        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }

        let latitudePadding = max((maxLatitude - minLatitude) * relativePadding, minimumDelta)
        let longitudePadding = max((maxLongitude - minLongitude) * relativePadding, minimumDelta)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: (maxLatitude - minLatitude) + latitudePadding,
                longitudeDelta: (maxLongitude - minLongitude) + longitudePadding
            )
        )
    }

    private func previewCoordinateRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        coordinateRegion(for: coordinates, relativePadding: 0.18, minimumDelta: 0.01)
    }

    private func previewCacheKey(
        for route: RouteRecord,
        size: CGSize,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> NSString {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let timestamp = Int((route.updatedAt ?? route.syncedAt).timeIntervalSinceReferenceDate.rounded())
        return "\(route.stravaRouteID)-\(width)x\(height)-\(userInterfaceStyle.rawValue)-\(timestamp)" as NSString
    }

    private static func previewTask(
        forKey key: String,
        create: () -> Task<UIImage, Error>
    ) -> Task<UIImage, Error> {
        previewImageTaskLock.lock()
        defer { previewImageTaskLock.unlock() }

        if let existingTask = previewImageTasks[key] {
            return existingTask
        }

        let task = create()
        previewImageTasks[key] = task
        return task
    }

    private static func clearPreviewTask(forKey key: String) {
        previewImageTaskLock.lock()
        previewImageTasks[key] = nil
        previewImageTaskLock.unlock()
    }

    private func directory(for route: RouteRecord) throws -> URL {
        try baseDirectory().appendingPathComponent(routeDirectoryName(for: route), isDirectory: true)
    }

    private func routeDirectoryName(for route: RouteRecord) -> String {
        "route-\(route.stravaRouteID)"
    }

    private func fileBaseName(for route: RouteRecord) -> String {
        let slug = route.name
            .trimmed
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nilIfEmpty ?? "route"

        return "\(slug.prefix(48))-\(route.stravaRouteID)"
    }

    private func baseDirectory() throws -> URL {
        if let baseDirectoryOverride {
            try ensureDirectoryExists(baseDirectoryOverride)
            return baseDirectoryOverride
        }

        let appSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let baseDirectory = appSupportDirectory.appendingPathComponent("OfflineRoutes", isDirectory: true)
        try ensureDirectoryExists(baseDirectory)
        return baseDirectory
    }

    private func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        try baseDirectory().appendingPathComponent(relativePath)
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum RouteDetailDownloadError: LocalizedError {
    case notConnected
    case privateRouteRequiresReadAll

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect Strava before downloading route details from the service."
        case .privateRouteRequiresReadAll:
            return "Private route GPX export requires Strava `read_all` access. Reconnect Strava and grant full route access."
        }
    }
}

@MainActor
struct RouteDetailDownloadCoordinator {
    private let apiService = StravaAPIService()
    private let credentialStore = StravaCredentialStore()
    private let gpxImportService = GPXImportService()
    private let offlineAssetService = RouteOfflineAssetService()

    func downloadRouteDetails(
        for route: RouteRecord,
        mapStyle: AppRouteMapStyle = .outdoors
    ) async throws -> RouteOfflineAssetFiles {
        try await downloadRouteDetails(
            for: route,
            selection: RouteOfflineDownloadSelection(
                includesGPX: true,
                mapStyles: [mapStyle],
                includesTerrain: false
            ),
            progress: nil
        )
    }

    func downloadRouteDetails(
        for route: RouteRecord,
        selection: RouteOfflineDownloadSelection,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)? = nil
    ) async throws -> RouteOfflineAssetFiles {
        progress?(RouteOfflineDownloadProgress(
            message: route.isImportedFromGPX ? "Preparing GPX" : "Downloading GPX",
            fractionCompleted: RouteOfflineDownloadProgressScale.preparingGPX
        ))
        let gpxData = try await routeGPXData(for: route)
        progress?(RouteOfflineDownloadProgress(
            message: "Importing route shape",
            fractionCompleted: RouteOfflineDownloadProgressScale.importingRouteShape
        ))
        let importedGeometry = try await gpxImportService.importRoute(
            from: gpxData,
            suggestedName: route.name,
            options: .geometryOnly
        )
        route.applyImportedGeometry(importedGeometry)
        return try await offlineAssetService.storeOfflineAssets(
            for: route,
            gpxData: gpxData,
            selection: selection,
            progress: progress
        )
    }

    private func routeGPXData(for route: RouteRecord) async throws -> Data {
        if let gpxData = offlineAssetService.existingGPXData(for: route) {
            return gpxData
        }

        // UI tests seed route geometry locally and should not depend on live Strava auth.
        if AppUITestSupport.isEnabled {
            return try offlineAssetService.exportGPXData(for: route)
        }

        if route.isImportedFromGPX {
            return try offlineAssetService.exportGPXData(for: route)
        }

        return try await fetchGPXFromStrava(for: route)
    }

    private func fetchGPXFromStrava(for route: RouteRecord) async throws -> Data {
        guard let credentials = try credentialStore.loadCredentials(),
              var session = try credentialStore.loadSession() else {
            throw RouteDetailDownloadError.notConnected
        }

        if route.isPrivate && !session.hasReadAllAccess {
            throw RouteDetailDownloadError.privateRouteRequiresReadAll
        }

        do {
            session = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            let gpxData = try await apiService.fetchRouteGPX(routeID: route.stravaRouteID, accessToken: session.accessToken)
            try credentialStore.save(session: session)
            return gpxData
        } catch StravaAPIService.APIError.unauthorized {
            session = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials, forceRefresh: true)
            let gpxData = try await apiService.fetchRouteGPX(routeID: route.stravaRouteID, accessToken: session.accessToken)
            try credentialStore.save(session: session)
            return gpxData
        } catch {
            invalidateSessionIfNeeded(for: error)
            throw error
        }
    }

    private func invalidateSessionIfNeeded(for error: Error) {
        guard let apiError = error as? StravaAPIService.APIError,
              apiError.requiresSessionReset else {
            return
        }

        try? credentialStore.clearSession()
    }
}
