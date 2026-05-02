import XCTest
@testable import ClaudeUsage

final class ClaudeBrowserAuthModelsTests: XCTestCase {
    func testImportedChromeSessionUsesReadableProfileMetadata() {
        let session = ClaudeBrowserImportedSession(
            profileName: "Profile 2",
            profileDisplayName: "회사",
            accountEmail: "work@example.com",
            sessionKey: "sk-ant-test-session"
        )

        XCTAssertEqual(session.readableProfileName, "회사")
        XCTAssertEqual(session.displayName, "Chrome 회사")
        XCTAssertEqual(session.sourceDetail, "회사 (Profile 2) · work@example.com")
    }

    func testImportedChromeSessionFallsBackFromDirectoryName() {
        let defaultSession = ClaudeBrowserImportedSession(
            profileName: "Default",
            sessionKey: "sk-ant-default"
        )
        let numberedSession = ClaudeBrowserImportedSession(
            profileName: "Profile 3",
            sessionKey: "sk-ant-profile"
        )

        XCTAssertEqual(defaultSession.readableProfileName, "기본 프로필")
        XCTAssertEqual(defaultSession.sourceDetail, "기본 프로필 (Default)")
        XCTAssertEqual(numberedSession.readableProfileName, "프로필 3")
        XCTAssertEqual(numberedSession.sourceDetail, "프로필 3 (Profile 3)")
    }
}
