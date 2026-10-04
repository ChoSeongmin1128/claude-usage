import Foundation

enum ClaudeAccountStatusTone: Equatable {
    case neutral
    case success
    case warning
}

/// Usage health snapshots carry the account inventory that existed when the
/// request started. Identity/profile enrichment may finish later for the same
/// account, so Settings must present the current store state rather than
/// replacing it with that older snapshot copy.
enum ClaudeAccountSnapshotPresentationPolicy {
    nonisolated static func resolve(
        snapshotActiveAccountID: String?,
        currentState: ClaudeAccountState
    ) -> ClaudeAccountState? {
        guard snapshotActiveAccountID == currentState.activeAccountID else {
            return nil
        }
        return currentState
    }
}

/// 설정 계정 카드에 보이는 메뉴바 계정 한 줄
struct ClaudeAccountSettingsPresentation: Equatable {
    let primaryTitle: String
    let secondaryLine: String?
    let sourceLabel: String?
    let statusText: String
    let statusTone: ClaudeAccountStatusTone
    let systemImage: String

    static func resolve(
        account: ClaudeAccount,
        isActive: Bool = false,
        organizations: [ClaudeAPIService.OrganizationSummary] = [],
        claudeCodeCredentialIssue: ClaudeCodeCredentialIssue? = nil
    ) -> ClaudeAccountSettingsPresentation {
        let status =
            account.kind == .claudeCodeExternal
            ? issueStatusPresentation(claudeCodeCredentialIssue) ?? statusPresentation(for: account.lastValidationState)
            : statusPresentation(for: account.lastValidationState)
        return ClaudeAccountSettingsPresentation(
            primaryTitle: primaryTitle(for: account),
            secondaryLine: organizationLabel(for: account, organizations: isActive ? organizations : []),
            sourceLabel: sourceLabel(for: account),
            statusText: status.text,
            statusTone: status.tone,
            systemImage: account.kind == .webSession ? "globe" : "terminal"
        )
    }

    private static func primaryTitle(for account: ClaudeAccount) -> String {
        let email = account.identity.email ?? emailFromSourceDetail(account.sourceDetail)
        let displayName = meaningfulDisplayName(for: account)

        switch account.kind {
        case .webSession:
            if account.source == .chromeProfile, let displayName, let email {
                return "\(displayName) · \(email)"
            }
            if let email {
                return email
            }
            if let displayName {
                return displayName
            }
            return "저장된 Claude 계정"
        case .claudeCodeExternal:
            if let email {
                return email
            }
            if let displayName {
                return displayName
            }
            return "Claude Code 계정"
        }
    }

    private static func sourceLabel(for account: ClaudeAccount) -> String {
        switch account.kind {
        case .claudeCodeExternal:
            return "Claude Code"
        case .webSession:
            switch account.source {
            case .chromeProfile: return ClaudeBrowserFamily.family(fromSourceDetail: account.sourceDetail).displayName
            case .embeddedWebLogin: return "앱에서 로그인"
            case .manualInput: return "직접 입력"
            case .legacyMigration: return "이전 버전에서 가져온 로그인"
            case .claudeCodeCLI, .none: return "웹 로그인"
            }
        }
    }

    private static func organizationLabel(
        for account: ClaudeAccount,
        organizations: [ClaudeAPIService.OrganizationSummary]
    ) -> String? {
        let organizationID = [
            account.userSelectedPreferredOrganizationID,
            account.identity.organizationID,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        if let organizationID,
           let organization = organizations.first(where: { $0.id == organizationID }) {
            return nilIfEmpty(organization.name) ?? shortOrganizationID(organization.id)
        }

        if let organizationName = account.identity.organizationName {
            return organizationName
        }

        if let organizationID, !organizationID.isEmpty {
            return shortOrganizationID(organizationID)
        }

        return nil
    }

    /// 저장된 검증 결과는 마지막 성공 뒤로 갱신되지 않으므로, 지금 읽기에 실패한 이유를 먼저 보여준다.
    private static func issueStatusPresentation(
        _ issue: ClaudeCodeCredentialIssue?
    ) -> (text: String, tone: ClaudeAccountStatusTone)? {
        switch issue {
        case .reconnectRequired:
            return ("다시 연결 필요", .warning)
        case .reauthenticationRequired:
            return ("Claude Code 로그인 필요", .warning)
        case .executableNotFound:
            return ("Claude Code 없음", .warning)
        case nil:
            return nil
        }
    }

    private static func statusPresentation(
        for state: ClaudeCredentialValidationState
    ) -> (text: String, tone: ClaudeAccountStatusTone) {
        switch state {
        case .verified:
            return ("연결됨", .success)
        case .failed:
            return ("다시 로그인 필요", .warning)
        case .unavailable, .detected:
            return ("확인 전", .neutral)
        }
    }

    private static func meaningfulDisplayName(for account: ClaudeAccount) -> String? {
        let value = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch account.kind {
        case .webSession:
            let genericValues = ["브라우저 계정", ClaudeAccountKind.webSession.displayName]
            return genericValues.contains(value) ? nil : value
        case .claudeCodeExternal:
            return ["Claude Code 계정", ClaudeAccountKind.claudeCodeExternal.displayName].contains(value) ? nil : value
        }
    }

    private static func emailFromSourceDetail(_ sourceDetail: String?) -> String? {
        guard let sourceDetail else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "·,;()<>[]"))
        let email = sourceDetail
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .first { token in
                token.contains("@") && token.contains(".")
            }
        return nilIfEmpty(email)
    }

    private static func shortOrganizationID(_ id: String) -> String {
        if id.count <= 12 { return id }
        return "\(id.prefix(8))..."
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
