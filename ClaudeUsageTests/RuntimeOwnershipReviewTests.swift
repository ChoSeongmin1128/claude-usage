import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class RuntimeOwnershipReviewTests: XCTestCase {
    private func codex(_ email: String?, workspace: String?) throws -> CodexUsageSnapshot {
        let claims = try JSONSerialization.data(withJSONObject: email.map { ["email": $0] } ?? [:])
        let jwt = "header.\(claims.base64EncodedString()).signature"
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("{}".utf8))
        return CodexUsageSnapshot(
            usage: usage,
            credential: .init(
                token: .init(accessToken: "fixture", idToken: jwt, accountID: workspace),
                generation: UUID(), sourceURL: URL(fileURLWithPath: "/fixture/.codex/auth.json")))
    }

    func testResetCreditsAreOwnedByValidatedUserAndWorkspaceRatherThanDiscovery() throws {
        let suite = "RuntimeOwnershipReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = CodexUsageAccountProvider.runtimeAccount(for: try codex("a@example.com", workspace: "team"))
        let b = CodexUsageAccountProvider.runtimeAccount(for: try codex("b@example.com", workspace: "team"))
        let aKey = try XCTUnwrap(RuntimeProviderFetchMetadata(account: a).resetCreditAccountKey(for: .codex))
        let bKey = try XCTUnwrap(RuntimeProviderFetchMetadata(account: b).resetCreditAccountKey(for: .codex))
        XCTAssertNotEqual(aKey, bKey)
        XCTAssertEqual(aKey, "codex:a@example.com|team")
        ResetCreditSeenStore.observe(summary: nil, count: 1, accountKey: aKey, defaults: defaults)
        ResetCreditSeenStore.observe(summary: nil, count: 3, accountKey: bKey, defaults: defaults)
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: aKey, defaults: defaults))
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: bKey, defaults: defaults))
        ResetCreditSeenStore.observe(summary: nil, count: 2, accountKey: aKey, defaults: defaults)
        XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: aKey, defaults: defaults))
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: bKey, defaults: defaults))
    }

    func testMissingUserOrWorkspaceDoesNotMakeResetCreditOwner() throws {
        for (email, workspace) in [(nil, "team"), ("a@example.com", nil)] {
            let candidate = CodexUsageAccountProvider.runtimeAccount(for: try codex(email, workspace: workspace))
            XCTAssertNil(RuntimeProviderFetchMetadata(account: candidate).resetCreditAccountKey(for: .codex))
        }
    }

    func testClaudeAndCodexMenuBarAccessibilityIncludesBothServicesAndResetCredits() throws {
        let config = ProviderMenuBarDisplayConfig(
            kind: .claude, showIcon: false, style: .batteryBar, percentageDisplay: .none,
            showBatteryPercent: false, resetTimeDisplay: .none, timeFormat: .h24,
            circularDisplayMode: .usage, iconMetric: .fiveHour)
        let claude = MenuBarStatusComposer.claudeSnapshot(
            config: config, usage: .init(fiveHour: .init(utilization: 42, resetsAt: nil), sevenDay: nil),
            error: nil, hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor,
            icon: nil, renderImages: false
        ).withResetCreditBadge(.init(count: 2, tone: .new))
        let codex = MenuBarStatusComposer.codexSnapshot(
            config: .init(
                kind: .codex, showIcon: false, style: .batteryBar, percentageDisplay: .none,
                showBatteryPercent: false, resetTimeDisplay: .none, timeFormat: .h24,
                circularDisplayMode: .usage, iconMetric: .fiveHour),
            usage: try codex("b@example.com", workspace: "team").usage,
            error: nil, hasAuthError: false, isAuthenticated: true,
            secondaryColor: .secondaryLabelColor, icon: nil, renderImages: false)
        let content = MenuBarStatusComposer.multipleProviderContent(
            snapshots: [claude, codex], secondaryColor: .secondaryLabelColor,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertTrue(content.accessibilityLabel?.contains("Claude") == true)
        XCTAssertTrue(content.accessibilityLabel?.contains("Codex") == true)
        XCTAssertTrue(content.accessibilityValue?.contains("42%") == true)
        XCTAssertTrue(content.accessibilityValue?.contains("신규 초기화권 2개") == true)
        XCTAssertNotNil(codex.accessibilityValue)
    }

    func testAntigravityTypedQuotaDrivesLowLimitRefreshAndResetFollowUp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(300)
        let quota = AntigravityQuotaSnapshot(
            identity: nil, plan: nil,
            lanes: [
                .init(
                    id: .geminiWeekly, upstreamGroupID: "gemini", upstreamBucketID: "weekly",
                    scope: .gemini, cadence: .weekly, remainingFraction: 0.05,
                    resetAt: reset, resetDescription: nil, availability: .available)
            ], decodeIssues: [],
            provenance: .init(
                transport: .cliUsageReport, endpointOwner: .managed,
                accountIdentity: nil, capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        for state in [
            AntigravityPresentationState.ready(quota), .partial(quota, issues: []), .refreshing(previous: quota),
        ] {
            let snapshot = AntigravityRuntimeSnapshot(
                readiness: .ready, settings: nil, presentationState: state,
                quotaPresentation: .unavailable(.disabled),
                managedRuntimeAvailability: .unavailable(reason: .executableNotFound),
                lastAttemptAt: now, lastSuccessfulAt: now)
            XCTAssertEqual(snapshot.adaptiveUsageLimits.first?.usedPercentage, 95)
            XCTAssertEqual(
                AdaptiveRefreshPolicy.interval(
                    .init(
                        now: now, isPopoverOpen: false, lastPopoverOpenedAt: nil, lastActivityAt: nil,
                        hasLowRemainingLimit: snapshot.adaptiveUsageLimits.contains { ($0.usedPercentage ?? 0) >= 90 })),
                120)
            XCTAssertEqual(
                AdaptiveRefreshPolicy.nextResetFollowUp(
                    resetDates: snapshot.adaptiveUsageLimits.compactMap(\.resetAt), now: now),
                reset.addingTimeInterval(5))
        }
    }
}

extension RuntimeOwnershipReviewTests {
    func testClaudeWebIdentityMustMatchLoginReferenceAndResolvedOrganization() {
        let known = UsageAccountIdentity(accountID: "user", organizationID: "team", email: "a@example.com")
        let provenance = ClaudeFetchProvenance(source: .webSession, accountID: "web-a", attemptedSources: [.webSession])
        let matched = ClaudeUsageAccountProvider.runtimeAccount(
            provenance: provenance, validatedIdentity: nil, resolvedOrganizationID: "team",
            knownIdentities: ["web-a": known])
        XCTAssertEqual(matched?.identity.mergeKey, "user|team")
        let changedOrganization = ClaudeUsageAccountProvider.runtimeAccount(
            provenance: provenance, validatedIdentity: nil, resolvedOrganizationID: "other",
            knownIdentities: ["web-a": known])
        XCTAssertNil(changedOrganization?.identity.mergeKey)
        let changedLogin = ClaudeUsageAccountProvider.runtimeAccount(
            provenance: .init(source: .webSession, accountID: "web-b", attemptedSources: [.webSession]),
            validatedIdentity: nil, resolvedOrganizationID: "team", knownIdentities: ["web-a": known])
        XCTAssertNil(changedLogin?.identity.mergeKey)
    }

    func testOrganizationPreviewKeepsCurrencyAndMinorUnitPrecision() {
        let overage = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 2000, usedCreditsCents: 1150, isEnabled: true,
            outOfCredits: false, currency: "KWD", decimalPlaces: 3)
        let preview = ClaudeAPIService.OrganizationPreview(
            organization: .init(id: "team", name: "Team"), fiveHourPercentage: nil,
            weeklyPercentage: nil, overage: overage, usageErrorMessage: nil)
        XCTAssertEqual(preview.overage?.currency, "KWD")
        XCTAssertEqual(preview.overage?.usedCredits, 1.15)
        XCTAssertEqual(preview.overage?.formattedUsedCredits, overage.formattedUsedCredits)
        XCTAssertFalse(preview.overage?.formattedUsedCredits.contains("$") == true)
        XCTAssertEqual(preview.overage?.decimalPlaces, 3)
    }
}

