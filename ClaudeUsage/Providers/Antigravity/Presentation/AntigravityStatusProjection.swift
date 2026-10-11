import Foundation

/// AGY 실패 하나의 제목, 설명, 고치는 방법을 정하는 유일한 표. 팝오버, 설정 안내, 상태 요약이 모두 이 표를 읽는다.
nonisolated struct AntigravityFailurePresentation: Equatable, Sendable {
    enum Remedy: Equatable, Sendable {
        /// 잠시 뒤 다시 시도하면 될 수 있다.
        case retry
        /// 설정에서 설치, 업데이트, 앱 설정을 고쳐야 한다.
        case settings
        /// 터미널에서 AGY CLI 로그인을 확인해야 한다. 상태 요약은 로그인 필요로 보인다.
        case signIn
    }

    let title: String
    let message: String
    let remedy: Remedy

    init(_ failure: AntigravityFailure) {
        switch failure {
        case .runtimeUnavailable(.executableMissing):
            self.init("AGY CLI 설치 필요", "공식 AGY CLI를 설치한 뒤 다시 시도하세요.", .settings)
        case .runtimeUnavailable(.executableChanged):
            self.init("AGY CLI 변경됨", "업데이트가 끝난 뒤 다시 시도하세요.", .retry)
        case .runtimeUnavailable(.verificationRejected):
            self.init("AGY CLI 실행 차단", "공식 서명이나 파일 권한을 확인하지 못했습니다. 공식 AGY CLI 설치 상태를 확인하세요.", .settings)
        case .runtimeUnavailable(.unsupportedVersion):
            self.init(
                "AGY CLI 업데이트 필요",
                "설치된 AGY CLI는 사용량 보고를 지원하지 않습니다. AGY CLI를 \(AntigravityCLIVersion.minimumUsageReport) 이상으로 업데이트하세요.",
                .settings)
        case .runtimeUnavailable(.reportDisabled):
            self.init(
                "AGY 사용량 보고 중지",
                "AGY가 사용량 대신 모델 응답을 실행해 한도가 더 쓰이지 않도록 자동 조회를 멈췄습니다. AGY CLI를 업데이트하거나 앱을 다시 실행하면 다시 조회합니다.",
                .settings)
        case .sourceUnavailable:
            self.init("사용 가능한 조회 경로 없음", "AGY CLI 설치와 로그인을 확인하세요.", .settings)
        case .invalidRefreshContext, .generationExhausted:
            self.init("조회 중 설정 변경", "조회 중 설정이 바뀌었습니다. 다시 시도하세요.", .settings)
        case .sourceContractViolation:
            self.init("보고 확인 실패", "AGY 사용량 보고가 예상한 형식이 아닙니다. 잠시 뒤 다시 시도하세요.", .retry)
        case .deadlineExceeded:
            self.init("조회 시간 초과", "제한 시간 안에 응답이 없었습니다. 잠시 뒤 다시 시도하세요.", .retry)
        case .transportUnavailable:
            self.init("실행 실패", "AGY CLI를 실행하지 못했습니다. 잠시 뒤 다시 시도하세요.", .retry)
        case .schemaChanged:
            self.init("응답 형식 변경", "응답을 읽지 못했습니다. 앱을 업데이트하세요.", .retry)
        case .cancelled:
            self.init("조회 취소됨", "새 조회가 시작돼 이전 조회를 취소했습니다.", .retry)
        case .appShuttingDown:
            self.init("앱 종료 중", "진행 중인 조회를 정리하는 중입니다.", .retry)
        case .cliReportFailed:
            self.init("AGY 사용량 없음", "터미널에서 AGY CLI 로그인을 확인한 뒤 다시 시도하세요.", .signIn)
        }
    }

    private init(_ title: String, _ message: String, _ remedy: Remedy) {
        self.title = title
        self.message = message
        self.remedy = remedy
    }
}

/// AGY 런타임 상태를 팝오버 요약, 경고 표시, 런타임 시도 상태가 같은 뜻으로 읽게 하는 한 곳.
nonisolated struct AntigravityStatusProjection: Equatable, Sendable {
    let phase: LocalProviderSummaryPhase
    let summary: String
    let requiresAction: Bool
    let showsWarning: Bool
    let attemptState: RuntimeProviderAttemptState

    init(snapshot: AntigravityRuntimeSnapshot, isEnabled: Bool = true) {
        let quotaSummary: String = {
            guard case .content(let presentation) = snapshot.quotaPresentation else { return "연결됨" }
            return "\(presentation.observedLaneCount)개 사용량 한도"
        }()
        var phase: LocalProviderSummaryPhase
        var summary: String
        var requiresAction = false
        var showsWarning = false
        var attemptState: RuntimeProviderAttemptState = .idle

        switch snapshot.presentationState {
        case .disabled:
            (phase, summary) = (.probingRuntime, "확인 전")
        case .refreshing:
            (phase, summary) = (.loading, "사용량 확인 중")
            attemptState = .loading
        case .ready:
            (phase, summary) = (.ready, quotaSummary)
        case .partial:
            (phase, summary) = (.ready, "\(quotaSummary) · 일부만 표시")
            showsWarning = true
        case .stale:
            attemptState = .temporaryFailure
            if snapshot.showsPreviousValue {
                (phase, summary) = (.temporaryError, UsageStatusLabel.previousValue)
                showsWarning = true
            } else {
                (phase, summary) = (.ready, quotaSummary)
            }
        case .failed(let failure):
            let presentation = AntigravityFailurePresentation(failure)
            requiresAction = presentation.remedy == .signIn
            (phase, summary) = (requiresAction ? .authRequired : .temporaryError, presentation.title)
            showsWarning = true
            attemptState = .definitiveFailure
        }

        switch snapshot.readiness {
        case .bootstrapping:
            (phase, summary) = (.loading, "확인 중")
            attemptState = .loading
        case .blocked:
            (phase, summary) = (.temporaryError, "설정 오류")
            showsWarning = true
            attemptState = .definitiveFailure
        case .shuttingDown:
            (phase, summary) = (.disabled, "종료 중")
        case .idle, .ready:
            break
        }
        if !isEnabled {
            (phase, summary) = (.disabled, "사용 꺼짐")
            showsWarning = false
        }

        self.phase = phase
        self.summary = summary
        self.requiresAction = requiresAction
        self.showsWarning = showsWarning
        self.attemptState = attemptState
    }
}
