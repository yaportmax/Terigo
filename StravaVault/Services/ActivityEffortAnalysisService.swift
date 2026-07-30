import Foundation

enum ActivityEffortAnalysisService {
    static func analyze(
        activity: ActivityRecord,
        detailedActivity: StravaDetailedActivityPayload? = nil,
        streams: StravaActivityStreamsPayload
    ) async -> ActivityEffortAnalysis {
        let activityDetail = detailedActivity ?? activity.asDetailedPayloadFallback
        let temperatureSummary = await temperatureSummary(for: activity, streams: streams)
        let samples = makeSamples(from: streams)

        let timeValues = streams.time?.data ?? []
        let distanceValues = streams.distance?.data ?? []
        let altitudeValues = streams.altitude?.data ?? []
        let heartRateValues = streams.heartrate?.data ?? []
        let speedValues = streams.velocitySmooth?.data ?? []
        let gradeValues = streams.gradeSmooth?.data ?? []
        let movingValues = streams.moving?.data ?? []
        let temperatureValues = streams.temp?.data ?? []
        let coordinateCount = streams.latlng?.data.count ?? 0

        let flatWindows = windowMetrics(for: samples, gradeFilter: { abs($0) <= 1.5 })
        let climbWindows = windowMetrics(for: samples, gradeFilter: { $0 >= 3 && $0 <= 8 })
        let firstThirdFlat = windowMetrics(
            for: samples.filter { $0.progress <= (1.0 / 3.0) },
            gradeFilter: { abs($0) <= 1.5 }
        )
        let lastThirdFlat = windowMetrics(
            for: samples.filter { $0.progress >= (2.0 / 3.0) },
            gradeFilter: { abs($0) <= 1.5 }
        )

        let heartRateSummary = heartRateSummary(
            activity: activity,
            detailedActivity: activityDetail,
            streamValues: heartRateValues,
            timeValues: timeValues,
            movingSamples: samples.filter(\.isMoving).compactMap(\.heartRate),
            sustainedSamples: samples.filter { $0.progress >= 0.2 && $0.progress <= 0.8 && $0.isMoving }.compactMap(\.heartRate)
        )
        let speedSummary = speedSummary(
            activity: activity,
            streamValues: speedValues,
            timeValues: timeValues,
            distanceValues: distanceValues
        )
        let gradeSummary = gradeSummary(
            activity: activity,
            streamValues: gradeValues,
            timeValues: timeValues,
            distanceValues: distanceValues,
            altitudeValues: altitudeValues
        )
        let movingSummary = movingSummary(
            activity: activity,
            streamValues: movingValues,
            speedValues: speedValues,
            timeValues: timeValues
        )

        let coverage = ActivityEffortStreamCoverage(
            coordinateSampleCount: coordinateCount,
            distanceSampleCount: distanceValues.count,
            altitudeSampleCount: altitudeValues.count,
            heartRateSampleCount: heartRateValues.count,
            speedSampleCount: speedValues.count,
            gradeSampleCount: gradeValues.count,
            movingSampleCount: movingValues.count,
            temperatureSampleCount: temperatureValues.count,
            timeSampleCount: timeValues.count
        )

        var notes: [String] = []
        if temperatureSummary.source == .historicalWeather {
            notes.append("Temperature fell back to Open-Meteo historical weather.")
        }
        if gradeValues.isEmpty, !distanceValues.isEmpty, !altitudeValues.isEmpty {
            notes.append("Grade was derived from distance and altitude streams.")
        }
        if speedValues.isEmpty, !timeValues.isEmpty, !distanceValues.isEmpty {
            notes.append("Speed was derived from distance and time streams.")
        }
        if heartRateValues.isEmpty, (activity.averageHeartRateBpm != nil || activity.maxHeartRateBpm != nil) {
            notes.append("Heart rate came from Strava activity detail instead of the stream payload.")
        }

        return ActivityEffortAnalysis(
            version: ActivityEffortAnalysisVersion.current,
            activityKey: activity.activityKey,
            analyzedAt: .now,
            activityStartDate: activity.startDate,
            startCoordinate: activity.startCoordinate.map {
                ActivityEffortCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            },
            distanceMeters: activity.distanceMeters,
            movingTimeSeconds: activity.movingTime,
            elapsedTimeSeconds: activity.elapsedTime,
            elevationGainMeters: activity.elevationGainMeters,
            heartRate: heartRateSummary,
            speed: speedSummary,
            grade: gradeSummary,
            moving: movingSummary,
            temperature: temperatureSummary,
            coverage: coverage,
            normalizationAnchors: ActivityEffortNormalizationAnchors(
                lowBpm: nil,
                highBpm: nil,
                sampleCount: 0
            ),
            flatWindows: flatWindows,
            climbWindows: climbWindows,
            firstThirdFlatWindows: firstThirdFlat,
            lastThirdFlatWindows: lastThirdFlat,
            derivedMetrics: ActivityEffortDerivedMetrics(
                flatEfficiency: nil,
                climbEfficiency: nil,
                decoupling: nil,
                heatPenalty: nil,
                effortAuthenticityScore: nil,
                sustainedEffort: nil,
                pacePercentile: nil,
                athleteCoolBaselineFlatEfficiency: nil,
                hotRunFlatEfficiency: nil
            ),
            notes: notes
        )
    }

