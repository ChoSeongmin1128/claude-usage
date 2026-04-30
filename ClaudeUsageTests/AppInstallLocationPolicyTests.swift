import XCTest
@testable import ClaudeUsage

final class AppInstallLocationPolicyTests: XCTestCase {
    func testApplicationsPathsAreStable() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Applications/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .applications)
        XCTAssertTrue(assessment.isStableInstall)
        XCTAssertFalse(assessment.requiresMovePrompt)
    }

    func testUserApplicationsPathIsStable() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Users/tester/Applications/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .userApplications)
        XCTAssertTrue(assessment.isStableInstall)
    }

    func testDiskImagePathRequiresMovePrompt() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Volumes/ClaudeUsage/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .diskImageVolume)
        XCTAssertTrue(assessment.requiresMovePrompt)
    }

    func testTranslocationPathRequiresMovePrompt() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/private/var/folders/x/AppTranslocation/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .appTranslocation)
        XCTAssertTrue(assessment.requiresMovePrompt)
    }

    func testDownloadsPathRequiresMovePrompt() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Users/tester/Downloads/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .downloads)
        XCTAssertTrue(assessment.requiresMovePrompt)
    }

    func testUnstableLocationDescriptionsDoNotExposeRawPaths() {
        let assessments = [
            AppInstallLocationPolicy.assess(bundlePath: "/Volumes/ClaudeUsage/ClaudeUsage.app", homeDirectory: "/Users/tester"),
            AppInstallLocationPolicy.assess(bundlePath: "/private/var/folders/x/AppTranslocation/ClaudeUsage.app", homeDirectory: "/Users/tester"),
            AppInstallLocationPolicy.assess(bundlePath: "/Users/tester/Downloads/ClaudeUsage.app", homeDirectory: "/Users/tester"),
        ]

        for assessment in assessments {
            XCTAssertTrue(assessment.requiresMovePrompt)
            XCTAssertFalse(assessment.locationDescription.contains("/"))
        }
    }
}
