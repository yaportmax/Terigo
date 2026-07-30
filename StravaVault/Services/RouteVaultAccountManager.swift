import AuthenticationServices
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RouteVaultAccountManager {
    enum BackendState: Equatable {
        case unavailable
        case bootstrapping
        case synced
        case degraded(String)
    }

    @ObservationIgnored private let credentialStore = StravaCredentialStore()
    @ObservationIgnored private let authCoordinator = StravaAuthSessionCoordinator()
    @ObservationIgnored private let apiService = StravaAPIService()
    @ObservationIgnored private let backendService = RouteVaultBackendService()
    @ObservationIgnored private let accountSessionStore = RouteVaultAccountSessionStore()
    @ObservationIgnored private var sessionInvalidationObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionUpdateObserver: NSObjectProtocol?
    @ObservationIgnored private var backendBootstrapSequence = 0

    private(set) var stravaSession: StravaSession?
    private(set) var accountSession: RouteVaultAccountSession?
    private(set) var backendState: BackendState = RouteVaultRuntimeConfiguration.hasBackendConfiguration
        ? .degraded("After you connect Strava, Terigo will set up your synced account.")
        : .unavailable
    private(set) var isRestoringSession = false
    private(set) var isConnecting = false
    private(set) var isDeletingAccount = false
    private(set) var didRestoreInitialState = false
    private(set) var pendingSharedListLink: RouteVaultSharedListLink?
    var errorMessage: String?
    var statusMessage: String?

    init() {
        sessionInvalidationObserver = NotificationCenter.default.addObserver(
            forName: StravaSessionNotifications.didInvalidate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                // Ignore stale invalidation notifications that arrive after a fresh
                // session has already been persisted during a reconnect.
                if let persistedSession = try? self.credentialStore.loadSession() {
                    self.stravaSession = persistedSession
                    await self.handlePersistedSessionUpdate()
                    return
                }

                self.stravaSession = nil
                self.accountSession = nil
                self.backendState = RouteVaultRuntimeConfiguration.hasBackendConfiguration ? .degraded("Reconnect Strava to restore your synced account.") : .unavailable
            }
        }
        sessionUpdateObserver = NotificationCenter.default.addObserver(
            forName: StravaSessionNotifications.didUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handlePersistedSessionUpdate()
            }
        }
    }

    deinit {
        if let sessionInvalidationObserver {
            NotificationCenter.default.removeObserver(sessionInvalidationObserver)
        }
        if let sessionUpdateObserver {
            NotificationCenter.default.removeObserver(sessionUpdateObserver)
        }
    }

    var isAuthenticated: Bool {
        stravaSession != nil
    }

    var isReviewerDemoActive: Bool {
        AppUITestSupport.isReviewDemoEnabled
    }

    var canUseBackendFeatures: Bool {
        accountSession != nil
    }

    var accountCode: String? {
        accountSession?.profile.accountCode
    }

    var backendStatusText: String {
        if isReviewerDemoActive {
            return "Reviewer demo mode is active. Terigo is showing seeded local routes, lists, and activities."
        }

        switch backendState {
        case .unavailable:
            return "Backend sync is not configured on this build yet."
        case .bootstrapping:
            return "Setting up your Terigo account…"
        case .synced:
            return "Routes and lists can sync across devices."
        case let .degraded(message):
            return message
        }
    }

    var compactBackendStatusText: String {
        if isReviewerDemoActive {
            return "Demo mode"
        }

        switch backendState {
        case .unavailable:
            return "Backend unavailable"
        case .bootstrapping:
            return "Setting up account"
        case .synced:
            return "Synced"
        case .degraded:
            return isAuthenticated ? "Reconnect Strava" : "Connect Strava"
        }
    }

    func restorePersistedStateIfNeeded() async {
        guard !didRestoreInitialState else {
            return
        }

        isRestoringSession = true
        defer {
            isRestoringSession = false
            didRestoreInitialState = true
        }

        do {
            if AppUITestSupport.isReviewDemoEnabled {
                installReviewerDemoState(statusMessage: "Reviewer demo mode is ready.")
                return
            }

            stravaSession = try credentialStore.loadSession()
            accountSession = try accountSessionStore.load()
            if stravaSession != nil {
                await bootstrapBackendAccountIfPossible(force: true)
            } else if !RouteVaultRuntimeConfiguration.hasBackendConfiguration {
                backendState = .unavailable
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func connectWithStrava() async {
        guard !isConnecting else {
            return
        }

        isConnecting = true
        errorMessage = nil
        statusMessage = nil
        defer { isConnecting = false }

        let credentials = RouteVaultRuntimeConfiguration.stravaCredentials
        do {
            try apiService.validate(credentials: credentials)
            try credentialStore.save(credentials: credentials)

            let state = UUID().uuidString
            let authURL = apiService.authorizationURL(credentials: credentials, state: state)
            let callbackURL = try await authCoordinator.authenticate(
                using: authURL,
                callbackScheme: credentials.redirectScheme
            )
            let callback = try apiService.parseCallback(callbackURL, expectedState: state)
            let authenticatedSession = try await apiService.exchangeCode(
                callback.authorizationCode,
                credentials: credentials,
                acceptedScopes: callback.acceptedScopes
            )

            try credentialStore.save(session: authenticatedSession)
            stravaSession = authenticatedSession
            accountSession = nil
            backendState = .bootstrapping
            statusMessage = "Connected as \(authenticatedSession.athlete.displayName)."

            await bootstrapBackendAccountIfPossible(force: true)
        } catch {
            errorMessage = connectErrorMessage(for: error)
        }
    }

    func activateReviewDemo(using context: ModelContext, accessCode: String) {
        errorMessage = nil

        guard AppUITestSupport.matchesReviewDemoCode(accessCode) else {
            errorMessage = "That access code is not valid."
            return
        }

        do {
            try AppUITestSupport.activateReviewDemo(using: context)
            installReviewerDemoState(statusMessage: "Reviewer demo mode unlocked.")
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func deactivateReviewDemo(using context: ModelContext) {
        do {
            try AppUITestSupport.deactivateReviewDemo(using: context)
            stravaSession = nil
            accountSession = nil
            backendState = RouteVaultRuntimeConfiguration.hasBackendConfiguration
                ? .degraded("Connect Strava to access Terigo.")
                : .unavailable
            statusMessage = "Reviewer demo mode exited."
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func disconnect() {
        do {
            try credentialStore.clearSession()
        } catch {
            errorMessage = displayMessage(for: error)
        }

        do {
            try accountSessionStore.clear()
        } catch {
            errorMessage = displayMessage(for: error)
        }

        stravaSession = nil
        accountSession = nil
        backendState = RouteVaultRuntimeConfiguration.hasBackendConfiguration ? .degraded("Reconnect Strava to restore your synced account.") : .unavailable
    }

    @discardableResult
    func deleteAccount() async -> Bool {
        guard !isReviewerDemoActive else {
            errorMessage = "Reviewer demo mode does not create a hosted Terigo account."
            return false
        }

        guard let accountSession else {
            errorMessage = "Terigo account sync is not available. Reconnect Strava and try again."
            return false
        }

        isDeletingAccount = true
        errorMessage = nil
        statusMessage = nil
        defer { isDeletingAccount = false }

        do {
            try await backendService.deleteAccount(accountSessionToken: accountSession.token)
            backendBootstrapSequence += 1
            try credentialStore.clearSession()
            try accountSessionStore.clear()

            stravaSession = nil
            self.accountSession = nil
            backendState = RouteVaultRuntimeConfiguration.hasBackendConfiguration
                ? .degraded("Connect Strava to create a new Terigo account.")
                : .unavailable
            statusMessage = "Your Terigo account and hosted sharing data were deleted."
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }
    }

    func captureIncomingURL(_ url: URL) {
        if authCoordinator.handleIncomingCallbackURL(url) {
            return
        }

        guard let sharedListLink = RouteVaultSharedListLink.decode(from: url) else {
            return
        }

        pendingSharedListLink = sharedListLink
        if !isAuthenticated {
            statusMessage = "Connect Strava to open this shared Terigo list."
        }
    }

    func consumePendingSharedListLink() -> RouteVaultSharedListLink? {
        defer { pendingSharedListLink = nil }
        return pendingSharedListLink
    }

    func clearTransientMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    func refreshBackendSessionAfterUnauthorized() async -> Bool {
        if AppUITestSupport.isReviewDemoEnabled {
            installReviewerDemoState(statusMessage: nil)
            return true
        }

        guard RouteVaultRuntimeConfiguration.hasBackendConfiguration else {
            backendState = .unavailable
            return false
        }

        do {
            try accountSessionStore.clear()
        } catch {
            errorMessage = displayMessage(for: error)
        }

        accountSession = nil

        guard stravaSession != nil else {
            backendState = .degraded("Reconnect Strava to restore your synced account.")
            return false
        }

        await bootstrapBackendAccountIfPossible(force: true)
        return accountSession != nil
    }

    func bootstrapBackendAccountIfPossible(force: Bool) async {
        if AppUITestSupport.isReviewDemoEnabled {
            installReviewerDemoState(statusMessage: nil)
            return
        }

        guard RouteVaultRuntimeConfiguration.hasBackendConfiguration else {
            backendState = .unavailable
            return
        }

        guard let stravaSession else {
            return
        }

        if !force, accountSession != nil {
            backendState = .synced
            return
        }

        let bootstrapRequest = beginBootstrapRequest(for: stravaSession)
        backendState = .bootstrapping

        do {
            let session = try await backendService.bootstrapAccount(
                with: stravaSession
            )
            guard isCurrentBootstrapRequest(bootstrapRequest) else {
                return
            }
            try accountSessionStore.save(session)
            accountSession = session
            backendState = .synced
            errorMessage = nil
            statusMessage = "Terigo account is ready for synced lists and sharing."
        } catch {
            guard isCurrentBootstrapRequest(bootstrapRequest) else {
                return
            }
            let message = displayMessage(for: error)
            accountSession = nil
            backendState = .degraded(message)
            errorMessage = message
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private func connectErrorMessage(for error: Error) -> String {
        if let authError = error as? ASWebAuthenticationSessionError,
           authError.code == .canceledLogin {
            return stravaConnectionCapacityMessage
        }

        if let authError = error as? StravaAuthSessionCoordinator.AuthError {
            switch authError {
            case .missingCallbackURL:
                return stravaConnectionCapacityMessage
            case .unableToStart:
                break
            }
        }

        return displayMessage(for: error)
    }

    private var stravaConnectionCapacityMessage: String {
        "Strava sign-in did not complete. If Strava showed “Error 403: Limit of connected athletes exceeded,” Terigo has reached Strava’s current new-user connection cap. New Strava sign-ins are blocked until the Strava app quota is increased."
    }

    private func handlePersistedSessionUpdate() async {
        if AppUITestSupport.isReviewDemoEnabled {
            installReviewerDemoState(statusMessage: nil)
            return
        }

        guard let refreshedSession = try? credentialStore.loadSession() else {
            return
        }

        let didSwitchAthlete = accountSession?.profile.stravaAthleteID != refreshedSession.athlete.id
        stravaSession = refreshedSession

        await bootstrapBackendAccountIfPossible(
            force: didSwitchAthlete ||
                accountSession == nil ||
                accountSession?.requiresRefresh == true ||
                {
                    if case .synced = backendState {
                        return false
                    }
                    return true
                }()
        )
    }

    private func beginBootstrapRequest(for session: StravaSession) -> BootstrapRequest {
        backendBootstrapSequence += 1
        return BootstrapRequest(
            sequence: backendBootstrapSequence,
            athleteID: session.athlete.id,
            accessToken: session.accessToken
        )
    }

    private func isCurrentBootstrapRequest(_ request: BootstrapRequest) -> Bool {
        request.sequence == backendBootstrapSequence &&
            stravaSession?.athlete.id == request.athleteID &&
            stravaSession?.accessToken == request.accessToken
    }

    private func installReviewerDemoState(statusMessage: String?) {
        stravaSession = AppUITestSupport.makeStubSession()
        accountSession = AppUITestSupport.makeStubAccountSession()
        backendState = .synced
        errorMessage = nil
        pendingSharedListLink = nil
        if let statusMessage {
            self.statusMessage = statusMessage
        }
    }
}

private struct BootstrapRequest {
    let sequence: Int
    let athleteID: Int
    let accessToken: String
}
