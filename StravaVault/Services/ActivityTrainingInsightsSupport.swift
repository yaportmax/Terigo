import Foundation

struct ActivityTrainingSnapshot {
    let timeline: [ActivityTrainingDay]
    let currentFitness: Double
    let currentFatigue: Double
    let currentForm: Double
    let currentRampRate: Double
    let currentStreakDays: Int
    let longestStreakDays: Int
    let activeDaysLast28: Int
    let rollingComparisons: [ActivityTrainingPeriodComparison]
    let weeklySummaries: [ActivityTrainingWeekSummary]
    let calendarWeeks: [ActivityTrainingCalendarWeek]
    let sportMix: [ActivityTrainingSportMix]
    let adaptationSnapshot: ActivityAdaptationSnapshot

    var last7DayLoad: Double {
        rollingComparisons.first(where: { $0.days == 7 })?.current.load ?? 0
    }
}

struct ActivityTrainingDay: Identifiable {
    let date: Date
    let load: Double
    let fitness: Double
    let fatigue: Double
    let form: Double
    let distanceMeters: Double
    let movingSeconds: Double
    let climbMeters: Double
    let activityCount: Int

    var id: Date { date }
}

struct ActivityTrainingPeriodStats {
    let load: Double
    let distanceMeters: Double
    let movingSeconds: Double
    let climbMeters: Double
    let activityCount: Int
}

struct ActivityTrainingPeriodComparison: Identifiable {
    let days: Int
    let current: ActivityTrainingPeriodStats
    let previous: ActivityTrainingPeriodStats

    var id: Int { days }
}

struct ActivityTrainingWeekSummary: Identifiable {
    let weekStart: Date
    let load: Double
    let distanceMeters: Double
    let movingSeconds: Double
    let activityCount: Int

    var id: Date { weekStart }
}

struct ActivityTrainingCalendarWeek: Identifiable {
    let weekStart: Date
    let days: [ActivityTrainingCalendarDay]

    var id: Date { weekStart }
}

struct ActivityTrainingCalendarDay: Identifiable {
    let date: Date
    let load: Double
    let activityCount: Int
    let isInCurrentMonth: Bool

    var id: Date { date }
}

struct ActivityTrainingSportMix: Identifiable {
    let sportKind: RouteSportKind
    let load: Double
    let distanceMeters: Double
    let movingSeconds: Double
    let activityCount: Int

    var id: String { sportKind.rawValue }
}

struct ActivityBestEffortCurveSnapshot {
    let sportKind: RouteSportKind
    let points: [ActivityBestEffortPoint]
}

struct ActivityBestEffortPoint: Identifiable {
    let label: String
    let distanceMeters: Double
    let bestAllTimeDuration: TimeInterval?
    let bestRecentDuration: TimeInterval?

    var id: String { label }
}

enum ActivityTrainingInsightsSupport {
    static func snapshot(from activities: [ActivityRecord]) -> ActivityTrainingSnapshot {
        snapshot(from: activities.map(ActivityForecastInput.init))
    }

