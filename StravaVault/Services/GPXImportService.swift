import CoreLocation
import CryptoKit
import Foundation

struct ImportedGPXRoute {
    let routeID: Int
    let name: String
    let description: String
    let distanceMeters: Double
    let elevationGainMeters: Double
    let elevationSamples: [RouteElevationSample]
    let estimatedMovingTime: Double
    let routeType: Int
    let routeSubType: Int
    let regionName: String
    let parkName: String
    let countyName: String
    let city: String
    let state: String
    let country: String
    let summaryPolyline: String
    let surfaceKind: RouteSurfaceKind?
    let createdAt: Date?
    let updatedAt: Date?
}

struct GPXImportService {
    struct ImportOptions {
        var resolvesLocation = true
        var resolvesSurfaceKind = true

        static let full = ImportOptions()
        static let geometryOnly = ImportOptions(
            resolvesLocation: false,
            resolvesSurfaceKind: false
        )
    }

    enum ImportError: LocalizedError {
        case unreadableFile
        case invalidGPX
        case missingCoordinates

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "The GPX file could not be opened."
            case .invalidGPX:
                return "The selected file is not a valid GPX route."
            case .missingCoordinates:
                return "The GPX file does not contain any route points."
            }
        }
    }

    func importRoute(
        from url: URL,
        options: ImportOptions = .full
    ) async throws -> ImportedGPXRoute {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data

        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadableFile
        }

        return try await importRoute(
            from: data,
            suggestedName: url.deletingPathExtension().lastPathComponent,
            options: options
        )
    }

    func importRoute(
        from data: Data,
        suggestedName: String,
        options: ImportOptions = .full
    ) async throws -> ImportedGPXRoute {
        let document = try GPXDocumentParser.parse(data: data)
        let points = document.trackPoints.isEmpty ? document.routePoints : document.trackPoints

        guard let startPoint = points.first else {
            throw ImportError.missingCoordinates
        }

        let name = preferredName(from: document, suggestedName: suggestedName)
        let description = preferredDescription(from: document)
        let activity = inferActivityKind(name: name, description: description, suggestedName: suggestedName)
        async let location = resolvedLocation(for: startPoint.coordinate, resolvesLocation: options.resolvesLocation)
        async let surfaceKind = resolvedSurfaceKind(for: points.map(\.coordinate), resolvesSurfaceKind: options.resolvesSurfaceKind)
        let resolvedLocation = await location

        return ImportedGPXRoute(
            routeID: stableRouteID(for: data),
            name: name,
            description: description,
            distanceMeters: totalDistanceMeters(for: points),
            elevationGainMeters: totalElevationGainMeters(for: points),
            elevationSamples: elevationProfileSamples(for: points),
            estimatedMovingTime: estimatedMovingTime(for: points),
            routeType: activity.type,
            routeSubType: activity.subType,
            regionName: resolvedLocation.regionName,
            parkName: resolvedLocation.parkName,
            countyName: resolvedLocation.countyName,
            city: resolvedLocation.city,
            state: resolvedLocation.state,
            country: resolvedLocation.country,
            summaryPolyline: RoutePolylineCodec.encode(points.map(\.coordinate)),
            surfaceKind: await surfaceKind,
            createdAt: document.createdAt ?? points.first?.timestamp,
            updatedAt: document.updatedAt ?? points.last?.timestamp
        )
    }

    private func preferredName(from document: GPXDocument, suggestedName: String) -> String {
        [
            document.metadataName,
            document.trackName,
            document.routeName,
            suggestedName
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? "Imported GPX Route"
    }

    private func preferredDescription(from document: GPXDocument) -> String {
        [
            document.trackDescription,
            document.routeDescription,
            document.metadataDescription
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? ""
    }

    private func totalDistanceMeters(for points: [GPXTrackPoint]) -> Double {
        guard points.count > 1 else {
            return 0
        }

        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            let start = CLLocation(latitude: pair.0.coordinate.latitude, longitude: pair.0.coordinate.longitude)
            let end = CLLocation(latitude: pair.1.coordinate.latitude, longitude: pair.1.coordinate.longitude)
            return total + start.distance(from: end)
        }
    }

    private func totalElevationGainMeters(for points: [GPXTrackPoint]) -> Double {
        guard points.count > 1 else {
            return 0
        }

        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            guard let startElevation = pair.0.elevation,
                  let endElevation = pair.1.elevation,
                  endElevation > startElevation else {
                return total
            }

            return total + (endElevation - startElevation)
        }
    }

    private func estimatedMovingTime(for points: [GPXTrackPoint]) -> Double {
        guard let firstTimestamp = points.compactMap(\.timestamp).first,
              let lastTimestamp = points.compactMap(\.timestamp).last,
              lastTimestamp > firstTimestamp else {
            return 0
        }

        return lastTimestamp.timeIntervalSince(firstTimestamp)
    }

    private func elevationProfileSamples(for points: [GPXTrackPoint]) -> [RouteElevationSample] {
        guard points.count > 1 else {
            return []
        }

        struct ProfilePoint {
            let coordinate: CLLocationCoordinate2D
            let distanceMeters: Double
            var elevationMeters: Double?
        }

        var profilePoints: [ProfilePoint] = []
        var cumulativeDistanceMeters = 0.0

        for (index, point) in points.enumerated() {
            if index > 0 {
                let previous = points[index - 1]
                let previousLocation = CLLocation(
                    latitude: previous.coordinate.latitude,
                    longitude: previous.coordinate.longitude
                )
                let currentLocation = CLLocation(
                    latitude: point.coordinate.latitude,
                    longitude: point.coordinate.longitude
                )
                cumulativeDistanceMeters += previousLocation.distance(from: currentLocation)
            }

            profilePoints.append(
                ProfilePoint(
                    coordinate: point.coordinate,
                    distanceMeters: cumulativeDistanceMeters,
                    elevationMeters: point.elevation
                )
            )
        }

        let knownElevationIndices = profilePoints.indices.filter { profilePoints[$0].elevationMeters != nil }
        guard knownElevationIndices.count >= 2 else {
            return []
        }

        if let firstKnownIndex = knownElevationIndices.first,
           let firstKnownElevation = profilePoints[firstKnownIndex].elevationMeters {
            for index in profilePoints.indices.prefix(upTo: firstKnownIndex) {
                profilePoints[index].elevationMeters = firstKnownElevation
            }
        }

        if let lastKnownIndex = knownElevationIndices.last,
           let lastKnownElevation = profilePoints[lastKnownIndex].elevationMeters {
            for index in profilePoints.indices.suffix(from: lastKnownIndex + 1) {
                profilePoints[index].elevationMeters = lastKnownElevation
            }
        }

        for pair in zip(knownElevationIndices, knownElevationIndices.dropFirst()) {
            let startIndex = pair.0
            let endIndex = pair.1
            guard endIndex > startIndex,
                  let startElevation = profilePoints[startIndex].elevationMeters,
                  let endElevation = profilePoints[endIndex].elevationMeters else {
                continue
            }

            let spanDistance = profilePoints[endIndex].distanceMeters - profilePoints[startIndex].distanceMeters
            guard spanDistance > 0 else {
                continue
            }

            for index in (startIndex + 1)..<endIndex {
                let progress = (profilePoints[index].distanceMeters - profilePoints[startIndex].distanceMeters) / spanDistance
                profilePoints[index].elevationMeters = startElevation + ((endElevation - startElevation) * progress)
            }
        }

        let samples = profilePoints.compactMap { point -> RouteElevationSample? in
            guard let elevationMeters = point.elevationMeters else {
                return nil
            }

            return RouteElevationSample(
                distanceMeters: point.distanceMeters,
                elevationMeters: elevationMeters,
                latitude: point.coordinate.latitude,
                longitude: point.coordinate.longitude
            )
        }

        return downsampledElevationSamples(samples, maximumCount: 240)
    }

    private func downsampledElevationSamples(_ samples: [RouteElevationSample], maximumCount: Int) -> [RouteElevationSample] {
        guard samples.count > maximumCount, maximumCount > 1 else {
            return samples
        }

        let step = Double(samples.count - 1) / Double(maximumCount - 1)
        let sampled = (0..<maximumCount).map { index in
            let sampleIndex = min(Int((Double(index) * step).rounded()), samples.count - 1)
            return samples[sampleIndex]
        }

        var deduplicated: [RouteElevationSample] = []
        var seen = Set<String>()

        for sample in sampled {
            guard seen.insert(sample.id).inserted else {
                continue
            }

            deduplicated.append(sample)
        }

        return deduplicated
    }

    private func inferActivityKind(name: String, description: String, suggestedName: String) -> (type: Int, subType: Int) {
        let searchableText = [name, description, suggestedName]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if searchableText.contains("hike") || searchableText.contains("hiking") || searchableText.contains("trek") {
            return (2, 0)
        }

        if searchableText.contains("walk") || searchableText.contains("walking") || searchableText.contains("stroll") {
            return (2, 0)
        }

        if searchableText.contains("snowshoe") || searchableText.contains("ski") || searchableText.contains("wheelchair") {
            return (0, 0)
        }

        if searchableText.contains("trail run") || (searchableText.contains("trail") && searchableText.contains("run")) {
            return (2, 4)
        }

        if searchableText.contains("run") || searchableText.contains("jog") {
            return (2, 0)
        }

        if searchableText.contains("mountain bike") || searchableText.contains(" mtb") || searchableText.hasPrefix("mtb") {
            return (1, 2)
        }

        if searchableText.contains("cross") || searchableText.contains("cyclocross") {
            return (1, 3)
        }

        if searchableText.contains("mixed") || searchableText.contains("gravel") {
            return (1, 5)
        }

        if searchableText.contains("road") || searchableText.contains("ride") || searchableText.contains("bike") || searchableText.contains("cycling") {
            return (1, 1)
        }

        return (0, 0)
    }

    private func stableRouteID(for data: Data) -> Int {
        let digest = SHA256.hash(data: data)
        let rawValue = digest.prefix(8).reduce(UInt64(0)) { partialResult, byte in
            (partialResult << 8) | UInt64(byte)
        }
        let boundedValue = Int(rawValue & UInt64(Int.max))
        return -max(1, boundedValue)
    }

    private func resolvedLocation(
        for coordinate: CLLocationCoordinate2D,
        resolvesLocation: Bool
    ) async -> ParsedLocation {
        guard resolvesLocation else {
            return defaultLocation(for: coordinate)
        }

        return await resolveLocation(for: coordinate)
    }

    private func resolvedSurfaceKind(
        for coordinates: [CLLocationCoordinate2D],
        resolvesSurfaceKind: Bool
    ) async -> RouteSurfaceKind? {
        guard resolvesSurfaceKind else {
            return nil
        }

        return await RouteSurfaceLookupService.surfaceKind(for: coordinates)
    }

    private func defaultLocation(for coordinate: CLLocationCoordinate2D) -> ParsedLocation {
        ParsedLocation(
            referenceName: coordinate.formattedLabel,
            regionName: "",
            parkName: "",
            countyName: "",
            city: coordinate.formattedLabel,
            state: "",
            country: ""
        )
    }

    private func resolveLocation(for coordinate: CLLocationCoordinate2D) async -> ParsedLocation {
        let fallback = defaultLocation(for: coordinate)

        do {
            let placemarks = try await reverseGeocode(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let placemark = placemarks.first else {
                return fallback
            }

            return ParsedLocation(details: placemark.routeStartLocationDetails(preferredName: nil, fallbackName: fallback.referenceName))
        } catch {
            return fallback
        }
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

private enum RouteSurfaceLookupService {
    private static let overpassURL = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let searchRadiusMeters = 18
    private static let maximumSampleCount = 24
    private static let requestTimeout: TimeInterval = 18

    private static let pavedSurfaceTokens = [
        "paved",
        "asphalt",
        "concrete",
        "paving_stones",
        "paving stones",
        "sett",
        "cobblestone",
        "chipseal",
        "metal",
        "brick",
        "rubber"
    ]

    private static let mixedSurfaceTokens = [
        "gravel",
        "fine_gravel",
        "fine gravel",
        "compacted",
        "crushed_stone",
        "crushed stone",
        "pebblestone",
        "shells"
    ]

    private static let trailSurfaceTokens = [
        "unpaved",
        "dirt",
        "earth",
        "ground",
        "grass",
        "sand",
        "mud",
        "rock",
        "stone",
        "roots",
        "woodchips",
        "wood chips",
        "bark",
        "snow",
        "ice"
    ]

    private static let pavedHighwayTokens = [
        "residential",
        "service",
        "living_street",
        "pedestrian",
        "unclassified",
        "tertiary",
        "secondary",
        "primary",
        "cycleway",
        "road",
        "footway",
        "sidewalk"
    ]

    private static let trailHighwayTokens = [
        "path",
        "track",
        "bridleway",
        "steps",
        "via_ferrata"
    ]

    private static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }()

    private static let session = URLSession(configuration: configuration)

    static func surfaceKind(for coordinates: [CLLocationCoordinate2D]) async -> RouteSurfaceKind? {
        let sampledCoordinates = sampledRouteCoordinates(from: coordinates)
        guard sampledCoordinates.count >= 2 else {
            return nil
        }

        do {
            let response = try await fetchSurfaceResponse(near: sampledCoordinates)
            return classifySurface(from: response.elements)
        } catch {
            return nil
        }
    }

    private static func fetchSurfaceResponse(near coordinates: [CLLocationCoordinate2D]) async throws -> OverpassSurfaceResponse {
        var request = URLRequest(url: overpassURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = overpassQuery(for: coordinates).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw GPXImportService.ImportError.invalidGPX
        }

        return try JSONDecoder().decode(OverpassSurfaceResponse.self, from: data)
    }

    private static func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String {
        let linestring = coordinates
            .map { coordinate in
                String(
                    format: "%.6f,%.6f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    coordinate.latitude,
                    coordinate.longitude
                )
            }
            .joined(separator: ",")

        return """
        [out:json][timeout:18];
        way[highway](around:\(searchRadiusMeters),\(linestring));
        out tags;
        """
    }

    private static func classifySurface(from elements: [OverpassSurfaceElement]) -> RouteSurfaceKind? {
        var pavedScore = 0.0
        var mixedScore = 0.0
        var trailScore = 0.0

        for element in elements {
            let tags = element.tags
            let surface = tags["surface"]?.normalizedSurfaceTokens
            let highway = tags["highway"]?.normalizedSurfaceTokens
            let tracktype = tags["tracktype"]?.normalizedSurfaceTokens

            if let surface {
                if pavedSurfaceTokens.contains(where: surface.contains) {
                    pavedScore += 3
                }

                if mixedSurfaceTokens.contains(where: surface.contains) {
                    mixedScore += 3
                }

                if trailSurfaceTokens.contains(where: surface.contains) {
                    trailScore += 3
                }
            }

            if let highway {
                if pavedHighwayTokens.contains(where: highway.contains) {
                    pavedScore += 1.5
                }

                if trailHighwayTokens.contains(where: highway.contains) {
                    trailScore += 1.75
                }
            }

            switch tracktype {
            case let value? where value.contains("grade1"):
                pavedScore += 2.5
            case let value? where value.contains("grade2"):
                mixedScore += 2.5
            case let value? where value.contains("grade3"):
                mixedScore += 2
                trailScore += 0.75
            case let value? where value.contains("grade4"):
                trailScore += 2.5
            case let value? where value.contains("grade5"):
                trailScore += 3
            default:
                break
            }
        }

        if mixedScore > 0, pavedScore > 0, trailScore > 0 {
            return .mixed
        }

        if pavedScore > 0, trailScore > 0 {
            let dominantScore = max(pavedScore, trailScore)
            let secondaryScore = min(pavedScore, trailScore)

            if dominantScore == 0 || secondaryScore / dominantScore >= 0.45 {
                return .mixed
            }

            return pavedScore > trailScore ? .paved : .trail
        }

        if mixedScore >= max(pavedScore, trailScore), mixedScore > 0 {
            return .mixed
        }

        if trailScore > pavedScore, trailScore > 0 {
            return .trail
        }

        if pavedScore > 0 {
            return .paved
        }

        return nil
    }

    private static func sampledRouteCoordinates(from coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let deduplicatedCoordinates = deduplicated(coordinates)
        guard deduplicatedCoordinates.count > maximumSampleCount else {
            return deduplicatedCoordinates
        }

        let step = Double(deduplicatedCoordinates.count - 1) / Double(maximumSampleCount - 1)
        let sampledCoordinates = (0..<maximumSampleCount).compactMap { index -> CLLocationCoordinate2D? in
            let coordinateIndex = min(
                Int((Double(index) * step).rounded()),
                deduplicatedCoordinates.count - 1
            )
            return deduplicatedCoordinates[coordinateIndex]
        }

        return deduplicated(sampledCoordinates)
    }

    private static func deduplicated(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var seen = Set<String>()
        var deduplicatedCoordinates: [CLLocationCoordinate2D] = []

        for coordinate in coordinates {
            let key = String(
                format: "%.5f,%.5f",
                locale: Locale(identifier: "en_US_POSIX"),
                coordinate.latitude,
                coordinate.longitude
            )
            guard seen.insert(key).inserted else {
                continue
            }

            deduplicatedCoordinates.append(coordinate)
        }

        return deduplicatedCoordinates
    }
}

private struct OverpassSurfaceResponse: Decodable {
    let elements: [OverpassSurfaceElement]
}

private struct OverpassSurfaceElement: Decodable {
    let tags: [String: String]
}

private struct GPXDocument {
    let metadataName: String?
    let metadataDescription: String?
    let routeName: String?
    let routeDescription: String?
    let trackName: String?
    let trackDescription: String?
    let trackPoints: [GPXTrackPoint]
    let routePoints: [GPXTrackPoint]
    let createdAt: Date?
    let updatedAt: Date?
}

private struct GPXTrackPoint {
    let coordinate: CLLocationCoordinate2D
    var elevation: Double?
    var timestamp: Date?
}

private struct ParsedLocation {
    let referenceName: String
    let regionName: String
    let parkName: String
    let countyName: String
    let city: String
    let state: String
    let country: String

    init(
        referenceName: String,
        regionName: String,
        parkName: String,
        countyName: String,
        city: String,
        state: String,
        country: String
    ) {
        self.referenceName = referenceName
        self.regionName = regionName
        self.parkName = parkName
        self.countyName = countyName
        self.city = city
        self.state = state
        self.country = country
    }

    init(details: RouteStartLocationDetails) {
        referenceName = details.referenceName
        regionName = details.regionName
        parkName = details.parkName
        countyName = details.countyName
        city = details.cityName
        state = details.stateName
        country = details.countryName
    }
}

private final class GPXDocumentParser: NSObject, XMLParserDelegate {
    private enum ParentContext {
        case metadata
        case route
        case track
    }

    private var contextStack: [ParentContext] = []
    private var currentText = ""
    private var currentRoutePoint: GPXTrackPoint?
    private var currentTrackPoint: GPXTrackPoint?

    private(set) var metadataName: String?
    private(set) var metadataDescription: String?
    private(set) var routeName: String?
    private(set) var routeDescription: String?
    private(set) var trackName: String?
    private(set) var trackDescription: String?
    private(set) var trackPoints: [GPXTrackPoint] = []
    private(set) var routePoints: [GPXTrackPoint] = []
    private(set) var createdAt: Date?
    private(set) var updatedAt: Date?

    static func parse(data: Data) throws -> GPXDocument {
        let delegate = GPXDocumentParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            throw parser.parserError ?? GPXImportService.ImportError.invalidGPX
        }

        return GPXDocument(
            metadataName: delegate.metadataName,
            metadataDescription: delegate.metadataDescription,
            routeName: delegate.routeName,
            routeDescription: delegate.routeDescription,
            trackName: delegate.trackName,
            trackDescription: delegate.trackDescription,
            trackPoints: delegate.trackPoints,
            routePoints: delegate.routePoints,
            createdAt: delegate.createdAt,
            updatedAt: delegate.updatedAt
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""

        switch elementName {
        case "metadata":
            contextStack.append(.metadata)
        case "rte":
            contextStack.append(.route)
        case "trk":
            contextStack.append(.track)
        case "rtept":
            currentRoutePoint = point(from: attributeDict)
        case "trkpt":
            currentTrackPoint = point(from: attributeDict)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name":
            assignName(text)
        case "desc":
            assignDescription(text)
        case "time":
            assignTime(text)
        case "ele":
            assignElevation(text)
        case "metadata", "rte", "trk":
            _ = contextStack.popLast()
        case "rtept":
            if let point = currentRoutePoint {
                routePoints.append(point)
            }
            currentRoutePoint = nil
        case "trkpt":
            if let point = currentTrackPoint {
                trackPoints.append(point)
            }
            currentTrackPoint = nil
        default:
            break
        }

        currentText = ""
    }

    private func assignName(_ text: String) {
        guard !text.isEmpty, currentRoutePoint == nil, currentTrackPoint == nil else {
            return
        }

        switch contextStack.last {
        case .metadata:
            metadataName = metadataName ?? text
        case .route:
            routeName = routeName ?? text
        case .track:
            trackName = trackName ?? text
        case .none:
            break
        }
    }

    private func assignDescription(_ text: String) {
        guard !text.isEmpty, currentRoutePoint == nil, currentTrackPoint == nil else {
            return
        }

        switch contextStack.last {
        case .metadata:
            metadataDescription = metadataDescription ?? text
        case .route:
            routeDescription = routeDescription ?? text
        case .track:
            trackDescription = trackDescription ?? text
        case .none:
            break
        }
    }

    private func assignTime(_ text: String) {
        guard !text.isEmpty else {
            return
        }

        let timestamp = ISO8601DateFormatter.fractional.date(from: text) ?? ISO8601DateFormatter.standard.date(from: text)

        if let timestamp {
            if currentTrackPoint != nil {
                currentTrackPoint?.timestamp = timestamp
                updatedAt = timestamp
            } else if currentRoutePoint != nil {
                currentRoutePoint?.timestamp = timestamp
                updatedAt = timestamp
            } else if contextStack.last == .metadata {
                createdAt = createdAt ?? timestamp
                updatedAt = timestamp
            }
        }
    }

    private func assignElevation(_ text: String) {
        guard let elevation = Double(text) else {
            return
        }

        if currentTrackPoint != nil {
            currentTrackPoint?.elevation = elevation
        } else if currentRoutePoint != nil {
            currentRoutePoint?.elevation = elevation
        }
    }

    private func point(from attributes: [String: String]) -> GPXTrackPoint? {
        guard let latitudeText = attributes["lat"],
              let longitudeText = attributes["lon"],
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }

        return GPXTrackPoint(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            elevation: nil,
            timestamp: nil
        )
    }
}

