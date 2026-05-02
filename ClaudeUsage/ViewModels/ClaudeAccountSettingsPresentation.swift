import Foundation

struct ClaudeAccountSettingsPresentation: Equatable {
    let title: String
    let accountLine: String
    let detailLine: String
    let statusLine: String
    let systemImage: String

    static func resolve(account: ClaudeAccount) -> ClaudeAccountSettingsPresentation {
        ClaudeAccountSettingsPresentation(
            title: title(for: account.kind),
            accountLine: "계정: \(accountLabel(for: account))",
            detailLine: detailLine(for: account.kind),
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

    private static func title(for kind: ClaudeAccountKind) -> String {
        switch kind {
        case .webSession:
            return "브라우저에서 가져온 로그인"
        case .claudeCodeExternal:
            return "터미널 Claude Code 로그인"
        }
    }

    private static func detailLine(for kind: ClaudeAccountKind) -> String {
        switch kind {
        case .webSession:
            return "Chrome 가져오기 또는 앱내 웹 로그인으로 저장한 로그인입니다"
        case .claudeCodeExternal:
            return "터미널의 Claude Code 로그인 상태를 읽기만 합니다"
        }
    }

    private static func accountLabel(for account: ClaudeAccount) -> String {
        let labels = [
            account.identity.email,
            account.identity.organizationName,
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
            return "저장된 브라우저 로그인"
        case .claudeCodeExternal:
            return "현재 Claude Code CLI 로그인"
        }
    }

    private static func meaningfulDisplayName(for account: ClaudeAccount) -> String? {
        let value = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch account.kind {
        case .webSession:
            return ["브라우저 계정", ClaudeAccountKind.webSession.displayName].contains(value) ? nil : value
        case .claudeCodeExternal:
            return ["Claude Code 계정", ClaudeAccountKind.claudeCodeExternal.displayName].contains(value) ? nil : value
        }
    }
}
