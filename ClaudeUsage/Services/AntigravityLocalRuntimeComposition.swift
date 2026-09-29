import Foundation

/// Leaf system boundaries of local app discovery. Tests inject deterministic
/// replacements while exercising the same assembly path.
nonisolated struct AntigravityLocalRuntimeDependencies: Sendable {
    let subprocessRunner: any AntigravityOwnedSubprocessRunning
    let libprocReader: any AntigravityLibprocReading
    let kernelIdentityReader: any AntigravityKernelProcessIdentityReading
    let runningExecutableImageValidator: any AntigravityRunningExecutableImageValidating
    let runningCodeTrustValidator: any AntigravityRunningCodeTrustValidating
    let portInspector: any AntigravityPortOwnershipInspecting

    static func production() -> Self {
        let subprocessRunner = AntigravityOwnedSubprocessRunner()
        return Self(
            subprocessRunner: subprocessRunner,
            libprocReader: AntigravitySystemLibprocReader(),
            kernelIdentityReader: AntigravitySystemKernelProcessIdentityReader(),
            runningExecutableImageValidator: AntigravitySystemRunningExecutableImageValidator(),
            runningCodeTrustValidator: AntigravityOfficialRunningCodeTrustValidator(),
            portInspector: AntigravityPortOwnershipInspector(subprocessRunner: subprocessRunner)
        )
    }
}

/// Discovery and RPC for the Antigravity app's language server.
///
/// Only app language servers are discovery installations. The AGY CLI is read
/// through its own usage report, so running AGY processes are never probed.
nonisolated struct AntigravityLocalRuntimeComposition: Sendable {
    let processInspector: AntigravityProcessInspector
    let discovery: AntigravityRuntimeDiscovery
    let localRPCClient: AntigravityLocalRPCClient

    static func makeProduction(catalog: AntigravityExecutableCatalog) -> Self {
        make(catalog: catalog, dependencies: .production())
    }

    static func make(
        catalog: AntigravityExecutableCatalog,
        dependencies: AntigravityLocalRuntimeDependencies
    ) -> Self {
        let processInspector = AntigravityProcessInspector(
            catalog: catalog,
            subprocessRunner: dependencies.subprocessRunner,
            libprocReader: dependencies.libprocReader,
            kernelIdentityReader: dependencies.kernelIdentityReader,
            runningExecutableImageValidator: dependencies.runningExecutableImageValidator,
            runningCodeTrustValidator: dependencies.runningCodeTrustValidator
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: dependencies.portInspector,
            installations: catalog.executables.filter { $0.role == .appLanguageServer }
        )
        let endpointRevalidator = AntigravityRuntimeEndpointRevalidator(
            processInspector: processInspector,
            portInspector: dependencies.portInspector
        )
        let localRPCClient = AntigravityLocalRPCClient(
            connectionFactory: AntigravityURLSessionRPCConnectionFactory(
                endpointRevalidator: endpointRevalidator
            )
        )
        return Self(
            processInspector: processInspector,
            discovery: discovery,
            localRPCClient: localRPCClient
        )
    }
}
