import LocalAuthentication
import Security
import XCTest
@testable import ClaudeUsage

final class AntigravityMigrationCoordinatorTests: XCTestCase {
    func testReconcilerBuildsOpaquePlanWithoutMutatingDurableStores() throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        let reconciler = harness.makeReconciler()

        let inventory = reconciler.inventory(authenticationContext: nil)
        try reconciler.validateSources(inventory)
        let prepared = try reconciler.prepareMigration(from: inventory)

        XCTAssertEqual(prepared.repositoryPlan.accounts.count, 1)
        XCTAssertTrue(prepared.repositoryPlan.activeAccountID.isOpaqueUUID)
        XCTAssertTrue(
            prepared.repositoryPlan.accounts[0]
                .credentialReference.isCanonical
        )
        XCTAssertEqual(prepared.sourceInventoryFingerprint.count, 64)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testReconcilerClassifiesLockedKeychainWithoutCreatingAuthenticationContext() throws {
        let harness = MigrationHarness()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "locked@example.invalid",
                    refresh: "locked-refresh"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]
        let reconciler = harness.makeReconciler()

        let inventory = reconciler.inventory(authenticationContext: nil)

        XCTAssertTrue(inventory.requiresInteraction)
        XCTAssertFalse(inventory.hasCandidates)
        XCTAssertEqual(
            inventory.outcomes[.bundleIdentifierKeychain],
            .interactionRequired
        )
        XCTAssertEqual(harness.contextFactory.count, 0)
    }

    func testRefreshFingerprintPreservesTokenBytesInsteadOfTrimming() {
        let plain = credential(
            email: "fingerprint@example.invalid",
            refresh: "refresh-token"
        )
        let whitespaceVariant = credential(
            email: "fingerprint@example.invalid",
            refresh: " refresh-token "
        )

        XCTAssertNotEqual(
            AntigravityMigrationFingerprint.refresh(plain),
            AntigravityMigrationFingerprint.refresh(whitespaceVariant)
        )
    }

    func testNoLegacySourcesCompletesWithoutKeychainPromptOrCanonicalMetadata() async throws {
        let harness = MigrationHarness()

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(result.sourceOutcomes.values.filter { $0 == .notFound }.count, 5)
        XCTAssertEqual(harness.contextFactory.count, 0)
        XCTAssertNotNil(harness.marker.marker)
        XCTAssertNil(harness.metadata.state)
    }

    func testPreflightDeletesUnreferencedCanonicalNamespaceOrphan() async throws {
        let harness = MigrationHarness()
        let orphanReference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        ).rawValue
        harness.vault.values[orphanReference] = Data("orphan".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertTrue(
            try harness.vault.references(
                in: AntigravityAccountRepository.credentialNamespace
            ).isEmpty
        )
        XCTAssertNotNil(harness.marker.marker)
    }

    func testCanonicalCleanupPreservesReferencedCredentialAndDeletesOrphan() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "canonical@example.invalid",
                refresh: "canonical-refresh"
            ),
            label: "Canonical",
            externalIdentity: .init(email: "canonical@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        let canonicalReference = try XCTUnwrap(
            state.activeAccount?.credentialReference.rawValue
        )
        let orphanReference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        ).rawValue
        harness.vault.values[orphanReference] = Data("orphan".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNotNil(harness.vault.values[canonicalReference])
        XCTAssertNil(harness.vault.values[orphanReference])
        XCTAssertEqual(
            try harness.vault.references(
                in: AntigravityAccountRepository.credentialNamespace
            ),
            [canonicalReference]
        )
    }

    func testOrphanCleanupFailureRetriesBeforeCompletionMarker() async throws {
        let harness = MigrationHarness()
        let orphanReference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        ).rawValue
        harness.vault.values[orphanReference] = Data("orphan".utf8)
        harness.vault.failDeleteReferences = [orphanReference]

        let failed = await harness.coordinator.checkForMigration()

        XCTAssertEqual(failed.phase, .blockedBeforeCutover)
        XCTAssertEqual(failed.blocker, .persistenceFailure)
        XCTAssertNotNil(harness.vault.values[orphanReference])
        XCTAssertNil(harness.marker.marker)

        harness.vault.failDeleteReferences = []
        let completed = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.vault.values[orphanReference])
        XCTAssertNotNil(harness.marker.marker)
    }

    func testCompletedMigrationReportsOrphanCleanupFailureAsPostCutover() async throws {
        let harness = MigrationHarness()
        let orphanReference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        ).rawValue
        harness.marker.marker = validMarker()
        harness.vault.values[orphanReference] = Data("orphan".utf8)
        harness.vault.failDeleteReferences = [orphanReference]

        let failed = await harness.coordinator.checkForMigration()

        XCTAssertEqual(failed.phase, .cleanupPending)
        XCTAssertEqual(failed.blocker, .persistenceFailure)
        XCTAssertNotNil(harness.vault.values[orphanReference])
        XCTAssertNotNil(harness.marker.marker)

        harness.vault.failDeleteReferences = []
        let completed = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.vault.values[orphanReference])
        XCTAssertNotNil(harness.marker.marker)
    }

    func testMetadataOnlyLegacyResidueIsRemovedBeforeCompletion() async {
        let harness = MigrationHarness()
        harness.files.values[.metadataFile] = Data(
            #"{"project_id":"metadata-only"}"#.utf8
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.files.values[.metadataFile])
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(harness.marker.marker)
    }

    func testEmptyLegacyAccountFileIsRemovedBeforeCompletion() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [],
            activeID: nil
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(harness.marker.marker)
    }

    func testRedactedRealShapeFixtureImportsTwoAccountsAndPreservesActiveAlias() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try fixtureData()

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        let state = try await harness.repository.state()
        XCTAssertEqual(state.accounts.count, 2)
        XCTAssertTrue(state.accounts.allSatisfy { $0.id.isOpaqueUUID })
        XCTAssertTrue(state.accounts.allSatisfy { $0.credentialReference.isCanonical })
        XCTAssertEqual(
            state.activeAccount?.externalIdentity.email,
            "team@example.invalid"
        )
        XCTAssertEqual(
            state.activeAccount?.migrationAliases,
            ["google-team-example-invalid"]
        )
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertEqual(harness.contextFactory.count, 0)
    }

    func testExactRefreshFingerprintMergesAccountAndActiveMirror() async throws {
        let harness = MigrationHarness()
        let accountCredential = credential(
            email: "same@example.invalid",
            refresh: "same-refresh",
            access: "older-access"
        )
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "legacy-same",
                    credentials: accountCredential
                ),
            ],
            activeID: "legacy-same"
        )
        harness.files.values[.activeCredentialFile] = try JSONEncoder().encode(
            credential(
                email: "same@example.invalid",
                refresh: "same-refresh",
                access: "newer-access"
            )
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        let state = try await harness.repository.state()
        XCTAssertEqual(state.accounts.count, 1)
        let snapshot = try await harness.repository.credentialSnapshot(
            for: try XCTUnwrap(state.activeAccountID)
        )
        XCTAssertEqual(snapshot?.credentials.accessToken, "newer-access")
        XCTAssertEqual(state.activeAccount?.migrationAliases, ["legacy-same"])
    }

    func testSameEmailWithDifferentRefreshLineageBlocksBeforeVaultWrite() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "legacy-one",
                    credentials: credential(
                        email: "collision@example.invalid",
                        refresh: "refresh-one"
                    )
                ),
                legacyAccount(
                    id: "legacy-two",
                    credentials: credential(
                        email: "COLLISION@example.invalid",
                        refresh: "refresh-two"
                    )
                ),
            ],
            activeID: "legacy-one"
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .blockedBeforeCutover)
        XCTAssertEqual(result.blocker, .tokenLineageConflict)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.metadata.state)
    }

    func testSameTrimmedLegacyAliasWithDifferentRefreshLineageBlocks() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "same-legacy-alias",
                    email: "first@example.invalid",
                    credentials: credential(
                        email: "first@example.invalid",
                        refresh: "refresh-one"
                    )
                ),
                legacyAccount(
                    id: " same-legacy-alias ",
                    email: "second@example.invalid",
                    credentials: credential(
                        email: "second@example.invalid",
                        refresh: "refresh-two"
                    )
                ),
            ],
            activeID: "same-legacy-alias"
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .blockedBeforeCutover)
        XCTAssertEqual(result.blocker, .tokenLineageConflict)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.metadata.state)
    }

    func testDuplicateLegacyAccountIDsAreRejectedAsRawCorruption() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "duplicate-alias",
                    email: "one@example.invalid",
                    credentials: credential(
                        email: "one@example.invalid",
                        refresh: "refresh-one"
                    )
                ),
                legacyAccount(
                    id: "duplicate-alias",
                    email: "two@example.invalid",
                    credentials: credential(
                        email: "two@example.invalid",
                        refresh: "refresh-two"
                    )
                ),
            ],
            activeID: "duplicate-alias"
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .blockedBeforeCutover)
        XCTAssertEqual(
            result.blocker,
            .invalidLegacySource(.accountFile)
        )
        XCTAssertTrue(harness.vault.values.isEmpty)
    }

    func testMultipleAccountsWithoutUniqueActiveSignalBlocks() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "one",
                    credentials: credential(
                        email: "one@example.invalid",
                        refresh: "refresh-one"
                    )
                ),
                legacyAccount(
                    id: "two",
                    credentials: credential(
                        email: "two@example.invalid",
                        refresh: "refresh-two"
                    )
                ),
            ],
            activeID: nil
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.blocker, .activeAccountAmbiguous)
        XCTAssertNil(harness.metadata.state)
    }

    func testLockedKeychainOnlyWaitsForExplicitActionAndCancelDoesNotRepromptSession() async throws {
        let harness = MigrationHarness()
        harness.keychain.values[.bundleIdentifierKeychain] = try JSONEncoder().encode(
            credential(
                email: "locked@example.invalid",
                refresh: "locked-refresh"
            )
        )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        let automatic = await harness.coordinator.checkForMigration()
        XCTAssertEqual(automatic.phase, .awaitingImportAuthorization)
        XCTAssertEqual(
            automatic.requiredAction,
            .importCredential
        )
        XCTAssertEqual(harness.contextFactory.count, 0)
        XCTAssertNil(harness.metadata.state)

        harness.keychain.cancelInteractiveSources = [.bundleIdentifierKeychain]
        let cancelled = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(cancelled.phase, .awaitingImportAuthorization)
        XCTAssertTrue(cancelled.authorizationCancelledThisSession)
        XCTAssertEqual(harness.contextFactory.count, 1)

        _ = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(harness.contextFactory.count, 1)
    }

    func testValidFileImportsWithoutPromptWhenLegacyKeychainIsLocked() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "file-account",
                    credentials: credential(
                        email: "file@example.invalid",
                        refresh: "file-refresh"
                    )
                ),
            ],
            activeID: "file-account"
        )
        harness.keychain.values[.bundleIdentifierKeychain] = try JSONEncoder().encode(
            credential(
                email: "locked-old@example.invalid",
                refresh: "locked-old-refresh"
            )
        )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        let automatic = await harness.coordinator.checkForMigration()

        XCTAssertEqual(automatic.phase, .cleanupPending)
        XCTAssertEqual(
            automatic.requiredAction,
            .cleanupLegacyCredential
        )
        XCTAssertEqual(harness.contextFactory.count, 0)
        XCTAssertEqual(harness.metadata.state?.accounts.count, 1)
        XCTAssertEqual(
            harness.metadata.state?.activeAccount?.externalIdentity.email,
            "file@example.invalid"
        )
        XCTAssertNotNil(harness.migrationJournal.journal)

        let protected = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(protected.phase, .cleanupPending)
        XCTAssertEqual(
            protected.blocker,
            .legacySourceChanged(.bundleIdentifierKeychain)
        )
        XCTAssertEqual(harness.contextFactory.count, 1)
        XCTAssertNotNil(harness.keychain.values[.bundleIdentifierKeychain])
    }

    func testLockedMirrorWithCanonicalRefreshLineageCanBeCleanedInteractively() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "single@example.invalid",
                    refresh: "single-refresh",
                    access: "newer-mirror-access"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        let automatic = await harness.coordinator.checkForMigration()
        XCTAssertEqual(automatic.phase, .cleanupPending)
        XCTAssertNotNil(harness.keychain.values[.bundleIdentifierKeychain])

        let completed = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(completed.blocker)
        XCTAssertNil(harness.keychain.values[.bundleIdentifierKeychain])
        XCTAssertEqual(harness.contextFactory.count, 1)
    }

    func testCancelledCleanupRemainsCleanupActionWithoutSessionReprompt() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "old@example.invalid",
                    refresh: "old-refresh"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]
        let automatic = await harness.coordinator.checkForMigration()
        XCTAssertEqual(automatic.phase, .cleanupPending)

        harness.keychain.cancelInteractiveSources = [.bundleIdentifierKeychain]
        let cancelled = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(cancelled.phase, .cleanupPending)
        XCTAssertEqual(cancelled.requiredAction, .cleanupLegacyCredential)
        XCTAssertTrue(cancelled.authorizationCancelledThisSession)
        XCTAssertEqual(harness.contextFactory.count, 1)

        let deferred = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(deferred.phase, .cleanupPending)
        XCTAssertEqual(deferred.requiredAction, .cleanupLegacyCredential)
        XCTAssertTrue(deferred.authorizationCancelledThisSession)
        XCTAssertEqual(harness.contextFactory.count, 1)
    }

    func testInteractiveKeychainImportReusesOneContextForReadAndDelete() async throws {
        let harness = MigrationHarness()
        harness.keychain.values[.bundleIdentifierKeychain] = try JSONEncoder().encode(
            credential(
                email: "interactive@example.invalid",
                refresh: "interactive-refresh"
            )
        )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]
        _ = await harness.coordinator.checkForMigration()

        let result = await harness.coordinator.performInteractiveMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(harness.contextFactory.count, 1)
        let contextIDs = Set(
            harness.keychain.interactiveReadContextIDs
                + harness.keychain.interactiveDeleteContextIDs
        )
        XCTAssertEqual(contextIDs.count, 1)
        XCTAssertEqual(
            harness.keychain.interactiveDeleteContextIDs.count,
            1
        )
    }

    func testConcurrentChecksShareOneMigrationTransaction() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        let coordinator = harness.coordinator

        async let first = coordinator.checkForMigration()
        async let second = coordinator.checkForMigration()
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy { $0.phase == .complete })
        XCTAssertEqual(harness.vault.payloadSaveCount, 1)
        XCTAssertEqual(harness.metadata.saveCallCount, 1)
        XCTAssertEqual(harness.metadata.state?.revision, 1)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(harness.marker.marker)
    }

    func testConcurrentInteractiveImportsShareOneAuthenticationContext() async throws {
        let harness = MigrationHarness()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "concurrent@example.invalid",
                    refresh: "concurrent-refresh"
                )
        )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]
        let coordinator = harness.coordinator

        async let first = coordinator.performInteractiveMigration()
        async let second = coordinator.performInteractiveMigration()
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy { $0.phase == .complete })
        XCTAssertEqual(harness.contextFactory.count, 1)
        XCTAssertEqual(harness.vault.payloadSaveCount, 1)
        XCTAssertEqual(harness.metadata.saveCallCount, 1)
        XCTAssertNil(harness.keychain.values[.bundleIdentifierKeychain])
        XCTAssertNotNil(harness.marker.marker)
    }

    func testExistingCanonicalIsNeverOverwrittenAndLockedLegacyIsDeleteOnly() async throws {
        let harness = MigrationHarness()
        let original = try await harness.repository.createAccount(
            credentials: credential(
                email: "canonical@example.invalid",
                refresh: "canonical-refresh"
            ),
            label: "Canonical",
            externalIdentity: .init(email: "canonical@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        harness.keychain.values[.bundleIdentifierKeychain] = try JSONEncoder().encode(
            credential(
                email: "legacy@example.invalid",
                refresh: "legacy-refresh"
            )
        )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        let automatic = await harness.coordinator.checkForMigration()
        XCTAssertEqual(automatic.phase, .cleanupPending)
        XCTAssertEqual(
            automatic.requiredAction,
            .cleanupLegacyCredential
        )
        XCTAssertEqual(harness.metadata.state, original)

        let protected = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(protected.phase, .cleanupPending)
        XCTAssertEqual(
            protected.blocker,
            .legacySourceChanged(.bundleIdentifierKeychain)
        )
        XCTAssertEqual(harness.metadata.state, original)
        XCTAssertNotNil(harness.keychain.values[.bundleIdentifierKeychain])
    }

    func testCompletionMarkerStillChecksCanonicalVaultIntegrity() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "canonical@example.invalid",
                refresh: "canonical-refresh"
            ),
            label: "Canonical",
            externalIdentity: .init(email: "canonical@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        harness.marker.marker = validMarker()
        let reference = try XCTUnwrap(state.activeAccount?.credentialReference.rawValue)
        harness.vault.values.removeValue(forKey: reference)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .blockedBeforeCutover)
        XCTAssertEqual(result.blocker, .missingCanonicalCredential)
    }

    func testInvalidCompletionMarkerIsRejected() async {
        let harness = MigrationHarness()
        harness.marker.marker = AntigravityMigrationCompletionMarker(
            version: 999,
            completedAtMilliseconds: .nan
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.blocker, .invalidCompletionMarker)
    }

    func testCorruptCompletionMarkerDecodeIsNotMisreportedAsJournalFailure() async {
        let harness = MigrationHarness()
        let coordinator = harness.makeCoordinator(
            markerStore: CorruptMigrationMarkerStore()
        )

        let result = await coordinator.checkForMigration()

        XCTAssertEqual(result.blocker, .invalidCompletionMarker)
    }

    func testRemovalJournalRecoversDespiteCorruptCompletionMarker() async {
        let harness = MigrationHarness()
        harness.migrationJournal.journal = AntigravityMigrationJournal(
            operationID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            kind: .removeAllAccounts,
            phase: .removalPending,
            expectedRevision: 0,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            removalCanonicalStateFingerprint:
                AntigravityMigrationFingerprint.removalCanonicalState(.init()),
            accounts: [],
            activeAccountID: nil
        )
        let marker = RecoverableCorruptMigrationMarkerStore()
        let coordinator = harness.makeCoordinator(markerStore: marker)

        let result = await coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(result.blocker)
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(marker.marker)
    }

    func testCorruptLegacySourceIsNotTreatedAsEmpty() async {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = Data("{".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(
            result.blocker,
            .invalidLegacySource(.accountFile)
        )
        XCTAssertNil(harness.marker.marker)
    }

    func testAuthoritativeAccountFileRecoversCorruptMirrorsAsCleanupTargets() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "single-without-active",
                    credentials: credential(
                        email: "single@example.invalid",
                        refresh: "single-refresh"
                    )
                ),
            ],
            activeID: nil
        )
        harness.files.values[.activeCredentialFile] = Data("{".utf8)
        harness.files.values[.metadataFile] = Data("{".utf8)
        harness.keychain.values[.bundleIdentifierKeychain] = Data("{".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(harness.metadata.state?.accounts.count, 1)
        XCTAssertTrue(harness.files.values.isEmpty)
        XCTAssertTrue(harness.keychain.values.isEmpty)
    }

    func testAuthoritativeAccountFileRemovesEmptyRedundantMirror() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.files.values[.activeCredentialFile] = Data()

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(result.blocker)
        XCTAssertNil(harness.files.values[.activeCredentialFile])
        XCTAssertNil(harness.files.quarantinedValues[.activeCredentialFile])
    }

    func testSingleAccountWithStaleActiveAliasAutoSelectsThatAccount() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "only-account",
                    credentials: credential(
                        email: "only@example.invalid",
                        refresh: "only-refresh"
                    )
                ),
            ],
            activeID: "missing-old-account"
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(
            harness.metadata.state?.activeAccount?.externalIdentity.email,
            "only@example.invalid"
        )
    }

    func testMultipleAccountsWithStaleActiveAliasRemainAmbiguous() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "first",
                    credentials: credential(
                        email: "first@example.invalid",
                        refresh: "first-refresh"
                    )
                ),
                legacyAccount(
                    id: "second",
                    credentials: credential(
                        email: "second@example.invalid",
                        refresh: "second-refresh"
                    )
                ),
            ],
            activeID: "missing-old-account"
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.blocker, .activeAccountAmbiguous)
        XCTAssertNil(harness.metadata.state)
    }

    func testInvalidAccountFileCannotBeMaskedByValidActiveMirror() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = Data("{".utf8)
        harness.files.values[.activeCredentialFile] = try JSONEncoder().encode(
            credential(
                email: "mirror@example.invalid",
                refresh: "mirror-refresh"
            )
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(
            result.blocker,
            .invalidLegacySource(.accountFile)
        )
        XCTAssertNil(harness.metadata.state)
    }

    func testOuterAndCredentialEmailsMustNotDisagree() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "identity-conflict",
                    email: "outer@example.invalid",
                    credentials: credential(
                        email: "inner@example.invalid",
                        refresh: "identity-refresh"
                    )
                ),
            ],
            activeID: "identity-conflict"
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.blocker, .externalIdentityConflict)
        XCTAssertNil(harness.metadata.state)
    }

    func testSplitKeychainSecretsMergeStrictMetadataBeforeImport() async throws {
        let harness = MigrationHarness()
        harness.files.values[.metadataFile] = Data("""
        {
          "client_id": "fixture-client",
          "email": "split@example.invalid",
          "expiry_date": 1900000000000,
          "project_id": "fixture-project"
        }
        """.utf8)
        harness.keychain.values[.bundleIdentifierKeychain] = Data("""
        {
          "access_token": "split-access",
          "refresh_token": "split-refresh",
          "id_token": "split-id"
        }
        """.utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        let state = try await harness.repository.state()
        let snapshot = try await harness.repository.credentialSnapshot(
            for: try XCTUnwrap(state.activeAccountID)
        )
        XCTAssertEqual(snapshot?.credentials.email, "split@example.invalid")
        XCTAssertEqual(snapshot?.credentials.clientID, "fixture-client")
        XCTAssertEqual(snapshot?.credentials.projectID, "fixture-project")
    }

    func testSelfContainedActiveCredentialRecoversCorruptMetadata() async throws {
        let harness = MigrationHarness()
        let active = credential(
            email: "self-contained@example.invalid",
            refresh: "self-contained-refresh"
        )
        harness.files.values[.activeCredentialFile] =
            try JSONEncoder().encode(active)
        harness.files.values[.metadataFile] = Data("{".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(result.blocker)
        let state = try await harness.repository.state()
        let snapshot = try await harness.repository.credentialSnapshot(
            for: try XCTUnwrap(state.activeAccountID)
        )
        XCTAssertEqual(snapshot?.credentials, active)
        XCTAssertNil(harness.files.values[.metadataFile])
        XCTAssertNil(harness.files.values[.activeCredentialFile])
    }

    func testPublicClientActiveCredentialRecoversCorruptMetadata() async throws {
        let harness = MigrationHarness()
        let active = AntigravityOAuthCredentials(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_900_000_000),
            idToken: nil,
            email: "public-client@example.invalid",
            projectID: "fixture-project",
            clientID: "fixture-public-client",
            clientSecret: nil
        )
        harness.files.values[.activeCredentialFile] =
            try JSONEncoder().encode(active)
        harness.files.values[.metadataFile] = Data("{".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(result.blocker)
        let state = try await harness.repository.state()
        let snapshot = try await harness.repository.credentialSnapshot(
            for: try XCTUnwrap(state.activeAccountID)
        )
        XCTAssertEqual(snapshot?.credentials, active)
        XCTAssertNil(harness.files.values[.metadataFile])
        XCTAssertNil(harness.files.values[.activeCredentialFile])
    }

    func testIncompleteActiveCredentialCannotMaskCorruptMetadata() async throws {
        let harness = MigrationHarness()
        let incomplete = AntigravityOAuthCredentials(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_900_000_000),
            idToken: nil,
            email: "incomplete@example.invalid",
            projectID: nil,
            clientID: "fixture-client",
            clientSecret: nil
        )
        harness.files.values[.activeCredentialFile] =
            try JSONEncoder().encode(incomplete)
        harness.files.values[.metadataFile] = Data("{".utf8)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(
            result.blocker,
            .invalidLegacySource(.metadataFile)
        )
        XCTAssertNil(harness.metadata.state)
        XCTAssertNotNil(harness.files.values[.metadataFile])
        XCTAssertNotNil(harness.files.values[.activeCredentialFile])
    }

    func testMigrationJournalFailureStopsBeforeAnyVaultWrite() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.migrationJournal.silentDropSaves = true

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.blocker, .persistenceFailure)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.metadata.state)
    }

    func testLegacyChangeImmediatelyBeforeCutoverBlocksAndPreservesNewPayload() async throws {
        let harness = MigrationHarness()
        let accountA = try singleAccountData()
        let accountB = try accountStateData(
            [
                legacyAccount(
                    id: "replacement-account",
                    credentials: credential(
                        email: "replacement@example.invalid",
                        refresh: "replacement-refresh"
                    )
                ),
            ],
            activeID: "replacement-account"
        )
        harness.files.scriptReads(
            [accountA, accountB],
            for: .accountFile
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .blockedBeforeCutover)
        XCTAssertEqual(
            result.blocker,
            .legacySourceChanged(.accountFile)
        )
        XCTAssertNil(harness.metadata.state)
        XCTAssertEqual(
            harness.files.values[.accountFile],
            accountB
        )
        XCTAssertEqual(
            harness.migrationJournal.journal?.phase,
            .credentialsStaged
        )
    }

    func testLegacyChangeAfterCutoverIsNeverDeleted() async throws {
        let harness = MigrationHarness()
        let accountA = try singleAccountData()
        let accountB = try accountStateData(
            [
                legacyAccount(
                    id: "replacement-account",
                    credentials: credential(
                        email: "replacement@example.invalid",
                        refresh: "replacement-refresh"
                    )
                ),
            ],
            activeID: "replacement-account"
        )
        harness.files.scriptReads(
            [accountA, accountA],
            for: .accountFile
        )
        harness.files.replaceImmediatelyBeforeQuarantine[.accountFile] =
            accountB

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .cleanupPending)
        XCTAssertEqual(
            result.blocker,
            .legacySourceChanged(.accountFile)
        )
        XCTAssertEqual(
            harness.metadata.state?.activeAccount?.externalIdentity.email,
            "single@example.invalid"
        )
        XCTAssertEqual(
            harness.files.values[.accountFile],
            accountB
        )
        XCTAssertNil(harness.marker.marker)
        XCTAssertNotNil(harness.migrationJournal.journal)
    }

    func testFileRecreatedAfterQuarantineIsNeverDeleted() async throws {
        let harness = MigrationHarness()
        let accountA = try singleAccountData()
        let accountB = try accountStateData(
            [
                legacyAccount(
                    id: "replacement-account",
                    credentials: credential(
                        email: "replacement@example.invalid",
                        refresh: "replacement-refresh"
                    )
                ),
            ],
            activeID: "replacement-account"
        )
        harness.files.values[.accountFile] = accountA
        harness.files.recreateImmediatelyAfterQuarantine[.accountFile] =
            accountB

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .cleanupPending)
        XCTAssertEqual(
            result.blocker,
            .legacySourceChanged(.accountFile)
        )
        XCTAssertEqual(harness.files.values[.accountFile], accountB)
        XCTAssertNil(harness.files.quarantinedValues[.accountFile])
    }

    func testKeychainUpdateImmediatelyBeforeQuarantineIsNeverDeleted() async throws {
        let harness = MigrationHarness()
        let credentialA = credential(
            email: "same@example.invalid",
            refresh: "same-refresh"
        )
        let credentialB = credential(
            email: "replacement@example.invalid",
            refresh: "replacement-refresh"
        )
        harness.files.values[.accountFile] = try accountStateData(
            [legacyAccount(id: "same", credentials: credentialA)],
            activeID: "same"
        )
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(credentialA)
        harness.keychain
            .replaceImmediatelyBeforeQuarantine[.bundleIdentifierKeychain] =
                try JSONEncoder().encode(credentialB)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .cleanupPending)
        XCTAssertEqual(
            result.blocker,
            .legacySourceChanged(.bundleIdentifierKeychain)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AntigravityOAuthCredentials.self,
                from: try XCTUnwrap(
                    harness.keychain.values[.bundleIdentifierKeychain]
                )
            ),
            credentialB
        )
        XCTAssertNil(
            harness.keychain.quarantinedValues[.bundleIdentifierKeychain]
        )
    }

    func testKeychainRecreatedAfterQuarantineIsNeverDeleted() async throws {
        let harness = MigrationHarness()
        let credentialA = credential(
            email: "same@example.invalid",
            refresh: "same-refresh"
        )
        let credentialB = credential(
            email: "replacement@example.invalid",
            refresh: "replacement-refresh"
        )
        harness.files.values[.accountFile] = try accountStateData(
            [legacyAccount(id: "same", credentials: credentialA)],
            activeID: "same"
        )
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(credentialA)
        harness.keychain
            .recreateImmediatelyAfterQuarantine[.bundleIdentifierKeychain] =
                try JSONEncoder().encode(credentialB)

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .cleanupPending)
        XCTAssertEqual(
            result.blocker,
            .legacySourceChanged(.bundleIdentifierKeychain)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AntigravityOAuthCredentials.self,
                from: try XCTUnwrap(
                    harness.keychain.values[.bundleIdentifierKeychain]
                )
            ),
            credentialB
        )
        XCTAssertNil(
            harness.keychain.quarantinedValues[.bundleIdentifierKeychain]
        )
    }

    func testCleanupResumesFixedQuarantineAfterCrash() async throws {
        let harness = MigrationHarness()
        let accountA = try singleAccountData()
        harness.files.values[.accountFile] = accountA
        harness.files.failAfterQuarantineSources = [.accountFile]

        let interrupted = await harness.coordinator.checkForMigration()

        XCTAssertEqual(interrupted.phase, .cleanupPending)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertEqual(
            harness.files.quarantinedValues[.accountFile],
            accountA
        )
        XCTAssertNotNil(
            harness.migrationJournal.journal?
                .cleanupPayloadFingerprints[.accountFile]
        )

        harness.files.failAfterQuarantineSources = []
        let completed = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertNil(harness.files.quarantinedValues[.accountFile])
    }

    func testMismatchRestoreFailurePreservesQuarantine() async throws {
        let harness = MigrationHarness()
        let accountA = try singleAccountData()
        let accountB = try accountStateData(
            [
                legacyAccount(
                    id: "replacement-account",
                    credentials: credential(
                        email: "replacement@example.invalid",
                        refresh: "replacement-refresh"
                    )
                ),
            ],
            activeID: "replacement-account"
        )
        harness.files.values[.accountFile] = accountA
        harness.files.replaceImmediatelyBeforeQuarantine[.accountFile] =
            accountB
        harness.files.failRestoreSources = [.accountFile]

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .cleanupPending)
        XCTAssertEqual(
            result.blocker,
            .legacySourceChanged(.accountFile)
        )
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertEqual(
            harness.files.quarantinedValues[.accountFile],
            accountB
        )
    }

    func testRemoveAllDeletesOriginalAndQuarantineIdentities() async throws {
        let harness = MigrationHarness()
        let accountA = try singleAccountData()
        harness.files.values[.accountFile] = accountA
        harness.files.failAfterQuarantineSources = [.accountFile]
        let interrupted = await harness.coordinator.checkForMigration()
        XCTAssertEqual(interrupted.phase, .cleanupPending)
        XCTAssertEqual(
            harness.files.quarantinedValues[.accountFile],
            accountA
        )
        harness.files.values[.accountFile] = Data("recreated".utf8)
        harness.keychain.values[.bundleIdentifierKeychain] =
            Data("legacy-original".utf8)
        harness.keychain.failAfterQuarantineSources =
            [.bundleIdentifierKeychain]
        _ = harness.keychain.deleteIfUnchanged(
            .bundleIdentifierKeychain,
            expectedPayloadFingerprint:
                AntigravityMigrationFingerprint.data(Data("legacy-original".utf8)),
            authenticationContext: nil
        )
        harness.keychain.values[.bundleIdentifierKeychain] =
            Data("legacy-recreated".utf8)

        let removed = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(removed.phase, .complete)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertNil(harness.files.quarantinedValues[.accountFile])
        XCTAssertNil(harness.keychain.values[.bundleIdentifierKeychain])
        XCTAssertNil(
            harness.keychain.quarantinedValues[.bundleIdentifierKeychain]
        )
    }

    func testVaultWriteFailureLeavesPlannedJournalAndRestartRollsBackThenRetries() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.vault.failSaveCalls = [1]

        let failed = await harness.coordinator.checkForMigration()
        XCTAssertEqual(failed.blocker, .persistenceFailure)
        XCTAssertEqual(harness.migrationJournal.journal?.phase, .planned)
        XCTAssertNil(harness.metadata.state)

        harness.vault.failSaveCalls = []
        let recovered = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(recovered.phase, .complete)
        XCTAssertEqual(harness.metadata.state?.accounts.count, 1)
        XCTAssertEqual(
            try harness.vault.references(
                in: AntigravityAccountRepository.credentialNamespace
            ).count,
            1
        )
    }

    func testMetadataWriteFailureRollsBackStagedSecretOnRestart() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.metadata.failSaveCalls = [1]

        let failed = await harness.coordinator.checkForMigration()
        XCTAssertEqual(failed.blocker, .persistenceFailure)
        XCTAssertEqual(
            harness.migrationJournal.journal?.phase,
            .credentialsStaged
        )
        XCTAssertEqual(harness.vault.values.count, 1)

        harness.metadata.failSaveCalls = []
        let recovered = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(recovered.phase, .complete)
        XCTAssertEqual(harness.vault.values.count, 1)
        XCTAssertEqual(harness.metadata.state?.accounts.count, 1)
    }

    func testLegacyDeleteFailurePreservesCanonicalAndRetryCompletes() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.files.deleteFailures[.accountFile] = -42

        let pending = await harness.coordinator.checkForMigration()

        XCTAssertEqual(pending.phase, .cleanupPending)
        let canonical = try XCTUnwrap(harness.metadata.state)
        let reference = try XCTUnwrap(
            canonical.activeAccount?.credentialReference.rawValue
        )
        XCTAssertNotNil(harness.vault.values[reference])
        XCTAssertNotNil(harness.migrationJournal.journal)

        harness.files.deleteFailures = [:]
        let completed = await harness.restartCoordinator().checkForMigration()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertEqual(harness.metadata.state, canonical)
        XCTAssertNotNil(harness.vault.values[reference])
    }

    func testSilentLegacyDeleteIsDetectedByExactAbsenceReadback() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.files.silentDeleteSources = [.accountFile]

        let pending = await harness.coordinator.checkForMigration()

        XCTAssertEqual(pending.phase, .cleanupPending)
        XCTAssertEqual(
            pending.sourceOutcomes[.accountFile],
            .failure(-1)
        )
        XCTAssertNotNil(harness.files.values[.accountFile])
        XCTAssertFalse(
            harness.migrationJournal.journal?
                .completedCleanupTargets.contains(.accountFile) ?? true
        )

        harness.files.silentDeleteSources = []
        let completed = await harness.restartCoordinator().checkForMigration()
        XCTAssertEqual(completed.phase, .complete)
    }

    func testCleanupCompletesWhenPendingSourceDisappearsExternally() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "locked@example.invalid",
                    refresh: "locked-refresh"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        let pending = await harness.coordinator.checkForMigration()
        XCTAssertEqual(pending.phase, .cleanupPending)
        XCTAssertEqual(
            pending.requiredAction,
            .cleanupLegacyCredential
        )

        harness.keychain.values.removeValue(forKey: .bundleIdentifierKeychain)
        let completed = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(harness.marker.marker)
        XCTAssertEqual(harness.contextFactory.count, 0)
    }

    func testMarkerWithLeftoverCleanupJournalIsSafelyFinalized() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        let initial = await harness.coordinator.checkForMigration()
        XCTAssertEqual(initial.phase, .complete)
        let leftover = try XCTUnwrap(
            harness.migrationJournal.savedJournals.last(where: {
                $0.phase == .cleanupPending
            })
        )
        harness.migrationJournal.journal = leftover

        let restarted = await harness.restartCoordinator().checkForMigration()

        XCTAssertEqual(restarted.phase, .complete)
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(harness.marker.marker)
    }

    func testMarkerRecoversCorruptLeftoverJournalWithoutDeletingCanonicalAccount() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "canonical@example.invalid",
                refresh: "canonical-refresh"
            ),
            label: "Canonical",
            externalIdentity: .init(email: "canonical@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        let canonicalReference = try XCTUnwrap(
            state.activeAccount?.credentialReference.rawValue
        )
        harness.marker.marker = validMarker()
        let corrupt = RecoverableCorruptMigrationJournalStore()
        let coordinator = harness.makeCoordinator(
            markerStore: harness.marker,
            journalStore: corrupt
        )

        let result = await coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(harness.metadata.state, state)
        XCTAssertNotNil(harness.vault.values[canonicalReference])
        XCTAssertNil(try corrupt.load())
    }

    func testCompletionMarkerFailureStaysPostCutoverAndResumesFromJournal() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.marker.silentDropSaves = true

        let pending = await harness.coordinator.checkForMigration()

        XCTAssertEqual(pending.phase, .cleanupPending)
        XCTAssertEqual(pending.blocker, .persistenceFailure)
        XCTAssertNotNil(harness.metadata.state)
        XCTAssertNotNil(harness.migrationJournal.journal)
        XCTAssertNil(harness.marker.marker)
        XCTAssertNil(harness.files.values[.accountFile])

        harness.marker.silentDropSaves = false
        let completed = await harness.restartCoordinator().checkForMigration()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertNotNil(harness.marker.marker)
    }

    func testJournalDeleteFailureStaysPostCutoverAndResumes() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.migrationJournal.failDelete = true

        let pending = await harness.coordinator.checkForMigration()

        XCTAssertEqual(pending.phase, .cleanupPending)
        XCTAssertEqual(pending.blocker, .persistenceFailure)
        XCTAssertNotNil(harness.metadata.state)
        XCTAssertNotNil(harness.marker.marker)
        XCTAssertNotNil(harness.migrationJournal.journal)

        harness.migrationJournal.failDelete = false
        let completed = await harness.restartCoordinator().checkForMigration()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testMarkerCleansReappearedLegacyFileWithoutResurrectingAccount() async throws {
        let harness = MigrationHarness()
        harness.marker.marker = validMarker()
        harness.files.values[.accountFile] = try singleAccountData()

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testMarkerKeepsReappearedLockedKeychainAsRemoveOnlyCleanup() async throws {
        let harness = MigrationHarness()
        harness.marker.marker = validMarker()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "downgrade@example.invalid",
                    refresh: "downgrade-refresh"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        let automatic = await harness.coordinator.checkForMigration()

        XCTAssertEqual(automatic.phase, .cleanupPending)
        XCTAssertEqual(
            automatic.requiredAction,
            .removeLegacyCredential
        )
        XCTAssertNil(harness.metadata.state)
        XCTAssertEqual(harness.contextFactory.count, 0)

        let completed = await harness.coordinator.performInteractiveMigration()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertNil(harness.keychain.values[.bundleIdentifierKeychain])
    }

    func testMarkerRollsBackStalePreCutoverJournalWithoutImportingLegacy() async throws {
        let harness = MigrationHarness()
        harness.marker.marker = validMarker()
        harness.files.values[.accountFile] = try singleAccountData()
        let accountID = AntigravityAccountID(
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let reference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        try await harness.repository.stageMigrationCredential(
            credential(
                email: "staged@example.invalid",
                refresh: "staged-refresh"
            ),
            reference: reference
        )
        harness.migrationJournal.journal = AntigravityMigrationJournal(
            operationID: UUID(
                uuidString: "33333333-3333-3333-3333-333333333333"
            )!,
            kind: .credentialImport,
            phase: .credentialsStaged,
            expectedRevision: 0,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            sourceFingerprints: legacySourceFingerprints(),
            accounts: [
                AntigravityMigrationJournalAccount(
                    accountID: accountID,
                    credentialReference: reference,
                    refreshTokenFingerprint: String(repeating: "b", count: 64)
                ),
            ],
            activeAccountID: accountID
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.files.values[.accountFile])
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testPersistedJournalContainsOnlyOpaqueAndOneWayMigrationData() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try accountStateData(
            [
                legacyAccount(
                    id: "person-alias",
                    credentials: credential(
                        email: "person@example.invalid",
                        refresh: "super-secret-refresh",
                        access: "super-secret-access"
                    )
                ),
            ],
            activeID: "person-alias"
        )
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "old@example.invalid",
                    refresh: "locked-secret-refresh"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]

        _ = await harness.coordinator.checkForMigration()

        let journal = try XCTUnwrap(harness.migrationJournal.journal)
        let json = String(
            decoding: try JSONEncoder().encode(journal),
            as: UTF8.self
        )
        for forbidden in [
            "super-secret-refresh",
            "super-secret-access",
            "locked-secret-refresh",
            "person@example.invalid",
            "person-alias",
        ] {
            XCTAssertFalse(json.contains(forbidden), "journal leaked \(forbidden)")
        }
        XCTAssertEqual(journal.sourceInventoryFingerprint.count, 64)
        XCTAssertTrue(journal.accounts.allSatisfy {
            $0.refreshTokenFingerprint.count == 64
        })
    }

    func testRemoveAllDeletesCanonicalNamespaceLegacySourcesAndMigrationJournal() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        let imported = await harness.coordinator.checkForMigration()
        XCTAssertEqual(imported.phase, .complete)
        harness.files.values[.activeCredentialFile] = try JSONEncoder().encode(
            credential(
                email: "residual@example.invalid",
                refresh: "residual-refresh"
            )
        )
        harness.keychain.values[.claudeUsageKeychain] = try JSONEncoder().encode(
            credential(
                email: "keychain@example.invalid",
                refresh: "keychain-refresh"
            )
        )

        let result = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(
            try harness.vault.references(
                in: AntigravityAccountRepository.credentialNamespace
            ).isEmpty
        )
        XCTAssertTrue(harness.files.values.isEmpty)
        XCTAssertTrue(harness.keychain.values.isEmpty)
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertTrue(harness.files.removeDirectoryIfEmptyCalled)
        XCTAssertNotNil(harness.marker.marker)
    }

    func testRemoveAllCanDeleteCanonicalAccountWhoseVaultItemIsMissing() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "broken@example.invalid",
                refresh: "broken-refresh"
            ),
            label: "Broken",
            externalIdentity: .init(email: "broken@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        let reference = try XCTUnwrap(
            state.activeAccount?.credentialReference.rawValue
        )
        var values = harness.vault.values
        values.removeValue(forKey: reference)
        harness.vault.values = values

        let result = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
    }

    func testStartupResumesRemovalJournalEvenWhenCanonicalVaultItemIsMissing() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "broken@example.invalid",
                refresh: "broken-refresh"
            ),
            label: "Broken",
            externalIdentity: .init(email: "broken@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        let reference = try XCTUnwrap(
            state.activeAccount?.credentialReference.rawValue
        )
        var values = harness.vault.values
        values.removeValue(forKey: reference)
        harness.vault.values = values
        harness.marker.marker = validMarker()
        harness.migrationJournal.journal = AntigravityMigrationJournal(
            operationID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            kind: .removeAllAccounts,
            phase: .removalPending,
            expectedRevision: state.revision,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            removalCanonicalStateFingerprint:
                AntigravityMigrationFingerprint.removalCanonicalState(state),
            accounts: [],
            activeAccountID: nil
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testRemoveAllSupersedesUncommittedImportJournal() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.vault.failSaveCalls = [1]
        let failedImport = await harness.coordinator.checkForMigration()
        XCTAssertEqual(
            harness.migrationJournal.journal?.phase,
            .planned
        )
        XCTAssertEqual(failedImport.blocker, .persistenceFailure)

        harness.vault.failSaveCalls = []
        let removed = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(removed.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertNil(harness.migrationJournal.journal)
        XCTAssertTrue(harness.files.values.isEmpty)
    }

    func testRemoveAllSupersedesPostCutoverCleanupJournal() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.keychain.values[.bundleIdentifierKeychain] =
            try JSONEncoder().encode(
                credential(
                    email: "locked@example.invalid",
                    refresh: "locked-refresh"
                )
            )
        harness.keychain.lockedSources = [.bundleIdentifierKeychain]
        let imported = await harness.coordinator.checkForMigration()
        XCTAssertEqual(imported.phase, .cleanupPending)
        XCTAssertNotNil(harness.metadata.state)

        let pendingRemoval = await harness.coordinator.removeAllAccounts()
        XCTAssertEqual(pendingRemoval.phase, .cleanupPending)
        XCTAssertEqual(
            pendingRemoval.requiredAction,
            .removeLegacyCredential
        )
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)

        let completed = await harness.coordinator
            .removeAllAccountsInteractively()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.keychain.values[.bundleIdentifierKeychain])
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testExplicitRemoveAllDiscardsInvalidStaleMigrationJournal() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        harness.migrationJournal.journal = AntigravityMigrationJournal(
            operationID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            kind: .credentialImport,
            phase: .canonicalCommitted,
            expectedRevision: 41,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            accounts: [],
            activeAccountID: nil
        )

        let result = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertTrue(harness.files.values.isEmpty)
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testExplicitRemoveAllContinuesValidStaleRemovalJournal() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "recreated@example.invalid",
                refresh: "recreated-refresh"
            ),
            label: "Recreated",
            externalIdentity: .init(email: "recreated@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        XCTAssertEqual(state.revision, 1)
        harness.files.values[.accountFile] = try singleAccountData()
        harness.migrationJournal.journal = AntigravityMigrationJournal(
            operationID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            kind: .removeAllAccounts,
            phase: .removalPending,
            expectedRevision: 0,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            removalCanonicalStateFingerprint:
                String(repeating: "b", count: 64),
            accounts: [],
            activeAccountID: nil
        )

        let result = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertTrue(harness.files.values.isEmpty)
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testStartupDoesNotApplyStaleRemovalJournalToRecreatedAccount() async throws {
        let harness = MigrationHarness()
        let state = try await harness.repository.createAccount(
            credentials: credential(
                email: "reconnected@example.invalid",
                refresh: "reconnected-refresh"
            ),
            label: "Reconnected",
            externalIdentity: .init(email: "reconnected@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        let reference = try XCTUnwrap(
            state.activeAccount?.credentialReference.rawValue
        )
        harness.migrationJournal.journal = AntigravityMigrationJournal(
            operationID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            kind: .removeAllAccounts,
            phase: .removalPending,
            expectedRevision: state.revision,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            removalCanonicalStateFingerprint:
                String(repeating: "b", count: 64),
            accounts: [],
            activeAccountID: nil
        )

        let result = await harness.coordinator.checkForMigration()

        XCTAssertEqual(result.phase, .blockedBeforeCutover)
        XCTAssertEqual(result.blocker, .invalidMigrationJournal)
        XCTAssertEqual(harness.metadata.state, state)
        XCTAssertNotNil(harness.vault.values[reference])
        XCTAssertNotNil(harness.migrationJournal.journal)
    }

    func testExplicitRemoveAllRecoversCorruptMigrationJournal() async throws {
        let harness = MigrationHarness()
        harness.files.values[.accountFile] = try singleAccountData()
        let corrupt = RecoverableCorruptMigrationJournalStore()
        let coordinator = harness.makeCoordinator(
            markerStore: harness.marker,
            journalStore: corrupt
        )

        let result = await coordinator.removeAllAccounts()

        XCTAssertEqual(result.phase, .complete)
        XCTAssertNil(harness.metadata.state)
        XCTAssertTrue(harness.vault.values.isEmpty)
        XCTAssertTrue(harness.files.values.isEmpty)
        XCTAssertNil(try corrupt.load())
    }

    func testRemovalDirectoryFailureRecreatesJournalAndResumes() async throws {
        let harness = MigrationHarness()
        _ = try await harness.repository.createAccount(
            credentials: credential(
                email: "remove@example.invalid",
                refresh: "remove-refresh"
            ),
            label: "Remove",
            externalIdentity: .init(email: "remove@example.invalid"),
            makeActive: true,
            expectedRevision: 0
        )
        harness.files.failRemoveDirectory = true

        let pending = await harness.coordinator.removeAllAccounts()

        XCTAssertEqual(pending.phase, .cleanupPending)
        XCTAssertEqual(pending.blocker, .persistenceFailure)
        XCTAssertNil(harness.metadata.state)
        XCTAssertNotNil(harness.migrationJournal.journal)

        harness.files.failRemoveDirectory = false
        let completed = await harness.restartCoordinator().checkForMigration()
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(harness.migrationJournal.journal)
    }

    func testAutomaticAndInteractiveSecurityQueriesHaveExactPromptContracts() throws {
        let automatic = try XCTUnwrap(
            AntigravityLegacyOAuthKeychainAccess.readQuery(
                source: .bundleIdentifierKeychain,
                bundleIdentifierService: "com.example.fixture",
                authenticationContext: nil
            )
        )
        XCTAssertEqual(
            automatic[kSecAttrService as String] as? String,
            "com.example.fixture"
        )
        XCTAssertEqual(
            automatic[kSecAttrAccount as String] as? String,
            "antigravity-oauth-credentials"
        )
        XCTAssertNotNil(automatic[kSecUseAuthenticationContext as String])
        XCTAssertNotNil(automatic[kSecUseAuthenticationUI as String])

        let context = LAContext()
        let interactiveRead = try XCTUnwrap(
            AntigravityLegacyOAuthKeychainAccess.readQuery(
                source: .claudeUsageKeychain,
                bundleIdentifierService: "com.example.fixture",
                authenticationContext: context
            )
        )
        let interactiveDelete = try XCTUnwrap(
            AntigravityLegacyOAuthKeychainAccess.deleteQuery(
                source: .claudeUsageKeychain,
                bundleIdentifierService: "com.example.fixture",
                authenticationContext: context
            )
        )
        XCTAssertTrue(
            interactiveRead[kSecUseAuthenticationContext as String] as? LAContext
                === context
        )
        XCTAssertTrue(
            interactiveDelete[kSecUseAuthenticationContext as String] as? LAContext
                === context
        )
        XCTAssertNil(interactiveRead[kSecUseAuthenticationUI as String])
        XCTAssertNil(interactiveDelete[kSecUseAuthenticationUI as String])
        XCTAssertNil(interactiveDelete[kSecReturnData as String])
    }

    func testSecurityStatusMappingDistinguishesAutomaticAndInteractiveAccess() {
        let security = MigrationSecurityItemAccess()
        let access = AntigravityLegacyOAuthKeychainAccess(
            bundleIdentifierService: "com.example.fixture",
            securityItemAccess: security
        )

        for status in [
            errSecInteractionNotAllowed,
            errSecAuthFailed,
            errSecUserCanceled,
        ] {
            security.readResult = .init(status: status, data: nil)
            security.deleteStatus = status
            XCTAssertEqual(
                access.read(
                    .bundleIdentifierKeychain,
                    authenticationContext: nil
                ),
                .interactionRequired
            )
            XCTAssertEqual(
                access.delete(
                    .bundleIdentifierKeychain,
                    authenticationContext: nil
                ),
                .interactionRequired
            )
        }

        let context = LAContext()
        security.readResult = .init(status: errSecUserCanceled, data: nil)
        security.deleteStatus = errSecUserCanceled
        XCTAssertEqual(
            access.read(
                .bundleIdentifierKeychain,
                authenticationContext: context
            ),
            .cancelled
        )
        XCTAssertEqual(
            access.delete(
                .bundleIdentifierKeychain,
                authenticationContext: context
            ),
            .cancelled
        )

        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            security.readResult = .init(status: status, data: nil)
            security.deleteStatus = status
            XCTAssertEqual(
                access.read(
                    .bundleIdentifierKeychain,
                    authenticationContext: context
                ),
                .failure(Int(status))
            )
            XCTAssertEqual(
                access.delete(
                    .bundleIdentifierKeychain,
                    authenticationContext: context
                ),
                .failure(Int(status))
            )
        }

        security.readResult = .init(status: errSecSuccess, data: nil)
        XCTAssertEqual(
            access.read(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .invalid
        )
        security.readResult = .init(status: errSecSuccess, data: Data())
        XCTAssertEqual(
            access.read(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .readable(Data())
        )
        security.readResult = .init(status: errSecItemNotFound, data: nil)
        security.deleteStatus = errSecItemNotFound
        XCTAssertEqual(
            access.read(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .notFound
        )
        XCTAssertEqual(
            access.delete(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .absent
        )

        security.readResult = .init(status: -9_999, data: nil)
        security.deleteStatus = -9_999
        XCTAssertEqual(
            access.read(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .failure(-9_999)
        )
        XCTAssertEqual(
            access.delete(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .failure(-9_999)
        )
    }

    func testProductionKeychainAdapterPreservesValueChangedBeforeMove() {
        let original = Data("keychain-a".utf8)
        let replacement = Data("keychain-b".utf8)
        let security = MigrationStatefulSecurityItemAccess(
            service: "com.example.fixture"
        )
        security.originalPayload = original
        security.replaceImmediatelyBeforeMove = replacement
        let access = AntigravityLegacyOAuthKeychainAccess(
            bundleIdentifierService: "com.example.fixture",
            securityItemAccess: security
        )

        let result = access.deleteIfUnchanged(
            .bundleIdentifierKeychain,
            expectedPayloadFingerprint:
                AntigravityMigrationFingerprint.data(original),
            authenticationContext: nil
        )

        XCTAssertEqual(result, .changed)
        XCTAssertEqual(security.originalPayload, replacement)
        XCTAssertNil(security.quarantinePayload)
    }

    func testSecurityUpdateStatusMappingDistinguishesNoUIAndInteractivePaths() {
        let security = MigrationSecurityItemAccess()
        security.readResult = .init(status: errSecItemNotFound, data: nil)
        let access = AntigravityLegacyOAuthKeychainAccess(
            bundleIdentifierService: "com.example.fixture",
            securityItemAccess: security
        )
        let expected = AntigravityMigrationFingerprint.data(Data("a".utf8))

        for status in [
            errSecInteractionNotAllowed,
            errSecAuthFailed,
            errSecUserCanceled,
        ] {
            security.updateStatus = status
            XCTAssertEqual(
                access.deleteIfUnchanged(
                    .bundleIdentifierKeychain,
                    expectedPayloadFingerprint: expected,
                    authenticationContext: nil
                ),
                .interactionRequired
            )
        }

        let context = LAContext()
        security.updateStatus = errSecUserCanceled
        XCTAssertEqual(
            access.deleteIfUnchanged(
                .bundleIdentifierKeychain,
                expectedPayloadFingerprint: expected,
                authenticationContext: context
            ),
            .cancelled
        )
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            security.updateStatus = status
            XCTAssertEqual(
                access.deleteIfUnchanged(
                    .bundleIdentifierKeychain,
                    expectedPayloadFingerprint: expected,
                    authenticationContext: context
                ),
                .failure(Int(status))
            )
        }
        for status in [errSecItemNotFound, errSecDuplicateItem] {
            security.updateStatus = status
            XCTAssertEqual(
                access.deleteIfUnchanged(
                    .bundleIdentifierKeychain,
                    expectedPayloadFingerprint: expected,
                    authenticationContext: nil
                ),
                .absent
            )
        }
    }

    func testProductionKeychainAdapterPreservesOriginalRecreatedAfterMove() {
        let original = Data("keychain-a".utf8)
        let replacement = Data("keychain-b".utf8)
        let security = MigrationStatefulSecurityItemAccess(
            service: "com.example.fixture"
        )
        security.originalPayload = original
        security.recreateImmediatelyAfterMove = replacement
        let access = AntigravityLegacyOAuthKeychainAccess(
            bundleIdentifierService: "com.example.fixture",
            securityItemAccess: security
        )

        let result = access.deleteIfUnchanged(
            .bundleIdentifierKeychain,
            expectedPayloadFingerprint:
                AntigravityMigrationFingerprint.data(original),
            authenticationContext: nil
        )

        XCTAssertEqual(result, .changed)
        XCTAssertEqual(security.originalPayload, replacement)
        XCTAssertNil(security.quarantinePayload)
    }

    func testProductionKeychainAdapterPreservesQuarantineWhenRestoreFails() {
        let original = Data("keychain-a".utf8)
        let replacement = Data("keychain-b".utf8)
        let security = MigrationStatefulSecurityItemAccess(
            service: "com.example.fixture"
        )
        security.originalPayload = original
        security.replaceImmediatelyBeforeMove = replacement
        security.failRestore = true
        let access = AntigravityLegacyOAuthKeychainAccess(
            bundleIdentifierService: "com.example.fixture",
            securityItemAccess: security
        )

        let result = access.deleteIfUnchanged(
            .bundleIdentifierKeychain,
            expectedPayloadFingerprint:
                AntigravityMigrationFingerprint.data(original),
            authenticationContext: nil
        )

        XCTAssertEqual(result, .changed)
        XCTAssertNil(security.originalPayload)
        XCTAssertEqual(security.quarantinePayload, replacement)
    }

    func testProductionKeychainRemoveAllDeletesBothBoundedIdentities() {
        let security = MigrationStatefulSecurityItemAccess(
            service: "com.example.fixture"
        )
        security.originalPayload = Data("original".utf8)
        security.quarantinePayload = Data("quarantine".utf8)
        let access = AntigravityLegacyOAuthKeychainAccess(
            bundleIdentifierService: "com.example.fixture",
            securityItemAccess: security
        )

        XCTAssertEqual(
            access.deleteAllIdentities(
                .bundleIdentifierKeychain,
                authenticationContext: nil
            ),
            .deleted
        )
        XCTAssertNil(security.originalPayload)
        XCTAssertNil(security.quarantinePayload)
    }

    func testProductionFileAdapterRejectsSymlinkWithoutDeletingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("target.json")
        let original = root.appendingPathComponent("oauth_accounts.json")
        let payload = Data("target-payload".utf8)
        try payload.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: original,
            withDestinationURL: target
        )
        let access = AntigravityLegacyOAuthFileAccess(directoryURL: root)

        let result = access.deleteIfUnchanged(
            .accountFile,
            expectedPayloadFingerprint:
                AntigravityMigrationFingerprint.data(payload)
        )

        XCTAssertEqual(result, .changed)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(access.read(.accountFile), .invalid)
        XCTAssertEqual(access.readQuarantine(.accountFile), .notFound)
    }

    func testProductionFileAdapterResumesFixedQuarantineAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let payload = Data("quarantined-a".utf8)
        let quarantine = root.appendingPathComponent(
            ".claudeusage-v2-quarantine-oauth_accounts.json"
        )
        try payload.write(to: quarantine)
        let access = AntigravityLegacyOAuthFileAccess(directoryURL: root)

        XCTAssertEqual(
            access.deleteIfUnchanged(
                .accountFile,
                expectedPayloadFingerprint:
                    AntigravityMigrationFingerprint.data(payload)
            ),
            .deleted
        )
        XCTAssertEqual(access.read(.accountFile), .notFound)
        XCTAssertEqual(access.readQuarantine(.accountFile), .notFound)
    }

    func testProductionFileAdapterDoesNotDeleteRecreatedOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let quarantined = Data("quarantined-a".utf8)
        let replacement = Data("original-b".utf8)
        try quarantined.write(
            to: root.appendingPathComponent(
                ".claudeusage-v2-quarantine-oauth_accounts.json"
            )
        )
        try replacement.write(
            to: root.appendingPathComponent("oauth_accounts.json")
        )
        let access = AntigravityLegacyOAuthFileAccess(directoryURL: root)

        XCTAssertEqual(
            access.deleteIfUnchanged(
                .accountFile,
                expectedPayloadFingerprint:
                    AntigravityMigrationFingerprint.data(quarantined)
            ),
            .changed
        )
        XCTAssertEqual(
            access.read(.accountFile),
            .readable(replacement)
        )
        XCTAssertEqual(access.readQuarantine(.accountFile), .notFound)
    }

    func testProductionFileAdapterRestoresMismatchedQuarantine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let expected = Data("expected-a".utf8)
        let changed = Data("changed-b".utf8)
        try changed.write(
            to: root.appendingPathComponent(
                ".claudeusage-v2-quarantine-oauth_accounts.json"
            )
        )
        let access = AntigravityLegacyOAuthFileAccess(directoryURL: root)

        XCTAssertEqual(
            access.deleteIfUnchanged(
                .accountFile,
                expectedPayloadFingerprint:
                    AntigravityMigrationFingerprint.data(expected)
            ),
            .changed
        )
        XCTAssertEqual(access.read(.accountFile), .readable(changed))
        XCTAssertEqual(access.readQuarantine(.accountFile), .notFound)
    }

    func testJournalAndCompletionMarkerFileStoresUsePrivateModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root
            .appendingPathComponent("Antigravity", isDirectory: true)
            .appendingPathComponent("migration.json")
        let markerURL = root
            .appendingPathComponent("Migrations", isDirectory: true)
            .appendingPathComponent("marker.json")
        let journalStore = AntigravityMigrationJournalFileStore(
            fileURL: journalURL
        )
        let markerStore = AntigravityMigrationCompletionMarkerFileStore(
            fileURL: markerURL
        )
        let journal = AntigravityMigrationJournal(
            operationID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .removeAllAccounts,
            phase: .removalPending,
            expectedRevision: 0,
            sourceInventoryFingerprint: String(repeating: "a", count: 64),
            removalCanonicalStateFingerprint:
                AntigravityMigrationFingerprint.removalCanonicalState(.init()),
            accounts: [],
            activeAccountID: nil
        )
        let marker = validMarker()

        try journalStore.save(journal)
        try markerStore.save(marker)

        XCTAssertEqual(try mode(journalURL), 0o600)
        XCTAssertEqual(try mode(journalURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(markerURL), 0o600)
        XCTAssertEqual(try mode(markerURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try journalStore.load(), journal)
        XCTAssertEqual(try markerStore.load(), marker)
    }

    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Antigravity/legacy-oauth-user-shape-redacted.json")
        return try Data(contentsOf: url)
    }

    private func singleAccountData() throws -> Data {
        try accountStateData(
            [
                legacyAccount(
                    id: "single-account",
                    credentials: credential(
                        email: "single@example.invalid",
                        refresh: "single-refresh"
                    )
                ),
            ],
            activeID: "single-account"
        )
    }

    private func accountStateData(
        _ accounts: [AntigravityOAuthAccount],
        activeID: String?
    ) throws -> Data {
        try JSONEncoder().encode(
            AntigravityOAuthAccountState(
                accounts: accounts,
                activeAccountID: activeID
            )
        )
    }

    private func legacyAccount(
        id: String,
        email: String? = nil,
        credentials: AntigravityOAuthCredentials
    ) -> AntigravityOAuthAccount {
        AntigravityOAuthAccount(
            id: id,
            label: email ?? credentials.email ?? "Fixture",
            email: email ?? credentials.email,
            credentials: credentials,
            createdAtMilliseconds: 1_800_000_000_000,
            updatedAtMilliseconds: 1_800_000_001_000
        )
    }

    private func credential(
        email: String,
        refresh: String,
        access: String = "fixture-access"
    ) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiryDate: Date(timeIntervalSince1970: 1_900_000_000),
            idToken: "fixture-id",
            email: email,
            projectID: "fixture-project",
            clientID: "fixture-client",
            clientSecret: "fixture-client-secret"
        )
    }

    private func validMarker() -> AntigravityMigrationCompletionMarker {
        AntigravityMigrationCompletionMarker(
            version: AntigravityMigrationCompletionMarker.currentVersion,
            completedAtMilliseconds: 1_800_000_000_000
        )
    }

    private func legacySourceFingerprints()
        -> [AntigravityLegacySourceID: String]
    {
        Dictionary(
            uniqueKeysWithValues: AntigravityLegacySourceID.allCases.map {
                ($0, String(repeating: "c", count: 64))
            }
        )
    }

    private func mode(_ url: URL) throws -> Int? {
        let value = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue ?? value as? Int
    }
}

