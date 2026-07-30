import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum RouteTrackingPhase: String {
    case idle
    case awaitingPermission
    case locating
    case tracking
    case paused
    case completed
    case finished

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .awaitingPermission:
            return "Waiting For Permission"
        case .locating:
            return "Finding You"
        case .tracking:
            return "Tracking"
        case .paused:
            return "Paused"
        case .completed:
            return "Route Complete"
        case .finished:
            return "Finished"
        }
    }
}

enum RouteTrackingLocationMode: String, CaseIterable, Codable, Identifiable {
    case reopenOnly
    case continuous

    static let storageKey = "routeTrackingLocationMode"
    static let defaultValue: RouteTrackingLocationMode = .reopenOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reopenOnly:
            return "Continuous GPS Off"
        case .continuous:
            return "Continuous GPS On"
        }
    }

    var shortDescription: String {
        switch self {
        case .reopenOnly:
            return "GPS pauses in the background and refreshes when you reopen Terigo during this activity."
        case .continuous:
            return "Keeps GPS updates running, including while the phone is locked."
        }
    }
}

enum RouteTrackingActivityStore {
    static let activeRouteIDDefaultsKey = "routeTrackingActiveRouteID"
    private static let snapshotKeyPrefix = "routeTrackingSnapshot."

    static func activeRouteID() -> Int {
        UserDefaults.standard.integer(forKey: activeRouteIDDefaultsKey)
    }

    static func setActiveRouteID(_ routeID: Int?) {
        if let routeID, routeID > 0 {
            UserDefaults.standard.set(routeID, forKey: activeRouteIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeRouteIDDefaultsKey)
        }
    }

    static func preferredTrackingMode() -> RouteTrackingLocationMode {
        guard let rawValue = UserDefaults.standard.string(forKey: RouteTrackingLocationMode.storageKey),
              let mode = RouteTrackingLocationMode(rawValue: rawValue) else {
            return .defaultValue
        }

        return mode
    }

    static func setPreferredTrackingMode(_ mode: RouteTrackingLocationMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: RouteTrackingLocationMode.storageKey)
    }

    fileprivate static func loadSnapshot(for routeID: Int) -> RouteTrackingSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey(for: routeID)),
              let snapshot = try? JSONDecoder().decode(RouteTrackingSessionSnapshot.self, from: data) else {
            return nil
        }

        return snapshot
    }

    fileprivate static func saveSnapshot(_ snapshot: RouteTrackingSessionSnapshot, for routeID: Int) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        UserDefaults.standard.set(data, forKey: snapshotKey(for: routeID))
    }

    static func clearSnapshot(for routeID: Int) {
        UserDefaults.standard.removeObject(forKey: snapshotKey(for: routeID))
    }

    private static func snapshotKey(for routeID: Int) -> String {
        "\(snapshotKeyPrefix)\(routeID)"
    }
}

private enum RouteTrackingTravelDirection: String, Codable {
    case forward
    case reverse
}

private struct PersistedCoordinate: Codable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct PersistedLocation: Codable {
    let coordinate: PersistedCoordinate
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let course: Double
    let speed: Double
    let timestamp: Date

    init(_ location: CLLocation) {
        coordinate = PersistedCoordinate(location.coordinate)
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        course = location.course
        speed = location.speed
        timestamp = location.timestamp
    }

