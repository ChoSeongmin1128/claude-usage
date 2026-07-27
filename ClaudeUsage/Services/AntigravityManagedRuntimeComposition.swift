import Foundation

/// The complete Stage 4/5 local runtime graph.
///
/// The ownership registry is intentionally created only by the factory. This
/// prevents production callers from constructing discovery and the managed
/// session with different registries and silently classifying an app-owned AGY
/// process as borrowed.
nonisolated struct AntigravityManagedRuntimeComposition: Sendable {
    let ownershipRegistry: AntigravityManagedRuntimeRegistry
    let processInspector: AntigravityProcessInspector
    let portInspector: any AntigravityPortOwnershipInspecting
    let discovery: AntigravityRuntimeDiscovery
    let endpointRevalidator: AntigravityRuntimeEndpointRevalidator
    let connectionFactory: AntigravityURLSessionRPCConnectionFactory
    let localRPCClient: AntigravityLocalRPCClient
    let managedProcessRecovery:
        AntigravityManagedSessionLifecycleRecovery
    let managedSession: AntigravityManagedCLISession
}

/// Leaf dependencies that do not participate in runtime ownership.
///
/// Production code should obtain these through `production`. Tests can inject
/// deterministic system boundaries while exercising the same composition
/// path. No ownership resolver/registering dependency is accepted here:
/// ownership is a graph invariant, not a caller option.
nonisolated struct AntigravityManagedRuntimeCompositionDependencies:
    Sendable
{
    let subprocessRunner: any AntigravityOwnedSubprocessRunning
    let libprocReader: any AntigravityLibprocReading
    let kernelIdentityReader:
        any AntigravityKernelProcessIdentityReading
    let runningExecutableImageValidator:
        any AntigravityRunningExecutableImageValidating
    let runningCodeTrustValidator:
        any AntigravityRunningCodeTrustValidating
    let portInspector: any AntigravityPortOwnershipInspecting
    let launcher: any AntigravityManagedCLIProcessLaunching
    let identityProviderOverride:
        (any AntigravityManagedProcessIdentityProviding)?
    let recordStore: any AntigravityManagedProcessLedgerStoring
    let launchCoordinator:
        any AntigravityManagedLaunchCoordinating
    let recoverySignaler:
        any AntigravityExactProcessSignaling
    let bootSessionProvider:
        any AntigravityBootSessionIdentityProviding
    let launchIntentInspectorOverride:
        (any AntigravityManagedLaunchIntentInspecting)?
    let processTreeInspectorOverride:
        (any AntigravityManagedProcessTreeInspecting)?
    let processTreeControllerOverride:
        (any AntigravityManagedProcessTreeControlling)?
    let readinessProbe:
        (any AntigravityManagedCLIRPCReadinessProbing)?

    init(
        subprocessRunner: any AntigravityOwnedSubprocessRunning,
        libprocReader: any AntigravityLibprocReading,
        kernelIdentityReader:
            any AntigravityKernelProcessIdentityReading,
        runningExecutableImageValidator:
            any AntigravityRunningExecutableImageValidating,
        runningCodeTrustValidator:
            any AntigravityRunningCodeTrustValidating,
        portInspector: any AntigravityPortOwnershipInspecting,
        launcher: any AntigravityManagedCLIProcessLaunching,
        identityProviderOverride:
            (any AntigravityManagedProcessIdentityProviding)? = nil,
        recordStore: any AntigravityManagedProcessLedgerStoring,
        launchCoordinator:
            any AntigravityManagedLaunchCoordinating,
        recoverySignaler:
            any AntigravityExactProcessSignaling,
        bootSessionProvider:
            any AntigravityBootSessionIdentityProviding =
                AntigravitySystemBootSessionIdentityProvider(),
        launchIntentInspectorOverride:
            (any AntigravityManagedLaunchIntentInspecting)? = nil,
        processTreeInspectorOverride:
            (any AntigravityManagedProcessTreeInspecting)? = nil,
        processTreeControllerOverride:
            (any AntigravityManagedProcessTreeControlling)? = nil,
        readinessProbe:
            (any AntigravityManagedCLIRPCReadinessProbing)? = nil
    ) {
        self.subprocessRunner = subprocessRunner
        self.libprocReader = libprocReader
        self.kernelIdentityReader = kernelIdentityReader
        self.runningExecutableImageValidator =
            runningExecutableImageValidator
        self.runningCodeTrustValidator =
            runningCodeTrustValidator
        self.portInspector = portInspector
        self.launcher = launcher
        self.identityProviderOverride = identityProviderOverride
        self.recordStore = recordStore
        self.launchCoordinator = launchCoordinator
        self.recoverySignaler = recoverySignaler
        self.bootSessionProvider = bootSessionProvider
        self.launchIntentInspectorOverride =
            launchIntentInspectorOverride
        self.processTreeInspectorOverride =
            processTreeInspectorOverride
        self.processTreeControllerOverride =
            processTreeControllerOverride
        self.readinessProbe = readinessProbe
    }

    static func production(
        managedStateDirectoryURL: URL =
            AntigravityStoragePaths
                .canonicalStateDirectoryURL()
    ) -> Self {
        let subprocessRunner = AntigravityOwnedSubprocessRunner()
        let libprocReader = AntigravitySystemLibprocReader()
        let recordStore =
            AntigravityManagedProcessRecordFileStore(
                fileURL: managedStateDirectoryURL
                    .appendingPathComponent(
                        "managed-agy-sessions.json"
                    )
            )

        return Self(
            subprocessRunner: subprocessRunner,
            libprocReader: libprocReader,
            kernelIdentityReader:
                AntigravitySystemKernelProcessIdentityReader(),
            runningExecutableImageValidator:
                AntigravitySystemRunningExecutableImageValidator(),
            runningCodeTrustValidator:
                AntigravityOfficialRunningCodeTrustValidator(),
            portInspector: AntigravityPortOwnershipInspector(
                subprocessRunner: subprocessRunner
            ),
            launcher: AntigravityManagedCLIProcessLauncher(),
            recordStore: recordStore,
            launchCoordinator:
                AntigravityManagedLaunchFileCoordinator(
                    directoryURL: managedStateDirectoryURL
                ),
            recoverySignaler:
                AntigravitySystemExactProcessSignaler()
        )
    }
}

