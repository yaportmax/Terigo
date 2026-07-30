import Foundation

struct ActivityForecastInput: Sendable {
    let activityKey: String
    let sourceKind: ActivitySourceKind
    let name: String
    let date: Date
    let sportKind: RouteSportKind
    let distanceMeters: Double
    let movingTime: Double
    let elapsedTime: Double
    let elevationGainMeters: Double
    let location: String
    let hasElevationProfile: Bool
    let hasHeartrate: Bool
    let averageHeartRateBpm: Double?
    let maxHeartRateBpm: Double?
    let effortAnalysis: ActivityEffortAnalysis?

    init(activity: ActivityRecord) {
        activityKey = activity.activityKey
        sourceKind = activity.sourceKind
        name = activity.name
        date = activity.startDate
        sportKind = activity.sportKind
        distanceMeters = activity.distanceMeters
        movingTime = activity.movingTime
        elapsedTime = activity.elapsedTime
        elevationGainMeters = activity.elevationGainMeters
        location = activity.startAddressText ?? activity.displayLocation.nilIfEmpty ?? "Location unavailable"
        hasElevationProfile = activity.elevationProfileBlob?.trimmed.nilIfEmpty != nil
        hasHeartrate = activity.hasHeartrate
        averageHeartRateBpm = activity.averageHeartRateBpm
        maxHeartRateBpm = activity.maxHeartRateBpm
        effortAnalysis = activity.effortAnalysis
    }

    var resolvedDuration: Double {
        if movingTime > 0 {
            return movingTime
        }
        return max(elapsedTime, 0)
    }
}

struct ActivityForecastPreset: Identifiable, Hashable, Sendable {
    let label: String
    let distanceMeters: Double

    var id: String { label }
}

enum ActivityRaceDistancePreset: String, CaseIterable, Identifiable, Sendable {
    case fiveK
    case tenK
    case halfMarathon
    case marathon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveK:
            return "5K"
        case .tenK:
            return "10K"
        case .halfMarathon:
            return "Half Marathon"
        case .marathon:
            return "Marathon"
        }
    }

    var shortTitle: String {
        switch self {
        case .fiveK:
            return "5K"
        case .tenK:
            return "10K"
        case .halfMarathon:
            return "Half"
        case .marathon:
            return "Marathon"
        }
    }

    var distanceMeters: Double {
        switch self {
        case .fiveK:
            return 5_000
        case .tenK:
            return 10_000
        case .halfMarathon:
            return 21_097.5
        case .marathon:
            return 42_195
        }
    }

    static func from(distanceMeters: Double) -> ActivityRaceDistancePreset? {
        allCases.min { lhs, rhs in
            abs(lhs.distanceMeters - distanceMeters) < abs(rhs.distanceMeters - distanceMeters)
        }
    }
}

enum ActivityForecastSignalAvailability: String, Sendable {
    case paceOnly
    case hrEnhanced
    case insufficient

    var title: String {
        switch self {
        case .paceOnly:
            return "Pace only"
        case .hrEnhanced:
            return "HR enhanced"
        case .insufficient:
            return "Insufficient signal"
        }
    }

    var caption: String {
        switch self {
        case .paceOnly:
            return "Built from road-running pace history without enough HR depth to unlock adaptation weighting."
        case .hrEnhanced:
            return "Built from road-running pace history, plus HR-derived zone estimates, flat pace-at-HR calibration, and adaptation scores."
        case .insufficient:
            return "There is not enough flat road-running evidence yet for a reliable road-race forecast."
        }
    }
}

enum ActivityForecastConfidence: String, Sendable {
    case high
    case medium
    case exploratory

    var title: String {
        switch self {
        case .high:
            return "High Confidence"
        case .medium:
            return "Good Confidence"
        case .exploratory:
            return "Exploratory"
        }
    }

    var caption: String {
        switch self {
        case .high:
            return "Deep benchmark support, solid backtesting, and the target distance sits inside your proven range."
        case .medium:
            return "Useful forecast, but the model is leaning on fewer benchmarks, lighter HR support, or a wider error band."
        case .exploratory:
            return "Directionally useful, but the model is extrapolating or leaning on sparse road-running history."
        }
    }
}

enum ActivityForecastComponentKind: String, CaseIterable, Identifiable, Sendable {
    case distanceCurve
    case localBenchmarks
    case criticalSpeed
    case hrRacePace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distanceCurve:
            return "Distance Curve"
        case .localBenchmarks:
            return "Local Benchmarks"
        case .criticalSpeed:
            return "Critical Speed"
        case .hrRacePace:
            return "HR Race Pace"
        }
    }
}

struct ActivityForecastComponentPrediction: Identifiable, Sendable {
    let kind: ActivityForecastComponentKind
    let predictedDuration: TimeInterval
    let weight: Double

    var id: String { kind.rawValue }
}

struct ActivityForecastComparableEffort: Identifiable, Sendable {
    let activityKey: String
    let name: String
    let date: Date
    let sportKind: RouteSportKind
    let distanceMeters: Double
    let duration: TimeInterval
    let location: String
    let projectedDurationAtTarget: TimeInterval
    let relevanceScore: Double
    let effortAuthenticityScore: Double?

    var id: String { activityKey }
}

struct ActivityForecastValidation: Sendable {
    let validationCount: Int
    let medianAbsolutePercentError: Double
    let p80AbsolutePercentError: Double
    let signedBias: Double
    let componentStats: [ActivityForecastValidationComponent]
}

struct ActivityForecastValidationComponent: Identifiable, Sendable {
    let kind: ActivityForecastComponentKind
    let validationCount: Int
    let medianAbsolutePercentError: Double
    let signedBias: Double

    var id: String { kind.rawValue }
}

struct ActivityForecastExplainabilityComponent: Identifiable, Sendable {
    let kind: ActivityForecastComponentKind
    let weight: Double
    let predictedDuration: TimeInterval
    let formula: String

    var id: String { kind.rawValue }
}

struct ActivityForecastExplainabilityFormula: Identifiable, Sendable {
    let label: String
    let expression: String

    var id: String { label }
}

struct ActivityForecastExplainabilitySnapshot: Sendable {
    let signalAvailability: ActivityForecastSignalAvailability
    let benchmarkCount: Int
    let targetDistanceSupportScore: Double
    let hrEnhanced: Bool
    let assumptions: [String]
    let confidenceReasons: [String]
    let formulas: [ActivityForecastExplainabilityFormula]
    let components: [ActivityForecastExplainabilityComponent]
}

struct ActivityForecastSnapshot: Sendable {
    let sportKind: RouteSportKind
    let racePreset: ActivityRaceDistancePreset
    let targetDistanceMeters: Double
    let predictedDuration: TimeInterval
    let lowerBoundDuration: TimeInterval
    let upperBoundDuration: TimeInterval
    let confidence: ActivityForecastConfidence
    let signalAvailability: ActivityForecastSignalAvailability
    let confidenceNotes: [String]
    let whyReasons: [String]
    let assumptions: [String]
    let sampleCount: Int
    let benchmarkCount: Int
    let distanceExponent: Double
    let terrainGamma: Double
    let supportScore: Double
    let recentFormMultiplier: Double
    let sourceWindowStart: Date?
    let sourceWindowEnd: Date?
    let componentPredictions: [ActivityForecastComponentPrediction]
    let comparableEfforts: [ActivityForecastComparableEffort]
    let validation: ActivityForecastValidation
    let explainability: ActivityForecastExplainabilitySnapshot

    var isExtrapolated: Bool {
        supportScore < 0.78
    }
}

