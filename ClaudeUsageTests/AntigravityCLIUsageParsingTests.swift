import XCTest
@testable import ClaudeUsage

final class AntigravityCLIUsageParsingTests: XCTestCase {
    func testParsesAgyUsageQuotaOutput() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-27T00:00:00Z")!
        let output = """
        Antigravity CLI 1.0.2
        nathan@glorang.com

        └ Model Quota

          Gemini 3.5 Flash (Medium)
          ███████████ ███████████ ███████████ ███████████ ░░░░░░░░░░░ 80%
          80% remaining · Refreshes in 167h 37m

          Gemini 3.1 Pro (Low)
          ███████████ ███████████ ███████████ ███████████ ░░░░░░░░░░░ 80%
          80% remaining · Refreshes in 167h 37m

          Claude Sonnet 4.6 (Thinking)
          ███████████ ███████████ ███████████ ███████████ ███████████ 100%
          Quota available

          Claude Opus 4.6 (Thinking)
          ███████████ ███████████ ███████████ ███████████ ███████████ 100%
          Quota available
        """

        let response = try AntigravityCLIUsageParsing.response(from: output, now: now)

        XCTAssertEqual(response.source, .agyCLI)
        XCTAssertEqual(response.accountEmail, "nathan@glorang.com")
        XCTAssertEqual(
            response.modelWindows.map(\.label),
            [
                "Gemini 3.5 Flash (Medium)",
                "Gemini 3.1 Pro (Low)",
                "Claude Sonnet 4.6 (Thinking)",
                "Claude Opus 4.6 (Thinking)",
            ]
        )
        XCTAssertEqual(response.primaryWindow?.label, "Gemini 3.1 Pro (Low)")
        XCTAssertEqual(response.primaryPercentage, 20, accuracy: 0.001)
        XCTAssertEqual(response.secondaryWindow?.label, "Gemini 3.5 Flash (Medium)")
        XCTAssertEqual(response.secondaryPercentage, 20, accuracy: 0.001)
        XCTAssertEqual(response.tertiaryWindow?.label, "Claude Sonnet 4.6 (Thinking)")
        XCTAssertEqual(response.tertiaryPercentage, 0, accuracy: 0.001)
        XCTAssertEqual(response.primaryWindow?.resetAtISO, "2026-06-02T23:37:00Z")
    }

    func testThrowsWhenAgyOutputDoesNotContainModelQuota() {
        XCTAssertThrowsError(
            try AntigravityCLIUsageParsing.response(
                from: "It looks like you typed /usage.",
                now: Date()
            )
        )
    }

    func testExecutableResolverSkipsBrokenPathCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)")
        let staleBin = directory.appendingPathComponent("stale-bin")
        let workingBin = directory.appendingPathComponent("working-bin")
        try FileManager.default.createDirectory(at: staleBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingTarget = directory.appendingPathComponent("missing-antigravity")
        let staleWrapper = staleBin.appendingPathComponent("agy.wrapper.sh")
        try "#!/bin/sh\nexec '\(missingTarget.path)' \"$@\"\n"
            .write(to: staleWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: staleWrapper.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: staleBin.appendingPathComponent("agy").path,
            withDestinationPath: staleWrapper.path
        )

        let workingExecutable = workingBin.appendingPathComponent("agy")
        try "#!/bin/sh\nexit 0\n".write(to: workingExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: workingExecutable.path
        )

        let resolvedURL = AntigravityCLIExecutableResolver.resolvedExecutableURL(
            environment: ["PATH": "\(staleBin.path):\(workingBin.path)"]
        )

        XCTAssertEqual(resolvedURL?.path, workingExecutable.path)
    }

    func testCurrentAgyUsageOutputParsesWhenIntegrationEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLAUDEUSAGE_RUN_AGY_INTEGRATION"] == "1",
            "Set CLAUDEUSAGE_RUN_AGY_INTEGRATION=1 to run the local agy TUI integration test."
        )

        guard let executableURL = AntigravityCLIExecutableResolver.resolvedExecutableURL() else {
            throw XCTSkip("agy executable is not available")
        }

        let output = try await AntigravityCLIPTYUsageCommandRunner()
            .runUsageCommand(executableURL: executableURL, timeout: 20)
        let response: AntigravityUsageResponse
        do {
            response = try AntigravityCLIUsageParsing.response(from: output, now: Date())
        } catch {
            XCTFail("Failed to parse agy /usage output:\n\(redactedOutputPreview(output))")
            throw error
        }

        XCTAssertEqual(response.source, .agyCLI)
        XCTAssertTrue(response.hasUsageWindows)
        XCTAssertFalse(response.modelWindows.isEmpty)
    }

    private func redactedOutputPreview(_ output: String) -> String {
        String(output.prefix(6_000))
            .replacingOccurrences(
                of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                with: "<email>",
                options: [.regularExpression, .caseInsensitive]
            )
    }
}
