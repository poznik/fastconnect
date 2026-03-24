import Foundation
import Security

enum KeychainServiceError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error: \(status)"
        case .invalidData:
            "В Keychain лежат повреждённые данные."
        }
    }
}

final class KeychainService {
    private let serviceName: String

    init(serviceName: String = "com.fastconnect.credentials") {
        self.serviceName = serviceName
    }

    func loadString(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(status)
        }

        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.invalidData
        }

        return value
    }

    func saveString(_ value: String, for account: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            try deleteString(for: account)
            return
        }

        let encoded = Data(trimmedValue.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: encoded
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainServiceError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = encoded

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(addStatus)
        }
    }

    func deleteString(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }
}