    var resolvedLocation: CLLocation {
        CLLocation(
            coordinate: coordinate.coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}

private struct PersistedProgress: Codable {
    let userCoordinate: PersistedCoordinate
    let snappedCoordinate: PersistedCoordinate
    let currentProgressDistanceMeters: Double
    let completedProgressDistanceMeters: Double
    let remainingDistanceMeters: Double
    let fractionCompleted: Double
    let distanceToRouteMeters: Double
    let offRouteThresholdMeters: Double
    let distanceToEndMeters: Double
    let estimatedRemainingTime: TimeInterval?

    init(_ progress: RouteTrackingProgress) {
        userCoordinate = PersistedCoordinate(progress.userCoordinate)
        snappedCoordinate = PersistedCoordinate(progress.snappedCoordinate)
        currentProgressDistanceMeters = progress.currentProgressDistanceMeters
        completedProgressDistanceMeters = progress.completedProgressDistanceMeters
        remainingDistanceMeters = progress.remainingDistanceMeters
        fractionCompleted = progress.fractionCompleted
        distanceToRouteMeters = progress.distanceToRouteMeters
        offRouteThresholdMeters = progress.offRouteThresholdMeters
        distanceToEndMeters = progress.distanceToEndMeters
        estimatedRemainingTime = progress.estimatedRemainingTime
    }

    func resolvedProgress(traversedRouteCoordinates: [CLLocationCoordinate2D]) -> RouteTrackingProgress {
        RouteTrackingProgress(
            userCoordinate: userCoordinate.coordinate,
            snappedCoordinate: snappedCoordinate.coordinate,
            currentProgressDistanceMeters: currentProgressDistanceMeters,
            completedProgressDistanceMeters: completedProgressDistanceMeters,
            remainingDistanceMeters: remainingDistanceMeters,
            fractionCompleted: fractionCompleted,
            distanceToRouteMeters: distanceToRouteMeters,
            offRouteThresholdMeters: offRouteThresholdMeters,
            distanceToEndMeters: distanceToEndMeters,
            estimatedRemainingTime: estimatedRemainingTime,
            traversedRouteCoordinates: traversedRouteCoordinates
        )
    }
}

private struct RouteTrackingSessionSnapshot: Codable {
    let routeID: Int
    let phaseRawValue: String
    let wantsTracking: Bool
    let trackingModeRawValue: String
    let travelDirectionRawValue: String?
    let currentLocation: PersistedLocation?
    let progress: PersistedProgress?
    let traversedRouteCoordinates: [PersistedCoordinate]
    let breadcrumbCoordinates: [PersistedCoordinate]
    let recordedDistanceMeters: Double
    let furthestProgressDistanceMeters: Double
    let startDate: Date?
    let pauseStartedAt: Date?
    let accumulatedPausedTime: TimeInterval
    let lastAcceptedLocation: PersistedLocation?
    let speedSamples: [Double]
    let instantaneousSpeedMetersPerSecond: Double?
    let averageSpeedMetersPerSecond: Double?
    let lastUpdatedAt: Date?
    let errorMessage: String?
    let lastMatchedProgressDistanceMetersRaw: Double?
}

struct RouteTrackingProgress {
    let userCoordinate: CLLocationCoordinate2D
    let snappedCoordinate: CLLocationCoordinate2D
    let currentProgressDistanceMeters: Double
    let completedProgressDistanceMeters: Double
    let remainingDistanceMeters: Double
    let fractionCompleted: Double
    let distanceToRouteMeters: Double
    let offRouteThresholdMeters: Double
    let distanceToEndMeters: Double
    let estimatedRemainingTime: TimeInterval?
    let traversedRouteCoordinates: [CLLocationCoordinate2D]

    var isOffRoute: Bool {
        distanceToRouteMeters > offRouteThresholdMeters
    }
}

struct RouteTrackingSummary {
    let elapsedTime: TimeInterval
    let completedDistanceMeters: Double
    let recordedDistanceMeters: Double
    let averageSpeedMetersPerSecond: Double?
    let completedAt: Date
}

final class RouteTrackingSession: NSObject, ObservableObject {
    @Published private(set) var phase: RouteTrackingPhase = .idle
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var trackingMode: RouteTrackingLocationMode
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var progress: RouteTrackingProgress?
    @Published private(set) var traversedRouteCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var breadcrumbCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var recordedDistanceMeters: Double = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var instantaneousSpeedMetersPerSecond: Double?
    @Published private(set) var averageSpeedMetersPerSecond: Double?
    @Published private(set) var summary: RouteTrackingSummary?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    let route: RouteRecord

    private let locationManager: CLLocationManager
    private let analyzer: RouteTrackingAnalyzer?
    private let notificationService: RouteTrackingNotificationService
    private var timer: Timer?
    private var wantsTracking = false
    private var furthestProgressDistanceMeters: Double = 0
    private var travelDirection: RouteTrackingTravelDirection?
    private var startDate: Date?
    private var pauseStartedAt: Date?
    private var accumulatedPausedTime: TimeInterval = 0
    private var lastAcceptedLocation: CLLocation?
    private var lastMatchedProgressDistanceMetersRaw: Double?
    private var speedSamples: [Double] = []
    private var offRouteAlertPolicy = RouteTrackingOffRouteAlertPolicy()
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private let screenshotPreview: AppStoreTrackingPreviewState?

    init(
        route: RouteRecord,
        locationManager: CLLocationManager = CLLocationManager(),
        notificationService: RouteTrackingNotificationService = .shared,
        screenshotPreview: AppStoreTrackingPreviewState? = nil
    ) {
        self.route = route
        self.locationManager = locationManager
        self.notificationService = notificationService
        self.screenshotPreview = screenshotPreview
        self.authorizationStatus = locationManager.authorizationStatus
        self.accuracyAuthorization = locationManager.accuracyAuthorization
        self.trackingMode = screenshotPreview?.trackingMode ?? RouteTrackingActivityStore.preferredTrackingMode()
        let routeCoordinates = route.routeCoordinates
        self.analyzer = routeCoordinates.count > 1 ? RouteTrackingAnalyzer(routeCoordinates: routeCoordinates) : nil
        super.init()

        if let screenshotPreview {
            applyScreenshotPreview(screenshotPreview)
            return
        }

        configureLocationManager()
        restorePersistedSnapshotIfAvailable()
        registerForApplicationLifecycle()
        restoreLiveTrackingIfNeeded()
        Task { [weak self] in
            await self?.refreshNotificationAuthorizationStatus()
        }
    }

    deinit {
        timer?.invalidate()
        locationManager.stopUpdatingLocation()
        locationManager.delegate = nil
        appLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var hasTrackableGeometry: Bool {
        analyzer != nil
    }

    var totalRouteDistanceMeters: Double {
        analyzer?.totalDistanceMeters ?? route.distanceMeters
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var needsPermission: Bool {
        authorizationStatus == .notDetermined
    }

    var permissionDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var hasReducedAccuracy: Bool {
        accuracyAuthorization == .reducedAccuracy
    }

    var usesContinuousTracking: Bool {
        trackingMode == .continuous
    }

    var notificationsAuthorized: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    var notificationPermissionDenied: Bool {
        notificationAuthorizationStatus == .denied
    }

    var notificationPermissionNeedsPrompt: Bool {
        notificationAuthorizationStatus == .notDetermined
    }

    var lockScreenTrackingDescription: String {
        if trackingMode == .reopenOnly {
            return "Continuous GPS is off. Terigo refreshes your location the next time you reopen the app during this activity."
        }

        if notificationsAuthorized {
            return "Tracking continues while the screen is locked, and off-route alerts can appear on the lock screen."
        }

        return "Tracking continues while the screen is locked. Enable notifications for off-route lock-screen alerts."
    }

    var canStart: Bool {
        hasTrackableGeometry && phase == .idle
    }

    var canPause: Bool {
        phase == .tracking || phase == .locating
    }

    var canResume: Bool {
        phase == .paused
    }

    var canFinish: Bool {
        phase == .tracking || phase == .paused || phase == .completed || phase == .locating
    }

    var keepsScreenAwake: Bool {
        trackingMode == .continuous && (phase == .tracking || phase == .locating)
    }

    var showsOffRouteAlertControls: Bool {
        trackingMode == .continuous && (notificationPermissionDenied || notificationPermissionNeedsPrompt)
    }

    func startActivity() {
        summary = nil
        errorMessage = nil

        guard analyzer != nil else {
            errorMessage = "This route does not have enough geometry to start tracking."
            return
        }

        wantsTracking = true
        RouteTrackingActivityStore.setActiveRouteID(route.stravaRouteID)
        persistSnapshotIfNeeded()

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if startDate == nil {
                startDate = .now
                accumulatedPausedTime = 0
                furthestProgressDistanceMeters = 0
                recordedDistanceMeters = 0
                breadcrumbCoordinates = []
                lastAcceptedLocation = nil
                lastMatchedProgressDistanceMetersRaw = nil
                travelDirection = nil
                speedSamples = []
                instantaneousSpeedMetersPerSecond = nil
                averageSpeedMetersPerSecond = nil
                progress = nil
                traversedRouteCoordinates = []
                offRouteAlertPolicy.reset()
                clearOffRouteAlert()
            }
            beginTracking()
        case .notDetermined:
            phase = .awaitingPermission
            locationManager.requestWhenInUseAuthorization()
            persistSnapshotIfNeeded()
        case .denied:
            phase = .idle
            errorMessage = "Location access is denied. Enable it in Settings to track this route."
            persistSnapshotIfNeeded()
        case .restricted:
            phase = .idle
            errorMessage = "Location access is restricted on this device."
            persistSnapshotIfNeeded()
        @unknown default:
            phase = .idle
            errorMessage = "Location access could not be determined."
            persistSnapshotIfNeeded()
        }
    }

    func pauseActivity() {
        guard canPause else {
            return
        }

        pauseStartedAt = .now
        wantsTracking = false
        phase = .paused
        updateElapsedTime()
        stopTrackingUpdates()
        clearOffRouteAlert()
        persistSnapshotIfNeeded()
    }

    func resumeActivity() {
        guard canResume else {
            return
        }

        if let pauseStartedAt {
            accumulatedPausedTime += Date().timeIntervalSince(pauseStartedAt)
            self.pauseStartedAt = nil
        }

        wantsTracking = true
        beginTracking()
    }

    func finishActivity() {
        wantsTracking = false
        stopTrackingUpdates()
        updateElapsedTime()
        phase = phase == .completed ? .completed : .finished
        clearOffRouteAlert()
        summary = RouteTrackingSummary(
            elapsedTime: elapsedTime,
            completedDistanceMeters: progress?.completedProgressDistanceMeters ?? furthestProgressDistanceMeters,
            recordedDistanceMeters: recordedDistanceMeters,
            averageSpeedMetersPerSecond: resolvedAverageSpeed(),
            completedAt: .now
        )
        persistSnapshotIfNeeded()
    }

    func clearError() {
        errorMessage = nil
        persistSnapshotIfNeeded()
    }

    // Thin aliases for the tracker screen contract.
    func start() {
        startActivity()
    }

    func pause() {
        pauseActivity()
    }

    func resume() {
        resumeActivity()
    }

    @discardableResult
    func finish() -> RouteTrackingSummary? {
        finishActivity()
        return summary
    }

    func requestNotificationAuthorization() {
        Task { [weak self] in
            await self?.requestNotificationAuthorizationIfNeeded()
        }
    }

    func toggleTrackingMode() {
        let nextMode: RouteTrackingLocationMode = trackingMode == .continuous ? .reopenOnly : .continuous
        setTrackingMode(nextMode)
    }

    func enableBatterySaver() {
        setTrackingMode(.reopenOnly)
    }

    func enableContinuousTracking() {
        setTrackingMode(.continuous)
    }

    func clearPersistedActivity() {
        RouteTrackingActivityStore.setActiveRouteID(nil)
        RouteTrackingActivityStore.clearSnapshot(for: route.stravaRouteID)
    }

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 4
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
    }

    private func beginTracking() {
        guard isAuthorized else {
            return
        }

        errorMessage = nil
        phase = progress == nil ? .locating : .tracking
        if trackingMode == .continuous {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
        } else {
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.showsBackgroundLocationIndicator = false
            locationManager.requestLocation()
            clearOffRouteAlert()
        }
        startTimerIfNeeded()
        updateElapsedTime()
        persistSnapshotIfNeeded()
        if trackingMode == .continuous {
            Task { [weak self] in
                await self?.requestNotificationAuthorizationIfNeeded()
            }
        }
    }

    private func stopTrackingUpdates(invalidateTimer: Bool = true) {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        if invalidateTimer {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else {
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateElapsedTime()
            }
        }
        timer?.tolerance = 0.25
    }

    private func updateElapsedTime() {
        guard let startDate else {
            elapsedTime = 0
            return
        }

        let activeEndDate = pauseStartedAt ?? .now
        elapsedTime = max(0, activeEndDate.timeIntervalSince(startDate) - accumulatedPausedTime)
    }

    private func setTrackingMode(_ mode: RouteTrackingLocationMode) {
        guard trackingMode != mode else {
            return
        }

        trackingMode = mode
        RouteTrackingActivityStore.setPreferredTrackingMode(mode)

        if wantsTracking, isAuthorized, phase != .paused, phase != .finished, phase != .completed {
            beginTracking()
        } else if mode == .reopenOnly {
            stopTrackingUpdates(invalidateTimer: false)
            clearOffRouteAlert()
        }

        persistSnapshotIfNeeded()
    }

    private func restorePersistedSnapshotIfAvailable() {
        guard RouteTrackingActivityStore.activeRouteID() == route.stravaRouteID else {
            return
        }

        guard let snapshot = RouteTrackingActivityStore.loadSnapshot(for: route.stravaRouteID),
              snapshot.routeID == route.stravaRouteID else {
            return
        }

        phase = RouteTrackingPhase(rawValue: snapshot.phaseRawValue) ?? .idle
        wantsTracking = snapshot.wantsTracking
        trackingMode = RouteTrackingLocationMode(rawValue: snapshot.trackingModeRawValue) ?? RouteTrackingActivityStore.preferredTrackingMode()
        travelDirection = snapshot.travelDirectionRawValue.flatMap(RouteTrackingTravelDirection.init(rawValue:))
        currentLocation = snapshot.currentLocation?.resolvedLocation
        traversedRouteCoordinates = snapshot.traversedRouteCoordinates.map { $0.coordinate }
        breadcrumbCoordinates = snapshot.breadcrumbCoordinates.map { $0.coordinate }
        progress = snapshot.progress?.resolvedProgress(traversedRouteCoordinates: traversedRouteCoordinates)
        recordedDistanceMeters = snapshot.recordedDistanceMeters
        furthestProgressDistanceMeters = snapshot.furthestProgressDistanceMeters
        startDate = snapshot.startDate
        pauseStartedAt = snapshot.pauseStartedAt
        accumulatedPausedTime = snapshot.accumulatedPausedTime
        lastAcceptedLocation = snapshot.lastAcceptedLocation?.resolvedLocation
        speedSamples = snapshot.speedSamples
        instantaneousSpeedMetersPerSecond = snapshot.instantaneousSpeedMetersPerSecond
        averageSpeedMetersPerSecond = snapshot.averageSpeedMetersPerSecond
        lastUpdatedAt = snapshot.lastUpdatedAt
        errorMessage = snapshot.errorMessage
        lastMatchedProgressDistanceMetersRaw = snapshot.lastMatchedProgressDistanceMetersRaw
        updateElapsedTime()
    }

    private func restoreLiveTrackingIfNeeded() {
        guard wantsTracking else {
            return
        }

        RouteTrackingActivityStore.setActiveRouteID(route.stravaRouteID)

        switch phase {
        case .paused:
            startTimerIfNeeded()
            updateElapsedTime()
        case .tracking, .locating:
            beginTracking()
        case .completed, .finished, .idle, .awaitingPermission:
            break
        }
    }

    private func persistSnapshotIfNeeded() {
        let isActiveOrRestorable = wantsTracking || phase == .completed || phase == .finished || RouteTrackingActivityStore.activeRouteID() == route.stravaRouteID
        guard isActiveOrRestorable else {
            return
        }

        let snapshot = RouteTrackingSessionSnapshot(
            routeID: route.stravaRouteID,
            phaseRawValue: phase.rawValue,
            wantsTracking: wantsTracking,
            trackingModeRawValue: trackingMode.rawValue,
            travelDirectionRawValue: travelDirection?.rawValue,
            currentLocation: currentLocation.map(PersistedLocation.init),
            progress: progress.map(PersistedProgress.init),
            traversedRouteCoordinates: traversedRouteCoordinates.map(PersistedCoordinate.init),
            breadcrumbCoordinates: breadcrumbCoordinates.map(PersistedCoordinate.init),
            recordedDistanceMeters: recordedDistanceMeters,
            furthestProgressDistanceMeters: furthestProgressDistanceMeters,
            startDate: startDate,
            pauseStartedAt: pauseStartedAt,
            accumulatedPausedTime: accumulatedPausedTime,
            lastAcceptedLocation: lastAcceptedLocation.map(PersistedLocation.init),
            speedSamples: speedSamples,
            instantaneousSpeedMetersPerSecond: instantaneousSpeedMetersPerSecond,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            lastUpdatedAt: lastUpdatedAt,
            errorMessage: errorMessage,
            lastMatchedProgressDistanceMetersRaw: lastMatchedProgressDistanceMetersRaw
        )
        RouteTrackingActivityStore.saveSnapshot(snapshot, for: route.stravaRouteID)
    }

    private func refreshAuthorizationState() {
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
    }

    private func registerForApplicationLifecycle() {
        let center = NotificationCenter.default

        appLifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleApplicationDidEnterBackground()
                }
            }
        )

        appLifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleApplicationDidBecomeActive()
                }
            }
        )
    }

    private func applyScreenshotPreview(_ preview: AppStoreTrackingPreviewState) {
        phase = preview.phase
        trackingMode = preview.trackingMode
        authorizationStatus = .authorizedWhenInUse
        accuracyAuthorization = .fullAccuracy
        currentLocation = preview.currentLocation
        progress = preview.progress
        traversedRouteCoordinates = preview.traversedRouteCoordinates
        breadcrumbCoordinates = preview.breadcrumbCoordinates
        recordedDistanceMeters = preview.recordedDistanceMeters
        elapsedTime = preview.elapsedTime
        instantaneousSpeedMetersPerSecond = preview.instantaneousSpeedMetersPerSecond
        averageSpeedMetersPerSecond = preview.averageSpeedMetersPerSecond
        lastUpdatedAt = preview.lastUpdatedAt
        notificationAuthorizationStatus = preview.notificationAuthorizationStatus
    }

    private func handleApplicationDidEnterBackground() {
        updateElapsedTime()
        if trackingMode == .reopenOnly {
            stopTrackingUpdates(invalidateTimer: false)
            clearOffRouteAlert()
        } else {
            evaluateOffRouteNotificationsIfNeeded()
        }
        persistSnapshotIfNeeded()
    }

    private func handleApplicationDidBecomeActive() {
        updateElapsedTime()
        if wantsTracking, phase != .paused, phase != .finished, phase != .completed {
            beginTracking()
        }
        Task { [weak self] in
            await self?.refreshNotificationAuthorizationStatus()
        }
    }

    private func refreshNotificationAuthorizationStatus() async {
        let status = await notificationService.currentAuthorizationStatus()
        await MainActor.run {
            notificationAuthorizationStatus = status
        }
    }

    private func requestNotificationAuthorizationIfNeeded() async {
        guard trackingMode == .continuous else {
            return
        }

        let status = await notificationService.requestAuthorizationIfNeeded()
        await MainActor.run {
            notificationAuthorizationStatus = status
        }
    }

    private func processLocation(_ location: CLLocation) {
        guard wantsTracking, [.locating, .tracking].contains(phase) else {
            return
        }

        guard shouldUseLocation(location) else {
            return
        }

        let previousLocation = currentLocation
        currentLocation = location
        lastUpdatedAt = location.timestamp
        updateElapsedTime()

        if let previousAcceptedLocation = lastAcceptedLocation {
            let segmentDistance = location.distance(from: previousAcceptedLocation)
            let timeDelta = location.timestamp.timeIntervalSince(previousAcceptedLocation.timestamp)

            if segmentDistance > 1, segmentDistance < 250, timeDelta > 0, timeDelta < 20 {
                recordedDistanceMeters += segmentDistance
            }
        }

        lastAcceptedLocation = location
        instantaneousSpeedMetersPerSecond = resolvedInstantaneousSpeed(for: location, previousLocation: previousLocation)
        updateAverageSpeed(using: instantaneousSpeedMetersPerSecond)
        appendBreadcrumbCoordinateIfNeeded(location.coordinate)

        let lastProgressDistance = lastMatchedProgressDistanceMetersRaw ?? progress?.currentProgressDistanceMeters

        let shouldPreferRouteStart = lastProgressDistance == nil &&
            analyzer?.isLikelyLoopRoute == true &&
            analyzer?.isNearRouteStart(location.coordinate) == true

        guard let analyzer,
              let rawMatch = analyzer.match(
                for: location,
                preferredProgressDistanceMeters: lastProgressDistance,
                preferEarlierProgress: shouldPreferRouteStart
              ) else {
            if phase != .paused {
                phase = .tracking
            }
            return
        }

        let offRouteThresholdMeters = offRouteThreshold(for: location)
        let resolvedTravelDirection = resolvedTravelDirection(
            for: rawMatch,
            totalDistanceMeters: analyzer.totalDistanceMeters
        )
        guard let match = acceptedMatch(
            rawMatch,
            for: location,
            previousLocation: previousLocation,
            travelDirection: resolvedTravelDirection
        ) else {
            if phase != .paused {
                phase = .tracking
            }
            return
        }

        travelDirection = resolvedTravelDirection
        lastMatchedProgressDistanceMetersRaw = match.progressDistanceMeters

        let directionalCurrentProgressDistance = directionalProgressDistance(
            for: match.progressDistanceMeters,
            totalDistanceMeters: analyzer.totalDistanceMeters,
            travelDirection: resolvedTravelDirection
        )
        furthestProgressDistanceMeters = max(furthestProgressDistanceMeters, directionalCurrentProgressDistance)
        let completedProgressDistanceMeters = max(furthestProgressDistanceMeters, directionalCurrentProgressDistance)
        let remainingDistanceMeters = max(0, analyzer.totalDistanceMeters - completedProgressDistanceMeters)
        let estimatedRemainingTime = estimateRemainingTime(forRemainingDistance: remainingDistanceMeters)
        let distanceToGoalMeters = distanceToGoal(from: match.snappedCoordinate, travelDirection: resolvedTravelDirection)

        progress = RouteTrackingProgress(
            userCoordinate: location.coordinate,
            snappedCoordinate: match.snappedCoordinate,
            currentProgressDistanceMeters: match.progressDistanceMeters,
            completedProgressDistanceMeters: completedProgressDistanceMeters,
            remainingDistanceMeters: remainingDistanceMeters,
            fractionCompleted: analyzer.totalDistanceMeters > 0 ? completedProgressDistanceMeters / analyzer.totalDistanceMeters : 0,
            distanceToRouteMeters: match.distanceToRouteMeters,
            offRouteThresholdMeters: offRouteThresholdMeters,
            distanceToEndMeters: distanceToGoalMeters,
            estimatedRemainingTime: estimatedRemainingTime,
            traversedRouteCoordinates: traversedRouteCoordinates(
                for: match,
                analyzer: analyzer,
                travelDirection: resolvedTravelDirection
            )
        )
        traversedRouteCoordinates = progress?.traversedRouteCoordinates ?? traversedRouteCoordinates
        evaluateOffRouteNotificationsIfNeeded()
        persistSnapshotIfNeeded()

        if shouldCompleteRoute(
            completedProgressDistanceMeters: completedProgressDistanceMeters,
            distanceToEndMeters: distanceToGoalMeters,
            distanceToRouteMeters: match.distanceToRouteMeters,
            offRouteThresholdMeters: offRouteThresholdMeters
        ) {
            phase = .completed
            wantsTracking = false
            stopTrackingUpdates()
            updateElapsedTime()
            clearOffRouteAlert()
            summary = RouteTrackingSummary(
                elapsedTime: elapsedTime,
                completedDistanceMeters: completedProgressDistanceMeters,
                recordedDistanceMeters: recordedDistanceMeters,
                averageSpeedMetersPerSecond: resolvedAverageSpeed(),
                completedAt: .now
            )
            traversedRouteCoordinates = progress?.traversedRouteCoordinates ?? traversedRouteCoordinates
            persistSnapshotIfNeeded()
        } else if phase != .paused {
            phase = .tracking
        }
    }

    private func shouldUseLocation(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100 else {
            return false
        }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        guard age <= 20 else {
            return false
        }

        return true
    }

    private func resolvedInstantaneousSpeed(for location: CLLocation, previousLocation: CLLocation?) -> Double? {
        if location.speed.isFinite, location.speed >= 0, location.speed < 25 {
            return location.speed
        }

        guard let previousLocation else {
            return nil
        }

        let timeDelta = location.timestamp.timeIntervalSince(previousLocation.timestamp)
        guard timeDelta > 0.5, timeDelta < 20 else {
            return nil
        }

        let distance = location.distance(from: previousLocation)
        let derivedSpeed = distance / timeDelta
        guard derivedSpeed.isFinite, derivedSpeed >= 0, derivedSpeed < 25 else {
            return nil
        }

        return derivedSpeed
    }

    private func updateAverageSpeed(using speed: Double?) {
        guard let speed, speed >= 0.2 else {
            return
        }

        speedSamples.append(speed)
        if speedSamples.count > 8 {
            speedSamples.removeFirst(speedSamples.count - 8)
        }

        averageSpeedMetersPerSecond = resolvedAverageSpeed()
    }

    private func resolvedAverageSpeed() -> Double? {
        if !speedSamples.isEmpty {
            return speedSamples.reduce(0, +) / Double(speedSamples.count)
        }

        guard elapsedTime > 0,
              let completedDistance = progress?.completedProgressDistanceMeters ?? (furthestProgressDistanceMeters > 0 ? furthestProgressDistanceMeters : nil) else {
            return nil
        }

        let derivedSpeed = completedDistance / elapsedTime
        return derivedSpeed.isFinite && derivedSpeed > 0 ? derivedSpeed : nil
    }

    private func appendBreadcrumbCoordinateIfNeeded(_ coordinate: CLLocationCoordinate2D) {
        guard let lastCoordinate = breadcrumbCoordinates.last else {
            breadcrumbCoordinates = [coordinate]
            return
        }

        let lastLocation = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
        let nextLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard nextLocation.distance(from: lastLocation) >= 3 else {
            return
        }

        breadcrumbCoordinates.append(coordinate)
        if breadcrumbCoordinates.count > 1_200 {
            breadcrumbCoordinates.removeFirst(breadcrumbCoordinates.count - 1_200)
        }
    }

    private func estimateRemainingTime(forRemainingDistance remainingDistanceMeters: Double) -> TimeInterval? {
        guard remainingDistanceMeters > 0 else {
            return 0
        }

        if let averageSpeed = resolvedAverageSpeed(),
           averageSpeed.isFinite,
           averageSpeed >= 0.4 {
            return remainingDistanceMeters / averageSpeed
        }

        guard route.estimatedMovingTime > 0, totalRouteDistanceMeters > 0 else {
            return nil
        }

        return route.estimatedMovingTime * (remainingDistanceMeters / totalRouteDistanceMeters)
    }

    private func offRouteThreshold(for location: CLLocation) -> Double {
        min(max(location.horizontalAccuracy * 1.4, 18), 55)
    }

    private func resolvedTravelDirection(
        for match: RouteTrackingAnalyzer.Match,
        totalDistanceMeters: Double
    ) -> RouteTrackingTravelDirection {
        if let travelDirection {
            return travelDirection
        }

        let distanceToRouteStartMeters = distanceToStart(from: match.snappedCoordinate)
        let distanceToRouteEndMeters = distanceToEnd(from: match.snappedCoordinate)
        let startsCloserToEnd = distanceToRouteEndMeters + max(40, distanceToRouteStartMeters * 0.12) < distanceToRouteStartMeters
        let isPastMidpoint = match.progressDistanceMeters >= totalDistanceMeters * 0.55

        if startsCloserToEnd && isPastMidpoint {
            return .reverse
        }

        return .forward
    }

    private func directionalProgressDistance(
        for rawProgressDistanceMeters: Double,
        totalDistanceMeters: Double,
        travelDirection: RouteTrackingTravelDirection
    ) -> Double {
        switch travelDirection {
        case .forward:
            return rawProgressDistanceMeters
        case .reverse:
            return max(0, totalDistanceMeters - rawProgressDistanceMeters)
        }
    }

    private func acceptedMatch(
        _ match: RouteTrackingAnalyzer.Match,
        for location: CLLocation,
        previousLocation: CLLocation?,
        travelDirection: RouteTrackingTravelDirection
    ) -> RouteTrackingAnalyzer.Match? {
        guard let previousLocation else {
            return match
        }

        guard let lastProgressDistance = lastMatchedProgressDistanceMetersRaw ?? progress?.currentProgressDistanceMeters else {
            return match
        }

        let movementDistance = location.distance(from: previousLocation)
        let accuracyBuffer = max(location.horizontalAccuracy, previousLocation.horizontalAccuracy)
        let timeDelta = max(location.timestamp.timeIntervalSince(previousLocation.timestamp), 0)
        let plausibleTravelDistance = min(
            max(movementDistance, timeDelta * 5.5),
            max(totalRouteDistanceMeters, movementDistance)
        )
        let rawProgressDelta = match.progressDistanceMeters - lastProgressDistance
        let directionAdjustedDelta = travelDirection == .reverse ? -rawProgressDelta : rawProgressDelta
        let maxForwardAdvance = max(90, plausibleTravelDistance + (accuracyBuffer * 2.4))
        let maxBackwardRegression = max(220, plausibleTravelDistance + (accuracyBuffer * 3.4))

        guard directionAdjustedDelta <= maxForwardAdvance else {
            return nil
        }

        guard directionAdjustedDelta >= -maxBackwardRegression else {
            return nil
        }

        return match
    }

    private func traversedRouteCoordinates(
        for match: RouteTrackingAnalyzer.Match,
        analyzer: RouteTrackingAnalyzer,
        travelDirection: RouteTrackingTravelDirection
    ) -> [CLLocationCoordinate2D] {
        switch travelDirection {
        case .forward:
            return analyzer.prefixCoordinates(through: match)
        case .reverse:
            return analyzer.suffixCoordinates(through: match)
        }
    }

    private func distanceToStart(from coordinate: CLLocationCoordinate2D) -> Double {
        guard let startCoordinate = route.startCoordinate else {
            return 0
        }

        let startLocation = CLLocation(latitude: startCoordinate.latitude, longitude: startCoordinate.longitude)
        let snappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return snappedLocation.distance(from: startLocation)
    }

    private func distanceToEnd(from coordinate: CLLocationCoordinate2D) -> Double {
        guard let endCoordinate = route.endCoordinate else {
            return 0
        }

        let endLocation = CLLocation(latitude: endCoordinate.latitude, longitude: endCoordinate.longitude)
        let snappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return snappedLocation.distance(from: endLocation)
    }

    private func distanceToGoal(
        from coordinate: CLLocationCoordinate2D,
        travelDirection: RouteTrackingTravelDirection
    ) -> Double {
        switch travelDirection {
        case .forward:
            return distanceToEnd(from: coordinate)
        case .reverse:
            return distanceToStart(from: coordinate)
        }
    }

    private func shouldCompleteRoute(
        completedProgressDistanceMeters: Double,
        distanceToEndMeters: Double,
        distanceToRouteMeters: Double,
        offRouteThresholdMeters: Double
    ) -> Bool {
        guard totalRouteDistanceMeters > 0 else {
            return false
        }

        guard distanceToRouteMeters <= offRouteThresholdMeters else {
            return false
        }

        if completedProgressDistanceMeters >= totalRouteDistanceMeters * 0.995,
           distanceToEndMeters <= max(18, offRouteThresholdMeters) {
            return true
        }

        return completedProgressDistanceMeters >= totalRouteDistanceMeters * 0.97 && distanceToEndMeters <= 30
    }

    private func evaluateOffRouteNotificationsIfNeeded() {
        guard let progress else {
            return
        }

        guard trackingMode == .continuous else {
            if offRouteAlertPolicy.isCurrentlyOffRoute || offRouteAlertPolicy.hasNotifiedCurrentEpisode {
                clearOffRouteAlert()
            }
            return
        }

        let wasOffRoute = offRouteAlertPolicy.isCurrentlyOffRoute || offRouteAlertPolicy.hasNotifiedCurrentEpisode
        let canNotifyNow = UIApplication.shared.applicationState != .active && notificationsAuthorized
        let shouldNotify = offRouteAlertPolicy.shouldNotify(
            isOffRoute: progress.isOffRoute,
            distanceToRouteMeters: progress.distanceToRouteMeters,
            canNotifyNow: canNotifyNow
        )

        guard progress.isOffRoute else {
            if wasOffRoute {
                clearOffRouteAlert()
            }
            return
        }

        guard shouldNotify else {
            return
        }

        offRouteAlertPolicy.noteNotificationSent(distanceToRouteMeters: progress.distanceToRouteMeters)

        let routeName = route.name.trimmed.nilIfEmpty ?? "your route"
        let distanceText = RouteDisplayFormatter.distance(progress.distanceToRouteMeters)
        let notificationID = offRouteAlertNotificationID
        Task {
            await notificationService.scheduleOffRouteAlert(
                routeName: routeName,
                distanceFromRouteText: distanceText,
                notificationID: notificationID
            )
        }
    }

    private func clearOffRouteAlert() {
        offRouteAlertPolicy.reset()

        let notificationID = offRouteAlertNotificationID
        Task {
            await notificationService.clearOffRouteAlert(notificationID: notificationID)
        }
    }

    private var offRouteAlertNotificationID: String {
        "route-tracking-off-route-\(route.stravaRouteID)"
    }
}

