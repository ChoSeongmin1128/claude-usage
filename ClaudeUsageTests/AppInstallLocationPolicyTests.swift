import XCTest
@testable import ClaudeUsage

@MainActor
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

    func testRunningApplicationPolicySelectsOnlySiblingProcesses() {
        let runningApplications = [
            AppRunningApplicationSnapshot(
                processIdentifier: 100,
                bundleIdentifier: "com.seongmin.ClaudeUsage",
                isTerminated: false
            ),
            AppRunningApplicationSnapshot(
                processIdentifier: 101,
                bundleIdentifier: "com.seongmin.ClaudeUsage",
                isTerminated: false
            ),
            AppRunningApplicationSnapshot(
                processIdentifier: 102,
                bundleIdentifier: "com.example.Other",
                isTerminated: false
            ),
            AppRunningApplicationSnapshot(
                processIdentifier: 103,
                bundleIdentifier: "com.seongmin.ClaudeUsage",
                isTerminated: true
            ),
        ]

        let selected = AppInstallRunningApplicationPolicy.siblingApplicationsToTerminate(
            currentBundleIdentifier: "com.seongmin.ClaudeUsage",
            currentProcessIdentifier: 100,
            runningApplications: runningApplications
        )

        XCTAssertEqual(selected.map(\.processIdentifier), [101])
    }

    func testRunningApplicationPolicyDoesNothingWithoutBundleIdentifier() {
        let selected = AppInstallRunningApplicationPolicy.siblingApplicationsToTerminate(
            currentBundleIdentifier: nil,
            currentProcessIdentifier: 100,
            runningApplications: [
                AppRunningApplicationSnapshot(
                    processIdentifier: 101,
                    bundleIdentifier: "com.seongmin.ClaudeUsage",
                    isTerminated: false
                ),
            ]
        )

        XCTAssertTrue(selected.isEmpty)
    }

    /// 모호함 판정은 이름과 번들 ID가 맞는 후보에만 적용해야 한다. 무관한 이미지가
    /// 같이 붙어 있다고 해서 정리를 포기하면 안 된다.
    func testDiskImageSourceIgnoresUnrelatedMountedImage() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            forAppNamed: "ClaudeUsage.app",
            bundleIdentifier: "com.example.ClaudeUsage",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(images: [
                ("/Users/tester/Downloads/Firefox.dmg", "/Volumes/Firefox"),
                ("/Users/tester/Downloads/ClaudeUsage.dmg", "/Volumes/ClaudeUsage"),
            ])
        ) { candidatePath in
            candidatePath == "/Volumes/ClaudeUsage/ClaudeUsage.app"
                ? "com.example.ClaudeUsage"
                : nil
        }

        XCTAssertEqual(
            source?.imagePath,
            "/Users/tester/Downloads/ClaudeUsage.dmg"
        )
    }

    func testDiskImageSourceSkipsAmbiguousMountedImages() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            forAppNamed: "ClaudeUsage.app",
            bundleIdentifier: "com.example.ClaudeUsage",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(images: [
                ("/Users/tester/Downloads/ClaudeUsage.dmg", "/Volumes/ClaudeUsage"),
                ("/Users/tester/Desktop/ClaudeUsage-old.dmg", "/Volumes/ClaudeUsage 1"),
            ])
        ) { _ in
            "com.example.ClaudeUsage"
        }

        XCTAssertNil(source)
    }

    func testDiskImageSourceAcceptsOneImageMountedTwice() throws {
        let source = AppInstallLocationPolicy.diskImageSource(
            forAppNamed: "ClaudeUsage.app",
            bundleIdentifier: "com.example.ClaudeUsage",
            hdiutilInfoPlistData: try makeHdiutilInfoPlistData(images: [
                ("/Users/tester/Downloads/ClaudeUsage.dmg", "/Volumes/ClaudeUsage"),
                ("/Users/tester/Downloads/ClaudeUsage.dmg", "/Volumes/ClaudeUsage 1"),
            ])
        ) { _ in
            "com.example.ClaudeUsage"
        }

        XCTAssertEqual(
            source?.imagePath,
            "/Users/tester/Downloads/ClaudeUsage.dmg"
        )
    }

    private func makeHdiutilInfoPlistData(
        imagePath: String,
        mountPoint: String
    ) throws -> Data {
        try makeHdiutilInfoPlistData(
            images: [(imagePath, mountPoint)]
        )
    }

    private func makeHdiutilInfoPlistData(
        images: [(imagePath: String, mountPoint: String)]
    ) throws -> Data {
        let plist: [String: Any] = [
            "images": images.enumerated().map { index, image in
                [
                    "image-path": image.imagePath,
                    "system-entities": [
                        ["dev-entry": "/dev/disk\(index + 4)"],
                        [
                            "dev-entry": "/dev/disk\(index + 4)s1",
                            "mount-point": image.mountPoint,
                        ],
                    ],
                ]
            },
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

@MainActor
final class AppInstallMovePromptPolicyTests: XCTestCase {
    private func unstableAssessment() -> AppInstallLocationAssessment {
        AppInstallLocationPolicy.assess(
            bundlePath: "/Users/tester/Downloads/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )
    }

    func testStableLocationNeverPrompts() {
        let assessment = AppInstallLocationPolicy.assess(
            bundlePath: "/Applications/ClaudeUsage.app",
            homeDirectory: "/Users/tester"
        )

        XCTAssertFalse(
            AppInstallMovePromptPolicy.shouldPrompt(
                assessment: assessment,
                isDeveloperBuild: false
            )
        )
    }

    func testUnstableLocationPromptsOnDistributedBuild() {
        XCTAssertTrue(
            AppInstallMovePromptPolicy.shouldPrompt(
                assessment: unstableAssessment(),
                isDeveloperBuild: false
            )
        )
    }

    func testDeveloperBuildIsExemptFromPrompt() {
        XCTAssertFalse(
            AppInstallMovePromptPolicy.shouldPrompt(
                assessment: unstableAssessment(),
                isDeveloperBuild: true
            )
        )
    }

    func testEmptyDestinationMayBeUsed() {
        XCTAssertTrue(
            AppInstallMovePromptPolicy.mayReplace(
                destinationBundleIdentifier: nil,
                destinationExists: false,
                ownBundleIdentifier: "com.seongmin.ClaudeUsage.staging"
            )
        )
    }

    func testSameAppAtDestinationMayBeReplaced() {
        XCTAssertTrue(
            AppInstallMovePromptPolicy.mayReplace(
                destinationBundleIdentifier: "com.seongmin.ClaudeUsage.staging",
                destinationExists: true,
                ownBundleIdentifier: "com.seongmin.ClaudeUsage.staging"
            )
        )
    }

    func testDifferentChannelAtDestinationIsNotReplaced() {
        XCTAssertFalse(
            AppInstallMovePromptPolicy.mayReplace(
                destinationBundleIdentifier: "com.seongmin.ClaudeUsage",
                destinationExists: true,
                ownBundleIdentifier: "com.seongmin.ClaudeUsage.staging"
            )
        )
    }

    func testUnreadableDestinationIsNotReplaced() {
        XCTAssertFalse(
            AppInstallMovePromptPolicy.mayReplace(
                destinationBundleIdentifier: nil,
                destinationExists: true,
                ownBundleIdentifier: "com.seongmin.ClaudeUsage.staging"
            )
        )
    }
}