enum ActivityAdaptationScoreKind: String, CaseIterable, Identifiable, Sendable {
    case aerobicEfficiency
    case durability
    case climbEfficiency
    case heatAdaptation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aerobicEfficiency:
            return "Aerobic Efficiency"
        case .durability:
            return "Durability"
        case .climbEfficiency:
            return "Climb Efficiency"
        case .heatAdaptation:
            return "Heat Adaptation"
        }
    }

    var shortTitle: String {
        switch self {
        case .aerobicEfficiency:
            return "Aerobic"
        case .durability:
            return "Durability"
        case .climbEfficiency:
            return "Climbing"
        case .heatAdaptation:
            return "Heat"
        }
    }

    var formulaDescription: String {
        switch self {
        case .aerobicEfficiency:
            return "Recent 42-day weighted median of flat speed divided by normalized HR, ranked against your trailing 365-day road-running history."
        case .durability:
            return "Recent 42-day weighted median of decoupling, inverted so lower fade scores higher against your trailing 365-day long-run history."
        case .climbEfficiency:
            return "Recent 42-day weighted median of climb speed divided by normalized HR, ranked against your trailing 365-day climb-session history."
        case .heatAdaptation:
            return "Recent 42-day weighted median of heat resilience, where smaller heat penalties score higher against your trailing 365-day hot-run history."
        }
    }
}

struct ActivityAdaptationTrendPoint: Identifiable, Sendable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct ActivityAdaptationScoreSnapshot: Identifiable, Sendable {
    let kind: ActivityAdaptationScoreKind
    let score: Int?
    let recentValue: Double?
    let baselineValue: Double?
    let qualifyingRecentCount: Int
    let requiredCount: Int
    let historyCount: Int
    let missingReasons: [String]
    let trend: [ActivityAdaptationTrendPoint]
    let formulaDescription: String
    let summary: String
    let valueLabel: String

    var id: String { kind.rawValue }
    var isAvailable: Bool { score != nil }

    var compactAvailabilityLabel: String {
        if isAvailable {
            return valueLabel
        }

        switch kind {
        case .aerobicEfficiency:
            return "Need HR flats"
        case .durability:
            return "Need long runs"
        case .climbEfficiency:
            return "Need climb data"
        case .heatAdaptation:
            return "Need temp data"
        }
    }
}

struct ActivityAdaptationSnapshot: Sendable {
    let recentWindowDays: Int
    let baselineWindowDays: Int
    let scores: [ActivityAdaptationScoreSnapshot]

    func score(for kind: ActivityAdaptationScoreKind) -> ActivityAdaptationScoreSnapshot? {
        scores.first(where: { $0.kind == kind })
    }
}

enum ActivityForecastSupport {
    static let assumptions = [
        "Flat road course",
        "Neutral temperature",
        "All-out race effort",
        "Minimal stoppage"
    ]

    static func availableSports(from activities: [ActivityRecord]) -> [RouteSportKind] {
        availableSports(from: activities.map(ActivityForecastInput.init))
    }

    static func availableSports(from activities: [ActivityForecastInput]) -> [RouteSportKind] {
        eligibleRoadRuns(from: activities).count >= 2 ? [.run] : []
    }

    static func availableRacePresets(from activities: [ActivityForecastInput]) -> [ActivityRaceDistancePreset] {
        availableSports(from: activities).isEmpty ? [] : ActivityRaceDistancePreset.allCases
    }

    static func roadRacePresets() -> [ActivityForecastPreset] {
        ActivityRaceDistancePreset.allCases.map { preset in
            ActivityForecastPreset(label: preset.shortTitle, distanceMeters: preset.distanceMeters)
        }
    }

    static func forecast(
        for sportKind: RouteSportKind,
        targetDistanceMeters: Double,
        activities: [ActivityRecord]
    ) -> ActivityForecastSnapshot? {
        forecast(
            for: sportKind,
            targetDistanceMeters: targetDistanceMeters,
            activities: activities.map(ActivityForecastInput.init)
        )
    }

    static func forecast(
        for sportKind: RouteSportKind,
        targetDistanceMeters: Double,
        activities: [ActivityForecastInput]
    ) -> ActivityForecastSnapshot? {
        guard sportKind == .run,
              let racePreset = ActivityRaceDistancePreset.from(distanceMeters: targetDistanceMeters) else {
            return nil
        }

        let roadRuns = eligibleRoadRuns(from: activities)
        guard roadRuns.count >= 2 else {
            return nil
        }

        let adaptation = adaptationSnapshot(from: activities)
        let anchors = heartRateAnchors(from: roadRuns)
        let zones = heartRateZoneModel(from: roadRuns, anchors: anchors)
        let targetNormalizedEffort = raceSustainableNormalizedEffortTarget(
            targetDistanceMeters: racePreset.distanceMeters,
            roadRuns: roadRuns
        )
        let raceHeartRateTarget = raceHeartRateTarget(
            targetDistanceMeters: racePreset.distanceMeters,
            targetNormalizedEffort: targetNormalizedEffort,
            anchors: anchors,
            zones: zones
        )
        let benchmarks = rankedBenchmarks(
            from: roadRuns,
            targetDistanceMeters: racePreset.distanceMeters,
            targetNormalizedEffort: raceHeartRateTarget.targetNormalizedEffort
        )
        let selectedBenchmarks = Array(benchmarks.prefix(10))
        let supportScore = distanceSupportScore(targetDistanceMeters: racePreset.distanceMeters, benchmarks: selectedBenchmarks)
        let signalAvailability = signalAvailability(
            for: selectedBenchmarks,
            anchors: anchors,
            adaptation: adaptation
        )
        let recentFormMultiplier = recentFormMultiplier(
            roadRuns: roadRuns,
            adaptation: adaptation
        )

        let distanceCurve = distanceCurvePrediction(
            from: selectedBenchmarks,
            targetDistanceMeters: racePreset.distanceMeters
        )
        let localBenchmarks = localBenchmarkPrediction(
            from: Array(selectedBenchmarks.prefix(6)),
            targetDistanceMeters: racePreset.distanceMeters,
            fallbackExponent: distanceCurve?.exponent ?? 1.06
        )
        let criticalSpeed = criticalSpeedPrediction(
            from: roadRuns,
            targetDistanceMeters: racePreset.distanceMeters
        )
        let hrRacePace = hrRacePacePrediction(
            from: roadRuns,
            targetDistanceMeters: racePreset.distanceMeters,
            raceHeartRateTarget: raceHeartRateTarget
        )

        let componentDurations = [
            (ActivityForecastComponentKind.distanceCurve, distanceCurve?.duration, distanceCurve?.exponent, distanceCurve?.formula),
            (ActivityForecastComponentKind.localBenchmarks, localBenchmarks?.duration, nil, localBenchmarks?.formula),
            (ActivityForecastComponentKind.criticalSpeed, criticalSpeed?.duration, nil, criticalSpeed?.formula),
            (ActivityForecastComponentKind.hrRacePace, hrRacePace?.duration, nil, hrRacePace?.formula)
        ]
        let validation = validation(
            using: roadRuns,
            targetDistanceMeters: racePreset.distanceMeters
        )
        let weights = componentWeights(
            validation: validation,
            signalAvailability: signalAvailability
        )

        let weightedComponents = componentDurations.compactMap { kind, duration, _, _ -> ActivityForecastComponentPrediction? in
            guard let duration else {
                return nil
            }
            return ActivityForecastComponentPrediction(
                kind: kind,
                predictedDuration: duration,
                weight: weights[kind] ?? 0
            )
        }
        guard !weightedComponents.isEmpty else {
            return nil
        }

        var predictedDuration = weightedGeometricMean(
            weightedComponents.map(\.predictedDuration),
            weights: weightedComponents.map(\.weight)
        )
        predictedDuration *= recentFormMultiplier
        if validation.validationCount >= 3 {
            predictedDuration *= max(0.94, min(1.06, 1 - validation.signedBias))
        }

        let errorBand = max(
            validation.p80AbsolutePercentError,
            validation.validationCount > 0 ? max(0.05, validation.medianAbsolutePercentError * 1.35) : 0.12
        )
        let lowerBoundDuration = predictedDuration * max(0.55, 1 - errorBand)
        let upperBoundDuration = predictedDuration * (1 + errorBand)
        let confidenceNotes = confidenceNotes(
            signalAvailability: signalAvailability,
            supportScore: supportScore,
            benchmarkCount: selectedBenchmarks.count,
            validation: validation,
            roadRuns: roadRuns,
            targetDistanceMeters: racePreset.distanceMeters
        )
        let confidence = forecastConfidence(
            benchmarkCount: selectedBenchmarks.count,
            supportScore: supportScore,
            validation: validation,
            signalAvailability: signalAvailability
        )
        let comparableEfforts = comparableEfforts(
            from: selectedBenchmarks,
            targetDistanceMeters: racePreset.distanceMeters,
            exponent: distanceCurve?.exponent ?? 1.06
        )
        let forecastReasons = whyReasons(
            signalAvailability: signalAvailability,
            recentFormMultiplier: recentFormMultiplier,
            supportScore: supportScore,
            adaptation: adaptation,
            comparableEfforts: comparableEfforts,
            raceHeartRateTarget: raceHeartRateTarget
        )
        let formulas = componentDurations.compactMap { kind, duration, _, formula -> ActivityForecastExplainabilityFormula? in
            guard duration != nil, let formula else {
                return nil
            }
            return ActivityForecastExplainabilityFormula(label: kind.title, expression: formula)
        } + [
            ActivityForecastExplainabilityFormula(
                label: "Recent Form",
                expression: "recent form multiplier = \(numberString(recentFormMultiplier))"
            ),
            ActivityForecastExplainabilityFormula(
                label: "Race HR Target",
                expression: raceHeartRateTarget.formula
            )
        ]
        let explainability = ActivityForecastExplainabilitySnapshot(
            signalAvailability: signalAvailability,
            benchmarkCount: selectedBenchmarks.count,
            targetDistanceSupportScore: supportScore,
            hrEnhanced: signalAvailability == .hrEnhanced,
            assumptions: assumptions,
            confidenceReasons: confidenceNotes,
            formulas: formulas,
            components: weightedComponents.map { component in
                ActivityForecastExplainabilityComponent(
                    kind: component.kind,
                    weight: component.weight,
                    predictedDuration: component.predictedDuration,
                    formula: formulas.first(where: { $0.label == component.kind.title })?.expression ?? ""
                )
            }
        )

        return ActivityForecastSnapshot(
            sportKind: .run,
            racePreset: racePreset,
            targetDistanceMeters: racePreset.distanceMeters,
            predictedDuration: predictedDuration,
            lowerBoundDuration: lowerBoundDuration,
            upperBoundDuration: upperBoundDuration,
            confidence: confidence,
            signalAvailability: signalAvailability,
            confidenceNotes: confidenceNotes,
            whyReasons: forecastReasons,
            assumptions: assumptions,
            sampleCount: roadRuns.count,
            benchmarkCount: selectedBenchmarks.count,
            distanceExponent: distanceCurve?.exponent ?? 1.06,
            terrainGamma: 0,
            supportScore: supportScore,
            recentFormMultiplier: recentFormMultiplier,
            sourceWindowStart: roadRuns.map(\.date).min(),
            sourceWindowEnd: roadRuns.map(\.date).max(),
            componentPredictions: weightedComponents,
            comparableEfforts: comparableEfforts,
            validation: validation,
            explainability: explainability
        )
    }

