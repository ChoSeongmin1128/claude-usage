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
    static var oauthProfileURL: URL { URL(string: "\(oauthAPIBase)/profile")! }

    static func applyWebHeaders(to request: inout URLRequest, sessionKey: String) {
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webOrigin, forHTTPHeaderField: "Referer")
        request.setValue(webOrigin, forHTTPHeaderField: "Origin")
    }

    static func applyOAuthHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(oauthUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
    }
}