extension RuntimeOwnershipReviewTests {
    func testRecoverableAndDefinitiveFailureBothMarkRetainedRuntimeQuotaAsPreviousData() {
        for error in [APIError.networkError("fixture"), .parseError] {
            let snapshot = RuntimeProviderSnapshot(
                service: .claude,
                payload: .claude(.init(fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil)),
                error: error, lastUpdated: Date(), credentialState: .usable,
                isDetected: true, canAttemptRefresh: true, hasAuthError: false)
            XCTAssertEqual(snapshot.freshness, .stale)
            XCTAssertEqual(snapshot.accountRowStatus(hasUsage: true), .stale)
            XCTAssertEqual(snapshot.claudeUsage?.fiveHour?.utilization, 20)
            let row = PopoverAccountRowData(
                id: "runtime", service: .claude, name: "fixture", badges: [],
                status: snapshot.accountRowStatus(hasUsage: true),
                usage: .init(fiveHour: .init(usedPercent: 20, resetsAt: nil)), fetchedAt: snapshot.lastUpdated,
                isRuntime: true, basis: .used)
            XCTAssertNotEqual(
                MultiAccountPresentation(
                    service: .claude, mode: .summaryRows, rows: [row], selectedIDs: []
                ).summary.text, "모든 계정 여유 있음")
        }
    }
}

extension RuntimeOwnershipReviewTests {
    func testVerifiedWebSessionUsesSameRecordOwnerForResetAndAlertsBeforeCloudUUIDIsKnown() {
        let metadata = fixtureClaudeMetadata(accountID: "web-session", organizationID: "team")
        XCTAssertEqual(metadata.resetCreditAccountKey(for: .claude), "claude:web:web-session|team")
        XCTAssertEqual(metadata.notificationAccountKey(for: .claude), metadata.resetCreditAccountKey(for: .claude))
        let known = RuntimeProviderFetchMetadata(
            accountID: "web-session",
            account: .init(
                source: .init(role: .web, reference: "web-session"),
                identity: .init(accountID: "user", organizationID: "team")))
        XCTAssertEqual(known.resetCreditAccountKey(for: .claude), "claude:user|team")
        XCTAssertEqual(
            known.supplementalAccountKey, metadata.supplementalAccountKey,
            "UUID가 확인돼도 같은 세션/조직의 돈 이력과 주기는 유지합니다")
    }
}
