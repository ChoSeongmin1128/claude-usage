import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeCodeUnavailablePresentationTests: XCTestCase {
    func testExecutableMissingHasSameAccurateAdviceInAuthAndErrorPanels() {
        let auth = CatalogPopoverPresentationAdapter.statusSummary(
            phase: .authRequired, error: nil, service: .claude, claudeCodeCredentialIssue: .executableNotFound)
        let error = CatalogPopoverPresentationAdapter.statusSummary(
            phase: .error, error: .claudeCodeExecutableNotFound, service: .claude)
        XCTAssertEqual(auth?.message, ClaudeCodeCredentialIssue.executableNotFoundExplanation)
        XCTAssertEqual(auth?.message, error?.message)
        XCTAssertEqual(auth?.action, .openSettings)
        XCTAssertFalse(auth?.title.contains("로그인 만료") == true)
    }

    func testMissingExecutableOverridesVerifiedAccountAndCompactLoginLabel() {
        let account = ClaudeAccount(
            id: "cli", kind: .claudeCodeExternal, displayName: "CLI", lastValidationState: .verified)
        let presentation = ClaudeAccountSettingsPresentation.resolve(
            account: account, isActive: true, claudeCodeCredentialIssue: .executableNotFound)
        XCTAssertEqual(presentation.statusText, "Claude Code 없음")
        let compact = CompactPopoverHeaderPresentationPolicy.resolve(
            accountCount: 1, activeAccount: account, isLoading: false, isAuthenticationRequired: true,
            hasRefreshError: false, claudeCodeCredentialIssue: .executableNotFound)
        XCTAssertEqual(compact?.labels, ["Claude Code 없음"])
    }

    func testRuntimeFailurePreservesLastSuccessfulQuotaAndAccount() {
        let metadata = RuntimeProviderFetchMetadata(sourceLabel: "Claude Code", accountID: "cli")
        var state = RuntimeProviderState()
        RuntimeProviderRefreshCoordinator.applySuccess(
            state: &state, payload: .claude(.init(fiveHour: .init(utilization: 42, resetsAt: nil), sevenDay: nil)),
            metadata: metadata)
        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state, error: .claudeCodeExecutableNotFound, minimumInterval: 30)
        XCTAssertNotNil(state.payload)
        XCTAssertEqual(state.lastSuccessfulMetadata?.accountID, "cli")
        XCTAssertFalse(state.hasAuthError)
        XCTAssertEqual(state.lastAttemptState, .definitiveFailure)
    }

    func testFirstMissingExecutableFailureKeepsAccurateAdviceAheadOfAuthPhase() {
        let settings = AppSettings.shared
        let saved = settings.createSnapshot()
        defer { settings.restore(from: saved) }
        settings.setProviderEnabled(true, for: .claude)
        let model = PopoverViewModel()
        model.update(snapshots: [
            RuntimeProviderSnapshot(
                service: .claude, payload: nil, error: .claudeCodeExecutableNotFound, isLoading: false,
                lastUpdated: nil, nextRefreshAllowedAt: nil, credentialState: .missing,
                isDetected: true, canAttemptRefresh: true, hasAuthError: false)
        ])

        XCTAssertEqual(model.contentPhase(for: .claude, settings: settings), .authRequired)
        XCTAssertEqual(model.claudeCodeCredentialIssue, .executableNotFound)
        XCTAssertEqual(model.authRequiredStatusLabel(for: .claude), "Claude Code 없음")
        let panel = CatalogPopoverPresentationAdapter.statusSummary(
            phase: model.contentPhase(for: .claude, settings: settings),
            error: model.runtimeServiceState(for: .claude, settings: settings).error,
            service: .claude, claudeCodeCredentialIssue: model.claudeCodeCredentialIssue)
        XCTAssertEqual(panel?.message, ClaudeCodeCredentialIssue.executableNotFoundExplanation)
        XCTAssertEqual(panel?.action, .openSettings)
    }

    func testMissingExecutableKeepsLastGoodQuotaAndExactAdviceInCompactAndStandardHeaders() {
        let settings = AppSettings.shared
        let saved = settings.createSnapshot()
        defer { settings.restore(from: saved) }
        settings.setProviderEnabled(true, for: .claude)
        let usage = ClaudeUsageResponse(fiveHour: .init(utilization: 42, resetsAt: nil), sevenDay: nil)
        let model = PopoverViewModel()
        model.update(snapshots: [
            RuntimeProviderSnapshot(
                service: .claude, payload: .claude(usage), error: .claudeCodeExecutableNotFound, isLoading: false,
                lastUpdated: Date().addingTimeInterval(-60), nextRefreshAllowedAt: nil, credentialState: .refreshable,
                isDetected: true, canAttemptRefresh: true, hasAuthError: false)
        ])

        XCTAssertEqual(model.contentPhase(for: .claude, settings: settings), .content)
        XCTAssertEqual(model.claudeUsage?.fiveHour?.utilization, 42)
        let compact = model.compactHeaderContext(for: .claude, settings: settings)
        XCTAssertEqual(compact?.status, .executableNotFound)
        XCTAssertTrue(compact?.labels.contains("Claude Code 없음") == true)
        XCTAssertTrue(compact?.helpText.contains(ClaudeCodeCredentialIssue.executableNotFoundExplanation) == true)
        let standard = model.runtimeServiceState(for: .claude, settings: settings)
        XCTAssertTrue(standard.meta?.contains("Claude Code 없음") == true)
        XCTAssertEqual(standard.failureHelpText, ClaudeCodeCredentialIssue.executableNotFoundExplanation)
        XCTAssertFalse(standard.isAuthRequired)
    }

    func testPrimarySettingsActionDoesNotStartLogin() {
        let model = PopoverViewModel()
        var settingsOpened: [PopoverService] = []
        var loginsStarted = 0
        model.onOpenSettingsForService = { settingsOpened.append($0) }
        model.onStartClaudeLogin = { loginsStarted += 1 }
        let settings = AppSettings.shared
        let host = ProviderPopoverContentHost(
            viewModel: model, settings: settings, service: .claude,
            layoutSpec: model.layoutSpec(for: .claude, settings: settings), sections: [], onOpenDisplayEditor: {})
        let copy = CatalogPopoverPresentationAdapter.claudeAuthRequiredSummary(
            claudeCodeCredentialIssue: .executableNotFound)
        host.action(for: copy.action)?()
        XCTAssertEqual(settingsOpened, [.claude])
        XCTAssertEqual(loginsStarted, 0)
    }

    func testMultiAccountMissingExecutableKeepsItsPreviousNumbers() {
        var state = UsageAccountState(usage: .init(fiveHour: .init(usedPercent: 42, resetsAt: nil)))
        state.issue = .executableNotFound
        XCTAssertEqual(state.status(isArchived: false), .executableNotFound)
        XCTAssertEqual(state.usage?.fiveHour?.usedPercent, 42)
    }
}
