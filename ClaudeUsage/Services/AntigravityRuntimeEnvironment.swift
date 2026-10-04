import Darwin
import Foundation

/// Cheap metadata only. Signature validation and hashing happen only after a change.
nonisolated struct AntigravityInstallationFingerprint: Sendable, Equatable {
    let entries: [String]

    static func read(home: URL, environment: [String: String]) -> Self {
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home, environment: environment
        )
        return Self(
            entries: candidates.agyExecutableURLs.map { url in
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
    let executableStatus: AntigravityAGYExecutableDiscoveryStatus
}

nonisolated struct AntigravityUnavailableRuntimeSource: AntigravityUsageSource {
    let id: AntigravityUsageSourceID
    let reason: AntigravityRuntimeFailure
    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        throw AntigravityUsageSourceError.runtimeUnavailable(reason)
    }
}

nonisolated protocol AntigravityRuntimeLifecycling: Sendable {
    /// Retires processes recorded by earlier releases. It never gates refreshes.
    func cleanUpLegacyManagedProcesses() async
    func shutdown() async
}

/// Serializes local graph leases, replacement and shutdown, without rebuilding
/// accounts or OAuth. A replaced graph owns no long-lived process: each CLI
/// usage report exits before its lease is released.
actor AntigravityRuntimeEnvironment: AntigravityRuntimeLifecycling {
    typealias FingerprintReader = @Sendable () async throws -> AntigravityInstallationFingerprint
    typealias Builder = @Sendable () async throws -> AntigravityLocalRuntimeGeneration
    typealias LegacyCleanup = @Sendable () async -> Void
    private let fingerprint: FingerprintReader
    private let build: Builder
    private let legacyCleanup: LegacyCleanup
    private var current: AntigravityLocalRuntimeGeneration?
    private var acceptedFingerprint: AntigravityInstallationFingerprint?
    private var leased = false
    private var stopped = false
    private var legacyCleanupTask: Task<Void, Never>?
    private var availability: AntigravityManagedRuntimeAvailability = .unavailable(reason: .executableNotFound)

    init(
        fingerprint: @escaping FingerprintReader,
        build: @escaping Builder,
        legacyCleanup: @escaping LegacyCleanup = {}
    ) {
        self.fingerprint = fingerprint
        self.build = build
        self.legacyCleanup = legacyCleanup
    }

    func managedAvailability() -> AntigravityManagedRuntimeAvailability { availability }

    func cleanUpLegacyManagedProcesses() async {
        guard !stopped, legacyCleanupTask == nil else { return }
        let legacyCleanup = self.legacyCleanup
        let task = Task.detached(priority: .utility) { await legacyCleanup() }
        legacyCleanupTask = task
        await task.value
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
            try check(deadline)
            var sources = generation.sources
            // The CLI source stays present even without a verified executable
            // so the failure names its cause instead of "no source".
            if let reason = runtimeFailure {
                sources.removeAll { $0.id == .cliReport }
                sources.append(AntigravityUnavailableRuntimeSource(id: .cliReport, reason: reason))
            }
            localSources = sources
        } catch let reason as AntigravityRuntimeFailure {
            localSources = [AntigravityUnavailableRuntimeSource(id: .cliReport, reason: reason)]
        }
        try check(deadline)
        return await operation(localSources)
    }

    private var runtimeFailure: AntigravityRuntimeFailure? {
        switch availability {
        case .available: nil
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
            return current
        }
        let candidate = try await bounded(deadline: deadline, operation: build)
        try check(deadline)
        let after = try await bounded(deadline: deadline, operation: fingerprint)
        try check(deadline)
        // A graph verified against files that changed meanwhile is never published.
        guard before == after else { throw AntigravityRuntimeFailure.executableChanged }
        availability = Self.availability(for: candidate.executableStatus)
        current = candidate
        acceptedFingerprint = after
        return candidate
    }

    private static func availability(
        for status: AntigravityAGYExecutableDiscoveryStatus
    ) -> AntigravityManagedRuntimeAvailability {
        switch status {
        case .verified(let path): .available(displayPath: path)
        case .notFound: .unavailable(reason: .executableNotFound)
        case .rejected: .unavailable(reason: .signatureRejected)
        }
    }

    func shutdown() async {
        stopped = true
        // The coordinator cancels its flights first. A cancelled report kills
        // its process group before the lease is released.
        while leased {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        await legacyCleanupTask?.value
        current = nil
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AntigravityRuntimeEnvironment {
        let legacyCleanup = AntigravityLegacyManagedProcessCleanup.production(
            stateDirectory: stateDirectory, homeDirectoryURL: homeDirectoryURL)
        let reportWorkspace = AntigravityCLIReportWorkspace.url(in: stateDirectory)
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
                    var sources: [any AntigravityUsageSource] = []
                    if let executable = resolution.reportExecutable {
                        sources.append(
                            AntigravityCLIUsageReportSource(
                                executable: executable,
                                executableRevalidator: resolution.catalog,
                                environment: AntigravityCLIReportEnvironment.values(
                                    homeDirectory: homeDirectoryURL),
                                prepareWorkingDirectory: {
                                    try AntigravityCLIReportWorkspace.prepare(at: reportWorkspace)
                                }
                            ))
                    }
                    return AntigravityLocalRuntimeGeneration(
                        sources: sources, executableStatus: resolution.agyExecutableStatus)
                }.value
            },
            legacyCleanup: { _ = await legacyCleanup.cleanUp() }
        )
    }
}