private enum MigrationTestError: Error {
    case injected
}

private final class MigrationHarness {
    let metadata = MigrationMetadataStore()
    let repositoryJournal = MigrationRepositoryJournalStore()
    let vault = MigrationVault()
    let migrationJournal = MigrationCoordinatorJournalStore()
    let marker = MigrationMarkerStore()
    let files = MigrationLegacyFileAccess()
    let keychain = MigrationLegacyKeychainAccess()
    let uuidGenerator = MigrationUUIDGenerator()
    let contextFactory = MigrationContextFactory()

    lazy var repository = AntigravityAccountRepository(
        metadataStore: metadata,
        journalStore: repositoryJournal,
        vault: vault,
        uuidGenerator: { [uuidGenerator] in uuidGenerator.next() },
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    lazy var coordinator = restartCoordinator()

    func makeReconciler() -> AntigravityMigrationReconciler {
        AntigravityMigrationReconciler(
            fileAccess: files,
            keychainAccess: keychain,
            uuidGenerator: { [uuidGenerator] in uuidGenerator.next() },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    func restartCoordinator() -> AntigravityMigrationCoordinator {
        makeCoordinator(markerStore: marker)
    }

    func makeCoordinator(
        markerStore: any AntigravityMigrationCompletionMarking,
        journalStore: (any AntigravityMigrationJournalStoring)? = nil
    ) -> AntigravityMigrationCoordinator {
        AntigravityMigrationCoordinator(
            repository: repository,
            journalStore: journalStore ?? migrationJournal,
            completionMarkerStore: markerStore,
            fileAccess: files,
            keychainAccess: keychain,
            uuidGenerator: { [uuidGenerator] in uuidGenerator.next() },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            authenticationContextFactory: { [contextFactory] in
                contextFactory.make()
            }
        )
    }
}

private struct CorruptMigrationMarkerStore:
    AntigravityMigrationCompletionMarking
{
    nonisolated func load() throws -> AntigravityMigrationCompletionMarker? {
        throw DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "fixture marker corruption"
        ))
    }

    nonisolated func save(
        _ marker: AntigravityMigrationCompletionMarker
    ) throws {
        throw MigrationTestError.injected
    }
}

private final class RecoverableCorruptMigrationMarkerStore:
    AntigravityMigrationCompletionMarking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var isCorrupt = true
    private var stored: AntigravityMigrationCompletionMarker?

