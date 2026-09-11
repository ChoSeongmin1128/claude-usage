import Darwin
import Foundation

/// Cheap metadata only. Signature validation and hashing happen only after a change.
nonisolated struct AntigravityInstallationFingerprint: Sendable, Equatable {
    let entries: [String]

    static func read(home: URL, environment: [String: String]) -> Self {
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home, environment: environment
        )
        let paths = candidates.agyExecutableURLs + candidates.appBundleRoots.flatMap { root in
            [root, root.appendingPathComponent("Contents/Info.plist"),
             root.appendingPathComponent("Contents/_CodeSignature/CodeResources")]
                + AntigravityExecutableCatalog.appLanguageServerRelativePaths.map {
                    root.appendingPathComponent($0)
                }
        }
        return Self(entries: paths.map { url in
            var value = stat()
            let path = url.standardizedFileURL.path
            guard lstat(path, &value) == 0 else { return "\(path):missing:\(errno)" }
            return [path, url.resolvingSymlinksInPath().path,
                    String(value.st_dev), String(value.st_ino), String(value.st_size),
                    String(value.st_mode), String(value.st_uid), String(value.st_gid),
                    String(value.st_nlink), String(value.st_ctimespec.tv_sec),
                    String(value.st_ctimespec.tv_nsec), String(value.st_mtimespec.tv_sec),
                    String(value.st_mtimespec.tv_nsec)].joined(separator: ":")
        })
    }
}

/// All local dependencies in a lease come from this one immutable graph.
nonisolated struct AntigravityLocalRuntimeGeneration: Sendable {
    let sources: [any AntigravityUsageSource]
    let discovery: any AntigravityManagedRuntimeDiscovering
    let session: any AntigravityManagedSessionLifecycling
    let executableStatus: AntigravityAGYExecutableDiscoveryStatus
}

nonisolated struct AntigravityUnavailableRuntimeSource: AntigravityUsageSource {
    let id: AntigravityUsageSourceID
    let reason: AntigravityRuntimeFailure
    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        throw AntigravityUsageSourceError.runtimeUnavailable(reason)
    }
}

