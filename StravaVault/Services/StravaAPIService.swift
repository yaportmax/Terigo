import Foundation

struct StravaAPIService {
    private actor RequestCoordinator {
        struct CachedValue<Value> {
            let value: Value
            let expiresAt: Date
        }

        private var refreshedSessions: [String: CachedValue<StravaSession>] = [:]
        private var refreshTasks: [String: Task<StravaSession, Error>] = [:]
        private var routeGPXCache: [Int: CachedValue<Data>] = [:]
        private var routeGPXTasks: [Int: Task<Data, Error>] = [:]

        func cachedSession(for refreshToken: String) -> StravaSession? {
            guard let entry = refreshedSessions[refreshToken], entry.expiresAt > Date() else {
                refreshedSessions[refreshToken] = nil
                return nil
            }
            return entry.value
        }

        func storeSession(_ session: StravaSession, for refreshToken: String) {
            refreshedSessions[refreshToken] = CachedValue(
                value: session,
                expiresAt: Date().addingTimeInterval(30)
            )
        }

        func refreshTask(for refreshToken: String) -> Task<StravaSession, Error>? {
            refreshTasks[refreshToken]
        }

        func setRefreshTask(_ task: Task<StravaSession, Error>, for refreshToken: String) {
            refreshTasks[refreshToken] = task
        }

        func clearRefreshTask(for refreshToken: String) {
            refreshTasks[refreshToken] = nil
        }

        func cachedRouteGPX(for routeID: Int) -> Data? {
            guard let entry = routeGPXCache[routeID], entry.expiresAt > Date() else {
                routeGPXCache[routeID] = nil
                return nil
            }
            return entry.value
        }

        func storeRouteGPX(_ data: Data, for routeID: Int) {
            routeGPXCache[routeID] = CachedValue(
                value: data,
                expiresAt: Date().addingTimeInterval(10 * 60)
            )
        }

        func routeGPXTask(for routeID: Int) -> Task<Data, Error>? {
            routeGPXTasks[routeID]
        }

        func setRouteGPXTask(_ task: Task<Data, Error>, for routeID: Int) {
            routeGPXTasks[routeID] = task
        }

        func clearRouteGPXTask(for routeID: Int) {
            routeGPXTasks[routeID] = nil
        }
    }

    private static let requestCoordinator = RequestCoordinator()

    private static let requestedScopes = [
        "read",
        "read_all",
        "activity:read",
        "activity:read_all",
        "activity:write"
    ]

    enum APIError: LocalizedError {
        case invalidRedirect
        case missingAuthorizationCode
        case cancelled
        case invalidState
        case missingCredentials
        case invalidClientID
        case missingAuthBroker
        case rateLimited(String, retryAfter: Date?)
        case server(String)
        case unauthorized
        case badResponse(String?)
        case missingRouteData
        case transport(URLError, URL?)

        var requiresSessionReset: Bool {
            switch self {
            case .unauthorized, .missingAuthBroker, .missingCredentials:
                return true
            case let .server(message):
                return Self.messageSuggestsSessionReset(message)
            case let .badResponse(message):
                return Self.messageSuggestsSessionReset(message)
            default:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidRedirect:
                return "The Strava redirect URL was malformed."
            case .missingAuthorizationCode:
                return "Strava did not return an authorization code."
            case .cancelled:
                return "The Strava authorization flow was cancelled."
            case .invalidState:
                return "The Strava callback could not be verified."
            case .missingCredentials:
                return "A Strava client ID is required."
            case .invalidClientID:
                return "The Strava client ID must be numeric."
            case .missingAuthBroker:
                return "This build is missing a usable Strava client secret or auth broker URL."
            case let .rateLimited(message, _):
                return message
            case let .server(message):
                return message
            case .unauthorized:
                return "Your Strava session is no longer authorized. Reconnect and try again."
            case let .badResponse(message):
                return message ?? "Strava returned an unexpected response."
            case .missingRouteData:
                return "Strava did not return route file data for this route."
            case let .transport(error, url):
                return Self.transportMessage(for: error, url: url)
            }
        }