    static func adaptationSnapshot(from activities: [ActivityRecord]) -> ActivityAdaptationSnapshot {
        adaptationSnapshot(from: activities.map(ActivityForecastInput.init))
    }

    static func adaptationSnapshot(from activities: [ActivityForecastInput]) -> ActivityAdaptationSnapshot {
        let roadRuns = eligibleRoadRuns(from: activities)
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let recentCutoff = calendar.date(byAdding: .day, value: -42, to: now) ?? now
        let baselineCutoff = calendar.date(byAdding: .day, value: -365, to: now) ?? now
        let eligibilityCutoff = calendar.date(byAdding: .day, value: -180, to: now) ?? now

        let scores = ActivityAdaptationScoreKind.allCases.map { kind in
            adaptationScore(
                kind: kind,
                roadRuns: roadRuns,
                recentCutoff: recentCutoff,
                baselineCutoff: baselineCutoff,
                eligibilityCutoff: eligibilityCutoff
            )
        }

        return ActivityAdaptationSnapshot(
            recentWindowDays: 42,
            baselineWindowDays: 365,
            scores: scores
        )
    }
}

extension ActivityForecastSupport {
    struct BenchmarkSample {
        let input: ActivityForecastInput
        let duration: Double
        let distanceMeters: Double
        let effortAuthenticityScore: Double
        let flatEfficiency: Double?
        let decoupling: Double?
        let temperatureCelsius: Double?
        let relevanceScore: Double
    }

    struct DistanceCurvePrediction {
        let duration: Double
        let exponent: Double
        let formula: String
    }

    struct LocalBenchmarkPrediction {
        let duration: Double
        let formula: String
    }

    struct CriticalSpeedPrediction {
        let duration: Double
        let formula: String
    }

    struct HRRacePacePrediction {
        let duration: Double
        let formula: String
    }

    struct HeartRateZoneModel {
        let lowBpm: Double?
        let highBpm: Double?
        let thresholdNormalizedEffort: Double
        let thresholdBpm: Double?
    }

    struct RaceHeartRateTarget {
        let targetNormalizedEffort: Double
        let targetBpm: Double?
        let zoneLabel: String
        let formula: String
    }

    struct ForecastLinearRegressionFit {
        let intercept: Double
        let slope: Double
    }

    struct ScoreMetricSample {
        let date: Date
        let value: Double
        let weight: Double
    }

