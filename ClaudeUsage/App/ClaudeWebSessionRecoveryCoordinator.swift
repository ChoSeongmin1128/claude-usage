import Foundation

@MainActor
final class ClaudeWebSessionRecoveryCoordinator {
    struct Request: Equatable, Sendable {
        let account: ClaudeAccount
        let expectedIdentity: UsageAccountIdentity?
        let previousAccountID: String
        let activeAccountID: String

        init(account: ClaudeAccount, expectedIdentity: UsageAccountIdentity?, previousAccountID: String,
             activeAccountID: String? = nil) {
            self.account = account
            self.expectedIdentity = expectedIdentity
            self.previousAccountID = previousAccountID
            self.activeAccountID = activeAccountID ?? account.id
        }
    }

    struct Candidate: Sendable {
        let sessionKey: String
        let browserSource: ClaudeBrowserSource?
        let validation: ClaudeValidatedWebSession
    }

    enum Failure: Error, LocalizedError {
        case loginRequired
        case differentAccount

        var errorDescription: String? {
            switch self {
            case .loginRequired: "새 웹 로그인을 찾지 못했습니다. 원래 계정으로 로그인한 뒤 다시 연결하세요."
            case .differentAccount: "브라우저의 계정 또는 조직이 기존 연결과 다릅니다. 기존 연결은 유지했습니다. 다른 계정은 계정 추가에서 연결하세요."
            }
        }
    }

    struct Dependencies {
        var load: @Sendable (String) -> String?
        var importSession: @Sendable (ClaudeBrowserSource) throws -> ClaudeBrowserImportOutcome
        var validate: @Sendable (String, String?) async throws -> ClaudeValidatedWebSession
        var selectSource: () async -> ClaudeBrowserSource?
        var confirmIdentity: (UsageAccountIdentity) async -> Bool
        var isCurrent: (Request) -> Bool
        var commit: (Request, Candidate) async throws -> Void
    }

    private let dependencies: Dependencies
    private var task: (id: UUID, request: Request, key: String?, source: ClaudeBrowserSource?, value: Task<Void, Error>)?

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func cancel() { task?.value.cancel(); task = nil }

    func recover(_ request: Request, sessionKey: String? = nil, source: ClaudeBrowserSource? = nil) async throws {
        if let task, !task.value.isCancelled, task.request == request, task.key == sessionKey, task.source == source {
            return try await awaitRecovery(task.value)
        }
        task?.value.cancel()
        let value = Task { try await run(request, sessionKey: sessionKey, source: source) }
        let id = UUID()
        task = (id, request, sessionKey, source, value)
        defer { if task?.id == id { task = nil } }
        try await awaitRecovery(value)
    }

    private func awaitRecovery(_ value: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await value.value
        } onCancel: {
            value.cancel()
        }
    }

    private func run(_ request: Request, sessionKey: String?, source: ClaudeBrowserSource?) async throws {
        try check(request)
        if let sessionKey {
            let candidate = try await validate(sessionKey, source: source, request: request)
            try check(request)
            return try await dependencies.commit(request, candidate)
        }
        let loader = dependencies.load
        let saved = await Task.detached(priority: .utility) { loader(request.account.id) }.value
        try check(request)
        if let saved, ClaudeAccountStore.webSessionAccountID(fingerprint: ClaudeAccountStore.fingerprint(for: saved)) != request.account.id {
            do {
                let candidate = try await validate(saved, source: request.account.browserSource, request: request)
                try check(request)
                return try await dependencies.commit(request, candidate)
            } catch APIError.invalidSessionKey {
                // The refreshed app copy was also revoked. Try only its original browser next.
            }
        }
        let origin: ClaudeBrowserSource
        if let existing = request.account.browserSource { origin = existing }
        else {
            guard request.account.source != .manualInput, request.account.source != .embeddedWebLogin
            else { throw Failure.loginRequired }
            guard let selected = await dependencies.selectSource() else { throw CancellationError() }
            origin = selected
        }
        try check(request)
        let importer = dependencies.importSession
        let outcome = try await Task.detached(priority: .userInitiated) { try importer(origin) }.value
        try check(request)
        let imported: ClaudeBrowserImportedSession
        switch outcome {
        case .importedSession(let session): imported = session
        case .importedSessionCandidates(let sessions) where sessions.count == 1: imported = sessions[0]
        default: throw Failure.loginRequired
        }
        guard imported.family == origin.family, imported.profileName == origin.profileName,
            ClaudeAccountStore.webSessionAccountID(fingerprint: ClaudeAccountStore.fingerprint(for: imported.sessionKey)) != request.account.id
        else { throw Failure.loginRequired }
        let candidate = try await validate(imported.sessionKey, source: origin, request: request)
        try check(request)
        try await dependencies.commit(request, candidate)
    }

    private func validate(_ key: String, source: ClaudeBrowserSource?, request: Request) async throws -> Candidate {
        let organization = request.expectedIdentity?.organizationID ?? request.account.identity.organizationID
        let validation = try await dependencies.validate(key, organization)
        try check(request)
        guard validation.identity.mergeKey != nil, validation.identity.email != nil else { throw Failure.loginRequired }
        if let organization, validation.identity.organizationID != organization { throw Failure.differentAccount }
        if request.expectedIdentity?.mergeKey != nil, let expected = request.expectedIdentity?.accountID {
            guard validation.identity.accountID == expected else { throw Failure.differentAccount }
        } else {
            guard await dependencies.confirmIdentity(validation.identity) else { throw CancellationError() }
        }
        try check(request)
        return Candidate(sessionKey: key, browserSource: source, validation: validation)
    }

    private func check(_ request: Request) throws {
        try Task.checkCancellation()
        guard dependencies.isCurrent(request) else { throw CancellationError() }
    }
}