        private static func messageSuggestsSessionReset(_ message: String?) -> Bool {
            guard let normalized = message?
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !normalized.isEmpty else {
                return false
            }

            let sessionResetHints = [
                "invalid_grant",
                "refresh_token",
                "refresh token",
                "authorization code",
                "invalid token",
                "access token",
                "revoked",
                "unauthorized",
                "not authorized",
                "code: invalid"
            ]

            return sessionResetHints.contains { normalized.contains($0) }
        }

        private static func transportMessage(for error: URLError, url: URL?) -> String {
            let host = url?.host?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBrokerRequest = url?.path.localizedCaseInsensitiveContains("strava-auth-broker") == true
                || host?.localizedCaseInsensitiveContains("supabase.co") == true

            switch error.code {
            case .cannotFindHost:
                if isBrokerRequest {
                    if let host, !host.isEmpty {
                        return "Terigo's Strava auth broker could not be found at \(host). Check that the configured Supabase project is active and rebuild with the live broker URL."
                    }
                    return "Terigo's Strava auth broker could not be found. Check that the configured Supabase project is active and rebuild with the live broker URL."
                }
                if let host, !host.isEmpty {
                    return "The Strava server host could not be found at \(host). Check your connection and try again."
                }
                return "The Strava server host could not be found. Check your connection and try again."
            case .notConnectedToInternet:
                return "The internet connection appears to be offline. Connect to the internet and try again."
            case .timedOut:
                return isBrokerRequest
                    ? "The Terigo Strava auth broker request timed out. Try again in a few minutes."
                    : "The Strava request timed out. Try again in a few minutes."
            case .cannotConnectToHost:
                return isBrokerRequest
                    ? "Terigo's Strava auth broker could not be reached. Check that the backend is running and try again."
                    : "Strava could not be reached. Check your connection and try again."
            case .networkConnectionLost:
                return "The network connection was lost. Try again."
            default:
                return isBrokerRequest
                    ? "The Terigo Strava auth broker request failed: \(error.localizedDescription)"
                    : "The Strava request failed: \(error.localizedDescription)"
            }
        }
    }

    struct CallbackResult {
        let authorizationCode: String
        let acceptedScopes: [String]
    }

    private let session: URLSession = .shared
    private let apiBaseURL = URL(string: "https://www.strava.com/api/v3")!
    private let oauthBaseURL = URL(string: "https://www.strava.com/oauth/mobile/authorize")!
    private let oauthTokenURL = URL(string: "https://www.strava.com/api/v3/oauth/token")!

    func authorizationURL(credentials: StravaAppCredentials, state: String) -> URL {
        var components = URLComponents(url: oauthBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: credentials.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: Self.requestedScopes.joined(separator: ",")),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    func parseCallback(_ callbackURL: URL, expectedState: String) throws -> CallbackResult {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidRedirect
        }

        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if items["error"] == "access_denied" {
            throw APIError.cancelled
        }

        guard items["state"] == expectedState else {
            throw APIError.invalidState
        }

        guard let code = items["code"], !code.isEmpty else {
            throw APIError.missingAuthorizationCode
        }

        let scopes = items["scope"]?
            .split(separator: ",")
            .map(String.init) ?? []

        return CallbackResult(authorizationCode: code, acceptedScopes: scopes)
    }

