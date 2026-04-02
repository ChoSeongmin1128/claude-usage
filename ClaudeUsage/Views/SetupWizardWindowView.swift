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

    private var visibleChecklistState: [(String, String, Bool)] {
        switch progress.stage {
        case .credential:
            return checklistState.filter { $0.0 == "자격 준비" }
        case .verification:
            return checklistState.filter { $0.0 == "조회 검증" }
        case .organization:
            return checklistState.filter { $0.0 == "Organization 확인" }
        case .complete:
            return checklistState
        }
    }

    private var checklistTitle: String {
        isFullyReady ? "준비 완료" : "남은 확인"
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
            return progress.isAutomaticOrganizationMode ? "완료" : "Organization 확인"
        case .complete:
            return "완료"
        }
    }

    private var secondaryActionTitle: String? {
        switch progress.stage {
        case .credential:
            return nil
        case .verification:
            return nil
        case .organization:
            return progress.isAutomaticOrganizationMode ? nil : "자동 선택으로 완료"
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
            return "먼저 Chrome 가져오기만 시도하면 됩니다. 다른 경로는 이 단계가 실패할 때만 여는 편이 맞습니다."
        case .verification:
            return "자격은 준비됐습니다. 이제 첫 성공 조회만 끝내면 됩니다."
        case .organization:
            if progress.isAutomaticOrganizationMode {
                return "자동 선택 모드입니다. 별도 organization을 고르지 않을 거라면 바로 마무리하시면 됩니다."
            }
            return "\(progress.organizationSummary) 특정 organization을 직접 쓸 때만 확인이 필요합니다."
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

            if progress.stage == .credential {
                SetupWizardView(
                    currentStep: currentStep,
                    hasReadyCredential: progress.hasReadyCredential,
                    isAdvancedExpanded: false,
                    onOpenChrome: onOpenChrome,
                    onOpenWebLogin: onOpenWebLogin,
                    onOpenAdvanced: onOpenAdvancedSettings,
                    onDismiss: onDismiss
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(checklistTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(visibleChecklistState.enumerated()), id: \.offset) { _, item in
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
                        if progress.isAutomaticOrganizationMode {
                            onComplete()
                        } else {
                            onOpenOrganizations()
                        }
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
            return
        case .verification:
            onOpenAdvancedSettings()
        case .organization:
            onComplete()
        case .complete:
            onOpenAdvancedSettings()
        }
    }
}
