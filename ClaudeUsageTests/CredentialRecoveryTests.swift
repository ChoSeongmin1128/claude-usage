import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

/// Every secret below is an invented fixture. Each test has its own temporary
/// home and in-memory vault; no system vault, default home, or external CLI.
final class CredentialRecoveryTests: XCTestCase, @unchecked Sendable {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAtomicCreateRefusesDuplicateWithoutChangingOriginalRecord() throws {
        let vault = RecoveryFixtureVault()
        let store = CredentialRecoveryStore(vault: vault)
        let first = CredentialRecoveryRefreshRecord(
            operationID: UUID(), accountID: nil, originalPayload: Self.managedPayload())
        try store.create(first)
        let raw = try vault.loadPayload(reference: CredentialRecoveryStore.refreshReference)
        let second = CredentialRecoveryRefreshRecord(
            operationID: UUID(), accountID: nil, originalPayload: Self.managedPayload(access: "another"))

        XCTAssertThrowsError(try store.create(second)) { XCTAssertEqual($0 as? CredentialRecoveryError, .busy) }
        XCTAssertEqual(try vault.loadPayload(reference: CredentialRecoveryStore.refreshReference), raw)
        XCTAssertEqual(try store.loadRefresh(), first)
        XCTAssertEqual(vault.saveCount, 0)
    }

    func testPreparedBeforePOSTCanBeRetiredAfterRestartWithoutUsingOriginalGeneration() async throws {
        let fixture = refreshFixture()
        _ = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        let restarted = fixture.restarted()

        let result = await restarted.recoverPending()

        XCTAssertTrue(result.didRecover)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertNil(try fixture.store.loadRefresh())
        XCTAssertEqual(fixture.appVault.saveCount, 0)
    }

    func testDurableSuccessorRestoresAfterRestartAndPreservesAdditionalFields() async throws {
        let fixture = refreshFixture()
        let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        try await fixture.coordinator.markRefreshStarted(id)
        let successor = Self.managedPayload(access: "successor-access", refresh: "successor-refresh", expired: false)
        try await fixture.coordinator.preserveSuccessor(successor, operationID: id)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertEqual(try fixture.store.loadRefresh()?.phase, .successor)

        let result = await fixture.restarted().recoverPending()

        XCTAssertTrue(result.didRecover)
        XCTAssertEqual(fixture.appVault.payload, successor)
        XCTAssertTrue(fixture.appVault.payload?.contains("fixture-extra-field") == true)
        XCTAssertNil(try fixture.store.loadRefresh())
        XCTAssertEqual(fixture.appVault.saveCount, 1)
    }

    func testUncertainPOSTNeverRetriesOldGenerationAfterTTLInvalidateOrRestart() async throws {
        let fixture = refreshFixture()
        let clock = RecoveryFixtureClock()
        let calls = RecoveryFixtureCalls()
        let refresher = ClaudeOAuthTokenRefresher(
            httpRunner: { request in
                calls.record(request)
                throw URLError(.timedOut)
            }, clientIDOverride: "fixture-public-client", cooldownInterval: 0)
        let reader = makeReader(fixture: fixture, refresher: refresher, clock: clock)
        let initial = try await reader.readCredential()
        XCTAssertNil(initial)
        XCTAssertEqual(try fixture.store.loadRefresh()?.phase, .started)
        clock.advance(61)
        await reader.invalidateCache()
        let afterInvalidation = try await reader.readCredential()
        XCTAssertNil(afterInvalidation)
        let restartedReader = makeReader(
            fixture: fixture, coordinator: fixture.restarted(), refresher: refresher, clock: clock)
        let afterRestart = try await restartedReader.readCredential()
        XCTAssertNil(afterRestart)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertEqual(fixture.appVault.deleteCount, 0)
        XCTAssertNotNil(try fixture.store.loadRefresh())
    }

    func testFailedSuccessorPersistenceSurvivesTTLAndInvalidateInSameProcess() async throws {
        let fixture = refreshFixture()
        fixture.recordVault.failSuccessorWrites(1)
        let clock = RecoveryFixtureClock()
        let calls = RecoveryFixtureCalls()
        let reader = makeReader(fixture: fixture, refresher: successRefresher(calls), clock: clock)
        let first = try await reader.readCredential()
        XCTAssertEqual(first?.accessToken, "rotated-access")
        XCTAssertEqual(first?.refreshToken, "rotated-refresh")
        XCTAssertEqual(try fixture.store.loadRefresh()?.phase, .started)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        clock.advance(61)
        await reader.invalidateCache()

        let second = try await reader.readCredential()

        XCTAssertEqual(second?.accessToken, "rotated-access")
        XCTAssertEqual(second?.refreshToken, "rotated-refresh")
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(fixture.appVault.payload?.contains("rotated-refresh") == true)
        XCTAssertNil(try fixture.store.loadRefresh())
    }