    func exchangeCode(_ code: String, credentials: StravaAppCredentials, acceptedScopes: [String]) async throws -> StravaSession {
        let tokenResponse: StravaTokenResponse

        if let authBrokerBaseURL = credentials.authBrokerBaseURL {
            tokenResponse = try await sendBrokerRequest(
                to: authBrokerBaseURL,
                path: "exchange",
                body: BrokerExchangeRequest(
                    clientID: credentials.clientID,
                    code: code,
                    redirectURI: credentials.redirectURI
                )
            )
        } else {
            guard let clientSecret = credentials.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clientSecret.isEmpty else {
                throw APIError.missingAuthBroker
            }

            tokenResponse = try await sendFormRequest(
                to: oauthTokenURL,
                bodyItems: [
                    URLQueryItem(name: "client_id", value: credentials.clientID),
                    URLQueryItem(name: "client_secret", value: clientSecret),
                    URLQueryItem(name: "code", value: code),
                    URLQueryItem(name: "grant_type", value: "authorization_code")
                ],
                accessToken: nil
            )
        }

        guard let athlete = tokenResponse.athlete?.athleteProfile else {
            throw APIError.badResponse("Strava did not include athlete data in the authorization response.")
        }

        return StravaSession(
            athlete: athlete,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(tokenResponse.expiresAt)),
            acceptedScopes: acceptedScopes
        )
    }

    func refreshedSessionIfNeeded(_ session: StravaSession, credentials: StravaAppCredentials, forceRefresh: Bool = false) async throws -> StravaSession {
        if !forceRefresh, session.expiresAt > Date().addingTimeInterval(120) {
            return session
        }

        if !forceRefresh, let cachedSession = await Self.requestCoordinator.cachedSession(for: session.refreshToken) {
            return cachedSession
        }

        if let inFlightTask = await Self.requestCoordinator.refreshTask(for: session.refreshToken) {
            return try await inFlightTask.value
        }

        let refreshTask = Task<StravaSession, Error> {
            let tokenResponse: StravaTokenResponse

            if let authBrokerBaseURL = credentials.authBrokerBaseURL {
                tokenResponse = try await sendBrokerRequest(
                    to: authBrokerBaseURL,
                    path: "refresh",
                    body: BrokerRefreshRequest(
                        clientID: credentials.clientID,
                        refreshToken: session.refreshToken
                    )
                )
            } else {
                guard let clientSecret = credentials.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !clientSecret.isEmpty else {
                    throw APIError.missingAuthBroker
                }

                tokenResponse = try await sendFormRequest(
                    to: oauthTokenURL,
                    bodyItems: [
                        URLQueryItem(name: "client_id", value: credentials.clientID),
                        URLQueryItem(name: "client_secret", value: clientSecret),
                        URLQueryItem(name: "grant_type", value: "refresh_token"),
                        URLQueryItem(name: "refresh_token", value: session.refreshToken)
                    ],
                    accessToken: nil
                )
            }

            return StravaSession(
                athlete: tokenResponse.athlete?.athleteProfile ?? session.athlete,
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(tokenResponse.expiresAt)),
                acceptedScopes: session.acceptedScopes
            )
        }

        await Self.requestCoordinator.setRefreshTask(refreshTask, for: session.refreshToken)

        do {
            let refreshedSession = try await refreshTask.value
            await Self.requestCoordinator.storeSession(refreshedSession, for: session.refreshToken)
            await Self.requestCoordinator.clearRefreshTask(for: session.refreshToken)
            return refreshedSession
        } catch {
            await Self.requestCoordinator.clearRefreshTask(for: session.refreshToken)
            throw error
        }
    }

    func fetchRoute(routeID: Int, accessToken: String) async throws -> StravaRoutePayload {
        let url = apiBaseURL.appendingPathComponent("routes/\(routeID)")
        return try await sendGETRequest(to: url, accessToken: accessToken)
    }

    func fetchAllRoutes(
        athleteID: Int,
        accessToken: String,
        progress: (@Sendable (_ downloadedCount: Int, _ expectedTotalCount: Int, _ isEstimatedTotal: Bool) async -> Void)? = nil
    ) async throws -> [StravaRoutePayload] {
        var page = 1
        var allRoutes: [StravaRoutePayload] = []
        var seenIDs = Set<Int>()
        let pageSize = 50

        while true {
            var components = URLComponents(url: apiBaseURL.appendingPathComponent("athletes/\(athleteID)/routes"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(pageSize))
            ]

            let batch: [StravaRoutePayload] = try await sendGETRequest(to: components.url!, accessToken: accessToken)

            guard !batch.isEmpty else {
                if !allRoutes.isEmpty {
                    await progress?(allRoutes.count, allRoutes.count, false)
                }
                break
            }

            let newRoutes = batch.filter { seenIDs.insert($0.id).inserted }
            allRoutes.append(contentsOf: newRoutes)

            let isEstimatedTotal = batch.count == pageSize && !newRoutes.isEmpty
            let expectedTotalCount = isEstimatedTotal ? allRoutes.count + pageSize : allRoutes.count
            await progress?(allRoutes.count, expectedTotalCount, isEstimatedTotal)

            if newRoutes.isEmpty {
                break
            }

            page += 1
            if page > 100 {
                break
            }
        }

        return allRoutes
    }

    func fetchRouteGPX(routeID: Int, accessToken: String) async throws -> Data {
        if let cachedData = await Self.requestCoordinator.cachedRouteGPX(for: routeID) {
            return cachedData
        }

        if let inFlightTask = await Self.requestCoordinator.routeGPXTask(for: routeID) {
            return try await inFlightTask.value
        }

        let url = apiBaseURL.appendingPathComponent("routes/\(routeID)/export_gpx")
        let fetchTask = Task<Data, Error> {
            try await sendDataGETRequest(to: url, accessToken: accessToken)
        }
        await Self.requestCoordinator.setRouteGPXTask(fetchTask, for: routeID)

        do {
            let data = try await fetchTask.value
            await Self.requestCoordinator.storeRouteGPX(data, for: routeID)
            await Self.requestCoordinator.clearRouteGPXTask(for: routeID)
            return data
        } catch {
            await Self.requestCoordinator.clearRouteGPXTask(for: routeID)
            throw error
        }
    }

    func fetchAllActivities(accessToken: String) async throws -> [StravaActivitySummaryPayload] {
        var page = 1
        var allActivities: [StravaActivitySummaryPayload] = []
        var seenIDs = Set<Int>()

        while true {
            var components = URLComponents(url: apiBaseURL.appendingPathComponent("athlete/activities"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: "100")
            ]

            let batch: [StravaActivitySummaryPayload] = try await sendGETRequest(to: components.url!, accessToken: accessToken)
            guard !batch.isEmpty else {
                break
            }

            let newActivities = batch.filter { seenIDs.insert($0.id).inserted }
            allActivities.append(contentsOf: newActivities)

            if newActivities.isEmpty || batch.count < 100 || page >= 100 {
                break
            }

            page += 1
        }

        return allActivities
    }

    func fetchActivity(activityID: Int, accessToken: String) async throws -> StravaDetailedActivityPayload {
        let url = apiBaseURL.appendingPathComponent("activities/\(activityID)")
        return try await sendGETRequest(to: url, accessToken: accessToken)
    }

    func fetchActivityStreams(activityID: Int, accessToken: String) async throws -> StravaActivityStreamsPayload {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("activities/\(activityID)/streams"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "keys", value: "latlng,distance,altitude,heartrate,velocity_smooth,grade_smooth,moving,temp,time"),
            URLQueryItem(name: "key_by_type", value: "true")
        ]
        return try await sendGETRequest(to: components.url!, accessToken: accessToken)
    }

    func uploadActivityGPX(
        fileData: Data,
        fileName: String,
        name: String,
        description: String?,
        sportType: String,
        accessToken: String,
        externalID: String
    ) async throws -> StravaUploadPayload {
        let url = apiBaseURL.appendingPathComponent("uploads")
        var fields = [
            "data_type": "gpx",
            "external_id": externalID,
            "name": name,
            "sport_type": sportType
        ]

        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            fields["description"] = description
        }

        return try await sendMultipartRequest(
            to: url,
            accessToken: accessToken,
            fields: fields,
            fileFieldName: "file",
            fileName: fileName,
            mimeType: "application/gpx+xml",
            fileData: fileData
        )
    }

    func fetchUploadStatus(uploadID: Int, accessToken: String) async throws -> StravaUploadPayload {
        let url = apiBaseURL.appendingPathComponent("uploads/\(uploadID)")
        return try await sendGETRequest(to: url, accessToken: accessToken)
    }

    func validate(credentials: StravaAppCredentials) throws {
        guard !credentials.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.missingCredentials
        }

        guard Int(credentials.clientID) != nil else {
            throw APIError.invalidClientID
        }

        let hasClientSecret = credentials.hasUsableClientSecret
        let hasAuthBroker = credentials.hasUsableAuthBrokerBaseURL
        guard hasClientSecret || hasAuthBroker else {
            throw APIError.missingAuthBroker
        }
    }

    private func sendGETRequest<T: Decodable>(to url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    private func sendDataGETRequest(to url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return try await sendData(request)
    }

    private func sendFormRequest<T: Decodable>(to url: URL, bodyItems: [URLQueryItem], accessToken: String?) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        var components = URLComponents()
        components.queryItems = bodyItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        return try await send(request)
    }

    private func sendMultipartRequest<T: Decodable>(
        to url: URL,
        accessToken: String,
        fields: [String: String],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let lineBreak = "\r\n"

        for key in fields.keys.sorted() {
            guard let value = fields[key] else {
                continue
            }

            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)")
            body.append("\(value)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")
        request.httpBody = body

        return try await send(request)
    }

    private func sendBrokerRequest<T: Decodable, Body: Encodable>(to baseURL: URL, path: String, body: Body) async throws -> T {
        var brokerURL = baseURL
        brokerURL.append(path: path)

        var request = URLRequest(url: brokerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error, request.url)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.badResponse(nil)
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            let fault = try? decoder.decode(StravaFault.self, from: data)

            if isAuthorizationFailure(statusCode: httpResponse.statusCode, fault: fault, requestURL: request.url) {
                throw APIError.unauthorized
            }

            switch httpResponse.statusCode {
            case 401:
                throw APIError.unauthorized
            case 429:
                let retryAfter = rateLimitResetDate(from: httpResponse)
                throw APIError.rateLimited(
                    rateLimitMessage(fallback: fault?.displayMessage, retryAfter: retryAfter),
                    retryAfter: retryAfter
                )
            default:
                throw APIError.server(fault?.displayMessage ?? "Strava returned HTTP \(httpResponse.statusCode).")
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("Strava decode failure for \(request.url?.absoluteString ?? "<unknown-url>"): \(error)")
            #endif
            throw APIError.badResponse("Strava returned data the app could not parse.")
        }
    }

    private func sendData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error, request.url)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.badResponse(nil)
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            let fault = try? decoder.decode(StravaFault.self, from: data)

            if isAuthorizationFailure(statusCode: httpResponse.statusCode, fault: fault, requestURL: request.url) {
                throw APIError.unauthorized
            }

            switch httpResponse.statusCode {
            case 401:
                throw APIError.unauthorized
            case 429:
                let retryAfter = rateLimitResetDate(from: httpResponse)
                throw APIError.rateLimited(
                    rateLimitMessage(fallback: fault?.displayMessage, retryAfter: retryAfter),
                    retryAfter: retryAfter
                )
            default:
                throw APIError.server(fault?.displayMessage ?? "Strava returned HTTP \(httpResponse.statusCode).")
            }
        }

        guard !data.isEmpty else {
            throw APIError.missingRouteData
        }

        return data
    }

    private func isAuthorizationFailure(statusCode: Int, fault: StravaFault?, requestURL: URL?) -> Bool {
        if statusCode == 401 {
            return true
        }

        guard let requestURL else {
            return false
        }

        let normalizedPath = requestURL.path.lowercased()
        let isTokenExchangeRequest = normalizedPath.contains("/oauth/token") ||
            normalizedPath.hasSuffix("/exchange") ||
            normalizedPath.hasSuffix("/refresh")

        guard isTokenExchangeRequest else {
            return false
        }

        if let fault,
           fault.errors?.contains(where: { item in
               let normalizedField = item.field?
                   .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                   .lowercased() ?? ""
               let normalizedCode = item.code?
                   .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                   .lowercased() ?? ""
               return (normalizedCode == "invalid" || normalizedCode == "invalid_grant") &&
                   (normalizedField.contains("refresh") || normalizedField.contains("code") || normalizedField.contains("token"))
           }) == true {
            return true
        }

        return APIError.server(fault?.displayMessage ?? "").requiresSessionReset
    }

    private func rateLimitMessage(fallback: String?, retryAfter: Date?) -> String {
        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }

        guard let retryAfter else {
            return "Strava rate limits were reached. Try again in a few minutes."
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Strava rate limits were reached. Sync will resume after \(formatter.string(from: retryAfter))."
    }

    private func rateLimitResetDate(from response: HTTPURLResponse) -> Date? {
        let responseDate = parsedResponseDate(from: response) ?? Date()

        if let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After"),
           let retryAfterSeconds = TimeInterval(retryAfterHeader),
           retryAfterSeconds > 0 {
            return responseDate.addingTimeInterval(retryAfterSeconds)
        }

        if let usage = parseRateLimitPair(response.value(forHTTPHeaderField: "X-ReadRateLimit-Usage")),
           let limit = parseRateLimitPair(response.value(forHTTPHeaderField: "X-ReadRateLimit-Limit")) {
            if usage.daily >= limit.daily {
                return nextUTCMidnight(after: responseDate)
            }

            if usage.short >= limit.short {
                return nextQuarterHour(after: responseDate)
            }
        }

        return nextQuarterHour(after: responseDate)
    }

    private func parsedResponseDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Date") else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }

    private func parseRateLimitPair(_ value: String?) -> (short: Int, daily: Int)? {
        guard let value else {
            return nil
        }

        let parts = value
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        guard parts.count == 2 else {
            return nil
        }

        return (short: parts[0], daily: parts[1])
    }

    private func nextQuarterHour(after date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = ((minute / 15) + 1) * 15
        components.second = 0

        if components.minute == 60 {
            components.hour = hour + 1
            components.minute = 0
        }

        return calendar.date(from: components) ?? date.addingTimeInterval(900)
    }

    private func nextUTCMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86_400)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter.standard.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        return decoder
    }
}

