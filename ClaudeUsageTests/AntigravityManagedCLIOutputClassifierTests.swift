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
        XCTAssertEqual(
            classifier.announcedLocalServerPort,
            AntigravityTCPPort(43_123)
        )
    }

    func testFragmentedANSIStyledLocalServerPortIsRecovered()
    {
        var classifier =
            AntigravityManagedCLIOutputClassifier()

        _ = classifier.ingest(
            Data(
                "\u{1B}[36mLocal server: https://127.0.0.1:"
                    .utf8
            )
        )
        XCTAssertNil(
            classifier.announcedLocalServerPort
        )

        _ = classifier.ingest(
            Data("55169\u{1B}[0m\r\n".utf8)
        )

        XCTAssertEqual(
            classifier.announcedLocalServerPort,
            AntigravityTCPPort(55_169)
        )
    }

    func testAGYHTTPSBootstrapLogSelectsHTTPSAndIgnoresHTTP()
    {
        var classifier =
            AntigravityManagedCLIOutputClassifier()
        let output = """
        I0730 18:29:34.034547 59191 server.go:560] Language server listening on random port at 59764 for HTTPS (gRPC)
        I0730 18:29:34.034787 59191 server.go:568] Language server listening on random port at 59765 for HTTP
        """

        XCTAssertEqual(
            classifier.ingest(Data(output.utf8)),
            []
        )
        XCTAssertEqual(
            classifier.announcedLocalServerPort,
            AntigravityTCPPort(59_764)
        )
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
