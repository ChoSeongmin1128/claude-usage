import XCTest
@testable import ClaudeUsage

/// CodexStatusProbe.parse — codex `/status` 텍스트 응답에서 사용량 필드 추출.
/// 실제 PTY 호출은 환경 의존성이 커서 텍스트 → 모델 매핑만 회귀 방지.
final class CodexStatusProbeTests: XCTestCase {
    func testParsesCreditsAndBothWindows() throws {
        let text = """
        Codex
        Credits: 24.50
        5h limit (37% left, resets 15:30)
        Weekly limit (62% left, resets 13:14 on 17 May)
        """

        let snapshot = try CodexStatusProbe.parse(text: text)

        XCTAssertEqual(snapshot.credits, 24.50)
        XCTAssertEqual(snapshot.fiveHourPercentLeft, 37)
        XCTAssertEqual(snapshot.weeklyPercentLeft, 62)
        XCTAssertNotNil(snapshot.fiveHourResetDescription)
        // 라인 끝 ')' 가 그대로 남는다 — 닫는 괄호 제거는 mapper 의 parseResetUnixTimestamp 가 처리.
        XCTAssertEqual(snapshot.weeklyResetDescription, "13:14 on 17 May)")
    }

    func testParsesEvenWithANSIColors() throws {
        // ESC[31m ... ESC[0m 같은 ANSI escape 가 섞여 있어도 stripANSICodes 후 정상 파싱.
        let text = "\u{001B}[1mCredits:\u{001B}[0m 12.0\n\u{001B}[32m5h limit\u{001B}[0m (50% left, resets 09:00)"
        let snapshot = try CodexStatusProbe.parse(text: text)
        XCTAssertEqual(snapshot.credits, 12.0)
        XCTAssertEqual(snapshot.fiveHourPercentLeft, 50)
    }

    func testEmptyTextThrowsParseFailed() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: ""))
    }

    func testDataNotAvailableYetThrowsParseFailed() {
        let text = "Data not available yet, try again shortly."
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: text)) { error in
            guard case CodexStatusProbeError.parseFailed = error else {
                XCTFail("Expected parseFailed, got \(error)")
                return
            }
        }
    }

    func testTextWithNoKnownFieldsThrowsParseFailed() {
        let text = "Welcome to Codex 0.130.0\nType /help for commands"
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: text)) { error in
            guard case CodexStatusProbeError.parseFailed = error else {
                XCTFail("Expected parseFailed, got \(error)")
                return
            }
        }
    }

    func testCLIStatusMapperConvertsPercentLeftToUsedPercent() {
        let snapshot = CodexCLIStatusSnapshot(
            credits: 10.0,
            fiveHourPercentLeft: 30,
            weeklyPercentLeft: 80,
            fiveHourResetDescription: nil,
            weeklyResetDescription: nil,
            rawText: ""
        )

        let response = CodexCLIStatusMapper.mapToUsageResponse(snapshot)

        // 30% left → 70% used
        XCTAssertEqual(response.rateLimit?.primaryWindow?.usedPercent, 70)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.usedPercent, 20)
        XCTAssertEqual(response.credits?.balance, 10.0)
        XCTAssertEqual(response.credits?.hasCredits, true)
        XCTAssertEqual(response.rateLimit?.primaryWindow?.limitWindowSeconds, 5 * 3600)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.limitWindowSeconds, 7 * 24 * 3600)
    }
}
