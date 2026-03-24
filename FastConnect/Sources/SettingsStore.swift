import Foundation

enum SettingsStoreError: LocalizedError {
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case let .saveFailed(message):
            message
        }
    }
}

final class SettingsStore {
    private enum DefaultsKey {
        static let legacyProfileName = "profileName"
        static let vpnHost = "vpnHost"
        static let profileSelection = "profileSelection"
        static let launchAtLogin = "launchAtLogin"
    }

    private enum KeychainAccount {
        static let username = "username"
        static let password = "password"
        static let totpSecret = "totpSecret"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainService

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func loadConfiguration() -> ConnectionConfiguration {
        var configuration = ConnectionConfiguration()
        configuration.vpnHost = defaults.string(forKey: DefaultsKey.vpnHost) ?? defaults.string(forKey: DefaultsKey.legacyProfileName) ?? ""
        configuration.profileSelection = defaults.string(forKey: DefaultsKey.profileSelection) ?? ""
        configuration.launchAtLogin = defaults.bool(forKey: DefaultsKey.launchAtLogin)
        configuration.username = (try? keychain.loadString(for: KeychainAccount.username)) ?? ""
        configuration.password = (try? keychain.loadString(for: KeychainAccount.password)) ?? ""
        configuration.totpSecret = (try? keychain.loadString(for: KeychainAccount.totpSecret)) ?? ""
        return configuration
    }

    func save(configuration: ConnectionConfiguration) throws {
        defaults.set(configuration.vpnHost, forKey: DefaultsKey.vpnHost)
        defaults.set(configuration.profileSelection, forKey: DefaultsKey.profileSelection)
        defaults.set(configuration.launchAtLogin, forKey: DefaultsKey.launchAtLogin)
        defaults.removeObject(forKey: DefaultsKey.legacyProfileName)

        do {
            try keychain.saveString(configuration.username, for: KeychainAccount.username)
            try keychain.saveString(configuration.password, for: KeychainAccount.password)
            try keychain.saveString(configuration.totpSecret, for: KeychainAccount.totpSecret)
        } catch {
            throw SettingsStoreError.saveFailed(error.localizedDescription)
        }
    }
}