    var marker: AntigravityMigrationCompletionMarker? {
        lock.withLock { stored }
    }

    nonisolated func load() throws -> AntigravityMigrationCompletionMarker? {
        try lock.withLock {
            if isCorrupt {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "fixture marker corruption"
                ))
            }
            return stored
        }
    }

    nonisolated func save(
        _ marker: AntigravityMigrationCompletionMarker
    ) throws {
        lock.withLock {
            isCorrupt = false
            stored = marker
        }
    }
}

private final class RecoverableCorruptMigrationJournalStore:
    AntigravityMigrationJournalStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var isCorrupt = true
    private var stored: AntigravityMigrationJournal?

    nonisolated func load() throws -> AntigravityMigrationJournal? {
        try lock.withLock {
            if isCorrupt {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "fixture journal corruption"
                ))
            }
            return stored
        }
    }

    nonisolated func save(_ journal: AntigravityMigrationJournal) throws {
        lock.withLock {
            isCorrupt = false
            stored = journal
        }
    }

    nonisolated func delete() throws {
        lock.withLock {
            isCorrupt = false
            stored = nil
        }
    }
}

private final class MigrationUUIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func next() -> UUID {
        lock.withLock {
            defer { value += 1 }
            return UUID(
                uuidString: String(
                    format: "10000000-0000-0000-0000-%012llx",
                    value
                )
            )!
        }
    }
}