/// Serializes local graph leases, replacement and shutdown, without rebuilding accounts
/// or OAuth. A cancelled refresh must release its graph before its successor may replace it.
actor AntigravityRuntimeEnvironment: AntigravityManagedSessionLifecycling {
    typealias FingerprintReader = @Sendable () async throws -> AntigravityInstallationFingerprint
    typealias Builder = @Sendable () async throws -> AntigravityLocalRuntimeGeneration
    private let fingerprint: FingerprintReader
    private let build: Builder
    private var current: AntigravityLocalRuntimeGeneration?
    private var acceptedFingerprint: AntigravityInstallationFingerprint?
    private var leased = false
    private var stopped = false
    private var availability: AntigravityManagedRuntimeAvailability = .unavailable(reason: .executableNotFound)

    init(fingerprint: @escaping FingerprintReader, build: @escaping Builder) {
        self.fingerprint = fingerprint
        self.build = build
    }

    func managedAvailability() -> AntigravityManagedRuntimeAvailability { availability }

    /// Startup recovery also runs when provider refresh is disabled. It never
    /// launches AGY; orphaned ownership records must not survive until a user refresh.
    func recoverOrphanedProcesses() async throws {
        let deadline = AntigravityRPCDeadline(totalTimeout: AntigravityRPCDeadline.defaultRefreshTimeout)
        try await acquire(deadline: deadline)
        defer { leased = false }
        _ = try await prepare(deadline: deadline)
        if case .recoveryBlocked = availability { throw AntigravityRuntimeFailure.recoveryBlocked }
    }

    func withSources<T: Sendable>(
        forceDiscovery: Bool,
        deadline: AntigravityRPCDeadline,
        operation: @Sendable ([any AntigravityUsageSource]) async -> T
    ) async throws -> T {
        try await acquire(deadline: deadline)
        defer { leased = false }
        let localSources: [any AntigravityUsageSource]
        do {
            let generation = try await prepare(deadline: deadline)
            if forceDiscovery { await generation.discovery.invalidateCache() }
            try check(deadline)
            var sources = generation.sources
            // The managed source remains present even when no executable exists.
            // It reports an actionable failure but never launches in a blocked state.
            if let reason = runtimeFailure {
                sources.removeAll { $0.id == .managedCLI }
                sources.append(AntigravityUnavailableRuntimeSource(id: .managedCLI, reason: reason))
            }
            localSources = sources
        } catch let reason as AntigravityRuntimeFailure {
            localSources = [.localApp, .borrowedCLI, .managedCLI].map {
                AntigravityUnavailableRuntimeSource(id: $0, reason: reason)
            }
        }
        try check(deadline)
        return await operation(localSources)
    }

    private var runtimeFailure: AntigravityRuntimeFailure? {
        switch availability {
        case .available: nil
        case .recoveryBlocked: .recoveryBlocked
        case .unavailable(.executableNotFound): .executableMissing
        case .unavailable(.signatureRejected): .verificationRejected
        }
    }

    private func bounded<T: Sendable>(deadline: AntigravityRPCDeadline,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try await operation() }
        defer { task.cancel() }
        return try await AntigravityEnvironmentTaskWaiter<T>().value(of: task, deadline: deadline)
    }

    private func acquire(deadline: AntigravityRPCDeadline) async throws {
        while leased {
            try check(deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(deadline)
        leased = true
    }

    private func check(_ deadline: AntigravityRPCDeadline) throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try deadline.check(.request)
    }

    private func prepare(deadline: AntigravityRPCDeadline) async throws -> AntigravityLocalRuntimeGeneration {
        let before = try await bounded(deadline: deadline, operation: fingerprint)
        try check(deadline)
        if let current, acceptedFingerprint == before {
            // Recovery failures are retryable without rehashing or rebuilding the graph.
            if case .recoveryBlocked = availability {
                let recovered = await recover(current)
                try check(deadline)
                availability = recovered
            }
            return current
        }
        let candidate = try await bounded(deadline: deadline, operation: build)
        try check(deadline)
        let after = try await bounded(deadline: deadline, operation: fingerprint)
        try check(deadline)
        guard before == after else { throw AntigravityRuntimeFailure.executableChanged }

        // No lease can overlap here. Only the old app-owned process tree is retired.
        if let old = current {
            current = nil
            acceptedFingerprint = nil
            await old.session.shutdown()
            try check(deadline)
        }
        let recovered = await recover(candidate)
        try check(deadline)
        // Shutdown/recovery may take time. Never publish a now-obsolete candidate.
        guard try await bounded(deadline: deadline, operation: fingerprint) == after else {
            throw AntigravityRuntimeFailure.executableChanged
        }
        try check(deadline)
        availability = recovered
        current = candidate
        acceptedFingerprint = after
        return candidate
    }

    private func recover(_ generation: AntigravityLocalRuntimeGeneration) async -> AntigravityManagedRuntimeAvailability {
        let path: String?
        if case .verified(let value) = generation.executableStatus { path = value } else { path = nil }
        do {
            try await generation.session.recoverOrphanedProcesses()
            switch generation.executableStatus {
            case .verified(let path): return .available(displayPath: path)
            case .notFound: return .unavailable(reason: .executableNotFound)
            case .rejected: return .unavailable(reason: .signatureRejected)
            }
        } catch {
            return .recoveryBlocked(displayPath: path)
        }
    }

    func shutdown() async {
        stopped = true
        // The coordinator cancels its flights first. Retain their graph until they finish.
        while leased {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        if let current {
            self.current = nil
            await current.session.shutdown()
        }
    }
}

/// Bounds read-only Security.framework work even when the system call cannot be
/// interrupted. Late results have no publication authority and own no processes.
private nonisolated final class AntigravityEnvironmentTaskWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func value(of task: Task<Value, Error>, deadline: AntigravityRPCDeadline) async throws -> Value {
        let timeout = try deadline.timeout(for: .request)
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.finish(.failure(AntigravityRPCDeadlineError.timedOut(.request)))
            } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
                Task.detached { self.finish(await task.result) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension AntigravityRuntimeEnvironment {
    nonisolated static func production(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory,
        stateDirectory: URL = AntigravityStoragePaths.canonicalStateDirectoryURL(),
        managedLaunchCoordinationDirectory: URL = AntigravityStoragePaths.managedLaunchCoordinationDirectoryURL(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AntigravityRuntimeEnvironment {
        return AntigravityRuntimeEnvironment(
            fingerprint: {
                await Task.detached(priority: .utility) {
                    AntigravityInstallationFingerprint.read(home: homeDirectoryURL, environment: environment)
                }.value
            },
            build: {
                await Task.detached(priority: .utility) {
                    let resolution = AntigravityProductionExecutableCatalogResolver(
                        homeDirectoryURL: homeDirectoryURL, environment: environment
                    ).resolve()
                    let runtime = AntigravityManagedRuntimeCompositionFactory.makeProduction(
                        catalog: resolution.catalog,
                        managedStateDirectoryURL: stateDirectory,
                        managedLaunchCoordinationDirectoryURL: managedLaunchCoordinationDirectory,
                        currentDirectoryURL: homeDirectoryURL
                    )
                    var sources: [any AntigravityUsageSource] = [
                        AntigravityDiscoveredLocalUsageSource(id: .localApp, discovery: runtime.discovery, client: runtime.localRPCClient),
                        AntigravityDiscoveredLocalUsageSource(id: .borrowedCLI, discovery: runtime.discovery, client: runtime.localRPCClient),
                    ]
                    if let executable = resolution.managedLaunchExecutable {
                        sources.append(AntigravityManagedCLIUsageSource(session: runtime.managedSession, executable: executable, client: runtime.localRPCClient))
                    }
                    return AntigravityLocalRuntimeGeneration(sources: sources, discovery: runtime.discovery,
                        session: runtime.managedSession, executableStatus: resolution.agyExecutableStatus)
                }.value
            }
        )
    }
}
