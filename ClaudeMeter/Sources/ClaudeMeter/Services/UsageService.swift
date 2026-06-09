import Foundation

enum UsageError: LocalizedError {
    case noToken
    case unauthorized
    case refreshTokenExpired
    case keychainAccessRequired
    case rateLimited
    case networkError(Error)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noToken: return "Claude Code 로그인이 필요합니다"
        case .unauthorized: return "인증 토큰이 만료되었습니다"
        case .refreshTokenExpired: return "인증 토큰이 만료되었습니다"
        case .keychainAccessRequired: return "키체인 접근 허용이 필요합니다 — 팝업을 확인해주세요"
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
    private var retryCount = 0
    private let refreshInterval: TimeInterval = 300    // 5분 정상 폴링
    private let baseRetryInterval: TimeInterval = 60   // 에러 후 첫 재시도
    private let maxRetryInterval: TimeInterval = 600   // 지수 백오프 상한 (10분)

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
        // retryTimer가 살아 있는 동안 refreshTimer는 중복 호출하지 않음
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.retryTimer == nil else { return }
                await self.fetchUsage()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func fetchUsage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let token = try await resolveValidToken()
            try await performFetch(token: token)
            clearRetry()
        } catch UsageError.refreshTokenExpired {
            // resolveValidToken()에서 refresh 시도했으나 refresh_token 확정 만료
            KeychainService.shared.deleteOwnTokens()
            error = .unauthorized
            scheduleRetry()
        } catch UsageError.unauthorized {
            // performFetch()에서 401 — access_token 만료, refresh 시도
            do {
                let newToken = try await refreshOAuthToken()
                try await performFetch(token: newToken)
                clearRetry()
            } catch UsageError.refreshTokenExpired {
                // refresh_token도 만료됨 (400/401) — 파일 삭제 후 다음 실행에서 재부트스트랩
                KeychainService.shared.deleteOwnTokens()
                error = .unauthorized
                scheduleRetry()
            } catch UsageError.rateLimited {
                // 갱신 엔드포인트 rate limit — 토큰 파일 유지, 재시도 없음
                error = .rateLimited
            } catch let e as UsageError {
                // 서버 오류 등 일시적 실패 — 파일은 유지하고 재시도
                error = e
                scheduleRetry()
            } catch {
                self.error = .networkError(error)
                scheduleRetry()
            }
        } catch UsageError.rateLimited {
            error = .rateLimited
        } catch let e as KeychainError {
            switch e {
            case .notFound:
                error = .noToken
            default:
                error = .keychainAccessRequired
                scheduleRetry()
            }
        } catch let e as UsageError {
            error = e
            scheduleRetry()
        } catch {
            self.error = .networkError(error)
            scheduleRetry()
        }
    }

    private func clearRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
    }

    // 지수 백오프: 60s → 120s → 240s → 최대 600s(10분)
    private func scheduleRetry() {
        retryTimer?.invalidate()
        let delay = min(baseRetryInterval * pow(2.0, Double(retryCount)), maxRetryInterval)
        retryCount += 1
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { await self?.fetchUsage() }
        }
    }

    // 자체 파일 우선 읽기 → 없으면 Claude Code Keychain fallback (최초 1회 팝업)
    private func resolveValidToken() async throws -> String {
        let tokenData = try loadTokenData()

        let isExpiredOrExpiring = tokenData.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false

        if isExpiredOrExpiring, tokenData.refreshToken != nil {
            return try await refreshOAuthToken()
        }

        return tokenData.accessToken
    }

    private func loadTokenData() throws -> OAuthTokenData {
        if let own = try? KeychainService.shared.loadOwnTokens(), own.refreshToken != nil {
            return own
        }
        // No file, or file has no refreshToken → re-bootstrap from Claude Code Keychain
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

        guard let http = response as? HTTPURLResponse else { throw UsageError.parseError }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            NSLog("[ClaudeMeter] refresh failed: HTTP %d — %@", http.statusCode, body)
        }
        switch http.statusCode {
        case 200: break
        case 429: throw UsageError.rateLimited      // rate limit — 토큰 파일 유지
        case 400, 401: throw UsageError.refreshTokenExpired  // refresh_token 만료 확정 → 파일 삭제
        default: throw UsageError.networkError(URLError(.badServerResponse))  // 서버 오류 — 파일 유지
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

        // OAuth2 서버가 refresh_token을 응답에 포함하지 않으면 기존 토큰을 그대로 보존
        let savedRefreshToken = refreshed.refreshToken ?? tokenData.refreshToken

        try KeychainService.shared.saveOwnTokens(
            accessToken: refreshed.accessToken,
            refreshToken: savedRefreshToken,
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