private final class MigrationContextFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func make() -> LAContext {
        lock.withLock { recordedCount += 1 }
        return LAContext()
    }
}

private final class MigrationMetadataStore:
    AntigravityAccountMetadataStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedState: AntigravityAccountRepositoryState?
    private var saveCount = 0
    var failSaveCalls: Set<Int> = []
    var silentDelete = false

    var state: AntigravityAccountRepositoryState? {
        get { lock.withLock { storedState } }
        set { lock.withLock { storedState = newValue } }
    }

    var saveCallCount: Int {
        lock.withLock { saveCount }
    }

    nonisolated func load() throws -> AntigravityAccountRepositoryState? {
        lock.withLock { storedState }
    }

    nonisolated func save(_ state: AntigravityAccountRepositoryState) throws {
        try lock.withLock {
            saveCount += 1
            if failSaveCalls.contains(saveCount) {
                throw MigrationTestError.injected
            }
            storedState = state
        }
    }

    nonisolated func delete() throws {
        lock.withLock {
            guard !silentDelete else { return }
            storedState = nil
        }
    }
}

private final class MigrationRepositoryJournalStore:
    AntigravityAccountOperationJournalStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: AntigravityAccountOperationJournal?

    nonisolated func load() throws -> AntigravityAccountOperationJournal? {
        lock.withLock { stored }
    }

    nonisolated func save(_ journal: AntigravityAccountOperationJournal) throws {
        lock.withLock { stored = journal }
    }

    nonisolated func delete() throws {
        lock.withLock { stored = nil }
    }
}