    static func refreshedAnalyses(for activities: [ActivityRecord]) -> [String: ActivityEffortAnalysis] {
        let currentAnalyses = activities.compactMap { activity -> (ActivityRecord, ActivityEffortAnalysis)? in
            guard let analysis = activity.effortAnalysis else {
                return nil
            }
            return (activity, analysis)
        }

        let anchorActivities = currentAnalyses.filter { isHeartRateAnchorEligible(activity: $0.0, analysis: $0.1) }
        let anchors = heartRateAnchors(from: anchorActivities.map(\.1))

        let coolBaseline = coolBaselineFlatEfficiency(
            from: currentAnalyses,
            anchors: anchors
        )

        let roadRuns = activities.filter(isRoadRunEligible)
        let updated = currentAnalyses.map { activity, analysis in
            (
                activity.activityKey,
                refreshedAnalysis(
                    analysis,
                    activity: activity,
                    anchors: anchors,
                    coolBaselineFlatEfficiency: coolBaseline,
                    neighborhood: roadRuns
                )
            )
        }

        return Dictionary(uniqueKeysWithValues: updated)
    }
}

private extension ActivityEffortAnalysisService {
    struct StreamSample {
        let time: Double
        let speed: Double?
        let heartRate: Double?
        let grade: Double?
        let isMoving: Bool
        let progress: Double
    }

    struct WindowAggregate {
        let speedValues: [Double]
        let heartRateValues: [Double]
    }