    static func eligibleRoadRuns(from activities: [ActivityForecastInput]) -> [ActivityForecastInput] {
        activities
            .filter { input in
                guard input.sportKind == .run,
                      input.distanceMeters >= 3_000,
                      input.resolvedDuration >= 15 * 60 else {
                    return false
                }
                let climbPerKilometer = input.elevationGainMeters / max(input.distanceMeters / 1_000, 1)
                return climbPerKilometer <= 55
            }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    return lhs.activityKey < rhs.activityKey
                }
                return lhs.date > rhs.date
            }
    }

    static func rankedBenchmarks(
        from roadRuns: [ActivityForecastInput],
        targetDistanceMeters: Double,
        targetNormalizedEffort: Double? = nil
    ) -> [BenchmarkSample] {
        let baselineExponent = 1.06
        let fastestProjectedTargetDuration = roadRuns.compactMap {
            projectedTargetDuration(
                for: $0,
                targetDistanceMeters: targetDistanceMeters,
                exponent: baselineExponent
            )
        }.min()

        return roadRuns.compactMap { input -> BenchmarkSample? in
            let duration = input.resolvedDuration
            guard input.distanceMeters > 0, duration > 0 else {
                return nil
            }

            let distanceRatio = distanceSimilarityRatio(input.distanceMeters, targetDistanceMeters)
            let recencyDays = max(0, Date().timeIntervalSince(input.date) / 86_400)
            let recencyScore = max(0.15, 1 - min(recencyDays / 365, 1))
            let effortAuthenticity = input.effortAnalysis?.derivedMetrics.effortAuthenticityScore
                ?? fallbackEffortAuthenticity(for: input)
            let flatEfficiency = input.effortAnalysis?.derivedMetrics.flatEfficiency
            let decoupling = input.effortAnalysis?.derivedMetrics.decoupling
            let temperature = input.effortAnalysis?.temperature.averageCelsius
            let performanceScore: Double
            if let projectedDuration = projectedTargetDuration(
                for: input,
                targetDistanceMeters: targetDistanceMeters,
                exponent: baselineExponent
            ),
               let fastestProjectedTargetDuration,
               fastestProjectedTargetDuration > 0 {
                performanceScore = max(0.35, min(1, fastestProjectedTargetDuration / projectedDuration))
            } else {
                performanceScore = 0.6
            }
            let raceIntensityMatch: Double
            if let targetNormalizedEffort,
               let sustainedEffort = input.effortAnalysis?.derivedMetrics.sustainedEffort {
                raceIntensityMatch = max(0.25, 1 - (abs(sustainedEffort - targetNormalizedEffort) / 0.30))
            } else {
                raceIntensityMatch = 0.6
            }
            let titleBoost = raceTitleBoost(for: input.name)
            let relevance = (0.30 * distanceRatio)
                + (0.14 * recencyScore)
                + (0.26 * effortAuthenticity)
                + (0.16 * performanceScore)
                + (0.14 * raceIntensityMatch)
                + titleBoost

            return BenchmarkSample(
                input: input,
                duration: duration,
                distanceMeters: input.distanceMeters,
                effortAuthenticityScore: effortAuthenticity,
                flatEfficiency: flatEfficiency,
                decoupling: decoupling,
                temperatureCelsius: temperature,
                relevanceScore: relevance
            )
        }
        .sorted { lhs, rhs in
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.input.date > rhs.input.date
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }
    }

    static func fallbackEffortAuthenticity(for input: ActivityForecastInput) -> Double {
        let distanceBonus = min(1, input.distanceMeters / 21_097.5) * 0.18
        let stopPenalty = input.elapsedTime > 0 ? max(0, (input.elapsedTime - input.movingTime) / input.elapsedTime) * 0.22 : 0
        let base = 0.52 + distanceBonus - stopPenalty
        return max(0.25, min(0.92, base))
    }

    static func raceTitleBoost(for title: String) -> Double {
        let normalized = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let keywords = ["race", "tempo", "threshold", "test", "tt", "interval", "benchmark", "pr", "pb"]
        return keywords.contains(where: { normalized.contains($0) }) ? 0.08 : 0
    }

    static func projectedTargetDuration(
        for input: ActivityForecastInput,
        targetDistanceMeters: Double,
        exponent: Double
    ) -> Double? {
        guard input.distanceMeters > 0, input.resolvedDuration > 0, targetDistanceMeters > 0 else {
            return nil
        }

        let ratio = max(0.1, targetDistanceMeters / input.distanceMeters)
        return input.resolvedDuration * pow(ratio, exponent)
    }

    static func defaultRaceNormalizedEffort(
        for targetDistanceMeters: Double
    ) -> Double {
        guard let preset = ActivityRaceDistancePreset.from(distanceMeters: targetDistanceMeters) else {
            return 0.92
        }

        switch preset {
        case .fiveK:
            return 0.99
        case .tenK:
            return 0.95
        case .halfMarathon:
            return 0.90
        case .marathon:
            return 0.86
        }
    }

    static func raceSustainableNormalizedEffortTarget(
        targetDistanceMeters: Double,
        roadRuns: [ActivityForecastInput]
    ) -> Double {
        let fallback = defaultRaceNormalizedEffort(for: targetDistanceMeters)
        let raceLikeSamples = roadRuns.compactMap { input -> WeightedSample? in
            guard let sustainedEffort = input.effortAnalysis?.derivedMetrics.sustainedEffort else {
                return nil
            }

            let authenticity = input.effortAnalysis?.derivedMetrics.effortAuthenticityScore
                ?? fallbackEffortAuthenticity(for: input)
            let raceLikeScore = min(1, authenticity + raceTitleBoost(for: input.name))
            guard raceLikeScore >= 0.62 else {
                return nil
            }

            let distanceSimilarity = distanceSimilarityRatio(input.distanceMeters, targetDistanceMeters)
            let recencyScore = min(1, recencyWeight(for: input.date) / 1.4)
            let blendedWeight = (0.5 * distanceSimilarity) + (0.3 * raceLikeScore) + (0.2 * recencyScore)
            let weight = max(1, Int((blendedWeight * 10).rounded()))
            return WeightedSample(value: sustainedEffort, weight: weight)
        }

        guard raceLikeSamples.count >= 2,
              let calibrated = weightedPercentile(raceLikeSamples, percentile: 0.6) else {
            return fallback
        }

        return max(fallback - 0.05, min(fallback + 0.08, calibrated))
    }

    static func heartRateZoneModel(
        from roadRuns: [ActivityForecastInput],
        anchors: ActivityEffortNormalizationAnchors
    ) -> HeartRateZoneModel {
        let thresholdCandidates = roadRuns.compactMap { input -> WeightedSample? in
            guard let sustainedEffort = input.effortAnalysis?.derivedMetrics.sustainedEffort else {
                return nil
            }

            let authenticity = input.effortAnalysis?.derivedMetrics.effortAuthenticityScore
                ?? fallbackEffortAuthenticity(for: input)
            guard authenticity >= 0.60 else {
                return nil
            }

            let thresholdDistanceSimilarity = max(
                distanceSimilarityRatio(input.distanceMeters, 10_000),
                distanceSimilarityRatio(input.distanceMeters, 21_097.5)
            )
            let weight = max(
                1,
                Int((((0.55 * authenticity) + (0.45 * thresholdDistanceSimilarity)) * 10).rounded())
            )
            return WeightedSample(value: sustainedEffort, weight: weight)
        }

        let thresholdNormalizedEffort = weightedPercentile(thresholdCandidates, percentile: 0.5) ?? 0.88
        return HeartRateZoneModel(
            lowBpm: anchors.lowBpm,
            highBpm: anchors.highBpm,
            thresholdNormalizedEffort: thresholdNormalizedEffort,
            thresholdBpm: denormalizedHeartRate(thresholdNormalizedEffort, anchors: anchors)
        )
    }

    static func raceHeartRateTarget(
        targetDistanceMeters: Double,
        targetNormalizedEffort: Double,
        anchors: ActivityEffortNormalizationAnchors,
        zones: HeartRateZoneModel
    ) -> RaceHeartRateTarget {
        let presetTitle = ActivityRaceDistancePreset.from(distanceMeters: targetDistanceMeters)?.shortTitle ?? "race"
        let zoneLabel: String
        let threshold = zones.thresholdNormalizedEffort
        if targetNormalizedEffort >= threshold + 0.03 {
            zoneLabel = "Zone 5"
        } else if targetNormalizedEffort >= threshold - 0.02 {
            zoneLabel = "Zone 4"
        } else if targetNormalizedEffort >= threshold - 0.10 {
            zoneLabel = "Zone 3"
        } else {
            zoneLabel = "Zone 2"
        }

        let bpm = denormalizedHeartRate(targetNormalizedEffort, anchors: anchors)
        let formula: String
        if let bpm, let thresholdBpm = zones.thresholdBpm {
            formula = "estimated \(presetTitle) race HR = \(numberString(bpm)) bpm in \(zoneLabel) (threshold ~ \(numberString(thresholdBpm)) bpm)"
        } else {
            formula = "estimated \(presetTitle) race effort = \(numberString(targetNormalizedEffort * 100))% of normalized HR in \(zoneLabel)"
        }

        return RaceHeartRateTarget(
            targetNormalizedEffort: targetNormalizedEffort,
            targetBpm: bpm,
            zoneLabel: zoneLabel,
            formula: formula
        )
    }

    static func denormalizedHeartRate(
        _ normalizedHeartRate: Double,
        anchors: ActivityEffortNormalizationAnchors
    ) -> Double? {
        guard let lowBpm = anchors.lowBpm,
              let highBpm = anchors.highBpm else {
            return nil
        }

        let span = max(15, highBpm - lowBpm)
        let clampedEffort = max(0, min(1.2, normalizedHeartRate))
        return lowBpm + (clampedEffort * span)
    }

    static func signalAvailability(
        for benchmarks: [BenchmarkSample],
        anchors: ActivityEffortNormalizationAnchors,
        adaptation: ActivityAdaptationSnapshot
    ) -> ActivityForecastSignalAvailability {
        guard benchmarks.count >= 4 else {
            return .insufficient
        }

        let hrQualifiedBenchmarks = benchmarks.filter { sample in
            sample.input.effortAnalysis?.derivedMetrics.flatEfficiency != nil &&
            sample.input.effortAnalysis?.derivedMetrics.effortAuthenticityScore != nil
        }.count
        let adaptationReadyCount = adaptation.scores.filter(\.isAvailable).count

        if hrQualifiedBenchmarks >= 6,
           adaptationReadyCount >= 2,
           anchors.sampleCount >= 120 {
            return .hrEnhanced
        }

        return .paceOnly
    }

    static func recentFormMultiplier(
        roadRuns: [ActivityForecastInput],
        adaptation: ActivityAdaptationSnapshot
    ) -> Double {
        let aerobicPercentile = Double(adaptation.score(for: .aerobicEfficiency)?.score ?? 50) / 100
        let durabilityPercentile = Double(adaptation.score(for: .durability)?.score ?? 50) / 100
        let hardEffortCount = roadRuns.filter { input in
            guard let effortScore = input.effortAnalysis?.derivedMetrics.effortAuthenticityScore else {
                return false
            }
            return input.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -42, to: Date()) ?? .distantPast)
                && effortScore >= 0.64
        }.count
        let hardEffortDensity = min(1, Double(hardEffortCount) / 4)
        let multiplier = 1
            + ((aerobicPercentile - 0.5) * 0.08)
            + ((durabilityPercentile - 0.5) * 0.04)
            + ((hardEffortDensity - 0.5) * 0.02)
        return max(0.94, min(1.06, multiplier))
    }

    static func distanceCurvePrediction(
        from benchmarks: [BenchmarkSample],
        targetDistanceMeters: Double
    ) -> DistanceCurvePrediction? {
        guard benchmarks.count >= 2 else {
            return nil
        }

        let points = benchmarks.map { sample in
            WeightedPoint(
                x: log(sample.distanceMeters),
                y: log(sample.duration),
                weight: sample.relevanceScore
            )
        }
        guard let fit = weightedLinearRegression(points: points) else {
            return nil
        }

        let predictedLogDuration = fit.intercept + (fit.slope * log(targetDistanceMeters))
        let predictedDuration = exp(predictedLogDuration)
        return DistanceCurvePrediction(
            duration: predictedDuration,
            exponent: fit.slope,
            formula: "log(duration) = \(numberString(fit.intercept)) + \(numberString(fit.slope)) * log(distance)"
        )
    }

    static func localBenchmarkPrediction(
        from benchmarks: [BenchmarkSample],
        targetDistanceMeters: Double,
        fallbackExponent: Double
    ) -> LocalBenchmarkPrediction? {
        guard !benchmarks.isEmpty else {
            return nil
        }

        let predictions = benchmarks.map { sample -> Double in
            let ratio = max(0.1, targetDistanceMeters / sample.distanceMeters)
            return sample.duration * pow(ratio, fallbackExponent)
        }
        let weights = benchmarks.map(\.relevanceScore)
        let duration = weightedGeometricMean(predictions, weights: weights)
        return LocalBenchmarkPrediction(
            duration: duration,
            formula: "weighted geometric mean of comparable efforts projected with exponent \(numberString(fallbackExponent))"
        )
    }

    static func criticalSpeedPrediction(
        from roadRuns: [ActivityForecastInput],
        targetDistanceMeters: Double
    ) -> CriticalSpeedPrediction? {
        let samples = roadRuns.compactMap { input -> WeightedPoint? in
            let duration = input.resolvedDuration
            guard duration >= 6 * 60, duration <= 90 * 60, input.distanceMeters > 0 else {
                return nil
            }
            return WeightedPoint(
                x: duration,
                y: input.distanceMeters,
                weight: input.effortAnalysis?.derivedMetrics.effortAuthenticityScore ?? fallbackEffortAuthenticity(for: input)
            )
        }
        guard samples.count >= 2,
              let fit = weightedLinearRegression(points: samples),
              fit.slope > 0,
              targetDistanceMeters > fit.intercept else {
            return nil
        }

        let duration = (targetDistanceMeters - fit.intercept) / fit.slope
        guard duration > 0 else {
            return nil
        }

        return CriticalSpeedPrediction(
            duration: duration,
            formula: "distance = CS * time + D', where CS = \(numberString(fit.slope)) m/s and D' = \(numberString(fit.intercept)) m"
        )
    }

    static func hrRacePacePrediction(
        from roadRuns: [ActivityForecastInput],
        targetDistanceMeters: Double,
        raceHeartRateTarget: RaceHeartRateTarget
    ) -> HRRacePacePrediction? {
        let targetNormalizedEffort = raceHeartRateTarget.targetNormalizedEffort

        let regressionSamples = roadRuns.compactMap { input -> WeightedPoint? in
            guard let analysis = input.effortAnalysis,
                  let normalizedHeartRate = analysis.flatWindows.medianNormalizedHeartRate,
                  let speed = analysis.flatWindows.medianSpeedMetersPerSecond,
                  normalizedHeartRate > 0.15,
                  speed > 0.5,
                  analysis.flatWindows.windowCount >= 3 else {
                return nil
            }

            let authenticity = analysis.derivedMetrics.effortAuthenticityScore
                ?? fallbackEffortAuthenticity(for: input)
            let sustainedEffort = analysis.derivedMetrics.sustainedEffort ?? normalizedHeartRate
            let effortMatch = max(0.35, 1 - (abs(sustainedEffort - targetNormalizedEffort) / 0.30))
            let distanceSimilarity = distanceSimilarityRatio(input.distanceMeters, targetDistanceMeters)
            let recencyScore = min(1, recencyWeight(for: input.date) / 1.4)
            let weight = (0.34 * distanceSimilarity)
                + (0.26 * effortMatch)
                + (0.22 * authenticity)
                + (0.18 * recencyScore)

            return WeightedPoint(
                x: normalizedHeartRate,
                y: speed,
                weight: weight * Double(max(1, analysis.flatWindows.windowCount))
            )
        }

        if regressionSamples.count >= 2,
           let fit = weightedLinearRegression(points: regressionSamples),
           fit.slope > 0 {
            let rawPredictedSpeed = fit.intercept + (fit.slope * targetNormalizedEffort)
            let observedSpeeds = regressionSamples.map(\.y)
            let minSpeed = (percentile(observedSpeeds, percentile: 0.10) ?? observedSpeeds.min() ?? 0.5) * 0.75
            let maxSpeed = (percentile(observedSpeeds, percentile: 0.90) ?? observedSpeeds.max() ?? 8) * 1.10
            let predictedSpeed = max(0.5, min(maxSpeed, max(minSpeed, rawPredictedSpeed)))

            if predictedSpeed > 0.5 {
                return HRRacePacePrediction(
                    duration: targetDistanceMeters / predictedSpeed,
                    formula: "flat speed = \(numberString(fit.intercept)) + \(numberString(fit.slope)) * normalized HR at \(raceHeartRateTarget.zoneLabel)"
                )
            }
        }

        let candidates = roadRuns.compactMap { input -> (duration: Double, weight: Double)? in
            guard let analysis = input.effortAnalysis,
                  let flatEfficiency = analysis.derivedMetrics.flatEfficiency,
                  flatEfficiency > 0,
                  analysis.flatWindows.windowCount >= 3 else {
                return nil
            }

            let authenticity = analysis.derivedMetrics.effortAuthenticityScore
                ?? fallbackEffortAuthenticity(for: input)
            let sustainedEffort = analysis.derivedMetrics.sustainedEffort ?? targetNormalizedEffort
            let effortMatch = max(0.35, 1 - (abs(sustainedEffort - targetNormalizedEffort) / 0.35))
            let distanceSimilarity = distanceSimilarityRatio(input.distanceMeters, targetDistanceMeters)
            let recencyScore = min(1, recencyWeight(for: input.date) / 1.4)
            let predictedSpeed = flatEfficiency * targetNormalizedEffort
            guard predictedSpeed > 0.5 else {
                return nil
            }

            let predictedDuration = targetDistanceMeters / predictedSpeed
            let weight = (0.34 * distanceSimilarity)
                + (0.26 * effortMatch)
                + (0.22 * authenticity)
                + (0.18 * recencyScore)

            return (duration: predictedDuration, weight: weight)
        }

        guard candidates.count >= 2 else {
            return nil
        }

        let duration = weightedGeometricMean(
            candidates.map(\.duration),
            weights: candidates.map(\.weight)
        )
        return HRRacePacePrediction(
            duration: duration,
            formula: "flat speed = flat efficiency * target normalized effort (\(numberString(targetNormalizedEffort))) at \(raceHeartRateTarget.zoneLabel)"
        )
    }

    static func validation(
        using roadRuns: [ActivityForecastInput],
        targetDistanceMeters: Double
    ) -> ActivityForecastValidation {
        let validationTargetNormalizedEffort = raceSustainableNormalizedEffortTarget(
            targetDistanceMeters: targetDistanceMeters,
            roadRuns: roadRuns
        )
        let benchmarks = rankedBenchmarks(
            from: roadRuns,
            targetDistanceMeters: targetDistanceMeters,
            targetNormalizedEffort: validationTargetNormalizedEffort
        )
        guard benchmarks.count >= 5 else {
            return ActivityForecastValidation(
                validationCount: 0,
                medianAbsolutePercentError: 0.12,
                p80AbsolutePercentError: 0.16,
                signedBias: 0,
                componentStats: []
            )
        }

        var ensembleErrors: [Double] = []
        var ensembleBiases: [Double] = []
        var componentErrors: [ActivityForecastComponentKind: [Double]] = [:]
        var componentBiases: [ActivityForecastComponentKind: [Double]] = [:]

        for heldOut in benchmarks {
            let trainingSet = benchmarks.filter { $0.input.activityKey != heldOut.input.activityKey }
            guard trainingSet.count >= 3 else {
                continue
            }
            let trainingInputs = trainingSet.map { $0.input }

            let distanceCurve = distanceCurvePrediction(from: trainingSet, targetDistanceMeters: heldOut.distanceMeters)
            let local = localBenchmarkPrediction(
                from: Array(trainingSet.prefix(6)),
                targetDistanceMeters: heldOut.distanceMeters,
                fallbackExponent: distanceCurve?.exponent ?? 1.06
            )
            let critical = criticalSpeedPrediction(
                from: trainingInputs,
                targetDistanceMeters: heldOut.distanceMeters
            )
            let targetNormalizedEffort = raceSustainableNormalizedEffortTarget(
                targetDistanceMeters: heldOut.distanceMeters,
                roadRuns: trainingInputs
            )
            let trainingAnchors = heartRateAnchors(from: trainingInputs)
            let trainingZones = heartRateZoneModel(from: trainingInputs, anchors: trainingAnchors)
            let raceHeartRateTarget = raceHeartRateTarget(
                targetDistanceMeters: heldOut.distanceMeters,
                targetNormalizedEffort: targetNormalizedEffort,
                anchors: trainingAnchors,
                zones: trainingZones
            )
            let hrRacePace = hrRacePacePrediction(
                from: trainingInputs,
                targetDistanceMeters: heldOut.distanceMeters,
                raceHeartRateTarget: raceHeartRateTarget
            )
            let components: [(kind: ActivityForecastComponentKind, duration: Double?)] = [
                (ActivityForecastComponentKind.distanceCurve, distanceCurve?.duration),
                (ActivityForecastComponentKind.localBenchmarks, local?.duration),
                (ActivityForecastComponentKind.criticalSpeed, critical?.duration),
                (ActivityForecastComponentKind.hrRacePace, hrRacePace?.duration)
            ]
            let validDurations = components.compactMap { kind, duration -> ActivityForecastComponentPrediction? in
                guard let duration else {
                    return nil
                }
                return ActivityForecastComponentPrediction(kind: kind, predictedDuration: duration, weight: 1)
            }
            guard !validDurations.isEmpty else {
                continue
            }

            let weights = componentWeights(
                validation: ActivityForecastValidation(
                    validationCount: 0,
                    medianAbsolutePercentError: 0.12,
                    p80AbsolutePercentError: 0.16,
                    signedBias: 0,
                    componentStats: []
                ),
                signalAvailability: hrRacePace != nil ? .hrEnhanced : .paceOnly
            )
            let predicted = weightedGeometricMean(
                validDurations.map(\.predictedDuration),
                weights: validDurations.map { weights[$0.kind] ?? 0.33 }
            )
            let actual = heldOut.duration
            let error = abs(predicted - actual) / actual
            let bias = (predicted - actual) / actual
            ensembleErrors.append(error)
            ensembleBiases.append(bias)

            for component in validDurations {
                let componentError = abs(component.predictedDuration - actual) / actual
                let componentBias = (component.predictedDuration - actual) / actual
                componentErrors[component.kind, default: []].append(componentError)
                componentBiases[component.kind, default: []].append(componentBias)
            }
        }

        let componentStats = ActivityForecastComponentKind.allCases.compactMap { kind -> ActivityForecastValidationComponent? in
            let errors = componentErrors[kind] ?? []
            guard !errors.isEmpty else {
                return nil
            }
            return ActivityForecastValidationComponent(
                kind: kind,
                validationCount: errors.count,
                medianAbsolutePercentError: percentile(errors, percentile: 0.5) ?? 0.12,
                signedBias: percentile(componentBiases[kind] ?? [], percentile: 0.5) ?? 0
            )
        }

        return ActivityForecastValidation(
            validationCount: ensembleErrors.count,
            medianAbsolutePercentError: percentile(ensembleErrors, percentile: 0.5) ?? 0.12,
            p80AbsolutePercentError: percentile(ensembleErrors, percentile: 0.8) ?? 0.16,
            signedBias: percentile(ensembleBiases, percentile: 0.5) ?? 0,
            componentStats: componentStats
        )
    }

    static func componentWeights(
        validation: ActivityForecastValidation,
        signalAvailability: ActivityForecastSignalAvailability
    ) -> [ActivityForecastComponentKind: Double] {
        var base: [ActivityForecastComponentKind: Double] = [
            .distanceCurve: 0.34,
            .localBenchmarks: 0.33,
            .criticalSpeed: 0.21,
            .hrRacePace: 0.12
        ]

        if signalAvailability == .hrEnhanced {
            base[.distanceCurve] = 0.27
            base[.localBenchmarks] = 0.24
            base[.criticalSpeed] = 0.20
            base[.hrRacePace] = 0.29
        }

        for component in validation.componentStats {
            let adjustment = max(0.7, min(1.2, 0.14 / max(component.medianAbsolutePercentError, 0.05)))
            base[component.kind] = (base[component.kind] ?? 0.3) * adjustment
        }

        let total = base.values.reduce(0, +)
        guard total > 0 else {
            return base
        }

        return Dictionary(uniqueKeysWithValues: base.map { ($0.key, $0.value / total) })
    }

    static func comparableEfforts(
        from benchmarks: [BenchmarkSample],
        targetDistanceMeters: Double,
        exponent: Double
    ) -> [ActivityForecastComparableEffort] {
        benchmarks.prefix(4).map { sample in
            let projected = sample.duration * pow(max(0.1, targetDistanceMeters / sample.distanceMeters), exponent)
            return ActivityForecastComparableEffort(
                activityKey: sample.input.activityKey,
                name: sample.input.name,
                date: sample.input.date,
                sportKind: sample.input.sportKind,
                distanceMeters: sample.distanceMeters,
                duration: sample.duration,
                location: sample.input.location,
                projectedDurationAtTarget: projected,
                relevanceScore: sample.relevanceScore,
                effortAuthenticityScore: sample.effortAuthenticityScore
            )
        }
    }

    static func distanceSupportScore(
        targetDistanceMeters: Double,
        benchmarks: [BenchmarkSample]
    ) -> Double {
        guard !benchmarks.isEmpty else {
            return 0
        }

        let ratios = benchmarks.map { distanceSimilarityRatio($0.distanceMeters, targetDistanceMeters) }
        let coverage = percentile(ratios, percentile: 0.7) ?? 0
        let maxDistance = benchmarks.map(\.distanceMeters).max() ?? 0
        let minDistance = benchmarks.map(\.distanceMeters).min() ?? 0
        let rangeBoost = (targetDistanceMeters >= minDistance && targetDistanceMeters <= maxDistance) ? 0.16 : 0
        return max(0, min(1, coverage + rangeBoost))
    }

    static func confidenceNotes(
        signalAvailability: ActivityForecastSignalAvailability,
        supportScore: Double,
        benchmarkCount: Int,
        validation: ActivityForecastValidation,
        roadRuns: [ActivityForecastInput],
        targetDistanceMeters: Double
    ) -> [String] {
        var notes: [String] = []

        if signalAvailability == .insufficient {
            notes.append("limited benchmark depth")
        }
        if signalAvailability != .hrEnhanced {
            notes.append("low HR coverage")
        }
        if supportScore < 0.78 {
            notes.append("forecast is outside your proven distance range")
        }
        let longRunSupport = roadRuns.contains { $0.distanceMeters >= targetDistanceMeters * 0.75 }
        if !longRunSupport && targetDistanceMeters >= ActivityRaceDistancePreset.halfMarathon.distanceMeters {
            notes.append("limited long-run support")
        }
        let recentHardEfforts = roadRuns.filter {
            $0.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -42, to: Date()) ?? .distantPast)
                && (($0.effortAnalysis?.derivedMetrics.effortAuthenticityScore ?? 0) >= 0.64)
        }.count
        if recentHardEfforts < 2 {
            notes.append("few recent hard efforts")
        }
        if benchmarkCount < 6 {
            notes.append("small benchmark set")
        }
        if validation.validationCount >= 3, validation.p80AbsolutePercentError > 0.09 {
            notes.append("wider historical backtest error")
        }

        return notes.uniqued()
    }

    static func forecastConfidence(
        benchmarkCount: Int,
        supportScore: Double,
        validation: ActivityForecastValidation,
        signalAvailability: ActivityForecastSignalAvailability
    ) -> ActivityForecastConfidence {
        if benchmarkCount >= 8,
           supportScore >= 0.84,
           validation.validationCount >= 4,
           validation.p80AbsolutePercentError <= 0.08,
           signalAvailability != .insufficient {
            return .high
        }

        if benchmarkCount >= 4,
           supportScore >= 0.7,
           validation.p80AbsolutePercentError <= 0.12 {
            return .medium
        }

        return .exploratory
    }

    static func whyReasons(
        signalAvailability: ActivityForecastSignalAvailability,
        recentFormMultiplier: Double,
        supportScore: Double,
        adaptation: ActivityAdaptationSnapshot,
        comparableEfforts: [ActivityForecastComparableEffort],
        raceHeartRateTarget: RaceHeartRateTarget
    ) -> [String] {
        var reasons = [
            signalAvailability.caption
        ]

        if let targetBpm = raceHeartRateTarget.targetBpm {
            reasons.append("Race pacing is anchored to your estimated \(raceHeartRateTarget.zoneLabel) effort around \(numberString(targetBpm)) bpm on flat terrain.")
        } else {
            reasons.append("Race pacing is anchored to your estimated \(raceHeartRateTarget.zoneLabel) effort on flat terrain.")
        }

        if recentFormMultiplier > 1.01 {
            reasons.append("Recent road-running form is pulling the forecast faster than your longer baseline.")
        } else if recentFormMultiplier < 0.99 {
            reasons.append("Recent road-running form is trailing your longer baseline, so the forecast stays conservative.")
        }

        if supportScore < 0.78 {
            reasons.append("The target distance sits outside your strongest proven range.")
        } else {
            reasons.append("The target distance is supported by comparable road efforts in your history.")
        }

        if let aerobic = adaptation.score(for: .aerobicEfficiency)?.score,
           aerobic >= 65 {
            reasons.append("Aerobic efficiency is trending above your longer-term baseline.")
        }

        if let effort = comparableEfforts.first {
            reasons.append("Your best comparable signal is \(effort.name), projected to \(RouteDisplayFormatter.duration(effort.projectedDurationAtTarget)).")
        }

        return Array(reasons.prefix(5))
    }

    static func heartRateAnchors(from roadRuns: [ActivityForecastInput]) -> ActivityEffortNormalizationAnchors {
        let weightedLows = roadRuns.compactMap { input -> WeightedSample? in
            guard let value = input.effortAnalysis?.heartRate.movingPercentiles?.p10 else {
                return nil
            }
            return WeightedSample(value: value, weight: max(1, input.effortAnalysis?.heartRate.sampleCount ?? 1))
        }
        let weightedHighs = roadRuns.compactMap { input -> WeightedSample? in
            guard let value = input.effortAnalysis?.heartRate.movingPercentiles?.p90 else {
                return nil
            }
            return WeightedSample(value: value, weight: max(1, input.effortAnalysis?.heartRate.sampleCount ?? 1))
        }

        return ActivityEffortNormalizationAnchors(
            lowBpm: weightedPercentile(weightedLows, percentile: 0.5),
            highBpm: weightedPercentile(weightedHighs, percentile: 0.5),
            sampleCount: roadRuns.reduce(0) { $0 + ($1.effortAnalysis?.heartRate.sampleCount ?? 0) }
        )
    }

    static func adaptationScore(
        kind: ActivityAdaptationScoreKind,
        roadRuns: [ActivityForecastInput],
        recentCutoff: Date,
        baselineCutoff: Date,
        eligibilityCutoff: Date
    ) -> ActivityAdaptationScoreSnapshot {
        let samples = metricSamples(for: kind, from: roadRuns, baselineCutoff: baselineCutoff)
        let recentSamples = samples.filter { $0.date >= recentCutoff }
        let eligibilitySamples = samples.filter { $0.date >= eligibilityCutoff }
        let requiredCount = requiredCount(for: kind)
        let historyCount = samples.count
        let recentCount = recentSamples.count
        let missingReasons = missingReasons(
            for: kind,
            eligibilitySamples: eligibilitySamples,
            roadRuns: roadRuns,
            requiredCount: requiredCount
        )

        guard missingReasons.isEmpty,
              let recentValue = weightedPercentile(recentSamples.map { WeightedSample(value: $0.value, weight: Int($0.weight.rounded())) }, percentile: 0.5),
              let baselineValue = percentile(samples.map(\.value), percentile: 0.5) else {
            return ActivityAdaptationScoreSnapshot(
                kind: kind,
                score: nil,
                recentValue: nil,
                baselineValue: nil,
                qualifyingRecentCount: recentCount,
                requiredCount: requiredCount,
                historyCount: historyCount,
                missingReasons: missingReasons,
                trend: samples.filter { $0.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast) }.map {
                    ActivityAdaptationTrendPoint(date: $0.date, value: $0.value)
                },
                formulaDescription: kind.formulaDescription,
                summary: missingReasons.first ?? "More qualifying runs are needed.",
                valueLabel: valueLabel(for: kind, value: nil)
            )
        }

        let percentileScore = percentileRank(of: recentValue, in: samples.map(\.value), invert: kind == .durability)
        let summary = summaryText(
            kind: kind,
            score: percentileScore,
            recentValue: recentValue,
            baselineValue: baselineValue
        )

        return ActivityAdaptationScoreSnapshot(
            kind: kind,
            score: percentileScore,
            recentValue: recentValue,
            baselineValue: baselineValue,
            qualifyingRecentCount: recentCount,
            requiredCount: requiredCount,
            historyCount: historyCount,
            missingReasons: [],
            trend: samples.filter { $0.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast) }.map {
                ActivityAdaptationTrendPoint(date: $0.date, value: $0.value)
            },
            formulaDescription: kind.formulaDescription,
            summary: summary,
            valueLabel: valueLabel(for: kind, value: recentValue)
        )
    }

    static func metricSamples(
        for kind: ActivityAdaptationScoreKind,
        from roadRuns: [ActivityForecastInput],
        baselineCutoff: Date
    ) -> [ScoreMetricSample] {
        let cutoffRuns = roadRuns.filter { $0.date >= baselineCutoff }
        return cutoffRuns.compactMap { input in
            let analysis = input.effortAnalysis
            let value: Double?
            switch kind {
            case .aerobicEfficiency:
                value = analysis?.derivedMetrics.flatEfficiency
            case .durability:
                value = analysis?.derivedMetrics.decoupling
            case .climbEfficiency:
                value = analysis?.derivedMetrics.climbEfficiency
            case .heatAdaptation:
                if let penalty = analysis?.derivedMetrics.heatPenalty {
                    value = 1 - penalty
                } else {
                    value = nil
                }
            }
            guard let value else {
                return nil
            }
            let recencyWeight = recencyWeight(for: input.date)
            return ScoreMetricSample(date: input.date, value: value, weight: recencyWeight)
        }
        .sorted { $0.date < $1.date }
    }

    static func requiredCount(for kind: ActivityAdaptationScoreKind) -> Int {
        switch kind {
        case .aerobicEfficiency:
            return 8
        case .durability:
            return 6
        case .climbEfficiency:
            return 8
        case .heatAdaptation:
            return 6
        }
    }

    static func missingReasons(
        for kind: ActivityAdaptationScoreKind,
        eligibilitySamples: [ScoreMetricSample],
        roadRuns: [ActivityForecastInput],
        requiredCount: Int
    ) -> [String] {
        switch kind {
        case .aerobicEfficiency:
            let count = roadRuns.filter { input in
                input.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -180, to: Date()) ?? .distantPast)
                    && input.effortAnalysis?.derivedMetrics.flatEfficiency != nil
            }.count
            return count >= requiredCount ? [] : ["Need \(requiredCount - count) more HR-qualified flat road runs in the last 180 days."]
        case .durability:
            let count = roadRuns.filter { input in
                input.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -180, to: Date()) ?? .distantPast)
                    && input.distanceMeters >= 10_000
                    && input.resolvedDuration >= 45 * 60
                    && input.effortAnalysis?.derivedMetrics.decoupling != nil
            }.count
            return count >= requiredCount ? [] : ["Need \(requiredCount - count) more HR-qualified long runs in the last 180 days."]
        case .climbEfficiency:
            let count = roadRuns.filter { input in
                input.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -180, to: Date()) ?? .distantPast)
                    && input.effortAnalysis?.derivedMetrics.climbEfficiency != nil
            }.count
            return count >= requiredCount ? [] : ["Need \(requiredCount - count) more HR-qualified climb sessions in the last 180 days."]
        case .heatAdaptation:
            let recentRoadRuns = roadRuns.filter {
                $0.date >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -180, to: Date()) ?? .distantPast)
            }
            let hotCount = recentRoadRuns.filter {
                ($0.effortAnalysis?.temperature.averageCelsius ?? -999) >= 18
                    && $0.effortAnalysis?.derivedMetrics.flatEfficiency != nil
            }.count
            let coolCount = recentRoadRuns.filter {
                let temperature = $0.effortAnalysis?.temperature.averageCelsius ?? -999
                return temperature >= 8 && temperature <= 16 && $0.effortAnalysis?.derivedMetrics.flatEfficiency != nil
            }.count
            var reasons: [String] = []
            if hotCount < requiredCount {
                reasons.append("Need \(requiredCount - hotCount) more hot runs (\u{2265}18\u{00B0}C) in the last 180 days.")
            }
            if coolCount < requiredCount {
                reasons.append("Need \(requiredCount - coolCount) more cool runs (8\u{00B0}C to 16\u{00B0}C) in the last 180 days.")
            }
            return reasons
        }
    }

    static func summaryText(
        kind: ActivityAdaptationScoreKind,
        score: Int,
        recentValue: Double,
        baselineValue: Double
    ) -> String {
        let delta = recentValue - baselineValue
        let direction = delta >= 0 ? "above" : "below"
        switch kind {
        case .aerobicEfficiency:
            return "Recent flat-run efficiency sits in your \(score)th percentile and is \(direction) your longer-term baseline."
        case .durability:
            return "Recent late-run fade ranks in your \(score)th percentile after inverting decoupling, which keeps lower fade higher."
        case .climbEfficiency:
            return "Recent climb efficiency sits in your \(score)th percentile versus your trailing climb sessions."
        case .heatAdaptation:
            return "Recent heat resilience sits in your \(score)th percentile compared with previous hot-condition runs."
        }
    }

    static func valueLabel(for kind: ActivityAdaptationScoreKind, value: Double?) -> String {
        guard let value else {
            return "Unavailable"
        }

        switch kind {
        case .aerobicEfficiency, .climbEfficiency:
            return "\(numberString(value)) m/s per nHR"
        case .durability:
            return "\(numberString(value * 100))% fade"
        case .heatAdaptation:
            return "\(numberString(value * 100))% resilience"
        }
    }

    static func recencyWeight(for date: Date) -> Double {
        let days = max(0, Date().timeIntervalSince(date) / 86_400)
        return max(0.5, 1.4 - min(days / 42, 0.9))
    }
}

