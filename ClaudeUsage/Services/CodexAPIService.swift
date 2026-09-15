import Foundation

nonisolated struct CodexUsageSnapshot: Sendable {
    let usage: CodexUsageResponse
    let credential: CodexCredentialSnapshot
}

nonisolated struct CodexUsageFailure: Error, Sendable, CustomStringConvertible {
    let error: APIError
    let generation: UUID
    var description: String { "Codex usage request failed" }
}

/// All requests in one transaction use one credential snapshot. Only the CLI
/// may rotate native credentials, and every result is checked against the file.
actor CodexAPIService {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CodexUsageSnapshot, Error>]
    }
    private var flights: [UUID: Flight] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var ownerRecovery: (id: UUID, task: Task<Void, Error>)?
    private var stopping = false
    private let baseURL: URL
    private let urlSession: URLSession
    private let authManager: CodexAuthManager
    private let owner: any CodexOwnerRefreshing

    init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        urlSession: URLSession = .shared,
        authManager: CodexAuthManager,
        owner: any CodexOwnerRefreshing = CodexOwnerCLI()
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.authManager = authManager
        self.owner = owner
    }

    func fetchUsage(
        snapshot: CodexCredentialSnapshot? = nil,
        budget: CodexRequestBudget = CodexRequestBudget()
    ) async throws -> CodexUsageSnapshot {
        guard !stopping else { throw CancellationError() }
        let credential: CodexCredentialSnapshot
        if let snapshot { credential = snapshot } else { credential = try await authManager.loadSnapshot() }
        try budget.check()
        try await authManager.validate(credential)
        guard !stopping else { throw CancellationError() }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var flight = flights[credential.generation] {
                    flight.waiters[waiterID] = continuation
                    flights[credential.generation] = flight
                } else {
                    let flightID = UUID()
                    let task = Task {
                        let result: Result<CodexUsageSnapshot, Error>
                        do { result = .success(try await performFetch(credential, budget: budget)) } catch {
                            result = .failure(error)
                        }
                        finish(credential.generation, id: flightID, result: result)
                    }
                    flights[credential.generation] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, generation: credential.generation) }
        }
    }

    private func finish(_ generation: UUID, id: UUID, result: Result<CodexUsageSnapshot, Error>) {
        retiring.removeValue(forKey: id)
        guard flights[generation]?.id == id else { return }
        guard let flight = flights.removeValue(forKey: generation) else { return }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancelWaiter(_ id: UUID, generation: UUID) {
        guard var flight = flights[generation], let waiter = flight.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: generation)
            retiring[flight.id] = flight.task
            flight.task.cancel()
        } else {
            flights[generation] = flight
        }
    }

    func shutdown() async {
        stopping = true
        let pending = Array(flights.values)
        let retiringTasks = Array(retiring.values)
        flights.removeAll()
        retiring.removeAll()
        for flight in pending {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        for task in retiringTasks { task.cancel() }
        for flight in pending { await flight.task.value }
        for task in retiringTasks { await task.value }
    }

    private func performFetch(_ initial: CodexCredentialSnapshot, budget: CodexRequestBudget) async throws
        -> CodexUsageSnapshot
    {
        var credential = initial
        var recovered = false
        var attempt = 0
        do {
            if credential.token.isExpired {
                recovered = true
                credential = try await recover(credential, budget: budget)
            }
            while true {
                try budget.check()
                do {
                    var usage = try await usageRequest(credential, budget: budget)
                    try await authManager.validate(credential)
                    do {
                        usage.resetCredits = try await resetCreditsRequest(credential, budget: budget)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Optional enrichment has the same credential and shared deadline.
                        // Neither raw responses nor server error strings are logged.
                    }
                    try budget.check()
                    try await authManager.validate(credential)
                    return CodexUsageSnapshot(usage: usage, credential: credential)
                } catch APIError.invalidSessionKey {
                    guard !recovered else {
                        throw APIError.codexReauthRequired(reason: "usage_unauthorized_after_recovery")
                    }
                    recovered = true
                    credential = try await recover(credential, budget: budget)
                } catch let error as APIError where error.isTemporaryFailure {
                    attempt += 1
                    guard attempt < 3 else { throw error }
                    let delay = pow(2.0, Double(attempt - 1))
                    guard budget.remaining > delay else {
                        throw APIError.codexTokenRefreshTemporary(reason: "request_timed_out")
                    }
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexCredentialError {
            throw error
        } catch {
            try await authManager.validate(credential)
            let apiError = (error as? APIError) ?? .networkError("codex_request_failed")
            throw CodexUsageFailure(error: apiError, generation: credential.generation)
        }
    }

    private func recover(_ previous: CodexCredentialSnapshot, budget: CodexRequestBudget) async throws
        -> CodexCredentialSnapshot
    {
        try budget.check()
        let current = try await authManager.loadSnapshot()
        guard current.generation == previous.generation else { throw CodexCredentialError.changed }
        guard let accountID = current.token.accountID, !accountID.isEmpty else {
            throw APIError.codexReauthRequired(reason: "account_identity_unavailable")
        }
        do {
            try await refreshWithOwner(current, accountID: accountID, budget: budget)
        } catch is CancellationError {
            throw CancellationError()
        } catch CodexOwnerError.accountMismatch {
            throw CodexCredentialError.changed
        } catch CodexOwnerError.unavailable {
            throw APIError.codexReauthRequired(reason: "owner_cli_unavailable")
        } catch CodexOwnerError.rejected {
            throw APIError.codexReauthRequired(reason: "owner_login_required")
        } catch let error as CodexCredentialError {
            throw error
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.codexTokenRefreshTemporary(reason: "owner_refresh_failed")
        }
        try budget.check()
        let refreshed = try await authManager.loadSnapshot()
        guard refreshed.token.accountID == accountID else { throw CodexCredentialError.changed }
        return refreshed
    }

    private func refreshWithOwner(_ credential: CodexCredentialSnapshot, accountID: String, budget: CodexRequestBudget)
        async throws
    {
        while true {
            try budget.check()
            guard !stopping else { throw CancellationError() }
            if let pending = ownerRecovery {
                _ = await pending.task.result
                if ownerRecovery?.id == pending.id { ownerRecovery = nil }
                continue
            }
            try await authManager.validate(credential)
            try budget.check()
            guard ownerRecovery == nil else { continue }
            guard budget.reserveOwnerRecovery() else {
                throw APIError.codexTokenRefreshTemporary(reason: "owner_recovery_exhausted")
            }
            let id = UUID()
            let task = Task { [owner] in
                try await owner.refresh(sourceURL: credential.sourceURL, expectedAccountID: accountID, budget: budget)
            }
            ownerRecovery = (id, task)
            defer { if ownerRecovery?.id == id { ownerRecovery = nil } }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return
        }
    }

    private func request(
        _ path: String, credential: CodexCredentialSnapshot, budget: CodexRequestBudget, timeout: TimeInterval
    ) throws -> URLRequest {
        try budget.check()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, budget.remaining)
        request.setValue("Bearer \(credential.token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ClaudeUsage", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credential.token.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    private func data(for request: URLRequest, budget: CodexRequestBudget) async throws -> Data {
        try budget.check()
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [urlSession] in
                let data: Data
                let response: URLResponse
                do { (data, response) = try await urlSession.data(for: request) } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    throw APIError.networkError("codex_connection_failed")
                }
                guard let response = response as? HTTPURLResponse else { throw APIError.parseError }
                if response.statusCode == 401 || response.statusCode == 403 { throw APIError.invalidSessionKey }
                guard (200...299).contains(response.statusCode) else { throw APIError.serverError(response.statusCode) }
                guard data.count <= 2_097_152 else { throw APIError.parseError }
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(min(request.timeoutInterval, budget.remaining)))
                throw APIError.codexTokenRefreshTemporary(reason: "request_timed_out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func usageRequest(_ credential: CodexCredentialSnapshot, budget: CodexRequestBudget) async throws
        -> CodexUsageResponse
    {
        let bytes = try await data(
            for: request("wham/usage", credential: credential, budget: budget, timeout: 30), budget: budget)
        let usage: CodexUsageResponse
        do { usage = try JSONDecoder().decode(CodexUsageResponse.self, from: bytes) } catch {
            throw APIError.parseError
        }
        if let responseAccount = usage.accountID, let requestedAccount = credential.token.accountID,
            responseAccount != requestedAccount
        {
            throw CodexCredentialError.changed
        }
        guard let accountID = usage.accountID ?? credential.token.accountID, !accountID.isEmpty else {
            throw APIError.codexReauthRequired(reason: "account_identity_unavailable")
        }
        guard usage.rateLimit?.primaryWindow != nil || usage.rateLimit?.secondaryWindow != nil else {
            throw APIError.parseError
        }
        return usage
    }

    private func resetCreditsRequest(_ credential: CodexCredentialSnapshot, budget: CodexRequestBudget) async throws
        -> CodexResetCreditsResponse
    {
        var request = try request("wham/rate-limit-reset-credits", credential: credential, budget: budget, timeout: 5)
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        let bytes = try await data(for: request, budget: budget)
        do { return try JSONDecoder().decode(CodexResetCreditsResponse.self, from: bytes) } catch {
            throw APIError.parseError
        }
    }
}