nonisolated enum AntigravityManagedRuntimeCompositionFactory {
    static func makeProduction(
        catalog: AntigravityExecutableCatalog,
        managedStateDirectoryURL: URL =
            AntigravityStoragePaths
                .canonicalStateDirectoryURL(),
        environment: AntigravityManagedCLIEnvironment =
            AntigravityManagedCLIEnvironment(),
        currentDirectoryURL: URL =
            FileManager.default.realHomeDirectory
    ) -> AntigravityManagedRuntimeComposition {
        make(
            catalog: catalog,
            dependencies: .production(
                managedStateDirectoryURL:
                    managedStateDirectoryURL
            ),
            environment: environment,
            currentDirectoryURL: currentDirectoryURL
        )
    }

    /// Assembles both production and deterministic integration-test graphs.
    ///
    /// Recovery deliberately does not register persisted records as managed:
    /// persisted evidence cannot grant live ownership. It does share the same
    /// record store and identity boundary used by the session.
    static func make(
        catalog: AntigravityExecutableCatalog,
        dependencies:
            AntigravityManagedRuntimeCompositionDependencies,
        environment: AntigravityManagedCLIEnvironment =
            AntigravityManagedCLIEnvironment(),
        currentDirectoryURL: URL =
            FileManager.default.realHomeDirectory
    ) -> AntigravityManagedRuntimeComposition {
        let managedIdentityProvider =
            dependencies.identityProviderOverride
                ?? AntigravityManagedProcessIdentityProvider(
                    libprocReader: dependencies.libprocReader,
                    kernelIdentityReader:
                        dependencies.kernelIdentityReader
                )
        let ownershipRegistry =
            AntigravityManagedRuntimeRegistry(
                ledgerStore: dependencies.recordStore,
                bootSessionProvider:
                    dependencies.bootSessionProvider,
                identityProvider: managedIdentityProvider
            )
        let processInspector = AntigravityProcessInspector(
            catalog: catalog,
            subprocessRunner: dependencies.subprocessRunner,
            libprocReader: dependencies.libprocReader,
            kernelIdentityReader:
                dependencies.kernelIdentityReader,
            runningExecutableImageValidator:
                dependencies.runningExecutableImageValidator,
            runningCodeTrustValidator:
                dependencies.runningCodeTrustValidator,
            ownershipResolver: ownershipRegistry
        )
        let portInspector = dependencies.portInspector
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: catalog.executables
        )
        let endpointRevalidator =
            AntigravityRuntimeEndpointRevalidator(
                processInspector: processInspector,
                portInspector: portInspector,
                ownershipResolver: ownershipRegistry
            )
        let connectionFactory =
            AntigravityURLSessionRPCConnectionFactory(
                endpointRevalidator: endpointRevalidator
            )
        let localRPCClient = AntigravityLocalRPCClient(
            connectionFactory: connectionFactory
        )
        let recordedProcessInspector =
            AntigravitySystemRecordedProcessInspector(
                identityProvider: managedIdentityProvider
            )
        let processTreeInspector =
            dependencies.processTreeInspectorOverride
                ?? AntigravitySystemManagedProcessTreeInspector(
                    identityProvider: managedIdentityProvider
                )
        let recordRecovery =
            AntigravityManagedProcessRecovery(
                recordStore: dependencies.recordStore,
                processInspector: recordedProcessInspector,
                processTreeInspector: processTreeInspector,
                signaler: dependencies.recoverySignaler
            )
        let launchIntentInspector =
            dependencies.launchIntentInspectorOverride
                ?? AntigravitySystemManagedLaunchIntentInspector(
                    identityProvider: managedIdentityProvider
                )
        let managedProcessRecovery =
            AntigravityManagedSessionLifecycleRecovery(
                ledgerStore: dependencies.recordStore,
                bootSessionProvider:
                    dependencies.bootSessionProvider,
                intentInspector: launchIntentInspector,
                recordRecovery: recordRecovery
            )
        let processTreeController =
            dependencies.processTreeControllerOverride
                ?? AntigravityManagedProcessTreeController(
                    recordStore: dependencies.recordStore,
                    processInspector: recordedProcessInspector,
                    processTreeInspector: processTreeInspector,
                    signaler: dependencies.recoverySignaler
                )
        let readinessProbe =
            dependencies.readinessProbe
                ?? AntigravityManagedCLIRPCReadinessProbe(
                    connectionFactory: connectionFactory
                )
        let readinessChecker =
            AntigravityManagedCLIReadinessChecker(
                discovery: discovery,
                processInspector: processInspector,
                rpcProbe: readinessProbe
            )
        let managedSession = AntigravityManagedCLISession(
            launcher: dependencies.launcher,
            executableRevalidator: catalog,
            identityProvider: managedIdentityProvider,
            recordStore: dependencies.recordStore,
            launchCoordinator: dependencies.launchCoordinator,
            recovery: managedProcessRecovery,
            processTreeController: processTreeController,
            registry: ownershipRegistry,
            readinessChecker: readinessChecker,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL
        )

        return AntigravityManagedRuntimeComposition(
            ownershipRegistry: ownershipRegistry,
            processInspector: processInspector,
            portInspector: portInspector,
            discovery: discovery,
            endpointRevalidator: endpointRevalidator,
            connectionFactory: connectionFactory,
            localRPCClient: localRPCClient,
            managedProcessRecovery: managedProcessRecovery,
            managedSession: managedSession
        )
    }
}
