import AuthenticationServices
import UIKit

@MainActor
final class StravaAuthSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum AuthError: LocalizedError {
        case unableToStart
        case missingCallbackURL

        var errorDescription: String? {
            switch self {
            case .unableToStart:
                return "Strava authentication could not be started."
            case .missingCallbackURL:
                return "Strava did not return a callback URL."
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackScheme: String?

    func authenticate(using authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            pendingCallbackScheme = callbackScheme

            let authSession = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                guard let self else {
                    return
                }

                self.session = nil

                if let callbackURL {
                    self.finish(with: .success(callbackURL))
                    return
                }

                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin,
                   self.continuation == nil {
                    return
                }

                if let error {
                    self.finish(with: .failure(error))
                    return
                }

                self.finish(with: .failure(AuthError.missingCallbackURL))
            }

            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false
            session = authSession

            guard authSession.start() else {
                finish(with: .failure(AuthError.unableToStart))
                return
            }
        }
    }

    func handleIncomingCallbackURL(_ url: URL) -> Bool {
        guard let pendingCallbackScheme,
              let urlScheme = url.scheme?.lowercased(),
              urlScheme == pendingCallbackScheme.lowercased(),
              url.path.lowercased().contains("oauth-callback") else {
            return false
        }

        session?.cancel()
        session = nil
        finish(with: .success(url))
        return true
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        pendingCallbackScheme = nil

        switch result {
        case let .success(callbackURL):
            continuation.resume(returning: callbackURL)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