    static func snapshot(from activities: [ActivityForecastInput]) -> ActivityTrainingSnapshot {
        let relevantActivities = activities
            .filter { $0.distanceMeters > 0 && resolvedDuration(for: $0) > 0 }
            .sorted {
                if $0.date == $1.date {
                    return $0.activityKey < $1.activityKey
                }
                return $0.date < $1.date
            }

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let startDate = calendar.date(byAdding: .day, value: -179, to: today) ?? today
        let dayCount = max(1, calendar.dateComponents([.day], from: startDate, to: today).day ?? 0)

        let scoredActivities = relevantActivities.map { activity -> ScoredTrainingActivity in
            let score = sessionLoad(for: activity, in: relevantActivities)
            return ScoredTrainingActivity(activity: activity, load: score)
        }

        let groupedByDay = Dictionary(grouping: scoredActivities) { scoredActivity in
            calendar.startOfDay(for: scoredActivity.activity.date)
        }

        var timeline: [ActivityTrainingDay] = []
        var fitness = 0.0
        var fatigue = 0.0

        for offset in 0...dayCount {
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                continue
            }

            let activitiesForDay = groupedByDay[date] ?? []
            let dailyLoad = activitiesForDay.reduce(0) { $0 + $1.load }
            let distance = activitiesForDay.reduce(0) { $0 + $1.activity.distanceMeters }
            let moving = activitiesForDay.reduce(0) { $0 + resolvedDuration(for: $1.activity) }
            let climb = activitiesForDay.reduce(0) { $0 + $1.activity.elevationGainMeters }

            fitness += (dailyLoad - fitness) / 42
            fatigue += (dailyLoad - fatigue) / 7

            timeline.append(
                ActivityTrainingDay(
                    date: date,
                    load: dailyLoad,
                    fitness: fitness,
                    fatigue: fatigue,
                    form: fitness - fatigue,
                    distanceMeters: distance,
                    movingSeconds: moving,
                    climbMeters: climb,
                    activityCount: activitiesForDay.count
                )
            )
        }

        let rollingComparisons = [7, 30, 90].map { days in
            makePeriodComparison(days: days, from: timeline)
        }

        let weeklySummaries = makeWeeklySummaries(from: timeline)
        let calendarWeeks = makeCalendarWeeks(from: timeline, today: today)
        let sportMix = makeSportMix(from: scoredActivities)
        let adaptationSnapshot = ActivityForecastSupport.adaptationSnapshot(from: relevantActivities)
        let currentFitness = timeline.last?.fitness ?? 0
        let currentFatigue = timeline.last?.fatigue ?? 0
        let currentForm = timeline.last?.form ?? 0
        let currentRampRate = currentRampRate(from: weeklySummaries)
        let currentStreakDays = currentStreakDays(from: timeline)
        let longestStreakDays = longestStreakDays(from: timeline)
        let activeDaysLast28 = activeDays(inLast: 28, from: timeline)

        return ActivityTrainingSnapshot(
            timeline: timeline,
            currentFitness: currentFitness,
            currentFatigue: currentFatigue,
            currentForm: currentForm,
            currentRampRate: currentRampRate,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            activeDaysLast28: activeDaysLast28,
            rollingComparisons: rollingComparisons,
            weeklySummaries: Array(weeklySummaries.suffix(16)),
            calendarWeeks: calendarWeeks,
            sportMix: sportMix,
            adaptationSnapshot: adaptationSnapshot
        )
    }

    static func bestEffortCurve(
        from activities: [ActivityRecord],
        sportKind: RouteSportKind
    ) -> ActivityBestEffortCurveSnapshot? {
        bestEffortCurve(from: activities.map(ActivityForecastInput.init), sportKind: sportKind)
    }

    static func bestEffortCurve(
        from activities: [ActivityForecastInput],
        sportKind: RouteSportKind
    ) -> ActivityBestEffortCurveSnapshot? {
        let comparableActivities = activities.filter { activity in
            activity.distanceMeters > 0 &&
            resolvedDuration(for: activity) > 0 &&
            activity.sportKind.movementKind == sportKind.movementKind &&
            activity.sportKind != .other
        }

        guard !comparableActivities.isEmpty else {
            return nil
        }

        let recentCutoff = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -120, to: .now) ?? .distantPast
        let points = effortPresets(for: sportKind).map { preset in
            let allTime = comparableActivities.compactMap { projectedDuration(for: $0, targetDistanceMeters: preset.distanceMeters, targetSportKind: sportKind) }.min()
            let recent = comparableActivities
                .filter { $0.date >= recentCutoff }
                .compactMap { projectedDuration(for: $0, targetDistanceMeters: preset.distanceMeters, targetSportKind: sportKind) }
                .min()

            return ActivityBestEffortPoint(
                label: preset.label,
                distanceMeters: preset.distanceMeters,
                bestAllTimeDuration: allTime,
                bestRecentDuration: recent
            )
        }

        return ActivityBestEffortCurveSnapshot(
            sportKind: sportKind,
            points: points
        )
    }
}

