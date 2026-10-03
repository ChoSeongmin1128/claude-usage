import XCTest
@testable import ClaudeUsage

final class AntigravityUsageSourceTests: XCTestCase {
    func testLocalEndpointFailurePolicyHasExplicitStableSeverity() {
        let ascending: [AntigravityUsageSourceError] = [
            .unavailable,
            .transportFailure,
            .deadlineExceeded,
            .malformedResponse,
            .reportFailed,
            .runtimeUnavailable(.executableMissing),
            .interactionRequired,
            .authenticationRequired,
            .cancelled,
        ]

        for (lower, higher) in zip(
            ascending,
            ascending.dropFirst()
        ) {
            XCTAssertEqual(
                AntigravityUsageSourceFailurePolicy.preferred(
                    lower,
                    higher
                ),
                higher
            )
            XCTAssertEqual(
                AntigravityUsageSourceFailurePolicy.preferred(
                    higher,
                    lower
                ),
                higher
            )
        }
    }
}