private final class MigrationVault: OAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var saveCount = 0
    var failSaveCalls: Set<Int> = []
    var failDeleteReferences: Set<String> = []
    var silentDeleteReferences: Set<String> = []

    var values: [String: Data] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var payloadSaveCount: Int {
        lock.withLock { saveCount }
    }

    nonisolated func loadPayload(reference: String) throws -> Data? {
        lock.withLock { storage[reference] }
    }

    nonisolated func savePayload(_ payload: Data, reference: String) throws {
        try lock.withLock {
            saveCount += 1
            if failSaveCalls.contains(saveCount) {
                throw MigrationTestError.injected
            }
            storage[reference] = payload
        }
    }

    nonisolated func deletePayload(reference: String) throws {
        try lock.withLock {
            if failDeleteReferences.contains(reference) {
                throw MigrationTestError.injected
            }
            guard !silentDeleteReferences.contains(reference) else { return }
            storage.removeValue(forKey: reference)
        }
    }

    nonisolated func references(
        in namespace: OAuthCredentialVaultNamespace
    ) throws -> Set<String> {
        lock.withLock {
            Set(storage.keys.filter(namespace.contains))
        }
    }
}

private final class MigrationCoordinatorJournalStore:
    AntigravityMigrationJournalStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: AntigravityMigrationJournal?
    private var history: [AntigravityMigrationJournal] = []
    var silentDropSaves = false
    var failDelete = false

    var journal: AntigravityMigrationJournal? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var savedJournals: [AntigravityMigrationJournal] {
        lock.withLock { history }
    }

    nonisolated func load() throws -> AntigravityMigrationJournal? {
        lock.withLock { stored }
    }

    nonisolated func save(_ journal: AntigravityMigrationJournal) throws {
        lock.withLock {
            history.append(journal)
            guard !silentDropSaves else { return }
            stored = journal
        }
    }

    nonisolated func delete() throws {
        try lock.withLock {
            if failDelete { throw MigrationTestError.injected }
            stored = nil
        }
    }
}

