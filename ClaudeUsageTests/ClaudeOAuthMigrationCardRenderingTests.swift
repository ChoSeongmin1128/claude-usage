import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeOAuthMigrationCardRenderingTests: XCTestCase {
    func testAvailableMigrationCardRendersAtSettingsWidth() throws {
        let view = ClaudeOAuthMigrationCard(
            state: .available,
            onMigrate: {},
            onDefer: {},
            onReconnectClaudeCode: {}
        )
        .frame(width: 680)
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, 600)
        XCTAssertGreaterThan(image.size.height, 70)
        XCTAssertLessThan(image.size.height, 180)

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
    }

    func testFailureMigrationCardKeepsAllActionsWithinSettingsWidth() throws {
        let view = ClaudeOAuthMigrationCard(
            state: .failed("기존 Claude Code 연결 정보를 읽지 못했습니다. Claude Code에 다시 로그인해 주세요."),
            onMigrate: {},
            onDefer: {},
            onReconnectClaudeCode: {}
        )
        .frame(width: 680)
        .padding(20)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 720, accuracy: 1)
        XCTAssertLessThan(image.size.height, 200)

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
    }

    func testMigrationActionReplacesDuplicateReconnectOnlyWhileActionable() {
        XCTAssertTrue(
            ClaudeOAuthCredentialMigrationState.available
                .replacesStandardClaudeCodeReconnectAction
        )
        XCTAssertTrue(
            ClaudeOAuthCredentialMigrationState.checking
                .replacesStandardClaudeCodeReconnectAction
        )
        XCTAssertTrue(
            ClaudeOAuthCredentialMigrationState.migrating
                .replacesStandardClaudeCodeReconnectAction
        )
        XCTAssertTrue(
            ClaudeOAuthCredentialMigrationState.failed("failure")
                .replacesStandardClaudeCodeReconnectAction
        )
        XCTAssertFalse(
            ClaudeOAuthCredentialMigrationState.deferred
                .replacesStandardClaudeCodeReconnectAction
        )
        XCTAssertFalse(
            ClaudeOAuthCredentialMigrationState.completed
                .replacesStandardClaudeCodeReconnectAction
        )
        XCTAssertFalse(
            ClaudeOAuthCredentialMigrationState.notNeeded
                .replacesStandardClaudeCodeReconnectAction
        )
    }
}
