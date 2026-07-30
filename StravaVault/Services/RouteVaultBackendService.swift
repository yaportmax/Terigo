import Foundation

struct RouteVaultBackendService {
    enum BackendError: LocalizedError {
        case missingConfiguration
        case invalidResponse
        case unauthorized
        case conflict(String)
        case server(String)
        case transport(URLError, URL?)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Terigo backend configuration is missing on this build."
            case .invalidResponse:
                return "The Terigo backend returned an invalid response."
            case .unauthorized:
                return "Your Terigo account session is no longer valid. Reconnect Strava and try again."
            case let .conflict(message):
                return message
            case let .server(message):
                return message
            case let .transport(error, url):
                return Self.transportMessage(for: error, url: url)
            }
        }

        private static func transportMessage(for error: URLError, url: URL?) -> String {
            switch error.code {
            case .cannotFindHost:
                let host = url?.host?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let host, !host.isEmpty {
                    return "Terigo's hosted backend could not be found at \(host). Check that the configured Supabase project is active and rebuild with the live backend URL."
                }
                return "Terigo's hosted backend could not be found. Check that the configured Supabase project is active and rebuild with the live backend URL."
            case .notConnectedToInternet:
                return "The internet connection appears to be offline. Connect to the internet and try again."
            case .timedOut:
                return "The Terigo backend request timed out. Try again in a few minutes."
            case .cannotConnectToHost:
                return "Terigo's hosted backend could not be reached. Check that the backend is running and try again."
            case .networkConnectionLost:
                return "The network connection was lost while contacting Terigo's backend. Try again."
            default:
                return "The Terigo backend request failed: \(error.localizedDescription)"
            }
        }
    }

    private struct AccountBootstrapRequest: Encodable {
        struct StravaSessionPayload: Encodable {
            let accessToken: String
        }

        struct DevicePayload: Encodable {
            let platform: String
            let appVersion: String
            let buildNumber: String
        }

        let stravaSession: StravaSessionPayload
        let device: DevicePayload
    }

    private struct ErrorEnvelope: Decodable {
        let error: String?
    }

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func bootstrapAccount(
        with stravaSession: StravaSession
    ) async throws -> RouteVaultAccountSession {
        guard let url = RouteVaultRuntimeConfiguration.functionsBaseURL?.appending(path: "account-bootstrap") else {
            throw BackendError.missingConfiguration
        }

        let requestBody = AccountBootstrapRequest(
            stravaSession: .init(
                accessToken: stravaSession.accessToken
            ),
            device: .init(
                platform: "ios",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            )
        )

        return try await send(requestBody, to: url, accountSessionToken: nil)
    }

    func deleteAccount(accountSessionToken: String) async throws {
        struct DeleteAccountRequest: Encodable {}
        struct DeleteAccountResponse: Decodable {
            let ok: Bool
        }

        guard let url = RouteVaultRuntimeConfiguration.functionsBaseURL?.appending(path: "delete-account") else {
            throw BackendError.missingConfiguration
        }

        let response: DeleteAccountResponse = try await send(
            DeleteAccountRequest(),
            to: url,
            accountSessionToken: accountSessionToken
        )

        guard response.ok else {
            throw BackendError.invalidResponse
        }
    }

    func syncList(
        _ requestBody: RouteVaultListSyncRequest,
        accountSessionToken: String
    ) async throws -> RouteVaultListSyncResponse {
        guard let url = RouteVaultRuntimeConfiguration.functionsBaseURL?.appending(path: "sync-list") else {
            throw BackendError.missingConfiguration
        }

        return try await send(requestBody, to: url, accountSessionToken: accountSessionToken)
    }

    func fetchAccountLists(accountSessionToken: String) async throws -> RouteVaultAccountListsResponse {
        guard let url = RouteVaultRuntimeConfiguration.functionsBaseURL?.appending(path: "account-lists") else {
            throw BackendError.missingConfiguration
        }

        return try await sendGET(to: url, accountSessionToken: accountSessionToken)
    }

    func fetchSharedList(
        shareToken: String,
        accountSessionToken: String? = nil
    ) async throws -> RouteVaultSharedListPayload {
        guard let baseURL = RouteVaultRuntimeConfiguration.sharedListBaseURL else {
            throw BackendError.missingConfiguration
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "token", value: shareToken)
        ]

        guard let url = components?.url else {
            throw BackendError.invalidResponse
        }

        return try await sendGET(to: url, accountSessionToken: accountSessionToken)
    }

    func setFollowState(
        shareToken: String,
        isFollowing: Bool,
        accountSessionToken: String
    ) async throws {
        struct FollowRequest: Encodable {
            let shareToken: String
            let isFollowing: Bool
        }

        struct FollowResponse: Decodable {
            let ok: Bool
        }

        guard let url = RouteVaultRuntimeConfiguration.functionsBaseURL?.appending(path: "follow-list") else {
            throw BackendError.missingConfiguration
        }

        _ = try await send(
            FollowRequest(shareToken: shareToken, isFollowing: isFollowing),
            to: url,
            accountSessionToken: accountSessionToken
        ) as FollowResponse
    }

    func submitFeedback(
        message: String,
        sourceScreen: String,
        accountSessionToken: String
    ) async throws {
        struct FeedbackRequest: Encodable {
            let message: String
            let sourceScreen: String
            let appVersion: String
            let buildNumber: String
        }

        struct FeedbackResponse: Decodable {
            let ok: Bool
        }

        guard let url = RouteVaultRuntimeConfiguration.functionsBaseURL?.appending(path: "submit-feedback") else {
            throw BackendError.missingConfiguration
        }

        _ = try await send(
            FeedbackRequest(
                message: message,
                sourceScreen: sourceScreen,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            ),
            to: url,
            accountSessionToken: accountSessionToken
        ) as FeedbackResponse
    }

    func downloadSharedRouteGPX(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let publishableKey = RouteVaultRuntimeConfiguration.supabasePublishableKey {
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw BackendError.transport(error, request.url)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BackendError.server(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }

        return data
    }

    func publicShareURL(for shareToken: String) -> URL? {
        if let shareBaseURL = RouteVaultRuntimeConfiguration.shareBaseURL {
            var components = URLComponents(
                url: shareBaseURL
                    .appending(path: "lists")
                    .appending(path: "shared"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "token", value: shareToken)
            ]
            if let url = components?.url {
                return url
            }
        }

        guard let baseURL = RouteVaultRuntimeConfiguration.sharedListBaseURL else {
            return nil
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "token", value: shareToken)
        ]
        return components?.url
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ body: Body,
        to url: URL,
        accountSessionToken: String?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let publishableKey = RouteVaultRuntimeConfiguration.supabasePublishableKey {
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        }
        if let accountSessionToken {
            request.setValue("Bearer \(accountSessionToken)", forHTTPHeaderField: "X-RouteVault-Session")
        }
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    private func sendGET<Response: Decodable>(
        to url: URL,
        accountSessionToken: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let publishableKey = RouteVaultRuntimeConfiguration.supabasePublishableKey {
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        }
        if let accountSessionToken {
            request.setValue("Bearer \(accountSessionToken)", forHTTPHeaderField: "X-RouteVault-Session")
        }
        return try await execute(request)
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw BackendError.transport(error, request.url)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw BackendError.invalidResponse
            }
        case 409:
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data).error)?.trimmed.nilIfEmpty
            throw BackendError.conflict(message ?? "This list changed elsewhere. Reload the latest shared state before syncing again.")
        case 401:
            throw BackendError.unauthorized
        case 403:
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data).error)?.trimmed.nilIfEmpty
            throw BackendError.server(message ?? "You do not have permission to open this Terigo list.")
        default:
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data).error)?.trimmed.nilIfEmpty
            if let message, isUnauthorizedBackendMessage(message) {
                throw BackendError.unauthorized
            }
            throw BackendError.server(message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }
    }

    private func isUnauthorizedBackendMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("session is invalid or expired")
            || normalized.contains("missing terigo account session")
    }
}