private struct ScoredTrainingActivity {
    let activity: ActivityForecastInput
    let load: Double
}

private struct EffortPreset {
    let label: String
    let distanceMeters: Double
}

private extension ActivityTrainingInsightsSupport {
    static func sessionLoad(
        for activity: ActivityForecastInput,
        in allActivities: [ActivityForecastInput]
    ) -> Double {
        let durationSeconds = resolvedDuration(for: activity)
        guard durationSeconds > 0 else {
            return 0
        }

        let similar = allActivities.filter { candidate in
            candidate.activityKey != activity.activityKey &&
            candidate.sportKind.movementKind == activity.sportKind.movementKind &&
            candidate.distanceMeters > 0 &&
            resolvedDuration(for: candidate) > 0 &&
            abs(log(max(candidate.distanceMeters, 1) / max(activity.distanceMeters, 1))) <= 0.7
        }

        let durationHours = durationSeconds / 3600
        let percentile = performancePercentile(for: activity, within: similar)
        let titleBoost = raceTitleBoost(for: activity.name)
        let effortAuthenticity = activity.effortAnalysis?.derivedMetrics.effortAuthenticityScore
            ?? fallbackEffortAuthenticity(for: activity)
        let sustainedEffort = activity.effortAnalysis?.derivedMetrics.sustainedEffort ?? 0.55
        let hrSignalActive = activity.effortAnalysis?.derivedMetrics.flatEfficiency != nil
        let intensity = max(
            0.48,
            min(
                1.16,
                0.42
                    + (effortAuthenticity * 0.40)
                    + (sustainedEffort * 0.12)
                    + (percentile * 0.16)
                    + titleBoost
            )
        )
        let terrainMultiplier = 1 + min(0.18, climbPerKilometer(for: activity) / 1_600)
        let signalMultiplier = hrSignalActive ? 1.08 : 0.98
        let qualityMultiplier = hrSignalActive ? 1.02 : 0.92

        return durationHours * pow(intensity, 2) * 100 * terrainMultiplier * signalMultiplier * qualityMultiplier
    }

    static func performancePercentile(for activity: ActivityForecastInput, within peers: [ActivityForecastInput]) -> Double {
        guard !peers.isEmpty else {
            return 0.58
        }

        let subjectScore = normalizedSpeed(for: activity)
        let sortedScores = peers.map(normalizedSpeed).sorted()
        let slowerCount = sortedScores.filter { $0 <= subjectScore }.count
        return max(0.08, min(1, Double(slowerCount) / Double(sortedScores.count)))
    }

    static func normalizedSpeed(for activity: ActivityForecastInput) -> Double {
        let durationSeconds = resolvedDuration(for: activity)
        guard durationSeconds > 0 else {
            return 0
        }

        let gamma = terrainGamma(for: activity.sportKind)
        let adjustedDistanceMeters = activity.distanceMeters * (1 + (gamma * climbPerKilometer(for: activity)))
        return adjustedDistanceMeters / durationSeconds
    }

    static func climbPerKilometer(for activity: ActivityForecastInput) -> Double {
        let kilometers = max(activity.distanceMeters / 1_000, 0.1)
        return max(0, activity.elevationGainMeters) / kilometers / 1_000
    }

    static func terrainGamma(for sportKind: RouteSportKind) -> Double {
        switch sportKind {
        case .trailRun, .hike, .snowshoe:
            return 0.35
        case .run, .walk:
            return 0.2
        case .mountainBike:
            return 0.3
        case .gravelRide, .mixedRide, .cyclocross:
            return 0.24
        case .ride:
            return 0.16
        case .ski:
            return 0.18
        case .wheelchair, .other:
            return 0.15
        }
    }

    static func resolvedDuration(for activity: ActivityForecastInput) -> Double {
        max(activity.movingTime, activity.elapsedTime)
    }

    static func raceTitleBoost(for title: String) -> Double {
        let normalized = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let keywords = ["race", "tempo", "threshold", "test", "tt", "interval", "benchmark", "pr", "pb"]
        return keywords.contains(where: { normalized.contains($0) }) ? 0.08 : 0
    }