enum RoutePolylineCodec {
    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> String {
        guard !coordinates.isEmpty else {
            return ""
        }

        var encodedPolyline = ""
        var previousLatitude = 0
        var previousLongitude = 0

        for coordinate in coordinates {
            let latitude = Int((coordinate.latitude * 100_000).rounded())
            let longitude = Int((coordinate.longitude * 100_000).rounded())

            encodedPolyline += encodeComponent(latitude - previousLatitude)
            encodedPolyline += encodeComponent(longitude - previousLongitude)

            previousLatitude = latitude
            previousLongitude = longitude
        }

        return encodedPolyline
    }

    static func decode(_ encodedPolyline: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(encodedPolyline.utf8)
        guard !bytes.isEmpty else {
            return []
        }

        var coordinates: [CLLocationCoordinate2D] = []
        var index = 0
        var latitude = 0
        var longitude = 0

        while index < bytes.count {
            guard let decodedLatitude = decodeComponent(from: bytes, index: &index),
                  let decodedLongitude = decodeComponent(from: bytes, index: &index) else {
                break
            }

            latitude += decodedLatitude
            longitude += decodedLongitude

            coordinates.append(
                CLLocationCoordinate2D(
                    latitude: Double(latitude) / 100_000,
                    longitude: Double(longitude) / 100_000
                )
            )
        }

        return coordinates
    }

