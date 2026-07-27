import XCTest
@testable import ClaudeUsage

final class AntigravityManagedCLIOutputClassifierTests: XCTestCase {
    func testFragmentedANSIStyledLoginPromptIsClassifiedOnce() {
        var classifier = AntigravityManagedCLIOutputClassifier()

        XCTAssertEqual(
            classifier.ingest(Data("\u{1B}[38;5;208mSelect log".utf8)),
            []
        )
        XCTAssertEqual(
            classifier.ingest(Data("in\u{1B}[0m method:\r\n".utf8)),
            [.loginRequired]
        )
        XCTAssertEqual(classifier.interactions, [.loginRequired])
        XCTAssertEqual(
            classifier.ingest(Data("Select login method:".utf8)),
            []
        )
    }

    func testTransientSignedOutStatusAndGeneralURLAreNotBlockingPrompts() {
        var classifier = AntigravityManagedCLIOutputClassifier()
        let output = """
        You are currently not signed in. Refreshing cached credentials…
        Documentation: https://developers.google.com/gemini
        Local server: https://127.0.0.1:43123
        For help, open the following URL in your browser:
        https://example.invalid/docs
        """

        XCTAssertEqual(classifier.ingest(Data(output.utf8)), [])
        XCTAssertTrue(classifier.interactions.isEmpty)
    }

    func testProjectTrustAndBrowserAuthenticationPromptsAreTyped() {
        var classifier = AntigravityManagedCLIOutputClassifier()

        XCTAssertEqual(
            classifier.ingest(
                Data("Do you trust the authors of the files in this folder?".utf8)
            ),
            [.projectTrustRequired]
        )
        XCTAssertEqual(
            classifier.ingest(
                Data(
                    "Open the following URL in your browser to authenticate:\nhttps://example.invalid/secret".utf8
                )
            ),
            [.browserAuthenticationRequired]
        )
        XCTAssertEqual(
            classifier.interactions,
            [.projectTrustRequired, .browserAuthenticationRequired]
        )
    }

    func testGeneralBrowserDocumentationInstructionIsNotAuthentication() {
        var classifier = AntigravityManagedCLIOutputClassifier()

        XCTAssertEqual(
            classifier.ingest(
                Data(
                    "For troubleshooting, open the following URL in your browser:\nhttps://example.invalid/docs".utf8
                )
            ),
            []
        )
    }

    func testOSCContentIsDiscardedBeforeClassification() {
        var classifier = AntigravityManagedCLIOutputClassifier()
        var output = Data("\u{1B}]0;Open your browser to authenticate".utf8)
        output.append(0x07)
        output.append(Data("AGY is starting normally".utf8))

        XCTAssertEqual(classifier.ingest(output), [])
        XCTAssertTrue(classifier.interactions.isEmpty)
    }

    func testRollingWindowDoesNotRetainEvictedPromptFragment() {
        var classifier = AntigravityManagedCLIOutputClassifier()

        XCTAssertEqual(classifier.ingest(Data("Select login ".utf8)), [])
        XCTAssertEqual(
            classifier.ingest(
                Data(
                    repeating: Character("x").asciiValue!,
                    count: AntigravityManagedCLIOutputClassifier.maximumBufferedBytes
                )
            ),
            []
        )
        XCTAssertEqual(classifier.ingest(Data("method:".utf8)), [])
        XCTAssertTrue(classifier.interactions.isEmpty)
        XCTAssertTrue(classifier.outputWasTruncated)
    }
}