    static func fallbackEffortAuthenticity(for activity: ActivityForecastInput) -> Double {
        let distanceBonus = min(1, activity.distanceMeters / 21_097.5) * 0.18
        let stopPenalty = activity.elapsedTime > 0 ? max(0, (activity.elapsedTime - activity.movingTime) / activity.elapsedTime) * 0.22 : 0
        let base = 0.52 + distanceBonus - stopPenalty
        return max(0.25, min(0.92, base))
    }

    static func makePeriodComparison(days: Int, from timeline: [ActivityTrainingDay]) -> ActivityTrainingPeriodComparison {
        let current = periodStats(days: days, offset: 0, from: timeline)
        let previous = periodStats(days: days, offset: days, from: timeline)

        return ActivityTrainingPeriodComparison(
            days: days,
            current: current,
            previous: previous
        )
    }

    static func periodStats(days: Int, offset: Int, from timeline: [ActivityTrainingDay]) -> ActivityTrainingPeriodStats {
        let relevant = Array(timeline.suffix(max(0, days + offset)).prefix(days))
        return ActivityTrainingPeriodStats(
            load: relevant.reduce(0) { $0 + $1.load },
            distanceMeters: relevant.reduce(0) { $0 + $1.distanceMeters },
            movingSeconds: relevant.reduce(0) { $0 + $1.movingSeconds },
            climbMeters: relevant.reduce(0) { $0 + $1.climbMeters },
            activityCount: relevant.reduce(0) { $0 + $1.activityCount }
        )
    }

