import XCTest
@testable import ClaudeUsage

final class AntigravityStatusProbeTests: XCTestCase {
    func testProcessDetectionAcceptsAntigravityTwoUnsuffixedLanguageServer() {
        let command = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --override_ide_name antigravity --override_ide_version 2.0.1 \
        --csrf_token token --app_data_dir antigravity
        """

        XCTAssertTrue(AntigravityStatusProbe.isAntigravityLanguageServerCommand(command))
    }

    func testProcessDetectionAcceptsAntigravityLanguageServerPathsWithSpaces() {
        let command = """
        /Applications/Google Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --override_ide_name antigravity --csrf_token token --app_data_dir antigravity
        """

        XCTAssertTrue(AntigravityStatusProbe.isAntigravityLanguageServerCommand(command))
    }

    func testProcessDetectionAcceptsLegacyLanguageServerNames() {
        let command = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm \
        --csrf_token token --app_data_dir antigravity
        """

        XCTAssertTrue(AntigravityStatusProbe.isAntigravityLanguageServerCommand(command))
    }

    func testProcessDetectionIgnoresNonLanguageServerHelpers() {
        let command = """
        /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper \
        --type=renderer --user-data-dir=/Users/test/Library/Application Support/Antigravity
        """

        XCTAssertFalse(AntigravityStatusProbe.isAntigravityLanguageServerCommand(command))
    }

    func testProcessDetectionRejectsWindowsStyleLanguageServerPath() {
        let command = #"C:\Users\test\AppData\Local\Antigravity\language_server.exe --csrf_token token --app_data_dir antigravity"#

        XCTAssertFalse(AntigravityStatusProbe.isAntigravityLanguageServerCommand(command))
    }

    func testProcessPriorityPrefersStandaloneAntigravityTwoOverLegacyIDE() {
        let standalone = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --override_ide_name antigravity --subclient_type hub --csrf_token token --app_data_dir antigravity
        """
        let legacyIDE = """
        /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm \
        --csrf_token token --extension_server_port 61725 --app_data_dir antigravity-ide --subclient_type ide
        """

        XCTAssertLessThan(
            AntigravityStatusProbe.antigravityProcessPriority(standalone),
            AntigravityStatusProbe.antigravityProcessPriority(legacyIDE)
        )
    }

    func testPortFlagParsingIgnoresZeroAndInvalidPortHints() {
        let command = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --https_server_port 0 --extension_server_port=70000 --app_data_dir antigravity
        """

        XCTAssertNil(AntigravityStatusProbe.extractPort("--https_server_port", from: command))
        XCTAssertNil(AntigravityStatusProbe.extractPort("--extension_server_port", from: command))
    }

    func testPortFlagParsingAcceptsValidSpaceAndEqualsForms() {
        let command = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --https_server_port 61662 --extension_server_port=61663 --app_data_dir antigravity
        """

        XCTAssertEqual(AntigravityStatusProbe.extractPort("--https_server_port", from: command), 61662)
        XCTAssertEqual(AntigravityStatusProbe.extractPort("--extension_server_port", from: command), 61663)
    }
}
