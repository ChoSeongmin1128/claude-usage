import Foundation

struct ClaudeAccountSettingsPresentation: Equatable {
    let title: String
    let identifierLine: String
    let sourceLine: String
    let organizationLine: String?
    let statusLine: String
    let systemImage: String

    static func resolve(
        account: ClaudeAccount,
        organizations: [ClaudeAPIService.OrganizationSummary] = [],
        previews: [String: ClaudeAPIService.OrganizationPreview] = [:]
    ) -> ClaudeAccountSettingsPresentation {
        ClaudeAccountSettingsPresentation(
            title: title(for: account),
            identifierLine: "식별: \(identifierLabel(for: account))",
            sourceLine: "출처: \(sourceLabel(for: account))",
            organizationLine: organizationLine(for: account, organizations: organizations, previews: previews),
            statusLine: "상태: \(statusLabel(for: account.lastValidationState))",
            systemImage: account.kind == .webSession ? "globe" : "terminal"
        )
    }

    static func statusLabel(for state: ClaudeCredentialValidationState) -> String {
        switch state {
        case .unavailable:
            return "확인 전"
        case .detected:
            return "감지됨"
        case .verified:
            return "최근 조회 성공"
        case .failed:
            return "확인 필요"
        }
    }

    private static func title(for account: ClaudeAccount) -> String {
        switch account.kind {
        case .webSession:
            switch account.source {
            case .chromeProfile:
                return "Chrome 프로필 로그인"
            case .embeddedWebLogin:
                return "앱내 웹 로그인"
            case .manualInput:
                return "수동 입력 로그인"
            case .legacyMigration:
                return "기존 브라우저 로그인"
            case .claudeCodeCLI, .none:
                return "브라우저 로그인"
            }
        case .claudeCodeExternal:
            return "터미널 Claude Code 로그인"
        }
    }

    private static func sourceLabel(for account: ClaudeAccount) -> String {
        switch account.kind {
        case .webSession:
            switch account.source {
            case .chromeProfile:
                if let detail = account.sourceDetail, !detail.isEmpty {
                    return "Chrome 프로필 \(detail)"
                }
                return "Chrome 프로필"
            case .embeddedWebLogin:
                return "앱내 웹 로그인"
            case .manualInput:
                return "고급 설정 수동 입력"
            case .legacyMigration:
                return "업데이트 전 저장된 브라우저 로그인"
            case .claudeCodeCLI, .none:
                return "브라우저 로그인"
            }
        case .claudeCodeExternal:
            return "터미널 Claude Code CLI"
        }
    }

    private static func identifierLabel(for account: ClaudeAccount) -> String {
        let labels = [
            account.identity.email,
            account.identity.planLabel,
            meaningfulDisplayName(for: account),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        var uniqueLabels: [String] = []
        for label in labels where !uniqueLabels.contains(label) {
            uniqueLabels.append(label)
        }

        if !uniqueLabels.isEmpty {
            return uniqueLabels.joined(separator: " · ")
        }

        switch account.kind {
        case .webSession:
            if account.source == .chromeProfile, let detail = account.sourceDetail {
                return "Chrome 프로필 \(detail)"
            }
            return "저장된 브라우저 로그인"
        case .claudeCodeExternal:
            return "현재 Claude Code CLI 로그인"
        }
    }

    private static func organizationLine(
        for account: ClaudeAccount,
        organizations: [ClaudeAPIService.OrganizationSummary],
        previews: [String: ClaudeAPIService.OrganizationPreview]
    ) -> String? {
        let organizationID = [
            Optional(account.preferredOrganizationID),
            account.identity.organizationID,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        if let organizationID,
           let organization = organizations.first(where: { $0.id == organizationID }) {
            return "조직: \(organizationLabel(for: organization, preview: previews[organization.id]))"
        }

        if let organizationName = account.identity.organizationName {
            return "조직: \(organizationName)"
        }

        if let organizationID, !organizationID.isEmpty {
            return "조직: \(shortOrganizationID(organizationID))"
        }

        if account.kind == .claudeCodeExternal {
            return nil
        }

        return "조직: 확인 전"
    }

    private static func organizationLabel(
        for organization: ClaudeAPIService.OrganizationSummary,
        preview: ClaudeAPIService.OrganizationPreview?
    ) -> String {
        var label = organization.displayName
        guard let preview else { return label }

        if preview.overageEnabled == true {
            if let used = preview.overageUsed,
               let limit = preview.overageLimit {
                label += " · 추가 사용량 \(formatCurrency(used)) / \(formatCurrency(limit))"
            } else {
                label += " · 추가 사용량 켜짐"
            }
        } else if preview.overageEnabled == false {
            label += " · 추가 사용량 꺼짐"
        }

        return label
    }

    private static func shortOrganizationID(_ id: String) -> String {
        if id.count <= 12 { return id }
        return "\(id.prefix(8))..."
    }

    private static func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func meaningfulDisplayName(for account: ClaudeAccount) -> String? {
        let value = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch account.kind {
        case .webSession:
            let genericValues = ["브라우저 계정", ClaudeAccountKind.webSession.displayName]
            if genericValues.contains(value) { return nil }
            if account.source == .chromeProfile,
               let detail = account.sourceDetail,
               value == "Chrome \(detail)" {
                return nil
            }
            return value
        case .claudeCodeExternal:
            return ["Claude Code 계정", ClaudeAccountKind.claudeCodeExternal.displayName].contains(value) ? nil : value
        }
    }
}