    static func refreshedAnalysis(
        _ analysis: ActivityEffortAnalysis,
        activity: ActivityRecord,
        anchors: ActivityEffortNormalizationAnchors,
        coolBaselineFlatEfficiency: Double?,
        neighborhood: [ActivityRecord]
    ) -> ActivityEffortAnalysis {
        let flatWindows = normalizedWindowMetrics(analysis.flatWindows, anchors: anchors)
        let climbWindows = normalizedWindowMetrics(analysis.climbWindows, anchors: anchors)
        let firstThirdFlat = normalizedWindowMetrics(analysis.firstThirdFlatWindows, anchors: anchors)
        let lastThirdFlat = normalizedWindowMetrics(analysis.lastThirdFlatWindows, anchors: anchors)

        let sustainedEffort = normalizedHeartRate(analysis.heartRate.sustainedMedianBpm, anchors: anchors)
        let pacePercentile = pacePercentile(for: activity, within: neighborhood)
        let effortAuthenticity = effortAuthenticityScore(
            pacePercentile: pacePercentile,
            sustainedEffort: sustainedEffort
        )

        let decoupling: Double?
        if activity.sportKind == .run,
           max(activity.movingTime, activity.elapsedTime) >= 45 * 60,
           activity.distanceMeters >= 10_000,
           let firstEfficiency = firstThirdFlat.efficiency,
           let lastEfficiency = lastThirdFlat.efficiency,
           firstEfficiency > 0 {
            decoupling = 1 - (lastEfficiency / firstEfficiency)
        } else {
            decoupling = nil
        }

        let hotRunFlatEfficiency = flatWindows.efficiency
        let heatPenalty: Double?
        if let temperature = analysis.temperature.averageCelsius,
           temperature >= 18,
           let hotRunFlatEfficiency,
           let coolBaselineFlatEfficiency,
           coolBaselineFlatEfficiency > 0 {
            heatPenalty = 1 - (hotRunFlatEfficiency / coolBaselineFlatEfficiency)
        } else {
            heatPenalty = nil
        }

        return ActivityEffortAnalysis(
            version: analysis.version,
            activityKey: analysis.activityKey,
            analyzedAt: analysis.analyzedAt,
            activityStartDate: analysis.activityStartDate,
            startCoordinate: analysis.startCoordinate,
            distanceMeters: analysis.distanceMeters,
            movingTimeSeconds: analysis.movingTimeSeconds,
            elapsedTimeSeconds: analysis.elapsedTimeSeconds,
            elevationGainMeters: analysis.elevationGainMeters,
            heartRate: analysis.heartRate,
            speed: analysis.speed,
            grade: analysis.grade,
            moving: analysis.moving,
            temperature: analysis.temperature,
            coverage: analysis.coverage,
            normalizationAnchors: anchors,
            flatWindows: flatWindows,
            climbWindows: climbWindows,
            firstThirdFlatWindows: firstThirdFlat,
            lastThirdFlatWindows: lastThirdFlat,
            derivedMetrics: ActivityEffortDerivedMetrics(
                flatEfficiency: flatWindows.efficiency,
                climbEfficiency: climbWindows.efficiency,
                decoupling: decoupling,
                heatPenalty: heatPenalty,
                effortAuthenticityScore: effortAuthenticity,
                sustainedEffort: sustainedEffort,
                pacePercentile: pacePercentile,
                athleteCoolBaselineFlatEfficiency: coolBaselineFlatEfficiency,
                hotRunFlatEfficiency: hotRunFlatEfficiency
            ),
            notes: analysis.notes
        )
    }

    static func normalizedWindowMetrics(
        _ metrics: ActivityEffortWindowMetrics,
        anchors: ActivityEffortNormalizationAnchors
    ) -> ActivityEffortWindowMetrics {
        let normalizedHeartRate = normalizedHeartRate(metrics.medianHeartRateBpm, anchors: anchors)
        let efficiency: Double?
        if let speed = metrics.medianSpeedMetersPerSecond,
           let normalizedHeartRate,
           normalizedHeartRate > 0.05 {
            efficiency = speed / normalizedHeartRate
        } else {
            efficiency = nil
        }

        return ActivityEffortWindowMetrics(
            windowCount: metrics.windowCount,
            medianSpeedMetersPerSecond: metrics.medianSpeedMetersPerSecond,
            medianHeartRateBpm: metrics.medianHeartRateBpm,
            medianNormalizedHeartRate: normalizedHeartRate,
            efficiency: efficiency
        )
    }

    static func heartRateAnchors(from analyses: [ActivityEffortAnalysis]) -> ActivityEffortNormalizationAnchors {
        let lows = analyses.compactMap { analysis -> WeightedValue? in
            guard let value = analysis.heartRate.movingPercentiles?.p10 else {
                return nil
            }
            return WeightedValue(value: value, weight: max(1, analysis.heartRate.sampleCount))
        }
        let highs = analyses.compactMap { analysis -> WeightedValue? in
            guard let value = analysis.heartRate.movingPercentiles?.p90 else {
                return nil
            }
            return WeightedValue(value: value, weight: max(1, analysis.heartRate.sampleCount))
        }
        let sampleCount = analyses.reduce(0) { $0 + $1.heartRate.sampleCount }

        return ActivityEffortNormalizationAnchors(
            lowBpm: weightedPercentile(lows, percentile: 0.5),
            highBpm: weightedPercentile(highs, percentile: 0.5),
            sampleCount: sampleCount
        )
    }