private extension StravaAppCredentials {
    var hasUsableClientSecret: Bool {
        guard let clientSecret else {
            return false
        }

        let normalized = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        return !normalized.localizedCaseInsensitiveContains("your_strava_client_secret")
    }

    var hasUsableAuthBrokerBaseURL: Bool {
        guard let authBrokerBaseURLString else {
            return false
        }

        let normalized = authBrokerBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        return RouteVaultRuntimeConfiguration.trustedServiceURL(from: normalized) != nil
    }
}

private struct BrokerExchangeRequest: Encodable {
    let clientID: String
    let code: String
    let redirectURI: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case code
        case redirectURI = "redirect_uri"
    }
}

private struct BrokerRefreshRequest: Encodable {
    let clientID: String
    let refreshToken: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case refreshToken = "refresh_token"
    }
}

private extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct StravaFault: Decodable {
    struct FaultItem: Decodable {
        let resource: String?
        let field: String?
        let code: String?
    }

    let message: String?
    let errors: [FaultItem]?

    var displayMessage: String {
        if let message, !message.isEmpty {
            return message
        }

        if let first = errors?.first, let field = first.field, let code = first.code {
            return "\(field): \(code)"
        }

        return "The request could not be completed."
    }
}

struct StravaTokenResponse: Decodable {
    let tokenType: String?
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let athlete: StravaAthletePayload?
}