private final class MigrationMarkerStore:
    AntigravityMigrationCompletionMarking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: AntigravityMigrationCompletionMarker?
    var silentDropSaves = false

    var marker: AntigravityMigrationCompletionMarker? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    nonisolated func load() throws -> AntigravityMigrationCompletionMarker? {
        lock.withLock { stored }
    }

    nonisolated func save(_ marker: AntigravityMigrationCompletionMarker) throws {
        lock.withLock {
            guard !silentDropSaves else { return }
            stored = marker
        }
    }
}

private final class MigrationLegacyFileAccess:
    AntigravityLegacyFileAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [AntigravityLegacySourceID: Data] = [:]
    private var quarantineStorage: [AntigravityLegacySourceID: Data] = [:]
    var readFailures: [AntigravityLegacySourceID: Int] = [:]
    var deleteFailures: [AntigravityLegacySourceID: Int] = [:]
    var silentDeleteSources: Set<AntigravityLegacySourceID> = []
    var replaceImmediatelyBeforeQuarantine:
        [AntigravityLegacySourceID: Data] = [:]
    var recreateImmediatelyAfterQuarantine:
        [AntigravityLegacySourceID: Data] = [:]
    var failAfterQuarantineSources: Set<AntigravityLegacySourceID> = []
    var failRestoreSources: Set<AntigravityLegacySourceID> = []
    var failRemoveDirectory = false
    private var removalCalled = false
    private var scriptedReads:
        [AntigravityLegacySourceID: [Data]] = [:]

    var values: [AntigravityLegacySourceID: Data] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var quarantinedValues: [AntigravityLegacySourceID: Data] {
        lock.withLock { quarantineStorage }
    }

    var removeDirectoryIfEmptyCalled: Bool {
        lock.withLock { removalCalled }
    }

    func scriptReads(
        _ values: [Data],
        for source: AntigravityLegacySourceID
    ) {
        lock.withLock {
            scriptedReads[source] = values
        }
    }

    nonisolated func read(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyReadResult {
        lock.withLock {
            if let failure = readFailures[source] { return .failure(failure) }
            if var values = scriptedReads[source], !values.isEmpty {
                let data = values.removeFirst()
                scriptedReads[source] = values
                storage[source] = data
                return .readable(data)
            }
            guard let data = storage[source] else { return .notFound }
            return .readable(data)
        }
    }

    nonisolated func readQuarantine(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyReadResult {
        lock.withLock {
            guard let data = quarantineStorage[source] else { return .notFound }
            return .readable(data)
        }
    }

    nonisolated func deleteIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String
    ) -> AntigravityLegacyDeleteResult {
        lock.withLock {
            if let failure = deleteFailures[source] { return .failure(failure) }
            if silentDeleteSources.contains(source) { return .deleted }
            if quarantineStorage[source] == nil {
                if let replacement =
                    replaceImmediatelyBeforeQuarantine.removeValue(forKey: source)
                {
                    storage[source] = replacement
                }
                guard let payload = storage.removeValue(forKey: source) else {
                    return .absent
                }
                quarantineStorage[source] = payload
                if let recreated =
                    recreateImmediatelyAfterQuarantine.removeValue(forKey: source)
                {
                    storage[source] = recreated
                }
                if failAfterQuarantineSources.remove(source) != nil {
                    return .failure(-777)
                }
            }
            guard let quarantined = quarantineStorage[source] else {
                return .absent
            }
            guard AntigravityMigrationFingerprint.data(quarantined)
                    == expectedPayloadFingerprint
            else {
                if storage[source] == nil,
                   !failRestoreSources.contains(source)
                {
                    storage[source] = quarantineStorage.removeValue(forKey: source)
                }
                return .changed
            }
            quarantineStorage.removeValue(forKey: source)
            return storage[source] == nil ? .deleted : .changed
        }
    }

    nonisolated func deleteAllIdentities(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyDeleteResult {
        lock.withLock {
            if let failure = deleteFailures[source] { return .failure(failure) }
            guard storage[source] != nil || quarantineStorage[source] != nil
            else { return .absent }
            if silentDeleteSources.contains(source) { return .deleted }
            storage.removeValue(forKey: source)
            quarantineStorage.removeValue(forKey: source)
            return .deleted
        }
    }

    nonisolated func removeAntigravityDirectoryIfEmpty() throws {
        try lock.withLock {
            removalCalled = true
            if failRemoveDirectory {
                throw MigrationTestError.injected
            }
        }
    }
}

private final class MigrationLegacyKeychainAccess:
    AntigravityLegacyKeychainAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [AntigravityLegacySourceID: Data] = [:]
    private var quarantineStorage: [AntigravityLegacySourceID: Data] = [:]
    var lockedSources: Set<AntigravityLegacySourceID> = []
    var cancelInteractiveSources: Set<AntigravityLegacySourceID> = []
    var readFailures: [AntigravityLegacySourceID: Int] = [:]
    var deleteFailures: [AntigravityLegacySourceID: Int] = [:]
    var silentDeleteSources: Set<AntigravityLegacySourceID> = []
    var replaceImmediatelyBeforeQuarantine:
        [AntigravityLegacySourceID: Data] = [:]
    var recreateImmediatelyAfterQuarantine:
        [AntigravityLegacySourceID: Data] = [:]
    var failAfterQuarantineSources: Set<AntigravityLegacySourceID> = []
    var failRestoreSources: Set<AntigravityLegacySourceID> = []
    private var readContextIDs: [ObjectIdentifier] = []
    private var deleteContextIDs: [ObjectIdentifier] = []

    var values: [AntigravityLegacySourceID: Data] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var quarantinedValues: [AntigravityLegacySourceID: Data] {
        lock.withLock { quarantineStorage }
    }

    var interactiveReadContextIDs: [ObjectIdentifier] {
        lock.withLock { readContextIDs }
    }

    var interactiveDeleteContextIDs: [ObjectIdentifier] {
        lock.withLock { deleteContextIDs }
    }

    nonisolated func read(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult {
        lock.withLock {
            if let failure = readFailures[source] { return .failure(failure) }
            guard let data = storage[source] else { return .notFound }
            if let authenticationContext {
                readContextIDs.append(ObjectIdentifier(authenticationContext))
                if cancelInteractiveSources.contains(source) {
                    return .cancelled
                }
                return .readable(data)
            }
            if lockedSources.contains(source) { return .interactionRequired }
            return .readable(data)
        }
    }

    nonisolated func readQuarantine(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult {
        lock.withLock {
            guard let data = quarantineStorage[source] else { return .notFound }
            if let authenticationContext {
                readContextIDs.append(ObjectIdentifier(authenticationContext))
                if cancelInteractiveSources.contains(source) {
                    return .cancelled
                }
            } else if lockedSources.contains(source) {
                return .interactionRequired
            }
            return .readable(data)
        }
    }

    nonisolated func deleteIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        lock.withLock {
            if let failure = deleteFailures[source] { return .failure(failure) }
            if let authenticationContext {
                deleteContextIDs.append(ObjectIdentifier(authenticationContext))
                if cancelInteractiveSources.contains(source) {
                    return .cancelled
                }
            } else if lockedSources.contains(source) {
                return .interactionRequired
            }
            if silentDeleteSources.contains(source) { return .deleted }
            if quarantineStorage[source] == nil {
                if let replacement =
                    replaceImmediatelyBeforeQuarantine.removeValue(forKey: source)
                {
                    storage[source] = replacement
                }
                guard let payload = storage.removeValue(forKey: source) else {
                    return .absent
                }
                quarantineStorage[source] = payload
                if let recreated =
                    recreateImmediatelyAfterQuarantine.removeValue(forKey: source)
                {
                    storage[source] = recreated
                }
                if failAfterQuarantineSources.remove(source) != nil {
                    return .failure(-777)
                }
            }
            guard let quarantined = quarantineStorage[source] else {
                return .absent
            }
            guard AntigravityMigrationFingerprint.data(quarantined)
                    == expectedPayloadFingerprint
            else {
                if storage[source] == nil,
                   !failRestoreSources.contains(source)
                {
                    storage[source] = quarantineStorage.removeValue(forKey: source)
                }
                return .changed
            }
            quarantineStorage.removeValue(forKey: source)
            return storage[source] == nil ? .deleted : .changed
        }
    }

    nonisolated func deleteAllIdentities(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        lock.withLock {
            if let failure = deleteFailures[source] { return .failure(failure) }
            guard storage[source] != nil || quarantineStorage[source] != nil
            else { return .absent }
            if let authenticationContext {
                deleteContextIDs.append(ObjectIdentifier(authenticationContext))
                if cancelInteractiveSources.contains(source) {
                    return .cancelled
                }
            } else if lockedSources.contains(source) {
                return .interactionRequired
            }
            if silentDeleteSources.contains(source) { return .deleted }
            storage.removeValue(forKey: source)
            quarantineStorage.removeValue(forKey: source)
            return .deleted
        }
    }
}

private final class MigrationSecurityItemAccess:
    AntigravitySecurityItemAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedReadResult = AntigravitySecurityItemReadResult(
        status: errSecItemNotFound,
        data: nil
    )
    private var storedDeleteStatus = errSecItemNotFound
    private var storedUpdateStatus = errSecItemNotFound

    var readResult: AntigravitySecurityItemReadResult {
        get { lock.withLock { storedReadResult } }
        set { lock.withLock { storedReadResult = newValue } }
    }

    var deleteStatus: OSStatus {
        get { lock.withLock { storedDeleteStatus } }
        set { lock.withLock { storedDeleteStatus = newValue } }
    }

    var updateStatus: OSStatus {
        get { lock.withLock { storedUpdateStatus } }
        set { lock.withLock { storedUpdateStatus = newValue } }
    }

    nonisolated func copyMatching(
        _ query: [String: Any]
    ) -> AntigravitySecurityItemReadResult {
        lock.withLock { storedReadResult }
    }

    nonisolated func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { storedDeleteStatus }
    }

    nonisolated func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        lock.withLock { storedUpdateStatus }
    }
}