    static func coolBaselineFlatEfficiency(
        from activities: [(ActivityRecord, ActivityEffortAnalysis)],
        anchors: ActivityEffortNormalizationAnchors
    ) -> Double? {
        let weightedEfficiencies = activities.compactMap { activity, analysis -> WeightedValue? in
            guard activity.sportKind == .run,
                  let temperature = analysis.temperature.averageCelsius,
                  temperature >= 8,
                  temperature <= 16,
                  let efficiency = normalizedWindowMetrics(analysis.flatWindows, anchors: anchors).efficiency else {
                return nil
            }

            return WeightedValue(
                value: efficiency,
                weight: max(1, analysis.flatWindows.windowCount)
            )
        }

        return weightedPercentile(weightedEfficiencies, percentile: 0.5)
    }

    static func effortAuthenticityScore(
        pacePercentile: Double?,
        sustainedEffort: Double?
    ) -> Double? {
        guard let pacePercentile, let sustainedEffort else {
            return nil
        }

        return max(0, min(1, (0.65 * pacePercentile) + (0.35 * sustainedEffort)))
    }

    static func pacePercentile(for activity: ActivityRecord, within activities: [ActivityRecord]) -> Double? {
        guard activity.sportKind == .run,
              activity.distanceMeters > 0,
              resolvedDuration(for: activity) > 0 else {
            return nil
        }

        let neighborhood = activities.filter { candidate in
            candidate.activityKey != activity.activityKey &&
            candidate.sportKind == .run &&
            candidate.distanceMeters > 0 &&
            resolvedDuration(for: candidate) > 0 &&
            distanceSimilarityRatio(candidate.distanceMeters, activity.distanceMeters) >= 0.74
        }

        guard !neighborhood.isEmpty else {
            return nil
        }

        let candidatePaces = neighborhood.map { resolvedDuration(for: $0) / max($0.distanceMeters, 1) }.sorted()
        let activityPace = resolvedDuration(for: activity) / max(activity.distanceMeters, 1)
        let slowerCount = candidatePaces.filter { $0 >= activityPace }.count
        return Double(slowerCount) / Double(candidatePaces.count)
    }

    static func normalizedHeartRate(
        _ value: Double?,
        anchors: ActivityEffortNormalizationAnchors
    ) -> Double? {
        guard let value,
              let low = anchors.lowBpm,
              let high = anchors.highBpm else {
            return nil
        }

        let denominator = max(15, high - low)
        guard denominator > 0 else {
            return nil
        }

        return max(0, min(1.2, (value - low) / denominator))
    }

    static func isRoadRunEligible(_ activity: ActivityRecord) -> Bool {
        guard activity.sportKind == .run,
              activity.distanceMeters >= 3_000,
              resolvedDuration(for: activity) >= 15 * 60 else {
            return false
        }

        let climbPerKilometer = activity.elevationGainMeters / max(activity.distanceMeters / 1_000, 1)
        return climbPerKilometer <= 55
    }

    static func isHeartRateAnchorEligible(
        activity: ActivityRecord,
        analysis: ActivityEffortAnalysis
    ) -> Bool {
        isRoadRunEligible(activity)
            && analysis.heartRate.sampleCount >= 30
            && analysis.heartRate.movingPercentiles?.p10 != nil
            && analysis.heartRate.movingPercentiles?.p90 != nil
    }

    static func resolvedDuration(for activity: ActivityRecord) -> Double {
        max(activity.movingTime, activity.elapsedTime)
    }

    static func distanceSimilarityRatio(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs > 0, rhs > 0 else {
            return 0
        }

        return min(lhs, rhs) / max(lhs, rhs)
    }

    static func makeSamples(from streams: StravaActivityStreamsPayload) -> [StreamSample] {
        let times = streams.time?.data ?? []
        guard !times.isEmpty else {
            return []
        }

        let distances = streams.distance?.data ?? []
        let derivedSpeeds = derivedSpeeds(distanceValues: distances, timeValues: times)
        let derivedGrades = derivedGrades(
            distanceValues: distances,
            altitudeValues: streams.altitude?.data ?? []
        )
        let maxDistance = distances.last ?? 0

        return times.enumerated().map { index, time in
            let speed = value(at: index, preferred: streams.velocitySmooth?.data, fallback: derivedSpeeds)
            let grade = value(at: index, preferred: streams.gradeSmooth?.data, fallback: derivedGrades)
            let movingValue = value(at: index, preferred: streams.moving?.data, fallback: nil)
            let isMoving = (movingValue ?? (speed ?? 0 > 0.1 ? 1 : 0)) > 0.5
            let progress: Double
            if maxDistance > 0, distances.indices.contains(index) {
                progress = max(0, min(1, distances[index] / maxDistance))
            } else if let duration = times.last, duration > 0 {
                progress = max(0, min(1, time / duration))
            } else {
                progress = 0
            }

            return StreamSample(
                time: time,
                speed: speed,
                heartRate: value(at: index, preferred: streams.heartrate?.data, fallback: nil),
                grade: grade,
                isMoving: isMoving,
                progress: progress
            )
        }
    }

