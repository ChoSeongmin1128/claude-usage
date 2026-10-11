import Foundation

@MainActor
final class AppRuntimeStateFacade {
    private var runtimeStateCatalog = RuntimeProviderStateCatalog()

    private(set) var claudeRequestRevision = UUID()
    private var supplementalUsage: ClaudeSupplementalUsage?
    private var overageFailure: (accountID: String, ownerKey: String, at: Date)?

    var overageOwnerKey: String? { self[.claude].lastSuccessfulMetadata?.supplementalAccountKey }

    private var scopedSupplementalUsage: ClaudeSupplementalUsage? {
        guard let value = supplementalUsage, let ownerKey = overageOwnerKey,
            value.accountID == activeClaudeAccountID, value.ownerKey == ownerKey
        else { return nil }
        return value
    }

    var currentOverage: OverageSpendLimitResponse? { scopedSupplementalUsage?.value }

    var lastOverageFetchAt: Date? { scopedSupplementalUsage?.fetchedAt }

    /// 실패한 조회도 간격 제한에 넣는다. 성공한 시각만 보면 계속 실패하는 계정은 조회할 때마다 다시 요청한다.
    var lastOverageAttemptAt: Date? {
        let failedAt =
            overageFailure?.accountID == activeClaudeAccountID && overageOwnerKey != nil
                && overageFailure?.ownerKey == overageOwnerKey ? overageFailure?.at : nil
        return [lastOverageFetchAt, failedAt].compactMap { $0 }.max()
    }

    /// 조회마다 새 소유권을 준다. 같은 계정의 이전 사용량과 추가 사용량은 보존한다.
    func beginClaudeUsageRequest() -> UUID {
        claudeRequestRevision = UUID()
        return claudeRequestRevision
    }

    @discardableResult
    func finishCancelledClaudeUsageRequest(_ revision: UUID) -> Bool {
        guard revision == claudeRequestRevision else { return false }
        var state = self[.claude]
        guard state.isLoading else { return false }
        state.isLoading = false
        state.loadingStartedAt = nil
        state.lastAttemptState = .idle
        state.lastAttemptError = nil
        state.lastAttemptMetadata = nil
        self[.claude] = state
        return true
    }

    func invalidateClaudeRequestContext() {
        claudeRequestRevision = UUID()
        supplementalUsage = nil
        overageFailure = nil
    }

    func applyClaudeSupplementalUsage(
        _ result: ClaudeSupplementalRefreshResult, accountID: String, ownerKey: String?
    ) {
        guard accountID == activeClaudeAccountID, let ownerKey else { return }
        if supplementalUsage?.ownerKey != ownerKey { supplementalUsage = nil }
        switch result {
        case .unchanged:
            break
        case .success(let value, let fetchedAt):
            supplementalUsage = ClaudeSupplementalUsage(
                accountID: accountID, ownerKey: ownerKey, value: value, fetchedAt: fetchedAt)
        case .failed:
            supplementalUsage?.lastRefreshFailed = true
            overageFailure = (accountID, ownerKey, Date())
        }
    }

    var currentClaudeNotificationPolicy: ClaudeNotificationPolicy?
    var currentClaudeProfileMetadata: ClaudeProfileMetadata?
    var activeClaudeAccountID: String? {
        didSet {
            if oldValue != activeClaudeAccountID { invalidateClaudeRequestContext() }
        }
    }
    var systemStatus: ClaudeSystemStatus?
    var providerSystemStatuses: [AppProviderKind: ProviderSystemStatus] = [:]
    var antigravityRuntimeSnapshot = AntigravityRuntimeSnapshot.idle
    var claudeCredentialAvailability = ClaudeCredentialAvailability(
        sessionCredentialAvailable: false,
        oauthCredentialAvailable: false
    )

    subscript(service: PopoverService) -> RuntimeProviderState {
        get { runtimeStateCatalog[service] }
        set { runtimeStateCatalog[service] = newValue }
    }