private final class MigrationStatefulSecurityItemAccess:
    AntigravitySecurityItemAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let service: String
    private var storage: [String: Data] = [:]
    private var replacementBeforeMove: Data?
    private var recreationAfterMove: Data?
    private var shouldFailRestore = false

    init(service: String) {
        self.service = service
    }

    var originalPayload: Data? {
        get {
            lock.withLock {
                storage[AntigravityOAuthCredentialsStore.legacyKeychainAccount]
            }
        }
        set {
            lock.withLock {
                storage[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
                    newValue
            }
        }
    }

    var quarantinePayload: Data? {
        get {
            lock.withLock {
                storage[AntigravityLegacyOAuthKeychainAccess.quarantineAccount]
            }
        }
        set {
            lock.withLock {
                storage[AntigravityLegacyOAuthKeychainAccess.quarantineAccount] =
                    newValue
            }
        }
    }

    var replaceImmediatelyBeforeMove: Data? {
        get { lock.withLock { replacementBeforeMove } }
        set { lock.withLock { replacementBeforeMove = newValue } }
    }

    var recreateImmediatelyAfterMove: Data? {
        get { lock.withLock { recreationAfterMove } }
        set { lock.withLock { recreationAfterMove = newValue } }
    }

    var failRestore: Bool {
        get { lock.withLock { shouldFailRestore } }
        set { lock.withLock { shouldFailRestore = newValue } }
    }

    nonisolated func copyMatching(
        _ query: [String: Any]
    ) -> AntigravitySecurityItemReadResult {
        lock.withLock {
            guard query[kSecAttrService as String] as? String == service,
                  let account = query[kSecAttrAccount as String] as? String,
                  let payload = storage[account]
            else {
                return .init(status: errSecItemNotFound, data: nil)
            }
            return .init(status: errSecSuccess, data: payload)
        }
    }

    nonisolated func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        lock.withLock {
            guard query[kSecAttrService as String] as? String == service,
                  let sourceAccount =
                    query[kSecAttrAccount as String] as? String,
                  let destinationAccount =
                    attributes[kSecAttrAccount as String] as? String
            else {
                return errSecParam
            }
            if sourceAccount
                == AntigravityOAuthCredentialsStore.legacyKeychainAccount,
               let replacementBeforeMove
            {
                storage[sourceAccount] = replacementBeforeMove
                self.replacementBeforeMove = nil
            }
            if sourceAccount
                == AntigravityLegacyOAuthKeychainAccess.quarantineAccount,
               shouldFailRestore
            {
                return errSecNotAvailable
            }
            guard let payload = storage[sourceAccount] else {
                return errSecItemNotFound
            }
            guard storage[destinationAccount] == nil else {
                return errSecDuplicateItem
            }
            storage.removeValue(forKey: sourceAccount)
            storage[destinationAccount] = payload
            if sourceAccount
                == AntigravityOAuthCredentialsStore.legacyKeychainAccount,
               let recreationAfterMove
            {
                storage[sourceAccount] = recreationAfterMove
                self.recreationAfterMove = nil
            }
            return errSecSuccess
        }
    }

    nonisolated func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            guard query[kSecAttrService as String] as? String == service,
                  let account = query[kSecAttrAccount as String] as? String
            else {
                return errSecParam
            }
            return storage.removeValue(forKey: account) == nil
                ? errSecItemNotFound
                : errSecSuccess
        }
    }
}
