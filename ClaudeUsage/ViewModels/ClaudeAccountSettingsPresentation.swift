import Foundation

enum ClaudeAccountSettingsAction: String, Equatable, Hashable {
    case use
    case deleteWebSession
    case showClaudeCodeLoginGuidance

    var title: String {
        switch self {
        case .use:
            return "사용"
        case .deleteWebSession:
            return "삭제"
        case .showClaudeCodeLoginGuidance:
            return "다시 로그인 안내"
        }
    }
}

enum ClaudeAccountStatusTone: Equatable {
    case neutral
    case success
    case warning
}

struct ClaudeAccountSettingsDetailRow: Equatable, Hashable {
    let title: String
    let value: String
}

struct ClaudeAccountSettingsPresentation: Equatable {
    let primaryTitle: String
    let secondaryLine: String?
    let statusText: String
    let statusTone: ClaudeAccountStatusTone
    let availableActions: [ClaudeAccountSettingsAction]
    let systemImage: String
    let detailRows: [ClaudeAccountSettingsDetailRow]

    static func resolve(
        account: ClaudeAccount,
        isActive: Bool = false,
        organizations: [ClaudeAPIService.OrganizationSummary] = []
    ) -> ClaudeAccountSettingsPresentation {
        let organization = organizationLabel(for: account, organizations: organizations)
        let source = sourceDescription(for: account)
        let detailRows = detailRows(for: account, organization: organization, source: source)
        let status = statusPresentation(for: account.lastValidationState)
        var actions: [ClaudeAccountSettingsAction] = []

        if !isActive {
            actions.append(.use)
        }
        switch account.kind {
        case .webSession:
            actions.append(.deleteWebSession)
        case .claudeCodeExternal:
            actions.append(.showClaudeCodeLoginGuidance)
        }

        return ClaudeAccountSettingsPresentation(
            primaryTitle: primaryTitle(for: account),
            secondaryLine: organization,
            statusText: status.text,
            statusTone: status.tone,
            availableActions: actions,
            systemImage: account.kind == .webSession ? "globe" : "terminal",
            detailRows: detailRows
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
            return "현재 터미널 Claude Code 계정"
        }
    }

    private static func sourceDescription(for account: ClaudeAccount) -> String? {
        switch account.kind {
        case .webSession:
            switch account.source {
            case .chromeProfile:
                if let source = chromeProfileSourceDescription(for: account) {
                    return source
                }
                if let profileName = readableChromeProfileName(from: account.sourceDetail) {
                    return "Chrome \(profileName)"
                }
                return "Chrome 프로필"
            case .embeddedWebLogin:
                return "앱에서 로그인"
            case .manualInput:
                return "수동 입력"
            case .legacyMigration:
                return "이전 버전에서 가져온 로그인"
            case .claudeCodeCLI, .none:
                return "브라우저 로그인"
            }
        case .claudeCodeExternal:
            return "터미널 Claude Code"
        }
    }

    private static func organizationLabel(
        for account: ClaudeAccount,
        organizations: [ClaudeAPIService.OrganizationSummary]
    ) -> String? {
        let organizationID = [
            Optional(account.preferredOrganizationID),
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

    private static func statusPresentation(
        for state: ClaudeCredentialValidationState
    ) -> (text: String, tone: ClaudeAccountStatusTone) {
        switch state {
        case .verified:
            return ("최근 조회 성공", .success)
        case .failed:
            return ("확인 필요", .warning)
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

    private static func readableChromeProfileName(from sourceDetail: String?) -> String? {
        guard let sourceDetail = nilIfEmpty(sourceDetail) else { return nil }
        let profilePart = sourceDetail.components(separatedBy: "·").first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard var profilePart, !profilePart.isEmpty else { return nil }

        if let range = profilePart.range(of: #" \([^)]+\)"#, options: String.CompareOptions.regularExpression) {
            profilePart.removeSubrange(range)
        }

        return nilIfEmpty(profilePart.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
    }

    private static func chromeProfileSourceDescription(for account: ClaudeAccount) -> String? {
        guard let sourceDetail = nilIfEmpty(account.sourceDetail) else {
            return meaningfulDisplayName(for: account)
        }
        let profilePart = sourceDetail.components(separatedBy: "·").first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return nilIfEmpty(profilePart) ?? meaningfulDisplayName(for: account)
    }

    private static func detailRows(
        for account: ClaudeAccount,
        organization: String?,
        source: String?
    ) -> [ClaudeAccountSettingsDetailRow] {
        var rows: [ClaudeAccountSettingsDetailRow] = []

        if let organization {
            rows.append(ClaudeAccountSettingsDetailRow(title: "조직", value: organization))
        } else if account.kind == .webSession {
            rows.append(ClaudeAccountSettingsDetailRow(title: "조직", value: "확인 전"))
        }

        if let source {
            let title = account.source == .chromeProfile ? "Chrome 프로필" : "로그인 방식"
            rows.append(ClaudeAccountSettingsDetailRow(title: title, value: source))
        }

        if let organizationID = nilIfEmpty(account.identity.organizationID ?? account.preferredOrganizationID) {
            let shortID = shortOrganizationID(organizationID)
            if shortID != organization {
                rows.append(ClaudeAccountSettingsDetailRow(title: "조직 ID", value: shortID))
            }
        }

        return rows
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