private struct WeightedPoint {
    let x: Double
    let y: Double
    let weight: Double
}

private struct WeightedSample {
    let value: Double
    let weight: Int
}

private func denormalizedHeartRate(
    _ normalizedValue: Double,
    anchors: ActivityEffortNormalizationAnchors
) -> Double? {
    guard let low = anchors.lowBpm,
          let high = anchors.highBpm else {
        return nil
    }

    return low + (max(0, min(1.2, normalizedValue)) * (high - low))
}

private func weightedLinearRegression(points: [WeightedPoint]) -> ActivityForecastSupport.ForecastLinearRegressionFit? {
    guard points.count >= 2 else {
        return nil
    }

    let totalWeight = points.reduce(0.0) { $0 + max(0.01, $1.weight) }
    guard totalWeight > 0 else {
        return nil
    }

    let meanX = points.reduce(0.0) { $0 + ($1.x * max(0.01, $1.weight)) } / totalWeight
    let meanY = points.reduce(0.0) { $0 + ($1.y * max(0.01, $1.weight)) } / totalWeight
    let numerator = points.reduce(0.0) { partial, point in
        let weight = max(0.01, point.weight)
        return partial + weight * (point.x - meanX) * (point.y - meanY)
    }
    let denominator = points.reduce(0.0) { partial, point in
        let weight = max(0.01, point.weight)
        return partial + weight * pow(point.x - meanX, 2)
    }
    guard denominator > 0 else {
        return nil
    }

    let slope = numerator / denominator
    let intercept = meanY - (slope * meanX)
    return ActivityForecastSupport.ForecastLinearRegressionFit(intercept: intercept, slope: slope)
}

