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

    // MARK: - 자체 토큰 파일 저장소
    // Keychain은 ad-hoc 재서명 시 코드 해시가 바뀌면 이전 빌드가 저장한 아이템에
    // 접근이 거부(errSecAuthFailed)되어 결국 Claude Code Keychain fallback이 반복된다.
    // 파일 저장은 코드 서명과 무관하게 영구 유지되므로 이 문제가 발생하지 않는다.

    private var tokenFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ClaudeMeter/tokens.json")
    }

    func saveOwnTokens(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        guard let url = tokenFileURL else { throw KeychainError.invalidData }
        var json: [String: Any] = ["accessToken": accessToken]
        if let refreshToken { json["refreshToken"] = refreshToken }
        if let expiresAt {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            json["expiresAt"] = f.string(from: expiresAt)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            throw KeychainError.invalidData
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    func loadOwnTokens() throws -> OAuthTokenData {
        guard let url = tokenFileURL else { throw KeychainError.invalidData }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KeychainError.notFound
        }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String
        else { throw KeychainError.invalidData }
        return OAuthTokenData(
            accessToken: accessToken,
            refreshToken: json["refreshToken"] as? String,
            expiresAt: parseDate(json["expiresAt"] as? String)
        )
    }

    func deleteOwnTokens() {
        guard let url = tokenFileURL else { return }
        try? FileManager.default.removeItem(at: url)
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