struct StravaAthletePayload: Decodable {
    let id: Int
    let username: String?
    let firstname: String?
    let lastname: String?
    let profileMedium: String?
    let profile: String?

    var athleteProfile: StravaAthleteProfile {
        StravaAthleteProfile(
            id: id,
            username: username,
            firstName: firstname,
            lastName: lastname,
            profileMedium: profileMedium,
            profile: profile
        )
    }
}

struct StravaRoutePayload: Decodable {
    let id: Int
    let name: String
    let description: String?
    let distance: Double
    let elevationGain: Double?
    let estimatedMovingTime: Double?
    let type: Int?
    let subType: Int?
    let `private`: Bool?
    let starred: Bool?
    let createdAt: Date?
    let updatedAt: Date?
    let map: StravaPolylineMapPayload?
    let segments: [StravaSegmentPayload]?
}

struct StravaPolylineMapPayload: Decodable {
    let id: String?
    let summaryPolyline: String?
}

struct StravaSegmentPayload: Decodable {
    let city: String?
    let state: String?
    let country: String?
}

struct StravaActivitySummaryPayload: Decodable {
    let id: Int
    let name: String
    let description: String?
    let distance: Double
    let movingTime: Double?
    let elapsedTime: Double?
    let totalElevationGain: Double?
    let averageSpeed: Double?
    let `private`: Bool?
    let startDate: Date?
    let updatedAt: Date?
    let locationCity: String?
    let locationState: String?
    let locationCountry: String?
    let startLatlng: [Double]?
    let endLatlng: [Double]?
    let map: StravaPolylineMapPayload?
    let sportType: String?
    let type: String?
    let hasHeartrate: Bool?
    let averageHeartrate: Double?
    let maxHeartrate: Double?
}

