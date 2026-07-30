import Foundation

struct RouteVaultAccountProfile: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let stravaAthleteID: Int
    let displayName: String
    let avatarURLString: String?
    let createdAt: Date?
    let updatedAt: Date?

    var avatarURL: URL? {
        guard let avatarURLString else {
            return nil
        }

        return URL(string: avatarURLString)
    }

    var accountCode: String {
        RouteVaultAccountCode.accountCode(for: stravaAthleteID)
    }
}

enum RouteVaultAccountCode {
    static let prefix = "TG-"

    static func accountCode(for athleteID: Int) -> String {
        "\(prefix)\(String(athleteID, radix: 36).uppercased())"
    }

    static func normalize(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let squashed = trimmed
            .uppercased()
            .replacingOccurrences(of: " ", with: "")

        if let athleteID = Int(squashed) {
            return accountCode(for: athleteID)
        }

        let payload = squashed.hasPrefix(prefix) ? String(squashed.dropFirst(prefix.count)) : squashed
        guard !payload.isEmpty,
              payload.allSatisfy({ $0.isNumber || ($0 >= "A" && $0 <= "Z") }) else {
            return nil
        }

        return "\(prefix)\(payload)"
    }
}

struct RouteVaultAccountSession: Codable, Equatable {
    let token: String
    let expiresAt: Date
    let profile: RouteVaultAccountProfile

    var requiresRefresh: Bool {
        expiresAt <= Date().addingTimeInterval(10 * 60)
    }
}

enum RouteVaultRemoteListAccessRole: String, Codable, CaseIterable {
    case owner
    case editor
    case viewer
    case follower

    var canEdit: Bool {
        switch self {
        case .owner, .editor:
            return true
        case .viewer, .follower:
            return false
        }
    }

    var isOwnedByCurrentAccount: Bool {
        self == .owner
    }
}

struct RouteListShareabilityIssue: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case privateRouteMissingDownloadedDetails = "private_route_missing_downloaded_details"
        case routeViewOnlyUntilDownloaded = "route_view_only_until_downloaded"
    }

    let routeID: Int
    let routeName: String
    let kind: Kind

    var id: String {
        "\(routeID)-\(kind.rawValue)"
    }

    var message: String {
        switch kind {
        case .privateRouteMissingDownloadedDetails:
            return "\(routeName) is private on Strava and has not been downloaded in Terigo yet, so other people will not be able to view or download it."
        case .routeViewOnlyUntilDownloaded:
            return "\(routeName) can appear in the shared list, but it cannot be downloaded by other people until route details have been downloaded in Terigo."
        }
    }
}

struct RouteListShareabilityAudit: Codable, Equatable {
    let issues: [RouteListShareabilityIssue]

    var hasBlockingIssues: Bool {
        issues.contains { $0.kind == .privateRouteMissingDownloadedDetails }
    }

    var blockingPrivateRouteCount: Int {
        issues.filter { $0.kind == .privateRouteMissingDownloadedDetails }.count
    }

    var summaryText: String? {
        if hasBlockingIssues {
            return "\(blockingPrivateRouteCount) private \(blockingPrivateRouteCount == 1 ? "route is" : "routes are") not downloaded on this device yet."
        }

        return nil
    }
}

struct RouteVaultSyncedRoutePayload: Codable, Equatable {
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
    let gpxPayload: String?
}

struct RouteVaultListSyncRequest: Codable, Equatable {
    let clientListID: String
    let remoteListID: String?
    let remoteShareToken: String?
    let expectedRevision: Int?
    let name: String
    let listDescription: String
    let visibility: String
    let collaborationMode: String
    let collaboratorCodes: [String]
    let viewerCodes: [String]
    let routes: [RouteVaultSyncedRoutePayload]
}

struct RouteVaultListSyncResponse: Codable, Equatable {
    let listID: String
    let ownerAccountID: String
    let shareToken: String
    let revision: Int
    let updatedAt: Date
    let shareabilityIssues: [RouteListShareabilityIssue]
}

struct RouteVaultSharedRoutePayload: Codable, Equatable, Identifiable {
    let stravaRouteID: Int
    let name: String
    let routeDescription: String
    let distanceMeters: Double
    let elevationGainMeters: Double
    let estimatedMovingTime: Double
    let sportKind: String
    let surfaceKind: String?
    let displayLocation: String
    let summaryPolyline: String
    let detailPolyline: String?
    let isDownloadable: Bool
    let downloadURLString: String?
    let shareabilityStatus: String
    let shareabilityMessage: String?

    var id: Int { stravaRouteID }

    var downloadURL: URL? {
        guard let downloadURLString else {
            return nil
        }

        return URL(string: downloadURLString)
    }
}

struct RouteVaultSharedListPayload: Codable, Equatable {
    let listID: String
    let name: String
    let listDescription: String
    let ownerDisplayName: String
    let visibility: String
    let collaborationMode: String
    let collaboratorCodes: [String]
    let viewerCodes: [String]
    let revision: Int
    let updatedAt: Date
    let routes: [RouteVaultSharedRoutePayload]
}

struct RouteVaultAccountListPayload: Codable, Equatable, Identifiable {
    let listID: String
    let shareToken: String
    let name: String
    let listDescription: String
    let ownerAccountID: String
    let ownerDisplayName: String
    let visibility: String
    let collaborationMode: String
    let collaboratorCodes: [String]
    let viewerCodes: [String]
    let relationship: RouteVaultRemoteListAccessRole
    let revision: Int
    let updatedAt: Date
    let routes: [RouteVaultSharedRoutePayload]

    var id: String { listID }
}

struct RouteVaultAccountListsResponse: Codable, Equatable {
    let lists: [RouteVaultAccountListPayload]
}

struct RouteVaultSharedListLink: Equatable {
    enum Kind: Equatable {
        case backendShareToken(String)
        case embeddedPayload(RouteListSharePayload)
    }

    let kind: Kind

    static func decode(from url: URL) -> RouteVaultSharedListLink? {
        if let payload = RouteListSharePayload.decode(from: url) {
            return RouteVaultSharedListLink(kind: .embeddedPayload(payload))
        }

        if let shareToken = shareToken(from: url) {
            return RouteVaultSharedListLink(kind: .backendShareToken(shareToken))
        }

        return nil
    }

    private static func shareToken(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value?.trimmed.nilIfEmpty else {
            return nil
        }

        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let path = url.path.lowercased()

        if scheme == "routevault", host == "lists", path.contains("shared") {
            return token
        }

        if path.contains("/lists/shared") {
            return token
        }

        if path.contains("shared-list") {
            return token
        }

        return nil
    }
}
