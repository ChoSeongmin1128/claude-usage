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
        XCTAssertEqual(assessment.preferredTransferStrategy, .copySource)
    }

    func testTranslocationPathRequiresMovePrompt() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/private/var/folders/x/AppTranslocation/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .appTranslocation)
        XCTAssertTrue(assessment.requiresMovePrompt)
        XCTAssertEqual(assessment.preferredTransferStrategy, .copySource)
    }

    func testDownloadsPathRequiresMovePrompt() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Users/tester/Downloads/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .downloads)
        XCTAssertTrue(assessment.requiresMovePrompt)
        XCTAssertEqual(assessment.preferredTransferStrategy, .moveSource)
    }

    func testOtherWritableLocationsMoveSourceInsteadOfLeavingDuplicateApp() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Users/tester/Desktop/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(assessment.kind, .other)
        XCTAssertTrue(assessment.requiresMovePrompt)
        XCTAssertEqual(assessment.preferredTransferStrategy, .moveSource)
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

    func testDiskImageSourceMatchesMountedVolume() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            for: "/Volumes/ClaudeUsage/ClaudeUsage.app",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(
                imagePath: "/Users/tester/Downloads/ClaudeUsage.dmg",
                mountPoint: "/Volumes/ClaudeUsage"
            )
        )

        XCTAssertEqual(
            source,
            AppDiskImageSource(
                imagePath: "/Users/tester/Downloads/ClaudeUsage.dmg",
                mountPoint: "/Volumes/ClaudeUsage"
            )
        )
    }

    func testDiskImageSourceReturnsNilForUnmatchedVolume() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            for: "/Users/tester/Downloads/ClaudeUsage.app",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(
                imagePath: "/Users/tester/Downloads/ClaudeUsage.dmg",
                mountPoint: "/Volumes/ClaudeUsage"
            )
        )

        XCTAssertNil(source)
    }

    func testDiskImageSourceCanMatchMountedAppByBundleIdentifier() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            forAppNamed: "ClaudeUsage.app",
            bundleIdentifier: "com.example.ClaudeUsage",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(
                imagePath: "/Users/tester/Downloads/ClaudeUsage.dmg",
                mountPoint: "/Volumes/ClaudeUsage"
            )
        ) { candidatePath in
            candidatePath == "/Volumes/ClaudeUsage/ClaudeUsage.app"
                ? "com.example.ClaudeUsage"
                : nil
        }

        XCTAssertEqual(
            source,
            AppDiskImageSource(
                imagePath: "/Users/tester/Downloads/ClaudeUsage.dmg",
                mountPoint: "/Volumes/ClaudeUsage"
            )
        )
    }

    func testDiskImageSourceRejectsMountedAppWithDifferentBundleIdentifier() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            forAppNamed: "ClaudeUsage.app",
            bundleIdentifier: "com.example.ClaudeUsage",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(
                imagePath: "/Users/tester/Downloads/ClaudeUsage.dmg",
                mountPoint: "/Volumes/ClaudeUsage"
            )
        ) { _ in
            "com.example.Other"
        }

        XCTAssertNil(source)
    }

    func testDiskImageSourceIgnoresMalformedHdiutilOutput() {
        let source = AppInstallLocationPolicy.diskImageSource(
            for: "/Volumes/ClaudeUsage/ClaudeUsage.app",
            hdiutilInfoPlistData: Data("not plist".utf8)
        )

        XCTAssertNil(source)
    }

    private func makeHdiutilInfoPlistData(
        imagePath: String,
        mountPoint: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "images": [
                [
                    "image-path": imagePath,
                    "system-entities": [
                        ["dev-entry": "/dev/disk4"],
                        [
                            "dev-entry": "/dev/disk4s1",
                            "mount-point": mountPoint,
                        ],
                    ],
                ],
            ],
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
