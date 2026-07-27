import XCTest
@testable import ClaudeUsage

final class AntigravityAccountRepositoryTests: XCTestCase {
    func testCreateUsesOpaqueIDsAndKeepsSecretsOutOfMetadataAndJournal() async throws {
        let harness = RepositoryHarness()
        let credentials = makeCredentials(seed: "first")

        let state = try await harness.repository.createAccount(
            credentials: credentials,
            label: "Primary",
            externalIdentity: .init(googleSubject: "subject-1", email: "user@example.com"),
            migrationAliases: ["legacy-user@example.com"],
            makeActive: true,
            expectedRevision: 0
        )

        let account = try XCTUnwrap(state.activeAccount)
        XCTAssertTrue(account.id.isOpaqueUUID)
        XCTAssertTrue(account.credentialReference.isCanonical)
        XCTAssertEqual(state.schemaVersion, 2)
        XCTAssertEqual(state.revision, 1)
        XCTAssertNil(harness.journal.storedJournal)

        let metadataJSON = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(metadataJSON.contains("access-first"))
        XCTAssertFalse(metadataJSON.contains("refresh-first"))
        XCTAssertFalse(metadataJSON.contains("client-secret-first"))

        let snapshot = try await harness.repository.credentialSnapshot(for: account.id)
        XCTAssertEqual(snapshot?.credentials, credentials)
        XCTAssertEqual(snapshot?.repositoryRevision, 1)
    }

