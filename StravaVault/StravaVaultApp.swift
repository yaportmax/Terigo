import Foundation
import MapKit
import SwiftData
import SwiftUI
import UIKit

struct AppIconGlyph: View {
    let name: String
    var size: CGFloat = 16
    var weight: Font.Weight = .semibold

    private var activityRenderSize: CGFloat {
        size * 1.9
    }

    var body: some View {
        Group {
            if name.hasPrefix("activity-") {
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: activityRenderSize, height: activityRenderSize)
            } else {
                Image(systemName: name)
                    .font(.system(size: size, weight: weight))
            }
        }
    }
}

extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier, !identifier.isEmpty {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

enum RouteTagCatalog {
    private static let defaultsKey = "routeTagCatalog"

    static func load() -> [String] {
        let storedTags = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return RouteRecord.normalizedLabels(storedTags)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func save(_ tags: [String]) {
        let normalizedTags = RouteRecord.normalizedLabels(tags)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(normalizedTags, forKey: defaultsKey)
    }

    static func add(_ tag: String) {
        let normalizedTag = tag.trimmed
        guard !normalizedTag.isEmpty else {
            return
        }

        save(load() + [normalizedTag])
    }

    static func remove(_ tag: String) {
        let tagToken = tag.routeLabelIdentifier
        guard !tagToken.isEmpty else {
            return
        }

        save(load().filter { $0.routeLabelIdentifier != tagToken })
    }

    static func merged(with routes: [RouteRecord]) -> [String] {
        let routeTags = routes.flatMap(\.labels)
        return RouteRecord.normalizedLabels(load() + routeTags)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        case .system:
            return "System"
        }
    }

    var symbolName: String {
        switch self {
        case .dark:
            return "moon.fill"
        case .light:
            return "sun.max.fill"
        case .system:
            return "circle.lefthalf.filled"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark:
            return .dark
        case .light:
            return .light
        case .system:
            return nil
        }
    }
}

enum AppMeasurementSystem: String, CaseIterable, Identifiable {
    case imperial
    case metric

    static let storageKey = "appMeasurementSystem"

    static var defaultValue: AppMeasurementSystem {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imperial:
            return "Imperial"
        case .metric:
            return "Metric"
        }
    }

    var symbolName: String {
        switch self {
        case .imperial:
            return "ruler"
        case .metric:
            return "scalemass"
        }
    }

    var distanceUnitLabel: String {
        switch self {
        case .imperial:
            return "mi"
        case .metric:
            return "km"
        }
    }

    var climbUnitLabel: String {
        switch self {
        case .imperial:
            return "ft"
        case .metric:
            return "m"
        }
    }
}

enum AppRouteMapStyle: String, CaseIterable, Identifiable {
    case outdoors
    case standard
    case dark
    case hybrid
    case satellite

    static let storageKey = "appRouteMapStyle"
    static let defaultValue: AppRouteMapStyle = .outdoors

    var id: String { rawValue }

    static func resolved(from rawValue: String?) -> AppRouteMapStyle {
        guard let rawValue else { return defaultValue }
        if rawValue == "automatic" {
            return .outdoors
        }
        return AppRouteMapStyle(rawValue: rawValue) ?? defaultValue
    }

    var title: String {
        switch self {
        case .outdoors:
            return "Outdoors"
        case .standard:
            return "Standard"
        case .dark:
            return "Dark"
        case .hybrid:
            return "Hybrid"
        case .satellite:
            return "Satellite"
        }
    }

    var symbolName: String {
        switch self {
        case .outdoors:
            return "figure.hiking"
        case .standard:
            return "map"
        case .dark:
            return "moon.fill"
        case .hybrid:
            return "square.2.layers.3d"
        case .satellite:
            return "globe.americas.fill"
        }
    }
}

enum AppRouteMapPerspective: String, CaseIterable, Identifiable {
    case twoDimensional
    case threeDimensional