    func testOneShotRecoveryReadFailureAfterPOSTKeepsSuccessorAcrossTTLAndInvalidate() async throws {
        let fixture = refreshFixture()
        let clock = RecoveryFixtureClock()
        let calls = RecoveryFixtureCalls()
        let refresher = ClaudeOAuthTokenRefresher(
            httpRunner: { request in
                calls.record(request)
                fixture.recordVault.failNextReads(CredentialRecoveryStore.refreshReference, count: 1)
                return (
                    Data(Self.refreshResponse.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }, clientIDOverride: "fixture-public-client")
        let reader = makeReader(fixture: fixture, refresher: refresher, clock: clock)

        let first = try await reader.readCredential()

        XCTAssertEqual(fixture.recordVault.failedReadCount, 1)
        XCTAssertEqual(first?.refreshToken, "rotated-refresh")
        XCTAssertEqual(try fixture.store.loadRefresh()?.phase, .started)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        clock.advance(61)
        await reader.invalidateCache()
        let recovered = try await reader.readCredential()

        XCTAssertEqual(recovered?.refreshToken, "rotated-refresh")
        XCTAssertTrue(fixture.appVault.payload?.contains("rotated-refresh") == true)
        XCTAssertNil(try fixture.store.loadRefresh())
        XCTAssertEqual(calls.count, 1)
    }

    func testRestartBeforeSuccessorPersistenceCannotRecoverItAndDoesNotRetryOriginal() async throws {
        let fixture = refreshFixture()
        fixture.recordVault.failSuccessorWrites(1)
        let calls = RecoveryFixtureCalls()
        let refresher = successRefresher(calls)
        let reader = makeReader(fixture: fixture, refresher: refresher)
        let first = try await reader.readCredential()
        XCTAssertEqual(first?.accessToken, "rotated-access")
        let record = try XCTUnwrap(fixture.store.loadRefresh())
        XCTAssertEqual(record.phase, .started)
        XCTAssertNil(record.successorPayload)

        let restartedReader = makeReader(fixture: fixture, coordinator: fixture.restarted(), refresher: refresher)
        let afterRestart = try await restartedReader.readCredential()

        XCTAssertNil(afterRestart)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertEqual(try fixture.store.loadRefresh(), record)
    }

    func testActiveVaultWriteFailureStillKeepsDurableSuccessorForRestart() async throws {
        let fixture = refreshFixture()
        fixture.appVault.failNextSaves(1)
        let calls = RecoveryFixtureCalls()
        let reader = makeReader(fixture: fixture, refresher: successRefresher(calls))
        let first = try await reader.readCredential()
        XCTAssertEqual(first?.refreshToken, "rotated-refresh")
        let durable = try XCTUnwrap(fixture.store.loadRefresh())
        XCTAssertEqual(durable.phase, .successor)
        XCTAssertTrue(durable.successorPayload?.contains("rotated-refresh") == true)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)

        let result = await fixture.restarted().recoverPending()

        XCTAssertTrue(result.didRecover)
        XCTAssertTrue(fixture.appVault.payload?.contains("rotated-refresh") == true)
        XCTAssertTrue(fixture.appVault.payload?.contains("fixture-extra-field") == true)
        XCTAssertNil(try fixture.store.loadRefresh())
        XCTAssertEqual(calls.count, 1)
    }

    func testCancelledDelayedFailedCLIReadDoesNotPromptOrSave() async throws {
        let fixture = refreshFixture(original: nil)
        let started = expectation(description: "fake CLI read started")
        let cli = RecoveryDeferredCLI(started: started)
        let prompts = RecoveryFixtureCounter()
        let reader = makeReader(
            fixture: fixture, cli: { await cli.read($0) },
            interactive: { _, _, _ in
                prompts.increment()
                return .value(Self.rawPayload(access: "imported", refresh: "new-cli", expired: false))
            })
        let task = Task { await reader.importActiveCLICredential() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await cli.finish(.failed)

        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(prompts.value, 0)
        XCTAssertEqual(fixture.appVault.saveCount, 0)
        XCTAssertNil(fixture.appVault.payload)
        let status = await fixture.coordinator.status(provider: .claude)
        XCTAssertEqual(status, .ready)
    }

    func testUncancelledInteractiveImportControlSavesMutableVault() async throws {
        let fixture = refreshFixture(original: nil)
        let prompts = RecoveryFixtureCounter()
        let reader = makeReader(
            fixture: fixture, cli: { _ in .failed },
            interactive: { _, _, _ in
                prompts.increment()
                return .value(Self.rawPayload(access: "imported", refresh: "new-cli", expired: false))
            })
        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(prompts.value, 1)
        XCTAssertEqual(fixture.appVault.saveCount, 1)
        XCTAssertEqual(
            fixture.appVault.payload.flatMap {
                ClaudeCodeCredentialReader.parseCredential(from: $0, source: .refreshed)?.refreshToken
            }, "new-cli")
        XCTAssertEqual(fixture.appVault.payload.map(ClaudeOAuthCredentialVaultPayload.ownership), .cliMirror)
    }

    func testFreshExplicitImportSuspendsOldPOSTAndLateSuccessNeverOverwritesNewVault() async throws {
        let fixture = refreshFixture()
        let started = expectation(description: "old POST started")
        let http = RecoveryDeferredHTTP(started: started)
        let cliPayload = Self.rawPayload(access: "new-cli-access", refresh: "new-cli-refresh", expired: false)
        let reader = makeReader(
            fixture: fixture,
            refresher: ClaudeOAuthTokenRefresher(httpRunner: { try await http.run($0) }, clientIDOverride: "fixture"),
            cli: { _ in .payload(cliPayload) })
        let oldRead = Task { try await reader.readCredential() }
        await fulfillment(of: [started], timeout: 2)
        let imported = await reader.importActiveCLICredential()
        XCTAssertEqual(imported, .imported(credentialChanged: true))
        let newVault = try XCTUnwrap(fixture.appVault.payload)
        let suspended = try XCTUnwrap(fixture.store.loadRefresh())
        XCTAssertFalse(suspended.automaticRecoveryAllowed)
        XCTAssertEqual(suspended.originalPayload, fixture.original)
        let status = await fixture.coordinator.status(provider: .claude, accountID: "current-user|workspace")
        let affected = await fixture.coordinator.affectedSources(provider: .claude)
        XCTAssertEqual(status, .ready)
        XCTAssertFalse(affected.includesCurrentAppVault)
        let oldCredential = try XCTUnwrap(
            ClaudeCodeCredentialReader.parseCredential(
                from: fixture.original, source: .appManagedVault))
        let oldAllowed = await fixture.coordinator.canRefreshCLIGeneration(oldCredential)
        XCTAssertFalse(oldAllowed)

        await http.finish(body: Self.refreshResponse)
        _ = try? await oldRead.value
        let retained = try XCTUnwrap(fixture.store.loadRefresh())

        XCTAssertEqual(fixture.appVault.payload, newVault)
        XCTAssertEqual(fixture.appVault.saveCount, 1)
        XCTAssertEqual(retained.operationID, suspended.operationID)
        XCTAssertEqual(retained.originalPayload, suspended.originalPayload)
        XCTAssertFalse(retained.automaticRecoveryAllowed)
        XCTAssertTrue(retained.successorPayload?.contains("rotated-refresh") == true)
        let restartedResult = await fixture.restarted().recoverPending()
        XCTAssertFalse(restartedResult.didRecover)
        XCTAssertEqual(fixture.appVault.payload, newVault)
        XCTAssertEqual(try fixture.store.loadRefresh(), retained)
    }

    func testKnownPendingRecordRejectsExplicitImportOfSameConsumedGeneration() async throws {
        let fixture = refreshFixture()
        let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        try await fixture.coordinator.markRefreshStarted(id)
        await fixture.coordinator.releaseRefresh(id)
        let before = try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference)
        let reader = makeReader(
            fixture: fixture,
            cli: { _ in
                .payload(Self.rawPayload(access: "different-access", refresh: "original-refresh", expired: false))
            })
        let result = await reader.importActiveCLICredential()

        guard case .failed = result else { return XCTFail("same consumed generation must be rejected") }
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertEqual(fixture.appVault.saveCount, 0)
        XCTAssertEqual(try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference), before)
    }

