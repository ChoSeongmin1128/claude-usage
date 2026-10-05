import Foundation

nonisolated enum AntigravityRuntimeControllerError:
    Error,
    Sendable,
    Equatable
{
    case appShuttingDown
    case settingsMigrationBlocked
    case typedSettingsUnavailable
    case operationSuperseded
}

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
/// Settings and refresh actors are individually safe, but their methods can
/// interleave at every `await`. This controller gates settings mutations, runs
/// remote refresh work outside that gate, and commits only the latest refresh
/// transaction to its secret-free projection.
actor AntigravityRuntimeController {
    private let settingsStore:
        any AntigravitySettingsStoring
    private let refreshCoordinator:
        any AntigravityRefreshCoordinating
    private let runtimeLifecycle: any AntigravityRuntimeLifecycling
    private let settingsBootstrap:
        AntigravitySettingsBootstrapResult
    private let agyExecutableStatus:
        AntigravityAGYExecutableDiscoveryStatus
    private let runtimeEnvironment: AntigravityRuntimeEnvironment?
    private let legacyAccountCleanup: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let operationGate =
        AntigravityRuntimeOperationGate()

    private struct RefreshTransaction: Sendable {
        let id: UUID
        let request: AntigravityRefreshRequest
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
    private var activeRefreshTransactionID: UUID?
    private var shutdownTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var lastSuccessfulAt: Date?
    private var usageDisplayBasis: UsageValueBasis?
    private var commonTimeFormat: TimeFormatStyle?
    private var usageDisplayRevision: UInt64 = 0

    init(
        settingsStore:
            any AntigravitySettingsStoring,
        refreshCoordinator:
            any AntigravityRefreshCoordinating,
        runtimeLifecycle:
            any AntigravityRuntimeLifecycling,
        settingsBootstrap:
            AntigravitySettingsBootstrapResult,
        agyExecutableStatus:
            AntigravityAGYExecutableDiscoveryStatus,
        runtimeEnvironment: AntigravityRuntimeEnvironment? = nil,
        legacyAccountCleanup: @escaping @Sendable () async -> Void = {},
        now:
            @escaping @Sendable () -> Date =
                Date.init
    ) {
        self.runtimeEnvironment = runtimeEnvironment
        self.settingsStore = settingsStore
        self.refreshCoordinator = refreshCoordinator
        self.runtimeLifecycle = runtimeLifecycle
        self.settingsBootstrap = settingsBootstrap
        self.agyExecutableStatus =
            agyExecutableStatus
        self.legacyAccountCleanup = legacyAccountCleanup
        self.now = now
        managedAvailability = Self.managedAvailability(
            for: agyExecutableStatus
        )
    }

    /// Reprojects verified data only. Never restarts a process or refreshes quota.
    @discardableResult
    func setUsageDisplayBasis(_ basis: UsageValueBasis?, revision: UInt64) -> AntigravityRuntimeSnapshot {
        guard !isShuttingDown, revision >= usageDisplayRevision else { return currentSnapshot }
        usageDisplayRevision = revision
        guard usageDisplayBasis != basis else { return currentSnapshot }
        usageDisplayBasis = basis
        return publish()
    }

    /// 공통 시간 형식으로 다시 그린다. 조회는 하지 않는다.
    @discardableResult
    func setTimeFormat(_ format: TimeFormatStyle?) -> AntigravityRuntimeSnapshot {
        guard !isShuttingDown, commonTimeFormat != format else { return currentSnapshot }
        commonTimeFormat = format
        return publish()
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
        let transaction = await withOperationGate {
            () async -> RefreshTransaction? in
            guard !isShuttingDown else {
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

            // Nothing current depends on the legacy ledger or the retired
            // account store, so their cleanup runs beside the first refresh.
            let runtimeLifecycle = self.runtimeLifecycle
            Task.detached(priority: .utility) {
                await runtimeLifecycle.cleanUpLegacyManagedProcesses()
            }
            let legacyAccountCleanup = self.legacyAccountCleanup
            Task.detached(priority: .utility) {
                await legacyAccountCleanup()
            }
            if let runtimeEnvironment {
                managedAvailability = await runtimeEnvironment.managedAvailability()
            }
            guard !isShuttingDown,
                let settings = await loadSettings()
            else {
                return nil
            }

            guard performInitialRefresh else {
                let presentation =
                    await refreshCoordinator
                        .presentationState()
                guard !isShuttingDown else {
                    return nil
                }
                _ = publish(
                    readiness: .ready,
                    settings: settings,
                    presentationState: presentation
                )
                return nil
            }
            return prepareRefresh(
                trigger: .manual,
                settings: settings
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
        let transaction = await withOperationGate {
            () async -> RefreshTransaction? in
            guard !isShuttingDown else {
                return nil
            }
            guard settingsBootstrap.isReady else {
                _ = publishBlocked(
                    .settingsMigration
                )
                return nil
            }
            guard let settings = await loadSettings() else {
                return nil
            }
            return prepareRefresh(
                trigger: trigger,
                settings: settings
            )
        }
        guard let transaction else {
            return currentSnapshot
        }
        return await executeRefresh(transaction)
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
            let current = try await requireSettings()
            if let expectedDisplay,
                current.display
                != expectedDisplay
            {
                throw AntigravityRuntimeControllerError
                    .operationSuperseded
            }
            var display = current.display
            mutation(&display)
            guard display.isCurrentAndValid else {
                throw AntigravitySettingsStoreError
                    .invalidValue(.display)
            }
            guard display != current.display else {
                return currentSnapshot
            }
            let settings = AntigravitySettingsSnapshot(
                connection: current.connection,
                display:
                    try await settingsStore
                        .saveDisplay(display)
            )
            try ensureMutable()
            return publish(
                readiness: .ready,
                settings: settings,
                presentationState:
                    currentSnapshot
                        .presentationState
            )
        }
    }

    @discardableResult
    func consumePendingSettingsNotice()
        async -> AntigravityRuntimeSnapshot
    {
        await withOperationGate {
            guard !isShuttingDown else {
                return currentSnapshot
            }
            do {
                _ = try await settingsStore
                    .consumePendingNotice()
                let settings = try await requireSettings()
                return publish(
                    readiness: .ready,
                    settings: settings,
                    presentationState:
                        currentSnapshot
                            .presentationState
                )
            } catch {
                guard !isShuttingDown else {
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
        activeRefreshTransactionID = nil
        publish(
            replacing: currentSnapshot,
            readiness: .shuttingDown,
            presentationState:
                .failed(.appShuttingDown)
        )

        let refreshCoordinator =
            self.refreshCoordinator
        let runtimeLifecycle = self.runtimeLifecycle
        let task = Task {
            // Quiescing cancels the flight first; the runtime then waits for
            // the cancelled report to reap its process group.
            await refreshCoordinator.quiesceForShutdown()
            await runtimeLifecycle.shutdown()
        }
        shutdownTask = task
        await task.value
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

    private func requireSettings()
        async throws -> AntigravitySettingsSnapshot
    {
        guard !isShuttingDown else {
            throw AntigravityRuntimeControllerError
                .appShuttingDown
        }
        let settings: AntigravitySettingsSnapshot
        do {
            settings = try await settingsStore.load()
        } catch {
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
        return settings
    }

    private func loadSettings() async -> AntigravitySettingsSnapshot? {
        try? await requireSettings()
    }

    private func prepareRefresh(
        trigger: AntigravityRefreshTrigger,
        settings: AntigravitySettingsSnapshot
    ) -> RefreshTransaction? {
        guard !isShuttingDown else {
            return nil
        }
        let transactionID = UUID()
        activeRefreshTransactionID = transactionID
        let refreshing =
            AntigravityPresentationState.refreshing(
                previous: Self.snapshot(
                    from: currentSnapshot
                        .presentationState
                )
            )
        lastAttemptAt = now()
        publish(
            readiness: .ready,
            settings: settings,
            presentationState: refreshing
        )
        return RefreshTransaction(
            id: transactionID,
            request: AntigravityRefreshRequest(
                trigger: trigger,
                connection: settings.connection
            )
        )
    }

    private static func managedAvailability(
        for status:
            AntigravityAGYExecutableDiscoveryStatus
    ) -> AntigravityManagedRuntimeAvailability {
        switch status {
        case .verified(let displayPath):
            return .available(
                displayPath: displayPath
            )
        case .notFound:
            return .unavailable(
                reason: .executableNotFound
            )
        case .rejected:
            return .unavailable(
                reason: .signatureRejected
            )
        }
    }

    private func executeRefresh(_ transaction: RefreshTransaction) async -> AntigravityRuntimeSnapshot {
        let presentation = await refreshCoordinator.refresh(transaction.request)
        guard isCurrent(transaction) else { return currentSnapshot }
        if let runtimeEnvironment {
            let availability = await runtimeEnvironment.managedAvailability()
            guard isCurrent(transaction) else { return currentSnapshot }
            managedAvailability = availability
        }
        return await withOperationGate {
            guard isCurrent(transaction) else { return currentSnapshot }
            let latestSettings: AntigravitySettingsSnapshot
            do {
                latestSettings = try await settingsStore.load()
            } catch {
                guard isCurrent(transaction) else { return currentSnapshot }
                return publishBlocked(.typedSettings)
            }
            guard isCurrent(transaction) else { return currentSnapshot }
            guard latestSettings.connection == transaction.request.connection else {
                return publishBlocked(.typedSettings)
            }
            let acceptedPresentation = presentation
            if Self.isSuccessful(acceptedPresentation) { lastSuccessfulAt = now() }
            switch acceptedPresentation {
            case .accountMismatch, .failed, .setupRequired: lastSuccessfulAt = nil
            default: break
            }
            return publish(
                readiness: .ready, settings: latestSettings,
                presentationState: acceptedPresentation)
        }
    }

    private func isCurrent(
        _ transaction: RefreshTransaction
    ) -> Bool {
        !isShuttingDown
            && activeRefreshTransactionID
                == transaction.id
    }

    @discardableResult
    private func publishBlocked(
        _ blocker: AntigravityRuntimeBlocker
    ) -> AntigravityRuntimeSnapshot {
        publish(
            readiness: .blocked(blocker),
            settings: currentSnapshot.settings,
            presentationState:
                .failed(.invalidRefreshContext)
        )
    }

    @discardableResult
    private func publish(
        replacing base:
            AntigravityRuntimeSnapshot? = nil,
        readiness:
            AntigravityRuntimeReadiness? = nil,
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
        guard currentSnapshot.publicationRevision < UInt64.max else { return currentSnapshot }
        let snapshot = AntigravityRuntimeSnapshot(
            readiness:
                readiness ?? base.readiness,
            settings: resolvedSettings,
            presentationState:
                resolvedPresentation,
            quotaPresentation: AntigravityQuotaPresentationMapper.map(
                state: resolvedPresentation,
                settings: Self.applyingCommonTimeFormat(
                    commonTimeFormat, to: resolvedSettings?.display ?? .default),
                basisOverride: usageDisplayBasis,
                now: now()
            ),
            managedRuntimeAvailability:
                managedAvailability,
            lastAttemptAt: lastAttemptAt,
            lastSuccessfulAt:
                lastSuccessfulAt,
            publicationRevision: currentSnapshot.publicationRevision + 1
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


}

extension AntigravityRuntimeController {
    nonisolated static func applyingCommonTimeFormat(
        _ format: TimeFormatStyle?, to display: AntigravityDisplaySettings
    ) -> AntigravityDisplaySettings {
        guard let format else { return display }
        var display = display
        display.menuBar.timeFormat = format
        return display
    }
}
