import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeWebSessionRecoveryTests: XCTestCase {
    private let identity = UsageAccountIdentity(
        accountID: "nathan", organizationID: "team", email: "nathan@example.com", organizationName: "Team")
    private let origin = ClaudeBrowserSource(family: .chrome, profileName: "Profile 2")
    private var validation: ClaudeValidatedWebSession {
        .init(usage: .init(fiveHour: .init(utilization: 12, resetsAt: nil), sevenDay: nil), identity: identity)
    }

    private func request(
        source: ClaudeAccountSource? = .chromeProfile, known: Bool = true,
        origin: ClaudeBrowserSource? = nil
    ) -> ClaudeWebSessionRecoveryCoordinator.Request {
        .init(
            account: .init(
                id: id("old"), kind: .webSession, displayName: "Chrome Nathan",
                identity: .init(email: "display-only@example.com", organizationID: "team"),
                source: source, browserSource: origin),
            expectedIdentity: known ? identity : nil, previousAccountID: "claude:web:old")
    }

    private func id(_ key: String) -> String {
        ClaudeAccountStore.webSessionAccountID(fingerprint: ClaudeAccountStore.fingerprint(for: key))
    }

    private func dependencies(_ probe: RecoveryProbe, gate: RecoveryGate? = nil)
        -> ClaudeWebSessionRecoveryCoordinator.Dependencies
    {
        let validation = validation
        let origin = origin
        return .init(
            load: { _ in
                probe.record("load"); return probe.saved
            },
            importSession: { source in
                probe.record("import:\(source.profileName)")
                if let error = probe.importError { throw error }
                return .importedSession(
                    .init(family: source.family, profileName: source.profileName, sessionKey: "new"))
            },
            validate: { key, _ in
                probe.record("validate:\(key)")
                if let gate { await gate.wait() }
                if let error = probe.validationError { throw error }
                return probe.validation ?? validation
            },
            selectSource: {
                probe.record("select"); return probe.selected ? origin : nil
            },
            confirmIdentity: { _ in
                probe.record("confirm"); return probe.confirmed
            },
            isCurrent: { _ in probe.current },
            commit: { _, candidate in
                probe.record("commit:\(candidate.sessionKey)")
            })
    }

    func testOriginalProfileOnlyAndRejectedStoredKeyIsNotRetried() async throws {
        let probe = RecoveryProbe()
        let coordinator = ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe))
        try await coordinator.recover(request(origin: origin))
        XCTAssertEqual(probe.events, ["load", "import:Profile 2", "validate:new", "commit:new"])
    }

    func testUpdatedAppStoreIsUsedBeforeReadingBrowser() async throws {
        let probe = RecoveryProbe(saved: "saved-new")
        try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(
            request(origin: origin))
        XCTAssertEqual(probe.events, ["load", "validate:saved-new", "commit:saved-new"])
    }

    func testOtherAccountOrOrganizationCannotReplaceOriginal() async {
        for owner in [
            UsageAccountIdentity(accountID: "hannah", organizationID: "team", email: identity.email),
            UsageAccountIdentity(accountID: "nathan", organizationID: "other", email: identity.email),
        ] {
            let probe = RecoveryProbe()
            probe.validation = .init(usage: validation.usage, identity: owner)
            do {
                try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(
                    request(origin: origin))
                XCTFail("Mismatched owner must be rejected")
            } catch {
                guard case .differentAccount = error as? ClaudeWebSessionRecoveryCoordinator.Failure else {
                    return XCTFail("\(error)")
                }
            }
            XCTAssertFalse(probe.events.contains { $0.hasPrefix("commit") })
        }
    }

    func testLegacyConnectionSelectsProfileAndConfirmsActualOwner() async throws {
        let probe = RecoveryProbe()
        try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(request(known: false))
        XCTAssertEqual(probe.events, ["load", "select", "import:Profile 2", "validate:new", "confirm", "commit:new"])
    }

    func testConnectionsWithoutKnownLoginMethodSelectProfileBeforeConfirmingOwner() async throws {
        let sources: [ClaudeAccountSource?] = [nil, .legacyMigration]
        for source in sources {
            let probe = RecoveryProbe()
            try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(
                request(source: source, known: false))
            XCTAssertEqual(
                probe.events, ["load", "select", "import:Profile 2", "validate:new", "confirm", "commit:new"])
        }
    }

    func testVerifiedBrowserOriginControlsSourceLabel() {
        let account = ClaudeAccount(
            id: "web", kind: .webSession, displayName: "Legacy",
            source: .chromeProfile, sourceDetail: "Chrome Default",
            browserSource: .init(family: .firefox, profileName: "opaque-default"))
        XCTAssertEqual(ClaudeAccountSettingsPresentation.resolve(account: account).sourceLabel, "Firefox")
    }

    func testLegacyOwnerConfirmationCancellationKeepsOriginal() async {
        let probe = RecoveryProbe()
        probe.confirmed = false
        do {
            try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(
                request(known: false))
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(probe.events.contains { $0.hasPrefix("commit") })
    }

    func testManualAndEmbeddedConnectionsNeverImportBrowser() async {
        for source in [ClaudeAccountSource.manualInput, .embeddedWebLogin] {
            let probe = RecoveryProbe()
            do {
                try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(
                    request(source: source))
                XCTFail()
            } catch { XCTAssertNotNil(error as? ClaudeWebSessionRecoveryCoordinator.Failure) }
            XCTAssertEqual(probe.events, ["load"])
        }
    }

    func testRateLimitAndPermissionFailureDoNotImportFromAnotherSource() async {
        for error in [
            APIError.rateLimited(retryAfter: 42), .permissionDenied("team"), .networkError("offline"),
            .cloudflareBlocked(retryAfter: nil),
        ] {
            let probe = RecoveryProbe(saved: "saved-new")
            probe.validationError = error
            do {
                try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe)).recover(
                    request(origin: origin))
                XCTFail()
            } catch {}
            XCTAssertEqual(probe.events, ["load", "validate:saved-new"])
        }
    }

    func testRepeatedClicksShareOneImportAndValidation() async throws {
        let probe = RecoveryProbe()
        let gate = RecoveryGate()
        let coordinator = ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe, gate: gate))
        let request = request(origin: origin)
        let first = Task { try await coordinator.recover(request) }
        await gate.waitUntilEntered()
        let second = Task { try await coordinator.recover(request) }
        await Task.yield()
        await gate.release()
        try await first.value
        try await second.value
        XCTAssertEqual(probe.events.filter { $0.hasPrefix("import") }.count, 1)
        XCTAssertEqual(probe.events.filter { $0.hasPrefix("commit") }.count, 1)
    }

    func testClosingCallerCancelsRecoveryWithoutExplicitCoordinatorCancel() async {
        let probe = RecoveryProbe()
        let gate = RecoveryGate()
        let coordinator = ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe, gate: gate))
        let request = request(origin: origin)
        let caller = Task { try await coordinator.recover(request, sessionKey: "new") }
        await gate.waitUntilEntered()
        caller.cancel()
        await gate.release()
        do { try await caller.value; XCTFail("Cancelled caller must not replace the connection") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(probe.events.contains { $0.hasPrefix("commit") })
    }

    func testRetryImmediatelyAfterCallerCancellationStartsNewWork() async throws {
        let probe = RecoveryProbe()
        let gate = RecoveryGate()
        var dependencies = dependencies(probe)
        let validation = validation
        dependencies.validate = { _, _ in
            probe.record("validate")
            if probe.events.filter({ $0 == "validate" }).count == 1 { await gate.wait() }
            return validation
        }
        let coordinator = ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies)
        let request = request(origin: origin)
        let first = Task { try await coordinator.recover(request, sessionKey: "new") }
        await gate.waitUntilEntered()
        first.cancel()
        let second = Task { try await coordinator.recover(request, sessionKey: "new") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while probe.events.filter({ $0 == "validate" }).count < 2, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(probe.events.filter({ $0 == "validate" }).count, 2)
        await gate.release()
        do { try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        try await second.value
        XCTAssertEqual(probe.events.filter { $0.hasPrefix("commit") }, ["commit:new"])
    }

    func testNewExplicitKeyCancelsOlderCandidateInsteadOfCoalescingIt() async throws {
        let probe = RecoveryProbe()
        let gate = RecoveryGate()
        var dependencies = dependencies(probe)
        let validation = validation
        dependencies.validate = { key, _ in
            probe.record("validate:\(key)")
            if key == "first" { await gate.wait() }
            return validation
        }
        let coordinator = ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies)
        let request = request(origin: origin)
        let first = Task { try await coordinator.recover(request, sessionKey: "first") }
        await gate.waitUntilEntered()
        try await coordinator.recover(request, sessionKey: "second")
        await gate.release()
        do { try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.events.filter { $0.hasPrefix("commit") }, ["commit:second"])
    }

    func testExplicitAccountAdditionBypassesExpiredOrPendingRecovery() {
        for pending in [false, true] {
            for failed in [false, true] {
                XCTAssertFalse(
                    ClaudeWebSessionSaveIntent.addAccount.shouldRecover(
                        hasPendingRequest: pending, authenticationFailed: failed))
                XCTAssertEqual(
                    ClaudeWebSessionSaveIntent.recoverExisting.shouldRecover(
                        hasPendingRequest: pending, authenticationFailed: failed), pending || failed)
            }
        }
    }

    func testMergedRowRecoversActiveWebConnectionBeforeOlderProfile() throws {
        let old = UsageAccountSource(role: .web, reference: "old")
        let active = UsageAccountSource(role: .web, reference: "active")
        let row = try XCTUnwrap(
            UsageAccount.merge(
                [.init(source: old, identity: identity), .init(source: active, identity: identity)], service: .claude
            ).first)
        XCTAssertEqual(ClaudeUsageAccountProvider.webRecoveryReference(in: row, activeAccountID: "active"), "active")
        XCTAssertEqual(ClaudeUsageAccountProvider.webRecoveryReference(in: row, activeAccountID: "unrelated"), "old")
    }

    func testExpiredRuntimeCLIInMergedRowCannotSelectAHealthyWebConnectionForRecovery() throws {
        let row = try XCTUnwrap(
            UsageAccount.merge(
                [
                    .init(source: .init(role: .web, reference: "web-healthy"), identity: identity),
                    .init(source: .init(role: .defaultLogin, reference: "/fixture/cli"), identity: identity),
                ], service: .claude
            ).first)
        XCTAssertNil(
            ClaudeUsageAccountProvider.webRecoveryReference(
                in: row, activeAccountID: ClaudeAccountStore.claudeCodeExternalAccountID))
        let separateWebRow = try XCTUnwrap(
            UsageAccount.merge(
                [
                    .init(
                        source: .init(role: .web, reference: "web-expired-other-owner"),
                        identity: .init(accountID: "other", organizationID: "team"))
                ], service: .claude
            ).first)
        XCTAssertEqual(
            ClaudeUsageAccountProvider.webRecoveryReference(
                in: separateWebRow,
                activeAccountID: ClaudeAccountStore.claudeCodeExternalAccountID), "web-expired-other-owner")
    }

    func testFirstWebUUIDMergePreservesPreferencesWithExistingCanonicalAlias() throws {
        let suite = "ClaudeWebFirstMerge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = UsageAccountSource(role: .web, reference: "web")
        let oldID = "claude:web:web"
        let target = "claude:nathan|team"
        var preferences = UsageAccountPreferences()
        preferences.aliases[oldID] = "Old web alias"
        preferences.aliases[target] = "Existing CLI alias"
        preferences.order = [oldID, target]
        preferences[.claude].selected = [oldID, target]
        preferences[.claude].pinnedTop = oldID
        XCTAssertTrue(preferences.commit(to: defaults, intent: .automatic).accepted)
        let controller = UsageAccountsController(providers: [], defaults: defaults, isServiceEnabled: { _ in true })
        controller.bindRuntimeAccount(
            .init(source: source, identity: .init(organizationID: "team", email: "profile-label@example.com")),
            for: .claude)
        controller.bindRuntimeAccount(
            .init(source: .init(role: .defaultLogin, reference: "/fixture"), identity: identity), for: .claude)
        controller.bindRuntimeAccount(.init(source: source, identity: identity), for: .claude)
        XCTAssertEqual(controller.accounts[.claude]?.count, 1)
        XCTAssertEqual(controller.preferences.aliases[target], "Existing CLI alias")
        XCTAssertNil(controller.preferences.aliases[oldID])
        XCTAssertEqual(controller.preferences.order, [target])
        XCTAssertEqual(controller.preferences[.claude].selected, [target])
        XCTAssertEqual(controller.preferences[.claude].pinnedTop, target)
    }

    func testLateResponseAfterAccountChangeOrCancellationIsNotSaved() async {
        for cancelled in [false, true] {
            let probe = RecoveryProbe()
            let gate = RecoveryGate()
            let coordinator = ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies(probe, gate: gate))
            let request = request(origin: origin)
            let task = Task { try await coordinator.recover(request) }
            await gate.waitUntilEntered()
            if cancelled { coordinator.cancel() } else { probe.current = false }
            await gate.release()
            do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(probe.events.contains { $0.hasPrefix("commit") })
        }
    }

    func testFreshValidatedIdentitySurvivesWithoutKnownIdentityAndMergesOnlyUUIDAndOrganization() throws {
        let candidate = try XCTUnwrap(
            ClaudeUsageAccountProvider.runtimeAccount(
                provenance: .init(source: .webSession, accountID: "web", attemptedSources: [.webSession]),
                validatedIdentity: identity, resolvedOrganizationID: "team", knownIdentities: [:]))
        XCTAssertEqual(candidate.identity, identity)
        let cli = UsageAccountCandidate(source: .init(role: .defaultLogin, reference: "/fixture"), identity: identity)
        XCTAssertEqual(UsageAccount.merge([candidate, cli], service: .claude).count, 1)
        for other in [
            UsageAccountIdentity(accountID: "other", organizationID: "team", email: identity.email),
            UsageAccountIdentity(accountID: "nathan", organizationID: "other", email: identity.email),
        ] {
            XCTAssertEqual(
                UsageAccount.merge([candidate, .init(source: cli.source, identity: other)], service: .claude).count, 2)
        }
    }

    func testReplacementPreservesAliasesSelectionPinAndUnrelatedCLIIdentity() throws {
        let vault = RecoveryVault()
        let suite = "ClaudeWebRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: false)
        let account = store.upsertWebSessionAccount(
            sessionKey: "old", preferredOrganizationID: "team", source: .chromeProfile)
        try vault.saveString("old", account: ClaudeKeychainStore.accountName(for: account.id))
        var preferences = UsageAccountPreferences()
        let oldID = "claude:web:\(account.id)"
        let destination = "claude:nathan|team"
        preferences.aliases[oldID] = "Previous alias"
        preferences.aliases[destination] = "Keep this alias"
        preferences.order = [oldID, "cli", destination]
        preferences[.claude].selected = [oldID, destination]
        preferences[.claude].pinnedTop = oldID
        preferences.knownIdentities[account.id] = identity
        preferences.knownIdentities["cli"] = .init(accountID: "hannah", organizationID: "team")
        XCTAssertTrue(preferences.commit(to: defaults, intent: .automatic).accepted)
        let replacement = try ClaudeWebSessionReplacement(store: store, vault: vault).replace(
            account: account, sessionKey: "new", validation: validation,
            origin: .init(source: .chromeProfile, sourceDetail: "프로필 2 (Profile 2)", browserSource: origin),
            expectedPreferences: preferences, previousAccountID: oldID)
        let restored = UsageAccountPreferences.load(from: defaults)
        XCTAssertEqual(restored.aliases[destination], "Keep this alias")
        XCTAssertNil(restored.aliases[oldID])
        XCTAssertEqual(restored.order, [destination, "cli"])
        XCTAssertEqual(restored[.claude].selected, [destination])
        XCTAssertEqual(restored[.claude].pinnedTop, destination)
        XCTAssertEqual(restored.knownIdentities["cli"]?.accountID, "hannah")
        XCTAssertEqual(store.activeAccount()?.id, replacement.id)
        XCTAssertEqual(store.activeAccount()?.userSelectedPreferredOrganizationID, "team")
        XCTAssertNil(try vault.loadString(account: ClaudeKeychainStore.accountName(for: account.id)))
        XCTAssertEqual(
            ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: false).activeAccount()?
                .browserSource, origin)
    }

    func testFailedWriteOrChangedSelectionKeepsOldCredentialAndPreferences() throws {
        for failWrite in [false, true] {
            let vault = RecoveryVault()
            let suite = "ClaudeWebRollback.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: false)
            let account = store.upsertWebSessionAccount(sessionKey: "old")
            try vault.saveString("old", account: ClaudeKeychainStore.accountName(for: account.id))
            let preferences = UsageAccountPreferences.load(from: defaults)
            if failWrite {
                vault.rejectWrites = true
            } else {
                _ = store.upsertClaudeCodeExternalAccount();
                store.setActiveAccountID(ClaudeAccountStore.claudeCodeExternalAccountID)
            }
            XCTAssertThrowsError(
                try ClaudeWebSessionReplacement(store: store, vault: vault).replace(
                    account: account, sessionKey: "new", validation: validation,
                    origin: .init(source: .chromeProfile, sourceDetail: "프로필 2 (Profile 2)", browserSource: origin),
                    expectedPreferences: preferences, previousAccountID: "old"))
            XCTAssertNotNil(store.accounts().first { $0.id == account.id })
            XCTAssertEqual(try vault.loadString(account: ClaudeKeychainStore.accountName(for: account.id)), "old")
            XCTAssertEqual(UsageAccountPreferences.load(from: defaults), preferences)
            XCTAssertNil(try vault.loadString(account: ClaudeKeychainStore.accountName(for: id("new"))))
        }
    }

    func testReplacementTakesEverySourceValueFromTheNewSession() throws {
        let aside = ClaudeBrowserImportedSession(family: .aside, profileName: "Profile 1", sessionKey: "new")
        for origin in [aside.origin, ClaudeWebSessionOrigin(source: .embeddedWebLogin)] {
            let vault = RecoveryVault()
            let suite = "ClaudeWebOrigin.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: false)
            let account = store.upsertWebSessionAccount(
                sessionKey: "old", preferredOrganizationID: "team", displayName: "Claude 앱", source: .chromeProfile,
                sourceDetail: "Claude 앱")
            store.setBrowserSource(.init(family: .claudeApp, profileName: "Default"), for: account.id)
            try vault.saveString("old", account: ClaudeKeychainStore.accountName(for: account.id))
            let stored = try XCTUnwrap(store.accounts().first { $0.id == account.id })

            let replacement = try ClaudeWebSessionReplacement(store: store, vault: vault).replace(
                account: stored, sessionKey: "new", validation: validation, origin: origin,
                expectedPreferences: UsageAccountPreferences.load(from: defaults),
                previousAccountID: "claude:web:\(account.id)")

            let saved = try XCTUnwrap(store.accounts().first { $0.id == replacement.id })
            XCTAssertEqual(saved.source, origin.source)
            XCTAssertEqual(saved.sourceDetail, origin.sourceDetail)
            XCTAssertEqual(saved.browserSource, origin.browserSource)
            XCTAssertEqual(saved.displayName, origin.displayName ?? identity.email)
        }
    }

    func testBrowserFamilyPrefersBrowserSourceOverStaleDetail() {
        let mismatched = ClaudeAccount(
            id: id("aside"), kind: .webSession, displayName: "Claude 앱", source: .chromeProfile,
            sourceDetail: "Claude 앱", browserSource: .init(family: .aside, profileName: "Profile 1"))
        let legacy = ClaudeAccount(
            id: id("legacy"), kind: .webSession, displayName: "Brave", source: .chromeProfile,
            sourceDetail: "Brave 프로필 2 (Profile 2)")

        XCTAssertEqual(mismatched.browserFamily, .aside)
        XCTAssertEqual(legacy.browserFamily, .brave)
    }

    func testCommitCarriesWhereTheNewSessionCameFrom() async throws {
        let probe = RecoveryProbe()
        var dependencies = dependencies(probe)
        dependencies.commit = { _, candidate in
            let origin = candidate.origin
            probe.record("commit:\(origin.browserSource?.family.rawValue ?? "-"):\(origin.sourceDetail ?? "-")")
        }
        let aside = ClaudeWebSessionOrigin(
            source: .chromeProfile, sourceDetail: "Aside 프로필 1 (Profile 1)",
            browserSource: .init(family: .aside, profileName: "Profile 1"))

        try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies).recover(
            request(origin: origin), sessionKey: "new", origin: aside)
        try await ClaudeWebSessionRecoveryCoordinator(dependencies: dependencies).recover(request(origin: origin))

        XCTAssertEqual(
            probe.events.filter { $0.hasPrefix("commit") },
            ["commit:aside:Aside 프로필 1 (Profile 1)", "commit:chrome:프로필 2 (Profile 2)"])
    }

    func testLegacyAccountDecodesWithoutBrowserOrigin() throws {
        let account = request().account
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        json["browserSource"] = nil
        let decoded = try JSONDecoder().decode(ClaudeAccount.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.browserSource)
        XCTAssertEqual(decoded.id, account.id)
    }

    func testMainValidationUsesActualAccountParserAndPersistsIdentityWithMultipleAccountsOff() async throws {
        let suite = "ClaudeWebIdentity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ClaudeAPIService(
            sessionKey: "fixture",
            cacheStorage: .init(
                defaults: defaults,
                profileMetadataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)),
            httpRunner: { request in
                let url = request.url!
                let body: String
                if url.path == "/api/account" {
                    body =
                        #"{"uuid":"nathan","email_address":"nathan@example.com","memberships":[{"organization":{"uuid":"team","name":"Team"}}]}"#
                } else if url.path == "/api/organizations" {
                    body = #"[{"uuid":"team","name":"Team"}]"#
                } else {
                    body = #"{"five_hour":{"utilization":12}}"#
                }
                return (
                    Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        await service.updatePreferredOrganizationID("team")
        _ = try await service.validateCurrentSessionUsage()
        let observed = await service.resolvedSessionIdentityForLastValidation()
        XCTAssertEqual(observed, identity)
        let controller = UsageAccountsController(providers: [], defaults: defaults, isServiceEnabled: { _ in true })
        XCTAssertFalse(controller.isMultiAccountEnabled(.claude))
        controller.bindRuntimeAccount(
            .init(source: .init(role: .web, reference: "web"), identity: identity), for: .claude)
        XCTAssertEqual(UsageAccountPreferences.load(from: defaults).knownIdentities["web"], identity)
    }

    func testDiscoveryAdoptsIdentitySavedByLoginVerification() async throws {
        let suite = "ClaudeWebPreferenceRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UsageAccountsController(providers: [], defaults: defaults, isServiceEnabled: { _ in true })
        var externallySaved = UsageAccountPreferences.load(from: defaults)
        externallySaved.knownIdentities["web"] = identity
        XCTAssertTrue(externallySaved.commit(to: defaults, intent: .automatic).accepted)
        await controller.discoverAndWait()
        XCTAssertEqual(controller.preferences.knownIdentities["web"], identity)
    }

    func testTargetedImportNeverReadsAnotherProfileOrRequestsPermissionWhenMissing() throws {
        let probe = RecoveryProbe()
        let candidates = ["Default", "Profile 2"].map {
            ClaudeBrowserSessionCandidate(
                family: .chrome, profileName: $0,
                cookiesPath: URL(fileURLWithPath: "/fixture/\($0)/Cookies"), supportsAutomaticImport: true)
        }
        let importer = ClaudeChromeCookieImportService(
            candidateProvider: { candidates },
            decryptionKeyProvider: {
                probe.record("permission"); return [Data([1])]
            },
            cookieReader: { _, profile, _ in
                probe.record("read:\(profile)")
                return [
                    .init(
                        domain: ".claude.ai", name: "sessionKey", path: "/",
                        value: "sk-ant-fixture-session-key-long-enough", expiresAt: nil, isSecure: true)
                ]
            })
        _ = try importer.attemptImport(source: origin)
        XCTAssertEqual(probe.events, ["permission", "read:Profile 2"])
        _ = try importer.attemptImport(source: .init(family: .chrome, profileName: "Missing"))
        XCTAssertEqual(probe.events, ["permission", "read:Profile 2"])
    }

    func testAuthenticationClassificationDoesNotConfuseOrganizationPermissionOrChallenge() {
        guard case .invalidSessionKey = ClaudeHTTPTransport.classify(statusCode: 401, data: nil, response: nil) else {
            return XCTFail()
        }
        guard
            case .invalidSessionKey = ClaudeHTTPTransport.classify(
                statusCode: 403,
                data: Data(#"{"error":{"type":"permission_error","message":"Invalid authorization"}}"#.utf8),
                response: nil)
        else { return XCTFail() }
        guard
            case .permissionDenied = ClaudeHTTPTransport.classify(statusCode: 403, data: Data("{}".utf8), response: nil)
        else { return XCTFail() }
        guard
            case .cloudflareBlocked = ClaudeHTTPTransport.classify(
                statusCode: 403, data: Data("<title>Just a moment...</title>".utf8), response: nil)
        else { return XCTFail() }
    }
}

private nonisolated final class RecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let saved: String
    var selected = true
    var confirmed = true
    var current = true
    var validation: ClaudeValidatedWebSession?
    var validationError: APIError?
    var importError: APIError?
    init(saved: String = "old") { self.saved = saved }
    func record(_ event: String) { lock.withLock { recorded.append(event) } }
    var events: [String] { lock.withLock { recorded } }
}

private actor RecoveryGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private nonisolated final class RecoveryVault: ClaudeSessionKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var rejectWrites = false
    func saveString(_ value: String, account: String) throws {
        if rejectWrites { throw KeychainError.invalidData }
        lock.withLock { values[account] = value }
    }
    func loadString(account: String) throws -> String? { lock.withLock { values[account] } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