    static func windowMetrics(
        for samples: [StreamSample],
        gradeFilter: (Double) -> Bool
    ) -> ActivityEffortWindowMetrics {
        let windows = sixtySecondWindows(from: samples, gradeFilter: gradeFilter)
        let speedValues = windows.compactMap { median($0.speedValues) }
        let heartRateValues = windows.compactMap { median($0.heartRateValues) }

        return ActivityEffortWindowMetrics(
            windowCount: windows.count,
            medianSpeedMetersPerSecond: median(speedValues),
            medianHeartRateBpm: median(heartRateValues),
            medianNormalizedHeartRate: nil,
            efficiency: nil
        )
    }

    static func sixtySecondWindows(
        from samples: [StreamSample],
        gradeFilter: (Double) -> Bool
    ) -> [WindowAggregate] {
        let movingSamples = samples.filter { $0.isMoving && $0.speed != nil && $0.heartRate != nil && $0.grade != nil }
        guard movingSamples.count >= 2 else {
            return []
        }

        var windows: [WindowAggregate] = []
        var bucket: [StreamSample] = []
        let bucketDuration = 60.0
        var bucketStart: Double?

        func flushBucket() {
            guard !bucket.isEmpty else {
                return
            }
            let grades = bucket.compactMap(\.grade)
            guard let medianGrade = median(grades),
                  gradeFilter(medianGrade) else {
                bucket = []
                bucketStart = nil
                return
            }

            let speeds = bucket.compactMap(\.speed)
            let heartRates = bucket.compactMap(\.heartRate)
            guard !speeds.isEmpty, !heartRates.isEmpty else {
                bucket = []
                bucketStart = nil
                return
            }

            windows.append(WindowAggregate(speedValues: speeds, heartRateValues: heartRates))
            bucket = []
            bucketStart = nil
        }

        for sample in movingSamples {
            if bucketStart == nil {
                bucketStart = sample.time
            }

            if let currentBucketStart = bucketStart, sample.time - currentBucketStart >= bucketDuration {
                flushBucket()
                bucketStart = sample.time
            }

            bucket.append(sample)
        }

        flushBucket()
        return windows
    }

    static func heartRateSummary(
        activity: ActivityRecord,
        detailedActivity: StravaDetailedActivityPayload,
        streamValues: [Double],
        timeValues: [Double],
        movingSamples: [Double],
        sustainedSamples: [Double]
    ) -> ActivityEffortHeartRateSummary {
        if !streamValues.isEmpty {
            return ActivityEffortHeartRateSummary(
                averageBpm: weightedAverage(streamValues, timeValues: timeValues),
                maxBpm: streamValues.max(),
                sampleCount: streamValues.count,
                movingPercentiles: ActivityEffortPercentiles(
                    p10: percentile(movingSamples, 0.10),
                    p50: percentile(movingSamples, 0.50),
                    p90: percentile(movingSamples, 0.90)
                ),
                sustainedMedianBpm: percentile(sustainedSamples, 0.50),
                source: .stream,
                sourceLabel: "Strava heartrate stream"
            )
        }

        let averageBpm = detailedActivity.averageHeartrate ?? activity.averageHeartRateBpm
        let maxBpm = detailedActivity.maxHeartrate ?? activity.maxHeartRateBpm
        let source = averageBpm != nil || maxBpm != nil ? ActivityEffortValueSource.detailedActivity : .unavailable
        let sourceLabel = source == .detailedActivity ? "Strava activity detail" : "Heart rate unavailable"

        return ActivityEffortHeartRateSummary(
            averageBpm: averageBpm,
            maxBpm: maxBpm,
            sampleCount: averageBpm != nil || maxBpm != nil ? 1 : 0,
            movingPercentiles: ActivityEffortPercentiles(
                p10: averageBpm,
                p50: averageBpm,
                p90: maxBpm ?? averageBpm
            ),
            sustainedMedianBpm: averageBpm,
            source: source,
            sourceLabel: sourceLabel
        )
    }