extension RouteTrackingSession: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorizationState()

        guard wantsTracking else {
            return
        }

        if isAuthorized {
            if startDate == nil {
                startDate = .now
            }
            beginTracking()
            return
        }

        if authorizationStatus == .denied || authorizationStatus == .restricted {
            wantsTracking = false
            stopTrackingUpdates()
            updateElapsedTime()
            phase = .idle
            clearOffRouteAlert()
            errorMessage = authorizationStatus == .denied
                ? "Location access is denied. Enable it in Settings to track this route."
                : "Location access is restricted on this device."
            persistSnapshotIfNeeded()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard wantsTracking else {
            return
        }

        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.locationUnknown.rawValue {
            return
        }

        errorMessage = error.localizedDescription
        persistSnapshotIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            processLocation(location)
        }
    }
}

private struct RouteTrackingAnalyzer {
    private struct Segment {
        let startCoordinate: CLLocationCoordinate2D
        let endCoordinate: CLLocationCoordinate2D
        let startPoint: MKMapPoint
        let endPoint: MKMapPoint
        let cumulativeStartDistanceMeters: Double
        let segmentDistanceMeters: Double
        let startIndex: Int
    }

    struct Match {
        let snappedCoordinate: CLLocationCoordinate2D
        let progressDistanceMeters: Double
        let distanceToRouteMeters: Double
        let segmentIndex: Int
    }