    static let storageKey = "appRouteMapPerspective"
    static let defaultValue: AppRouteMapPerspective = .twoDimensional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoDimensional:
            return "2D"
        case .threeDimensional:
            return "3D"
        }
    }

    var symbolName: String {
        switch self {
        case .twoDimensional:
            return "square"
        case .threeDimensional:
            return "cube"
        }
    }

    var isThreeDimensional: Bool {
        self == .threeDimensional
    }

    var pitch: CGFloat {
        switch self {
        case .twoDimensional:
            return 0
        case .threeDimensional:
            return 58
        }
    }

    func cameraPosition(for region: MKCoordinateRegion) -> MapCameraPosition {
        guard isThreeDimensional else {
            return .region(region)
        }

        return .camera(
            MapCamera(
                centerCoordinate: region.center,
                distance: cameraDistance(for: region),
                heading: 0,
                pitch: pitch
            )
        )
    }

    private func cameraDistance(for region: MKCoordinateRegion) -> CLLocationDistance {
        let latitudeMeters = max(region.span.latitudeDelta, 0.003) * 111_000
        let longitudeMeters = max(region.span.longitudeDelta, 0.003) * 111_000 * max(cos(region.center.latitude * .pi / 180), 0.2)
        return max(latitudeMeters, longitudeMeters) * 2.2
    }
}

enum AppRouteListDensity: String, CaseIterable, Identifiable {
    case compact
    case medium
    case expanded

    static let storageKey = "appRouteListDensity"
    static let defaultValue: AppRouteListDensity = .compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .medium:
            return "Medium"
        case .expanded:
            return "Expanded"
        }
    }

    var symbolName: String {
        switch self {
        case .compact:
            return "list.bullet"
        case .medium:
            return "rectangle.grid.1x2"
        case .expanded:
            return "map"
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .compact:
            return 0
        case .medium:
            return 12
        case .expanded:
            return 16
        }
    }

    var cardCornerRadius: CGFloat {
        switch self {
        case .compact:
            return 22
        case .medium:
            return 24
        case .expanded:
            return 28
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .compact:
            return 14
        case .medium:
            return 16
        case .expanded:
            return 18
        }
    }
}

enum AppActivityListDensity: String, CaseIterable, Identifiable {
    case compact
    case medium
    case expanded

    static let storageKey = "appActivityListDensity"
    static let defaultValue: AppActivityListDensity = .medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .medium:
            return "Medium"
        case .expanded:
            return "Expanded"
        }
    }

    var symbolName: String {
        switch self {
        case .compact:
            return "list.bullet"
        case .medium:
            return "rectangle.grid.1x2"
        case .expanded:
            return "rectangle.expand.vertical"
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .compact:
            return 0
        case .medium:
            return 14
        case .expanded:
            return 16
        }
    }

    var cardCornerRadius: CGFloat {
        switch self {
        case .compact:
            return 20
        case .medium:
            return 22
        case .expanded:
            return 24
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .compact:
            return 0
        case .medium:
            return 16
        case .expanded:
            return 18
        }
    }
}

struct RouteMapSettingsButton: View {
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue

    var body: some View {
        Menu {
            Picker("Map Style", selection: appRouteMapStyleSelection) {
                ForEach(AppRouteMapStyle.allCases) { mapStyle in
                    Label(mapStyle.title, systemImage: mapStyle.symbolName)
                        .tag(mapStyle)
                }
            }

            Picker("Map Perspective", selection: appRouteMapPerspectiveSelection) {
                ForEach(AppRouteMapPerspective.allCases) { perspective in
                    Label(perspective.title, systemImage: perspective.symbolName)
                        .tag(perspective)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.headline.weight(.bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map settings")
    }

    private var appRouteMapStyleSelection: Binding<AppRouteMapStyle> {
        Binding(
            get: { AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue) },
            set: { appRouteMapStyleRawValue = $0.rawValue }
        )
    }

    private var appRouteMapPerspectiveSelection: Binding<AppRouteMapPerspective> {
        Binding(
            get: { AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? AppRouteMapPerspective.defaultValue },
            set: { appRouteMapPerspectiveRawValue = $0.rawValue }
        )
    }
}

enum AppUITestSupport {
    private static let uiTestingFlag = "--ui-testing"
    private static let seedDemoDataFlag = "--ui-testing-seed-demo"
    private static let disableAnimationsFlag = "--ui-testing-disable-animations"
    private static let reviewDemoModeDefaultsKey = "routevault.review-demo-mode"
    private static let normalizedReviewDemoAccessCode = "TERIGODEMO2026"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingFlag)
    }

    static var isReviewDemoEnabled: Bool {
        UserDefaults.standard.bool(forKey: reviewDemoModeDefaultsKey)
    }

    static var shouldSeedDemoData: Bool {
        (isEnabled && ProcessInfo.processInfo.arguments.contains(seedDemoDataFlag)) || isReviewDemoEnabled
    }

    static var shouldUseStubSession: Bool {
        shouldSeedDemoData
    }

    static func prepareForLaunch() {
        guard isEnabled else {
            return
        }

        if ProcessInfo.processInfo.arguments.contains(disableAnimationsFlag) {
            UIView.setAnimationsEnabled(false)
        }

        resetPersistedState()
    }

    static func makeModelConfiguration() -> ModelConfiguration {
        if isEnabled {
            return ModelConfiguration("StravaVaultUITests", isStoredInMemoryOnly: true)
        }

        return ModelConfiguration("StravaVault")
    }

    @MainActor
    static func seedDemoDataIfNeeded(in container: ModelContainer) {
        seedDemoDataIfNeeded(in: container.mainContext)
    }

    @MainActor
    static func seedDemoDataIfNeeded(in context: ModelContext) {
        guard shouldSeedDemoData else {
            return
        }

        let existingRouteCount = (try? context.fetchCount(FetchDescriptor<RouteRecord>())) ?? 0
        let existingActivityCount = (try? context.fetchCount(FetchDescriptor<ActivityRecord>())) ?? 0
        let existingListCount = (try? context.fetchCount(FetchDescriptor<RouteList>())) ?? 0

        guard existingRouteCount == 0, existingActivityCount == 0, existingListCount == 0 else {
            return
        }

        let baseDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 1)) ?? .now

        let lists = makeSeedLists()
        let routes = makeSeedRoutes(baseDate: baseDate)
        let activities = makeSeedActivities(baseDate: baseDate)

        for list in lists {
            context.insert(list)
        }

        for route in routes {
            context.insert(route)
        }

        for activity in activities {
            context.insert(activity)
        }