private func weightedGeometricMean(_ values: [Double], weights: [Double]) -> Double {
    let paired = zip(values, weights).filter { $0.0 > 0 && $0.1 > 0 }
    let totalWeight = paired.reduce(0.0) { $0 + $1.1 }
    guard totalWeight > 0 else {
        return values.first ?? 0
    }

    let weightedLogSum = paired.reduce(0.0) { partial, pair in
        partial + (log(pair.0) * pair.1)
    }
    return exp(weightedLogSum / totalWeight)
}

private func percentile(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty else {
        return nil
    }

    let sorted = values.sorted()
    if sorted.count == 1 {
        return sorted[0]
    }

    let bounded = max(0, min(1, percentile))
    let scaledIndex = bounded * Double(sorted.count - 1)
    let lower = Int(floor(scaledIndex))
    let upper = Int(ceil(scaledIndex))
    if lower == upper {
        return sorted[lower]
    }

    let fraction = scaledIndex - Double(lower)
    return sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
}

private func weightedPercentile(_ samples: [WeightedSample], percentile: Double) -> Double? {
    guard !samples.isEmpty else {
        return nil
    }

    let sorted = samples.sorted { lhs, rhs in
        if lhs.value == rhs.value {
            return lhs.weight < rhs.weight
        }
        return lhs.value < rhs.value
    }
    let totalWeight = sorted.reduce(0.0) { $0 + Double(max(1, $1.weight)) }
    let target = max(0, min(1, percentile)) * totalWeight

    var running = 0.0
    for sample in sorted {
        running += Double(max(1, sample.weight))
        if running >= target {
            return sample.value
        }
    }

    return sorted.last?.value
}

private func percentileRank(of value: Double, in values: [Double], invert: Bool) -> Int {
    guard !values.isEmpty else {
        return 50
    }

    let betterCount: Int
    if invert {
        betterCount = values.filter { $0 >= value }.count
    } else {
        betterCount = values.filter { $0 <= value }.count
    }
    let percentile = Int((Double(betterCount) / Double(values.count)) * 100)
    return max(0, min(100, percentile))
}

private func numberString(_ value: Double) -> String {
    if value == 0 {
        return "0"
    }
    if abs(value) >= 100 {
        return String(format: "%.0f", value)
    }
    if abs(value) >= 10 {
        return String(format: "%.1f", value)
    }
    return String(format: "%.2f", value)
}

private func distanceSimilarityRatio(_ lhs: Double, _ rhs: Double) -> Double {
    guard lhs > 0, rhs > 0 else {
        return 0
    }
    return min(lhs, rhs) / max(lhs, rhs)
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
