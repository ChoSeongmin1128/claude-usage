import CryptoKit
import Foundation
import Security

nonisolated protocol AntigravityRuntimeEndpointRevalidating: Sendable {
    func revalidate(
        _ endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline
    ) async throws
}

/// Re-checks both sides of the endpoint proof: the immutable process identity
/// and ownership of the selected listening port.
nonisolated final class AntigravityRuntimeEndpointRevalidator:
    AntigravityRuntimeEndpointRevalidating,
    @unchecked Sendable
{
    private let processInspector: any AntigravityRuntimeProcessInspecting
    private let portInspector: any AntigravityPortOwnershipInspecting
    private let ownershipResolver:
        any AntigravityRuntimeOwnershipResolving
    private let maximumPortInspectionTime: TimeInterval

    init(
        processInspector: any AntigravityRuntimeProcessInspecting,
        portInspector: any AntigravityPortOwnershipInspecting,
        ownershipResolver:
            any AntigravityRuntimeOwnershipResolving =
                AntigravityDefaultRuntimeOwnershipResolver(),
        maximumPortInspectionTime: TimeInterval = 1
    ) {
        self.processInspector = processInspector
        self.portInspector = portInspector
        self.ownershipResolver = ownershipResolver
        self.maximumPortInspectionTime = maximumPortInspectionTime
    }

    func revalidate(
        _ endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline
    ) async throws {
        do {
            try deadline.check(.request)
            guard await processInspector.revalidate(
                    endpoint.processIdentity
                  ),
                  await ownershipResolver.ownership(
                      for: endpoint.processIdentity
                  ) == endpoint.ownership,
                  endpoint.ownership != .quarantined else {
                throw AntigravityLocalRPCError.endpointOwnershipChanged
            }

            let timeout = try deadline.timeInterval(
                for: .request,
                maximum: maximumPortInspectionTime
            )
            let endpoints = try await portInspector.listeningEndpoints(
                ownedBy: [endpoint.processIdentity.processID],
                timeout: timeout
            )
            let selected = AntigravityOwnedListeningEndpoint(
                host: endpoint.host,
                port: endpoint.port
            )
            guard endpoints[endpoint.processIdentity.processID]?.contains(
                selected
            ) == true,
                  await processInspector.revalidate(
                      endpoint.processIdentity
                  ),
                  await ownershipResolver.ownership(
                      for: endpoint.processIdentity
                  ) == endpoint.ownership,
                  endpoint.ownership != .quarantined
            else {
                throw AntigravityLocalRPCError.endpointOwnershipChanged
            }
        } catch is CancellationError {
            throw AntigravityLocalRPCError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityLocalRPCError.deadlineExceeded
        } catch let error as AntigravityLocalRPCError {
            throw error
        } catch {
            // Helper failures cannot weaken the endpoint proof. They fail
            // closed without exposing helper output or process arguments.
            throw AntigravityLocalRPCError.endpointOwnershipChanged
        }
    }
}