    static func speedSummary(
        activity: ActivityRecord,
        streamValues: [Double],
        timeValues: [Double],
        distanceValues: [Double]
    ) -> ActivityEffortSpeedSummary {
        if !streamValues.isEmpty {
            return ActivityEffortSpeedSummary(
                averageMetersPerSecond: weightedAverage(streamValues, timeValues: timeValues),
                maxMetersPerSecond: streamValues.max(),
                sampleCount: streamValues.count,
                source: .stream,
                sourceLabel: "Strava velocity_smooth stream"
            )
        }

        let derivedValues = derivedSpeeds(distanceValues: distanceValues, timeValues: timeValues)
        if !derivedValues.isEmpty {
            return ActivityEffortSpeedSummary(
                averageMetersPerSecond: derivedValues.average,
                maxMetersPerSecond: derivedValues.max(),
                sampleCount: derivedValues.count,
                source: .derived,
                sourceLabel: "Speed derived from distance and time streams"
            )
        }

        let hasActivityTotals = activity.distanceMeters > 0 || activity.movingTime > 0 || activity.elapsedTime > 0
        let averageMetersPerSecond = hasActivityTotals ? activity.averageSpeedMetersPerSecond : nil
        return ActivityEffortSpeedSummary(
            averageMetersPerSecond: averageMetersPerSecond,
            maxMetersPerSecond: averageMetersPerSecond,
            sampleCount: averageMetersPerSecond != nil ? 1 : 0,
            source: averageMetersPerSecond != nil ? .detailedActivity : .unavailable,
            sourceLabel: averageMetersPerSecond != nil ? "Strava activity detail" : "Speed unavailable"
        )
    }

    static func gradeSummary(
        activity: ActivityRecord,
        streamValues: [Double],
        timeValues: [Double],
        distanceValues: [Double],
        altitudeValues: [Double]
    ) -> ActivityEffortGradeSummary {
        if !streamValues.isEmpty {
            return ActivityEffortGradeSummary(
                averagePercent: weightedAverage(streamValues, timeValues: timeValues),
                minimumPercent: streamValues.min(),
                maximumPercent: streamValues.max(),
                sampleCount: streamValues.count,
                source: .stream,
                sourceLabel: "Strava grade_smooth stream"
            )
        }

        let derivedValues = derivedGrades(distanceValues: distanceValues, altitudeValues: altitudeValues)
        if !derivedValues.isEmpty {
            return ActivityEffortGradeSummary(
                averagePercent: derivedValues.average,
                minimumPercent: derivedValues.min(),
                maximumPercent: derivedValues.max(),
                sampleCount: derivedValues.count,
                source: .derived,
                sourceLabel: "Grade derived from distance and altitude streams"
            )
        }

        let averagePercent = netGradePercent(distanceMeters: activity.distanceMeters, elevationGainMeters: activity.elevationGainMeters)
        return ActivityEffortGradeSummary(
            averagePercent: averagePercent,
            minimumPercent: averagePercent,
            maximumPercent: averagePercent,
            sampleCount: averagePercent != nil ? 1 : 0,
            source: averagePercent != nil ? .derived : .unavailable,
            sourceLabel: averagePercent != nil ? "Grade derived from activity totals" : "Grade unavailable"
        )
    }

