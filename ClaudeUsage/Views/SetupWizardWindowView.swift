import SwiftUI

struct SetupWizardWindowView: View {
    let currentStep: SetupWizardView.Step
    let hasReadyCredential: Bool
    let hasSuccessfulFetch: Bool
    let organizationSummary: String
    let onOpenChrome: () -> Void
    let onOpenWebLogin: () -> Void
    let onOpenAdvancedSettings: () -> Void
    let onDismiss: () -> Void

    private var checklistState: [(String, String, Bool)] {
        [
            (
                "자격 준비",
                hasReadyCredential ? "세션키 또는 OAuth 자격을 감지했습니다" : "Chrome 가져오기 또는 웹 로그인부터 진행해야 합니다",
                hasReadyCredential
            ),
            (
                "조회 검증",
                hasSuccessfulFetch ? "최근 성공 조회가 있습니다" : "인증 후 첫 조회를 완료해야 합니다",
                hasSuccessfulFetch
            ),
            (
                "Organization 확인",
                organizationSummary,
                !organizationSummary.contains("없습니다")
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("빠른 시작")
                    .font(.title3.weight(.semibold))
                Text("Claude 중심 menubar 앱이므로, 먼저 Claude 자격을 안정적으로 확보한 뒤 설정과 provider 확장을 진행하는 편이 맞습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SetupWizardView(
                currentStep: currentStep,
                hasReadyCredential: hasReadyCredential,
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
                Button("설정 열기") {
                    onOpenAdvancedSettings()
                }
                .buttonStyle(.bordered)

                Spacer()

                if hasReadyCredential {
                    Button("나중에") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Button(currentStep.ctaTitle) {
                    if currentStep == .manualSessionKey {
                        onOpenAdvancedSettings()
                    } else if currentStep == .chromeImport {
                        onOpenChrome()
                    } else {
                        onOpenWebLogin()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
