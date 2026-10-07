import Foundation

nonisolated struct CodexUsageSnapshot: Sendable {
    var usage: CodexUsageResponse
    let credential: CodexCredentialSnapshot
    var revision: Int = 0
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
    private enum Channel: Hashable, Sendable { case usage, resetCredits }
    private struct RequestKey: Hashable, Sendable {
        let generation: UUID
        let channel: Channel
    }
    private struct ResetCreditCache {
        let generation: UUID
        let response: CodexResetCreditsResponse
        let updatedAt: Date
        var needsRetry = false
    }
    private var flights: [RequestKey: Flight] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var ownerRecovery: (id: UUID, task: Task<Void, Error>)?
    private var cachedResetCredits: ResetCreditCache?
    private var usageRevision = 0
    private var lastResetCount: (generation: UUID, count: Int, revision: Int)?
    private static let resetCreditsRefreshInterval: TimeInterval = 300
    private var stopping = false
    private let baseURL: URL
    private let urlSession: URLSession
    private let authManager: CodexAuthManager
    private let owner: any CodexOwnerRefreshing
    private let now: @Sendable () -> Date

    init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        urlSession: URLSession = .shared,
        authManager: CodexAuthManager,
        owner: any CodexOwnerRefreshing = CodexOwnerCLI(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.authManager = authManager
        self.owner = owner
        self.now = now
    }

    func fetchUsage(
        snapshot: CodexCredentialSnapshot? = nil,
        budget: CodexRequestBudget = CodexRequestBudget()
    ) async throws -> CodexUsageSnapshot {
        let credential = try await snapshotOrLoad(snapshot)
        return try await fetch(credential, channel: .usage, budget: budget, base: nil)
    }

    func fetchResetCreditDetails(
        for base: CodexUsageSnapshot, force: Bool = false,
        budget: CodexRequestBudget = CodexRequestBudget(timeout: 10)
    ) async throws -> CodexUsageSnapshot {
        try await authManager.validate(base.credential)
        let started = ContinuousClock.now
        do {
            try budget.check()
            guard !stopping else { throw CancellationError() }
            var base = base
            applyLatestCount(to: &base)
            if base.usage.resetCreditMetadata?.countIsCurrent != false,
                base.usage.resetCredits?.availableCountField == 0
            {
                return base
            }
            if !force, base.usage.resetCreditMetadata?.countIsCurrent != false,
                let cached = usableCache(for: base.usage, credential: base.credential),
                now().timeIntervalSince(cached.updatedAt) < Self.resetCreditsRefreshInterval,
                !cached.needsRetry && cached.response.hasCompleteDetails
            {
                var result = base
                result.usage.resetCredits = cached.response
                result.usage.resetCreditMetadata = .init(status: .cached, updatedAt: cached.updatedAt)
                return result
            }
            let result = try await fetch(base.credential, channel: .resetCredits, budget: budget, base: base)
            try await authManager.validate(base.credential)
            try Task.checkCancellation()
            var merged = base
            merged.usage.resetCredits = result.usage.resetCredits
            merged.usage.resetCreditMetadata = result.usage.resetCreditMetadata
            merged.revision = result.revision
            applyLatestCount(to: &merged)
            return merged
        } catch let error as APIError {
            return try await resetCreditFailure(for: base, error: error, started: started)
        }
    }

    private func snapshotOrLoad(_ snapshot: CodexCredentialSnapshot?) async throws -> CodexCredentialSnapshot {
        guard !stopping else { throw CancellationError() }
        if let snapshot { return snapshot }
        return try await authManager.loadSnapshot()
    }

    private func fetch(
        _ credential: CodexCredentialSnapshot, channel: Channel, budget: CodexRequestBudget,
        base: CodexUsageSnapshot?
    ) async throws -> CodexUsageSnapshot {
        try budget.check()
        try await authManager.validate(credential)
        guard !stopping else { throw CancellationError() }
        let key = RequestKey(generation: credential.generation, channel: channel)
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var flight = flights[key] {
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                } else {
                    let flightID = UUID()
                    let task = Task {
                        let result: Result<CodexUsageSnapshot, Error>
                        do {
                            if let base {
                                result = .success(try await performResetCreditFetch(base, budget: budget))
                            } else {
                                result = .success(try await performFetch(credential, budget: budget))
                            }
                        } catch { result = .failure(error) }
                        finish(key, id: flightID, result: result)
                    }
                    flights[key] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key) }
        }
    }

    private func finish(_ key: RequestKey, id: UUID, result: Result<CodexUsageSnapshot, Error>) {
        retiring.removeValue(forKey: id)
        guard flights[key]?.id == id else { return }
        guard let flight = flights.removeValue(forKey: key) else { return }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancelWaiter(_ id: UUID, key: RequestKey) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            retiring[flight.id] = flight.task
            flight.task.cancel()
        } else {
            flights[key] = flight
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
                    try budget.check()
                    usageRevision += 1
                    let countIsCurrent = usage.resetCredits?.availableCountField != nil
                    if let count = usage.resetCredits?.availableCountField {
                        lastResetCount = (credential.generation, count, usageRevision)
                        if cachedResetCredits?.response.availableCountField != count { cachedResetCredits = nil }
                    } else if let known = lastResetCount, known.generation == credential.generation {
                        usage.resetCredits = CodexResetCreditsResponse(credits: [], availableCountField: known.count)
                    }
                    if let cached = usableCache(for: usage, credential: credential) {
                        usage.resetCredits = cached.response
                        let fresh =
                            now().timeIntervalSince(cached.updatedAt) < Self.resetCreditsRefreshInterval
                            && !cached.needsRetry && cached.response.hasCompleteDetails
                        usage.resetCreditMetadata = .init(
                            status: fresh && countIsCurrent ? .cached : .loading, updatedAt: cached.updatedAt,
                            countIsCurrent: countIsCurrent)
                    } else {
                        usage.resetCreditMetadata = .init(status: .loading, countIsCurrent: countIsCurrent)
                    }
                    return CodexUsageSnapshot(usage: usage, credential: credential, revision: usageRevision)
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
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, budget.remaining)
        request.setValue("Bearer \(credential.token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppIdentifiers.userAgentProduct, forHTTPHeaderField: "User-Agent")
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
                    if (error as? URLError)?.code == .timedOut {
                        throw APIError.codexTokenRefreshTemporary(reason: "request_timed_out")
                    }
                    throw APIError.networkError("codex_connection_failed")
                }
                guard let response = response as? HTTPURLResponse else { throw APIError.parseError }
                guard (200...299).contains(response.statusCode) else {
                    throw CodexHTTPFailure(status: response.statusCode)
                }
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
        let bytes: Data
        do {
            bytes = try await data(
                for: request("wham/usage", credential: credential, budget: budget, timeout: 30), budget: budget)
        } catch let failure as CodexHTTPFailure {
            throw failure.apiError
        }
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
        return usage
    }

    private func usableCache(for usage: CodexUsageResponse, credential: CodexCredentialSnapshot) -> ResetCreditCache? {
        guard let cached = cachedResetCredits, cached.generation == credential.generation else { return nil }
        if let count = usage.resetCredits?.availableCountField, count != cached.response.availableCountField {
            return nil
        }
        return cached
    }

    /// A supplementary response must not replace a count confirmed by a later usage request.
    private func applyLatestCount(to snapshot: inout CodexUsageSnapshot) {
        guard let known = lastResetCount, known.generation == snapshot.credential.generation,
            known.revision > snapshot.revision,
            known.count != snapshot.usage.resetCredits?.availableCountField
        else { return }
        snapshot.usage.resetCredits = CodexResetCreditsResponse(credits: [], availableCountField: known.count)
        snapshot.usage.resetCreditMetadata = .init(status: .partial)
        snapshot.revision = known.revision
    }

    private func performResetCreditFetch(_ base: CodexUsageSnapshot, budget: CodexRequestBudget) async throws
        -> CodexUsageSnapshot
    {
        let started = ContinuousClock.now
        var result = base
        do {
            try await authManager.validate(base.credential)
            let bytes = try await data(
                for: request(
                    "wham/rate-limit-reset-credits", credential: base.credential,
                    budget: budget, timeout: 10), budget: budget)
            let response = try JSONDecoder().decode(CodexResetCreditsResponse.self, from: bytes)
            guard let count = response.availableCountField, count >= 0 else { throw APIError.parseError }
            if let account = response.accountID, account != base.credential.token.accountID {
                throw CodexCredentialError.changed
            }
            try await authManager.validate(base.credential)
            try budget.check()
            let checkedAt = now()
            if let newer = lastResetCount, newer.generation == base.credential.generation,
                newer.revision > base.revision, newer.count != count
            {
                result.usage.resetCredits = CodexResetCreditsResponse(credits: [], availableCountField: newer.count)
                result.usage.resetCreditMetadata = .init(status: .partial)
                result.revision = newer.revision
                OperationalLog.record(.codexResetCredits(.init(status: .partial)), elapsed: started.duration(to: .now))
                return result
            }
            let previousRevision =
                lastResetCount?.generation == base.credential.generation ? lastResetCount?.revision ?? 0 : 0
            let revision = max(base.revision, previousRevision)
            lastResetCount = (base.credential.generation, count, revision)
            cachedResetCredits = ResetCreditCache(
                generation: base.credential.generation, response: response,
                updatedAt: checkedAt)
            result.usage.resetCredits = response
            let metadata = CodexResetCreditMetadata(
                status: response.hasCompleteDetails ? .fresh : .partial, updatedAt: checkedAt)
            result.usage.resetCreditMetadata = metadata
            result.revision = revision
            OperationalLog.record(.codexResetCredits(metadata), elapsed: started.duration(to: .now))
            return result
        } catch is CancellationError { throw CancellationError() } catch CodexCredentialError.changed {
            OperationalLog.record(.codexResetCreditAccountChanged, elapsed: started.duration(to: .now))
            throw CodexCredentialError.changed
        } catch {
            return try await resetCreditFailure(for: base, error: error, started: started)
        }
    }

    private func resetCreditFailure(
        for base: CodexUsageSnapshot, error: Error, started: ContinuousClock.Instant
    ) async throws -> CodexUsageSnapshot {
        var result = base
        do { try await authManager.validate(base.credential) } catch {
            OperationalLog.record(.codexResetCreditAccountChanged, elapsed: started.duration(to: .now))
            throw error
        }
        try Task.checkCancellation()
        let reason = CodexResetCreditFailure.classify(error)
        let cached = usableCache(for: base.usage, credential: base.credential)
        if let cached { result.usage.resetCredits = cached.response; cachedResetCredits?.needsRetry = true }
        let metadata = CodexResetCreditMetadata(
            status: .failed(reason), updatedAt: cached?.updatedAt,
            countIsCurrent: base.usage.resetCreditMetadata?.countIsCurrent ?? true)
        result.usage.resetCreditMetadata = metadata
        applyLatestCount(to: &result)
        OperationalLog.record(.codexResetCredits(metadata), elapsed: started.duration(to: .now))
        return result
    }
}
