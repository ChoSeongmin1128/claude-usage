import XCTest
@testable import ClaudeUsage

final class AppInstallLocationPolicyTests: XCTestCase {
    private let homeDirectory = "/Users/tester"

    func testSystemAndUserApplicationsAreStable() {
        for (path, expectedKind) in [
            ("/Applications/ClaudeUsage.app", AppInstallLocationKind.applications),
            ("/Users/tester/Applications/ClaudeUsage.app", .userApplications),
        ] {
            let assessment = AppInstallLocationPolicy.assess(
                bundlePath: path,
                homeDirectory: homeDirectory
            )
            XCTAssertEqual(assessment.kind, expectedKind)
            XCTAssertTrue(assessment.isStableInstall)
            XCTAssertFalse(AppInstallGuidancePolicy.shouldShow(assessment: assessment, isDeveloperBuild: false))
        }
    }

    func testUnstableLocationsShowGuidanceInReleaseBuilds() {
        for (path, expectedKind) in [
            ("/Volumes/Install ClaudeUsage/ClaudeUsage.app", AppInstallLocationKind.diskImageVolume),
            ("/private/var/folders/x/AppTranslocation/ClaudeUsage.app", .appTranslocation),
            ("/private/var/folders/x/ClaudeUsage.app", .temporary),
            ("/Users/tester/Downloads/ClaudeUsage.app", .downloads),
            ("/Users/tester/Desktop/ClaudeUsage.app", .other),
        ] {
            let assessment = AppInstallLocationPolicy.assess(
                bundlePath: path,
                homeDirectory: homeDirectory
            )
            XCTAssertEqual(assessment.kind, expectedKind)
            XCTAssertFalse(assessment.isStableInstall)
            XCTAssertTrue(AppInstallGuidancePolicy.shouldShow(assessment: assessment, isDeveloperBuild: false))
            XCTAssertFalse(AppInstallGuidancePolicy.shouldShow(assessment: assessment, isDeveloperBuild: true))
            XCTAssertFalse(assessment.locationDescription.contains(path))
        }
    }

    func testApplicationsPrefixDoesNotMatchAnotherFolderName() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Applications-old/ClaudeUsage.app",
            homeDirectory: homeDirectory
        )
        XCTAssertEqual(assessment.kind, .other)
        XCTAssertTrue(AppInstallGuidancePolicy.shouldShow(assessment: assessment, isDeveloperBuild: false))
    }
}
