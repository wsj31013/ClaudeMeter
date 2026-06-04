import Foundation

enum UsageError: LocalizedError {
    case noToken
    case unauthorized
    case rateLimited
    case networkError(Error)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noToken: return "Claude Code 로그인이 필요합니다"
        case .unauthorized: return "인증 토큰이 만료되었습니다"
        case .rateLimited: return "요청 한도 초과 — 잠시 후 재시도"
        case .networkError(let e): return "네트워크 오류: \(e.localizedDescription)"
        case .parseError: return "응답 파싱 실패"
        }
    }
}

@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published var usageData: UsageData?
    @Published var error: UsageError?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    private var refreshTimer: Timer?
    private var retryTimer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5분
    private let retryInterval: TimeInterval = 60   // 에러 후 1분 재시도

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenEndpoint = URL(string: "https://api.anthropic.com/api/oauth/token")!
    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFrac, plain]
    }()

    private init() {}

    func startAutoRefresh() {
        Task { await fetchUsage() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetchUsage() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func fetchUsage() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let token = try await resolveValidToken()
            try await performFetch(token: token)
            retryTimer?.invalidate()
            retryTimer = nil
        } catch UsageError.unauthorized {
            // access_token 만료 — refresh_token으로 재시도
            do {
                let newToken = try await refreshOAuthToken()
                try await performFetch(token: newToken)
                retryTimer?.invalidate()
                retryTimer = nil
            } catch UsageError.unauthorized {
                // refresh_token도 만료됨 — 저장된 파일 삭제 후 재시도
                // 다음 fetchUsage()에서 Claude Code Keychain 재부트스트랩 (팝업 1회)
                KeychainService.shared.deleteOwnTokens()
                error = .unauthorized
                scheduleRetry()
            } catch let e as UsageError {
                error = e
                scheduleRetry()
            } catch {
                self.error = .networkError(error)
                scheduleRetry()
            }
        } catch let e as KeychainError {
            error = e == .notFound ? .noToken : .unauthorized
            if e != .notFound { scheduleRetry() }
        } catch let e as UsageError {
            error = e
            scheduleRetry()
        } catch {
            self.error = .networkError(error)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
            Task { await self?.fetchUsage() }
        }
    }

    // 자체 Keychain 우선 읽기 → 없으면 Claude Code Keychain fallback (최초 1회 팝업)
    private func resolveValidToken() async throws -> String {
        let tokenData = try loadTokenData()

        let isExpiredOrExpiring = tokenData.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false

        if isExpiredOrExpiring, tokenData.refreshToken != nil {
            return try await refreshOAuthToken()
        }

        return tokenData.accessToken
    }

    private func loadTokenData() throws -> OAuthTokenData {
        // 자체 Keychain에서 먼저 읽기 (팝업 없음)
        if let own = try? KeychainService.shared.loadOwnTokens() {
            return own
        }
        // 없으면 Claude Code Keychain에서 부트스트랩 (최초 1회 팝업 발생 가능)
        let bootstrapped = try KeychainService.shared.oAuthTokenData()
        try? KeychainService.shared.saveOwnTokens(
            accessToken: bootstrapped.accessToken,
            refreshToken: bootstrapped.refreshToken,
            expiresAt: bootstrapped.expiresAt
        )
        return bootstrapped
    }

    private func performFetch(token: String) async throws {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.77", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw UsageError.parseError }
        switch http.statusCode {
        case 200: break
        case 401: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.parseError
        }

        let raw = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        usageData = parseResponse(raw)
        lastUpdated = Date()
        error = nil
        NotificationCenter.default.post(name: .usageDataDidUpdate, object: nil)
    }

    private func refreshOAuthToken() async throws -> String {
        // 자체 Keychain 우선, 없으면 Claude Code Keychain fallback
        let tokenData: OAuthTokenData
        if let own = try? KeychainService.shared.loadOwnTokens() {
            tokenData = own
        } else {
            tokenData = try KeychainService.shared.oAuthTokenData()
        }
        guard let refreshToken = tokenData.refreshToken else {
            throw UsageError.unauthorized
        }

        var request = URLRequest(url: Self.tokenEndpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let body = ["grant_type": "refresh_token", "refresh_token": refreshToken]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UsageError.unauthorized
        }

        struct RefreshResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }

        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        try KeychainService.shared.saveOwnTokens(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            expiresAt: expiresAt
        )

        return refreshed.accessToken
    }

    private func parseResponse(_ raw: UsageAPIResponse) -> UsageData {
        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return Self.isoFormatters.lazy.compactMap { $0.date(from: s) }.first
        }

        return UsageData(
            fiveHour: UsageWindow(percent: raw.fiveHour.utilization, resetAt: parseDate(raw.fiveHour.resetsAt)),
            sevenDay: UsageWindow(percent: raw.sevenDay.utilization, resetAt: parseDate(raw.sevenDay.resetsAt)),
            fetchedAt: Date()
        )
    }
}