    static func makeWeeklySummaries(from timeline: [ActivityTrainingDay]) -> [ActivityTrainingWeekSummary] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: timeline) { day in
            calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
        }

        return grouped.keys.sorted().map { weekStart in
            let days = grouped[weekStart] ?? []
            return ActivityTrainingWeekSummary(
                weekStart: weekStart,
                load: days.reduce(0) { $0 + $1.load },
                distanceMeters: days.reduce(0) { $0 + $1.distanceMeters },
                movingSeconds: days.reduce(0) { $0 + $1.movingSeconds },
                activityCount: days.reduce(0) { $0 + $1.activityCount }
            )
        }
    }

    static func makeCalendarWeeks(from timeline: [ActivityTrainingDay], today: Date) -> [ActivityTrainingCalendarWeek] {
        let calendar = Calendar.autoupdatingCurrent
        let currentMonthInterval = calendar.dateInterval(of: .month, for: today)
        let currentMonth = currentMonthInterval?.start ?? today
        let recentDays = Array(timeline.suffix(84))
        let grouped = Dictionary(grouping: recentDays) { day in
            calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
        }

        return grouped.keys.sorted().map { weekStart in
            let days = (0..<7).compactMap { offset -> ActivityTrainingCalendarDay? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    return nil
                }

                let day = grouped[weekStart]?.first(where: { calendar.isDate($0.date, inSameDayAs: date) })
                return ActivityTrainingCalendarDay(
                    date: date,
                    load: day?.load ?? 0,
                    activityCount: day?.activityCount ?? 0,
                    isInCurrentMonth: (calendar.dateInterval(of: .month, for: date)?.start ?? date) == currentMonth
                )
            }

            return ActivityTrainingCalendarWeek(weekStart: weekStart, days: days)
        }
    }

    static func makeSportMix(from activities: [ScoredTrainingActivity]) -> [ActivityTrainingSportMix] {
        let grouped = Dictionary(grouping: activities) { $0.activity.sportKind }
        return grouped.map { sportKind, activities in
            ActivityTrainingSportMix(
                sportKind: sportKind,
                load: activities.reduce(0) { $0 + $1.load },
                distanceMeters: activities.reduce(0) { $0 + $1.activity.distanceMeters },
                movingSeconds: activities.reduce(0) { $0 + resolvedDuration(for: $1.activity) },
                activityCount: activities.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.load == rhs.load {
                return lhs.sportKind.title.localizedCaseInsensitiveCompare(rhs.sportKind.title) == .orderedAscending
            }
            return lhs.load > rhs.load
        }
    }

    static func currentRampRate(from weeklySummaries: [ActivityTrainingWeekSummary]) -> Double {
        guard weeklySummaries.count >= 2 else {
            return 0
        }

        let recent = weeklySummaries.suffix(2)
        let previous = recent.first?.load ?? 0
        let current = recent.last?.load ?? 0
        return current - previous
    }

    static func currentStreakDays(from timeline: [ActivityTrainingDay]) -> Int {
        var streak = 0

        for day in timeline.reversed() {
            guard day.activityCount > 0 else {
                break
            }
            streak += 1
        }

        return streak
    }

    static func longestStreakDays(from timeline: [ActivityTrainingDay]) -> Int {
        var best = 0
        var current = 0

        for day in timeline {
            if day.activityCount > 0 {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }

        return best
    }

    static func activeDays(inLast days: Int, from timeline: [ActivityTrainingDay]) -> Int {
        Array(timeline.suffix(days)).reduce(0) { partialResult, day in
            partialResult + (day.activityCount > 0 ? 1 : 0)
        }
    }

    static func effortPresets(for sportKind: RouteSportKind) -> [EffortPreset] {
        switch sportKind {
        case .run, .trailRun:
            return [
                EffortPreset(label: "1K", distanceMeters: 1_000),
                EffortPreset(label: "5K", distanceMeters: 5_000),
                EffortPreset(label: "10K", distanceMeters: 10_000),
                EffortPreset(label: "Half", distanceMeters: 21_097.5),
                EffortPreset(label: "Marathon", distanceMeters: 42_195)
            ]
        case .ride, .mixedRide, .gravelRide, .cyclocross, .mountainBike:
            return [
                EffortPreset(label: "20K", distanceMeters: 20_000),
                EffortPreset(label: "40K", distanceMeters: 40_000),
                EffortPreset(label: "100K", distanceMeters: 100_000),
                EffortPreset(label: "100 mi", distanceMeters: 160_934)
            ]
        case .walk, .hike, .snowshoe, .ski, .wheelchair, .other:
            return [
                EffortPreset(label: "5K", distanceMeters: 5_000),
                EffortPreset(label: "10K", distanceMeters: 10_000),
                EffortPreset(label: "25K", distanceMeters: 25_000),
                EffortPreset(label: "50K", distanceMeters: 50_000)
            ]
        }
    }

    static func projectedDuration(
        for activity: ActivityForecastInput,
        targetDistanceMeters: Double,
        targetSportKind: RouteSportKind
    ) -> TimeInterval? {
        guard activity.sportKind.movementKind == targetSportKind.movementKind else {
            return nil
        }

        let duration = resolvedDuration(for: activity)
        guard duration > 0, activity.distanceMeters > 0 else {
            return nil
        }

        let exponent = riegelExponent(for: targetSportKind)
        let ratio = targetDistanceMeters / max(activity.distanceMeters, 1)
        guard ratio > 0.25, ratio < 4.5 else {
            return nil
        }

        let terrainAdjustedTarget = targetDistanceMeters / (1 + (terrainGamma(for: targetSportKind) * climbPerKilometer(for: activity)))
        let projected = duration * pow(max(terrainAdjustedTarget, 1) / max(activity.distanceMeters, 1), exponent)
        return projected.isFinite ? projected : nil
    }

    static func riegelExponent(for sportKind: RouteSportKind) -> Double {
        switch sportKind {
        case .run:
            return 1.06
        case .trailRun:
            return 1.085
        case .ride, .mixedRide:
            return 1.05
        case .gravelRide, .cyclocross:
            return 1.065
        case .mountainBike:
            return 1.08
        case .walk:
            return 1.07
        case .hike:
            return 1.09
        case .snowshoe:
            return 1.1
        case .ski:
            return 1.07
        case .wheelchair, .other:
            return 1.06
        }
    }
}
