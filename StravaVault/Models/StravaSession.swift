import Foundation

struct StravaAppCredentials: Codable, Equatable {
    let clientID: String
    let clientSecret: String?
    let redirectScheme: String
    let redirectHost: String
    let authBrokerBaseURLString: String?

    var redirectURI: String {
        "\(redirectScheme)://\(redirectHost)/oauth-callback"
    }

    var authBrokerBaseURL: URL? {
        guard let authBrokerBaseURLString else {
            return nil
        }

        return RouteVaultRuntimeConfiguration.trustedServiceURL(from: authBrokerBaseURLString)
    }
}

struct StravaAthleteProfile: Codable, Equatable {
    let id: Int
    let username: String?
    let firstName: String?
    let lastName: String?
    let profileMedium: String?
    let profile: String?

    var displayName: String {
        let fullName = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !fullName.isEmpty {
            return fullName
        }

        if let username, !username.isEmpty {
            return username
        }

        return "Connected Athlete"
    }

    var avatarURL: URL? {
        URL(string: profileMedium ?? profile ?? "")
    }
}

struct StravaSession: Codable, Equatable {
    let athlete: StravaAthleteProfile
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let acceptedScopes: [String]

    var scopeSummary: String {
        acceptedScopes.joined(separator: ", ")
    }

    var hasReadAllAccess: Bool {
        acceptedScopes.contains("read_all")
    }

    var hasActivityReadAccess: Bool {
        acceptedScopes.contains("activity:read") || acceptedScopes.contains("activity:read_all")
    }

    var hasActivityReadAllAccess: Bool {
        acceptedScopes.contains("activity:read_all")
    }

    var hasActivityWriteAccess: Bool {
        acceptedScopes.contains("activity:write")
    }
}

struct ImportSummary: Equatable {
    let insertedCount: Int
    let updatedCount: Int
    let totalRemoteRoutes: Int
    let skippedDeletedCount: Int
    let finishedAt: Date
}