    func snapshot(
        for service: PopoverService,
        codexAuthenticated: Bool
    ) -> RuntimeProviderSnapshot {
        let state = self[service]

        switch service {
        case .claude:
            let hasCredential = claudeCredentialAvailability.hasAnyCredential
            return RuntimeProviderSnapshot(
                service: .claude,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: hasCredential ? .usable : .missing,
                isDetected: hasCredential,
                canAttemptRefresh: hasCredential,
                hasAuthError: state.hasAuthError,
                lastAttemptState: state.lastAttemptState,
                lastSuccessfulMetadata: state.lastSuccessfulMetadata,
                lastAttemptMetadata: state.lastAttemptMetadata,
                claudeOverage: state.lastSuccessfulMetadata?.accountID == activeClaudeAccountID
                    ? (currentOverage ?? state.claudeUsage?.extraUsage) : nil,
                claudeOverageUpdatedAt: lastOverageFetchAt,
                claudeOverageIsStale: scopedSupplementalUsage?.lastRefreshFailed ?? false,
                consecutiveFailures: state.consecutiveFailures
            )
        case .codex:
            return RuntimeProviderSnapshot(
                service: .codex,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: codexAuthenticated ? .usable : .missing,
                isDetected: codexAuthenticated,
                canAttemptRefresh: codexAuthenticated,
                hasAuthError: state.hasAuthError,
                lastAttemptState: state.lastAttemptState,
                lastSuccessfulMetadata: state.lastSuccessfulMetadata,
                lastAttemptMetadata: state.lastAttemptMetadata,
                consecutiveFailures: state.consecutiveFailures
            )
        case .antigravity:
            let snapshot = antigravityRuntimeSnapshot
            let canAttemptRefresh =
                Self.antigravityCanAttemptRefresh(
                    snapshot
                )
            return RuntimeProviderSnapshot(
                service: .antigravity,
                payload: nil,
                error: nil,
                isLoading: snapshot.isLoading,
                lastUpdated:
                    snapshot.lastSuccessfulAt,
                nextRefreshAllowedAt: nil,
                credentialState:
                    Self.antigravityCredentialState(
                        snapshot,
                        canAttemptRefresh:
                            canAttemptRefresh
                    ),
                isDetected:
                    snapshot.settings != nil,
                canAttemptRefresh:
                    canAttemptRefresh,
                hasAuthError: false,
                lastAttemptState:
                    Self.antigravityAttemptState(
                        snapshot
                    ),
                lastSuccessfulMetadata: nil,
                lastAttemptMetadata: nil
            )
        }
    }

    private static func antigravityCanAttemptRefresh(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> Bool {
        switch snapshot.readiness {
        case .ready:
            return snapshot.settings != nil
        case .blocked(.typedSettings):
            // 설정을 한 번 읽지 못한 상태는 다음 조회가 설정을 다시 읽어 스스로 복구한다.
            return true
        case .idle, .bootstrapping, .blocked, .shuttingDown:
            return false
        }
    }

    private static func antigravityCredentialState(
        _ snapshot: AntigravityRuntimeSnapshot,
        canAttemptRefresh: Bool
    ) -> ProviderCredentialState {
        if canAttemptRefresh {
            return .refreshable
        }
        switch snapshot.readiness {
        case .idle, .bootstrapping:
            return .unknown
        case .ready, .blocked, .shuttingDown:
            return .missing
        }
    }

    private static func antigravityAttemptState(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> RuntimeProviderAttemptState {
        AntigravityStatusProjection(snapshot: snapshot).attemptState
    }

    @discardableResult
    func applyClaudeUsageHealthSnapshot(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> Bool {
        let previousCredentialAvailability = claudeCredentialAvailability.hasAnyCredential
        if activeClaudeAccountID != snapshot.activeAccountID {
            runtimeStateCatalog[.claude] = RuntimeProviderState()
        }
        activeClaudeAccountID = snapshot.activeAccountID
        claudeCredentialAvailability = snapshot.runtime.credentialAvailability
        return previousCredentialAvailability != claudeCredentialAvailability.hasAnyCredential
    }

    func clearClaudePresentationState() {
        runtimeStateCatalog[.claude] = RuntimeProviderState()
        invalidateClaudeRequestContext()
        currentClaudeProfileMetadata = nil
        currentClaudeNotificationPolicy = nil
        activeClaudeAccountID = nil
    }

    func systemStatus(for kind: AppProviderKind) -> ProviderSystemStatus? {
        if kind == .claude {
            return providerSystemStatuses[.claude] ?? systemStatus
        }
        return providerSystemStatuses[kind]
    }

    /// 상태 페이지를 읽지 못한 회차는 마지막으로 읽은 상태를 그대로 둔다. 한 번도 읽지 못한 서비스는 비어 있다.
    func recordSystemStatusFetch(_ status: ProviderSystemStatus?, for kind: AppProviderKind) {
        guard let status else { return }
        setSystemStatus(status, for: kind)
    }

    func setSystemStatus(_ status: ProviderSystemStatus?, for kind: AppProviderKind) {
        if let status {
            providerSystemStatuses[kind] = status
        } else {
            providerSystemStatuses.removeValue(forKey: kind)
        }

        if kind == .claude {
            systemStatus = status
        }
    }
}
