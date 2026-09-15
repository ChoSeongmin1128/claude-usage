import Foundation

/// Owns the UI transaction separately from the shared network request. A login
/// change invalidates both stale successes and failures before presentation.
@MainActor
final class CodexRefreshController {
    private let authManager: CodexAuthManager
    private let apiService: CodexAPIService
    private let isEnabled: () -> Bool
    private let prepare: (Bool) -> Bool
    private let clearPresentation: () -> Void
    private let applySuccess: (CodexUsageSnapshot) -> Void
    private let applyFailure: (APIError) -> Void
    private var preparation: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var preparationID: UUID?
    private var requestID: UUID?
    private var credentialGeneration: UUID?

    init(
        authManager: CodexAuthManager, apiService: CodexAPIService,
        isEnabled: @escaping () -> Bool, prepare: @escaping (Bool) -> Bool,
        clearPresentation: @escaping () -> Void,
        applySuccess: @escaping (CodexUsageSnapshot) -> Void,
        applyFailure: @escaping (APIError) -> Void
    ) {
        self.authManager = authManager
        self.apiService = apiService
        self.isEnabled = isEnabled
        self.prepare = prepare
        self.clearPresentation = clearPresentation
        self.applySuccess = applySuccess
        self.applyFailure = applyFailure
    }

    func refresh(force: Bool, budget: CodexRequestBudget = CodexRequestBudget(), mayRetryCredentialChange: Bool = true)
    {
        guard isEnabled() else { return }
        preparation?.cancel()
        let id = UUID()
        preparationID = id
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await authManager.loadSnapshot()
                try budget.check()
                guard preparationID == id, isEnabled() else { return }
                let changed = credentialGeneration != credential.generation
                if changed {
                    request?.cancel()
                    requestID = nil
                    credentialGeneration = credential.generation
                    clearPresentation()
                }
                guard prepare(force || changed) else { return }
                start(credential, budget: budget, mayRetryCredentialChange: mayRetryCredentialChange)
            } catch is CancellationError {
                return
            } catch {
                guard preparationID == id, isEnabled() else { return }
                request?.cancel()
                requestID = nil
                credentialGeneration = nil
                clearPresentation()
                applyFailure((error as? APIError) ?? .codexReauthRequired(reason: "credential_unavailable"))
            }
        }
    }

    private func start(
        _ credential: CodexCredentialSnapshot, budget: CodexRequestBudget, mayRetryCredentialChange: Bool
    ) {
        let id = UUID()
        requestID = id
        request = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == id { requestID = nil; request = nil }
            }
            do {
                let result = try await CodexRuntimeRefresher.refresh(
                    apiService: apiService, credential: credential, budget: budget
                )
                try await authManager.validate(result.credential)
                try Task.checkCancellation()
                guard requestID == id, isEnabled() else { return }
                credentialGeneration = result.credential.generation
                applySuccess(result)
            } catch is CancellationError {
                return
            } catch let failure as CodexUsageFailure {
                guard requestID == id, isEnabled() else { return }
                let current = try? await authManager.loadSnapshot()
                guard requestID == id, !Task.isCancelled, isEnabled() else { return }
                if current?.generation == failure.generation {
                    credentialGeneration = failure.generation
                    applyFailure(failure.error)
                } else {
                    retryChangedCredential(budget: budget, allowed: mayRetryCredentialChange)
                }
            } catch {
                guard requestID == id, !Task.isCancelled, isEnabled() else { return }
                retryChangedCredential(budget: budget, allowed: mayRetryCredentialChange)
            }
        }
    }

    private func retryChangedCredential(budget: CodexRequestBudget, allowed: Bool) {
        credentialGeneration = nil
        clearPresentation()
        if allowed, budget.remaining > 0 {
            refresh(force: true, budget: budget, mayRetryCredentialChange: false)
        } else {
            applyFailure(.codexTokenRefreshTemporary(reason: "credential_changed"))
        }
    }

    func cancel() {
        preparationID = nil
        requestID = nil
        preparation?.cancel()
        request?.cancel()
        preparation = nil
        request = nil
        credentialGeneration = nil
    }

    func shutdown() async {
        cancel()
        await apiService.shutdown()
    }
}
