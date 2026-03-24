import CryptoKit
import Foundation

enum TOTPGeneratorError: LocalizedError {
    case invalidSecret

    var errorDescription: String? {
        switch self {
        case .invalidSecret:
            "Не удалось разобрать TOTP secret. Ожидается Base32-строка."
        }
    }
}

enum TOTPGenerator {
    static func generate(secret: String, now: Date = Date(), digits: Int = 6, period: TimeInterval = 30) throws -> String {
        guard let secretData = Base32.decode(secret) else {
            throw TOTPGeneratorError.invalidSecret
        }

        var counter = UInt64(now.timeIntervalSince1970 / period).bigEndian
        let counterData = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secretData)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hash = Array(digest)
        let offset = Int(hash[hash.count - 1] & 0x0f)

        let truncated = (
            UInt32(hash[offset] & 0x7f) << 24 |
            UInt32(hash[offset + 1]) << 16 |
            UInt32(hash[offset + 2]) << 8 |
            UInt32(hash[offset + 3])
        )

        let modulus = UInt32(pow(10.0, Double(digits)))
        let code = truncated % modulus
        return String(format: "%0*u", digits, code)
    }
}

private enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let lookup: [Character: UInt8] = {
        var result: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            result[character] = UInt8(index)
        }
        return result
    }()

    static func decode(_ string: String) -> Data? {
        let normalized = string
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "=" && $0 != "-" }

        guard !normalized.isEmpty else {
            return nil
        }

        var buffer: UInt32 = 0
        var bitsLeft: Int = 0
        var bytes: [UInt8] = []

        for character in normalized {
            guard let value = lookup[character] else {
                return nil
            }

            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5

            if bitsLeft >= 8 {
                let shifted = UInt8((buffer >> UInt32(bitsLeft - 8)) & 0xff)
                bytes.append(shifted)
                bitsLeft -= 8
            }
        }

        return Data(bytes)
    }
}