    static func firstCoordinate(in encodedPolyline: String) -> CLLocationCoordinate2D? {
        let bytes = Array(encodedPolyline.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0

        guard let decodedLatitude = decodeComponent(from: bytes, index: &index),
              let decodedLongitude = decodeComponent(from: bytes, index: &index) else {
            return nil
        }

        latitude += decodedLatitude
        longitude += decodedLongitude

        return CLLocationCoordinate2D(
            latitude: Double(latitude) / 100_000,
            longitude: Double(longitude) / 100_000
        )
    }

    private static func encodeComponent(_ value: Int) -> String {
        var shiftedValue = value < 0 ? ~(value << 1) : (value << 1)
        var output = ""

        while shiftedValue >= 0x20 {
            let nextValue = (0x20 | (shiftedValue & 0x1F)) + 63
            output.append(Character(UnicodeScalar(nextValue)!))
            shiftedValue >>= 5
        }

        output.append(Character(UnicodeScalar(shiftedValue + 63)!))
        return output
    }

    private static func decodeComponent(from bytes: [UInt8], index: inout Int) -> Int? {
        guard index < bytes.count else {
            return nil
        }

        var result = 0
        var shift = 0

        while index < bytes.count {
            let byte = Int(bytes[index]) - 63
            index += 1
            result |= (byte & 0x1F) << shift
            shift += 5

            if byte < 0x20 {
                return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
        }

        return nil
    }
}

extension CLLocationCoordinate2D {
    var formattedLabel: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

extension CLPlacemark {
    func routeStartLocationDetails(preferredName: String?, fallbackName: String) -> RouteStartLocationDetails {
        let park = areasOfInterest?
            .compactMap { $0.trimmed.nilIfEmpty }
            .first ?? ""

        let county = subAdministrativeArea?.trimmed ?? ""

        let city = [
            locality,
            subLocality,
            name
        ]
        .compactMap { $0?.trimmed.nilIfEmpty }
        .first ?? fallbackName

        let state = [
            administrativeArea,
            subAdministrativeArea
        ]
        .compactMap { $0?.trimmed.nilIfEmpty }
        .first ?? ""

        let country = country?.trimmed ?? ""

        let region = [
            subLocality?.trimmed.nilIfEmpty,
            locality?.trimmed.nilIfEmpty,
            county.trimmed.nilIfEmpty,
            park.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .first(where: {
            let token = $0.routeLocationToken
            return !token.isEmpty &&
                token != city.routeLocationToken &&
                token != state.routeLocationToken &&
                token != country.routeLocationToken
        }) ?? ""

        let referenceName = preferredName?.trimmed.nilIfEmpty
            ?? [park.trimmed.nilIfEmpty, city.trimmed.nilIfEmpty, state.trimmed.nilIfEmpty]
                .compactMap { $0 }
                .joined(separator: ", ")
                .nilIfEmpty
            ?? fallbackName

        return RouteStartLocationDetails(
            referenceName: referenceName,
            regionName: region,
            parkName: park,
            countyName: county,
            cityName: city,
            stateName: state,
            countryName: country
        )
    }
}

private extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension String {
    var normalizedSurfaceTokens: String {
        trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
    }
}
