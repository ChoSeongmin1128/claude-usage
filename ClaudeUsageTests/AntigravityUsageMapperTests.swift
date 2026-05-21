import XCTest
@testable import ClaudeUsage

final class AntigravityUsageMapperTests: XCTestCase {
    func testBuildResponseKeepsRepresentativeCodingModelsAndSkipsAutocompleteOrLiteQuotas() {
        let response = AntigravityUsageMapper.buildResponse(
            quotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet",
                    modelID: "claude-sonnet-4.5",
                    remainingFraction: 0.4,
                    resetAtISO: "2026-05-20T20:00:00Z"
                ),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro Autocomplete",
                    modelID: "gemini-2.5-pro-autocomplete",
                    remainingFraction: 0.1,
                    resetAtISO: nil
                ),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelID: "gemini-2.5-pro",
                    remainingFraction: 0.9,
                    resetAtISO: nil
                ),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Lite",
                    modelID: "gemini-2.5-flash-lite",
                    remainingFraction: 0,
                    resetAtISO: nil
                ),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash",
                    modelID: "gemini-2.5-flash",
                    remainingFraction: 0.8,
                    resetAtISO: nil
                ),
            ],
            accountEmail: "nathan@example.com",
            accountPlan: "Paid",
            source: .googleOAuth
        )

        XCTAssertEqual(response.source, .googleOAuth)
        XCTAssertEqual(response.accountEmail, "nathan@example.com")
        XCTAssertEqual(response.primaryWindow?.label, "Claude")
        XCTAssertEqual(response.primaryPercentage, 60, accuracy: 0.001)
        XCTAssertEqual(response.secondaryWindow?.modelID, "gemini-2.5-pro")
        XCTAssertEqual(response.secondaryWindow?.label, "Gemini Pro")
        XCTAssertEqual(response.tertiaryWindow?.modelID, "gemini-2.5-flash")
        XCTAssertEqual(response.tertiaryWindow?.label, "Gemini Flash")
    }

    func testBuildResponseDoesNotInventUsageWhenRemainingFractionIsMissing() {
        let response = AntigravityUsageMapper.buildResponse(
            quotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet",
                    modelID: "claude-sonnet-4.5",
                    remainingFraction: nil,
                    resetAtISO: "2026-05-20T20:00:00Z"
                ),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelID: "gemini-2.5-pro",
                    remainingFraction: nil,
                    resetAtISO: nil
                ),
            ],
            accountEmail: "nathan@example.com",
            accountPlan: "Paid",
            source: .googleOAuth
        )

        XCTAssertFalse(response.hasUsageWindows)
        XCTAssertEqual(response.primaryPercentage, 0)
        XCTAssertEqual(response.accountEmail, "nathan@example.com")
    }

    func testBuildResponseFallsBackToUsableUnknownQuotaWhenKnownFamilyHasNoUsageValue() {
        let response = AntigravityUsageMapper.buildResponse(
            quotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet",
                    modelID: "claude-sonnet-4.5",
                    remainingFraction: nil,
                    resetAtISO: nil
                ),
                AntigravityModelQuota(
                    label: "General Agent Quota",
                    modelID: "agent-quota",
                    remainingFraction: 0.25,
                    resetAtISO: nil
                ),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .localIDE
        )

        XCTAssertEqual(response.primaryWindow?.label, "General Agent Quota")
        XCTAssertEqual(response.primaryPercentage, 75, accuracy: 0.001)
    }
}
