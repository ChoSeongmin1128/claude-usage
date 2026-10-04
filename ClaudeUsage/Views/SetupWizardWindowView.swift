import SwiftUI

struct SetupWizardWindowView: View {
    let currentStep: SetupWizardView.Step
    let progress: SetupCompletionPolicy.WizardProgress
    let isVerifyingFetch: Bool
    let onImportFromBrowser: () -> Void
    let onOpenWebLogin: () -> Void
    let onOpenAdvancedSettings: () -> Void
    let onOpenOrganizations: () -> Void
    let onUseAutomaticOrganization: () -> Void
    let onVerifyFetch: () -> Void
    let onComplete: () -> Void
    let onDismiss: () -> Void

    private var visibleChecklistItem: (title: String, detail: String?, isDone: Bool)? {
        switch progress.stage {
        case .credential:
            return ("로그인", nil, progress.hasReadyCredential)
        case .verification:
            return (
                "사용량 확인",
                progress.hasSuccessfulFetch ? "사용량을 확인했습니다" : "사용량을 한 번 조회하세요",
                progress.hasSuccessfulFetch
            )
        case .organization:
            return (
                "조직 확인",
                progress.organizationSummary,
                progress.isOrganizationReady
            )
        case .complete:
            return nil
        }
    }

    private var isFullyReady: Bool {
        progress.stage == .complete
    }

    private var primaryActionTitle: String {
        switch progress.stage {
        case .credential:
            return currentStep.ctaTitle
        case .verification:
            return isVerifyingFetch ? "확인 중" : "사용량 확인"
        case .organization:
            return progress.isAutomaticOrganizationMode ? "자동 선택으로 완료" : "조직 확인"
        case .complete:
            return "완료"
        }
    }

    private var secondaryActionTitle: String? {
        switch progress.stage {
        case .credential:
            return currentStep == .browserImport ? SetupWizardView.Step.webLogin.title : nil
        case .verification:
            return nil
        case .organization:
            return progress.isAutomaticOrganizationMode ? nil : "자동 선택으로 전환"
        case .complete:
            return "설정 열기"
        }
    }

    private var stageSummaryTitle: String {
        switch progress.stage {
        case .credential:
            return "1단계: 로그인"
        case .verification:
            return "2단계: 사용량 확인"
        case .organization:
            return "3단계: 조직 확인"
        case .complete:
            return "설정 완료"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            Text(stageSummaryTitle)
                .font(AppDesign.Typography.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppDesign.Space.content)
                .background(AppDesign.Surface.strongGroup)
                .cornerRadius(AppDesign.Radius.group)

            if progress.stage == .credential {
                SetupWizardView(
                    currentStep: currentStep,
                    isAdvancedExpanded: false,
                    onImportFromBrowser: onImportFromBrowser,
                    onOpenWebLogin: onOpenWebLogin,
                    onOpenAdvanced: onOpenAdvancedSettings
                )
            }

            if let item = visibleChecklistItem {
                VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                    Text("남은 단계")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: AppDesign.Space.row) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.isDone ? .green : .orange)
                            .font(AppDesign.Typography.caption)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                            Text(item.title)
                                .font(AppDesign.Typography.caption)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(AppDesign.Typography.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(AppDesign.Space.label)
                .appPanelStyle()
            }

            HStack {
                if progress.stage == .credential && !progress.hasReadyCredential {
                    Button("직접 입력") {
                        onOpenAdvancedSettings()
                    }
                    .buttonStyle(.bordered)
                }

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
                        } else if currentStep == .browserImport {
                            onImportFromBrowser()
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
        .padding(AppDesign.Space.window)
        .frame(width: AppDesign.Window.setupWidth)
    }

    private func performSecondaryAction() {
        switch progress.stage {
        case .credential:
            if currentStep == .browserImport {
                onOpenWebLogin()
            }
        case .verification:
            onOpenAdvancedSettings()
        case .organization:
            onUseAutomaticOrganization()
        case .complete:
            onOpenAdvancedSettings()
        }
    }
}