    let routeCoordinates: [CLLocationCoordinate2D]
    let totalDistanceMeters: Double
    let isLikelyLoopRoute: Bool

    private let segments: [Segment]
    private let routeStartCoordinate: CLLocationCoordinate2D?
    private let routeEndCoordinate: CLLocationCoordinate2D?
    private let loopClosureThresholdMeters: Double

    init(routeCoordinates: [CLLocationCoordinate2D]) {
        self.routeCoordinates = routeCoordinates
        self.routeStartCoordinate = routeCoordinates.first
        self.routeEndCoordinate = routeCoordinates.last

        var builtSegments: [Segment] = []
        var cumulativeDistanceMeters = 0.0

        for index in 0..<(routeCoordinates.count - 1) {
            let startCoordinate = routeCoordinates[index]
            let endCoordinate = routeCoordinates[index + 1]
            let startPoint = MKMapPoint(startCoordinate)
            let endPoint = MKMapPoint(endCoordinate)
            let segmentDistanceMeters = CLLocation(
                latitude: startCoordinate.latitude,
                longitude: startCoordinate.longitude
            )
            .distance(
                from: CLLocation(
                    latitude: endCoordinate.latitude,
                    longitude: endCoordinate.longitude
                )
            )

            guard segmentDistanceMeters > 0.1 else {
                continue
            }

            builtSegments.append(
                Segment(
                    startCoordinate: startCoordinate,
                    endCoordinate: endCoordinate,
                    startPoint: startPoint,
                    endPoint: endPoint,
                    cumulativeStartDistanceMeters: cumulativeDistanceMeters,
                    segmentDistanceMeters: segmentDistanceMeters,
                    startIndex: index
                )
            )

            cumulativeDistanceMeters += segmentDistanceMeters
        }

        self.segments = builtSegments
        self.totalDistanceMeters = cumulativeDistanceMeters
        self.loopClosureThresholdMeters = min(max(cumulativeDistanceMeters * 0.015, 18), 80)
        if let routeStartCoordinate,
           let routeEndCoordinate {
            self.isLikelyLoopRoute = routeStartCoordinate.distance(to: routeEndCoordinate) <= loopClosureThresholdMeters
        } else {
            self.isLikelyLoopRoute = false
        }
    }

