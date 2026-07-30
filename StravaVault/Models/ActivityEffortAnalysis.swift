import Foundation

enum ActivityEffortAnalysisVersion {
    static let current = 2
}

enum ActivityEffortValueSource: String, Codable, Sendable {
    case stream
    case detailedActivity
    case historicalWeather
    case derived
    case unavailable
}

struct ActivityEffortCoordinate: Codable, Sendable, Hashable {
    let latitude: Double
    let longitude: Double
}

struct ActivityEffortStreamCoverage: Codable, Sendable {
    let coordinateSampleCount: Int
    let distanceSampleCount: Int
    let altitudeSampleCount: Int
    let heartRateSampleCount: Int
    let speedSampleCount: Int
    let gradeSampleCount: Int
    let movingSampleCount: Int
    let temperatureSampleCount: Int
    let timeSampleCount: Int
}

struct ActivityEffortPercentiles: Codable, Sendable {
    let p10: Double?
    let p50: Double?
    let p90: Double?
}

struct ActivityEffortHeartRateSummary: Codable, Sendable {
    let averageBpm: Double?
    let maxBpm: Double?
    let sampleCount: Int
    let movingPercentiles: ActivityEffortPercentiles?
    let sustainedMedianBpm: Double?
    let source: ActivityEffortValueSource
    let sourceLabel: String
}

struct ActivityEffortSpeedSummary: Codable, Sendable {
    let averageMetersPerSecond: Double?
    let maxMetersPerSecond: Double?
    let sampleCount: Int
    let source: ActivityEffortValueSource
    let sourceLabel: String
}

struct ActivityEffortGradeSummary: Codable, Sendable {
    let averagePercent: Double?
    let minimumPercent: Double?
    let maximumPercent: Double?
    let sampleCount: Int
    let source: ActivityEffortValueSource
    let sourceLabel: String
}

struct ActivityEffortMovingSummary: Codable, Sendable {
    let movingFraction: Double?
    let movingSampleCount: Int
    let stationarySampleCount: Int
    let source: ActivityEffortValueSource
    let sourceLabel: String
}

struct ActivityEffortTemperatureSummary: Codable, Sendable {
    let averageCelsius: Double?
    let minimumCelsius: Double?
    let maximumCelsius: Double?
    let observedAt: Date?
    let sampleCount: Int
    let source: ActivityEffortValueSource
    let sourceLabel: String
}

struct ActivityEffortWindowMetrics: Codable, Sendable {
    let windowCount: Int
    let medianSpeedMetersPerSecond: Double?
    let medianHeartRateBpm: Double?
    let medianNormalizedHeartRate: Double?
    let efficiency: Double?
}

struct ActivityEffortNormalizationAnchors: Codable, Sendable {
    let lowBpm: Double?
    let highBpm: Double?
    let sampleCount: Int
}

struct ActivityEffortDerivedMetrics: Codable, Sendable {
    let flatEfficiency: Double?
    let climbEfficiency: Double?
    let decoupling: Double?
    let heatPenalty: Double?
    let effortAuthenticityScore: Double?
    let sustainedEffort: Double?
    let pacePercentile: Double?
    let athleteCoolBaselineFlatEfficiency: Double?
    let hotRunFlatEfficiency: Double?
}

struct ActivityEffortAnalysis: Codable, Sendable {
    let version: Int
    let activityKey: String
    let analyzedAt: Date
    let activityStartDate: Date
    let startCoordinate: ActivityEffortCoordinate?
    let distanceMeters: Double
    let movingTimeSeconds: Double
    let elapsedTimeSeconds: Double
    let elevationGainMeters: Double
    let heartRate: ActivityEffortHeartRateSummary
    let speed: ActivityEffortSpeedSummary
    let grade: ActivityEffortGradeSummary
    let moving: ActivityEffortMovingSummary
    let temperature: ActivityEffortTemperatureSummary
    let coverage: ActivityEffortStreamCoverage
    let normalizationAnchors: ActivityEffortNormalizationAnchors
    let flatWindows: ActivityEffortWindowMetrics
    let climbWindows: ActivityEffortWindowMetrics
    let firstThirdFlatWindows: ActivityEffortWindowMetrics
    let lastThirdFlatWindows: ActivityEffortWindowMetrics
    let derivedMetrics: ActivityEffortDerivedMetrics
    let notes: [String]

    var isCurrentVersion: Bool {
        version == ActivityEffortAnalysisVersion.current
    }

    var hasTemperatureFallback: Bool {
        temperature.source == .historicalWeather
    }
}

enum ActivityEffortAnalysisCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode(_ analysis: ActivityEffortAnalysis) -> String? {
        guard let data = try? encoder.encode(analysis) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func decode(_ blob: String?) -> ActivityEffortAnalysis? {
        guard let blob = blob?.trimmed.nilIfEmpty,
              let data = blob.data(using: .utf8) else {
            return nil
        }

        return try? decoder.decode(ActivityEffortAnalysis.self, from: data)
    }
}