nonisolated enum AntigravityLocalRPCRequestBuilder {
    static func request(
        for method: AntigravityLocalRPCMethod,
        endpoint: AntigravityVerifiedRuntimeEndpoint,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard endpoint.host == .ipv4,
              timeout.isFinite,
              timeout > 0
        else {
            throw AntigravityLocalRPCError.invalidEndpoint
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = AntigravityLoopbackHost.ipv4.rawValue
        components.port = Int(endpoint.port.rawValue)
        components.path = method.path
        guard let url = components.url,
              url.scheme == "https",
              url.host == AntigravityLoopbackHost.ipv4.rawValue,
              url.port == Int(endpoint.port.rawValue)
        else {
            throw AntigravityLocalRPCError.invalidEndpoint
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.httpBody = method.requestBody
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "1",
            forHTTPHeaderField: "Connect-Protocol-Version"
        )

        switch endpoint.authentication {
        case .appCSRF(let token):
            request.setValue(
                token.value,
                forHTTPHeaderField: "X-Codeium-Csrf-Token"
            )
        case .cliTokenless:
            break
        }
        return request
    }
}

nonisolated protocol AntigravityLocalRPCConnection: Sendable {
    func perform(
        _ method: AntigravityLocalRPCMethod,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLocalRPCResponse

    func invalidate()
}

nonisolated protocol AntigravityLocalRPCConnectionFactory: Sendable {
    func makeConnection(
        endpoint: AntigravityVerifiedRuntimeEndpoint
    ) throws -> any AntigravityLocalRPCConnection
}

nonisolated final class AntigravityURLSessionRPCConnectionFactory:
    AntigravityLocalRPCConnectionFactory,
    @unchecked Sendable
{
    private let endpointRevalidator: any AntigravityRuntimeEndpointRevalidating
    private let maximumResponseBytes: Int

    init(
        endpointRevalidator: any AntigravityRuntimeEndpointRevalidating,
        maximumResponseBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.endpointRevalidator = endpointRevalidator
        self.maximumResponseBytes = maximumResponseBytes
    }

    func makeConnection(
        endpoint: AntigravityVerifiedRuntimeEndpoint
    ) throws -> any AntigravityLocalRPCConnection {
        guard endpoint.host == .ipv4,
              maximumResponseBytes > 0
        else {
            throw AntigravityLocalRPCError.invalidEndpoint
        }
        return AntigravityURLSessionRPCConnection(
            endpoint: endpoint,
            endpointRevalidator: endpointRevalidator,
            maximumResponseBytes: maximumResponseBytes
        )
    }
}

/// One ephemeral session is created for one quota transaction. Quota and
/// identity requests share that session; it is invalidated when the transaction
/// completes, so credentials, cookies, and certificate pins never persist.
nonisolated final class AntigravityURLSessionRPCConnection:
    AntigravityLocalRPCConnection,
    @unchecked Sendable
{
    private let endpoint: AntigravityVerifiedRuntimeEndpoint
    private let endpointRevalidator: any AntigravityRuntimeEndpointRevalidating
    private let maximumResponseBytes: Int
    private let delegate: AntigravityLocalRPCSessionDelegate
    private let session: URLSession
    private let stateLock = NSLock()
    private var invalidated = false
    private var requestInFlight = false

    init(
        endpoint: AntigravityVerifiedRuntimeEndpoint,
        endpointRevalidator: any AntigravityRuntimeEndpointRevalidating,
        maximumResponseBytes: Int
    ) {
        self.endpoint = endpoint
        self.endpointRevalidator = endpointRevalidator
        self.maximumResponseBytes = maximumResponseBytes

        let delegate = AntigravityLocalRPCSessionDelegate(
            endpoint: endpoint,
            endpointRevalidator: endpointRevalidator
        )
        self.delegate = delegate

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 8
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func perform(
        _ method: AntigravityLocalRPCMethod,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLocalRPCResponse {
        guard beginRequest() else {
            throw AntigravityLocalRPCError.transportFailure
        }
        defer { endRequest() }

        do {
            try await endpointRevalidator.revalidate(
                endpoint,
                deadline: deadline
            )
            let timeout = try deadline.timeInterval(for: .request)
            let request = try AntigravityLocalRPCRequestBuilder.request(
                for: method,
                endpoint: endpoint,
                timeout: timeout
            )
            let dataTask = session.dataTask(with: request)
            let (body, response) = try await delegate.execute(
                dataTask,
                maximumResponseBytes: maximumResponseBytes,
                deadline: deadline
            )

            try await endpointRevalidator.revalidate(
                endpoint,
                deadline: deadline
            )
            let headers = response.allHeaderFields.reduce(
                into: [String: String]()
            ) { result, entry in
                guard let key = entry.key as? String else { return }
                result[key] = String(describing: entry.value)
            }
            return AntigravityLocalRPCResponse(
                statusCode: response.statusCode,
                headers: headers,
                body: body
            )
        } catch is CancellationError {
            throw AntigravityLocalRPCError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityLocalRPCError.deadlineExceeded
        } catch let error as AntigravityLocalRPCError {
            throw error
        } catch {
            throw AntigravityLocalRPCError.transportFailure
        }
    }

    func invalidate() {
        stateLock.lock()
        let shouldInvalidate = !invalidated
        invalidated = true
        stateLock.unlock()

        if shouldInvalidate {
            delegate.cancelAll(with: .cancelled)
            session.invalidateAndCancel()
        }
    }

    private func beginRequest() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !invalidated, !requestInFlight else {
            return false
        }
        requestInFlight = true
        return true
    }

    private func endRequest() {
        stateLock.lock()
        requestInFlight = false
        stateLock.unlock()
    }
}

nonisolated final class AntigravityLocalRPCSessionDelegate:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private struct RequestContext {
        let maximumResponseBytes: Int
        let deadline: AntigravityRPCDeadline
        let continuation:
            CheckedContinuation<(Data, HTTPURLResponse), Error>
        var body = Data()
        var response: HTTPURLResponse?
        var terminalError: AntigravityLocalRPCError?
    }

    private let endpoint: AntigravityVerifiedRuntimeEndpoint
    private let endpointRevalidator: any AntigravityRuntimeEndpointRevalidating
    private let lock = NSLock()
    private var contexts: [Int: RequestContext] = [:]
    private var challengeTasks: [Int: Task<Void, Never>] = [:]
    private var deadlineTasks: [Int: Task<Void, Never>] = [:]
    private var pendingTerminalErrors:
        [Int: AntigravityLocalRPCError] = [:]
    private var completedTaskIdentifiers: Set<Int> = []
    private var terminalSessionError: AntigravityLocalRPCError?
    private var pinnedLeafCertificateDigest: Data?

    init(
        endpoint: AntigravityVerifiedRuntimeEndpoint,
        endpointRevalidator: any AntigravityRuntimeEndpointRevalidating
    ) {
        self.endpoint = endpoint
        self.endpointRevalidator = endpointRevalidator
    }

    func execute(
        _ task: URLSessionDataTask,
        maximumResponseBytes: Int,
        deadline: AntigravityRPCDeadline
    ) async throws -> (Data, HTTPURLResponse) {
        let absoluteTimeout = try deadline.timeout(for: .request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let taskIdentifier = task.taskIdentifier
                lock.lock()
                if let terminalSessionError {
                    lock.unlock()
                    continuation.resume(throwing: terminalSessionError)
                    return
                }
                if let pendingError = pendingTerminalErrors.removeValue(
                    forKey: taskIdentifier
                ) {
                    completedTaskIdentifiers.insert(taskIdentifier)
                    lock.unlock()
                    continuation.resume(throwing: pendingError)
                    return
                }
                guard contexts[taskIdentifier] == nil,
                      !completedTaskIdentifiers.contains(taskIdentifier)
                else {
                    lock.unlock()
                    continuation.resume(
                        throwing: AntigravityLocalRPCError.transportFailure
                    )
                    return
                }
                contexts[taskIdentifier] = RequestContext(
                    maximumResponseBytes: maximumResponseBytes,
                    deadline: deadline,
                    continuation: continuation
                )
                let deadlineTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: absoluteTimeout)
                        self?.cancel(
                            task,
                            with: .deadlineExceeded
                        )
                    } catch {
                        // Completion or caller cancellation won the race.
                    }
                }
                deadlineTasks[taskIdentifier] = deadlineTask
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel(task, with: .cancelled)
        }
    }

    func cancel(
        _ task: URLSessionTask,
        with error: AntigravityLocalRPCError
    ) {
        let challengeTask: Task<Void, Never>?
        let deadlineTask: Task<Void, Never>?
        let taskIdentifier = task.taskIdentifier
        lock.lock()
        if completedTaskIdentifiers.contains(taskIdentifier) {
            challengeTask = nil
            deadlineTask = nil
        } else if contexts[taskIdentifier] != nil {
            if contexts[taskIdentifier]?.terminalError == nil {
                contexts[taskIdentifier]?.terminalError = error
            }
            challengeTask = challengeTasks.removeValue(
                forKey: taskIdentifier
            )
            deadlineTask = deadlineTasks.removeValue(
                forKey: taskIdentifier
            )
        } else {
            if pendingTerminalErrors[taskIdentifier] == nil {
                pendingTerminalErrors[taskIdentifier] = error
            }
            challengeTask = challengeTasks.removeValue(
                forKey: taskIdentifier
            )
            deadlineTask = deadlineTasks.removeValue(
                forKey: taskIdentifier
            )
        }
        lock.unlock()

        challengeTask?.cancel()
        deadlineTask?.cancel()
        // Always cancel the URLSession task, including cancellation that races
        // ahead of context registration.
        task.cancel()
    }

    func cancelAll(with error: AntigravityLocalRPCError) {
        let tasks: [Task<Void, Never>]
        lock.lock()
        if terminalSessionError == nil {
            terminalSessionError = error
        }
        for taskIdentifier in contexts.keys {
            if contexts[taskIdentifier]?.terminalError == nil {
                contexts[taskIdentifier]?.terminalError = error
            }
        }
        tasks = Array(challengeTasks.values)
            + Array(deadlineTasks.values)
        challengeTasks.removeAll()
        deadlineTasks.removeAll()
        pendingTerminalErrors.removeAll()
        lock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            setTerminalError(
                .invalidHTTPResponse,
                forTaskIdentifier: dataTask.taskIdentifier
            )
            completionHandler(.cancel)
            return
        }

        if response.expectedContentLength > 0,
           response.expectedContentLength > Int64(
               maximumResponseBytes(forTaskIdentifier: dataTask.taskIdentifier)
           ) {
            let limit = maximumResponseBytes(
                forTaskIdentifier: dataTask.taskIdentifier
            )
            setTerminalError(
                .responseTooLarge(limit: limit),
                forTaskIdentifier: dataTask.taskIdentifier
            )
            completionHandler(.cancel)
            return
        }

        lock.lock()
        contexts[dataTask.taskIdentifier]?.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard var context = contexts[dataTask.taskIdentifier],
              context.terminalError == nil else {
            lock.unlock()
            return
        }
        guard context.body.count <= context.maximumResponseBytes - data.count else {
            context.terminalError = .responseTooLarge(
                limit: context.maximumResponseBytes
            )
            contexts[dataTask.taskIdentifier] = context
            lock.unlock()
            dataTask.cancel()
            return
        }
        context.body.append(data)
        contexts[dataTask.taskIdentifier] = context
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        setTerminalError(
            .redirectRejected,
            forTaskIdentifier: task.taskIdentifier
        )
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.protocol?.lowercased() == "https",
              challenge.protectionSpace.host
                == AntigravityLoopbackHost.ipv4.rawValue,
              challenge.protectionSpace.port == Int(endpoint.port.rawValue),
              let trust = challenge.protectionSpace.serverTrust,
              let deadline = deadline(
                  forTaskIdentifier: task.taskIdentifier
              )
        else {
            setTerminalError(
                .tlsRejected,
                forTaskIdentifier: task.taskIdentifier
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let challengeTask = Task { [weak self] in
            guard let self else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            defer {
                self.removeChallengeTask(
                    forTaskIdentifier: task.taskIdentifier
                )
            }
            do {
                try await self.endpointRevalidator.revalidate(
                    self.endpoint,
                    deadline: deadline
                )
                guard self.pinLeafCertificate(from: trust) else {
                    throw AntigravityLocalRPCError.tlsRejected
                }
                completionHandler(
                    .useCredential,
                    URLCredential(trust: trust)
                )
            } catch let error as AntigravityLocalRPCError {
                self.setTerminalError(
                    error,
                    forTaskIdentifier: task.taskIdentifier
                )
                completionHandler(.cancelAuthenticationChallenge, nil)
            } catch {
                self.setTerminalError(
                    .tlsRejected,
                    forTaskIdentifier: task.taskIdentifier
                )
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
        replaceChallengeTask(
            challengeTask,
            forTaskIdentifier: task.taskIdentifier
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let taskIdentifier = task.taskIdentifier
        let context = contexts.removeValue(forKey: taskIdentifier)
        completedTaskIdentifiers.insert(taskIdentifier)
        // A task cancelled before execute() registers its continuation can
        // complete first. Keep that pending terminal cause so execute() can
        // still resume with the original cancellation/deadline error instead
        // of degrading it to a generic transport failure.
        if context != nil {
            pendingTerminalErrors.removeValue(forKey: taskIdentifier)
        }
        let challengeTask = challengeTasks.removeValue(
            forKey: taskIdentifier
        )
        let deadlineTask = deadlineTasks.removeValue(
            forKey: taskIdentifier
        )
        lock.unlock()
        challengeTask?.cancel()
        deadlineTask?.cancel()

        guard let context else { return }
        if let terminalError = context.terminalError {
            context.continuation.resume(throwing: terminalError)
            return
        }
        if let urlError = error as? URLError {
            let mapped: AntigravityLocalRPCError
            switch urlError.code {
            case .cancelled:
                mapped = .cancelled
            case .timedOut:
                mapped = .deadlineExceeded
            case .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .secureConnectionFailed:
                mapped = .tlsRejected
            default:
                mapped = .transportFailure
            }
            context.continuation.resume(throwing: mapped)
            return
        }
        if error != nil {
            context.continuation.resume(
                throwing: AntigravityLocalRPCError.transportFailure
            )
            return
        }
        guard let response = context.response else {
            context.continuation.resume(
                throwing: AntigravityLocalRPCError.invalidHTTPResponse
            )
            return
        }
        context.continuation.resume(returning: (context.body, response))
    }

    private func maximumResponseBytes(
        forTaskIdentifier taskIdentifier: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return contexts[taskIdentifier]?.maximumResponseBytes ?? 0
    }

    private func setTerminalError(
        _ error: AntigravityLocalRPCError,
        forTaskIdentifier taskIdentifier: Int
    ) {
        lock.lock()
        if contexts[taskIdentifier]?.terminalError == nil {
            contexts[taskIdentifier]?.terminalError = error
        }
        lock.unlock()
    }

    private func deadline(
        forTaskIdentifier taskIdentifier: Int
    ) -> AntigravityRPCDeadline? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[taskIdentifier]?.deadline
    }

    private func replaceChallengeTask(
        _ task: Task<Void, Never>,
        forTaskIdentifier taskIdentifier: Int
    ) {
        lock.lock()
        guard contexts[taskIdentifier]?.terminalError == nil,
              !completedTaskIdentifiers.contains(taskIdentifier)
        else {
            lock.unlock()
            task.cancel()
            return
        }
        let previous = challengeTasks.updateValue(
            task,
            forKey: taskIdentifier
        )
        lock.unlock()
        previous?.cancel()
    }

    private func removeChallengeTask(
        forTaskIdentifier taskIdentifier: Int
    ) {
        lock.lock()
        challengeTasks.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    private func pinLeafCertificate(from trust: SecTrust) -> Bool {
        guard let certificates = SecTrustCopyCertificateChain(trust)
                as? [SecCertificate],
              let leaf = certificates.first else {
            return false
        }
        let digest = Data(SHA256.hash(
            data: SecCertificateCopyData(leaf) as Data
        ))

        lock.lock()
        defer { lock.unlock() }
        if let pinnedLeafCertificateDigest {
            return pinnedLeafCertificateDigest == digest
        }
        pinnedLeafCertificateDigest = digest
        return true
    }
}
