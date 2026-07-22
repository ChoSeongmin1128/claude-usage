import XCTest
@testable import ClaudeUsage

/// Claude limits[] 스코프 한도 / Codex 초기화 크레딧 등
/// 2026-07 API 변경분에 대한 디코딩·매핑 테스트.
final class UsageModelsDecodingTests: XCTestCase {
    // MARK: - Claude limits[] (모델 스코프 주간 한도)

    func testClaudeUsageDecodesScopedWeeklyLimits() throws {
        let json = """
        {
          "five_hour": { "utilization": 12, "resets_at": "2026-07-22T10:00:00Z" },
          "seven_day": { "utilization": 40, "resets_at": "2026-07-28T00:00:00Z" },
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 27,
              "resets_at": "2026-07-28T00:00:00Z",
              "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } }
            },
            {
              "kind": "weekly_scoped",
              "percent": 90,
              "scope": { "model": { "id": "all-models", "display_name": "All models" } }
            },
            "malformed-entry",
            { "kind": "something_else", "percent": 5 }
          ]
        }
        """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))

        XCTAssertEqual(usage.scopedLimits.count, 3)

        let windows = usage.modelWeeklyWindows
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.slug, "claude-fable-5")
        XCTAssertEqual(windows.first?.modelName, "Fable")
        XCTAssertEqual(windows.first?.utilization, 27)
        XCTAssertEqual(windows.first?.resetsAt, "2026-07-28T00:00:00Z")
    }

    func testClaudeUsageWithoutLimitsArrayStillDecodes() throws {
        let json = """
        { "five_hour": { "utilization": 3, "resets_at": null } }
        """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        XCTAssertTrue(usage.scopedLimits.isEmpty)
        XCTAssertTrue(usage.modelWeeklyWindows.isEmpty)
    }

    func testModelWeeklyWindowsMergesLegacyFieldsWithoutDuplication() {
        // 신형 limits 에 Sonnet 이 있으면 레거시 seven_day_sonnet 은 중복 추가하지 않는다.
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 10, resetsAt: nil),
            sevenDay: nil,
            sevenDaySonnet: UsageWindow(utilization: 61, resetsAt: nil),
            sevenDayOpus: UsageWindow(utilization: 33, resetsAt: nil),
            scopedLimits: [
                ClaudeScopedLimit(kind: "weekly_scoped", percent: 55, modelID: "claude-sonnet-4-5", modelName: "Sonnet"),
                ClaudeScopedLimit(kind: "weekly_scoped", percent: 27, modelName: "Fable"),
            ]
        )

        let windows = usage.modelWeeklyWindows
        XCTAssertEqual(windows.map(\.slug), ["claude-sonnet-4-5", "fable", "opus"])
        XCTAssertEqual(windows.map(\.utilization), [55, 27, 33])
    }

    func testModelWeeklyWindowsFallsBackToLegacyFieldsOnly() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 10, resetsAt: nil),
            sevenDay: nil,
            sevenDaySonnet: UsageWindow(utilization: 61, resetsAt: nil),
            sevenDayOpus: UsageWindow(utilization: 33, resetsAt: nil)
        )

        let windows = usage.modelWeeklyWindows
        XCTAssertEqual(windows.map(\.slug), ["sonnet", "opus"])
        XCTAssertEqual(windows.map(\.modelName), ["Sonnet", "Opus"])
    }

    // MARK: - Codex 주간 전용 응답

    /// 2026-07 실제 응답: 주간(604800초) 창이 primary_window 자리에 오고 secondary 는 null.
    /// 위치가 아니라 창 길이로 세션/주간을 분류해야 한다.
    func testCodexWeeklyAsPrimaryResponseClassifiesAsWeekly() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 12,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 571302,
              "reset_at": 1785283490
            },
            "secondary_window": null
          }
        }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))

        XCTAssertNil(usage.sessionWindow)
        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertEqual(usage.weeklyWindow?.utilization, 12)
        XCTAssertEqual(usage.gaugePercentage, 12)
        XCTAssertEqual(usage.usageSummaryText, "주간 12%")
    }

    /// 레거시 형태(5시간 primary + 주간 secondary)도 계속 올바르게 분류돼야 한다.
    func testCodexLegacyDualWindowResponseKeepsSessionAndWeekly() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 4, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 63, "limit_window_seconds": 604800 }
          }
        }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))

        XCTAssertEqual(usage.sessionWindow?.utilization, 4)
        XCTAssertEqual(usage.weeklyWindow?.utilization, 63)
        XCTAssertEqual(usage.usageSummaryText, "현재 4% · 주간 63%")
    }

    func testCodexAdditionalRateLimitsDecoding() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 12, "limit_window_seconds": 604800 },
            "secondary_window": null
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": { "used_percent": 7, "limit_window_seconds": 604800, "reset_at": 1785316988 },
                "secondary_window": null
              }
            },
            "malformed"
          ]
        }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))

        XCTAssertEqual(usage.additionalRateLimits.count, 1)
        let spark = try XCTUnwrap(usage.additionalRateLimits.first)
        XCTAssertEqual(spark.limitName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(spark.window?.utilization, 7)
        XCTAssertEqual(spark.window?.windowDescription, "주간")
    }

    func testCodexWindowAdaptiveTitleFollowsWindowSeconds() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 5, "limit_window_seconds": 604800 },
            "secondary_window": { "used_percent": 40, "limit_window_seconds": 2592000 }
          }
        }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))

        let primary = try XCTUnwrap(usage.rateLimit?.primaryWindow)
        let secondary = try XCTUnwrap(usage.rateLimit?.secondaryWindow)

        // primary 가 5시간이 아니라 주간이면 라벨이 따라간다
        XCTAssertEqual(primary.adaptiveTitle(expectedSeconds: 5 * 3600, fallback: "현재 세션"), "주간 한도")
        // secondary 가 7일이 아니라 30일이면 실제 창 길이를 노출
        XCTAssertEqual(secondary.adaptiveTitle(expectedSeconds: 7 * 24 * 3600, fallback: "주간 한도"), "30일 한도")
        // 기대값과 같으면 fallback 유지
        XCTAssertEqual(primary.adaptiveTitle(expectedSeconds: 604800, fallback: "주간 한도"), "주간 한도")
    }

    // MARK: - Codex rate limit reset credits

    func testCodexResetCreditsDecodingAndAvailability() throws {
        let now = Date(timeIntervalSince1970: 1_753_000_000)
        let json = """
        {
          "available_count": 2,
          "credits": [
            {
              "id": "credit-1",
              "reset_type": "weekly",
              "status": "available",
              "granted_at": 1752900000,
              "expires_at": 1753100000
            },
            {
              "id": "credit-2",
              "reset_type": "weekly",
              "status": "available",
              "granted_at": 1752900000000,
              "expires_at": 1753200000000
            },
            {
              "id": "credit-3",
              "status": "redeemed",
              "granted_at": "2026-07-01T00:00:00Z"
            },
            "malformed"
          ]
        }
        """
        let response = try JSONDecoder().decode(CodexResetCreditsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.credits.count, 3)
        XCTAssertEqual(response.availableCount(at: now), 2)

        let available = response.availableCredits(at: now)
        XCTAssertEqual(available.map(\.id), ["credit-1", "credit-2"])
        XCTAssertEqual(response.nextExpiringAvailable(at: now)?.id, "credit-1")

        // 밀리초 timestamp 도 초로 정규화되어야 한다
        let msCredit = try XCTUnwrap(response.credits.first { $0.id == "credit-2" })
        let msExpires = try XCTUnwrap(msCredit.expiresDate)
        XCTAssertEqual(msExpires.timeIntervalSince1970, 1_753_200_000, accuracy: 1)
    }

    func testCodexResetCreditsCountFallsBackToComputedWhenFieldMissing() throws {
        let json = """
        {
          "credits": [
            { "id": "a", "status": "available" },
            { "id": "b", "status": "expired" }
          ]
        }
        """
        let response = try JSONDecoder().decode(CodexResetCreditsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.availableCount(), 1)
    }
}
