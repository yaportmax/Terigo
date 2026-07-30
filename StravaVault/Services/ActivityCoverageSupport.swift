import CoreLocation
import Foundation

struct ActivityCoverageInput: Sendable {
    let activityKey: String
    let name: String
    let sportTitle: String
    let startDate: Date
    let distanceMeters: Double
    let elevationGainMeters: Double
    let displayLocation: String
    let country: String
    let normalizedStateDisplayName: String
    let startParkName: String?
    let city: String
    let activityGeometryPolyline: String

    init(activity: ActivityRecord) {
        activityKey = activity.activityKey
        name = activity.name
        sportTitle = activity.sportDisplayName
        startDate = activity.startDate
        distanceMeters = activity.distanceMeters
        elevationGainMeters = activity.elevationGainMeters
        displayLocation = activity.displayLocation
        country = activity.country
        normalizedStateDisplayName = activity.normalizedStateDisplayName
        startParkName = activity.startParkName
        city = activity.city
        activityGeometryPolyline = activity.activityGeometryPolyline
    }
}

struct ActivityCoverageLine: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
}

struct ActivityCoverageHighlight: Identifiable {
    let activityKey: String
    let name: String
    let sportTitle: String
    let startDate: Date
    let location: String
    let newCoverageMeters: Double

    var id: String { activityKey }
}

struct ExplorerTileCoordinate: Hashable, Identifiable, Comparable {
    let x: Int
    let y: Int

    var id: String { "\(x):\(y)" }

    static func < (lhs: ExplorerTileCoordinate, rhs: ExplorerTileCoordinate) -> Bool {
        if lhs.y == rhs.y {
            return lhs.x < rhs.x
        }

        return lhs.y < rhs.y
    }
}

struct ActivityExplorerTile: Identifiable {
    let coordinate: ExplorerTileCoordinate
    let visitCount: Int
    let polygon: [CLLocationCoordinate2D]

    var id: String { coordinate.id }
}

struct ActivityExplorerSquareSummary {
    let sideLength: Int
    let tileCount: Int
    let anchorTile: ExplorerTileCoordinate?
    let tiles: [ExplorerTileCoordinate]
    let nextExpansionMissingTiles: [ExplorerTileCoordinate]
}

struct ActivityExplorerClusterSummary {
    let tileCount: Int
    let tiles: [ExplorerTileCoordinate]
}

struct ActivityCoveragePeriodSnapshot: Identifiable {
    let id: String
    let title: String
    let year: Int?
    let activitiesCount: Int
    let activeDayCount: Int
    let totalDistanceMeters: Double
    let totalClimbMeters: Double
    let uniqueDistanceMeters: Double
    let visitedTileCount: Int
    let explorerTiles: [ActivityExplorerTile]
    let coverageLines: [ActivityCoverageLine]
    let activitiesWithNewCoverage: [ActivityCoverageHighlight]
    let bestSquare: ActivityExplorerSquareSummary
    let bestCluster: ActivityExplorerClusterSummary
    let eddingtonNumber: Int
    let longestStreakDays: Int
    let countryCount: Int
    let stateCount: Int
    let parkCount: Int
    let cityCount: Int

    var compactSummary: String {
        "\(RouteDisplayFormatter.compactCount(visitedTileCount)) tiles • \(bestSquare.sideLength)x\(bestSquare.sideLength) square • \(RouteDisplayFormatter.compactCount(bestCluster.tileCount)) cluster"
    }
}

struct ActivityCoverageSnapshot {
    let allTime: ActivityCoveragePeriodSnapshot
    let yearly: [ActivityCoveragePeriodSnapshot]
    let recentNewCoverageMeters: Double

    var totalActivities: Int { allTime.activitiesCount }
    var totalDistanceMeters: Double { allTime.totalDistanceMeters }
    var uniqueDistanceMeters: Double { allTime.uniqueDistanceMeters }
    var visitedTileCount: Int { allTime.visitedTileCount }
    var activitiesWithNewCoverage: [ActivityCoverageHighlight] { allTime.activitiesWithNewCoverage }
    var coverageLines: [ActivityCoverageLine] { allTime.coverageLines }
    var periods: [ActivityCoveragePeriodSnapshot] { [allTime] + yearly }
}