    static func movingSummary(
        activity: ActivityRecord,
        streamValues: [Double],
        speedValues: [Double],
        timeValues: [Double]
    ) -> ActivityEffortMovingSummary {
        if !streamValues.isEmpty {
            let movingFraction = weightedAverage(streamValues, timeValues: timeValues)
            let movingCount = streamValues.filter { $0 > 0.5 }.count
            return ActivityEffortMovingSummary(
                movingFraction: movingFraction,
                movingSampleCount: movingCount,
                stationarySampleCount: max(0, streamValues.count - movingCount),
                source: .stream,
                sourceLabel: "Strava moving stream"
            )
        }

        if !speedValues.isEmpty {
            let movingCount = speedValues.filter { $0 > 0.1 }.count
            let movingFraction = Double(movingCount) / Double(speedValues.count)
            return ActivityEffortMovingSummary(
                movingFraction: movingFraction,
                movingSampleCount: movingCount,
                stationarySampleCount: max(0, speedValues.count - movingCount),
                source: .derived,
                sourceLabel: "Moving inferred from speed stream"
            )
        }

        let totalDuration = max(activity.elapsedTime, activity.movingTime)
        let movingFraction = totalDuration > 0 ? activity.movingTime / totalDuration : nil
        return ActivityEffortMovingSummary(
            movingFraction: movingFraction,
            movingSampleCount: movingFraction != nil ? 1 : 0,
            stationarySampleCount: 0,
            source: movingFraction != nil ? .derived : .unavailable,
            sourceLabel: movingFraction != nil ? "Moving derived from activity totals" : "Moving unavailable"
        )
    }

    static func temperatureSummary(
        for activity: ActivityRecord,
        streams: StravaActivityStreamsPayload
    ) async -> ActivityEffortTemperatureSummary {
        if let tempStream = streams.temp?.data, !tempStream.isEmpty {
            return ActivityEffortTemperatureSummary(
                averageCelsius: weightedAverage(tempStream, timeValues: streams.time?.data ?? []),
                minimumCelsius: tempStream.min(),
                maximumCelsius: tempStream.max(),
                observedAt: activity.startDate,
                sampleCount: tempStream.count,
                source: .stream,
                sourceLabel: "Strava temp stream"
            )
        }

        guard let startCoordinate = activity.startCoordinate else {
            return ActivityEffortTemperatureSummary(
                averageCelsius: nil,
                minimumCelsius: nil,
                maximumCelsius: nil,
                observedAt: nil,
                sampleCount: 0,
                source: .unavailable,
                sourceLabel: "Temperature unavailable"
            )
        }

        do {
            let historicalWeather = try await RouteWeatherService.shared.historicalWeather(
                at: startCoordinate,
                on: activity.startDate
            )

            guard let observation = historicalWeather.observation(closestTo: activity.startDate) else {
                return ActivityEffortTemperatureSummary(
                    averageCelsius: nil,
                    minimumCelsius: nil,
                    maximumCelsius: nil,
                    observedAt: nil,
                    sampleCount: 0,
                    source: .unavailable,
                    sourceLabel: "Historical weather unavailable"
                )
            }

            return ActivityEffortTemperatureSummary(
                averageCelsius: observation.temperatureCelsius,
                minimumCelsius: observation.temperatureCelsius,
                maximumCelsius: observation.temperatureCelsius,
                observedAt: observation.observedAt,
                sampleCount: 1,
                source: .historicalWeather,
                sourceLabel: historicalWeather.providerName
            )
        } catch {
            return ActivityEffortTemperatureSummary(
                averageCelsius: nil,
                minimumCelsius: nil,
                maximumCelsius: nil,
                observedAt: nil,
                sampleCount: 0,
                source: .unavailable,
                sourceLabel: "Historical weather unavailable"
            )
        }
    }

    static func weightedAverage(_ values: [Double], timeValues: [Double]) -> Double? {
        let count = min(values.count, timeValues.count)
        guard count > 0 else {
            return values.average
        }

        if count == 1 {
            return values.first
        }

        var weightedTotal = 0.0
        var totalDuration = 0.0

        for index in 0..<(count - 1) {
            let duration = max(0, timeValues[index + 1] - timeValues[index])
            weightedTotal += values[index] * duration
            totalDuration += duration
        }

        guard totalDuration > 0 else {
            return Array(values.prefix(count)).average
        }

        return weightedTotal / totalDuration
    }

    static func derivedSpeeds(distanceValues: [Double], timeValues: [Double]) -> [Double] {
        let count = min(distanceValues.count, timeValues.count)
        guard count > 1 else {
            return []
        }

        return (0..<(count - 1)).compactMap { index in
            let deltaDistance = distanceValues[index + 1] - distanceValues[index]
            let deltaTime = timeValues[index + 1] - timeValues[index]
            guard deltaDistance.isFinite, deltaTime.isFinite, deltaDistance >= 0, deltaTime > 0 else {
                return nil
            }

            return deltaDistance / deltaTime
        }
    }

