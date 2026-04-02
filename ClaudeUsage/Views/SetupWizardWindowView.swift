import SwiftUI

struct SetupWizardWindowView: View {
    let currentStep: SetupWizardView.Step
    let progress: SetupCompletionPolicy.WizardProgress
    let isVerifyingFetch: Bool
    let onOpenChrome: () -> Void
    let onOpenWebLogin: () -> Void
    let onOpenAdvancedSettings: () -> Void
    let onOpenOrganizations: () -> Void
    let onVerifyFetch: () -> Void
    let onComplete: () -> Void
    let onDismiss: () -> Void

    private var checklistState: [(String, String, Bool)] {
        [
            (
                "자격 준비",
                progress.hasReadyCredential ? "세션키 또는 OAuth 자격을 감지했습니다" : "Chrome 가져오기 또는 웹 로그인부터 진행해야 합니다",
                progress.hasReadyCredential
            ),
            (
                "조회 검증",
                progress.hasSuccessfulFetch ? "최근 성공 조회가 있습니다" : "인증 후 첫 조회를 완료해야 합니다",
                progress.hasSuccessfulFetch
            ),
            (
                "Organization 확인",
                progress.organizationSummary,
                progress.isOrganizationReady
            )
        ]
    }

    private var isFullyReady: Bool {
        progress.stage == .complete
    }

    private var primaryActionTitle: String {
        switch progress.stage {
        case .credential:
            return currentStep.ctaTitle
        case .verification:
            return isVerifyingFetch ? "조회 확인 중" : "지금 조회 검증"
        case .organization:
            return "Organization 열기"
        case .complete:
            return "완료"
        }
    }

    private var secondaryActionTitle: String? {
        switch progress.stage {
        case .credential:
            return "고급 설정"
        case .verification:
            return "설정 열기"
        case .organization:
            return "설정 열기"
        case .complete:
            return "설정 열기"
        }
    }

    private var stageSummaryTitle: String {
        switch progress.stage {
        case .credential:
            return "1단계: 자격 준비"
        case .verification:
            return "2단계: 조회 검증"
        case .organization:
            return "3단계: Organization 확인"
        case .complete:
            return "설정 완료"
        }
    }

    private var stageSummaryDetail: String {
        switch progress.stage {
        case .credential:
            return "Chrome 가져오기나 웹 로그인 중 하나로 Claude 자격을 먼저 확보해야 합니다."
        case .verification:
            return "자격은 준비됐지만 아직 첫 성공 조회가 없습니다. 지금 바로 조회를 실행해 검증하는 편이 맞습니다."
        case .organization:
            return progress.organizationSummary
        case .complete:
            return "Claude 초기 설정이 끝났습니다. 이제 필요할 때 다른 provider를 추가하면 됩니다."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("빠른 시작")
                    .font(.title3.weight(.semibold))
                Text("처음에는 Claude 연결만 안정적으로 끝내면 됩니다. 다른 provider와 세부 설정은 그 뒤에 해도 늦지 않습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stageSummaryTitle)
                    .font(.headline)
                Text(stageSummaryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
            .cornerRadius(8)

            SetupWizardView(
                currentStep: currentStep,
                hasReadyCredential: progress.hasReadyCredential,
                isAdvancedExpanded: false,
                onOpenChrome: onOpenChrome,
                onOpenWebLogin: onOpenWebLogin,
                onOpenAdvanced: onOpenAdvancedSettings,
                onDismiss: onDismiss
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("초기 체크")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(checklistState.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.2 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.2 ? .green : .orange)
                            .font(.caption)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0)
                                .font(.caption)
                            Text(item.1)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            HStack {
                if let secondaryActionTitle {
                    Button(secondaryActionTitle) {
                        performSecondaryAction()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(isFullyReady ? "닫기" : "나중에") {
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button(primaryActionTitle) {
                    switch progress.stage {
                    case .credential:
                        if currentStep == .manualSessionKey {
                            onOpenAdvancedSettings()
                        } else if currentStep == .chromeImport {
                            onOpenChrome()
                        } else {
                            onOpenWebLogin()
                        }
                    case .verification:
                        onVerifyFetch()
                    case .organization:
                        onOpenOrganizations()
                    case .complete:
                        onComplete()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifyingFetch)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func performSecondaryAction() {
        switch progress.stage {
        case .credential:
            onOpenAdvancedSettings()
        case .verification:
            onOpenAdvancedSettings()
        case .organization:
            onOpenAdvancedSettings()
        case .complete:
            onOpenAdvancedSettings()
        }
    }
}
