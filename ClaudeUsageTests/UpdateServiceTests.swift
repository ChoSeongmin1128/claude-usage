import Foundation
import XCTest
@testable import ClaudeUsage

final class UpdateRuntimeStateTests: XCTestCase {
    func testPopoverButtonOnlyAppearsAfterSparkleDownloadIsPrepared() {
        let sparkleReady = UpdateEngineStatus(
            modeSummary: "Sparkle",
            sparkleIntegrated: true,
            feedConfigured: true,
            publicKeyConfigured: true
        )

        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .idle,
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .updateAvailable(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .downloading(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .downloaded(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .readyToInstall(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .readyToInstall(version: "9.9.9"),
                engineStatus: UpdateEngineStatus(
                    modeSummary: "Fallback",
                    sparkleIntegrated: false,
                    feedConfigured: false,
                    publicKeyConfigured: false
                )
            )
        )
    }

    func testPrimaryActionOnlyTreatsSparklePreparedUpdateAsInstallable() {
        let sparkleReady = UpdateEngineStatus(
            modeSummary: "Sparkle",
            sparkleIntegrated: true,
            feedConfigured: true,
            publicKeyConfigured: true
        )
        let fallback = UpdateEngineStatus(
            modeSummary: "Fallback",
            sparkleIntegrated: false,
            feedConfigured: false,
            publicKeyConfigured: false
        )

        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .downloaded(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .readyToInstall(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .updateAvailable(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .updateAvailable(version: "9.9.9"),
                engineStatus: fallback
            )
        )
    }
}

final class UpdateServiceTests: XCTestCase {
    func testUserInitiatedCheckUsesBackgroundCheckWhenEngineIsNotInteractive() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false)
        let service = UpdateService(engine: engine)

        await service.performUserInitiatedCheck()

        XCTAssertEqual(engine.checkCount, 1)
        XCTAssertEqual(engine.interactiveCheckCount, 0)
    }

    func testUserInitiatedCheckUsesInteractivePathOnlyWhenEngineSupportsIt() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: true)
        let service = UpdateService(engine: engine)

        await service.performUserInitiatedCheck()

        XCTAssertEqual(engine.checkCount, 0)
        XCTAssertEqual(engine.interactiveCheckCount, 1)
    }

    func testPreparedUpdatePresentationUsesExplicitInteractivePath() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false)
        let service = UpdateService(engine: engine)

        let didPresent = await service.presentPreparedUpdate()

        XCTAssertTrue(didPresent)
        XCTAssertEqual(engine.checkCount, 0)
        XCTAssertEqual(engine.interactiveCheckCount, 1)
    }

    func testInstallPreparedUpdateDelegatesToEngine() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false)
        let service = UpdateService(engine: engine)

        let didInstall = await service.installPreparedUpdate()

        XCTAssertTrue(didInstall)
        XCTAssertEqual(engine.installCount, 1)
    }
}

private final class FakeUpdateEngine: AppUpdateEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let isInteractive: Bool
    private var _checkCount = 0
    private var _interactiveCheckCount = 0
    private var _installCount = 0

    init(supportsInteractiveCheck: Bool) {
        self.isInteractive = supportsInteractiveCheck
    }

    var checkCount: Int {
        lock.withLock { _checkCount }
    }

    var interactiveCheckCount: Int {
        lock.withLock { _interactiveCheckCount }
    }

    var installCount: Int {
        lock.withLock { _installCount }
    }

    func modeSummary() async -> String {
        "Fake"
    }

    func checkForUpdates() async -> UpdateCheckResult {
        lock.withLock {
            _checkCount += 1
        }
        return .upToDate(message: nil)
    }

    func latestDownloadURL() async -> URL {
        URL(string: "https://example.com/ClaudeUsage.zip")!
    }

    func usesExternalScheduler() async -> Bool {
        true
    }

    func supportsInteractiveCheck() async -> Bool {
        isInteractive
    }

    func performInteractiveCheck() async -> String? {
        lock.withLock {
            _interactiveCheckCount += 1
        }
        return "interactive"
    }

    func presentPreparedUpdate() async -> Bool {
        _ = await performInteractiveCheck()
        return true
    }

    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async { }

    func installPreparedUpdate() async -> Bool {
        lock.withLock {
            _installCount += 1
        }
        return true
    }

    func configurationStatus() async -> UpdateEngineStatus {
        UpdateEngineStatus(
            modeSummary: "Fake",
            sparkleIntegrated: true,
            feedConfigured: true,
            publicKeyConfigured: true
        )
    }
}
