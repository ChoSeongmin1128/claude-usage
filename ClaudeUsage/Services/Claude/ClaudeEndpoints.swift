import Foundation

/// Claude 사용량 조회 주소와 공통 헤더. 메뉴바 계정과 다른 계정 조회가 같은 요청을 보내도록 한곳에 둔다.
nonisolated enum ClaudeEndpoints {
    static let webOrigin = "https://claude.ai"
    static let webAPIBase = "\(webOrigin)/api"
    static let oauthAPIBase = "https://api.anthropic.com/api/oauth"
    static let requestTimeout: TimeInterval = 20

    /// Cloudflare가 기본 CFNetwork UA를 봇으로 분류하는 경우가 있어 Safari UA를 쓴다.
    static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let oauthUserAgent = "claude-code/2.1.5"
    static let oauthBeta = "oauth-2025-04-20"

    /// 이 쿼리가 없으면 사용량 응답의 초기화권 블록이 null로 온다.
    private static let resetCreditsQuery = "cedar_ember=1"

    static var accountURL: URL { URL(string: "\(webAPIBase)/account")! }

    static func webUsageURL(organizationID: String) -> URL {
        URL(string: "\(webAPIBase)/organizations/\(organizationID)/usage?\(resetCreditsQuery)")!
    }

    static var oauthUsageURL: URL { URL(string: "\(oauthAPIBase)/usage?\(resetCreditsQuery)")! }
    /// 초기화권 쿼리를 거부한 응답 뒤에 한 번만 쓴다. 사용량은 이 쿼리 없이도 온다.
    static var oauthUsageURLWithoutResetCredits: URL { URL(string: "\(oauthAPIBase)/usage")! }

    /// 선택 쿼리만 거부한 응답인지. Cloudflare 확인 페이지와 인증 실패(401)는 해당하지 않는다.
    static func rejectsOptionalUsageQuery(status: Int, data: Data?) -> Bool {
        status == 400 || (status == 403 && !HTTPResponseClassification.isCloudflareChallenge(data))
    }
    static var oauthProfileURL: URL { URL(string: "\(oauthAPIBase)/profile")! }

    static func applyWebHeaders(to request: inout URLRequest, sessionKey: String) {
        // Cookie 헤더를 직접 넣으면 저장된 쿠키는 보내지 않는다. 응답의 세션 쿠키를 앱 쿠키 저장소에 남기지 않는다.
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webOrigin, forHTTPHeaderField: "Referer")
        request.setValue(webOrigin, forHTTPHeaderField: "Origin")
    }

    /// 이전 버전이 앱 쿠키 저장소에 남긴 claude.ai 쿠키(세션 키 포함)를 지운다. 이 쿠키를 읽는 곳은 없다.
    static func removeStoredWebCookies(from storage: HTTPCookieStorage = .shared) {
        for cookie in storage.cookies ?? [] where cookie.domain == "claude.ai" || cookie.domain.hasSuffix(".claude.ai")
        {
            storage.deleteCookie(cookie)
        }
    }

    static func applyOAuthHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(oauthUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
    }
}