    func testConsumedGenerationCannotRefreshThroughProviderOwnerVerificationOrNativeKeychainReader() async throws {
        let fixture = refreshFixture()
        let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        try await fixture.coordinator.markRefreshStarted(id)
        await fixture.coordinator.releaseRefresh(id)
        let oldCLI = Self.rawPayload(expired: true)
        let slot = try claudeSlot("consumed-generation", access: "original-access", refresh: "original-refresh")
        try Data(oldCLI.utf8).write(to: slot.credentialFiles[0])
        let calls = RecoveryFixtureCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryRejectNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let before = try fixture.store.loadRefresh()

        do {
            _ = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
                slot: slot, interactive: false, keychain: .none, session: session,
                cliRefresher: { _ in
                    calls.increment(); return .unavailable
                },
                recoveryCoordinator: fixture.coordinator)
            XCTFail("quota fetch must reject the consumed CLI generation before refresh")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .loginExpired) }
        do {
            _ = try await ClaudeAccountSwitcher.verifyOwner(
                of: slot, keychain: .none,
                refresher: { _ in
                    calls.increment(); return .unavailable
                },
                tokenOwner: { _ in
                    XCTFail("a consumed expired token must not reach owner lookup"); return nil
                },
                recoveryCoordinator: fixture.coordinator)
            XCTFail("owner verification must reject the consumed CLI generation before refresh")
        } catch { XCTAssertEqual(error as? AccountSwitchError, .ownerUnverified) }
        // A missing app mirror must not let the native Keychain path retry it.
        try fixture.appVault.deletePayload()
        let reader = makeReader(
            fixture: fixture, cli: { _ in .payload(oldCLI) },
            cliRefresher: { _ in
                calls.increment(); return .unavailable
            })
        let credential = try await reader.readCredential()

        XCTAssertNil(credential)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(fixture.appVault.saveCount, 0)
        XCTAssertEqual(try fixture.store.loadRefresh(), before)
        XCTAssertEqual(try Data(contentsOf: slot.credentialFiles[0]), Data(oldCLI.utf8))
    }

    func testOwnerVerificationAllowsRefreshOnlyForItsActiveSwitchOperation() async throws {
        let fixture = refreshFixture(original: nil)
        let slot = try claudeSlot("owned-operation", access: "owned-expired", refresh: "owned-original")
        let original = Data(Self.rawPayload(access: "owned-expired", refresh: "owned-original", expired: true).utf8)
        let fresh = Data(Self.rawPayload(access: "owned-fresh", refresh: "owned-successor", expired: false).utf8)
        let file = slot.credentialFiles[0]
        try original.write(to: file)
        let id = try await fixture.coordinator.beginSwitch(
            provider: .claude, accountID: nil,
            components: [
                .init(location: .file(file), original: original, proposed: fresh)
            ])
        let calls = RecoveryFixtureCounter()
        let refresher: ClaudeCodeCredentialReader.CLIRefresher = { _ in
            calls.increment()
            do { try fresh.write(to: file); return .refreshed } catch {
                XCTFail("could not update the temp credential fixture"); return .unavailable
            }
        }
        let owner: ClaudeCodeFolderKeychain.TokenOwner = { _ in
            UsageAccountIdentity(email: "owned-operation@example.invalid")
        }

        do {
            _ = try await ClaudeAccountSwitcher.verifyOwner(
                of: slot, keychain: .none,
                refresher: refresher, tokenOwner: owner,
                recoveryCoordinator: fixture.coordinator, switchOperationID: UUID())
            XCTFail("an unrelated operationID must not grant refresh rights")
        } catch { XCTAssertEqual(error as? AccountSwitchError, .ownerUnverified) }
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let token = try await ClaudeAccountSwitcher.verifyOwner(
            of: slot, keychain: .none,
            refresher: refresher, tokenOwner: owner,
            recoveryCoordinator: fixture.coordinator, switchOperationID: id)

        XCTAssertEqual(token, "owned-fresh")
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(try Data(contentsOf: file), fresh)
        XCTAssertEqual(try fixture.store.loadSwitch()?.operationID, id)
        await fixture.coordinator.releaseSwitch(id)
    }

    func testFreshReconnectSuspendsKnownSwitchAndFailedOrSameGenerationImportKeepsOriginalPermission() async throws {
        for scenario in ["fresh", "save-failed", "same-generation"] {
            let fixture = refreshFixture(original: nil)
            let files = try switchFixture(name: "switch-reconnect-" + scenario, includeProfiles: true)
            let id = try await fixture.coordinator.beginSwitch(
                provider: .claude, accountID: "old-account", components: files.components)
            try await fixture.coordinator.applySwitch(id)
            await fixture.coordinator.releaseSwitch(id)
            let prior = try XCTUnwrap(fixture.store.loadSwitch())
            if scenario == "save-failed" { fixture.appVault.failNextSaves(1) }
            let generation = scenario == "same-generation" ? "a-refresh" : "fresh-switch-reconnect"
            let reader = makeReader(
                fixture: fixture,
                cli: { _ in
                    .payload(Self.rawPayload(access: "reconnected-access", refresh: generation, expired: false))
                })

            let result = await reader.importActiveCLICredential()

            if scenario == "fresh" {
                XCTAssertEqual(result, .imported(credentialChanged: false))
                let imported = try XCTUnwrap(fixture.appVault.payload)
                let suspended = try XCTUnwrap(fixture.store.loadSwitch())
                XCTAssertFalse(suspended.automaticRecoveryAllowed)
                XCTAssertEqual(suspended.operationID, prior.operationID)
                XCTAssertEqual(suspended.components, prior.components)
                XCTAssertEqual(suspended.steps, prior.steps)
                XCTAssertEqual(suspended.nextStep, prior.nextStep)
                XCTAssertEqual(ClaudeOAuthCredentialVaultPayload.ownership(of: imported), .cliMirror)
                let recovered = await fixture.restarted().recoverPending()
                XCTAssertFalse(recovered.didRecover)
                XCTAssertEqual(try fixture.store.loadSwitch(), suspended)
                XCTAssertEqual(fixture.appVault.payload, imported)
                for component in files.components {
                    XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.proposed)
                }
            } else {
                guard case .failed = result else { return XCTFail("uncommitted reconnect must fail") }
                XCTAssertNil(fixture.appVault.payload)
                XCTAssertEqual(try fixture.store.loadSwitch(), prior)
                let recovered = await fixture.restarted().recoverPending()
                XCTAssertTrue(recovered.didRecover)
                XCTAssertNil(try fixture.store.loadSwitch())
                for component in files.components {
                    XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.original)
                }
            }
        }
    }

    func testFailedNewImportRestoresExactRecoveryPermissionAndKeepsPriorSuccessor() async throws {
        for durable in [false, true] {
            let fixture = refreshFixture()
            let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
            try await fixture.coordinator.markRefreshStarted(id)
            let successor = Self.managedPayload(
                access: "protected-successor", refresh: "protected-refresh", expired: false)
            if durable {
                try await fixture.coordinator.preserveSuccessor(successor, operationID: id)
            } else {
                fixture.recordVault.failSuccessorWrites(1)
                do {
                    try await fixture.coordinator.preserveSuccessor(successor, operationID: id)
                    XCTFail("the fixture must fail successor persistence")
                } catch {}
            }
            await fixture.coordinator.releaseRefresh(id)
            let prior = try XCTUnwrap(fixture.store.loadRefresh())
            fixture.appVault.failNextSaves(1)
            let reader = makeReader(
                fixture: fixture,
                cli: { _ in
                    .payload(
                        Self.rawPayload(access: "failed-new-import", refresh: "new-cli-generation", expired: false))
                })

            let result = await reader.importActiveCLICredential()

            guard case .failed = result else { return XCTFail("the new import must report its save failure") }
            XCTAssertEqual(fixture.appVault.payload, fixture.original)
            XCTAssertEqual(try fixture.store.loadRefresh(), prior)
            XCTAssertTrue(try XCTUnwrap(fixture.store.loadRefresh()).automaticRecoveryAllowed)
            let recovery = durable ? fixture.restarted() : fixture.coordinator
            let recovered = await recovery.recoverPending()
            XCTAssertTrue(recovered.didRecover)
            XCTAssertEqual(fixture.appVault.payload, successor)
            XCTAssertNil(try fixture.store.loadRefresh())
        }
    }

    func testResetSuspendsKnownPendingRecordAndRestartDoesNotApplyIt() async throws {
        let fixture = refreshFixture()
        let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        try await fixture.coordinator.markRefreshStarted(id)
        let successor = Self.managedPayload(access: "successor", refresh: "successor-refresh", expired: false)
        try await fixture.coordinator.preserveSuccessor(successor, operationID: id)
        await fixture.coordinator.releaseRefresh(id)

        let prepared = await fixture.coordinator.prepareForReset(timeout: .zero)
        XCTAssertTrue(prepared)
        let suspended = try XCTUnwrap(fixture.store.loadRefresh())
        XCTAssertFalse(suspended.automaticRecoveryAllowed)
        XCTAssertEqual(suspended.originalPayload, fixture.original)
        XCTAssertEqual(suspended.successorPayload, successor)
        try fixture.appVault.deletePayload()  // Only the fake app cache is reset.
        _ = await fixture.restarted().recoverPending()
        XCTAssertNil(fixture.appVault.payload)
        XCTAssertEqual(try fixture.store.loadRefresh(), suspended)
    }

    func testResetPreparationReadFailurePreservesRecordsAndReopensReadGate() async throws {
        let fixture = refreshFixture()
        let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        try await fixture.coordinator.markRefreshStarted(id)
        await fixture.coordinator.releaseRefresh(id)
        let before = try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference)
        fixture.recordVault.setReadFailure(CredentialRecoveryStore.refreshReference, enabled: true)

        let prepared = await fixture.coordinator.prepareForReset(timeout: .zero)
        XCTAssertFalse(prepared)
        let lease = try await fixture.coordinator.beginRead()
        XCTAssertTrue(fixture.coordinator.isReadCurrent(lease))
        fixture.recordVault.setReadFailure(CredentialRecoveryStore.refreshReference, enabled: false)
        XCTAssertEqual(try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference), before)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
    }

    func testMalformedAndFutureRecoveryRecordsStayIntactWhileNativeReadOnlyUsageWorks() async throws {
        for bytes in [Data("not-json".utf8), Data(#"{"schemaVersion":99,"operationID":"future"}"#.utf8)] {
            let fixture = refreshFixture(original: nil)
            fixture.recordVault.inject(bytes, reference: CredentialRecoveryStore.refreshReference)
            let cliPayload = Self.rawPayload(
                access: "native-read-only", refresh: "native-new-generation", expired: false)
            let reader = makeReader(fixture: fixture, cli: { _ in .payload(cliPayload) })

            let credential = try await reader.readCredential()
            XCTAssertEqual(credential?.accessToken, "native-read-only")
            XCTAssertEqual(fixture.appVault.saveCount, 0)
            XCTAssertNil(fixture.appVault.payload)
            let prepared = await fixture.coordinator.prepareForReset(timeout: .zero)
            XCTAssertFalse(prepared)
            let lease = try await fixture.coordinator.beginRead()
            XCTAssertTrue(fixture.coordinator.isReadCurrent(lease))
            XCTAssertEqual(
                try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference), bytes)
        }
    }

    func testResetTimeoutSuspendsIntentAndSealsEveryLateCallbackWrite() async throws {
        let fixture = refreshFixture()
        let started = expectation(description: "POST held across reset")
        let http = RecoveryDeferredHTTP(started: started)
        let reader = makeReader(
            fixture: fixture,
            refresher: ClaudeOAuthTokenRefresher(httpRunner: { try await http.run($0) }, clientIDOverride: "fixture"))
        let task = Task { try await reader.readCredential() }
        await fulfillment(of: [started], timeout: 2)

        let prepared = await fixture.coordinator.prepareForReset(timeout: .zero)
        XCTAssertTrue(prepared)
        let sealedIntent = try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadRefresh()).automaticRecoveryAllowed)
        try fixture.appVault.deletePayload()
        await http.finish(body: Self.refreshResponse)
        _ = try? await task.value

        XCTAssertNil(fixture.appVault.payload)
        XCTAssertEqual(fixture.appVault.saveCount, 0)
        XCTAssertEqual(
            try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference), sealedIntent)
        let status = await fixture.coordinator.status(provider: .claude)
        XCTAssertEqual(status, .closing)
    }

    func testNormalClosingDrainsPOSTPreservesSuccessorAndDoesNotApplyActiveVault() async throws {
        let fixture = refreshFixture()
        let started = expectation(description: "POST held during closing")
        let finished = expectation(description: "closing drained")
        let http = RecoveryDeferredHTTP(started: started)
        let reader = makeReader(
            fixture: fixture,
            refresher: ClaudeOAuthTokenRefresher(httpRunner: { try await http.run($0) }, clientIDOverride: "fixture"))
        let read = Task { try await reader.readCredential() }
        await fulfillment(of: [started], timeout: 2)
        fixture.coordinator.beginClosing()
        let closing = Task {
            await fixture.coordinator.finishClosing()
            finished.fulfill()
        }
        await http.finish(body: Self.refreshResponse)
        _ = try? await read.value
        await fulfillment(of: [finished], timeout: 2)
        await closing.value

        let durable = try XCTUnwrap(fixture.store.loadRefresh())
        XCTAssertEqual(durable.phase, .successor)
        XCTAssertTrue(durable.successorPayload?.contains("rotated-refresh") == true)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertEqual(fixture.appVault.saveCount, 0)
    }

    func testRestartRecoversEveryRecordedClaudeCredentialAndProfileBoundary() async throws {
        for boundary in 0..<4 {
            let fixture = try switchFixture(name: "boundary-\(boundary)", includeProfiles: true)
            let id = try await fixture.coordinator.beginSwitch(
                provider: .claude, accountID: "selected|workspace", components: fixture.components)
            var record = try XCTUnwrap(fixture.store.loadSwitch())
            for index in 0...boundary {
                record.intendedStep = index
                try fixture.store.update(record)
                let step = record.steps[index]
                let component = fixture.components[step.components[0]]
                try CredentialRecoveryFile.replace(
                    component.location, expected: step.before[0],
                    replacement: step.after[0], temporaryPath: step.temporaryPaths[0])
                if index < boundary {
                    record.nextStep = index + 1
                    record.intendedStep = nil
                    try fixture.store.update(record)
                }
            }
            XCTAssertEqual(record.operationID, id)
            // The last mutation succeeded but its completion marker did not.
            let recovered = await fixture.restarted().recoverPending()
            XCTAssertTrue(recovered.didRecover, "boundary \(boundary)")
            for component in fixture.components {
                XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.original)
            }
            XCTAssertNil(try fixture.store.loadSwitch())
        }
    }

    func testForeignChangeAfterCrashBlocksRestorationAndPreservesOriginals() async throws {
        let fixture = try switchFixture(name: "foreign", includeProfiles: false)
        _ = try await fixture.coordinator.beginSwitch(
            provider: .codex, accountID: "target", components: fixture.components)
        let before = try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.switchReference)
        try Data("foreign-account".utf8).write(to: fixture.files[0])

        let result = await fixture.restarted().recoverPending()

        XCTAssertEqual(result.codex, .blocked)
        XCTAssertEqual(try Data(contentsOf: fixture.files[0]), Data("foreign-account".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.files[1]), fixture.components[1].original)
        XCTAssertEqual(try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.switchReference), before)
    }

    func testPartialTargetCopyAfterCrashStopsRecoveryAndPreservesFilesAndRecord() async throws {
        let fixture = try switchFixture(name: "partial-copy", includeProfiles: false)
        let id = try await fixture.coordinator.beginSwitch(
            provider: .codex, accountID: "target", components: fixture.components)
        var record = try XCTUnwrap(fixture.store.loadSwitch())
        record.intendedStep = 0
        try fixture.store.update(record)
        let path = record.steps[0].temporaryPaths[0]
        let partial = Data("incomplete-target-copy".utf8)
        try partial.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let result = await fixture.restarted().recoverPending()

        XCTAssertFalse(result.didRecover)
        XCTAssertEqual(result.codex, .blocked)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), partial)
        for component in fixture.components {
            XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.original)
        }
        let retained = try XCTUnwrap(fixture.store.loadSwitch())
        XCTAssertEqual(retained.operationID, id)
        XCTAssertEqual(retained.components, record.components)
        XCTAssertEqual(retained.steps, record.steps)
        XCTAssertNil(retained.verifiedStates)
        let second = await fixture.restarted().recoverPending()
        XCTAssertFalse(second.didRecover)
        XCTAssertEqual(second.codex, .blocked)
        XCTAssertEqual(try fixture.store.loadSwitch(), retained)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), partial)
    }

    func testTargetVolumeFallbackRetainsBothOriginalsAndRollsBackOnSecondIntentFailure() async throws {
        let fixture = try switchFixture(name: "fallback", includeProfiles: false)
        fixture.recordVault.failSwitchSave(at: 3)
        do {
            try await CodexAccountSwitcher.swapAuthFiles(
                fixture.files[0], fixture.files[1], recoveryCoordinator: fixture.coordinator,
                preferAtomicExchange: false)
            XCTFail("second intent failure must fail the switch")
        } catch { XCTAssertEqual(error as? AccountSwitchError, .writeFailed) }

        for component in fixture.components {
            XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.original)
        }
        let created = try XCTUnwrap(fixture.recordVault.createdSwitch)
        XCTAssertEqual(created.components.map(\.original), fixture.components.map(\.original))
        XCTAssertEqual(created.steps.count, 2)
        for step in created.steps {
            let target = try fixture.components[step.components[0]].location.checkedFileURL()
            XCTAssertEqual(
                URL(fileURLWithPath: step.temporaryPaths[0]).deletingLastPathComponent(),
                target.deletingLastPathComponent())
        }
        XCTAssertNil(try fixture.store.loadSwitch())
    }

    func testCompletionReadbackFailureReportsRecoveryPendingWithoutRollingBackVerifiedFiles() async throws {
        let fixture = try switchFixture(name: "completion-readback", includeProfiles: false)
        fixture.recordVault.failNextCompletionReadback()

        do {
            try await CodexAccountSwitcher.swapAuthFiles(
                fixture.files[0], fixture.files[1], recoveryCoordinator: fixture.coordinator,
                preferAtomicExchange: false)
            XCTFail("an unconfirmed completion update must report recovery pending")
        } catch { XCTAssertEqual(error as? AccountSwitchError, .recoveryPending) }

        XCTAssertEqual(fixture.recordVault.failedReadCount, 1)
        let retained = try XCTUnwrap(fixture.store.loadSwitch())
        XCTAssertEqual(retained.verifiedStates, fixture.components.map(\.proposed))
        XCTAssertFalse(retained.restoring)
        XCTAssertEqual(retained.components.map(\.original), fixture.components.map(\.original))
        for component in fixture.components {
            XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.proposed)
        }
        let recovered = await fixture.restarted().recoverPending()
        XCTAssertTrue(recovered.didRecover)
        XCTAssertNil(try fixture.store.loadSwitch())
        for component in fixture.components {
            XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.proposed)
        }
    }

    func testCancelledOwnedProcessNeverStartsOrSendsCredentialInput() async throws {
        let started = root.appendingPathComponent("process-started")
        let received = root.appendingPathComponent("process-input")
        let running = OwnedProcessRun()
        running.cancel()
        let request = OwnedProcessRun.Request(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf started > process-started; /bin/cat > process-input"],
            environment: ["HOME": root.path], currentDirectory: root,
            input: Data("invented-credential-input".utf8), timeout: 1)

        let output = await BlockingWork.run { running.run(request) }

        XCTAssertNil(output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path))
    }

    func testRealHardlinkAliasesRefuseBothProvidersBeforeRecordCreation() async throws {
        for provider in [CredentialRecoveryProvider.claude, .codex] {
            let fixture = try switchFixture(name: "hardlink-\(provider.rawValue)", includeProfiles: false)
            try FileManager.default.removeItem(at: fixture.files[1])
            try FileManager.default.linkItem(at: fixture.files[0], to: fixture.files[1])
            let bytes = try Data(contentsOf: fixture.files[0])
            let components: [CredentialRecoverySwitchComponent] = fixture.files.map {
                .init(location: .file($0), original: bytes, proposed: Data("replacement".utf8))
            }
            do {
                _ = try await fixture.coordinator.beginSwitch(
                    provider: provider, accountID: nil, components: components)
                XCTFail("same device/inode must be refused")
            } catch { XCTAssertEqual(error as? CredentialRecoveryError, .changed) }
            XCTAssertNil(try fixture.store.loadSwitch())
            XCTAssertEqual(fixture.recordVault.createCount, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.files[0]), bytes)
            XCTAssertEqual(try Data(contentsOf: fixture.files[1]), bytes)
        }
    }

    func testSharedClaudeKeychainSelectionRefusesBeforeRecordOrWrite() async throws {
        let fixture = refreshFixture(original: nil)
        let payload = Data(Self.rawPayload(access: "same-account", refresh: "same-refresh", expired: false).utf8)
        let components: [CredentialRecoverySwitchComponent] = [
            .init(
                location: .claudeKeychain("fixture-service", account: "fixture"), original: payload, proposed: payload),
            .init(
                location: .claudeKeychain("fixture-service", account: "fixture"), original: payload, proposed: payload),
        ]
        do {
            _ = try await fixture.coordinator.beginSwitch(provider: .claude, accountID: nil, components: components)
            XCTFail("duplicate service selection must be refused")
        } catch { XCTAssertEqual(error as? CredentialRecoveryError, .changed) }
        XCTAssertNil(try fixture.store.loadSwitch())
        XCTAssertEqual(fixture.recordVault.createCount, 0)
    }

    func testUnknownAccountStatusAndBothSwitchSourcesAreReportedWithoutSecretPayloads() async throws {
        let refresh = refreshFixture()
        _ = try await refresh.coordinator.beginRefresh(originalPayload: refresh.original, accountID: nil)
        let status = await refresh.coordinator.status(provider: .claude, accountID: "known|workspace")
        XCTAssertNotEqual(status, .ready)
        let affected = await refresh.coordinator.affectedSources(provider: .claude)
        XCTAssertTrue(affected.includesCurrentAppVault)
        let fixture = try switchFixture(name: "status", includeProfiles: false)
        _ = try await fixture.coordinator.beginSwitch(
            provider: .codex, accountID: "selected|workspace",
            components: fixture.components, affectedAccountIDs: ["original|workspace", "selected|workspace"])
        let originalStatus = await fixture.coordinator.status(provider: .codex, accountID: "original|workspace")
        let sources = await fixture.coordinator.affectedSources(provider: .codex)
        XCTAssertNotEqual(originalStatus, .ready)
        XCTAssertEqual(sources.sourceReferences, Set(fixture.files.map { $0.deletingLastPathComponent().path }))
    }

    func testClosingAndSealCancelOwnedAsyncKeychainWriteBeforeItCommits() async throws {
        for seal in [false, true] {
            let fixture = refreshFixture(original: nil)
            let before = Data(Self.rawPayload(access: "before", refresh: "before-refresh", expired: false).utf8)
            let after = Data(Self.rawPayload(access: "after", refresh: "after-refresh", expired: false).utf8)
            let backend = RecoveryMutableKeychain(values: ["fixture-service": before])
            let started = expectation(description: "owned Keychain update suspended")
            let cancelled = RecoveryFixtureCounter()
            let delayed = RecoveryDeferredKeychainWrite(started: started, cancelled: cancelled, backend: backend)
            var keychain = backend.adapter()
            keychain.update = { service, payload in await delayed.update(service: service, payload: payload) }
            keychain.updateExact = { service, account, payload in
                guard account == "fixture" else { return false }
                return await delayed.update(service: service, payload: payload)
            }
            let coordinator = CredentialRecoveryCoordinator(
                store: fixture.store, appVault: fixture.appVault, keychain: keychain)
            let id = try await coordinator.beginSwitch(
                provider: .claude, accountID: nil,
                components: [
                    .init(
                        location: .claudeKeychain("fixture-service", account: "fixture"), original: before,
                        proposed: after)
                ])
            let applying = Task { try await coordinator.applySwitch(id) }
            await fulfillment(of: [started], timeout: 2)
            let intent = try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.switchReference)
            if seal { coordinator.sealWrites() } else { coordinator.beginClosing() }
            await delayed.finish()
            do { try await applying.value; XCTFail("closing/seal must not allow the deferred write") } catch {}
            await coordinator.releaseSwitch(id)

            XCTAssertEqual(cancelled.value, 1)
            XCTAssertEqual(backend.payload(service: "fixture-service"), before)
            XCTAssertEqual(backend.successfulWriteCount, 0)
            XCTAssertEqual(
                try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.switchReference), intent)
        }
    }

    func testClaudeProfileFailureAndFailedCredentialRollbackKeepOnlyCurrentOriginalInRecoveryRecord() async throws {
        let a = try claudeSlot("double-failure-a", access: "a-current", refresh: "a-current-refresh")
        let b = try claudeSlot("double-failure-b", access: "b-stale-file", refresh: "b-stale-refresh")
        let originalA = try Data(contentsOf: a.credentialFiles[0])
        let originalB = Data(Self.rawPayload(access: "b-current", refresh: "b-current-refresh", expired: false).utf8)
        // A user-immutable TEMP fixture profile makes the actual rename fail;
        // lock directories remain writable so restoration reaches Keychain.
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: b.profileFile.path) }
        do {
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: b.profileFile.path)
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: b.profileFile.path)
        } catch { throw XCTSkip("temporary filesystem does not support the immutable-profile failure fixture") }
        let backend = RecoveryMutableKeychain(values: [b.keychainService: originalB])
        backend.denyUpdate(service: b.keychainService, payload: originalB)
        let bService = b.keychainService
        let bProfile = b.profileFile
        backend.onAcceptedWrite { service, payload in
            if service == bService, payload == originalA {
                do { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: bProfile.path) } catch {
                    XCTFail("failed to inject immutable temp profile: \(error)")
                }
            }
        }
        let recordVault = RecoveryFixtureVault()
        let store = CredentialRecoveryStore(vault: recordVault)
        let recovery = CredentialRecoveryCoordinator(
            store: store, appVault: RecoveryFixtureClaudeVault(), keychain: backend.adapter())

        do {
            try await ClaudeAccountSwitcher.swap(a, b, keychain: backend.adapter(), recoveryCoordinator: recovery)
            XCTFail("profile write and credential restoration must fail")
        } catch { XCTAssertEqual(error as? AccountSwitchError, .rollbackFailed) }

        let retained = try XCTUnwrap(store.loadSwitch())
        XCTAssertTrue(retained.restoring)
        XCTAssertEqual(retained.components[0].original, originalA)
        XCTAssertEqual(retained.components[2].original, originalB)
        XCTAssertEqual(try Data(contentsOf: a.credentialFiles[0]), originalA)
        XCTAssertEqual(backend.payload(service: bService), originalA)
        XCTAssertNotEqual(try Data(contentsOf: b.credentialFiles[0]), originalB)
        XCTAssertTrue(backend.rejectedWriteCount > 0)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: bProfile.path)
        backend.clearDeniedUpdates()
        let restarted = CredentialRecoveryCoordinator(
            store: store, appVault: RecoveryFixtureClaudeVault(), keychain: backend.adapter())
        let result = await restarted.recoverPending()
        XCTAssertTrue(result.didRecover)
        XCTAssertEqual(backend.payload(service: bService), originalB)
        XCTAssertEqual(try Data(contentsOf: a.credentialFiles[0]), originalA)
        XCTAssertNil(try store.loadSwitch())
    }

    func testBeforeSendingFailureIsNotSentAndDoesNotCallHTTP() async throws {
        let fixture = refreshFixture()
        let id = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        let calls = RecoveryFixtureCalls()
        let refresher = successRefresher(calls)
        let credential = try XCTUnwrap(
            ClaudeCodeCredentialReader.parseCredential(
                from: fixture.original, source: .appManagedVault))
        do {
            _ = try await refresher.refresh(credential, beforeSending: { throw CancellationError() })
            XCTFail("local cancellation must not POST")
        } catch let error as ClaudeOAuthTokenRefresher.RefreshError {
            guard case .notSent = error else { return XCTFail("expected notSent, got \(error)") }
        }
        try await fixture.coordinator.finishRefreshWithoutSending(id)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertNil(try fixture.store.loadRefresh())
    }

    func testInvalidGrantPreservesOriginalRecordAndNeverDeletesFakeVault() async throws {
        let fixture = refreshFixture()
        let calls = RecoveryFixtureCalls()
        let refresher = ClaudeOAuthTokenRefresher(
            httpRunner: { request in
                calls.record(request)
                return (
                    Data(#"{"error":"invalid_grant"}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                )
            }, clientIDOverride: "fixture", cooldownInterval: 0)
        let reader = makeReader(fixture: fixture, refresher: refresher)
        let initial = try await reader.readCredential()
        XCTAssertNil(initial)
        let record = try XCTUnwrap(fixture.store.loadRefresh())
        XCTAssertEqual(record.originalPayload, fixture.original)
        XCTAssertEqual(record.phase, .started)
        await reader.invalidateCache()
        let second = try await reader.readCredential()
        XCTAssertNil(second)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
        XCTAssertEqual(fixture.appVault.deleteCount, 0)
        XCTAssertEqual(try fixture.store.loadRefresh(), record)
    }

    func testUnknownAdditionalRecordFieldIsPreservedAndCannotBeOverwritten() async throws {
        let fixture = refreshFixture()
        _ = try await fixture.coordinator.beginRefresh(originalPayload: fixture.original, accountID: nil)
        let encoded = try XCTUnwrap(
            fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["futureRecoveryPolicy"] = ["keep": true]
        let unknown = try JSONSerialization.data(withJSONObject: object)
        fixture.recordVault.inject(unknown, reference: CredentialRecoveryStore.refreshReference)
        XCTAssertThrowsError(try fixture.store.loadRefresh()) {
            XCTAssertEqual($0 as? CredentialRecoveryError, .unsupported)
        }
        let prepared = await fixture.coordinator.prepareForReset(timeout: .zero)
        XCTAssertFalse(prepared)
        XCTAssertEqual(
            try fixture.recordVault.loadPayload(reference: CredentialRecoveryStore.refreshReference), unknown)
        XCTAssertEqual(fixture.appVault.payload, fixture.original)
    }

    func testKnownSwitchResetSuspendsBothOriginalsWithoutRestoringFilesOnRestart() async throws {
        let fixture = try switchFixture(name: "switch-reset", includeProfiles: false)
        let id = try await fixture.coordinator.beginSwitch(
            provider: .codex, accountID: nil, components: fixture.components)
        await fixture.coordinator.releaseSwitch(id)
        let prepared = await fixture.coordinator.prepareForReset(timeout: .zero)
        XCTAssertTrue(prepared)
        let suspended = try XCTUnwrap(fixture.store.loadSwitch())
        XCTAssertFalse(suspended.automaticRecoveryAllowed)
        XCTAssertEqual(suspended.components.map(\.original), fixture.components.map(\.original))
        _ = await fixture.restarted().recoverPending()
        XCTAssertEqual(try fixture.store.loadSwitch(), suspended)
        for component in fixture.components {
            XCTAssertEqual(try CredentialRecoveryFile.read(component.location), component.original)
        }
    }

    private struct RefreshFixture: Sendable {
        let recordVault: RecoveryFixtureVault
        let store: CredentialRecoveryStore
        let appVault: RecoveryFixtureClaudeVault
        let coordinator: CredentialRecoveryCoordinator
        let original: String
        func restarted() -> CredentialRecoveryCoordinator {
            CredentialRecoveryCoordinator(store: store, appVault: appVault, keychain: .none)
        }
    }

    private func refreshFixture() -> RefreshFixture {
        refreshFixture(original: Self.managedPayload())
    }

    private func refreshFixture(original originalPayload: String?) -> RefreshFixture {
        let recordVault = RecoveryFixtureVault()
        let store = CredentialRecoveryStore(vault: recordVault)
        let appVault = RecoveryFixtureClaudeVault(payload: originalPayload)
        return RefreshFixture(
            recordVault: recordVault, store: store, appVault: appVault,
            coordinator: CredentialRecoveryCoordinator(store: store, appVault: appVault, keychain: .none),
            original: originalPayload ?? Self.managedPayload())
    }

    private struct SwitchFixture: Sendable {
        let recordVault: RecoveryFixtureVault
        let store: CredentialRecoveryStore
        let coordinator: CredentialRecoveryCoordinator
        let files: [URL]
        let components: [CredentialRecoverySwitchComponent]
        func restarted() -> CredentialRecoveryCoordinator {
            CredentialRecoveryCoordinator(store: store, appVault: RecoveryFixtureClaudeVault(), keychain: .none)
        }
    }

    private func switchFixture(name: String, includeProfiles: Bool) throws -> SwitchFixture {
        var files: [URL] = []
        var components: [CredentialRecoverySwitchComponent] = []
        for slotName in ["a", "b"] {
            let directory = root.appendingPathComponent(name + "-" + slotName + "-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let credential = directory.appendingPathComponent("auth.json")
            let original = Data(
                Self.rawPayload(access: "\(slotName)-access", refresh: "\(slotName)-refresh", expired: false).utf8)
            let other = slotName == "a" ? "b" : "a"
            let proposed = Data(
                Self.rawPayload(access: "\(other)-access", refresh: "\(other)-refresh", expired: false).utf8)
            try original.write(to: credential)
            files.append(credential)
            components.append(.init(location: .file(credential), original: original, proposed: proposed))
            if includeProfiles {
                let profile = directory.appendingPathComponent(".claude.json")
                let before = Data("{\"oauthAccount\":{\"accountUuid\":\"\(slotName)\"},\"theme\":\"fixture\"}".utf8)
                let after = Data("{\"oauthAccount\":{\"accountUuid\":\"\(other)\"},\"theme\":\"fixture\"}".utf8)
                try before.write(to: profile)
                files.append(profile)
                components.append(.init(location: .file(profile), original: before, proposed: after))
            }
        }
        let recordVault = RecoveryFixtureVault()
        let store = CredentialRecoveryStore(vault: recordVault)
        return SwitchFixture(
            recordVault: recordVault, store: store,
            coordinator: CredentialRecoveryCoordinator(
                store: store, appVault: RecoveryFixtureClaudeVault(), keychain: .none),
            files: files, components: components)
    }

    private func claudeSlot(_ name: String, access: String, refresh: String) throws -> ClaudeCodeLoginSlot {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.rawPayload(access: access, refresh: refresh, expired: false).utf8)
            .write(to: directory.appendingPathComponent(".credentials.json"))
        let profile = directory.appendingPathComponent(".claude.json")
        try Data("{\"oauthAccount\":{\"emailAddress\":\"\(name)@example.invalid\"},\"theme\":\"fixture\"}".utf8).write(
            to: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
        return ClaudeCodeLoginSlot(
            configDirectory: directory, profileFile: profile,
            keychainService: "fixture.\(name)", keychainMatch: .configDirectoryValue(directory.path))
    }

    private func makeReader(
        fixture: RefreshFixture, coordinator: CredentialRecoveryCoordinator? = nil,
        refresher: ClaudeOAuthTokenRefresher? = nil, clock: RecoveryFixtureClock = RecoveryFixtureClock(),
        cli: @escaping ClaudeCodeCredentialReader.CLIKeychainPayloadReader = { _ in .notFound },
        interactive: @escaping ClaudeCodeCredentialReader.InteractiveKeychainPayloadReader = { _, _, _ in
            XCTFail("unexpected interactive read")
            return .cancelled
        },
        cliRefresher: @escaping ClaudeCodeCredentialReader.CLIRefresher = { _ in
            XCTFail("external CLI must not run"); return .unavailable
        }
    ) -> ClaudeCodeCredentialReader {
        let home = root.appendingPathComponent("home-\(UUID().uuidString)")
        return ClaudeCodeCredentialReader(
            homeDirectory: home,
            claudeConfigDirectory: home.appendingPathComponent(".claude"), profileMetadataStore: nil,
            tokenRefresher: refresher
                ?? ClaudeOAuthTokenRefresher(
                    httpRunner: { _ in
                        XCTFail("unexpected HTTP refresh")
                        throw URLError(.cancelled)
                    }, clientIDOverride: "fixture"),
            appCredentialVault: fixture.appVault, cacheTTL: 60, now: { clock.now },
            interactiveKeychainPayloadReader: interactive, cliKeychainPayloadReader: cli,
            cliRefresher: cliRefresher,
            recoveryCoordinator: coordinator ?? fixture.coordinator)
    }

    private func successRefresher(_ calls: RecoveryFixtureCalls) -> ClaudeOAuthTokenRefresher {
        ClaudeOAuthTokenRefresher(
            httpRunner: { request in
                calls.record(request)
                return (
                    Data(Self.refreshResponse.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }, clientIDOverride: "fixture-public-client")
    }

    private static let refreshResponse =
        #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#

    private static func rawPayload(
        access: String = "original-access", refresh: String = "original-refresh", expired: Bool = true
    ) -> String {
        // Fixed timestamps keep separately constructed originals byte-identical.
        let expiration = expired ? "1000000000000" : "4102444800000"
        return
            "{\"claudeAiOauth\":{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\",\"expiresAt\":\(expiration),\"scope\":\"fixture-extra-field\"},\"fixtureRoot\":true}"
    }

    private static func managedPayload(
        access: String = "original-access", refresh: String = "original-refresh", expired: Bool = true
    ) -> String {
        ClaudeOAuthCredentialVaultPayload.encode(
            credentialPayload: rawPayload(access: access, refresh: refresh, expired: expired), ownership: .appManaged)!
    }
}

private enum RecoveryFixtureError: Error { case expected }

private final class RecoveryRejectNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("blocked credential generation must never reach real HTTP")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

private final class RecoveryFixtureVault: OAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var readFailures: Set<String> = []
    private var remainingReadFailures: [String: Int] = [:]
    private var failedReads = 0
    private var successorFailures = 0
    private var switchSaveFailure: Int?
    private var completionReadbackFailure = false
    private var switchSaves = 0
    private var saves = 0
    private var creates = 0
    private var createdSwitchData: Data?
    var saveCount: Int { lock.withLock { saves } }
    var createCount: Int { lock.withLock { creates } }
    var failedReadCount: Int { lock.withLock { failedReads } }
    var createdSwitch: CredentialRecoverySwitchRecord? {
        lock.withLock {
            createdSwitchData.flatMap { try? JSONDecoder().decode(CredentialRecoverySwitchRecord.self, from: $0) }
        }
    }
    func inject(_ data: Data, reference: String) { lock.withLock { values[reference] = data } }
    func failSuccessorWrites(_ count: Int) { lock.withLock { successorFailures = count } }
    func failSwitchSave(at count: Int) { lock.withLock { switchSaveFailure = count } }
    func failNextCompletionReadback() { lock.withLock { completionReadbackFailure = true } }
    func failNextReads(_ reference: String, count: Int) { lock.withLock { remainingReadFailures[reference] = count } }
    func setReadFailure(_ reference: String, enabled: Bool) {
        lock.withLock {
            if enabled { readFailures.insert(reference) } else { readFailures.remove(reference) }
        }
    }
    func loadPayload(reference: String) throws -> Data? {
        try lock.withLock {
            if readFailures.contains(reference) { throw RecoveryFixtureError.expected }
            if let remaining = remainingReadFailures[reference], remaining > 0 {
                remainingReadFailures[reference] = remaining - 1
                failedReads += 1
                throw RecoveryFixtureError.expected
            }
            return values[reference]
        }
    }
    func createIfAbsent(_ payload: Data, reference: String) throws -> Bool {
        lock.withLock {
            guard values[reference] == nil else { return false }
            creates += 1
            values[reference] = payload
            if reference == CredentialRecoveryStore.switchReference { createdSwitchData = payload }
            return true
        }
    }
    func savePayload(_ payload: Data, reference: String) throws {
        try lock.withLock {
            saves += 1
            if reference == CredentialRecoveryStore.switchReference {
                switchSaves += 1
                if switchSaveFailure == switchSaves { throw RecoveryFixtureError.expected }
            }
            if reference == CredentialRecoveryStore.refreshReference, successorFailures > 0,
                let record = try? JSONDecoder().decode(CredentialRecoveryRefreshRecord.self, from: payload),
                record.phase == .successor
            {
                successorFailures -= 1
                throw RecoveryFixtureError.expected
            }
            values[reference] = payload
            if reference == CredentialRecoveryStore.switchReference, completionReadbackFailure,
                let record = try? JSONDecoder().decode(CredentialRecoverySwitchRecord.self, from: payload),
                record.verifiedStates != nil
            {
                completionReadbackFailure = false
                remainingReadFailures[reference] = 1
            }
        }
    }
    func deletePayload(reference: String) throws { lock.withLock { _ = values.removeValue(forKey: reference) } }
    func references(in namespace: OAuthCredentialVaultNamespace) throws -> Set<String> {
        lock.withLock { Set(values.keys.filter(namespace.contains)) }
    }
}

private final class RecoveryFixtureClaudeVault: ClaudeOAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var failures = 0
    private var saves = 0
    private var deletes = 0
    init(payload: String? = nil) { value = payload }
    var payload: String? { lock.withLock { value } }
    var saveCount: Int { lock.withLock { saves } }
    var deleteCount: Int { lock.withLock { deletes } }
    func failNextSaves(_ count: Int) { lock.withLock { failures = count } }
    func loadPayload() throws -> String? { lock.withLock { value } }
    func savePayload(_ payload: String) throws {
        try lock.withLock {
            saves += 1
            if failures > 0 { failures -= 1; throw RecoveryFixtureError.expected }
            value = payload
        }
    }
    func deletePayload() throws {
        lock.withLock {
            deletes += 1; value = nil
        }
    }
}

private final class RecoveryFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private final class RecoveryFixtureCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var count: Int { lock.withLock { requests.count } }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

private final class RecoveryFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor RecoveryDeferredCLI {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<ClaudeCodeKeychainCLI.Outcome, Never>?
    private var result: ClaudeCodeKeychainCLI.Outcome?
    init(started: XCTestExpectation) { self.started = started }
    func read(_ service: String) async -> ClaudeCodeKeychainCLI.Outcome {
        if let result { return result }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish(_ outcome: ClaudeCodeKeychainCLI.Outcome) {
        result = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor RecoveryDeferredHTTP {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var result: (Data, URLResponse)?
    private var url = URL(string: "https://fixture.invalid/token")!
    init(started: XCTestExpectation) { self.started = started }
    func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        url = request.url ?? url
        if let result { return result }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish(body: String) {
        let response: (Data, URLResponse) = (
            Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
        result = response
        continuation?.resume(returning: response)
        continuation = nil
    }
}

private final class RecoveryMutableKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    private var writes = 0
    private var denied: [String: Data] = [:]
    private var rejected = 0
    private var acceptedWrite: (@Sendable (String, Data) -> Void)?
    init(values: [String: Data]) { self.values = values }
    var successfulWriteCount: Int { lock.withLock { writes } }
    var rejectedWriteCount: Int { lock.withLock { rejected } }
    func denyUpdate(service: String, payload: Data) { lock.withLock { denied[service] = payload } }
    func clearDeniedUpdates() { lock.withLock { denied.removeAll() } }
    func onAcceptedWrite(_ callback: @escaping @Sendable (String, Data) -> Void) {
        lock.withLock { acceptedWrite = callback }
    }
    func payload(service: String) -> Data? { lock.withLock { values[service] } }
    func read(service: String) -> ClaudeCodeKeychainCLI.Outcome {
        lock.withLock { values[service].map { .payload(String(decoding: $0, as: UTF8.self)) } ?? .notFound }
    }
    func update(service: String, payload: Data) -> Bool {
        let result: (Bool, (@Sendable (String, Data) -> Void)?) = lock.withLock {
            if denied[service] == payload { rejected += 1; return (false, nil) }
            values[service] = payload
            writes += 1
            return (true, acceptedWrite)
        }
        if result.0 { result.1?(service, payload) }
        return result.0
    }
    func adapter() -> ClaudeCodeKeychain {
        var result = ClaudeCodeKeychain.none
        result.accountName = { _ in "fixture" }
        result.read = { service in self.read(service: service) }
        result.readExact = { service, account in
            account == "fixture" ? self.read(service: service) : .notFound
        }
        result.update = { service, payload in
            guard !Task.isCancelled else { return false }
            return self.update(service: service, payload: payload)
        }
        result.updateExact = { service, account, payload in
            guard account == "fixture", !Task.isCancelled else { return false }
            return self.update(service: service, payload: payload)
        }
        result.updateDirectly = { _, _ in
            XCTFail("no direct/system Keychain fallback"); return false
        }
        result.readInteractively = { _, _ in
            XCTFail("no interactive Keychain during recovery"); return .cancelled
        }
        return result
    }
}

private actor RecoveryDeferredKeychainWrite {
    let started: XCTestExpectation
    let cancelled: RecoveryFixtureCounter
    let backend: RecoveryMutableKeychain
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    init(started: XCTestExpectation, cancelled: RecoveryFixtureCounter, backend: RecoveryMutableKeychain) {
        self.started = started
        self.cancelled = cancelled
        self.backend = backend
    }
    func update(service: String, payload: Data) async -> Bool {
        let counter = cancelled
        return await withTaskCancellationHandler {
            if !finished {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            guard !Task.isCancelled else { return false }
            return backend.update(service: service, payload: payload)
        } onCancel: {
            counter.increment()
        }
    }
    func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
