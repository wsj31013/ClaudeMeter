import Foundation
import Security

enum KeychainError: Error, Equatable {
    case notFound
    case invalidData
    case unexpectedStatus(OSStatus)
}

struct OAuthTokenData: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

@MainActor
final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    private static let service = "Claude Code-credentials"

    // MARK: - 자체 소유 토큰 저장소 (com.claudemeter.tokens)
    // Claude Code Keychain 크로스앱 접근을 최초 1회로 줄이기 위해 사용

    private static let ownService = "com.claudemeter.tokens"
    private static let ownAccount = "oauth"

    func saveOwnTokens(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        var json: [String: Any] = ["accessToken": accessToken]
        if let refreshToken { json["refreshToken"] = refreshToken }
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            json["expiresAt"] = formatter.string(from: expiresAt)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            throw KeychainError.invalidData
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.ownService,
            kSecAttrAccount: Self.ownAccount
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func loadOwnTokens() throws -> OAuthTokenData {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.ownService,
            kSecAttrAccount: Self.ownAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.notFound }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String
        else {
            throw KeychainError.invalidData
        }

        return OAuthTokenData(
            accessToken: accessToken,
            refreshToken: json["refreshToken"] as? String,
            expiresAt: parseDate(json["expiresAt"] as? String)
        )
    }

    func deleteOwnTokens() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.ownService,
            kSecAttrAccount: Self.ownAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    func claudeOAuthToken() throws -> String {
        try oAuthTokenData().accessToken
    }

    func oAuthTokenData() throws -> OAuthTokenData {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.notFound }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthData = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauthData["accessToken"] as? String
        else {
            throw KeychainError.invalidData
        }

        let refreshToken = oauthData["refreshToken"] as? String
        let expiresAt = parseDate(oauthData["expiresAt"] as? String)

        return OAuthTokenData(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    func updateOAuthTokens(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        let readQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)

        guard readStatus == errSecSuccess,
              let existingData = result as? Data,
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              var oauthData = json["claudeAiOauth"] as? [String: Any]
        else {
            throw KeychainError.invalidData
        }

        oauthData["accessToken"] = accessToken
        if let refreshToken {
            oauthData["refreshToken"] = refreshToken
        }
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            oauthData["expiresAt"] = formatter.string(from: expiresAt)
        }
        json["claudeAiOauth"] = oauthData

        guard let newData = try? JSONSerialization.data(withJSONObject: json) else {
            throw KeychainError.invalidData
        }

        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service
        ]
        let update: [CFString: Any] = [kSecValueData: newData]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, update as CFDictionary)

        guard updateStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