typealias StravaDetailedActivityPayload = StravaActivitySummaryPayload

struct StravaNumericStreamPayload: Decodable {
    let data: [Double]

    init(data: [Double]) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([FlexibleDouble].self, forKey: .data).map(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }
}

struct StravaLatLngStreamPayload: Decodable {
    let data: [[Double]]

    init(data: [[Double]]) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([[FlexibleDouble]].self, forKey: .data)
            .map { $0.map(\.value) }
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }
}

struct StravaActivityStreamsPayload: Decodable {
    let latlng: StravaLatLngStreamPayload?
    let distance: StravaNumericStreamPayload?
    let altitude: StravaNumericStreamPayload?
    let heartrate: StravaNumericStreamPayload?
    let velocitySmooth: StravaNumericStreamPayload?
    let gradeSmooth: StravaNumericStreamPayload?
    let moving: StravaNumericStreamPayload?
    let temp: StravaNumericStreamPayload?
    let time: StravaNumericStreamPayload?

    init(
        latlng: StravaLatLngStreamPayload? = nil,
        distance: StravaNumericStreamPayload? = nil,
        altitude: StravaNumericStreamPayload? = nil,
        heartrate: StravaNumericStreamPayload? = nil,
        velocitySmooth: StravaNumericStreamPayload? = nil,
        gradeSmooth: StravaNumericStreamPayload? = nil,
        moving: StravaNumericStreamPayload? = nil,
        temp: StravaNumericStreamPayload? = nil,
        time: StravaNumericStreamPayload? = nil
    ) {
        self.latlng = latlng
        self.distance = distance
        self.altitude = altitude
        self.heartrate = heartrate
        self.velocitySmooth = velocitySmooth
        self.gradeSmooth = gradeSmooth
        self.moving = moving
        self.temp = temp
        self.time = time
    }
}

struct StravaUploadPayload: Decodable {
    let id: Int?
    let idStr: String?
    let externalID: String?
    let error: String?
    let status: String
    let activityID: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case idStr = "id_str"
        case externalID = "external_id"
        case error
        case status
        case activityID = "activity_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        idStr = try container.decodeIfPresent(String.self, forKey: .idStr)
        externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "Processing"
        if let decodedInt = try? container.decode(Int.self, forKey: .activityID) {
            activityID = decodedInt
        } else if let decodedString = try? container.decode(String.self, forKey: .activityID) {
            activityID = Int(decodedString)
        } else {
            activityID = nil
        }
    }

    var numericID: Int? {
        id ?? idStr.flatMap(Int.init)
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
            return
        }

        if let intValue = try? container.decode(Int.self) {
            value = Double(intValue)
            return
        }

        if let boolValue = try? container.decode(Bool.self) {
            value = boolValue ? 1 : 0
            return
        }

        if let stringValue = try? container.decode(String.self),
           let parsedValue = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsedValue
            return
        }

        throw DecodingError.typeMismatch(
            Double.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a numeric, boolean, or numeric-string stream value."
            )
        )
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
