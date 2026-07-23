import Foundation

struct CompactPopoverHeaderContext: Equatable {
    enum Status: Equatable {
        case refreshing
        case authenticationRequired
        case refreshFailed

        var label: String {
            switch self {
            case .refreshing:
                return "갱신 중"
            case .authenticationRequired:
                return "로그인 필요"
            case .refreshFailed:
                return "갱신 실패"
            }
        }
    }

    let accountLabel: String?
    let status: Status?

    var labels: [String] {
        [accountLabel, status?.label].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }
}

enum CompactPopoverHeaderPresentationPolicy {
    /// Compact 모드는 사용량 스캔이 주목적이다. 정상 상태의 provenance와
    /// freshness는 숨기고, 계정 혼동을 막는 실제 식별자와 행동 가능한 상태만
    /// 상단 한 줄에 노출한다.
    static func resolve(
        accountCount: Int,
        activeAccount: ClaudeAccount?,
        isLoading: Bool,
        isAuthenticationRequired: Bool,
        hasRefreshError: Bool
    ) -> CompactPopoverHeaderContext? {
        let accountLabel = accountCount > 1
            ? actualIdentityLabel(for: activeAccount)
            : nil

        let status: CompactPopoverHeaderContext.Status?
        if isAuthenticationRequired {
            status = .authenticationRequired
        } else if isLoading {
            status = .refreshing
        } else if hasRefreshError {
            status = .refreshFailed
        } else {
            status = nil
        }

        guard accountLabel != nil || status != nil else { return nil }
        return CompactPopoverHeaderContext(accountLabel: accountLabel, status: status)
    }

    private static func actualIdentityLabel(for account: ClaudeAccount?) -> String? {
        guard let account else { return nil }
        // planLabel("team" 등)은 계정 식별자가 아니므로 compact 헤더에 쓰지 않는다.
        return account.identity.email ?? account.identity.organizationName
    }
}
