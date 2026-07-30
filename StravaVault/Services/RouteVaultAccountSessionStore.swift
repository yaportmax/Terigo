import Foundation
import Security

struct RouteVaultAccountSessionStore {
    private let keychain = KeychainStore(service: "com.myaport.RouteVault")
    private let defaults = UserDefaults.standard
    private let accountSessionAccount = "routevault.account-session"

    func save(_ session: RouteVaultAccountSession) throws {
        do {
            try keychain.saveCodable(session, account: accountSessionAccount)
            clearDefaults()
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            try saveToDefaults(session)
        }
    }

    func load() throws -> RouteVaultAccountSession? {
        do {
            if let session = try keychain.readCodable(RouteVaultAccountSession.self, account: accountSessionAccount) {
                return session
            }
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            return try loadFromDefaults()
        }

        return try loadFromDefaults()
    }

    func clear() throws {
        do {
            try keychain.delete(account: accountSessionAccount)
        } catch let error as KeychainStore.KeychainError where shouldUseDefaultsFallback(for: error) {
            clearDefaults()
            return
        }

        clearDefaults()
    }

    private func saveToDefaults(_ session: RouteVaultAccountSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(session), forKey: defaultsKey)
    }

    private func loadFromDefaults() throws -> RouteVaultAccountSession? {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RouteVaultAccountSession.self, from: data)
    }

    private func clearDefaults() {
        defaults.removeObject(forKey: defaultsKey)
    }

    private var defaultsKey: String {
        "com.myaport.RouteVault.defaults-fallback.\(accountSessionAccount)"
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
