import Foundation

enum RouteVaultRuntimeConfiguration {
    private static func value(for key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmed ?? ""
    }

    static var stravaClientID: String {
        value(for: "RouteVaultStravaClientID")
    }

    static var stravaClientSecret: String? {
        value(for: "RouteVaultStravaClientSecret").nilIfEmpty
    }

    static var stravaAuthBrokerURLString: String? {
        trustedServiceURL(from: value(for: "RouteVaultStravaAuthBrokerURL"))?.absoluteString
    }

    static var redirectScheme: String {
        value(for: "RouteVaultRedirectScheme").nilIfEmpty ?? "routevault"
    }

    static var redirectHost: String {
        value(for: "RouteVaultRedirectHost").nilIfEmpty ?? "localhost"
    }

    static var supabaseProjectURL: URL? {
        trustedServiceURL(from: value(for: "RouteVaultSupabaseURL"))
    }

    static var supabasePublishableKey: String? {
        value(for: "RouteVaultSupabasePublishableKey").nilIfEmpty
    }

    static var functionsBaseURL: URL? {
        explicitFunctionsBaseURL ?? supabaseProjectURL?.appending(path: "functions").appending(path: "v1")
    }

    static var sharedListBaseURL: URL? {
        functionsBaseURL?.appending(path: "shared-list")
    }

    static var shareBaseURL: URL? {
        trustedServiceURL(from: value(for: "RouteVaultShareBaseURL"))
    }

    static var hasBackendConfiguration: Bool {
        functionsBaseURL != nil && supabasePublishableKey != nil
    }

    static var stravaCredentials: StravaAppCredentials {
        StravaAppCredentials(
            clientID: stravaClientID,
            clientSecret: stravaClientSecret,
            redirectScheme: redirectScheme,
            redirectHost: redirectHost,
            authBrokerBaseURLString: stravaAuthBrokerURLString
        )
    }

    private static var explicitFunctionsBaseURL: URL? {
        trustedServiceURL(from: value(for: "RouteVaultFunctionsBaseURL"))
    }

    static func trustedServiceURL(from rawValue: String) -> URL? {
        guard let url = URL(string: rawValue.trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased().nilIfEmpty else {
            return nil
        }

        if scheme == "https" {
            return url
        }

        #if DEBUG
        if scheme == "http",
           host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return url
        }
        #endif

        return nil
    }
}
