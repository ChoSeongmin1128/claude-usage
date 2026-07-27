import Foundation

nonisolated enum AntigravityRuntimeControllerError:
    Error,
    Sendable,
    Equatable
{
    case appShuttingDown
    case settingsMigrationBlocked
    case canonicalAccountStateUnavailable
    case typedSettingsUnavailable
    case accountNotFound
    case invalidCredentials
    case operationSuperseded
}

nonisolated protocol AntigravityRuntimeAccountPersisting:
    Sendable
{
    func state() async throws
        -> AntigravityAccountRepositoryState

    func createAccount(
        credentials: AntigravityOAuthCredentials,
        label: String,
        externalIdentity: AntigravityExternalAccountIdentity,
        migrationAliases: [String],
        makeActive: Bool,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState

    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity:
            AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState

    func setActiveAccountID(
        _ accountID: AntigravityAccountID?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState

    func deleteAccount(
        id accountID: AntigravityAccountID,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState
}

extension AntigravityAccountRepository:
    AntigravityRuntimeAccountPersisting
{}

nonisolated protocol AntigravityRuntimeMigrationCoordinating:
    Sendable
{
    func checkForMigration() async
        -> AntigravityMigrationStatus

    func performInteractiveMigration() async
        -> AntigravityMigrationStatus

    func removeAllAccounts() async
        -> AntigravityMigrationStatus

    func removeAllAccountsInteractively() async
        -> AntigravityMigrationStatus
}

extension AntigravityMigrationCoordinator:
    AntigravityRuntimeMigrationCoordinating
{}

nonisolated protocol AntigravityManagedSessionLifecycling:
    Sendable
{
    func recoverOrphanedProcesses() async throws
    func shutdown() async
}

extension AntigravityManagedCLISession:
    AntigravityManagedSessionLifecycling
{}

private actor AntigravityRuntimeOperationGate {
    private var isAcquired = false
    private var waiters:
        [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isAcquired {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// The only product mutation boundary for Antigravity runtime state.
///
/// Repository, settings, migration and refresh actors are individually safe,
/// but their methods can interleave at every `await`. This controller gates
/// canonical mutations, runs remote refresh work outside that gate, and
/// commits only the active boundary transaction to its secret-free projection.
actor AntigravityRuntimeController {
    private let repository:
        any AntigravityRuntimeAccountPersisting
    private let settingsStore:
        any AntigravitySettingsStoring
    private let migrationCoordinator:
        any AntigravityRuntimeMigrationCoordinating
    private let refreshCoordinator:
        any AntigravityRefreshCoordinating
    private let managedSession:
        any AntigravityManagedSessionLifecycling
    private let settingsBootstrap:
        AntigravitySettingsBootstrapResult
    private let hasManagedExecutable: Bool
    private let now: @Sendable () -> Date
    private let operationGate =
        AntigravityRuntimeOperationGate()

    private struct RefreshTransaction: Sendable {
        let id: UUID
        let boundaryID: UUID
        let request: AntigravityRefreshRequest
        let migrationStatus:
            AntigravityMigrationStatus?
        let context: CanonicalContext
    }

    private struct BoundaryChange: Sendable {
        let id: UUID
        let previousSnapshot:
            AntigravityRuntimeSnapshot
    }

    private var currentSnapshot =
        AntigravityRuntimeSnapshot.idle
    private var continuations:
        [
            UUID:
                AsyncStream<
                    AntigravityRuntimeSnapshot
                >.Continuation
        ] = [:]
    private var isShuttingDown = false
    private var didBootstrap = false
    private var managedAvailability:
        AntigravityManagedRuntimeAvailability
    private var currentBoundaryID = UUID()
    private var activeRefreshTransactionID: UUID?
    private var shutdownTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var lastSuccessfulAt: Date?

    init(
        repository:
            any AntigravityRuntimeAccountPersisting,
        settingsStore:
            any AntigravitySettingsStoring,
        migrationCoordinator:
            any AntigravityRuntimeMigrationCoordinating,
        refreshCoordinator:
            any AntigravityRefreshCoordinating,
        managedSession:
            any AntigravityManagedSessionLifecycling,
        settingsBootstrap:
            AntigravitySettingsBootstrapResult,
        hasManagedExecutable: Bool,
        now:
            @escaping @Sendable () -> Date =
                Date.init
    ) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.migrationCoordinator =
            migrationCoordinator
        self.refreshCoordinator = refreshCoordinator
        self.managedSession = managedSession
        self.settingsBootstrap = settingsBootstrap
        self.hasManagedExecutable =
            hasManagedExecutable
        self.now = now
        managedAvailability = hasManagedExecutable
            ? .available
            : .unavailable
    }

    func snapshot() -> AntigravityRuntimeSnapshot {
        currentSnapshot
    }

    func snapshots()
        -> AsyncStream<AntigravityRuntimeSnapshot>
    {
        let id = UUID()
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuations[id] = continuation
            continuation.yield(currentSnapshot)
            continuation.onTermination = {
                @Sendable [weak self] _ in
                Task {
                    await self?.removeContinuation(id)
                }
            }
        }
    }

    @discardableResult
    func bootstrap(
        performInitialRefresh: Bool = true
    ) async -> AntigravityRuntimeSnapshot {
        let boundaryID = currentBoundaryID
        let transaction = await withOperationGate {
            () async -> RefreshTransaction? in
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }
            guard !didBootstrap else {
                return nil
            }
            didBootstrap = true
            guard settingsBootstrap.isReady else {
                _ = publishBlocked(
                    .settingsMigration
                )
                return nil
            }

            publish(
                replacing: currentSnapshot,
                readiness: .bootstrapping
            )

            do {
                try await managedSession
                    .recoverOrphanedProcesses()
                managedAvailability =
                    hasManagedExecutable
                        ? .available
                        : .unavailable
            } catch {
                managedAvailability = .recoveryBlocked
            }
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }

            let migration =
                await migrationCoordinator
                    .checkForMigration()
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }
            guard
                let context =
                    await loadCanonicalContext(
                        migrationStatus: migration,
                        boundaryID: boundaryID
                    )
            else {
                return nil
            }
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }

            guard performInitialRefresh else {
                let presentation =
                    await refreshCoordinator
                        .presentationState()
                guard isCurrentBoundary(boundaryID)
                else {
                    return nil
                }
                _ = publish(
                    readiness: .ready,
                    migrationStatus: migration,
                    repositoryState:
                        context.repositoryState,
                    settings: context.settings,
                    presentationState: presentation
                )
                return nil
            }
            return prepareRefresh(
                trigger: .migrationCompleted,
                migrationStatus: migration,
                context: context,
                boundaryID: boundaryID
            )
        }
        guard let transaction else {
            return currentSnapshot
        }
        return await executeRefresh(transaction)
    }

    @discardableResult
    func refresh(
        trigger: AntigravityRefreshTrigger
    ) async -> AntigravityRuntimeSnapshot {
        let boundaryID = currentBoundaryID
        let transaction = await withOperationGate {
            () async -> RefreshTransaction? in
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }
            guard settingsBootstrap.isReady else {
                _ = publishBlocked(
                    .settingsMigration
                )
                return nil
            }
            let migration: AntigravityMigrationStatus
            if let current =
                    currentSnapshot.migrationStatus
            {
                migration = current
            } else {
                migration =
                    await migrationCoordinator
                        .checkForMigration()
            }
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }
            guard
                let context =
                    await loadCanonicalContext(
                        migrationStatus: migration,
                        boundaryID: boundaryID
                    )
            else {
                return nil
            }
            guard isCurrentBoundary(boundaryID) else {
                return nil
            }
            return prepareRefresh(
                trigger: trigger,
                migrationStatus: migration,
                context: context,
                boundaryID: boundaryID
            )
        }
        guard let transaction else {
            return currentSnapshot
        }
        return await executeRefresh(transaction)
    }

    @discardableResult
    func selectAccount(
        _ accountID: AntigravityAccountID
    ) async throws -> AntigravityRuntimeSnapshot {
        try await performBoundaryMutation {
            transactionID in
            try ensureMutable()
            guard isCurrent(transactionID) else {
                return nil
            }
            let context = try await requireCanonicalContext(
                boundaryID: transactionID
            )
            guard isCurrent(transactionID) else {
                return nil
            }
            guard context.repositoryState.usableAccounts
                .contains(where: { $0.id == accountID })
            else {
                throw AntigravityRuntimeControllerError
                    .accountNotFound
            }

            let repositoryState:
                AntigravityAccountRepositoryState
            if context.repositoryState.activeAccountID
                == accountID
            {
                repositoryState =
                    context.repositoryState
            } else {
                repositoryState = try await repository
                    .setActiveAccountID(
                        accountID,
                        expectedRevision:
                            context.repositoryState
                                .revision
                    )
            }
            guard isCurrent(transactionID) else {
                return nil
            }
            let refreshedContext = CanonicalContext(
                repositoryState: repositoryState,
                settings: try await settingsStore.load()
            )
            guard isCurrent(transactionID) else {
                return nil
            }
            return prepareRefresh(
                trigger: .accountBoundaryChanged,
                migrationStatus:
                    currentSnapshot.migrationStatus,
                context: refreshedContext,
                transactionID: transactionID
            )
        }
    }

    @discardableResult
    func connectAccount(
        credentials: AntigravityOAuthCredentials,
        label requestedLabel: String? = nil
    ) async throws -> AntigravityRuntimeSnapshot {
        try ensureMutable()
        guard credentials.hasTokenMaterial else {
            throw AntigravityRuntimeControllerError
                .invalidCredentials
        }
        return try await performBoundaryMutation {
            transactionID in
            try ensureMutable()
            guard isCurrent(transactionID) else {
                return nil
            }
            let context = try await requireCanonicalContext(
                boundaryID: transactionID
            )
            guard isCurrent(transactionID) else {
                return nil
            }
            let identity = Self.externalIdentity(
                from: credentials
            )
            let label =
                Self.nonEmpty(requestedLabel)
                ?? identity.email
                ?? "Google 계정"

            var repositoryState =
                context.repositoryState
            if let existing = repositoryState
                .usableAccounts
                .first(where: {
                    Self.matches(
                        identity,
                        account: $0
                    )
                })
            {
                repositoryState = try await repository
                    .replaceCredential(
                        for: existing.id,
                        with: credentials,
                        externalIdentity: identity,
                        expectedRevision:
                            repositoryState.revision
                    )
                if repositoryState.activeAccountID
                    != existing.id
                {
                    repositoryState = try await repository
                        .setActiveAccountID(
                            existing.id,
                            expectedRevision:
                                repositoryState.revision
                        )
                }
            } else {
                repositoryState = try await repository
                    .createAccount(
                        credentials: credentials,
                        label: label,
                        externalIdentity: identity,
                        migrationAliases: [],
                        makeActive: true,
                        expectedRevision:
                            repositoryState.revision
                    )
            }

            guard isCurrent(transactionID) else {
                return nil
            }
            let settings =
                try await settingsStore.load()
            guard isCurrent(transactionID) else {
                return nil
            }
            return prepareRefresh(
                trigger: .accountBoundaryChanged,
                migrationStatus:
                    currentSnapshot.migrationStatus,
                context: CanonicalContext(
                    repositoryState: repositoryState,
                    settings: settings
                ),
                transactionID: transactionID
            )
        }
    }

    @discardableResult
    func deleteAccount(
        _ accountID: AntigravityAccountID
    ) async throws -> AntigravityRuntimeSnapshot {
        try await performBoundaryMutation {
            transactionID in
            try ensureMutable()
            guard isCurrent(transactionID) else {
                return nil
            }
            let context = try await requireCanonicalContext(
                boundaryID: transactionID
            )
            guard isCurrent(transactionID) else {
                return nil
            }
            guard context.repositoryState.usableAccounts
                .contains(where: { $0.id == accountID })
            else {
                throw AntigravityRuntimeControllerError
                    .accountNotFound
            }
            let repositoryState = try await repository
                .deleteAccount(
                    id: accountID,
                    expectedRevision:
                        context.repositoryState.revision
                )
            guard isCurrent(transactionID) else {
                return nil
            }
            let settings =
                try await settingsStore.load()
            guard isCurrent(transactionID) else {
                return nil
            }
            return prepareRefresh(
                trigger: .accountBoundaryChanged,
                migrationStatus:
                    currentSnapshot.migrationStatus,
                context: CanonicalContext(
                    repositoryState: repositoryState,
                    settings: settings
                ),
                transactionID: transactionID
            )
        }
    }

    @discardableResult
    func updateConnection(
        _ connection: AntigravityConnectionSettings
    ) async throws -> AntigravityRuntimeSnapshot {
        try ensureMutable()
        guard connection.isCurrentAndValid else {
            throw AntigravitySettingsStoreError
                .invalidValue(.connection)
        }
        return try await performBoundaryMutation {
            transactionID in
            try ensureMutable()
            guard isCurrent(transactionID) else {
                return nil
            }
            let context = try await requireCanonicalContext(
                boundaryID: transactionID
            )
            guard isCurrent(transactionID) else {
                return nil
            }
            let settings = AntigravitySettingsSnapshot(
                connection:
                    try await settingsStore
                        .saveConnection(connection),
                display: context.settings.display
            )
            guard isCurrent(transactionID) else {
                return nil
            }
            let repositoryState =
                try await repository.state()
            guard isCurrent(transactionID) else {
                return nil
            }
            return prepareRefresh(
                trigger: .sourceBoundaryChanged,
                migrationStatus:
                    currentSnapshot.migrationStatus,
                context: CanonicalContext(
                    repositoryState: repositoryState,
                    settings: settings
                ),
                transactionID: transactionID
            )
        }
    }

    @discardableResult
    func updateDisplay(
        _ display: AntigravityDisplaySettings,
        replacing expectedDisplay:
            AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot {
        guard display.isCurrentAndValid,
              expectedDisplay.isCurrentAndValid
        else {
            throw AntigravitySettingsStoreError
                .invalidValue(.display)
        }
        return try await mutateDisplay(
            replacing: expectedDisplay
        ) {
            $0 = display
        }
    }

    @discardableResult
    func updateMenuBarStyle(
        _ style: AntigravityDisplaySettings
            .MenuBarPresentationIntent.Style
    ) async throws -> AntigravityRuntimeSnapshot {
        try await mutateDisplay {
            $0.menuBar.style = style
        }
    }

    private func mutateDisplay(
        replacing expectedDisplay:
            AntigravityDisplaySettings? = nil,
        _ mutation:
            (inout AntigravityDisplaySettings)
                -> Void
    ) async throws -> AntigravityRuntimeSnapshot {
        try await withOperationGate {
            try ensureMutable()
            let boundaryID = currentBoundaryID
            let context = try await requireCanonicalContext(
                boundaryID: boundaryID
            )
            guard isCurrentBoundary(boundaryID) else {
                return currentSnapshot
            }
            if let expectedDisplay,
               context.settings.display
                != expectedDisplay
            {
                throw AntigravityRuntimeControllerError
                    .operationSuperseded
            }
            var display = context.settings.display
            mutation(&display)
            guard display.isCurrentAndValid else {
                throw AntigravitySettingsStoreError
                    .invalidValue(.display)
            }
            guard display != context.settings.display else {
                return currentSnapshot
            }
            let settings = AntigravitySettingsSnapshot(
                connection: context.settings.connection,
                display:
                    try await settingsStore
                        .saveDisplay(display)
            )
            try ensureMutable()
            guard isCurrentBoundary(boundaryID) else {
                return currentSnapshot
            }
            return publish(
                readiness: .ready,
                migrationStatus:
                    currentSnapshot.migrationStatus,
                repositoryState:
                    context.repositoryState,
                settings: settings,
                presentationState:
                    currentSnapshot
                        .presentationState
            )
        }
    }

    @discardableResult
    func continueMigration()
        async -> AntigravityRuntimeSnapshot
    {
        guard !isShuttingDown else {
            return currentSnapshot
        }
        let transactionID =
            beginBoundaryChange().id
        await refreshCoordinator.invalidateBoundary()
        let transaction = await withOperationGate {
            () async -> RefreshTransaction? in
            guard !isShuttingDown,
                  isCurrent(transactionID)
            else {
                return nil
            }
            let migration =
                await migrationCoordinator
                    .performInteractiveMigration()
            guard !isShuttingDown,
                  isCurrent(transactionID)
            else {
                return nil
            }
            guard
                let context =
                    await loadCanonicalContext(
                        migrationStatus: migration,
                        boundaryID: transactionID
                    )
            else {
                return nil
            }
            guard !isShuttingDown,
                  isCurrent(transactionID)
            else {
                return nil
            }
            return prepareRefresh(
                trigger: .migrationCompleted,
                migrationStatus: migration,
                context: context,
                transactionID: transactionID
            )
        }
        guard let transaction else {
            return currentSnapshot
        }
        return await executeRefresh(transaction)
    }

    @discardableResult
    func removeAllAccounts(
        interactively: Bool
    ) async -> AntigravityRuntimeSnapshot {
        guard !isShuttingDown else {
            return currentSnapshot
        }
        let transactionID =
            beginBoundaryChange().id
        await refreshCoordinator.invalidateBoundary()
        let transaction = await withOperationGate {
            () async -> RefreshTransaction? in
            guard !isShuttingDown,
                  isCurrent(transactionID)
            else {
                return nil
            }
            let migration: AntigravityMigrationStatus
            if interactively {
                migration = await migrationCoordinator
                    .removeAllAccountsInteractively()
            } else {
                migration = await migrationCoordinator
                    .removeAllAccounts()
            }
            guard !isShuttingDown,
                  isCurrent(transactionID)
            else {
                return nil
            }
            guard
                let context =
                    await loadCanonicalContext(
                        migrationStatus: migration,
                        boundaryID: transactionID
                    )
            else {
                return nil
            }
            guard !isShuttingDown,
                  isCurrent(transactionID)
            else {
                return nil
            }
            return prepareRefresh(
                trigger: .accountBoundaryChanged,
                migrationStatus: migration,
                context: context,
                transactionID: transactionID
            )
        }
        guard let transaction else {
            return currentSnapshot
        }
        return await executeRefresh(transaction)
    }

    @discardableResult
    func consumePendingSettingsNotice()
        async -> AntigravityRuntimeSnapshot
    {
        await withOperationGate {
            guard !isShuttingDown else {
                return currentSnapshot
            }
            let boundaryID = currentBoundaryID
            do {
                _ = try await settingsStore
                    .consumePendingNotice()
                guard isCurrentBoundary(boundaryID) else {
                    return currentSnapshot
                }
                let context =
                    try await requireCanonicalContext(
                        boundaryID: boundaryID
                    )
                guard isCurrentBoundary(boundaryID) else {
                    return currentSnapshot
                }
                return publish(
                    readiness: .ready,
                    migrationStatus:
                        currentSnapshot.migrationStatus,
                    repositoryState:
                        context.repositoryState,
                    settings: context.settings,
                    presentationState:
                        currentSnapshot
                            .presentationState
                )
            } catch {
                guard isCurrentBoundary(boundaryID) else {
                    return currentSnapshot
                }
                return publishBlocked(.typedSettings)
            }
        }
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !isShuttingDown else { return }
        isShuttingDown = true
        currentBoundaryID = UUID()
        activeRefreshTransactionID = nil
        publish(
            replacing: currentSnapshot,
            readiness: .shuttingDown,
            presentationState:
                .failed(.appShuttingDown)
        )

        let refreshCoordinator =
            self.refreshCoordinator
        let managedSession = self.managedSession
        let task = Task {
            async let quiesce: Void =
                refreshCoordinator
                    .quiesceForShutdown()
            async let stopManaged: Void =
                managedSession.shutdown()
            _ = await (quiesce, stopManaged)
        }
        shutdownTask = task
        await task.value
    }

    private struct CanonicalContext: Sendable {
        let repositoryState:
            AntigravityAccountRepositoryState
        let settings: AntigravitySettingsSnapshot
    }

    private func withOperationGate<T: Sendable>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await operationGate.acquire()
        do {
            let result = try await operation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func ensureMutable() throws {
        guard !isShuttingDown else {
            throw AntigravityRuntimeControllerError
                .appShuttingDown
        }
        guard settingsBootstrap.isReady else {
            throw AntigravityRuntimeControllerError
                .settingsMigrationBlocked
        }
    }

    private func requireCanonicalContext(
        boundaryID: UUID? = nil
    )
        async throws -> CanonicalContext
    {
        guard !isShuttingDown else {
            throw AntigravityRuntimeControllerError
                .appShuttingDown
        }
        let repositoryState: AntigravityAccountRepositoryState
        do {
            repositoryState = try await repository.state()
        } catch {
            if let boundaryID,
               !isCurrentBoundary(boundaryID)
            {
                throw AntigravityRuntimeControllerError
                    .canonicalAccountStateUnavailable
            }
            if isShuttingDown {
                throw AntigravityRuntimeControllerError
                    .appShuttingDown
            }
            _ = publishBlocked(.canonicalAccountState)
            throw AntigravityRuntimeControllerError
                .canonicalAccountStateUnavailable
        }
        guard !isShuttingDown else {
            throw AntigravityRuntimeControllerError
                .appShuttingDown
        }
        let settings: AntigravitySettingsSnapshot
        do {
            settings = try await settingsStore.load()
        } catch {
            if let boundaryID,
               !isCurrentBoundary(boundaryID)
            {
                throw AntigravityRuntimeControllerError
                    .typedSettingsUnavailable
            }
            if isShuttingDown {
                throw AntigravityRuntimeControllerError
                    .appShuttingDown
            }
            _ = publishBlocked(.typedSettings)
            throw AntigravityRuntimeControllerError
                .typedSettingsUnavailable
        }
        guard !isShuttingDown else {
            throw AntigravityRuntimeControllerError
                .appShuttingDown
        }
        return CanonicalContext(
            repositoryState: repositoryState,
            settings: settings
        )
    }

    private func loadCanonicalContext(
        migrationStatus: AntigravityMigrationStatus,
        boundaryID: UUID? = nil
    ) async -> CanonicalContext? {
        do {
            return try await requireCanonicalContext(
                boundaryID: boundaryID
            )
        } catch {
            if let boundaryID,
               !isCurrentBoundary(boundaryID)
            {
                return nil
            }
            guard !isShuttingDown else {
                return nil
            }
            publish(
                replacing: currentSnapshot,
                migrationStatus: migrationStatus
            )
            return nil
        }
    }

    private func performBoundaryMutation(
        _ mutation:
            (UUID) async throws
                -> RefreshTransaction?
    ) async throws -> AntigravityRuntimeSnapshot {
        try ensureMutable()
        let boundary = beginBoundaryChange()
        await refreshCoordinator.invalidateBoundary()

        do {
            let transaction =
                try await withOperationGate {
                    () async throws
                        -> RefreshTransaction? in
                    try ensureMutable()
                    guard isCurrent(boundary.id)
                    else {
                        return nil
                    }
                    return try await mutation(
                        boundary.id
                    )
                }
            guard let transaction else {
                try ensureMutable()
                throw AntigravityRuntimeControllerError
                    .operationSuperseded
            }
            let snapshot =
                await executeRefresh(transaction)
            guard isCurrent(transaction) else {
                try ensureMutable()
                throw AntigravityRuntimeControllerError
                    .operationSuperseded
            }
            return snapshot
        } catch {
            await recover(
                from: error,
                boundary: boundary
            )
            throw error
        }
    }

    private func recover(
        from error: Error,
        boundary: BoundaryChange
    ) async {
        guard isCurrent(boundary.id) else {
            return
        }
        if let controllerError =
                error
                    as?
                    AntigravityRuntimeControllerError,
           controllerError == .accountNotFound
        {
            activeRefreshTransactionID = nil
            publish(
                replacing:
                    boundary.previousSnapshot
            )
            return
        }

        let repositoryState:
            AntigravityAccountRepositoryState
        do {
            repositoryState =
                try await repository.state()
        } catch {
            guard isCurrent(boundary.id) else {
                return
            }
            activeRefreshTransactionID = nil
            _ = publishBlocked(.canonicalAccountState)
            return
        }
        guard isCurrent(boundary.id) else {
            return
        }

        let settings:
            AntigravitySettingsSnapshot
        do {
            settings = try await settingsStore.load()
        } catch {
            guard isCurrent(boundary.id) else {
                return
            }
            activeRefreshTransactionID = nil
            _ = publishBlocked(.typedSettings)
            return
        }
        guard isCurrent(boundary.id) else {
            return
        }

        activeRefreshTransactionID = nil
        publish(
            readiness: .ready,
            migrationStatus:
                currentSnapshot.migrationStatus,
            repositoryState: repositoryState,
            settings: settings,
            presentationState:
                .failed(.repositoryUnavailable)
        )
    }

    private func beginBoundaryChange()
        -> BoundaryChange
    {
        let previousSnapshot = currentSnapshot
        let transactionID = UUID()
        currentBoundaryID = transactionID
        activeRefreshTransactionID = transactionID
        publish(
            presentationState:
                .refreshing(previous: nil)
        )
        return BoundaryChange(
            id: transactionID,
            previousSnapshot: previousSnapshot
        )
    }

    private func isCurrent(
        _ transactionID: UUID
    ) -> Bool {
        !isShuttingDown
            && currentBoundaryID == transactionID
            && activeRefreshTransactionID
                == transactionID
    }

    private func isCurrentBoundary(
        _ boundaryID: UUID
    ) -> Bool {
        !isShuttingDown
            && currentBoundaryID == boundaryID
    }

    private func prepareRefresh(
        trigger: AntigravityRefreshTrigger,
        migrationStatus: AntigravityMigrationStatus?,
        context: CanonicalContext,
        transactionID requestedTransactionID:
            UUID? = nil,
        boundaryID requestedBoundaryID:
            UUID? = nil
    ) -> RefreshTransaction? {
        guard !isShuttingDown else {
            return nil
        }
        let boundaryID =
            requestedBoundaryID
                ?? requestedTransactionID
                ?? currentBoundaryID
        guard isCurrentBoundary(boundaryID)
        else {
            return nil
        }
        let transactionID: UUID
        if let requestedTransactionID {
            guard isCurrent(requestedTransactionID)
            else {
                return nil
            }
            transactionID = requestedTransactionID
        } else {
            transactionID = UUID()
            activeRefreshTransactionID =
                transactionID
        }
        let previous = trigger.clearsPreviousSnapshot
            ? nil
            : Self.snapshot(
                from: currentSnapshot
                    .presentationState
            )
        let refreshing =
            AntigravityPresentationState.refreshing(
                previous: previous
            )
        lastAttemptAt = now()
        publish(
            readiness: .ready,
            migrationStatus: migrationStatus,
            repositoryState: context.repositoryState,
            settings: context.settings,
            presentationState: refreshing
        )

        let request = AntigravityRefreshRequest(
            trigger: trigger,
            accountTarget: Self.accountTarget(
                repositoryState: context.repositoryState,
                connection:
                    context.settings.connection
            ),
            repositoryRevision:
                context.repositoryState.revision,
            connection: effectiveConnection(
                context.settings.connection
            )
        )
        return RefreshTransaction(
            id: transactionID,
            boundaryID: boundaryID,
            request: request,
            migrationStatus: migrationStatus,
            context: context
        )
    }

    private func executeRefresh(
        _ transaction: RefreshTransaction
    ) async -> AntigravityRuntimeSnapshot {
        let presentation =
            await refreshCoordinator.refresh(
                transaction.request
            )
        guard isCurrent(transaction) else {
            return currentSnapshot
        }

        let latestRepository:
            AntigravityAccountRepositoryState
        do {
            latestRepository =
                try await repository.state()
        } catch {
            latestRepository =
                transaction.context.repositoryState
        }
        guard isCurrent(transaction) else {
            return currentSnapshot
        }
        let latestSettings:
            AntigravitySettingsSnapshot
        do {
            latestSettings =
                try await settingsStore.load()
        } catch {
            latestSettings =
                transaction.context.settings
        }
        guard isCurrent(transaction) else {
            return currentSnapshot
        }
        if Self.isSuccessful(presentation) {
            lastSuccessfulAt = now()
        }
        return publish(
            readiness: .ready,
            migrationStatus:
                transaction.migrationStatus,
            repositoryState: latestRepository,
            settings: latestSettings,
            presentationState: presentation
        )
    }

    private func isCurrent(
        _ transaction: RefreshTransaction
    ) -> Bool {
        !isShuttingDown
            && currentBoundaryID
                == transaction.boundaryID
            && activeRefreshTransactionID
                == transaction.id
    }

    private func effectiveConnection(
        _ connection: AntigravityConnectionSettings
    ) -> AntigravityConnectionSettings {
        guard managedAvailability
                == .recoveryBlocked,
              connection.allowManagedCLI
        else {
            return connection
        }
        var safe = connection
        safe.allowManagedCLI = false
        return safe
    }

    @discardableResult
    private func publishBlocked(
        _ blocker: AntigravityRuntimeBlocker
    ) -> AntigravityRuntimeSnapshot {
        publish(
            readiness: .blocked(blocker),
            migrationStatus:
                currentSnapshot.migrationStatus,
            repositoryState: nil,
            settings: currentSnapshot.settings,
            presentationState:
                .failed(.repositoryUnavailable)
        )
    }

    @discardableResult
    private func publish(
        replacing base:
            AntigravityRuntimeSnapshot? = nil,
        readiness:
            AntigravityRuntimeReadiness? = nil,
        migrationStatus:
            AntigravityMigrationStatus? = nil,
        repositoryState:
            AntigravityAccountRepositoryState? = nil,
        settings:
            AntigravitySettingsSnapshot? = nil,
        presentationState:
            AntigravityPresentationState? = nil
    ) -> AntigravityRuntimeSnapshot {
        let base = base ?? currentSnapshot
        let resolvedSettings = settings ?? base.settings
        let resolvedPresentation =
            presentationState
                ?? base.presentationState
        let snapshot = AntigravityRuntimeSnapshot(
            readiness:
                readiness ?? base.readiness,
            migrationStatus:
                migrationStatus
                    ?? base.migrationStatus,
            repositoryRevision:
                repositoryState?.revision
                    ?? base.repositoryRevision,
            accounts:
                repositoryState.map(
                    Self.accountSummaries
                ) ?? base.accounts,
            activeAccountID:
                repositoryState.map {
                    $0.activeAccountID
                } ?? base.activeAccountID,
            settings: resolvedSettings,
            presentationState:
                resolvedPresentation,
            quotaPresentation:
                AntigravityQuotaPresentationMapper
                    .map(
                        state:
                            resolvedPresentation,
                        settings:
                            resolvedSettings?.display
                                ?? .default,
                        now: now()
                    ),
            managedRuntimeAvailability:
                managedAvailability,
            lastAttemptAt: lastAttemptAt,
            lastSuccessfulAt:
                lastSuccessfulAt
        )
        currentSnapshot = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
        return snapshot
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private nonisolated static func accountTarget(
        repositoryState:
            AntigravityAccountRepositoryState,
        connection: AntigravityConnectionSettings
    ) -> AntigravityRefreshAccountTarget {
        switch connection.sourcePolicy {
        case .localSession:
            return .ambientLocal
        case .automatic, .googleAccount:
            guard let accountID =
                    repositoryState.activeAccountID
            else {
                return .ambientLocal
            }
            return .selectedOAuth(accountID)
        }
    }

    private nonisolated static func accountSummaries(
        _ repositoryState:
            AntigravityAccountRepositoryState
    ) -> [AntigravityRuntimeAccountSummary] {
        repositoryState.usableAccounts.map { account in
            AntigravityRuntimeAccountSummary(
                id: account.id,
                label: account.label,
                identity:
                    account.externalIdentity
                        .providerAccountIdentity,
                isActive:
                    repositoryState.activeAccountID
                        == account.id
            )
        }
    }

    private nonisolated static func externalIdentity(
        from credentials: AntigravityOAuthCredentials
    ) -> AntigravityExternalAccountIdentity {
        AntigravityExternalAccountIdentity(
            googleSubject:
                idTokenSubject(credentials.idToken),
            email: credentials.email
        )
    }

    private nonisolated static func idTokenSubject(
        _ token: String?
    ) -> String? {
        guard let token = nonEmpty(token) else {
            return nil
        }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(
                repeating: "=",
                count: 4 - remainder
            )
        }
        guard
            let data = Data(
                base64Encoded: payload
            ),
            let object = try? JSONSerialization
                .jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return nonEmpty(object["sub"] as? String)
    }

    private nonisolated static func matches(
        _ identity:
            AntigravityExternalAccountIdentity,
        account: AntigravityStoredAccount
    ) -> Bool {
        AntigravityAccountIdentityMatcher.match(
            expected:
                account.externalIdentity
                    .providerAccountIdentity,
            received:
                identity.providerAccountIdentity
        ).isMatch
    }

    private nonisolated static func snapshot(
        from state: AntigravityPresentationState
    ) -> AntigravityQuotaSnapshot? {
        switch state {
        case .ready(let snapshot),
             .partial(let snapshot, _),
             .stale(let snapshot, _),
             .refreshing(previous: let snapshot?):
            return snapshot
        case .disabled,
             .setupRequired,
             .refreshing(previous: nil),
             .accountMismatch,
             .limited,
             .identityOnly,
             .failed:
            return nil
        }
    }

    private nonisolated static func isSuccessful(
        _ state: AntigravityPresentationState
    ) -> Bool {
        switch state {
        case .ready, .partial, .limited, .identityOnly:
            true
        case .disabled,
             .setupRequired,
             .refreshing,
             .stale,
             .accountMismatch,
             .failed:
            false
        }
    }

    private nonisolated static func nonEmpty(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