    func testCredentialReplacementUsesImmutableReferenceAndCASWithoutChangingActiveAccount() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "first")
        let account = try XCTUnwrap(created.activeAccount)
        let oldReference = account.credentialReference.rawValue

        let updated = try await harness.repository.replaceCredential(
            for: account.id,
            with: makeCredentials(seed: "second"),
            expectedRevision: created.revision
        )

        let updatedAccount = try XCTUnwrap(updated.activeAccount)
        XCTAssertEqual(updatedAccount.id, account.id)
        XCTAssertNotEqual(updatedAccount.credentialReference, account.credentialReference)
        XCTAssertNil(harness.vault.value(for: oldReference))
        XCTAssertNotNil(harness.vault.value(for: updatedAccount.credentialReference.rawValue))

        do {
            _ = try await harness.repository.replaceCredential(
                for: account.id,
                with: makeCredentials(seed: "stale"),
                expectedRevision: created.revision
            )
            XCTFail("stale revision은 credential을 쓸 수 없어야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(
                error,
                .revisionConflict(expected: created.revision, actual: updated.revision)
            )
        }
        XCTAssertEqual(harness.vault.saveCount, 2)
    }

    func testRecoveryDeletesStagedSecretWhenMetadataCommitFailed() async throws {
        let harness = RepositoryHarness()
        harness.metadata.failSaveCall = 1

        do {
            _ = try await harness.create(seed: "staged")
            XCTFail("metadata fault가 create를 실패시켜야 합니다")
        } catch RepositoryStubError.injected {
            // Expected.
        }

        let journal = try XCTUnwrap(harness.journal.storedJournal)
        XCTAssertEqual(journal.phase, .secretStaged)
        let stagedReference = try XCTUnwrap(journal.newReferences.first).rawValue
        XCTAssertNotNil(harness.vault.value(for: stagedReference))
        let journalJSON = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        XCTAssertFalse(journalJSON.contains("access-staged"))
        XCTAssertFalse(journalJSON.contains("refresh-staged"))

        harness.metadata.failSaveCall = nil
        let restarted = harness.makeRestartedRepository()
        let recovered = try await restarted.state()

        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.vault.value(for: stagedReference))
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testRecoveryAcceptsCommittedCreateWhenJournalStillHasSecretStagedPhase() async throws {
        let harness = RepositoryHarness()
        harness.journal.silentDropSaveCalls = [3]

        do {
            _ = try await harness.create(seed: "committed-create")
            XCTFail("metadata commit 뒤 journal phase 저장 실패를 검출해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .journalPersistenceVerificationFailed)
        }

        let committed = try XCTUnwrap(harness.metadata.storedState)
        let reference = try XCTUnwrap(committed.activeAccount?.credentialReference.rawValue)
        XCTAssertEqual(harness.journal.storedJournal?.phase, .secretStaged)
        XCTAssertNotNil(harness.vault.value(for: reference))

        harness.journal.silentDropSaveCalls = []
        let recovered = try await harness.makeRestartedRepository().state()

        XCTAssertEqual(recovered, committed)
        XCTAssertNotNil(harness.vault.value(for: reference))
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testRecoveryKeepsCommittedNewSecretAndCleansOldReference() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "old")
        let account = try XCTUnwrap(created.activeAccount)
        let oldReference = account.credentialReference.rawValue
        harness.vault.failingDeleteReferences = [oldReference]

        do {
            _ = try await harness.repository.replaceCredential(
                for: account.id,
                with: makeCredentials(seed: "new"),
                expectedRevision: created.revision
            )
            XCTFail("old reference cleanup fault가 replace를 실패시켜야 합니다")
        } catch RepositoryStubError.injected {
            // Expected.
        }

        let committed = try XCTUnwrap(harness.metadata.storedState)
        let newReference = try XCTUnwrap(committed.activeAccount?.credentialReference.rawValue)
        XCTAssertNotEqual(newReference, oldReference)
        XCTAssertNotNil(harness.vault.value(for: oldReference))
        XCTAssertNotNil(harness.vault.value(for: newReference))
        XCTAssertEqual(harness.journal.storedJournal?.phase, .metadataCommitted)

        harness.vault.failingDeleteReferences = []
        let restarted = harness.makeRestartedRepository()
        let recovered = try await restarted.state()

        XCTAssertEqual(recovered.activeAccount?.credentialReference.rawValue, newReference)
        XCTAssertNil(harness.vault.value(for: oldReference))
        XCTAssertNotNil(harness.vault.value(for: newReference))
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testRecoveryRejectsReplaceJournalWhoseNewReferenceBelongsToWrongAccount() async throws {
        let harness = RepositoryHarness()
        let first = try await harness.create(seed: "first-owner")
        let firstAccount = try XCTUnwrap(first.activeAccount)
        let second = try await harness.create(seed: "wrong-owner")
        let currentFirst = try XCTUnwrap(second.accounts.first { $0.id == firstAccount.id })
        let wrongAccount = try XCTUnwrap(second.accounts.first { $0.id != firstAccount.id })
        harness.journal.insert(AntigravityAccountOperationJournal(
            operationID: UUID(uuidString: "11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .replaceCredential,
            phase: .metadataCommitted,
            expectedRevision: second.revision - 1,
            accountID: currentFirst.id,
            oldReferences: [currentFirst.credentialReference],
            newReferences: [wrongAccount.credentialReference]
        ))

        do {
            _ = try await harness.makeRestartedRepository().state()
            XCTFail("다른 계정의 new reference를 committed replace로 복구하면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .interruptedOperationRequiresRecovery)
        }

        XCTAssertTrue(harness.vault.deleteAttempts.isEmpty)
        XCTAssertNotNil(harness.vault.value(for: currentFirst.credentialReference.rawValue))
        XCTAssertNotNil(harness.vault.value(for: wrongAccount.credentialReference.rawValue))
        XCTAssertNotNil(harness.journal.storedJournal)
    }

    func testRecoveryRejectsUncommittedReplaceUnlessTargetStillOwnsOldReference() async throws {
        let harness = RepositoryHarness()
        let first = try await harness.create(seed: "replace-target")
        let firstAccount = try XCTUnwrap(first.activeAccount)
        let second = try await harness.create(seed: "old-ref-owner")
        let target = try XCTUnwrap(second.accounts.first { $0.id == firstAccount.id })
        let wrongOldOwner = try XCTUnwrap(second.accounts.first { $0.id != firstAccount.id })
        let stagedReference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "22222222-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        harness.vault.insert(Data("staged".utf8), for: stagedReference.rawValue)
        harness.journal.insert(AntigravityAccountOperationJournal(
            operationID: UUID(uuidString: "33333333-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .replaceCredential,
            phase: .secretStaged,
            expectedRevision: second.revision,
            accountID: target.id,
            oldReferences: [wrongOldOwner.credentialReference],
            newReferences: [stagedReference]
        ))

        do {
            _ = try await harness.makeRestartedRepository().state()
            XCTFail("target가 old reference를 소유하지 않는 replace rollback은 거부해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .interruptedOperationRequiresRecovery)
        }

        XCTAssertTrue(harness.vault.deleteAttempts.isEmpty)
        XCTAssertNotNil(harness.vault.value(for: stagedReference.rawValue))
        XCTAssertNotNil(harness.journal.storedJournal)
    }

    func testDeletionRemainsPendingAndUnselectableUntilVaultCleanupRecovers() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "delete")
        let account = try XCTUnwrap(created.activeAccount)
        harness.vault.failingDeleteReferences = [account.credentialReference.rawValue]

        do {
            _ = try await harness.repository.deleteAccount(
                id: account.id,
                expectedRevision: created.revision
            )
            XCTFail("vault delete fault가 account removal을 중단해야 합니다")
        } catch RepositoryStubError.injected {
            // Expected.
        }

        let pending = try XCTUnwrap(harness.metadata.storedState)
        XCTAssertEqual(pending.accounts.first?.lifecycle, .pendingDeletion)
        XCTAssertNil(pending.activeAccountID)
        XCTAssertNotNil(harness.journal.storedJournal)

        harness.vault.failingDeleteReferences = []
        let restarted = harness.makeRestartedRepository()
        let recovered = try await restarted.state()

        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.vault.value(for: account.credentialReference.rawValue))
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testRecoveryRejectsDeleteAccountPhaseThatCannotBePersistedByTheOperation() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "delete-phase")
        let account = try XCTUnwrap(created.activeAccount)
        harness.journal.insert(AntigravityAccountOperationJournal(
            operationID: UUID(uuidString: "44444444-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .deleteAccount,
            phase: .secretStaged,
            expectedRevision: created.revision,
            accountID: account.id,
            oldReferences: [account.credentialReference],
            newReferences: []
        ))

        do {
            _ = try await harness.makeRestartedRepository().state()
            XCTFail("deleteAccount에 존재할 수 없는 phase는 복구 전에 거부해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .invalidMetadata)
        }

        XCTAssertTrue(harness.vault.deleteAttempts.isEmpty)
        XCTAssertNotNil(harness.vault.value(for: account.credentialReference.rawValue))
    }

    func testRecoveryAcceptsPendingDeleteAccountWhenJournalStillHasPlannedPhase() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "delete-planned")
        let account = try XCTUnwrap(created.activeAccount)
        harness.journal.silentDropSaveCalls = [5]

        do {
            _ = try await harness.repository.deleteAccount(
                id: account.id,
                expectedRevision: created.revision
            )
            XCTFail("pending metadata 뒤 journal phase 저장 실패를 검출해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .journalPersistenceVerificationFailed)
        }

        XCTAssertEqual(harness.metadata.storedState?.accounts.first?.lifecycle, .pendingDeletion)
        XCTAssertEqual(harness.journal.storedJournal?.phase, .planned)

        harness.journal.silentDropSaveCalls = []
        let recovered = try await harness.makeRestartedRepository().state()

        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.vault.value(for: account.credentialReference.rawValue))
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testDeletingActiveAccountAutoSelectsOnlyWhenExactlyOneUsableAccountRemains() async throws {
        let harness = RepositoryHarness()
        let first = try await harness.create(seed: "one")
        let firstID = try XCTUnwrap(first.activeAccountID)
        let second = try await harness.repository.createAccount(
            credentials: makeCredentials(seed: "two"),
            label: "Two",
            externalIdentity: .init(email: "two@example.com"),
            makeActive: false,
            expectedRevision: first.revision
        )

        let afterFirstDeletion = try await harness.repository.deleteAccount(
            id: firstID,
            expectedRevision: second.revision
        )
        XCTAssertEqual(afterFirstDeletion.activeAccountID, afterFirstDeletion.accounts.first?.id)

        let third = try await harness.repository.createAccount(
            credentials: makeCredentials(seed: "three"),
            label: "Three",
            externalIdentity: .init(email: "three@example.com"),
            makeActive: false,
            expectedRevision: afterFirstDeletion.revision
        )
        let activeID = try XCTUnwrap(third.activeAccountID)
        let fourth = try await harness.repository.createAccount(
            credentials: makeCredentials(seed: "four"),
            label: "Four",
            externalIdentity: .init(email: "four@example.com"),
            makeActive: false,
            expectedRevision: third.revision
        )

        let afterSecondDeletion = try await harness.repository.deleteAccount(
            id: activeID,
            expectedRevision: fourth.revision
        )
        XCTAssertEqual(afterSecondDeletion.usableAccounts.count, 2)
        XCTAssertNil(afterSecondDeletion.activeAccountID)
    }

    func testDeleteAllUsesNamespaceEnumerationRemovesOrphansAndDoesNotResurrect() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "all")
        let orphan = "oauth.antigravity.v2.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let claudeReference = KeychainClaudeOAuthCredentialVault.account
        harness.vault.insert(Data("orphan".utf8), for: orphan)
        harness.vault.insert(Data("claude".utf8), for: claudeReference)

        try await harness.repository.deleteAll(expectedRevision: created.revision)

        XCTAssertNil(harness.metadata.storedState)
        XCTAssertNil(harness.journal.storedJournal)
        XCTAssertTrue(
            try harness.vault.references(in: AntigravityAccountRepository.credentialNamespace).isEmpty
        )
        XCTAssertNotNil(harness.vault.value(for: claudeReference))

        let restarted = harness.makeRestartedRepository()
        let state = try await restarted.state()
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertNil(state.activeAccountID)
    }

    func testDeleteAllFailureLeavesPendingStateAndRestartCompletesCleanup() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "retry-all")
        let reference = try XCTUnwrap(created.activeAccount?.credentialReference.rawValue)
        harness.vault.failingDeleteReferences = [reference]

        do {
            try await harness.repository.deleteAll(expectedRevision: created.revision)
            XCTFail("namespace cleanup fault가 delete-all을 중단해야 합니다")
        } catch RepositoryStubError.injected {
            // Expected.
        }

        let pending = try XCTUnwrap(harness.metadata.storedState)
        XCTAssertTrue(pending.accounts.allSatisfy { $0.lifecycle == .pendingDeletion })
        XCTAssertNil(pending.activeAccountID)
        XCTAssertEqual(harness.journal.storedJournal?.kind, .deleteAll)

        harness.vault.failingDeleteReferences = []
        let restarted = harness.makeRestartedRepository()
        let recovered = try await restarted.state()

        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.metadata.storedState)
        XCTAssertNil(harness.journal.storedJournal)
        XCTAssertNil(harness.vault.value(for: reference))
    }

    func testStaleDeleteAllJournalIsRejectedBeforeNamespaceAccess() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "stale-delete-all")
        let references = Set(created.accounts.map(\.credentialReference))
        harness.journal.insert(AntigravityAccountOperationJournal(
            operationID: UUID(uuidString: "55555555-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .deleteAll,
            phase: .metadataCommitted,
            expectedRevision: created.revision,
            accountID: nil,
            oldReferences: references,
            newReferences: []
        ))

        do {
            _ = try await harness.makeRestartedRepository().state()
            XCTFail("active metadata와 결합할 수 없는 stale deleteAll journal은 거부해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .interruptedOperationRequiresRecovery)
        }

        XCTAssertEqual(harness.vault.enumerationCount, 0)
        XCTAssertTrue(harness.vault.deleteAttempts.isEmpty)
        XCTAssertNotNil(
            harness.vault.value(for: try XCTUnwrap(created.activeAccount).credentialReference.rawValue)
        )
        XCTAssertNotNil(harness.journal.storedJournal)
    }

    func testDeleteAllRecoveryAfterMetadataDeletionDoesNotTouchNamespaceAgain() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "delete-all-final-journal")
        let reference = try XCTUnwrap(created.activeAccount?.credentialReference.rawValue)
        harness.journal.silentDropDelete = true

        do {
            try await harness.repository.deleteAll(expectedRevision: created.revision)
            XCTFail("남아 있는 최종 journal은 성공으로 처리하면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .journalPersistenceVerificationFailed)
        }

        XCTAssertNil(harness.metadata.storedState)
        XCTAssertEqual(harness.journal.storedJournal?.phase, .vaultCleanupCompleted)
        XCTAssertNil(harness.vault.value(for: reference))
        let enumerationCountBeforeRecovery = harness.vault.enumerationCount

        harness.journal.silentDropDelete = false
        let recovered = try await harness.makeRestartedRepository().state()

        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.journal.storedJournal)
        XCTAssertEqual(harness.vault.enumerationCount, enumerationCountBeforeRecovery)
    }

    func testRecoveryAcceptsPendingDeleteAllWhenJournalStillHasPlannedPhase() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "delete-all-planned")
        let reference = try XCTUnwrap(created.activeAccount?.credentialReference.rawValue)
        harness.journal.silentDropSaveCalls = [5]

        do {
            try await harness.repository.deleteAll(expectedRevision: created.revision)
            XCTFail("pending deleteAll metadata 뒤 journal phase 저장 실패를 검출해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .journalPersistenceVerificationFailed)
        }

        XCTAssertEqual(harness.journal.storedJournal?.phase, .planned)
        XCTAssertTrue(
            try XCTUnwrap(harness.metadata.storedState)
                .accounts
                .allSatisfy { $0.lifecycle == .pendingDeletion }
        )

        harness.journal.silentDropSaveCalls = []
        let recovered = try await harness.makeRestartedRepository().state()

        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.metadata.storedState)
        XCTAssertNil(harness.journal.storedJournal)
        XCTAssertNil(harness.vault.value(for: reference))
    }

    func testOrphanCleanupIsBoundedToAntigravityNamespace() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "keep")
        let kept = try XCTUnwrap(created.activeAccount?.credentialReference.rawValue)
        let orphan = "oauth.antigravity.v2.bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let claudeReference = KeychainClaudeOAuthCredentialVault.account
        harness.vault.insert(Data("orphan".utf8), for: orphan)
        harness.vault.insert(Data("claude".utf8), for: claudeReference)

        let result = try await harness.repository.cleanupOrphanedCredentials()

        XCTAssertEqual(result.deletedReferences, [orphan])
        XCTAssertEqual(result.preservedReferences, [kept])
        XCTAssertNotNil(harness.vault.value(for: kept))
        XCTAssertNotNil(harness.vault.value(for: claudeReference))
    }

    func testSilentJournalSaveFailureStopsBeforeSecretStaging() async throws {
        let harness = RepositoryHarness()
        harness.journal.silentDropSaveCalls = [1]

        do {
            _ = try await harness.create(seed: "journal-drop")
            XCTFail("persist되지 않은 journal은 즉시 검출해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .journalPersistenceVerificationFailed)
        }

        XCTAssertEqual(harness.vault.saveCount, 0)
        XCTAssertNil(harness.metadata.storedState)
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testSilentMetadataSaveFailureDoesNotAdvanceCommittedPhase() async throws {
        let harness = RepositoryHarness()
        harness.metadata.silentDropSaveCalls = [1]

        do {
            _ = try await harness.create(seed: "metadata-drop")
            XCTFail("persist되지 않은 metadata는 즉시 검출해야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .metadataPersistenceVerificationFailed)
        }

        let journal = try XCTUnwrap(harness.journal.storedJournal)
        XCTAssertEqual(journal.phase, .secretStaged)
        XCTAssertNil(harness.metadata.storedState)
        XCTAssertNotNil(
            harness.vault.value(for: try XCTUnwrap(journal.newReferences.first).rawValue)
        )
    }

    func testSilentVaultDeleteFailureLeavesPendingDeletionForRecovery() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "silent-delete")
        let account = try XCTUnwrap(created.activeAccount)
        harness.vault.silentDropDeleteReferences = [account.credentialReference.rawValue]

        do {
            _ = try await harness.repository.deleteAccount(
                id: account.id,
                expectedRevision: created.revision
            )
            XCTFail("실제로 삭제되지 않은 vault item을 성공 처리하면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .credentialDeletionVerificationFailed)
        }

        XCTAssertEqual(harness.metadata.storedState?.accounts.first?.lifecycle, .pendingDeletion)
        XCTAssertEqual(harness.journal.storedJournal?.phase, .metadataCommitted)
        XCTAssertNotNil(harness.vault.value(for: account.credentialReference.rawValue))

        harness.vault.silentDropDeleteReferences = []
        let recovered = try await harness.makeRestartedRepository().state()
        XCTAssertTrue(recovered.accounts.isEmpty)
    }

    func testSilentMetadataDeleteFailureKeepsDeleteAllJournalUntilRestart() async throws {
        let harness = RepositoryHarness()
        let created = try await harness.create(seed: "metadata-delete-drop")
        harness.metadata.silentDropDelete = true

        do {
            try await harness.repository.deleteAll(expectedRevision: created.revision)
            XCTFail("metadata delete 결과가 남아 있으면 성공 처리하면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .metadataPersistenceVerificationFailed)
        }

        XCTAssertNotNil(harness.metadata.storedState)
        XCTAssertEqual(harness.journal.storedJournal?.kind, .deleteAll)
        XCTAssertTrue(
            try harness.vault.references(in: AntigravityAccountRepository.credentialNamespace).isEmpty
        )

        harness.metadata.silentDropDelete = false
        let recovered = try await harness.makeRestartedRepository().state()
        XCTAssertTrue(recovered.accounts.isEmpty)
        XCTAssertNil(harness.metadata.storedState)
        XCTAssertNil(harness.journal.storedJournal)
    }

    func testMalformedDeleteAllJournalIsRejectedBeforeNamespaceEnumeration() async throws {
        let harness = RepositoryHarness()
        let accountID = AntigravityAccountID(
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let reference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        harness.journal.insert(AntigravityAccountOperationJournal(
            operationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            kind: .deleteAll,
            expectedRevision: 0,
            accountID: accountID,
            oldReferences: [],
            newReferences: [reference]
        ))
        harness.vault.insert(Data("orphan".utf8), for: reference.rawValue)

        do {
            _ = try await harness.repository.state()
            XCTFail("shape가 잘못된 delete-all journal은 복구하면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .invalidMetadata)
        }

        XCTAssertEqual(harness.vault.enumerationCount, 0)
        XCTAssertTrue(harness.vault.deleteAttempts.isEmpty)
        XCTAssertNotNil(harness.vault.value(for: reference.rawValue))
    }

    func testConcurrentMutationsWithSameRevisionAllowExactlyOneCASWinner() async throws {
        let harness = RepositoryHarness()
        let repository = harness.repository
        let first = makeCredentials(seed: "concurrent-one")
        let second = makeCredentials(seed: "concurrent-two")

        let outcomes = await withTaskGroup(of: String.self) { group in
            for (label, credentials) in [("One", first), ("Two", second)] {
                group.addTask {
                    do {
                        _ = try await repository.createAccount(
                            credentials: credentials,
                            label: label,
                            externalIdentity: .init(email: "\(label.lowercased())@example.com"),
                            makeActive: true,
                            expectedRevision: 0
                        )
                        return "success"
                    } catch AntigravityAccountRepositoryError.revisionConflict(expected: 0, actual: 1) {
                        return "conflict"
                    } catch {
                        return "unexpected"
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(outcomes.filter { $0 == "success" }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == "conflict" }.count, 1)
        XCTAssertFalse(outcomes.contains("unexpected"))
        let state = try await repository.state()
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.accounts.count, 1)
        XCTAssertEqual(harness.vault.saveCount, 1)
    }

    func testCanonicalFileStoresEnforceAndVerifyPrivateModes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeUsageCanonicalStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("Antigravity", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? fileManager.removeItem(at: root) }

        let metadataURL = directory.appendingPathComponent("accounts.json")
        let journalURL = directory.appendingPathComponent("account-operation.json")
        let metadataStore = AntigravityAccountMetadataFileStore(
            fileURL: metadataURL,
            fileManager: fileManager
        )
        let journalStore = AntigravityAccountOperationJournalFileStore(
            fileURL: journalURL,
            fileManager: fileManager
        )
        let state = AntigravityAccountRepositoryState()
        let journal = AntigravityAccountOperationJournal(
            operationID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            kind: .deleteAll,
            expectedRevision: 0,
            accountID: nil,
            oldReferences: [],
            newReferences: []
        )

        try metadataStore.save(state)
        try journalStore.save(journal)

        XCTAssertEqual(try posixMode(at: directory), 0o700)
        XCTAssertEqual(try posixMode(at: metadataURL), 0o600)
        XCTAssertEqual(try posixMode(at: journalURL), 0o600)
        XCTAssertEqual(try metadataStore.load(), state)
        XCTAssertEqual(try journalStore.load(), journal)
    }

    func testMigrationInspectionDistinguishesAbsentMetadataAndMissingCanonicalSecret() async throws {
        let harness = RepositoryHarness()

        let absent = try await harness.repository.inspectCanonicalForMigration()
        XCTAssertFalse(absent.metadataExists)
        XCTAssertTrue(absent.state.accounts.isEmpty)
        XCTAssertTrue(absent.missingOrInvalidCredentialAccountIDs.isEmpty)

        let created = try await harness.create(seed: "canonical")
        let account = try XCTUnwrap(created.activeAccount)
        harness.vault.insert(
            Data(),
            for: account.credentialReference.rawValue
        )

        let invalid = try await harness.repository.inspectCanonicalForMigration()
        XCTAssertTrue(invalid.metadataExists)
        XCTAssertEqual(invalid.state, created)
        XCTAssertEqual(invalid.missingOrInvalidCredentialAccountIDs, [account.id])
        XCTAssertFalse(invalid.hasValidCanonicalState)
    }

    func testMigrationStagingIsIdempotentButNeverOverwritesReferenceCollision() async throws {
        let harness = RepositoryHarness()
        let reference = AntigravityCredentialReference(
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let original = makeCredentials(seed: "original")

        try await harness.repository.stageMigrationCredential(
            original,
            reference: reference
        )
        try await harness.repository.stageMigrationCredential(
            original,
            reference: reference
        )
        XCTAssertEqual(harness.vault.saveCount, 1)

        let semanticallyIdenticalHarness = RepositoryHarness()
        let credentialObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        )
        let differentlyFormattedEnvelope = try JSONSerialization.data(
            withJSONObject: [
                "credentials": credentialObject,
                "schemaVersion": 2,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        semanticallyIdenticalHarness.vault.insert(
            differentlyFormattedEnvelope,
            for: reference.rawValue
        )
        try await semanticallyIdenticalHarness.repository.stageMigrationCredential(
            original,
            reference: reference
        )
        XCTAssertEqual(semanticallyIdenticalHarness.vault.saveCount, 0)

        do {
            try await harness.repository.stageMigrationCredential(
                makeCredentials(seed: "different"),
                reference: reference
            )
            XCTFail("같은 immutable reference에 다른 secret을 덮어쓰면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .credentialReferenceCollision)
        }
        let loaded = try await harness.repository.migrationCredential(reference: reference)
        XCTAssertEqual(loaded, original)
    }

    func testMigrationCommitPublishesAllAccountsInOneRevisionAndResumesExactly() async throws {
        let harness = RepositoryHarness()
        let plan = migrationPlan()
        let credentials = [
            makeCredentials(seed: "migration-one"),
            makeCredentials(seed: "migration-two"),
        ]
        for (planned, credential) in zip(plan.accounts, credentials) {
            try await harness.repository.stageMigrationCredential(
                credential,
                reference: planned.credentialReference
            )
        }

        let committed = try await harness.repository.commitMigration(plan)
        XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(committed.accounts.count, 2)
        XCTAssertEqual(committed.activeAccountID, plan.activeAccountID)
        XCTAssertEqual(harness.metadata.storedState, committed)

        let resumed = try await harness.repository.commitMigration(plan)
        XCTAssertEqual(resumed, committed)
    }

    func testMigrationCommitProtectsExistingCanonicalStateAndMissingVaultItem() async throws {
        let existingHarness = RepositoryHarness()
        _ = try await existingHarness.create(seed: "existing")
        let plan = migrationPlan()
        for account in plan.accounts {
            try await existingHarness.repository.stageMigrationCredential(
                makeCredentials(seed: account.id.rawValue),
                reference: account.credentialReference
            )
        }
        do {
            _ = try await existingHarness.repository.commitMigration(plan)
            XCTFail("기존 canonical metadata를 migration이 대체하면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .canonicalStateAlreadyExists)
        }

        let missingHarness = RepositoryHarness()
        try await missingHarness.repository.stageMigrationCredential(
            makeCredentials(seed: "only-one"),
            reference: plan.accounts[0].credentialReference
        )
        do {
            _ = try await missingHarness.repository.commitMigration(plan)
            XCTFail("모든 vault item을 검증하기 전에 metadata를 써서는 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .invalidCredential)
        }
        XCTAssertNil(missingHarness.metadata.storedState)
    }

    func testMigrationRollbackCannotDeleteCredentialOwnedByCanonicalMetadata() async throws {
        let harness = RepositoryHarness()
        let plan = migrationPlan()
        for account in plan.accounts {
            try await harness.repository.stageMigrationCredential(
                makeCredentials(seed: account.id.rawValue),
                reference: account.credentialReference
            )
        }
        _ = try await harness.repository.commitMigration(plan)

        do {
            try await harness.repository.discardStagedMigrationCredential(
                reference: plan.accounts[0].credentialReference
            )
            XCTFail("canonical metadata가 소유한 secret은 rollback할 수 없어야 합니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .credentialReferenceIsCanonical)
        }
        XCTAssertNotNil(
            harness.vault.value(for: plan.accounts[0].credentialReference.rawValue)
        )
    }

    func testMigrationPlanRejectsNonFiniteOrRegressingTimestamps() async throws {
        let harness = RepositoryHarness()
        let valid = migrationPlan()
        let first = valid.accounts[0]
        let invalidAccount = AntigravityMigrationPlannedAccount(
            id: first.id,
            label: first.label,
            externalIdentity: first.externalIdentity,
            migrationAliases: first.migrationAliases,
            credentialReference: first.credentialReference,
            createdAtMilliseconds: .nan,
            updatedAtMilliseconds: -1
        )
        let invalid = AntigravityMigrationRepositoryPlan(
            expectedRevision: 0,
            activeAccountID: invalidAccount.id,
            accounts: [invalidAccount]
        )
        try await harness.repository.stageMigrationCredential(
            makeCredentials(seed: "invalid-time"),
            reference: invalidAccount.credentialReference
        )

        do {
            _ = try await harness.repository.commitMigration(invalid)
            XCTFail("비정상 timestamp가 canonical metadata에 들어가면 안 됩니다")
        } catch let error as AntigravityAccountRepositoryError {
            XCTAssertEqual(error, .invalidMetadata)
        }
        XCTAssertNil(harness.metadata.storedState)
    }

    private func makeCredentials(seed: String) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: "access-\(seed)",
            refreshToken: "refresh-\(seed)",
            expiryDate: Date(timeIntervalSince1970: 1_900_000_000),
            idToken: "id-\(seed)",
            email: "\(seed)@example.com",
            projectID: "project-\(seed)",
            clientID: "client-\(seed)",
            clientSecret: "client-secret-\(seed)"
        )
    }

    private func migrationPlan() -> AntigravityMigrationRepositoryPlan {
        let firstID = AntigravityAccountID(
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let secondID = AntigravityAccountID(
            uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        return AntigravityMigrationRepositoryPlan(
            expectedRevision: 0,
            activeAccountID: secondID,
            accounts: [
                AntigravityMigrationPlannedAccount(
                    id: firstID,
                    label: "First",
                    externalIdentity: .init(email: "first@example.com"),
                    migrationAliases: ["legacy-first"],
                    credentialReference: AntigravityCredentialReference(
                        uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
                    ),
                    createdAtMilliseconds: 1,
                    updatedAtMilliseconds: 2
                ),
                AntigravityMigrationPlannedAccount(
                    id: secondID,
                    label: "Second",
                    externalIdentity: .init(email: "second@example.com"),
                    migrationAliases: ["legacy-second"],
                    credentialReference: AntigravityCredentialReference(
                        uuid: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
                    ),
                    createdAtMilliseconds: 3,
                    updatedAtMilliseconds: 4
                ),
            ]
        )
    }

    private func posixMode(at url: URL) throws -> Int? {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue ?? value as? Int
    }
}

private enum RepositoryStubError: Error {
    case injected
}

private final class RepositoryHarness {
    let metadata = InMemoryAntigravityMetadataStore()
    let journal = InMemoryAntigravityJournalStore()
    let vault = InMemoryAntigravityVault()
    let uuids = DeterministicUUIDGenerator()
    lazy var repository = makeRestartedRepository()

    func makeRestartedRepository() -> AntigravityAccountRepository {
        AntigravityAccountRepository(
            metadataStore: metadata,
            journalStore: journal,
            vault: vault,
            uuidGenerator: { [uuids] in uuids.next() },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    func create(seed: String) async throws -> AntigravityAccountRepositoryState {
        try await repository.createAccount(
            credentials: AntigravityOAuthCredentials(
                accessToken: "access-\(seed)",
                refreshToken: "refresh-\(seed)",
                expiryDate: Date(timeIntervalSince1970: 1_900_000_000),
                idToken: nil,
                email: "\(seed)@example.com",
                projectID: nil,
                clientID: "client-\(seed)",
                clientSecret: nil
            ),
            label: seed.capitalized,
            externalIdentity: .init(email: "\(seed)@example.com"),
            makeActive: true,
            expectedRevision: metadata.storedState?.revision ?? 0
        )
    }
}

private final class DeterministicUUIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 1

    nonisolated func next() -> UUID {
        lock.withLock {
            defer { nextValue += 1 }
            let suffix = String(format: "%012llx", nextValue)
            return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        }
    }
}

private final class InMemoryAntigravityMetadataStore:
    AntigravityAccountMetadataStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state: AntigravityAccountRepositoryState?
    private var saveCalls = 0
    var failSaveCall: Int?
    var silentDropSaveCalls: Set<Int> = []
    var silentDropDelete = false

    var storedState: AntigravityAccountRepositoryState? {
        lock.withLock { state }
    }

    nonisolated func load() throws -> AntigravityAccountRepositoryState? {
        lock.withLock { state }
    }

    nonisolated func save(_ state: AntigravityAccountRepositoryState) throws {
        try lock.withLock {
            saveCalls += 1
            if saveCalls == failSaveCall { throw RepositoryStubError.injected }
            if silentDropSaveCalls.contains(saveCalls) { return }
            self.state = state
        }
    }

    nonisolated func delete() throws {
        lock.withLock {
            guard !silentDropDelete else { return }
            state = nil
        }
    }
}

private final class InMemoryAntigravityJournalStore:
    AntigravityAccountOperationJournalStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var journal: AntigravityAccountOperationJournal?
    private var saveCalls = 0
    var silentDropSaveCalls: Set<Int> = []
    var silentDropDelete = false

    var storedJournal: AntigravityAccountOperationJournal? {
        lock.withLock { journal }
    }

    func insert(_ journal: AntigravityAccountOperationJournal) {
        lock.withLock { self.journal = journal }
    }

    nonisolated func load() throws -> AntigravityAccountOperationJournal? {
        lock.withLock { journal }
    }

    nonisolated func save(_ journal: AntigravityAccountOperationJournal) throws {
        lock.withLock {
            saveCalls += 1
            guard !silentDropSaveCalls.contains(saveCalls) else { return }
            self.journal = journal
        }
    }

    nonisolated func delete() throws {
        lock.withLock {
            guard !silentDropDelete else { return }
            journal = nil
        }
    }
}

private final class InMemoryAntigravityVault: OAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var recordedSaveCount = 0
    private var recordedEnumerationCount = 0
    private var recordedDeleteAttempts: [String] = []
    var failingDeleteReferences: Set<String> = []
    var silentDropDeleteReferences: Set<String> = []

    var saveCount: Int { lock.withLock { recordedSaveCount } }
    var enumerationCount: Int { lock.withLock { recordedEnumerationCount } }
    var deleteAttempts: [String] { lock.withLock { recordedDeleteAttempts } }

    func value(for reference: String) -> Data? {
        lock.withLock { values[reference] }
    }

    func insert(_ payload: Data, for reference: String) {
        lock.withLock { values[reference] = payload }
    }

    nonisolated func loadPayload(reference: String) throws -> Data? {
        lock.withLock { values[reference] }
    }

    nonisolated func savePayload(_ payload: Data, reference: String) throws {
        lock.withLock {
            recordedSaveCount += 1
            values[reference] = payload
        }
    }

    nonisolated func deletePayload(reference: String) throws {
        try lock.withLock {
            recordedDeleteAttempts.append(reference)
            if failingDeleteReferences.contains(reference) {
                throw RepositoryStubError.injected
            }
            if silentDropDeleteReferences.contains(reference) { return }
            values.removeValue(forKey: reference)
        }
    }

    nonisolated func references(in namespace: OAuthCredentialVaultNamespace) throws -> Set<String> {
        lock.withLock {
            recordedEnumerationCount += 1
            return Set(values.keys.filter(namespace.contains))
        }
    }
}
