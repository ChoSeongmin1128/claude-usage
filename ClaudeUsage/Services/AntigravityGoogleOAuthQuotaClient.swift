import Foundation

nonisolated struct AntigravityGoogleOAuthHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
    let url: URL
}

nonisolated enum AntigravityGoogleOAuthHTTPTransportError:
    Error,
    Sendable,
    Equatable
{
    case cancelled
    case deadlineExceeded
    case invalidResponse
    case responseTooLarge
    case redirectRejected
    case transportFailure
}

/// The transport boundary receives a complete request and the transaction's
/// original deadline. It has no credential, account, or persistence access.
nonisolated protocol AntigravityGoogleOAuthHTTPTransport: Sendable {
    func response(
        for request: URLRequest,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthHTTPResponse
}

/// A fresh ephemeral URLSession is used for each request. This keeps cookies,
/// caches, URL credentials, and proxy state out of the OAuth quota transaction.
nonisolated final class AntigravityGoogleOAuthURLSessionTransport:
    AntigravityGoogleOAuthHTTPTransport,
    @unchecked Sendable
{
    static let defaultMaximumResponseBytes = 2 * 1_024 * 1_024

    private let maximumResponseBytes: Int

    init(
        maximumResponseBytes: Int =
            AntigravityGoogleOAuthURLSessionTransport
                .defaultMaximumResponseBytes
    ) {
        precondition(maximumResponseBytes > 0)
        self.maximumResponseBytes = maximumResponseBytes
    }

    func response(
        for request: URLRequest,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthHTTPResponse {
        let timeout: TimeInterval
        do {
            timeout = try deadline.timeInterval(for: .request)
        } catch is CancellationError {
            throw AntigravityGoogleOAuthHTTPTransportError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityGoogleOAuthHTTPTransportError
                .deadlineExceeded
        }

        var request = request
        request.timeoutInterval = timeout
        let delegate = AntigravityGoogleOAuthURLSessionDelegate()
        let session = URLSession(
            configuration: Self.configuration(
                resourceTimeout: timeout
            ),
            delegate: delegate,
            delegateQueue: nil
        )
        defer {
            session.invalidateAndCancel()
        }

        let task = session.dataTask(with: request)
        return try await delegate.execute(
            task,
            maximumResponseBytes: maximumResponseBytes,
            deadline: deadline
        )
    }

    static func configuration(
        resourceTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy =
            .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = resourceTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}

nonisolated final class AntigravityGoogleOAuthURLSessionDelegate:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private struct RequestContext {
        let maximumResponseBytes: Int
        let continuation:
            CheckedContinuation<
                AntigravityGoogleOAuthHTTPResponse,
                Error
            >
        var body = Data()
        var response: HTTPURLResponse?
        var terminalError:
            AntigravityGoogleOAuthHTTPTransportError?
    }

    private let lock = NSLock()
    private var contexts: [Int: RequestContext] = [:]
    private var deadlineTasks: [Int: Task<Void, Never>] = [:]
    private var pendingTerminalErrors:
        [Int: AntigravityGoogleOAuthHTTPTransportError] = [:]
    private var completedTaskIdentifiers: Set<Int> = []

    func execute(
        _ task: URLSessionDataTask,
        maximumResponseBytes: Int,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthHTTPResponse {
        let absoluteTimeout = try deadline.timeout(for: .request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
                let identifier = task.taskIdentifier
                lock.lock()
                if let pending =
                        pendingTerminalErrors.removeValue(
                            forKey: identifier
                        )
                {
                    completedTaskIdentifiers.insert(identifier)
                    lock.unlock()
                    continuation.resume(throwing: pending)
                    return
                }
                guard contexts[identifier] == nil,
                      !completedTaskIdentifiers.contains(identifier)
                else {
                    lock.unlock()
                    continuation.resume(
                        throwing:
                            AntigravityGoogleOAuthHTTPTransportError
                                .transportFailure
                    )
                    return
                }
                contexts[identifier] = RequestContext(
                    maximumResponseBytes: maximumResponseBytes,
                    continuation: continuation
                )
                let timeoutTask = Task { [weak self] in
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
                deadlineTasks[identifier] = timeoutTask
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel(task, with: .cancelled)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler:
            @escaping @Sendable (
                URLSession.ResponseDisposition
            ) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            setTerminalError(
                .invalidResponse,
                for: dataTask.taskIdentifier
            )
            completionHandler(.cancel)
            return
        }

        let maximum = maximumResponseBytes(
            for: dataTask.taskIdentifier
        )
        if response.expectedContentLength > 0,
           response.expectedContentLength > Int64(maximum)
        {
            setTerminalError(
                .responseTooLarge,
                for: dataTask.taskIdentifier
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
              context.terminalError == nil
        else {
            lock.unlock()
            return
        }
        guard data.count
                <= context.maximumResponseBytes - context.body.count
        else {
            context.terminalError = .responseTooLarge
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
        completionHandler:
            @escaping @Sendable (URLRequest?) -> Void
    ) {
        setTerminalError(
            .redirectRejected,
            for: task.taskIdentifier
        )
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let identifier = task.taskIdentifier
        let context = contexts.removeValue(forKey: identifier)
        completedTaskIdentifiers.insert(identifier)
        if context != nil {
            pendingTerminalErrors.removeValue(forKey: identifier)
        }
        let deadlineTask = deadlineTasks.removeValue(
            forKey: identifier
        )
        lock.unlock()
        deadlineTask?.cancel()

        guard let context else { return }
        if let terminalError = context.terminalError {
            context.continuation.resume(throwing: terminalError)
            return
        }
        if let urlError = error as? URLError {
            let mapped:
                AntigravityGoogleOAuthHTTPTransportError
            switch urlError.code {
            case .cancelled:
                mapped = .cancelled
            case .timedOut:
                mapped = .deadlineExceeded
            default:
                mapped = .transportFailure
            }
            context.continuation.resume(throwing: mapped)
            return
        }
        if error != nil {
            context.continuation.resume(
                throwing:
                    AntigravityGoogleOAuthHTTPTransportError
                        .transportFailure
            )
            return
        }
        guard let response = context.response,
              let url = response.url
        else {
            context.continuation.resume(
                throwing:
                    AntigravityGoogleOAuthHTTPTransportError
                        .invalidResponse
            )
            return
        }
        context.continuation.resume(
            returning: AntigravityGoogleOAuthHTTPResponse(
                statusCode: response.statusCode,
                body: context.body,
                url: url
            )
        )
    }

    private func cancel(
        _ task: URLSessionTask,
        with error: AntigravityGoogleOAuthHTTPTransportError
    ) {
        let identifier = task.taskIdentifier
        let timeoutTask: Task<Void, Never>?
        lock.lock()
        if completedTaskIdentifiers.contains(identifier) {
            timeoutTask = nil
        } else if contexts[identifier] != nil {
            if contexts[identifier]?.terminalError == nil {
                contexts[identifier]?.terminalError = error
            }
            timeoutTask = deadlineTasks.removeValue(
                forKey: identifier
            )
        } else {
            if pendingTerminalErrors[identifier] == nil {
                pendingTerminalErrors[identifier] = error
            }
            timeoutTask = deadlineTasks.removeValue(
                forKey: identifier
            )
        }
        lock.unlock()
        timeoutTask?.cancel()
        task.cancel()
    }

    private func setTerminalError(
        _ error: AntigravityGoogleOAuthHTTPTransportError,
        for identifier: Int
    ) {
        lock.lock()
        if contexts[identifier]?.terminalError == nil {
            contexts[identifier]?.terminalError = error
        }
        lock.unlock()
    }

    private func maximumResponseBytes(
        for identifier: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return contexts[identifier]?.maximumResponseBytes ?? 0
    }
}

/// Persistence-free Google OAuth quota client. The only secret-bearing input is
/// the credential value passed by the refresh coordinator. Refreshed tokens and
/// discovered project IDs are returned as candidates and are never stored here.
nonisolated struct AntigravityGoogleOAuthQuotaClient:
    AntigravityGoogleOAuthQuotaFetching,
    Sendable
{
    private static let primaryBaseURL =
        URL(string: "https://cloudcode-pa.googleapis.com")!
    private static let dailyBaseURL =
        URL(string: "https://daily-cloudcode-pa.googleapis.com")!
    private static let tokenURL =
        URL(string: "https://oauth2.googleapis.com/token")!
    private static let allowedQuotaHosts: Set<String> = [
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
    ]
    private static let refreshSafetyWindow: TimeInterval = 60

    private let transport:
        any AntigravityGoogleOAuthHTTPTransport
    private let baseURLs: [URL]
    private let oauthTokenURL: URL
    private let now: @Sendable () -> Date

    init(
        transport:
            any AntigravityGoogleOAuthHTTPTransport =
                AntigravityGoogleOAuthURLSessionTransport(),
        baseURLs: [URL] = [
            AntigravityGoogleOAuthQuotaClient.primaryBaseURL,
            AntigravityGoogleOAuthQuotaClient.dailyBaseURL,
        ],
        oauthTokenURL: URL =
            AntigravityGoogleOAuthQuotaClient.tokenURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.baseURLs = baseURLs
        self.oauthTokenURL = oauthTokenURL
        self.now = now
    }

    func fetchQuota(
        credentials: AntigravityOAuthCredentials,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthQuotaResult {
        do {
            try deadline.check(.request)
            var state = CredentialState(
                credentials: credentials
            )
            var didRefresh = false

            if state.accessToken == nil
                || shouldRefresh(
                    expiryDate: state.credentials.expiryDate,
                    now: now()
                )
            {
                try await refresh(
                    state: &state,
                    deadline: deadline
                )
                didRefresh = true
            }

            let endpointResult: EndpointResult
            do {
                endpointResult = try await fetchFromEndpoints(
                    state: state,
                    deadline: deadline
                )
            } catch FlowError.unauthorized {
                guard !didRefresh else {
                    throw AntigravityUsageSourceError
                        .authenticationRequired
                }
                try await refresh(
                    state: &state,
                    deadline: deadline
                )
                didRefresh = true
                do {
                    endpointResult =
                        try await fetchFromEndpoints(
                            state: state,
                            deadline: deadline
                        )
                } catch FlowError.unauthorized {
                    throw AntigravityUsageSourceError
                        .authenticationRequired
                }
            }

            if let projectID = endpointResult.projectID {
                state.recordProjectID(projectID)
            }
            return try result(
                endpointResult: endpointResult,
                state: state,
                fetchedAt: now()
            )
        } catch is CancellationError {
            throw AntigravityUsageSourceError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityUsageSourceError.deadlineExceeded
        } catch let error as
            AntigravityGoogleOAuthHTTPTransportError
        {
            throw Self.map(error)
        } catch let error as AntigravityUsageSourceError {
            throw error
        } catch FlowError.unauthorized {
            throw AntigravityUsageSourceError
                .authenticationRequired
        } catch FlowError.permissionDenied {
            throw AntigravityUsageSourceError.transportFailure
        } catch {
            throw AntigravityUsageSourceError.transportFailure
        }
    }

    private func fetchFromEndpoints(
        state: CredentialState,
        deadline: AntigravityRPCDeadline
    ) async throws -> EndpointResult {
        guard let accessToken = state.accessToken else {
            throw AntigravityUsageSourceError
                .authenticationRequired
        }
        guard !baseURLs.isEmpty else {
            throw AntigravityUsageSourceError.unavailable
        }

        var projectID =
            Self.value(state.credentials.projectID)
        var identityOnlyCandidate: EndpointResult?
        var preferredFailure:
            AntigravityUsageSourceError = .unavailable

        for baseURL in baseURLs {
            do {
                let endpoints = try Self.endpoints(
                    for: baseURL
                )
                let codeAssist: CodeAssistWire =
                    try await sendJSON(
                        endpoint: endpoints.loadCodeAssist,
                        accessToken: accessToken,
                        body: Self.metadataBody,
                        deadline: deadline
                    )
                if let observedProjectID =
                        codeAssist.projectID
                {
                    projectID = observedProjectID
                }
                let count = try await modelQuotaCount(
                    endpoints: endpoints,
                    accessToken: accessToken,
                    projectID: projectID,
                    deadline: deadline
                )
                let endpointResult = EndpointResult(
                    codeAssist: codeAssist,
                    modelQuotaCount: count,
                    projectID: projectID
                )
                if count > 0 {
                    return endpointResult
                }
                if identityOnlyCandidate == nil {
                    identityOnlyCandidate = endpointResult
                }
            } catch FlowError.unauthorized {
                throw FlowError.unauthorized
            } catch is CancellationError {
                throw CancellationError()
            } catch is AntigravityRPCDeadlineError {
                throw AntigravityRPCDeadlineError.timedOut(
                    .request
                )
            } catch let error as
                AntigravityGoogleOAuthHTTPTransportError
            {
                switch error {
                case .cancelled:
                    throw CancellationError()
                case .deadlineExceeded:
                    throw AntigravityRPCDeadlineError.timedOut(
                        .request
                    )
                case .invalidResponse, .responseTooLarge:
                    preferredFailure = .malformedResponse
                case .redirectRejected, .transportFailure:
                    preferredFailure = .transportFailure
                }
            } catch let error as AntigravityUsageSourceError {
                if error == .cancelled
                    || error == .deadlineExceeded
                {
                    throw error
                }
                preferredFailure =
                    AntigravityUsageSourceFailurePolicy.preferred(
                        preferredFailure,
                        error
                    )
            } catch {
                preferredFailure = .transportFailure
            }
        }

        if let identityOnlyCandidate {
            return identityOnlyCandidate
        }
        throw preferredFailure
    }

    private func modelQuotaCount(
        endpoints: EndpointSet,
        accessToken: String,
        projectID: String?,
        deadline: AntigravityRPCDeadline
    ) async throws -> Int {
        do {
            let response: AvailableModelsWire =
                try await sendJSON(
                    endpoint: endpoints.fetchAvailableModels,
                    accessToken: accessToken,
                    body: Self.projectBody(projectID),
                    deadline: deadline
                )
            let count = response.modelQuotaCount
            if count > 0 {
                return count
            }
        } catch FlowError.permissionDenied {
            // This account may expose only the older quota endpoint.
        }

        do {
            let response: RetrieveUserQuotaWire =
                try await sendJSON(
                    endpoint: endpoints.retrieveUserQuota,
                    accessToken: accessToken,
                    body: Self.projectBody(projectID),
                    deadline: deadline
                )
            return response.modelQuotaCount
        } catch FlowError.permissionDenied {
            return 0
        }
    }

    private func refresh(
        state: inout CredentialState,
        deadline: AntigravityRPCDeadline
    ) async throws {
        guard let refreshToken =
                Self.value(state.credentials.refreshToken),
              let clientID =
                Self.value(state.credentials.clientID)
        else {
            throw AntigravityUsageSourceError
                .authenticationRequired
        }
        try Self.validateTokenEndpoint(oauthTokenURL)

        let body = try Self.formBody([
            ("client_id", clientID),
            (
                "client_secret",
                Self.value(state.credentials.clientSecret)
            ),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
        var request = try request(
            endpoint: oauthTokenURL,
            accessToken: nil,
            contentType:
                "application/x-www-form-urlencoded",
            body: body,
            deadline: deadline
        )
        request.setValue(
            "antigravity",
            forHTTPHeaderField: "User-Agent"
        )

        let response = try await perform(
            request,
            deadline: deadline
        )
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 400, 401, 403:
                throw AntigravityUsageSourceError
                    .authenticationRequired
            default:
                throw AntigravityUsageSourceError
                    .transportFailure
            }
        }
        let wire: TokenRefreshWire
        do {
            wire = try JSONDecoder().decode(
                TokenRefreshWire.self,
                from: response.body
            )
        } catch {
            throw AntigravityUsageSourceError
                .malformedResponse
        }
        guard let accessToken = Self.value(wire.accessToken),
              let expiresIn = wire.expiresIn,
              expiresIn.isFinite,
              expiresIn > 0
        else {
            throw AntigravityUsageSourceError
                .malformedResponse
        }
        state.applyRefresh(
            accessToken: accessToken,
            refreshToken: Self.value(wire.refreshToken),
            idToken: Self.value(wire.idToken),
            expiryDate: now().addingTimeInterval(expiresIn)
        )
    }

    private func sendJSON<Response: Decodable>(
        endpoint: URL,
        accessToken: String,
        body: [String: Any],
        deadline: AntigravityRPCDeadline
    ) async throws -> Response {
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys]
            )
        } catch {
            throw AntigravityUsageSourceError
                .malformedResponse
        }
        let request = try request(
            endpoint: endpoint,
            accessToken: accessToken,
            contentType: "application/json",
            body: bodyData,
            deadline: deadline
        )
        let response = try await perform(
            request,
            deadline: deadline
        )
        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(
                    Response.self,
                    from: response.body
                )
            } catch {
                throw AntigravityUsageSourceError
                    .malformedResponse
            }
        case 401:
            throw FlowError.unauthorized
        case 403:
            throw FlowError.permissionDenied
        default:
            throw AntigravityUsageSourceError
                .transportFailure
        }
    }

    private func request(
        endpoint: URL,
        accessToken: String?,
        contentType: String,
        body: Data,
        deadline: AntigravityRPCDeadline
    ) throws -> URLRequest {
        let timeout = try deadline.timeInterval(
            for: .request
        )
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            contentType,
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "antigravity",
            forHTTPHeaderField: "User-Agent"
        )
        if let accessToken {
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthHTTPResponse {
        try deadline.check(.request)
        let response = try await transport.response(
            for: request,
            deadline: deadline
        )
        try deadline.check(.request)
        guard response.url == request.url else {
            throw AntigravityGoogleOAuthHTTPTransportError
                .redirectRejected
        }
        return response
    }

    private func result(
        endpointResult: EndpointResult,
        state: CredentialState,
        fetchedAt: Date
    ) throws -> AntigravityGoogleOAuthQuotaResult {
        let claims = Self.claims(
            from: state.credentials.idToken
        )
        let identity = ProviderAccountIdentity(
            stableAccountID: claims.subject,
            email: claims.email
                ?? Self.value(state.credentials.email)
        )
        guard AntigravityAccountIdentityMatcher.match(
            expected: identity,
            received: identity
        ).isMatch else {
            throw AntigravityUsageSourceError
                .malformedResponse
        }
        let plan = Self.plan(
            from: endpointResult.codeAssist,
            hostedDomain: claims.hostedDomain
        )
        let provenance = AntigravityQuotaProvenance(
            transport: .googleOAuth,
            endpointOwner: .external,
            accountIdentity: identity,
            capability: .limitedQuota,
            processIdentity: nil
        )
        let candidate = state.refreshedCredentialCandidate

        if endpointResult.modelQuotaCount > 0 {
            return .limited(
                .googleOAuth(
                    evidence:
                        AntigravityGoogleOAuthLimitedQuotaEvidence(
                            identity: identity,
                            plan: plan,
                            modelQuotaCount:
                                endpointResult.modelQuotaCount
                        ),
                    provenance: provenance,
                    fetchedAt: fetchedAt
                ),
                refreshedCredential: candidate
            )
        }
        return .identityOnly(
            AntigravityIdentityOnlyUsage(
                identity: identity,
                plan: plan,
                provenance: provenance,
                fetchedAt: fetchedAt
            ),
            refreshedCredential: candidate
        )
    }

    private func shouldRefresh(
        expiryDate: Date?,
        now: Date
    ) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSince(now)
            <= Self.refreshSafetyWindow
    }

    private static func endpoints(
        for baseURL: URL
    ) throws -> EndpointSet {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.port == nil,
              let host = baseURL.host?.lowercased(),
              allowedQuotaHosts.contains(host)
        else {
            throw AntigravityUsageSourceError
                .transportFailure
        }
        return EndpointSet(
            loadCodeAssist: try endpoint(
                host: host,
                path: "/v1internal:loadCodeAssist"
            ),
            fetchAvailableModels: try endpoint(
                host: host,
                path: "/v1internal:fetchAvailableModels"
            ),
            retrieveUserQuota: try endpoint(
                host: host,
                path: "/v1internal:retrieveUserQuota"
            )
        )
    }

    private static func endpoint(
        host: String,
        path: String
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else {
            throw AntigravityUsageSourceError
                .transportFailure
        }
        return url
    }

    private static func validateTokenEndpoint(
        _ url: URL
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased()
                == "oauth2.googleapis.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.path == "/token",
              url.query == nil,
              url.fragment == nil
        else {
            throw AntigravityUsageSourceError
                .transportFailure
        }
    }

    private static func formBody(
        _ values: [(String, String?)]
    ) throws -> Data {
        var components = URLComponents()
        components.queryItems = values.compactMap {
            key,
            value in
            guard let value else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        guard let query = components.percentEncodedQuery else {
            throw AntigravityUsageSourceError
                .malformedResponse
        }
        return Data(query.utf8)
    }

    private static func projectBody(
        _ projectID: String?
    ) -> [String: Any] {
        guard let projectID = value(projectID) else {
            return [:]
        }
        return ["project": projectID]
    }

    private static var metadataBody: [String: Any] {
        [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
    }

    private static func plan(
        from response: CodeAssistWire,
        hostedDomain: String?
    ) -> String? {
        if let plan = value(response.planInfo?.planType) {
            return plan
        }
        switch (
            value(response.currentTier?.id),
            value(hostedDomain)
        ) {
        case ("standard-tier", _):
            return "Paid"
        case ("free-tier", .some):
            return "Workspace"
        case ("free-tier", .none):
            return "Free"
        case ("legacy-tier", _):
            return "Legacy"
        default:
            return value(response.currentTier?.name)
        }
    }

    private static func claims(
        from token: String?
    ) -> IdentityClaims {
        guard let token = value(token) else {
            return IdentityClaims()
        }
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3,
              !parts[1].isEmpty
        else {
            return IdentityClaims()
        }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(
                repeating: "=",
                count: 4 - remainder
            )
        }
        guard let data = Data(base64Encoded: payload),
              let wire = try? JSONDecoder().decode(
                  IdentityClaimsWire.self,
                  from: data
              )
        else {
            return IdentityClaims()
        }
        return IdentityClaims(
            subject: value(wire.subject),
            email: value(wire.email),
            hostedDomain: value(wire.hostedDomain)
        )
    }

    private static func value(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func map(
        _ error: AntigravityGoogleOAuthHTTPTransportError
    ) -> AntigravityUsageSourceError {
        switch error {
        case .cancelled:
            .cancelled
        case .deadlineExceeded:
            .deadlineExceeded
        case .invalidResponse, .responseTooLarge:
            .malformedResponse
        case .redirectRejected, .transportFailure:
            .transportFailure
        }
    }
}

private nonisolated extension AntigravityGoogleOAuthQuotaClient {
    enum FlowError: Error {
        case unauthorized
        case permissionDenied
    }

    struct EndpointSet {
        let loadCodeAssist: URL
        let fetchAvailableModels: URL
        let retrieveUserQuota: URL
    }

    struct EndpointResult {
        let codeAssist: CodeAssistWire
        let modelQuotaCount: Int
        let projectID: String?
    }

    struct CredentialState {
        var credentials: AntigravityOAuthCredentials
        private var didRefresh = false
        private var refreshedAccessToken: String?
        private var refreshedRefreshToken: String?
        private var refreshedExpiryDate: Date?
        private var refreshedIDToken: String?
        private var discoveredProjectID: String?

        init(credentials: AntigravityOAuthCredentials) {
            self.credentials = credentials
        }

        var accessToken: String? {
            AntigravityGoogleOAuthQuotaClient.value(
                credentials.accessToken
            )
        }

        mutating func applyRefresh(
            accessToken: String,
            refreshToken: String?,
            idToken: String?,
            expiryDate: Date
        ) {
            didRefresh = true
            refreshedAccessToken = accessToken
            refreshedRefreshToken = refreshToken
            refreshedExpiryDate = expiryDate
            refreshedIDToken = idToken

            credentials.accessToken = accessToken
            if let refreshToken {
                credentials.refreshToken = refreshToken
            }
            credentials.expiryDateMilliseconds =
                expiryDate.timeIntervalSince1970 * 1_000
            if let idToken {
                credentials.idToken = idToken
            }
        }

        mutating func recordProjectID(_ projectID: String) {
            let normalized =
                AntigravityGoogleOAuthQuotaClient.value(projectID)
            guard normalized !=
                    AntigravityGoogleOAuthQuotaClient.value(
                        credentials.projectID
                    )
            else {
                return
            }
            discoveredProjectID = normalized
            credentials.projectID = normalized
        }

        var refreshedCredentialCandidate:
            AntigravityOAuthCredentials?
        {
            guard didRefresh || discoveredProjectID != nil,
                  let accessToken
            else {
                return nil
            }
            return AntigravityOAuthCredentials(
                accessToken:
                    refreshedAccessToken ?? accessToken,
                refreshToken: refreshedRefreshToken,
                expiryDate: refreshedExpiryDate,
                idToken: refreshedIDToken,
                email: nil,
                projectID: discoveredProjectID,
                clientID: nil,
                clientSecret: nil
            )
        }
    }

    struct IdentityClaims {
        let subject: String?
        let email: String?
        let hostedDomain: String?

        init(
            subject: String? = nil,
            email: String? = nil,
            hostedDomain: String? = nil
        ) {
            self.subject = subject
            self.email = email
            self.hostedDomain = hostedDomain
        }
    }

    struct IdentityClaimsWire: Decodable {
        let subject: String?
        let email: String?
        let hostedDomain: String?

        enum CodingKeys: String, CodingKey {
            case subject = "sub"
            case email
            case hostedDomain = "hd"
        }
    }

    struct TokenRefreshWire: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    struct CodeAssistWire: Decodable {
        let planInfo: PlanInfoWire?
        let currentTier: TierWire?
        let cloudaicompanionProject: ProjectReferenceWire?

        var projectID: String? {
            AntigravityGoogleOAuthQuotaClient.value(
                cloudaicompanionProject?.value
            )
        }
    }

    struct PlanInfoWire: Decodable {
        let planType: String?
    }

    struct TierWire: Decodable {
        let id: String?
        let name: String?
    }

    struct ProjectReferenceWire: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(String.self) {
                self.value = value
                return
            }
            let keyed = try decoder.container(
                keyedBy: CodingKeys.self
            )
            value =
                try keyed.decodeIfPresent(
                    String.self,
                    forKey: .projectID
                )
                ?? keyed.decodeIfPresent(
                    String.self,
                    forKey: .id
                )
        }

        enum CodingKeys: String, CodingKey {
            case projectID = "projectId"
            case id
        }
    }

    struct AvailableModelsWire: Decodable {
        let models: [String: AvailableModelWire]?

        var modelQuotaCount: Int {
            Set<String>(
                (models ?? [:]).compactMap {
                    modelID,
                    model in
                    guard model.quotaInfo != nil else {
                        return nil
                    }
                    return AntigravityGoogleOAuthQuotaClient
                        .value(modelID)
                }
            ).count
        }
    }

    struct AvailableModelWire: Decodable {
        let quotaInfo: QuotaInfoWire?
    }

    struct QuotaInfoWire: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    struct RetrieveUserQuotaWire: Decodable {
        let buckets: [QuotaBucketWire]?

        var modelQuotaCount: Int {
            Set<String>(
                (buckets ?? []).compactMap {
                    AntigravityGoogleOAuthQuotaClient
                        .value($0.modelID)
                }
            ).count
        }
    }

    struct QuotaBucketWire: Decodable {
        let modelID: String?

        enum CodingKeys: String, CodingKey {
            case modelID = "modelId"
        }
    }
}
