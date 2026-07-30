import CryptoKit
import Foundation

struct RouteVaultListSyncService {
    enum SyncError: LocalizedError {
        case missingAccountSession

        var errorDescription: String? {
            switch self {
            case .missingAccountSession:
                return "Connect Strava and finish Terigo account setup before syncing lists."
            }
        }
    }

    private let backendService: RouteVaultBackendService
    private let accountSessionStore: RouteVaultAccountSessionStore
    private let offlineAssetService: RouteOfflineAssetService
    private let encoder: JSONEncoder

    init(
        backendService: RouteVaultBackendService = RouteVaultBackendService(),
        accountSessionStore: RouteVaultAccountSessionStore = RouteVaultAccountSessionStore(),
        offlineAssetService: RouteOfflineAssetService = RouteOfflineAssetService()
    ) {
        self.backendService = backendService
        self.accountSessionStore = accountSessionStore
        self.offlineAssetService = offlineAssetService
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func auditShareability(for routes: [RouteRecord]) -> RouteListShareabilityAudit {
        let issues = routes.compactMap { route -> RouteListShareabilityIssue? in
            if route.isPrivate && !route.hasOfflineAssets {
                return RouteListShareabilityIssue(
                    routeID: route.stravaRouteID,
                    routeName: route.name,
                    kind: .privateRouteMissingDownloadedDetails
                )
            }

            return nil
        }

        return RouteListShareabilityAudit(issues: issues)
    }

    func sync(
        list: RouteList,
        routes: [RouteRecord]
    ) async throws -> RouteVaultListSyncResponse {
        guard let accountSession = try accountSessionStore.load() else {
            throw SyncError.missingAccountSession
        }

        let request = RouteVaultListSyncRequest(
            clientListID: list.id,
            remoteListID: list.remoteListID?.trimmed.nilIfEmpty,
            remoteShareToken: list.remoteShareToken?.trimmed.nilIfEmpty,
            expectedRevision: list.remoteRevision > 0 ? list.remoteRevision : nil,
            name: list.name,
            listDescription: list.listDescription.trimmed,
            visibility: list.sharingVisibility.rawValue,
            collaborationMode: list.collaborationMode.rawValue,
            collaboratorCodes: list.collaboratorCodes,
            viewerCodes: list.viewerCodes,
            routes: routes.map(makeSyncedRoutePayload)
        )

        return try await backendService.syncList(request, accountSessionToken: accountSession.token)
    }

    func fingerprint(for list: RouteList, routes: [RouteRecord]) -> String {
        struct FingerprintRoute: Encodable {
            let stravaRouteID: Int
            let name: String
            let routeDescription: String
            let distanceMeters: Double
            let elevationGainMeters: Double
            let estimatedMovingTime: Double
            let sportKind: String
            let surfaceKind: String?
            let displayLocation: String
            let isPrivateOnStrava: Bool
            let summaryPolyline: String
            let detailPolyline: String?
            let hasDownloadedDetails: Bool
        }

        struct FingerprintPayload: Encodable {
            let name: String
            let listDescription: String
            let visibility: String
            let collaborationMode: String
            let collaboratorCodes: [String]
            let viewerCodes: [String]
            let routes: [FingerprintRoute]
        }

        let payload = FingerprintPayload(
            name: list.name.trimmed,
            listDescription: list.listDescription.trimmed,
            visibility: list.sharingVisibility.rawValue,
            collaborationMode: list.collaborationMode.rawValue,
            collaboratorCodes: list.collaboratorCodes.sorted(),
            viewerCodes: list.viewerCodes.sorted(),
            routes: routes
                .sorted { $0.stravaRouteID < $1.stravaRouteID }
                .map { route in
                    FingerprintRoute(
                        stravaRouteID: route.stravaRouteID,
                        name: route.name,
                        routeDescription: route.routeDescription,
                        distanceMeters: route.distanceMeters,
                        elevationGainMeters: route.elevationGainMeters,
                        estimatedMovingTime: route.estimatedMovingTime,
                        sportKind: route.sportKind.rawValue,
                        surfaceKind: route.surfaceKind?.rawValue,
                        displayLocation: route.displayLocation,
                        isPrivateOnStrava: route.isPrivate,
                        summaryPolyline: route.mapSummaryPolyline,
                        detailPolyline: route.routeDetailPolyline?.trimmed.nilIfEmpty,
                        hasDownloadedDetails: route.hasOfflineAssets
                    )
                }
        )

        guard let data = try? encoder.encode(payload) else {
            return UUID().uuidString
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func shouldSync(list: RouteList, routes: [RouteRecord]) -> Bool {
        guard list.canSyncRemotelyFromThisDevice else {
            return false
        }

        let syncFingerprint = fingerprint(for: list, routes: routes)
        if list.remoteListID?.trimmed.nilIfEmpty == nil {
            return true
        }

        return syncFingerprint != list.lastRemoteSyncFingerprint
    }

    func publicShareURL(for list: RouteList) -> URL? {
        guard let shareToken = list.remoteShareToken?.trimmed.nilIfEmpty else {
            return nil
        }

        return backendService.publicShareURL(for: shareToken)
    }

    private func makeSyncedRoutePayload(for route: RouteRecord) -> RouteVaultSyncedRoutePayload {
        RouteVaultSyncedRoutePayload(
            stravaRouteID: route.stravaRouteID,
            name: route.name,
            routeDescription: route.routeDescription,
            distanceMeters: route.distanceMeters,
            elevationGainMeters: route.elevationGainMeters,
            estimatedMovingTime: route.estimatedMovingTime,
            sportKind: route.sportKind.rawValue,
            surfaceKind: route.surfaceKind?.rawValue,
            displayLocation: route.displayLocation,
            isPrivateOnStrava: route.isPrivate,
            summaryPolyline: route.mapSummaryPolyline,
            detailPolyline: route.routeDetailPolyline?.trimmed.nilIfEmpty,
            hasDownloadedDetails: route.hasOfflineAssets,
            gpxPayload: gpxPayload(for: route)
        )
    }

    private func gpxPayload(for route: RouteRecord) -> String? {
        guard let gpxURL = offlineAssetService.gpxURL(for: route),
              let gpxData = try? Data(contentsOf: gpxURL),
              !gpxData.isEmpty else {
            return nil
        }

        return String(data: gpxData, encoding: .utf8)
    }
}
