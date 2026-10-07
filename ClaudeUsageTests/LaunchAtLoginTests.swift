import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private func settings(_ service: FakeLoginItemService) throws -> (AppSettings, UserDefaults) {
        let suite = "LaunchAtLoginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (
            AppSettings(
                defaults: defaults, hasExistingAccountStorage: false,
                launchAtLoginController: LaunchAtLoginController(service: service)), defaults
        )
    }

    func testNotFoundEnableActuallyRegistersAndTurnsOnWithoutOpeningSystemSettings() throws {
        let service = FakeLoginItemService(status: .notFound)
        let (settings, defaults) = try settings(service)
        XCTAssertFalse(settings.launchAtLoginState.isSelected)
        settings.setLaunchAtLogin(true)
        XCTAssertEqual(service.registerCalls, 1, "the previous notRegistered-only guard skipped this user request")
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.launchAtLoginState.isSelected)
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertNil(settings.launchAtLoginState.failure)
        XCTAssertEqual(service.settingsCalls, 0)
    }

    func testFirstRegistrationCanEnableInsideApp() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        let (settings, _) = try settings(service)
        settings.launchAtLogin = true
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.launchAtLoginState.isSelected)
        XCTAssertEqual(service.settingsCalls, 0)
    }

    func testApprovalKeepsRegisteredToggleOnButDoesNotPersistAuthorizationThatWasNotGranted() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        service.afterRegister = .requiresApproval
        let (settings, defaults) = try settings(service)
        settings.setLaunchAtLogin(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(settings.launchAtLoginState.isSelected)
        XCTAssertTrue(settings.launchAtLoginState.requiresApproval)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertNotNil(settings.launchAtLoginState.notice)
        XCTAssertNil(settings.launchAtLoginState.failure)
        XCTAssertEqual(service.settingsCalls, 0)
        settings.openLoginItemSettings()
        XCTAssertEqual(service.settingsCalls, 1)
    }

    func testPendingRegistrationCanBeDisabledEvenWhenLegacyBooleanIsFalse() throws {
        let service = FakeLoginItemService(status: .requiresApproval)
        let (settings, defaults) = try settings(service)
        XCTAssertFalse(settings.launchAtLogin)
        settings.setLaunchAtLogin(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(settings.launchAtLoginState.isSelected)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
    }

    func testRegistrationErrorCannotMakeTogglePretendToBeOnOrIssueRollbackCommand() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = NSError(
            domain: "private.domain", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "sensitive fixture path /private/account-token"])
        let (settings, defaults) = try settings(service)
        settings.launchAtLogin = true
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.launchAtLoginState.isSelected)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertEqual(settings.launchAtLoginState.failure?.code, 7)
        XCTAssertNotNil(settings.launchAtLoginState.notice)
        let diagnostic = OperationalDiagnostic.launchAtLogin(settings.launchAtLoginState)
        XCTAssertEqual(diagnostic.code, "loginItem.registerFailed.7")
        XCTAssertFalse(String(describing: diagnostic).contains("private.domain"))
        XCTAssertFalse(String(describing: diagnostic).contains("account-token"))
    }

    func testUnconfirmedRegistrationIsNotSuccess() throws {
        let service = FakeLoginItemService(status: .notFound)
        service.afterRegister = .notFound
        let (settings, _) = try settings(service)
        settings.setLaunchAtLogin(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertFalse(settings.launchAtLoginState.isSelected)
        XCTAssertNotNil(settings.launchAtLoginState.failure)
        XCTAssertTrue(settings.launchAtLoginState.canOpenSystemSettings)
    }

    func testUnregisterFailureKeepsActualRegistrationAndDoesNotReRegister() throws {
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = NSError(domain: "private.domain", code: 8)
        let (settings, defaults) = try settings(service)
        settings.setLaunchAtLogin(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertEqual(settings.launchAtLoginState.failure?.action, .disable)
    }

    func testExternalChangeRefreshesPresentationWithoutChangingSystemRegistration() throws {
        let service = FakeLoginItemService(status: .requiresApproval)
        let (settings, defaults) = try settings(service)
        service.status = .enabled
        settings.refreshLaunchAtLoginStatus()
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.launchAtLoginState.notice)
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        service.status = .notRegistered
        settings.refreshLaunchAtLoginStatus()
        XCTAssertFalse(settings.launchAtLoginState.isSelected)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testExternalApprovalClearsPriorFailureAndRepeatedRequestsDoNotDuplicateRegistration() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = NSError(domain: "private.domain", code: 1)
        let (settings, _) = try settings(service)
        settings.setLaunchAtLogin(true)
        XCTAssertNotNil(settings.launchAtLoginState.failure)
        service.status = .enabled
        settings.refreshLaunchAtLoginStatus()
        XCTAssertNil(settings.launchAtLoginState.failure)
        settings.setLaunchAtLogin(true)
        XCTAssertEqual(service.registerCalls, 1)
        let snapshot = settings.createSnapshot()
        settings.restore(from: snapshot)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testInitialSystemStatusWinsOverSavedBooleanWithoutAnyRegistration() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        let (settings, defaults) = try settings(service)
        defaults.set(true, forKey: "launchAtLogin")
        let restored = AppSettings(
            defaults: defaults, hasExistingAccountStorage: true,
            launchAtLoginController: LaunchAtLoginController(service: service))
        XCTAssertFalse(restored.launchAtLogin)
        XCTAssertFalse(restored.launchAtLoginState.isSelected)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testFailureIsNotClearedJustBecauseAnUnresolvedSystemStatusChanged() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = NSError(domain: "private.domain", code: 1)
        let (settings, _) = try settings(service)
        settings.setLaunchAtLogin(true)
        service.status = .notFound
        settings.refreshLaunchAtLoginStatus()
        XCTAssertEqual(settings.launchAtLoginState.failure?.code, 1)
        service.status = .requiresApproval
        settings.refreshLaunchAtLoginStatus()
        XCTAssertNil(settings.launchAtLoginState.failure)
        XCTAssertTrue(settings.launchAtLoginState.isSelected)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testAlreadyRegisteredAndApprovalErrorsAreJudgedAgainstActualSystemStatus() throws {
        for after in [LoginItemStatus.enabled, .requiresApproval] {
            let service = FakeLoginItemService(status: .notFound)
            service.registerError = NSError(domain: "private.domain", code: 1)
            service.registerErrorResult = after
            let (settings, _) = try settings(service)
            settings.setLaunchAtLogin(true)
            XCTAssertEqual(service.registerCalls, 1)
            XCTAssertTrue(settings.launchAtLoginState.isSelected)
            XCTAssertNil(settings.launchAtLoginState.failure)
            XCTAssertEqual(settings.launchAtLogin, after == .enabled)
        }
    }

    func testLoginItemRowRendersRegistrationApprovalAndFailure() throws {
        let services = [
            FakeLoginItemService(status: .notRegistered), FakeLoginItemService(status: .enabled),
            FakeLoginItemService(status: .requiresApproval), FakeLoginItemService(status: .notFound),
        ]
        let models = try services.map { try settings($0).0 }
        services[3].registerError = NSError(domain: "private.domain", code: 1)
        models[3].setLaunchAtLogin(true)
        let view = VStack(spacing: 18) {
            ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                VStack(alignment: .leading, spacing: 6) {
                    Text(["끔", "사용", "승인 대기", "등록 실패"][index]).font(.caption)
                    LaunchAtLoginToggle(settings: model)
                }
            }
        }
        .padding(16)
        .frame(width: 520)
        .environment(\.colorScheme, .dark)
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: 520, height: 2000))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        defer { window.close() }
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        XCTAssertEqual(image.size.width, 520, accuracy: 0.1)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Login item registration states"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemManaging {
    var status: LoginItemStatus
    var afterRegister: LoginItemStatus = .enabled
    var afterUnregister: LoginItemStatus = .notRegistered
    var registerError: Error?
    var registerErrorResult: LoginItemStatus?
    var unregisterError: Error?
    var registerCalls = 0
    var unregisterCalls = 0
    var settingsCalls = 0
    init(status: LoginItemStatus) { self.status = status }
    func register() throws {
        registerCalls += 1
        if let registerError {
            if let registerErrorResult { status = registerErrorResult }
            throw registerError
        }
        status = afterRegister
    }
    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = afterUnregister
    }
    func openSystemSettings() { settingsCalls += 1 }
}