struct ActivityCoverageComputation {
    let snapshot: ActivityCoverageSnapshot
    let newCoverageByActivityKey: [String: Double]
}

enum ActivityCoverageSupport {
    private static let recentWindowDays = 30
    private static let tileSizeMeters = 1_609.344
    private static let tileSamplingStepMeters = 200.0
    private static let earthRadiusMeters = 6_378_137.0

    static func compute(from activities: [ActivityRecord]) -> ActivityCoverageComputation {
        compute(from: activities.map(ActivityCoverageInput.init))
    }

    static func compute(from activities: [ActivityCoverageInput]) -> ActivityCoverageComputation {
        let preparedActivities = activities
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.activityKey < rhs.activityKey
                }

                return lhs.startDate < rhs.startDate
            }
            .map(prepare(activity:))

        let allTimeAnalysis = analyze(
            preparedActivities,
            title: "All Time",
            year: nil
        )

        let yearlyAnalyses = Dictionary(grouping: preparedActivities) {
            Calendar.current.component(.year, from: $0.activity.startDate)
        }
        .keys
        .sorted(by: >)
        .compactMap { year -> PeriodAnalysis? in
            guard let groupedActivities = Dictionary(grouping: preparedActivities, by: { Calendar.current.component(.year, from: $0.activity.startDate) })[year] else {
                return nil
            }
            return analyze(groupedActivities, title: "\(year)", year: year)
        }

        let recentCutoff = Calendar.current.date(byAdding: .day, value: -recentWindowDays, to: .now) ?? .distantPast
        let recentNewCoverageMeters = allTimeAnalysis.snapshot.activitiesWithNewCoverage
            .filter { $0.startDate >= recentCutoff }
            .reduce(0) { $0 + $1.newCoverageMeters }

        return ActivityCoverageComputation(
            snapshot: ActivityCoverageSnapshot(
                allTime: allTimeAnalysis.snapshot,
                yearly: yearlyAnalyses.map(\.snapshot),
                recentNewCoverageMeters: recentNewCoverageMeters
            ),
            newCoverageByActivityKey: allTimeAnalysis.newCoverageByActivityKey
        )
    }

    private struct PreparedSegment {
        let token: String
        let distanceMeters: Double
    }

    private struct PreparedActivity {
        let activity: ActivityCoverageInput
        let segments: [PreparedSegment]
        let tileSet: Set<ExplorerTileCoordinate>
        let coverageLine: ActivityCoverageLine?
    }

    private struct PeriodAnalysis {
        let snapshot: ActivityCoveragePeriodSnapshot
        let newCoverageByActivityKey: [String: Double]
    }

    private struct TileBoundingBox {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
    }

    private static func analyze(
        _ preparedActivities: [PreparedActivity],
        title: String,
        year: Int?
    ) -> PeriodAnalysis {
        guard !preparedActivities.isEmpty else {
            return PeriodAnalysis(
                snapshot: ActivityCoveragePeriodSnapshot(
                    id: year.map { "year-\($0)" } ?? "all-time",
                    title: title,
                    year: year,
                    activitiesCount: 0,
                    activeDayCount: 0,
                    totalDistanceMeters: 0,
                    totalClimbMeters: 0,
                    uniqueDistanceMeters: 0,
                    visitedTileCount: 0,
                    explorerTiles: [],
                    coverageLines: [],
                    activitiesWithNewCoverage: [],
                    bestSquare: ActivityExplorerSquareSummary(
                        sideLength: 0,
                        tileCount: 0,
                        anchorTile: nil,
                        tiles: [],
                        nextExpansionMissingTiles: []
                    ),
                    bestCluster: ActivityExplorerClusterSummary(tileCount: 0, tiles: []),
                    eddingtonNumber: 0,
                    longestStreakDays: 0,
                    countryCount: 0,
                    stateCount: 0,
                    parkCount: 0,
                    cityCount: 0
                ),
                newCoverageByActivityKey: [:]
            )
        }

        var seenSegments = Set<String>()
        var tileVisitCounts: [ExplorerTileCoordinate: Int] = [:]
        var newCoverageByActivityKey: [String: Double] = [:]
        var uniqueDistanceMeters = 0.0

        for preparedActivity in preparedActivities {
            for tile in preparedActivity.tileSet {
                tileVisitCounts[tile, default: 0] += 1
            }

            var activityNewCoverageMeters = 0.0
            for segment in preparedActivity.segments {
                if seenSegments.insert(segment.token).inserted {
                    uniqueDistanceMeters += segment.distanceMeters
                    activityNewCoverageMeters += segment.distanceMeters
                }
            }

            newCoverageByActivityKey[preparedActivity.activity.activityKey] = activityNewCoverageMeters
        }

        let visitedTiles = Set(tileVisitCounts.keys)
        let explorerTiles = visitedTiles
            .sorted()
            .map { tile in
                ActivityExplorerTile(
                    coordinate: tile,
                    visitCount: tileVisitCounts[tile, default: 0],
                    polygon: tilePolygon(for: tile)
                )
            }

        let bestSquare = bestSquareSummary(in: visitedTiles)
        let bestCluster = bestClusterSummary(in: visitedTiles)
        let highlights = preparedActivities
            .compactMap { preparedActivity -> ActivityCoverageHighlight? in
                let newCoverageMeters = newCoverageByActivityKey[preparedActivity.activity.activityKey] ?? 0
                guard newCoverageMeters > 0 else {
                    return nil
                }

                return ActivityCoverageHighlight(
                    activityKey: preparedActivity.activity.activityKey,
                    name: preparedActivity.activity.name,
                    sportTitle: preparedActivity.activity.sportTitle,
                    startDate: preparedActivity.activity.startDate,
                    location: preparedActivity.activity.displayLocation,
                    newCoverageMeters: newCoverageMeters
                )
            }
            .sorted { lhs, rhs in
                if abs(lhs.newCoverageMeters - rhs.newCoverageMeters) > 0.5 {
                    return lhs.newCoverageMeters > rhs.newCoverageMeters
                }
                if lhs.startDate == rhs.startDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.startDate > rhs.startDate
            }

        let activities = preparedActivities.map(\.activity)
        let activeDayCount = Set(activities.map { Calendar.current.startOfDay(for: $0.startDate) }).count
        let totalDistanceMeters = activities.reduce(0) { $0 + max($1.distanceMeters, 0) }
        let totalClimbMeters = activities.reduce(0) { $0 + max($1.elevationGainMeters, 0) }
        let coverageLines = preparedActivities.compactMap(\.coverageLine)
        let countries = distinctTokens(from: activities.map(\.country))
        let states = distinctTokens(from: activities.map(\.normalizedStateDisplayName))
        let parks = distinctTokens(from: activities.compactMap { $0.startParkName })
        let cities = distinctTokens(from: activities.map(\.city))

        let snapshot = ActivityCoveragePeriodSnapshot(
            id: year.map { "year-\($0)" } ?? "all-time",
            title: title,
            year: year,
            activitiesCount: activities.count,
            activeDayCount: activeDayCount,
            totalDistanceMeters: totalDistanceMeters,
            totalClimbMeters: totalClimbMeters,
            uniqueDistanceMeters: uniqueDistanceMeters,
            visitedTileCount: visitedTiles.count,
            explorerTiles: explorerTiles,
            coverageLines: coverageLines,
            activitiesWithNewCoverage: highlights,
            bestSquare: bestSquare,
            bestCluster: bestCluster,
            eddingtonNumber: eddingtonNumber(for: activities),
            longestStreakDays: longestStreakDays(for: activities),
            countryCount: countries.count,
            stateCount: states.count,
            parkCount: parks.count,
            cityCount: cities.count
        )

        return PeriodAnalysis(snapshot: snapshot, newCoverageByActivityKey: newCoverageByActivityKey)
    }

    private static func prepare(activity: ActivityCoverageInput) -> PreparedActivity {
        let coordinates = RoutePolylineCodec.decode(activity.activityGeometryPolyline)
        let segments = zip(coordinates, coordinates.dropFirst()).compactMap { start, end -> PreparedSegment? in
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            guard distance.isFinite, distance > 0 else {
                return nil
            }

            return PreparedSegment(
                token: segmentToken(start, end),
                distanceMeters: distance
            )
        }

        let coverageLine = coordinates.count > 1
            ? ActivityCoverageLine(
                id: activity.activityKey,
                coordinates: RouteMapboxGeometry.simplifiedOfflineLineCoordinates(
                    for: coordinates,
                    maximumPointCount: 180
                )
            )
            : nil

        return PreparedActivity(
            activity: activity,
            segments: segments,
            tileSet: visitedTiles(for: coordinates),
            coverageLine: coverageLine
        )
    }

    private static func visitedTiles(for coordinates: [CLLocationCoordinate2D]) -> Set<ExplorerTileCoordinate> {
        guard let firstCoordinate = coordinates.first else {
            return []
        }

        var visitedTiles: Set<ExplorerTileCoordinate> = [tileCoordinate(for: firstCoordinate)]

        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            guard distance.isFinite, distance > 0 else {
                continue
            }

            let steps = max(Int(ceil(distance / tileSamplingStepMeters)), 1)
            let projectedStart = mercatorPoint(for: start)
            let projectedEnd = mercatorPoint(for: end)

            for step in 0...steps {
                let progress = Double(step) / Double(steps)
                let interpolated = CGPoint(
                    x: projectedStart.x + ((projectedEnd.x - projectedStart.x) * progress),
                    y: projectedStart.y + ((projectedEnd.y - projectedStart.y) * progress)
                )
                visitedTiles.insert(tileCoordinate(forMercatorPoint: interpolated))
            }
        }

        return visitedTiles
    }

    private static func bestSquareSummary(in tiles: Set<ExplorerTileCoordinate>) -> ActivityExplorerSquareSummary {
        guard let bounds = tileBounds(for: tiles), !tiles.isEmpty else {
            return ActivityExplorerSquareSummary(
                sideLength: 0,
                tileCount: 0,
                anchorTile: nil,
                tiles: [],
                nextExpansionMissingTiles: []
            )
        }

        var bestAnchor: ExplorerTileCoordinate?
        var bestSide = 0

        for x in bounds.minX...bounds.maxX {
            for y in bounds.minY...bounds.maxY {
                let anchor = ExplorerTileCoordinate(x: x, y: y)
                let side = largestSquareSide(from: anchor, in: tiles, maxSide: max(bounds.maxX - x, bounds.maxY - y) + 1)
                if side > bestSide {
                    bestSide = side
                    bestAnchor = anchor
                }
            }
        }

        guard let bestAnchor, bestSide > 0 else {
            return ActivityExplorerSquareSummary(
                sideLength: 0,
                tileCount: 0,
                anchorTile: nil,
                tiles: [],
                nextExpansionMissingTiles: []
            )
        }

        let squareTiles = squareTiles(anchor: bestAnchor, sideLength: bestSide)
        let missingTiles = nextSquareMissingTiles(in: tiles, currentBestSide: bestSide, bounds: bounds)

        return ActivityExplorerSquareSummary(
            sideLength: bestSide,
            tileCount: squareTiles.count,
            anchorTile: bestAnchor,
            tiles: squareTiles,
            nextExpansionMissingTiles: missingTiles
        )
    }

    private static func bestClusterSummary(in tiles: Set<ExplorerTileCoordinate>) -> ActivityExplorerClusterSummary {
        guard !tiles.isEmpty else {
            return ActivityExplorerClusterSummary(tileCount: 0, tiles: [])
        }

        var remainingTiles = tiles
        var bestCluster: [ExplorerTileCoordinate] = []

        while let startTile = remainingTiles.first {
            var queue = [startTile]
            var index = 0
            var cluster: [ExplorerTileCoordinate] = []
            remainingTiles.remove(startTile)

            while index < queue.count {
                let current = queue[index]
                index += 1
                cluster.append(current)

                for neighbor in orthogonalNeighbors(of: current) where remainingTiles.contains(neighbor) {
                    remainingTiles.remove(neighbor)
                    queue.append(neighbor)
                }
            }

            if cluster.count > bestCluster.count {
                bestCluster = cluster
            }
        }

        return ActivityExplorerClusterSummary(
            tileCount: bestCluster.count,
            tiles: bestCluster.sorted()
        )
    }

    private static func eddingtonNumber(for activities: [ActivityCoverageInput]) -> Int {
        let dailyDistances = activities
            .map { $0.distanceMeters / 1_000.0 }
            .sorted(by: >)

        var eddington = 0
        for (index, distanceInKilometers) in dailyDistances.enumerated() where distanceInKilometers >= Double(index + 1) {
            eddington = index + 1
        }

        return eddington
    }

    private static func longestStreakDays(for activities: [ActivityCoverageInput]) -> Int {
        let days = Set(activities.map { Calendar.current.startOfDay(for: $0.startDate) }).sorted()
        guard let firstDay = days.first else {
            return 0
        }

        var longestStreak = 1
        var currentStreak = 1
        var previousDay = firstDay

        for day in days.dropFirst() {
            let delta = Calendar.current.dateComponents([.day], from: previousDay, to: day).day ?? 0
            if delta == 1 {
                currentStreak += 1
                longestStreak = max(longestStreak, currentStreak)
            } else {
                currentStreak = 1
            }
            previousDay = day
        }

        return longestStreak
    }

    private static func distinctTokens(from values: [String]) -> Set<String> {
        Set(values.compactMap { value in
            let trimmed = value.trimmed.nilIfEmpty
            return trimmed?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
    }

    private static func distinctTokens(from values: [String?]) -> Set<String> {
        distinctTokens(from: values.compactMap { $0 })
    }

    private static func tileBounds(for tiles: Set<ExplorerTileCoordinate>) -> TileBoundingBox? {
        guard let firstTile = tiles.first else {
            return nil
        }

        return tiles.dropFirst().reduce(
            TileBoundingBox(minX: firstTile.x, maxX: firstTile.x, minY: firstTile.y, maxY: firstTile.y)
        ) { bounds, tile in
            TileBoundingBox(
                minX: min(bounds.minX, tile.x),
                maxX: max(bounds.maxX, tile.x),
                minY: min(bounds.minY, tile.y),
                maxY: max(bounds.maxY, tile.y)
            )
        }
    }

    private static func largestSquareSide(
        from anchor: ExplorerTileCoordinate,
        in tiles: Set<ExplorerTileCoordinate>,
        maxSide: Int
    ) -> Int {
        var currentSide = 0

        for candidateSide in 1...maxSide {
            if squareExists(anchor: anchor, sideLength: candidateSide, in: tiles) {
                currentSide = candidateSide
            } else {
                break
            }
        }

        return currentSide
    }

    private static func squareExists(
        anchor: ExplorerTileCoordinate,
        sideLength: Int,
        in tiles: Set<ExplorerTileCoordinate>
    ) -> Bool {
        for x in anchor.x..<(anchor.x + sideLength) {
            for y in anchor.y..<(anchor.y + sideLength) {
                if !tiles.contains(ExplorerTileCoordinate(x: x, y: y)) {
                    return false
                }
            }
        }

        return true
    }

    private static func squareTiles(anchor: ExplorerTileCoordinate, sideLength: Int) -> [ExplorerTileCoordinate] {
        guard sideLength > 0 else {
            return []
        }

        var tiles: [ExplorerTileCoordinate] = []
        tiles.reserveCapacity(sideLength * sideLength)

        for x in anchor.x..<(anchor.x + sideLength) {
            for y in anchor.y..<(anchor.y + sideLength) {
                tiles.append(ExplorerTileCoordinate(x: x, y: y))
            }
        }

        return tiles.sorted()
    }

    private static func nextSquareMissingTiles(
        in tiles: Set<ExplorerTileCoordinate>,
        currentBestSide: Int,
        bounds: TileBoundingBox
    ) -> [ExplorerTileCoordinate] {
        let targetSide = max(currentBestSide + 1, 1)
        var bestMissingTiles: [ExplorerTileCoordinate] = []
        var bestMissingCount = Int.max

        let xRange = (bounds.minX - 1)...bounds.maxX
        let yRange = (bounds.minY - 1)...bounds.maxY

        for x in xRange {
            for y in yRange {
                let anchor = ExplorerTileCoordinate(x: x, y: y)
                let missingTiles = missingTilesForSquare(anchor: anchor, sideLength: targetSide, in: tiles)
                guard missingTiles.count < bestMissingCount else {
                    continue
                }

                bestMissingCount = missingTiles.count
                bestMissingTiles = missingTiles

                if bestMissingCount == 0 {
                    return []
                }
            }
        }

        return Array(bestMissingTiles.prefix(12))
    }

    private static func missingTilesForSquare(
        anchor: ExplorerTileCoordinate,
        sideLength: Int,
        in tiles: Set<ExplorerTileCoordinate>
    ) -> [ExplorerTileCoordinate] {
        guard sideLength > 0 else {
            return []
        }

        var missingTiles: [ExplorerTileCoordinate] = []
        for x in anchor.x..<(anchor.x + sideLength) {
            for y in anchor.y..<(anchor.y + sideLength) {
                let tile = ExplorerTileCoordinate(x: x, y: y)
                if !tiles.contains(tile) {
                    missingTiles.append(tile)
                }
            }
        }

        return missingTiles.sorted()
    }

    private static func orthogonalNeighbors(of tile: ExplorerTileCoordinate) -> [ExplorerTileCoordinate] {
        [
            ExplorerTileCoordinate(x: tile.x + 1, y: tile.y),
            ExplorerTileCoordinate(x: tile.x - 1, y: tile.y),
            ExplorerTileCoordinate(x: tile.x, y: tile.y + 1),
            ExplorerTileCoordinate(x: tile.x, y: tile.y - 1)
        ]
    }

    private static func segmentToken(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> String {
        let lhsKey = coordinateKey(lhs)
        let rhsKey = coordinateKey(rhs)
        return lhsKey < rhsKey ? "\(lhsKey)|\(rhsKey)" : "\(rhsKey)|\(lhsKey)"
    }

    private static func coordinateKey(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func mercatorPoint(for coordinate: CLLocationCoordinate2D) -> CGPoint {
        let longitude = coordinate.longitude * .pi / 180
        let clampedLatitude = min(max(coordinate.latitude, -85.05112878), 85.05112878)
        let latitude = clampedLatitude * .pi / 180

        return CGPoint(
            x: earthRadiusMeters * longitude,
            y: earthRadiusMeters * log(tan(.pi / 4 + latitude / 2))
        )
    }

    private static func coordinate(forMercatorPoint point: CGPoint) -> CLLocationCoordinate2D {
        let longitude = (point.x / earthRadiusMeters) * 180 / .pi
        let latitude = (2 * atan(exp(point.y / earthRadiusMeters)) - .pi / 2) * 180 / .pi
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func tileCoordinate(for coordinate: CLLocationCoordinate2D) -> ExplorerTileCoordinate {
        tileCoordinate(forMercatorPoint: mercatorPoint(for: coordinate))
    }

    private static func tileCoordinate(forMercatorPoint point: CGPoint) -> ExplorerTileCoordinate {
        ExplorerTileCoordinate(
            x: Int(floor(point.x / tileSizeMeters)),
            y: Int(floor(point.y / tileSizeMeters))
        )
    }

    private static func tilePolygon(for tile: ExplorerTileCoordinate) -> [CLLocationCoordinate2D] {
        let minX = Double(tile.x) * tileSizeMeters
        let minY = Double(tile.y) * tileSizeMeters
        let maxX = minX + tileSizeMeters
        let maxY = minY + tileSizeMeters

        let bottomLeft = coordinate(forMercatorPoint: CGPoint(x: minX, y: minY))
        let bottomRight = coordinate(forMercatorPoint: CGPoint(x: maxX, y: minY))
        let topRight = coordinate(forMercatorPoint: CGPoint(x: maxX, y: maxY))
        let topLeft = coordinate(forMercatorPoint: CGPoint(x: minX, y: maxY))

        return [bottomLeft, bottomRight, topRight, topLeft, bottomLeft]
    }
}