    func match(
        for location: CLLocation,
        preferredProgressDistanceMeters: Double? = nil,
        preferEarlierProgress: Bool = false
    ) -> Match? {
        guard !segments.isEmpty else {
            return nil
        }

        let locationPoint = MKMapPoint(location.coordinate)
        var candidates: [Match] = []
        var bestDistanceMeters = CLLocationDistance.greatestFiniteMagnitude

        for (segmentIndex, segment) in segments.enumerated() {
            let deltaX = segment.endPoint.x - segment.startPoint.x
            let deltaY = segment.endPoint.y - segment.startPoint.y
            let segmentLengthSquared = (deltaX * deltaX) + (deltaY * deltaY)
            guard segmentLengthSquared > 0 else {
                continue
            }

            let projectedProgress = (
                ((locationPoint.x - segment.startPoint.x) * deltaX) +
                ((locationPoint.y - segment.startPoint.y) * deltaY)
            ) / segmentLengthSquared
            let clampedProgress = min(max(projectedProgress, 0), 1)

            let projectedPoint = MKMapPoint(
                x: segment.startPoint.x + (deltaX * clampedProgress),
                y: segment.startPoint.y + (deltaY * clampedProgress)
            )

            let distanceToRouteMeters = locationPoint.distance(to: projectedPoint)
            let snappedCoordinate = projectedPoint.coordinate
            let progressDistanceMeters = segment.cumulativeStartDistanceMeters + (segment.segmentDistanceMeters * clampedProgress)

            bestDistanceMeters = min(bestDistanceMeters, distanceToRouteMeters)
            candidates.append(
                Match(
                snappedCoordinate: snappedCoordinate,
                progressDistanceMeters: progressDistanceMeters,
                distanceToRouteMeters: distanceToRouteMeters,
                segmentIndex: segmentIndex
            )
            )
        }

        guard !candidates.isEmpty else {
            return nil
        }

        if let preferredProgressDistanceMeters {
            return candidates.min {
                candidateScore(
                    for: $0,
                    preferredProgressDistanceMeters: preferredProgressDistanceMeters
                ) < candidateScore(
                    for: $1,
                    preferredProgressDistanceMeters: preferredProgressDistanceMeters
                )
            }
        }

        if preferEarlierProgress {
            let distanceTolerance = max(8, bestDistanceMeters * 0.35)
            let cappedCandidates = candidates.filter {
                $0.distanceToRouteMeters <= bestDistanceMeters + distanceTolerance
            }

            return cappedCandidates.min {
                if abs($0.progressDistanceMeters - $1.progressDistanceMeters) > 4 {
                    return $0.progressDistanceMeters < $1.progressDistanceMeters
                }
                return $0.distanceToRouteMeters < $1.distanceToRouteMeters
            }
        }

        return candidates.min { $0.distanceToRouteMeters < $1.distanceToRouteMeters }
    }

