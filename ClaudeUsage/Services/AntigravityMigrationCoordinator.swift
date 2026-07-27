import Foundation
import LocalAuthentication

/// Dormant credential migration coordinator. No current AppDelegate or runtime
/// service constructs this actor; migration UI/cutover will wire it in a later
/// stage only after the legacy readers are retired together.
actor AntigravityMigrationCoordinator {
    private enum OperationIntent: Equatable, Sendable {
        case migrationCheck
        case interactiveMigration
        case removal
        case interactiveRemoval
    }

    private struct InFlightOperation {
        let id: UInt64
        let intent: OperationIntent
        let task: Task<AntigravityMigrationStatus, Never>
    }

    private enum CleanupPayloadBinding {
        case absent
        case ready(String, AntigravityLegacySourceOutcome)
        case interactionRequired
        case changed(AntigravityLegacySourceOutcome)
    }

    private let repository: AntigravityAccountRepository
    private let journalStore: any AntigravityMigrationJournalStoring
    private let completionMarkerStore: any AntigravityMigrationCompletionMarking
    private let fileAccess: any AntigravityLegacyFileAccessing
    private let keychainAccess: any AntigravityLegacyKeychainAccessing
    private let reconciler: AntigravityMigrationReconciler
    private let uuidGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let authenticationContextFactory: @Sendable () -> LAContext
    private var authorizationCancelledThisSession = false
    private var inFlightOperation: InFlightOperation?
    private var nextInFlightOperationID: UInt64 = 0

    init(
        repository: AntigravityAccountRepository,
        journalStore: any AntigravityMigrationJournalStoring = AntigravityMigrationJournalFileStore(),
        completionMarkerStore: any AntigravityMigrationCompletionMarking =
            AntigravityMigrationCompletionMarkerFileStore(),
        fileAccess: any AntigravityLegacyFileAccessing = AntigravityLegacyOAuthFileAccess(),
        keychainAccess: any AntigravityLegacyKeychainAccessing =
            AntigravityLegacyOAuthKeychainAccess(),
        uuidGenerator: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init,
        authenticationContextFactory: @escaping @Sendable () -> LAContext = LAContext.init
    ) {
        self.repository = repository
        self.journalStore = journalStore
        self.completionMarkerStore = completionMarkerStore
        self.fileAccess = fileAccess
        self.keychainAccess = keychainAccess
        self.reconciler = AntigravityMigrationReconciler(
            fileAccess: fileAccess,
            keychainAccess: keychainAccess,
            uuidGenerator: uuidGenerator,
            now: now
        )
        self.uuidGenerator = uuidGenerator
        self.now = now
        self.authenticationContextFactory = authenticationContextFactory
    }

    /// Prompt-free startup/preflight path.
    func checkForMigration() async -> AntigravityMigrationStatus {
        await performSingleFlight(.migrationCheck)
    }

    /// The only credential import/cleanup entry point allowed to present
    /// Keychain authentication UI. One context is reused for the entire
    /// read -> canonical write/readback -> legacy delete transaction.
    func performInteractiveMigration() async -> AntigravityMigrationStatus {
        await performSingleFlight(.interactiveMigration)
    }

    /// Complete account-removal boundary. Canonical deletion is journaled by
    /// the repository; this coordinator separately journals legacy cleanup.
    func removeAllAccounts() async -> AntigravityMigrationStatus {
        await performSingleFlight(.removal)
    }

    func removeAllAccountsInteractively() async -> AntigravityMigrationStatus {
        await performSingleFlight(.interactiveRemoval)
    }

    /// Repository actor hops make the coordinator reentrant. Keep journal,
    /// vault and cleanup side effects behind one transaction gate so concurrent
    /// callers cannot create competing plans or duplicate authentication UI.
    private func performSingleFlight(
        _ intent: OperationIntent
    ) async -> AntigravityMigrationStatus {
        if let operation = inFlightOperation {
            let result = await operation.task.value
            if inFlightOperation?.id == operation.id {
                inFlightOperation = nil
            }
            if operation.intent == intent {
                return result
            }
            // A different intent (for example explicit removal arriving during
            // startup migration) is serialized and then evaluated against the
            // durable state left by the first operation.
            return await performSingleFlight(intent)
        }

        nextInFlightOperationID &+= 1
        let id = nextInFlightOperationID
        let task = Task { [self] in
            await execute(intent)
        }
        inFlightOperation = InFlightOperation(
            id: id,
            intent: intent,
            task: task
        )
        let result = await task.value
        if inFlightOperation?.id == id {
            inFlightOperation = nil
        }
        return result
    }

    private func execute(
        _ intent: OperationIntent
    ) async -> AntigravityMigrationStatus {
        switch intent {
        case .migrationCheck:
            return await run(authenticationContext: nil)
        case .interactiveMigration:
            guard !authorizationCancelledThisSession else {
                return await currentAwaitingAuthorizationStatus(
                    defaultAction: .importCredential
                )
            }
            let context = authenticationContextFactory()
            context.localizedReason =
                "Antigravity OAuth 계정을 안전한 ClaudeUsage 저장소로 이전합니다."
            return await run(authenticationContext: context)
        case .removal:
            return await runRemoval(authenticationContext: nil)
        case .interactiveRemoval:
            guard !authorizationCancelledThisSession else {
                return await currentAwaitingAuthorizationStatus(
                    defaultAction: .removeLegacyCredential
                )
            }
            let context = authenticationContextFactory()
            context.localizedReason =
                "Antigravity OAuth 계정의 기존 Keychain 항목을 제거합니다."
            return await runRemoval(authenticationContext: context)
        }
    }

    private func run(
        authenticationContext: LAContext?
    ) async -> AntigravityMigrationStatus {
        var durableCompletionMarkerObserved = false
        do {
            var journalDecodeFailed = false
            var journalAtStart: AntigravityMigrationJournal?
            do {
                journalAtStart = try journalStore.load()
            } catch is DecodingError {
                journalDecodeFailed = true
                journalAtStart = nil
            }
            let inspection = try await inspectCanonical()
            if inspection.metadataExists,
               !inspection.missingOrInvalidCredentialAccountIDs.isEmpty,
               journalAtStart?.kind != .removeAllAccounts
            {
                throw AntigravityMigrationFlowError.blocked(.missingCanonicalCredential)
            }
            if let journal = journalAtStart,
               isValid(journal),
               journal.kind == .removeAllAccounts
            {
                return await resumeRemoval(
                    journal: journal,
                    inspection: inspection,
                    authenticationContext: authenticationContext,
                    allowRevisionRebase: false
                )
            }

            // A durable removal transaction takes precedence over marker
            // decoding. This allows explicit deletion to recover a stale or
            // corrupt marker instead of trapping the user behind migration
            // bookkeeping that removal is supposed to supersede.
            let marker = try loadCompletionMarker()
            if let marker {
                guard isValid(marker) else {
                    throw AntigravityMigrationFlowError.blocked(.invalidCompletionMarker)
                }
                durableCompletionMarkerObserved = true
                if journalDecodeFailed
                    || journalAtStart.map({ !isValid($0) }) == true
                {
                    // The marker is written only after canonical and legacy
                    // cleanup verification. A corrupt leftover temporary
                    // journal may therefore be discarded and reconstructed
                    // without re-importing legacy credentials.
                    try deleteJournalAndVerify()
                    journalDecodeFailed = false
                    journalAtStart = nil
                }
                if let journal = journalAtStart {
                    if inspection.metadataExists,
                       canonicalState(inspection.state, matches: journal)
                    {
                        return try await cleanupAfterCanonicalCutover(
                            journal: journal,
                            authenticationContext: authenticationContext
                        )
                    }
                    if journal.kind == .credentialImport,
                       journal.phase == .planned
                           || journal.phase == .credentialsStaged
                    {
                        try await rollbackUncommittedJournal(journal)
                        if inspection.metadataExists {
                            return try await cleanupExistingCanonical(
                                inspection: inspection,
                                authenticationContext: authenticationContext
                            )
                        }
                        return await runRemoval(
                            authenticationContext: authenticationContext
                        )
                    }
                    throw AntigravityMigrationFlowError.blocked(
                        .invalidMigrationJournal
                    )
                }
                let residualInventory = reconciler.inventory(
                    authenticationContext: nil
                )
                guard residualInventory.outcomes.values.contains(where: {
                    $0 != .notFound
                }) else {
                    _ = try await repository.cleanupOrphanedCredentials()
                    return status(phase: .complete)
                }
                if inspection.metadataExists {
                    return try await cleanupExistingCanonical(
                        inspection: inspection,
                        authenticationContext: authenticationContext
                    )
                }
                // Completion marker forbids re-import. If a downgrade or old
                // login path recreates legacy data after all accounts were
                // removed, run the removal journal as cleanup-only.
                return await runRemoval(
                    authenticationContext: authenticationContext
                )
            }

            if journalDecodeFailed {
                throw AntigravityMigrationFlowError.blocked(
                    .invalidMigrationJournal
                )
            }
            if let journal = journalAtStart {
                guard isValid(journal) else {
                    throw AntigravityMigrationFlowError.blocked(.invalidMigrationJournal)
                }
                if canonicalState(inspection.state, matches: journal) {
                    return try await cleanupAfterCanonicalCutover(
                        journal: journal,
                        authenticationContext: authenticationContext
                    )
                }
                if inspection.metadataExists {
                    try await rollbackUncommittedJournal(journal)
                    return try await cleanupExistingCanonical(
                        inspection: inspection,
                        authenticationContext: authenticationContext
                    )
                }
                switch journal.phase {
                case .planned, .credentialsStaged:
                    // A pre-cutover restart never trusts in-memory identity
                    // metadata. Roll back immutable staged refs, delete the
                    // journal, then rebuild and re-fingerprint the inventory.
                    try await rollbackUncommittedJournal(journal)
                case .canonicalCommitted, .cleanupPending, .removalPending:
                    throw AntigravityMigrationFlowError.blocked(.invalidMigrationJournal)
                }
            }

            let refreshedInspection = try await inspectCanonical()
            if refreshedInspection.metadataExists {
                return try await cleanupExistingCanonical(
                    inspection: refreshedInspection,
                    authenticationContext: authenticationContext
                )
            }
            // With no canonical metadata or resumable migration journal, every
            // item in the bounded Antigravity v2 namespace is orphaned. Clean
            // it before importing legacy data or recording completion.
            _ = try await repository.cleanupOrphanedCredentials()

            let inventory = reconciler.inventory(
                authenticationContext: authenticationContext
            )
            if inventory.authorizationWasCancelled {
                authorizationCancelledThisSession = true
            }
            if inventory.requiresInteraction,
               !inventory.hasFileCredentialCandidate
            {
                if authenticationContext == nil
                    || inventory.authorizationWasCancelled
                {
                    return status(
                        phase: .awaitingImportAuthorization,
                        outcomes: inventory.outcomes,
                        requiredAction: .importCredential
                    )
                }
                return status(
                    phase: .awaitingImportAuthorization,
                    outcomes: inventory.outcomes,
                    requiredAction: .importCredential
                )
            }
            try reconciler.validateSources(inventory)

            guard inventory.hasCandidates else {
                if inventory.outcomes.values.contains(where: {
                    $0 != .notFound
                }) {
                    // Readable but credential-free legacy files are still
                    // residue. Journal their bounded deletion instead of
                    // marking migration complete and leaving them behind.
                    return await runRemoval(
                        authenticationContext: authenticationContext
                    )
                }
                return try finalizeCompletion(outcomes: inventory.outcomes)
            }
            let prepared = try reconciler.prepareMigration(from: inventory)
            var journal = AntigravityMigrationJournal(
                operationID: uuidGenerator(),
                kind: .credentialImport,
                phase: .planned,
                expectedRevision: prepared.repositoryPlan.expectedRevision,
                sourceInventoryFingerprint: prepared.sourceInventoryFingerprint,
                sourceFingerprints: prepared.sourceFingerprints,
                cleanupPayloadFingerprints:
                    prepared.sourcePayloadFingerprints,
                accounts: prepared.journalAccounts,
                activeAccountID: prepared.repositoryPlan.activeAccountID
            )
            try saveJournalAndVerify(journal)

            for planned in prepared.repositoryPlan.accounts {
                guard let credentials = prepared.credentialsByReference[
                    planned.credentialReference
                ] else {
                    throw AntigravityMigrationFlowError.blocked(.invalidMigrationJournal)
                }
                try await repository.stageMigrationCredential(
                    credentials,
                    reference: planned.credentialReference
                )
                guard let readback = try await repository.migrationCredential(
                    reference: planned.credentialReference
                ), AntigravityMigrationFingerprint.refresh(readback)
                    == prepared.journalAccounts.first(where: {
                    $0.credentialReference == planned.credentialReference
                })?.refreshTokenFingerprint else {
                    throw AntigravityAccountRepositoryError.credentialVerificationFailed
                }
            }

            journal.phase = .credentialsStaged
            try saveJournalAndVerify(journal)
            let cutoverInventory = reconciler.inventory(
                authenticationContext: authenticationContext
            )
            if cutoverInventory.authorizationWasCancelled {
                authorizationCancelledThisSession = true
            }
            try verifyInventory(
                cutoverInventory,
                matches: journal
            )
            _ = try await repository.commitMigration(prepared.repositoryPlan)
            journal.phase = .canonicalCommitted
            try saveJournalAndVerify(journal)
            return try await cleanupAfterCanonicalCutover(
                journal: journal,
                authenticationContext: authenticationContext
            )
        } catch let AntigravityMigrationFlowError.blocked(blocker) {
            if blocker == .persistenceFailure {
                let canonicalExists =
                    (try? await inspectCanonical())?.metadataExists == true
                if durableCompletionMarkerObserved || canonicalExists {
                    return status(
                        phase: .cleanupPending,
                        blocker: blocker
                    )
                }
            }
            return status(phase: .blockedBeforeCutover, blocker: blocker)
        } catch is DecodingError {
            return status(
                phase: .blockedBeforeCutover,
                blocker: .invalidMigrationJournal
            )
        } catch {
            let canonicalExists =
                (try? await inspectCanonical())?.metadataExists == true
            if durableCompletionMarkerObserved || canonicalExists {
                return status(
                    phase: .cleanupPending,
                    blocker: .persistenceFailure
                )
            }
            return status(phase: .blockedBeforeCutover, blocker: .persistenceFailure)
        }
    }


    private func cleanupExistingCanonical(
        inspection: AntigravityMigrationCanonicalInspection,
        authenticationContext: LAContext?
    ) async throws -> AntigravityMigrationStatus {
        guard inspection.missingOrInvalidCredentialAccountIDs.isEmpty else {
            throw AntigravityMigrationFlowError.blocked(.missingCanonicalCredential)
        }
        let inventory = reconciler.inventory(authenticationContext: nil)
        let journalAccounts = try await canonicalJournalAccounts(
            state: inspection.state
        )
        var journal = AntigravityMigrationJournal(
            operationID: uuidGenerator(),
            kind: .canonicalCleanup,
            phase: .canonicalCommitted,
            expectedRevision: inspection.state.revision,
            sourceInventoryFingerprint:
                reconciler.sourceInventoryFingerprint(inventory),
            sourceFingerprints: reconciler.sourceFingerprints(inventory),
            cleanupPayloadFingerprints:
                reconciler.payloadFingerprints(inventory),
            accounts: journalAccounts,
            activeAccountID: inspection.state.activeAccountID
        )
        try saveJournalAndVerify(journal)
        journal.phase = .cleanupPending
        try saveJournalAndVerify(journal)
        return try await cleanupAfterCanonicalCutover(
            journal: journal,
            authenticationContext: authenticationContext
        )
    }

    private func canonicalJournalAccounts(
        state: AntigravityAccountRepositoryState
    ) async throws -> [AntigravityMigrationJournalAccount] {
        var result: [AntigravityMigrationJournalAccount] = []
        for account in state.accounts {
            guard let credentials = try await repository.migrationCredential(
                reference: account.credentialReference
            ), let fingerprint = AntigravityMigrationFingerprint.refresh(
                credentials
            ) else {
                throw AntigravityMigrationFlowError.blocked(.missingCanonicalCredential)
            }
            result.append(AntigravityMigrationJournalAccount(
                accountID: account.id,
                credentialReference: account.credentialReference,
                refreshTokenFingerprint: fingerprint
            ))
        }
        return result.sorted { $0.accountID.rawValue < $1.accountID.rawValue }
    }

    private func cleanupAfterCanonicalCutover(
        journal sourceJournal: AntigravityMigrationJournal,
        authenticationContext: LAContext?
    ) async throws -> AntigravityMigrationStatus {
        let inspection = try await inspectCanonical()
        guard inspection.metadataExists,
              inspection.missingOrInvalidCredentialAccountIDs.isEmpty,
              canonicalState(inspection.state, matches: sourceJournal)
        else {
            throw AntigravityMigrationFlowError.blocked(.missingCanonicalCredential)
        }
        // Repository enumeration is the durable retry source for namespace
        // orphans; referenced canonical credentials are preserved by metadata.
        _ = try await repository.cleanupOrphanedCredentials()

        var journal = sourceJournal
        if journal.phase != .cleanupPending {
            journal.phase = .cleanupPending
            try saveJournalAndVerify(journal)
        }
        var outcomes = Dictionary(
            uniqueKeysWithValues: AntigravityLegacySourceID.allCases.map {
                ($0, AntigravityLegacySourceOutcome.notFound)
            }
        )
        var cleanupBlocker: AntigravityMigrationBlocker?

        for source in AntigravityLegacySourceID.allCases {
            if journal.completedCleanupTargets.contains(source),
               verifyAllLegacyIdentitiesAbsent(
                   source,
                   authenticationContext: authenticationContext
               )
            {
                outcomes[source] = .notFound
                continue
            }
            journal.completedCleanupTargets.remove(source)
            let expectedPayloadFingerprint: String
            switch try bindCleanupPayloadFingerprint(
                source,
                journal: &journal,
                authenticationContext: authenticationContext
            ) {
            case .absent:
                if verifyAllLegacyIdentitiesAbsent(
                    source,
                    authenticationContext: authenticationContext
                ) {
                    journal.completedCleanupTargets.insert(source)
                    outcomes[source] = .notFound
                    try saveJournalAndVerify(journal)
                } else {
                    cleanupBlocker = cleanupBlocker
                        ?? .legacySourceChanged(source)
                }
                continue
            case let .ready(fingerprint, outcome):
                expectedPayloadFingerprint = fingerprint
                outcomes[source] = outcome
            case .interactionRequired:
                outcomes[source] = .interactionRequired
                continue
            case let .changed(outcome):
                outcomes[source] = outcome
                cleanupBlocker = cleanupBlocker
                    ?? .legacySourceChanged(source)
                continue
            }
            let deletion = deleteLegacySourceIfUnchanged(
                source,
                expectedPayloadFingerprint: expectedPayloadFingerprint,
                authenticationContext: authenticationContext
            )
            switch deletion {
            case .absent, .deleted:
                if verifyAllLegacyIdentitiesAbsent(
                    source,
                    authenticationContext: authenticationContext
                ) {
                    journal.completedCleanupTargets.insert(source)
                    outcomes[source] = .notFound
                    try saveJournalAndVerify(journal)
                } else {
                    outcomes[source] = source.isKeychainSource
                        ? .interactionRequired
                        : .failure(-1)
                }
            case .changed:
                outcomes[source] = .readable
                cleanupBlocker = cleanupBlocker
                    ?? .legacySourceChanged(source)
            case .interactionRequired:
                outcomes[source] = .interactionRequired
            case .cancelled:
                authorizationCancelledThisSession = true
                outcomes[source] = .interactionRequired
            case let .failure(code):
                outcomes[source] = .failure(code)
            }
        }

        guard journal.completedCleanupTargets
            == Set(AntigravityLegacySourceID.allCases)
        else {
            try saveJournalAndVerify(journal)
            return status(
                phase: .cleanupPending,
                outcomes: outcomes,
                plannedAccountCount: journal.accounts.count,
                blocker: cleanupBlocker,
                requiredAction: outcomes.values.contains(.interactionRequired)
                    ? .cleanupLegacyCredential
                    : nil
            )
        }

        // The completion marker is the durable cutover guard. Persist and
        // verify it before deleting the resumable journal; a crash in between
        // is handled as marker + leftover cleanup journal on the next launch.
        let completed = try finalizeCompletion(outcomes: outcomes)
        try finishJournalCleanup(journal)
        return completed
    }

    /// Binds the raw-payload SHA-256 to the durable journal before the adapter
    /// atomically removes the legacy identity from its writer namespace. A
    /// later restart can therefore resume a fixed quarantine without trusting
    /// in-memory verification state.
    private func bindCleanupPayloadFingerprint(
        _ source: AntigravityLegacySourceID,
        journal: inout AntigravityMigrationJournal,
        authenticationContext: LAContext?
    ) throws -> CleanupPayloadBinding {
        if let expected = journal.cleanupPayloadFingerprints[source] {
            return .ready(expected, .readable)
        }

        var inventory = reconciler.inventory(authenticationContext: nil)
        var outcome = inventory.outcomes[source] ?? .notFound

        if outcome == .interactionRequired {
            guard let authenticationContext else {
                return .interactionRequired
            }
            inventory = reconciler.inventory(
                authenticationContext: authenticationContext
            )
            if inventory.authorizationWasCancelled {
                authorizationCancelledThisSession = true
                return .interactionRequired
            }
            outcome = inventory.outcomes[source] ?? .notFound
        }

        guard outcome != .interactionRequired else {
            return .interactionRequired
        }

        if outcome == .notFound {
            let quarantine = readLegacyQuarantine(
                source,
                authenticationContext: authenticationContext
            )
            if case .notFound = quarantine {
                return .absent
            }
            // A quarantine without its durable payload binding is not safe to
            // delete. This indicates corrupt/out-of-contract durable state.
            return .changed(.readable)
        }

        guard case .failure = outcome else {
            let current = reconciler.sourceFingerprints(inventory)[source]
            var isAllowed = current == journal.sourceFingerprints[source]
            let wasUnreadable = journal.sourceFingerprints[source]
                == reconciler.interactionRequiredFingerprint(for: source)
            let currentCredentials = reconciler.credentialFingerprints(
                for: source,
                in: inventory
            )
            let canonicalCredentials = Set(
                journal.accounts.map(\.refreshTokenFingerprint)
            )
            if wasUnreadable,
               outcome == .readable,
               !currentCredentials.isEmpty,
               currentCredentials.isSubset(of: canonicalCredentials)
            {
                isAllowed = true
            }
            guard isAllowed,
                  let payloadFingerprint =
                    reconciler.payloadFingerprints(inventory)[source]
            else {
                return .changed(outcome)
            }
            journal.cleanupPayloadFingerprints[source] = payloadFingerprint
            try saveJournalAndVerify(journal)
            return .ready(payloadFingerprint, outcome)
        }

        return .changed(outcome)
    }

    private func deleteLegacySourceIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        if source.isKeychainSource {
            return keychainAccess.deleteIfUnchanged(
                source,
                expectedPayloadFingerprint:
                    expectedPayloadFingerprint,
                authenticationContext: authenticationContext
            )
        }
        return fileAccess.deleteIfUnchanged(
            source,
            expectedPayloadFingerprint:
                expectedPayloadFingerprint
        )
    }

    private func readLegacyQuarantine(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult {
        if source.isKeychainSource {
            return keychainAccess.readQuarantine(
                source,
                authenticationContext: authenticationContext
            )
        }
        return fileAccess.readQuarantine(source)
    }

    private func verifyAllLegacyIdentitiesAbsent(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> Bool {
        let original: AntigravityLegacyReadResult
        let quarantine: AntigravityLegacyReadResult
        if source.isKeychainSource {
            original = keychainAccess.read(
                source,
                authenticationContext: authenticationContext
            )
            quarantine = keychainAccess.readQuarantine(
                source,
                authenticationContext: authenticationContext
            )
        } else {
            original = fileAccess.read(source)
            quarantine = fileAccess.readQuarantine(source)
        }
        guard case .notFound = original,
              case .notFound = quarantine
        else {
            return false
        }
        return true
    }

    private func rollbackUncommittedJournal(
        _ journal: AntigravityMigrationJournal
    ) async throws {
        guard journal.kind == .credentialImport,
              journal.phase == .planned || journal.phase == .credentialsStaged
        else {
            throw AntigravityMigrationFlowError.blocked(.invalidMigrationJournal)
        }
        for account in journal.accounts.sorted(by: {
            $0.credentialReference.rawValue < $1.credentialReference.rawValue
        }) {
            try await repository.discardStagedMigrationCredential(
                reference: account.credentialReference
            )
        }
        try deleteJournalAndVerify()
    }

    private func canonicalState(
        _ state: AntigravityAccountRepositoryState,
        matches journal: AntigravityMigrationJournal
    ) -> Bool {
        guard journal.kind != .removeAllAccounts,
              state.revision == (
                  journal.kind == .credentialImport
                      ? journal.expectedRevision + 1
                      : journal.expectedRevision
              ),
              state.activeAccountID == journal.activeAccountID,
              state.accounts.count == journal.accounts.count
        else {
            return false
        }
        let canonicalPairs = Set(state.accounts.map {
            "\($0.id.rawValue)|\($0.credentialReference.rawValue)"
        })
        let journalPairs = Set(journal.accounts.map {
            "\($0.accountID.rawValue)|\($0.credentialReference.rawValue)"
        })
        return canonicalPairs == journalPairs
    }

    private func verifyInventory(
        _ inventory: AntigravityMigrationReconciler.Inventory,
        matches journal: AntigravityMigrationJournal
    ) throws {
        let current = reconciler.sourceFingerprints(inventory)
        guard current == journal.sourceFingerprints,
              reconciler.sourceInventoryFingerprint(inventory)
                == journal.sourceInventoryFingerprint
        else {
            let changedSource = AntigravityLegacySourceID.allCases.first {
                current[$0] != journal.sourceFingerprints[$0]
            } ?? .accountFile
            throw AntigravityMigrationFlowError.blocked(
                .legacySourceChanged(changedSource)
            )
        }
    }

    private func runRemoval(
        authenticationContext: LAContext?
    ) async -> AntigravityMigrationStatus {
        do {
            var inspection = try await inspectCanonical()
            let existing: AntigravityMigrationJournal?
            do {
                existing = try journalStore.load()
            } catch {
                // Explicit "remove all" is a bounded destructive boundary. A
                // corrupt migration journal must not strand canonical secrets;
                // discard it, then enumerate only the Antigravity namespace and
                // fixed legacy targets below.
                try deleteJournalAndVerify()
                existing = nil
            }
            if let existing {
                if !isValid(existing) {
                    try deleteJournalAndVerify()
                } else if existing.kind == .removeAllAccounts {
                    return await resumeRemoval(
                        journal: existing,
                        inspection: inspection,
                        authenticationContext: authenticationContext,
                        allowRevisionRebase: true
                    )
                } else {
                    // Any import/cleanup transaction is superseded by the
                    // user's explicit removal. Repository namespace cleanup
                    // below also removes staged orphan references.
                    try deleteJournalAndVerify()
                }
                inspection = try await inspectCanonical()
            }

            var journal = makeRemovalJournal(for: inspection.state)
            try saveJournalAndVerify(journal)
            if inspection.metadataExists {
                try await repository.deleteAll(
                    expectedRevision: inspection.state.revision
                )
            } else {
                _ = try await repository.cleanupOrphanedCredentials()
            }
            journal.phase = .removalPending
            try saveJournalAndVerify(journal)
            return try cleanupRemovalLegacySources(
                journal: journal,
                authenticationContext: authenticationContext
            )
        } catch let AntigravityMigrationFlowError.blocked(blocker) {
            return status(phase: .blockedBeforeCutover, blocker: blocker)
        } catch {
            return status(phase: .cleanupPending, blocker: .persistenceFailure)
        }
    }

    private func resumeRemoval(
        journal: AntigravityMigrationJournal,
        inspection: AntigravityMigrationCanonicalInspection,
        authenticationContext: LAContext?,
        allowRevisionRebase: Bool
    ) async -> AntigravityMigrationStatus {
        do {
            guard journal.kind == .removeAllAccounts else {
                throw AntigravityMigrationFlowError.blocked(.invalidMigrationJournal)
            }
            var activeJournal = journal
            if inspection.metadataExists {
                // Startup recovery must not let an old removal journal delete
                // an account intentionally reconnected later, even when the
                // new repository happens to reuse the same revision number.
                // A fresh explicit remove-all action replaces the stale
                // binding with a new operation over the inspected state.
                if allowRevisionRebase {
                    activeJournal = makeRemovalJournal(for: inspection.state)
                    try saveJournalAndVerify(activeJournal)
                } else {
                    guard inspection.state.revision
                            == journal.expectedRevision,
                          journal.removalCanonicalStateFingerprint
                            == AntigravityMigrationFingerprint
                                .removalCanonicalState(inspection.state)
                    else {
                        throw AntigravityMigrationFlowError.blocked(
                            .invalidMigrationJournal
                        )
                    }
                }
                try await repository.deleteAll(
                    expectedRevision: inspection.state.revision
                )
            } else {
                _ = try await repository.cleanupOrphanedCredentials()
            }
            return try cleanupRemovalLegacySources(
                journal: activeJournal,
                authenticationContext: authenticationContext
            )
        } catch let AntigravityMigrationFlowError.blocked(blocker) {
            return status(phase: .blockedBeforeCutover, blocker: blocker)
        } catch {
            return status(phase: .cleanupPending, blocker: .persistenceFailure)
        }
    }

    private func makeRemovalJournal(
        for state: AntigravityAccountRepositoryState
    ) -> AntigravityMigrationJournal {
        AntigravityMigrationJournal(
            operationID: uuidGenerator(),
            kind: .removeAllAccounts,
            phase: .removalPending,
            expectedRevision: state.revision,
            sourceInventoryFingerprint: AntigravityMigrationFingerprint.digest([
                "remove-all-source-inventory",
                String(state.revision),
            ]),
            removalCanonicalStateFingerprint:
                AntigravityMigrationFingerprint.removalCanonicalState(state),
            accounts: [],
            activeAccountID: nil
        )
    }

    private func cleanupRemovalLegacySources(
        journal sourceJournal: AntigravityMigrationJournal,
        authenticationContext: LAContext?
    ) throws -> AntigravityMigrationStatus {
        var journal = sourceJournal
        var outcomes = Dictionary(
            uniqueKeysWithValues: AntigravityLegacySourceID.allCases.map {
                ($0, AntigravityLegacySourceOutcome.notFound)
            }
        )
        for source in AntigravityLegacySourceID.allCases {
            if journal.completedCleanupTargets.contains(source),
               verifyAllLegacyIdentitiesAbsent(
                   source,
                   authenticationContext: authenticationContext
               )
            {
                continue
            }
            journal.completedCleanupTargets.remove(source)
            let noUIInventory = reconciler.inventory(
                authenticationContext: nil
            )
            if noUIInventory.outcomes[source] == .interactionRequired,
               authenticationContext == nil
            {
                outcomes[source] = .interactionRequired
                continue
            }
            let deletion: AntigravityLegacyDeleteResult
            if source.isKeychainSource {
                deletion = keychainAccess.deleteAllIdentities(
                    source,
                    authenticationContext: authenticationContext
                )
            } else {
                deletion = fileAccess.deleteAllIdentities(source)
            }
            switch deletion {
            case .absent, .deleted:
                if verifyAllLegacyIdentitiesAbsent(
                    source,
                    authenticationContext: authenticationContext
                ) {
                    journal.completedCleanupTargets.insert(source)
                    try saveJournalAndVerify(journal)
                } else {
                    outcomes[source] = source.isKeychainSource
                        ? .interactionRequired
                        : .failure(-1)
                }
            case .changed:
                outcomes[source] = .failure(-1)
            case .interactionRequired:
                outcomes[source] = .interactionRequired
            case .cancelled:
                authorizationCancelledThisSession = true
                outcomes[source] = .interactionRequired
            case let .failure(code):
                outcomes[source] = .failure(code)
            }
        }
        guard journal.completedCleanupTargets
            == Set(AntigravityLegacySourceID.allCases)
        else {
            try saveJournalAndVerify(journal)
            return status(
                phase: .cleanupPending,
                outcomes: outcomes,
                requiredAction: outcomes.values.contains(.interactionRequired)
                    ? .removeLegacyCredential
                    : nil
            )
        }
        // The separate completion marker deliberately survives account removal
        // so a later launch cannot resurrect downgraded legacy files.
        let completed = try finalizeCompletion(outcomes: outcomes)
        try finishJournalCleanup(journal)
        return completed
    }

    private func currentAwaitingAuthorizationStatus(
        defaultAction: AntigravityMigrationRequiredAction
    ) async -> AntigravityMigrationStatus {
        let action: AntigravityMigrationRequiredAction
        let journal = try? journalStore.load()
        if let journal {
            switch journal.kind {
            case .removeAllAccounts:
                action = .removeLegacyCredential
            case .canonicalCleanup:
                action = .cleanupLegacyCredential
            case .credentialImport:
                switch journal.phase {
                case .canonicalCommitted, .cleanupPending:
                    action = .cleanupLegacyCredential
                case .planned, .credentialsStaged, .removalPending:
                    action = defaultAction
                }
            }
        } else {
            action = defaultAction
        }
        let inventory = reconciler.inventory(authenticationContext: nil)
        return status(
            phase: action == .importCredential
                ? .awaitingImportAuthorization
                : .cleanupPending,
            outcomes: inventory.outcomes,
            requiredAction: action
        )
    }

    private func inspectCanonical() async throws
        -> AntigravityMigrationCanonicalInspection
    {
        do {
            return try await repository.inspectCanonicalForMigration()
        } catch let error as AntigravityAccountRepositoryError
            where error == .invalidMetadata
        {
            throw AntigravityMigrationFlowError.blocked(.invalidCanonicalState)
        }
    }

    private func loadCompletionMarker() throws
        -> AntigravityMigrationCompletionMarker?
    {
        do {
            return try completionMarkerStore.load()
        } catch is DecodingError {
            throw AntigravityMigrationFlowError.blocked(
                .invalidCompletionMarker
            )
        }
    }

    private func finalizeCompletion(
        outcomes: [AntigravityLegacySourceID: AntigravityLegacySourceOutcome]
    ) throws -> AntigravityMigrationStatus {
        let timestamp = now().timeIntervalSince1970 * 1_000
        guard timestamp.isFinite, timestamp >= 0 else {
            throw AntigravityMigrationFlowError.blocked(.persistenceFailure)
        }
        let marker = AntigravityMigrationCompletionMarker(
            version: AntigravityMigrationCompletionMarker.currentVersion,
            completedAtMilliseconds: timestamp
        )
        try completionMarkerStore.save(marker)
        guard try completionMarkerStore.load() == marker else {
            throw AntigravityMigrationFlowError.blocked(.persistenceFailure)
        }
        return status(phase: .complete, outcomes: outcomes)
    }

    private func saveJournalAndVerify(
        _ journal: AntigravityMigrationJournal
    ) throws {
        guard isValid(journal) else {
            throw AntigravityMigrationFlowError.blocked(.invalidMigrationJournal)
        }
        try journalStore.save(journal)
        guard try journalStore.load() == journal else {
            throw AntigravityMigrationFlowError.blocked(.persistenceFailure)
        }
    }

    private func deleteJournalAndVerify() throws {
        try journalStore.delete()
        guard try journalStore.load() == nil else {
            throw AntigravityMigrationFlowError.blocked(.persistenceFailure)
        }
    }

    private func finishJournalCleanup(
        _ journal: AntigravityMigrationJournal
    ) throws {
        try deleteJournalAndVerify()
        do {
            try fileAccess.removeAntigravityDirectoryIfEmpty()
        } catch {
            // If removing the now-empty Antigravity directory fails, recreate
            // the verified journal so the cleanup remains durable and retryable.
            try saveJournalAndVerify(journal)
            throw error
        }
    }

    private func isValid(
        _ marker: AntigravityMigrationCompletionMarker
    ) -> Bool {
        marker.version == AntigravityMigrationCompletionMarker.currentVersion
            && marker.completedAtMilliseconds.isFinite
            && marker.completedAtMilliseconds >= 0
    }

    private func isValid(_ journal: AntigravityMigrationJournal) -> Bool {
        guard journal.schemaVersion == AntigravityMigrationJournal.currentSchemaVersion,
              UUID(uuidString: journal.operationID)?.uuidString.lowercased()
                == journal.operationID,
              AntigravityMigrationFingerprint.isSHA256Hex(
                  journal.sourceInventoryFingerprint
              ),
              journal.sourceFingerprints.values.allSatisfy(
                  AntigravityMigrationFingerprint.isSHA256Hex
              ),
              journal.cleanupPayloadFingerprints.keys.allSatisfy({
                  AntigravityLegacySourceID.allCases.contains($0)
              }),
              journal.cleanupPayloadFingerprints.values.allSatisfy(
                  AntigravityMigrationFingerprint.isSHA256Hex
              ),
              journal.completedCleanupTargets.isSubset(
                  of: Set(AntigravityLegacySourceID.allCases)
              ),
              Set(journal.accounts.map(\.accountID)).count == journal.accounts.count,
              Set(journal.accounts.map(\.credentialReference)).count
                == journal.accounts.count,
              journal.activeAccountID?.isOpaqueUUID != false,
              journal.accounts.allSatisfy({
                  $0.accountID.isOpaqueUUID
                      && $0.credentialReference.isCanonical
                      && AntigravityMigrationFingerprint.isSHA256Hex(
                          $0.refreshTokenFingerprint
                      )
              })
        else {
            return false
        }
        switch journal.kind {
        case .credentialImport:
            return journal.removalCanonicalStateFingerprint == nil
                && journal.expectedRevision < UInt64.max
                && Set(journal.sourceFingerprints.keys)
                    == Set(AntigravityLegacySourceID.allCases)
                && !journal.accounts.isEmpty
                && journal.activeAccountID.map {
                    active in journal.accounts.contains { $0.accountID == active }
                } == true
                && (
                    journal.phase == .planned
                        || journal.phase == .credentialsStaged
                        || journal.phase == .canonicalCommitted
                        || journal.phase == .cleanupPending
                )
        case .canonicalCleanup:
            return journal.removalCanonicalStateFingerprint == nil
                && Set(journal.sourceFingerprints.keys)
                == Set(AntigravityLegacySourceID.allCases)
                && (
                journal.activeAccountID == nil
                    || journal.accounts.contains {
                        $0.accountID == journal.activeAccountID
                    }
            ) && (
                journal.phase == .canonicalCommitted
                    || journal.phase == .cleanupPending
            )
        case .removeAllAccounts:
            return journal.removalCanonicalStateFingerprint.map(
                AntigravityMigrationFingerprint.isSHA256Hex
            ) == true
                && journal.accounts.isEmpty
                && journal.activeAccountID == nil
                && journal.phase == .removalPending
        }
    }


    private func status(
        phase: AntigravityMigrationPhase,
        outcomes: [AntigravityLegacySourceID: AntigravityLegacySourceOutcome] = [:],
        plannedAccountCount: Int = 0,
        blocker: AntigravityMigrationBlocker? = nil,
        requiredAction: AntigravityMigrationRequiredAction? = nil
    ) -> AntigravityMigrationStatus {
        AntigravityMigrationStatus(
            phase: phase,
            sourceOutcomes: outcomes,
            plannedAccountCount: plannedAccountCount,
            blocker: blocker,
            requiredAction: requiredAction,
            authorizationCancelledThisSession: authorizationCancelledThisSession
        )
    }
}

private extension AntigravityLegacySourceID {
    nonisolated var isKeychainSource: Bool {
        self == .bundleIdentifierKeychain || self == .claudeUsageKeychain
    }
}
