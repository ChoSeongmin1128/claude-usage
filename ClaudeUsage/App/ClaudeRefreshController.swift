import Foundation

/// Claude 사용량 조회 한 번의 수명. 요청 귀속(계정, 세션 문맥, 자격 증명 세대)이 그대로인 결과만 화면에 넘긴다.
/// 자격 증명이 바뀌어 결과를 버렸으면 한 번 다시 조회하고, 처음 조회를 기다리는 쪽(연결 확인)이 그 결과까지 기다린다.
@MainActor
final class ClaudeRefreshController {
    struct Inputs {
        let lastOverageAttemptAt: Date?
        let overageOwnerKey: String?
        let knownIdentities: [String: UsageAccountIdentity]
    }

    struct Host {
        let isEnabled: () -> Bool
        let prepare: (_ force: Bool) -> Bool
        let beginRequest: () -> UUID
        let currentRequest: () -> UUID
        /// 성공이나 실패로 끝내지 못한 요청이면 조회 중 표시를 풀고 참을 돌려준다.
        let releaseUnfinishedRequest: (UUID) -> Bool
        let inputs: () -> Inputs
        let applySuccess:
            (_ result: ClaudeRuntimeRefreshSuccess, _ profile: ClaudeProfileMetadata?, _ syncHealth: Bool) -> Void
        let applyFailure: (_ error: APIError, _ metadata: RuntimeProviderFetchMetadata?, _ syncHealth: Bool) -> Void
        let didReleaseRequest: () -> Void
    }

    private let apiService: ClaudeAPIService
    private let host: Host
    private var task: Task<Void, Never>?

    init(apiService: ClaudeAPIService, host: Host) {
        self.apiService = apiService
        self.host = host
    }

    func cancel() {
        task?.cancel()
    }

    @discardableResult
    func refresh(
        force: Bool, syncHealthAfterCompletion: Bool = true, allowWhenDisabled: Bool = false,
        mayRetryCredentialChange: Bool = true
    ) -> Task<Void, Never>? {
        guard allowWhenDisabled || host.isEnabled() else { return nil }
        guard host.prepare(force) else { return nil }

        task?.cancel()
        let revision = host.beginRequest()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(revision: revision, force: force, syncHealth: syncHealthAfterCompletion)
            guard self.host.releaseUnfinishedRequest(revision) else { return }
            self.host.didReleaseRequest()
            guard !Task.isCancelled, mayRetryCredentialChange else { return }
            await self.refresh(
                force: true, syncHealthAfterCompletion: syncHealthAfterCompletion,
                allowWhenDisabled: allowWhenDisabled, mayRetryCredentialChange: false)?.value
        }
        self.task = task
        return task
    }

    private func run(revision: UUID, force: Bool, syncHealth: Bool) async {
        let requestAccountID = await apiService.currentActiveAccountID()
        do {
            Logger.debug("사용량 갱신 시작")
            let inputs = host.inputs()
            let result = try await ClaudeRuntimeRefresher.refresh(
                apiService: apiService, lastOverageAttemptAt: inputs.lastOverageAttemptAt,
                lastOverageOwnerKey: inputs.overageOwnerKey, knownIdentities: inputs.knownIdentities,
                bypassOAuthCache: force)
            let profile = await apiService.fetchCachedProfileMetadata()
            let responseAccountID = await apiService.currentActiveAccountID()
            let responseContextRevision = await apiService.currentSessionContextRevision()
            let responseCredentialGeneration = await apiService.currentClaudeCodeCredentialGeneration()
            guard !Task.isCancelled, host.currentRequest() == revision, requestAccountID == responseAccountID,
                requestAccountID == result.provenance.accountID,
                result.sessionContextRevision == responseContextRevision,
                result.credentialGeneration.map({ $0 == responseCredentialGeneration }) ?? true
            else {
                Logger.info("Claude 계정 귀속이 다른 조회 결과 무시")
                return
            }
            host.applySuccess(result, profile, syncHealth)
        } catch is CancellationError {
            Logger.debug("Claude credential 변경으로 오래된 사용량 응답 폐기")
        } catch {
            guard !Task.isCancelled else {
                Logger.debug("Claude 사용량 갱신 취소")
                return
            }
            let apiError = error as? APIError ?? .unknownError(error.localizedDescription)
            Logger.error("Claude 사용량 갱신 실패: \(apiError.errorDescription ?? "")")
            let responseAccountID = await apiService.currentActiveAccountID()
            let metadata = await apiService.currentFetchMetadataSnapshot()
            guard !Task.isCancelled, host.currentRequest() == revision, requestAccountID == responseAccountID else {
                Logger.info("Claude 계정 전환 중 도착한 이전 조회 실패 무시")
                return
            }
            host.applyFailure(apiError, metadata, syncHealth)
        }
    }
}