    func prefixCoordinates(through match: Match) -> [CLLocationCoordinate2D] {
        guard !segments.isEmpty else {
            return routeCoordinates
        }

        let segment = segments[match.segmentIndex]
        let upperBound = min(segment.startIndex, routeCoordinates.count - 1)
        var prefix = Array(routeCoordinates[0...upperBound])

        if let lastCoordinate = prefix.last,
           lastCoordinate.distance(to: match.snappedCoordinate) < 0.5 {
            return prefix
        }

        prefix.append(match.snappedCoordinate)
        return prefix
    }

    func suffixCoordinates(through match: Match) -> [CLLocationCoordinate2D] {
        guard !segments.isEmpty else {
            return routeCoordinates
        }

        let segment = segments[match.segmentIndex]
        let lowerBound = min(segment.startIndex + 1, routeCoordinates.count - 1)
        var suffix = [match.snappedCoordinate]

        if lowerBound < routeCoordinates.count {
            let tail = Array(routeCoordinates[lowerBound...])
            if let firstTailCoordinate = tail.first,
               firstTailCoordinate.distance(to: match.snappedCoordinate) < 0.5 {
                suffix.append(contentsOf: tail.dropFirst())
            } else {
                suffix.append(contentsOf: tail)
            }
        }

        return suffix
    }

    func isNearRouteStart(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let routeStartCoordinate else {
            return false
        }

        return routeStartCoordinate.distance(to: coordinate) <= loopClosureThresholdMeters
    }

    private func candidateScore(
        for candidate: Match,
        preferredProgressDistanceMeters: Double
    ) -> Double {
        let progressDelta = candidate.progressDistanceMeters - preferredProgressDistanceMeters
        let backwardPenalty = progressDelta < 0 ? abs(progressDelta) * 0.03 : 0
        let forwardPenalty = progressDelta > 0 ? progressDelta * 0.01 : 0
        return candidate.distanceToRouteMeters + backwardPenalty + forwardPenalty
    }
}

private extension CLLocationCoordinate2D {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}
