import XCTest
@testable import ClaudeUsage

/// v2.1.1 → 다음 버전 업데이트 사각지대 대응으로 추가한 OAuth-aware
/// 자동 복구 정책 (`shouldAutoSwitchActiveToCLIForBrokenLegacyMigration`)의
/// 결정 룰을 회귀 방지로 고정한다.
///
/// 핵심 원칙:
///   • 사용자가 직접 선택/추가한 web 계정(chromeProfile, embeddedWebLogin,
///     manualInput) 은 절대 자동 전환하지 않는다 (의도 존중).
///   • 레거시 자동 마이그레이션 결과(`source == .legacyMigration`) 이면서
///     실제로 동작 불가(sessionKey 손상 또는 직전 검증 실패) 인 경우에만 전환.
///   • OAuth credential 이 없으면 전환할 곳이 없으므로 항상 false.
final class ClaudeAPIServiceOAuthAwareMigrationTests: XCTestCase {
    func testTrueWhenLegacyMigrationWebHasMissingSessionKeyAndOAuthAvailable() {
        let active = makeWeb(source: .legacyMigration, validation: .verified)

        let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
            activeAccount: active,
            oauthCredentialAvailable: true,
            sessionKeyMissing: true
        )

        XCTAssertTrue(result, "sessionKey 가 빠진 레거시 web 은 OAuth 가 있으면 자동 전환 대상")
    }

    func testTrueWhenLegacyMigrationWebLastValidationFailedAndOAuthAvailable() {
        let active = makeWeb(source: .legacyMigration, validation: .failed)

        let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
            activeAccount: active,
            oauthCredentialAvailable: true,
            sessionKeyMissing: false
        )

        XCTAssertTrue(result, "sessionKey 가 있어도 직전 검증이 .failed 면 OAuth 로 전환")
    }

    func testFalseWhenLegacyMigrationWebStillVerified() {
        // 레거시 web 이지만 현재 정상 동작 중이면 사용자가 그 자격으로 사용량을 잘 보고 있을 가능성.
        // 이 시점에 자동 전환은 오히려 사용자를 놀라게 한다 → false.
        let active = makeWeb(source: .legacyMigration, validation: .verified)

        let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
            activeAccount: active,
            oauthCredentialAvailable: true,
            sessionKeyMissing: false
        )

        XCTAssertFalse(result)
    }

    func testFalseWhenWebSessionExplicitlySelectedEvenIfBroken() {
        // Chrome 자동 가져오기로 추가됐든 사용자가 직접 입력했든, 사용자가 명시 의도를
        // 가진 계정은 자동 전환하지 않는다. 사용자가 직접 설정 UI 에서 CLI 로 전환해야 함.
        for source in [ClaudeAccountSource.chromeProfile, .embeddedWebLogin, .manualInput] {
            let active = makeWeb(source: source, validation: .failed)
            let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
                activeAccount: active,
                oauthCredentialAvailable: true,
                sessionKeyMissing: true
            )
            XCTAssertFalse(result, "명시 선택 web(\(source.rawValue)) 은 손상되어도 전환 안 됨")
        }
    }

    func testFalseWhenOAuthCredentialUnavailable() {
        // OAuth 토큰이 없으면 전환할 대상 자체가 없으므로 false.
        let active = makeWeb(source: .legacyMigration, validation: .failed)

        let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
            activeAccount: active,
            oauthCredentialAvailable: false,
            sessionKeyMissing: true
        )

        XCTAssertFalse(result)
    }

    func testFalseWhenActiveIsAlreadyClaudeCodeExternal() {
        // 이미 CLI 활성이면 전환 불필요.
        let active = ClaudeAccount(
            id: ClaudeAccountStore.claudeCodeExternalAccountID,
            kind: .claudeCodeExternal,
            displayName: "Claude Code 계정",
            source: .claudeCodeCLI
        )

        let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
            activeAccount: active,
            oauthCredentialAvailable: true,
            sessionKeyMissing: true
        )

        XCTAssertFalse(result)
    }

    func testFalseWhenNoActiveAccount() {
        // 활성 계정 자체가 없으면 (계정 미설정) → 다른 흐름이 setActiveIfMissing 로 처리.
        // 이 케이스는 자동 전환 룰의 책임 영역 밖이므로 false.
        let result = ClaudeAPIService.shouldAutoSwitchActiveToCLIForBrokenLegacyMigration(
            activeAccount: nil,
            oauthCredentialAvailable: true,
            sessionKeyMissing: true
        )

        XCTAssertFalse(result)
    }

    // MARK: - Helpers

    private func makeWeb(
        source: ClaudeAccountSource,
        validation: ClaudeCredentialValidationState
    ) -> ClaudeAccount {
        ClaudeAccount(
            id: "web-test-fingerprint",
            kind: .webSession,
            displayName: "브라우저 계정",
            source: source,
            lastValidationState: validation
        )
    }
}