    static func derivedGrades(distanceValues: [Double], altitudeValues: [Double]) -> [Double] {
        let count = min(distanceValues.count, altitudeValues.count)
        guard count > 1 else {
            return []
        }

        return (0..<(count - 1)).compactMap { index in
            let deltaDistance = distanceValues[index + 1] - distanceValues[index]
            let deltaAltitude = altitudeValues[index + 1] - altitudeValues[index]
            guard deltaDistance.isFinite, deltaAltitude.isFinite, deltaDistance > 0 else {
                return nil
            }

            return (deltaAltitude / deltaDistance) * 100
        }
    }

    static func netGradePercent(distanceMeters: Double, elevationGainMeters: Double) -> Double? {
        guard distanceMeters > 0 else {
            return nil
        }

        return (elevationGainMeters / distanceMeters) * 100
    }

    static func value(at index: Int, preferred: [Double]?, fallback: [Double]?) -> Double? {
        if let preferred, preferred.indices.contains(index) {
            return preferred[index]
        }
        if let fallback, fallback.indices.contains(index) {
            return fallback[index]
        }
        return nil
    }
}

private struct WeightedValue {
    let value: Double
    let weight: Int
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double? {
    guard !values.isEmpty else {
        return nil
    }

    let sorted = values.sorted()
    let bounded = max(0, min(1, percentile))
    if sorted.count == 1 {
        return sorted[0]
    }

    let scaledIndex = bounded * Double(sorted.count - 1)
    let lowerIndex = Int(floor(scaledIndex))
    let upperIndex = Int(ceil(scaledIndex))
    if lowerIndex == upperIndex {
        return sorted[lowerIndex]
    }

    let fraction = scaledIndex - Double(lowerIndex)
    return sorted[lowerIndex] + ((sorted[upperIndex] - sorted[lowerIndex]) * fraction)
}

private func median(_ values: [Double]) -> Double? {
    percentile(values, 0.5)
}

private func weightedPercentile(_ values: [WeightedValue], percentile: Double) -> Double? {
    guard !values.isEmpty else {
        return nil
    }

    let sorted = values.sorted { lhs, rhs in
        if lhs.value == rhs.value {
            return lhs.weight < rhs.weight
        }
        return lhs.value < rhs.value
    }
    let totalWeight = sorted.reduce(0) { $0 + max(1, $1.weight) }
    guard totalWeight > 0 else {
        return nil
    }

    let target = max(0, min(1, percentile)) * Double(totalWeight)
    var cumulative = 0.0
    for value in sorted {
        cumulative += Double(max(1, value.weight))
        if cumulative >= target {
            return value.value
        }
    }

    return sorted.last?.value
}

extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else {
            return nil
        }

        return reduce(0, +) / Double(count)
    }
}

private extension ActivityRecord {
    var asDetailedPayloadFallback: StravaDetailedActivityPayload {
        StravaDetailedActivityPayload(
            id: stravaActivityID ?? -1,
            name: name,
            description: activityDescription.nilIfEmpty,
            distance: distanceMeters,
            movingTime: movingTime,
            elapsedTime: elapsedTime,
            totalElevationGain: elevationGainMeters,
            averageSpeed: averageSpeedMetersPerSecond,
            private: isPrivate,
            startDate: startDate,
            updatedAt: updatedAt,
            locationCity: city.nilIfEmpty,
            locationState: state.nilIfEmpty,
            locationCountry: country.nilIfEmpty,
            startLatlng: startCoordinate.map { [$0.latitude, $0.longitude] },
            endLatlng: endCoordinate.map { [$0.latitude, $0.longitude] },
            map: StravaPolylineMapPayload(id: nil, summaryPolyline: mapSummaryPolyline.nilIfEmpty),
            sportType: sportTypeRawValue.nilIfEmpty,
            type: legacyTypeRawValue.nilIfEmpty,
            hasHeartrate: hasHeartrate,
            averageHeartrate: averageHeartRateBpm,
            maxHeartrate: maxHeartRateBpm
        )
    }
}
