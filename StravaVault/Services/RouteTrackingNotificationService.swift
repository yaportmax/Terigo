import Foundation
import UserNotifications

struct RouteTrackingOffRouteAlertPolicy {
    private enum Defaults {
        static let repeatNotificationCooldown: TimeInterval = 120
        static let repeatNotificationDistanceDeltaMeters: Double = 35
    }

    private(set) var isCurrentlyOffRoute = false
    private(set) var hasNotifiedCurrentEpisode = false
    private(set) var lastNotificationAt: Date?
    private(set) var lastNotificationDistanceMeters: Double?

    mutating func shouldNotify(
        isOffRoute: Bool,
        distanceToRouteMeters: Double,
        canNotifyNow: Bool,
        now: Date = .now
    ) -> Bool {
        guard isOffRoute else {
            resetEpisode()
            return false
        }

        let startedNewEpisode = !isCurrentlyOffRoute
        isCurrentlyOffRoute = true

        guard canNotifyNow else {
            return false
        }

        if startedNewEpisode || !hasNotifiedCurrentEpisode {
            return true
        }

        guard let lastNotificationAt else {
            return true
        }

        guard now.timeIntervalSince(lastNotificationAt) >= Defaults.repeatNotificationCooldown else {
            return false
        }

        let lastDistance = lastNotificationDistanceMeters ?? 0
        return distanceToRouteMeters >= lastDistance + Defaults.repeatNotificationDistanceDeltaMeters
    }

    mutating func noteNotificationSent(distanceToRouteMeters: Double, at date: Date = .now) {
        isCurrentlyOffRoute = true
        hasNotifiedCurrentEpisode = true
        lastNotificationAt = date
        lastNotificationDistanceMeters = distanceToRouteMeters
    }

    mutating func resetEpisode() {
        isCurrentlyOffRoute = false
        hasNotifiedCurrentEpisode = false
        lastNotificationAt = nil
        lastNotificationDistanceMeters = nil
    }

    mutating func reset() {
        resetEpisode()
    }
}

actor RouteTrackingNotificationService {
    static let shared = RouteTrackingNotificationService()

    private let center = UNUserNotificationCenter.current()

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let status = await currentAuthorizationStatus()
        guard status == .notDetermined else {
            return status
        }

        _ = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }

        return await currentAuthorizationStatus()
    }

    func scheduleOffRouteAlert(
        routeName: String,
        distanceFromRouteText: String,
        notificationID: String
    ) async {
        let resolvedRouteName = routeName.trimmed.nilIfEmpty ?? "your route"

        let content = UNMutableNotificationContent()
        content.title = "Off Route"
        content.body = "You're about \(distanceFromRouteText) away from \(resolvedRouteName). Open Terigo to get back on track."
        content.sound = .default
        content.threadIdentifier = "route-tracking"

        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])

        await withCheckedContinuation { continuation in
            center.add(request) { _ in
                continuation.resume(returning: ())
            }
        }
    }

    func clearOffRouteAlert(notificationID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }
}