        try? context.save()
    }

    static func makeStubSession() -> StravaSession {
        StravaSession(
            athlete: StravaAthleteProfile(
                id: 42,
                username: "ui-test-athlete",
                firstName: "Route",
                lastName: "Tester",
                profileMedium: nil,
                profile: nil
            ),
            accessToken: "ui-test-access-token",
            refreshToken: "ui-test-refresh-token",
            expiresAt: Date().addingTimeInterval(86_400),
            acceptedScopes: ["read_all", "activity:read", "activity:read_all", "activity:write"]
        )
    }

    static func makeStubAccountSession() -> RouteVaultAccountSession {
        RouteVaultAccountSession(
            token: "review-demo-session-token",
            expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 365),
            profile: RouteVaultAccountProfile(
                id: "review-demo-account",
                stravaAthleteID: 42,
                displayName: "Terigo Demo",
                avatarURLString: nil,
                createdAt: nil,
                updatedAt: nil
            )
        )
    }

    static func matchesReviewDemoCode(_ code: String) -> Bool {
        normalizedAccessCode(code) == normalizedReviewDemoAccessCode
    }

    @MainActor
    static func activateReviewDemo(using context: ModelContext) throws {
        UserDefaults.standard.set(true, forKey: reviewDemoModeDefaultsKey)
        resetPersistedState()
        try clearStoredModels(in: context)
        seedDemoDataIfNeeded(in: context)
    }

    @MainActor
    static func deactivateReviewDemo(using context: ModelContext) throws {
        UserDefaults.standard.removeObject(forKey: reviewDemoModeDefaultsKey)
        resetPersistedState()
        try clearStoredModels(in: context)
    }

    private static func resetPersistedState() {
        let defaults = UserDefaults.standard
        [
            AppAppearance.storageKey,
            AppMeasurementSystem.storageKey,
            AppRouteListDensity.storageKey,
            AppActivityListDensity.storageKey,
            AppRouteMapStyle.storageKey,
            AppRouteMapPerspective.storageKey,
            RouteTrackingActivityStore.activeRouteIDDefaultsKey,
            RouteTrackingLocationMode.storageKey,
            "deletedStravaRouteTombstones",
            "didMigrateLegacyRouteLists",
            "routeTagCatalog"
        ].forEach { defaults.removeObject(forKey: $0) }

        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("routeTrackingSnapshot.") }
            .forEach { defaults.removeObject(forKey: $0) }

        let fileManager = FileManager.default
        if let appSupportDirectory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let offlineRoutesDirectory = appSupportDirectory.appendingPathComponent("OfflineRoutes", isDirectory: true)
            if fileManager.fileExists(atPath: offlineRoutesDirectory.path) {
                try? fileManager.removeItem(at: offlineRoutesDirectory)
            }
        }
    }

    @MainActor
    private static func clearStoredModels(in context: ModelContext) throws {
        try deleteAll(RouteRecord.self, in: context)
        try deleteAll(ActivityRecord.self, in: context)
        try deleteAll(RouteList.self, in: context)
        try deleteAll(RouteStartHub.self, in: context)
        try context.save()
    }

    @MainActor
    private static func deleteAll<ModelType: PersistentModel>(
        _ type: ModelType.Type,
        in context: ModelContext
    ) throws {
        let models = try context.fetch(FetchDescriptor<ModelType>())
        for model in models {
            context.delete(model)
        }
    }

    private static func normalizedAccessCode(_ rawValue: String) -> String {
        String(
            rawValue
                .uppercased()
                .filter { $0.isLetter || $0.isNumber }
        )
    }

    private static func makeSeedLists() -> [RouteList] {
        [
            RouteList(
                id: "ui-weekend-hits",
                name: "Weekend Hits",
                listDescription: "Routes worth revisiting on easy weekends.",
                isPublic: true,
                shareCode: "UIWEEKEND01"
            ),
            RouteList(
                id: "ui-training-block",
                name: "Training Block",
                listDescription: "Longer routes for sustained efforts and race prep.",
                isPublic: false,
                shareCode: "UITRAINING1"
            )
        ]
    }

    private static func makeSeedRoutes(baseDate: Date) -> [RouteRecord] {
        let routeOne = makeRoute(
            id: 4_001,
            name: "Morning Marin Headlands 🌉",
            description: "Coastal trail run with climbs and city views.",
            sportKind: .trailRun,
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.8260, longitude: -122.4980),
                CLLocationCoordinate2D(latitude: 37.8304, longitude: -122.5050),
                CLLocationCoordinate2D(latitude: 37.8345, longitude: -122.5142),
                CLLocationCoordinate2D(latitude: 37.8390, longitude: -122.5234),
                CLLocationCoordinate2D(latitude: 37.8433, longitude: -122.5311),
                CLLocationCoordinate2D(latitude: 37.8478, longitude: -122.5376)
            ],
            distanceMeters: 16_200,
            elevationGainMeters: 602,
            movingTime: 6_020,
            details: RouteStartLocationDetails(
                referenceName: "Marin Headlands",
                regionName: "Bay Area",
                parkName: "Golden Gate National Recreation Area",
                countyName: "Marin County",
                cityName: "Sausalito",
                stateName: "California",
                countryName: "United States"
            ),
            surfaceKind: .trail,
            createdAt: baseDate.addingTimeInterval(86_400 * 3),
            updatedAt: baseDate.addingTimeInterval(86_400 * 28),
            notes: "Great for sunrise efforts.",
            listNames: ["Weekend Hits", "Training Block"]
        )

        let routeTwo = makeRoute(
            id: 4_002,
            name: "Presidio Tempo Loop",
            description: "Compact city-side loop for steady threshold work.",
            sportKind: .run,
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.7984, longitude: -122.4668),
                CLLocationCoordinate2D(latitude: 37.8003, longitude: -122.4717),
                CLLocationCoordinate2D(latitude: 37.8026, longitude: -122.4776),
                CLLocationCoordinate2D(latitude: 37.8049, longitude: -122.4814),
                CLLocationCoordinate2D(latitude: 37.8050, longitude: -122.4745),
                CLLocationCoordinate2D(latitude: 37.8012, longitude: -122.4680)
            ],
            distanceMeters: 8_400,
            elevationGainMeters: 156,
            movingTime: 2_760,
            details: RouteStartLocationDetails(
                referenceName: "Presidio",
                regionName: "Bay Area",
                parkName: "Presidio of San Francisco",
                countyName: "San Francisco County",
                cityName: "San Francisco",
                stateName: "California",
                countryName: "United States"
            ),
            surfaceKind: .paved,
            createdAt: baseDate.addingTimeInterval(86_400 * 7),
            updatedAt: baseDate.addingTimeInterval(86_400 * 31),
            notes: "Smooth weekday workout route.",
            listNames: ["Weekend Hits"]
        )

        let routeThree = makeRoute(
            id: 4_003,
            name: "Yosemite Valley Big Day 🏔️",
            description: "Long hiking line with sustained climbing.",
            sportKind: .hike,
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.7457, longitude: -119.5332),
                CLLocationCoordinate2D(latitude: 37.7428, longitude: -119.5419),
                CLLocationCoordinate2D(latitude: 37.7396, longitude: -119.5490),
                CLLocationCoordinate2D(latitude: 37.7349, longitude: -119.5567),
                CLLocationCoordinate2D(latitude: 37.7290, longitude: -119.5631),
                CLLocationCoordinate2D(latitude: 37.7247, longitude: -119.5710)
            ],
            distanceMeters: 21_700,
            elevationGainMeters: 1_340,
            movingTime: 13_800,
            details: RouteStartLocationDetails(
                referenceName: "Yosemite Valley",
                regionName: "Sierra Nevada",
                parkName: "Yosemite National Park",
                countyName: "Mariposa County",
                cityName: "Yosemite Valley",
                stateName: "California",
                countryName: "United States"
            ),
            surfaceKind: .trail,
            createdAt: baseDate.addingTimeInterval(86_400 * 12),
            updatedAt: baseDate.addingTimeInterval(86_400 * 36),
            notes: "Use for mountain long days.",
            listNames: ["Training Block"]
        )

        return [routeOne, routeTwo, routeThree]
    }

    private static func makeSeedActivities(baseDate: Date) -> [ActivityRecord] {
        [
            makeActivity(
                key: "ui-activity-headlands-tempo",
                name: "Sunrise Headlands Tempo 🌁",
                description: "Steady state effort over rolling trails.",
                sportKind: .trailRun,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.8259, longitude: -122.4977),
                    CLLocationCoordinate2D(latitude: 37.8296, longitude: -122.5035),
                    CLLocationCoordinate2D(latitude: 37.8331, longitude: -122.5098),
                    CLLocationCoordinate2D(latitude: 37.8378, longitude: -122.5188),
                    CLLocationCoordinate2D(latitude: 37.8421, longitude: -122.5270)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 25),
                movingTime: 3_250,
                elapsedTime: 3_480,
                distanceMeters: 11_200,
                elevationGainMeters: 428,
                averageSpeedMetersPerSecond: 3.45,
                details: RouteStartLocationDetails(
                    referenceName: "Marin Headlands",
                    regionName: "Bay Area",
                    parkName: "Golden Gate National Recreation Area",
                    countyName: "Marin County",
                    cityName: "Sausalito",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 1_420,
                uploadedActivityID: 98_001
            ),
            makeActivity(
                key: "ui-activity-presidio-threshold",
                name: "Presidio Threshold",
                description: "10k pace work on smooth pavement.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.7982, longitude: -122.4667),
                    CLLocationCoordinate2D(latitude: 37.8000, longitude: -122.4702),
                    CLLocationCoordinate2D(latitude: 37.8028, longitude: -122.4748),
                    CLLocationCoordinate2D(latitude: 37.8042, longitude: -122.4790),
                    CLLocationCoordinate2D(latitude: 37.8032, longitude: -122.4726)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 22),
                movingTime: 2_420,
                elapsedTime: 2_510,
                distanceMeters: 8_000,
                elevationGainMeters: 118,
                averageSpeedMetersPerSecond: 3.31,
                details: RouteStartLocationDetails(
                    referenceName: "Presidio",
                    regionName: "Bay Area",
                    parkName: "Presidio of San Francisco",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 640,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-tennessee-valley-long-run",
                name: "Long Run to Tennessee Valley",
                description: "Long aerobic run with moderate climbing.",
                sportKind: .trailRun,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.8330, longitude: -122.5350),
                    CLLocationCoordinate2D(latitude: 37.8362, longitude: -122.5428),
                    CLLocationCoordinate2D(latitude: 37.8398, longitude: -122.5509),
                    CLLocationCoordinate2D(latitude: 37.8440, longitude: -122.5591),
                    CLLocationCoordinate2D(latitude: 37.8485, longitude: -122.5663)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 18),
                movingTime: 5_880,
                elapsedTime: 6_090,
                distanceMeters: 18_400,
                elevationGainMeters: 612,
                averageSpeedMetersPerSecond: 3.12,
                details: RouteStartLocationDetails(
                    referenceName: "Tennessee Valley",
                    regionName: "Bay Area",
                    parkName: "Golden Gate National Recreation Area",
                    countyName: "Marin County",
                    cityName: "Mill Valley",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 2_210,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-track-session",
                name: "Track Session 8x1k",
                description: "Controlled speed session on the oval.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.7701, longitude: -122.4510),
                    CLLocationCoordinate2D(latitude: 37.7705, longitude: -122.4501),
                    CLLocationCoordinate2D(latitude: 37.7709, longitude: -122.4510),
                    CLLocationCoordinate2D(latitude: 37.7705, longitude: -122.4519)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 14),
                movingTime: 3_050,
                elapsedTime: 3_400,
                distanceMeters: 10_000,
                elevationGainMeters: 32,
                averageSpeedMetersPerSecond: 3.28,
                details: RouteStartLocationDetails(
                    referenceName: "Kezar Stadium",
                    regionName: "Bay Area",
                    parkName: "Golden Gate Park",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 120,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-waterfront-5k-rustbuster",
                name: "Waterfront 5K Rustbuster",
                description: "Short road benchmark with a hard closing kilometer.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.8073, longitude: -122.4173),
                    CLLocationCoordinate2D(latitude: 37.8087, longitude: -122.4124),
                    CLLocationCoordinate2D(latitude: 37.8099, longitude: -122.4073),
                    CLLocationCoordinate2D(latitude: 37.8110, longitude: -122.4024),
                    CLLocationCoordinate2D(latitude: 37.8122, longitude: -122.3976)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 31),
                movingTime: 1_305,
                elapsedTime: 1_360,
                distanceMeters: 5_000,
                elevationGainMeters: 24,
                averageSpeedMetersPerSecond: 3.83,
                details: RouteStartLocationDetails(
                    referenceName: "Embarcadero",
                    regionName: "Bay Area",
                    parkName: "The Embarcadero",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 410,
                uploadedActivityID: 98_002
            ),
            makeActivity(
                key: "ui-activity-panhandle-10k-benchmark",
                name: "Panhandle 10K Benchmark",
                description: "Road 10K benchmark with evenly-controlled pace.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.7725, longitude: -122.4542),
                    CLLocationCoordinate2D(latitude: 37.7721, longitude: -122.4478),
                    CLLocationCoordinate2D(latitude: 37.7718, longitude: -122.4410),
                    CLLocationCoordinate2D(latitude: 37.7715, longitude: -122.4341),
                    CLLocationCoordinate2D(latitude: 37.7712, longitude: -122.4278)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 27),
                movingTime: 2_890,
                elapsedTime: 2_970,
                distanceMeters: 10_000,
                elevationGainMeters: 42,
                averageSpeedMetersPerSecond: 3.46,
                details: RouteStartLocationDetails(
                    referenceName: "Panhandle",
                    regionName: "Bay Area",
                    parkName: "Panhandle",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 520,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-mission-bay-marathon-pace",
                name: "Mission Bay Marathon Pace",
                description: "Long flat aerobic run with controlled marathon effort.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.7695, longitude: -122.3912),
                    CLLocationCoordinate2D(latitude: 37.7716, longitude: -122.3874),
                    CLLocationCoordinate2D(latitude: 37.7739, longitude: -122.3833),
                    CLLocationCoordinate2D(latitude: 37.7768, longitude: -122.3795),
                    CLLocationCoordinate2D(latitude: 37.7790, longitude: -122.3756)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 24),
                movingTime: 5_460,
                elapsedTime: 5_640,
                distanceMeters: 16_200,
                elevationGainMeters: 36,
                averageSpeedMetersPerSecond: 2.97,
                details: RouteStartLocationDetails(
                    referenceName: "Mission Bay",
                    regionName: "Bay Area",
                    parkName: "Mission Creek Park",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 690,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-golden-gate-half-simulation",
                name: "Golden Gate Half Simulation",
                description: "Road half-marathon simulation over rolling city pavement.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.8078, longitude: -122.4746),
                    CLLocationCoordinate2D(latitude: 37.8088, longitude: -122.4684),
                    CLLocationCoordinate2D(latitude: 37.8095, longitude: -122.4612),
                    CLLocationCoordinate2D(latitude: 37.8104, longitude: -122.4541),
                    CLLocationCoordinate2D(latitude: 37.8111, longitude: -122.4468)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 20),
                movingTime: 6_620,
                elapsedTime: 6_780,
                distanceMeters: 21_097.5,
                elevationGainMeters: 102,
                averageSpeedMetersPerSecond: 3.19,
                details: RouteStartLocationDetails(
                    referenceName: "Golden Gate Park",
                    regionName: "Bay Area",
                    parkName: "Golden Gate Park",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 930,
                uploadedActivityID: 98_003
            ),
            makeActivity(
                key: "ui-activity-lake-merced-long-run",
                name: "Lake Merced Long Run",
                description: "Steady long road run for marathon adaptation work.",
                sportKind: .run,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.7288, longitude: -122.4937),
                    CLLocationCoordinate2D(latitude: 37.7264, longitude: -122.4890),
                    CLLocationCoordinate2D(latitude: 37.7241, longitude: -122.4842),
                    CLLocationCoordinate2D(latitude: 37.7221, longitude: -122.4791),
                    CLLocationCoordinate2D(latitude: 37.7200, longitude: -122.4740)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 16),
                movingTime: 7_740,
                elapsedTime: 7_950,
                distanceMeters: 24_600,
                elevationGainMeters: 118,
                averageSpeedMetersPerSecond: 3.18,
                details: RouteStartLocationDetails(
                    referenceName: "Lake Merced",
                    regionName: "Bay Area",
                    parkName: "Lake Merced",
                    countyName: "San Francisco County",
                    cityName: "San Francisco",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 1_120,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-marin-gravel",
                name: "Marin Gravel Adventure",
                description: "Mixed-surface ride with punchy climbs.",
                sportKind: .gravelRide,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.9240, longitude: -122.5960),
                    CLLocationCoordinate2D(latitude: 37.9304, longitude: -122.6038),
                    CLLocationCoordinate2D(latitude: 37.9372, longitude: -122.6112),
                    CLLocationCoordinate2D(latitude: 37.9435, longitude: -122.6174),
                    CLLocationCoordinate2D(latitude: 37.9508, longitude: -122.6226)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 10),
                movingTime: 7_900,
                elapsedTime: 8_340,
                distanceMeters: 33_100,
                elevationGainMeters: 870,
                averageSpeedMetersPerSecond: 4.19,
                details: RouteStartLocationDetails(
                    referenceName: "Point Reyes",
                    regionName: "Bay Area",
                    parkName: "Point Reyes National Seashore",
                    countyName: "Marin County",
                    cityName: "Inverness",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 5_450,
                uploadedActivityID: nil
            ),
            makeActivity(
                key: "ui-activity-yosemite-hike",
                name: "Yosemite Mist Trail Hike",
                description: "Steep climb with long stair sections.",
                sportKind: .hike,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 37.7325, longitude: -119.5586),
                    CLLocationCoordinate2D(latitude: 37.7284, longitude: -119.5618),
                    CLLocationCoordinate2D(latitude: 37.7247, longitude: -119.5644),
                    CLLocationCoordinate2D(latitude: 37.7208, longitude: -119.5673),
                    CLLocationCoordinate2D(latitude: 37.7164, longitude: -119.5698)
                ],
                startDate: baseDate.addingTimeInterval(86_400 * 7),
                movingTime: 9_800,
                elapsedTime: 11_200,
                distanceMeters: 13_500,
                elevationGainMeters: 1_120,
                averageSpeedMetersPerSecond: 1.38,
                details: RouteStartLocationDetails(
                    referenceName: "Yosemite Valley",
                    regionName: "Sierra Nevada",
                    parkName: "Yosemite National Park",
                    countyName: "Mariposa County",
                    cityName: "Yosemite Valley",
                    stateName: "California",
                    countryName: "United States"
                ),
                newCoverageMeters: 3_600,
                uploadedActivityID: nil
            )
        ]
    }

    private static func makeRoute(
        id: Int,
        name: String,
        description: String,
        sportKind: RouteSportKind,
        coordinates: [CLLocationCoordinate2D],
        distanceMeters: Double,
        elevationGainMeters: Double,
        movingTime: Double,
        details: RouteStartLocationDetails,
        surfaceKind: RouteSurfaceKind?,
        createdAt: Date,
        updatedAt: Date,
        notes: String,
        listNames: [String]
    ) -> RouteRecord {
        let route = ImportedGPXRoute(
            routeID: id,
            name: name,
            description: description,
            distanceMeters: distanceMeters,
            elevationGainMeters: elevationGainMeters,
            elevationSamples: makeElevationSamples(for: coordinates, totalDistanceMeters: distanceMeters, startingElevation: 18, totalGainMeters: elevationGainMeters),
            estimatedMovingTime: movingTime,
            routeType: sportKind.routeTypeMapping.type,
            routeSubType: sportKind.routeTypeMapping.subType,
            regionName: details.regionName,
            parkName: details.parkName,
            countyName: details.countyName,
            city: details.cityName,
            state: details.stateName,
            country: details.countryName,
            summaryPolyline: RoutePolylineCodec.encode(coordinates),
            surfaceKind: surfaceKind,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let record = RouteRecord(importedGPX: route, syncedAt: updatedAt)
        record.startLocationIndexedAt = updatedAt
        record.notes = notes
        record.listNames = listNames
        return record
    }

    private static func makeActivity(
        key: String,
        name: String,
        description: String,
        sportKind: RouteSportKind,
        coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        movingTime: Double,
        elapsedTime: Double,
        distanceMeters: Double,
        elevationGainMeters: Double,
        averageSpeedMetersPerSecond: Double,
        details: RouteStartLocationDetails,
        newCoverageMeters: Double,
        uploadedActivityID: Int?
    ) -> ActivityRecord {
        let activity = ActivityRecord(
            localName: name,
            description: description,
            sportKind: sportKind,
            coordinates: coordinates,
            elevationSamples: makeElevationSamples(for: coordinates, totalDistanceMeters: distanceMeters, startingElevation: 12, totalGainMeters: elevationGainMeters),
            startDate: startDate,
            movingTime: movingTime,
            elapsedTime: elapsedTime,
            distanceMeters: distanceMeters,
            elevationGainMeters: elevationGainMeters,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            locationDetails: details
        )
        activity.activityKey = key
        activity.newCoverageMeters = newCoverageMeters
        activity.coverageIndexedAt = startDate
        activity.uploadedActivityID = uploadedActivityID
        if uploadedActivityID != nil {
            activity.uploadedAt = startDate.addingTimeInterval(300)
        }
        return activity
    }

    private static func makeElevationSamples(
        for coordinates: [CLLocationCoordinate2D],
        totalDistanceMeters: Double,
        startingElevation: Double,
        totalGainMeters: Double
    ) -> [RouteElevationSample] {
        guard !coordinates.isEmpty else {
            return []
        }

        let denominator = Double(max(coordinates.count - 1, 1))
        return coordinates.enumerated().map { index, coordinate in
            let progress = Double(index) / denominator
            return RouteElevationSample(
                distanceMeters: totalDistanceMeters * progress,
                elevationMeters: startingElevation + (totalGainMeters * progress),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }
}

@main
struct StravaVaultApp: App {
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.dark.rawValue

    let modelContainer: ModelContainer

    init() {
        do {
            AppUITestSupport.prepareForLaunch()
            RouteVaultMapboxConfiguration.configure()
            let configuration = AppUITestSupport.makeModelConfiguration()
            modelContainer = try ModelContainer(
                for: RouteRecord.self,
                ActivityRecord.self,
                RouteList.self,
                RouteStartHub.self,
                configurations: configuration
            )
            AppUITestSupport.seedDemoDataIfNeeded(in: modelContainer)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RouteVaultRootScreen()
                .preferredColorScheme(appAppearance.colorScheme)
        }
        .modelContainer(modelContainer)
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRawValue) ?? .dark
    }
}
