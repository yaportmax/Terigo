import Foundation
import Security

enum StravaSessionNotifications {
    static let didInvalidate = Notification.Name("StravaSessionDidInvalidate")
    static let didUpdate = Notification.Name("StravaSessionDidUpdate")
}

struct StravaCredentialStore {
    private let keychain = KeychainStore(service: "com.myaport.RouteVault")
    private let legacyKeychain = KeychainStore(service: "com.myaport.StravaVault")
    private let credentialsAccount = "strava.credentials"
    private let sessionAccount = "strava.session"
    private let defaults = UserDefaults.standard

    func save(credentials: StravaAppCredentials) throws {
        do {
            try keychain.saveCodable(credentials, account: credentialsAccount)
            clearDefaultsValue(account: credentialsAccount)
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            try saveToDefaults(credentials, account: credentialsAccount)
        }
    }

    func loadCredentials() throws -> StravaAppCredentials? {
        do {
            if let credentials = try keychain.readCodable(StravaAppCredentials.self, account: credentialsAccount) {
                return credentials
            }
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            return try loadFromDefaults(StravaAppCredentials.self, account: credentialsAccount)
        }

        do {
            if let credentials = try legacyKeychain.readCodable(StravaAppCredentials.self, account: credentialsAccount) {
                return credentials
            }
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            return try loadFromDefaults(StravaAppCredentials.self, account: credentialsAccount)
        }

        return try loadFromDefaults(StravaAppCredentials.self, account: credentialsAccount)
    }

    func save(session: StravaSession) throws {
        do {
            try keychain.saveCodable(session, account: sessionAccount)
            clearDefaultsValue(account: sessionAccount)
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            try saveToDefaults(session, account: sessionAccount)
        }

        NotificationCenter.default.post(name: StravaSessionNotifications.didUpdate, object: nil)
    }

    func loadSession() throws -> StravaSession? {
        do {
            if let session = try keychain.readCodable(StravaSession.self, account: sessionAccount) {
                return session
            }
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            return try loadFromDefaults(StravaSession.self, account: sessionAccount)
        }

        do {
            if let session = try legacyKeychain.readCodable(StravaSession.self, account: sessionAccount) {
                return session
            }
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            return try loadFromDefaults(StravaSession.self, account: sessionAccount)
        }

        return try loadFromDefaults(StravaSession.self, account: sessionAccount)
    }

    func clearSession() throws {
        do {
            try keychain.delete(account: sessionAccount)
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            clearDefaultsValue(account: sessionAccount)
        }

        do {
            try legacyKeychain.delete(account: sessionAccount)
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            clearDefaultsValue(account: sessionAccount)
        }

        clearDefaultsValue(account: sessionAccount)
        NotificationCenter.default.post(name: StravaSessionNotifications.didInvalidate, object: nil)
    }

    private func saveToDefaults<T: Codable>(_ value: T, account: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(value), forKey: defaultsKey(for: account))
    }

    private func loadFromDefaults<T: Codable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = defaults.data(forKey: defaultsKey(for: account)) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func clearDefaultsValue(account: String) {
        defaults.removeObject(forKey: defaultsKey(for: account))
    }

    private func defaultsKey(for account: String) -> String {
        "com.myaport.RouteVault.defaults-fallback.\(account)"
    }

    private func shouldUseDefaultsFallback(for error: KeychainStore.KeychainError) -> Bool {
        #if targetEnvironment(simulator)
        if case let .unexpectedStatus(status) = error {
            return status == errSecMissingEntitlement || status == errSecNotAvailable
        }
        #endif

        return false
    }
}
