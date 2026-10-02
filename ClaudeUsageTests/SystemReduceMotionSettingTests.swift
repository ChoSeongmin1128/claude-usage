import XCTest
@testable import ClaudeUsage

final class SystemReduceMotionSettingTests: XCTestCase {
    func testMotionPaneMovedInMacOS26() {
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

        XCTAssertEqual(SystemReduceMotionSetting.location(for: sequoia), "손쉬운 사용 > 디스플레이")
        XCTAssertEqual(
            SystemReduceMotionSetting.url(for: sequoia)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")
        XCTAssertEqual(SystemReduceMotionSetting.location(for: tahoe), "손쉬운 사용 > 동작")
        XCTAssertEqual(
            SystemReduceMotionSetting.url(for: tahoe)?.absoluteString,
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Motion")
    }
}
