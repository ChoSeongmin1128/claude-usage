import SwiftUI

struct SetupWizardView: View {
    @State private var isAlternativeMethodsExpanded = false

    enum Step: Int, CaseIterable, Identifiable {
        case chromeImport
        case webLogin
        case manualSessionKey

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .chromeImport:
                return "Chrome 가져오기"
            case .webLogin:
                return "웹 로그인 추출"
            case .manualSessionKey:
                return "수동 sessionKey"
            }
        }

        var detail: String {
            switch self {
            case .chromeImport:
                return "권장 경로입니다. Chrome 로그인 상태에서 sessionKey를 먼저 읽어옵니다."
            case .webLogin:
                return "Chrome 가져오기가 안 되면 내장 로그인 창에서 sessionKey 자동 추출을 시도합니다."
            case .manualSessionKey:
                return "둘 다 실패했을 때만 고급 설정에서 값만 직접 입력합니다."
            }
        }

        var ctaTitle: String {
            switch self {
            case .chromeImport, .webLogin:
                return self == .chromeImport ? "Chrome 열기" : "웹 로그인 열기"
            case .manualSessionKey:
                return "고급 열기"
            }
        }
    }

    let currentStep: Step
    let hasReadyCredential: Bool
    let isAdvancedExpanded: Bool
    let onOpenChrome: () -> Void
    let onOpenWebLogin: () -> Void
    let onOpenAdvanced: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("빠른 시작")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasReadyCredential {
                    Text("준비됨")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .cornerRadius(5)
                } else {
                    Text("단계형 안내")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                ForEach(Step.allCases) { step in
                    Capsule()
                        .fill(color(for: step))
                        .frame(height: 5)
                }
            }

            primaryStepCard

            if !alternativeSteps.isEmpty {
                DisclosureGroup(isExpanded: $isAlternativeMethodsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(alternativeSteps) { step in
                            alternativeStepRow(step)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("다른 인증 방법")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasReadyCredential {
                Text("자격 준비는 끝났습니다. 이제 상태 새로고침이나 첫 성공 조회 확인으로 다음 단계로 넘어가면 됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !isAdvancedExpanded {
                Text("수동 sessionKey는 마지막 수단입니다. 먼저 권장 경로를 끝내는 편이 맞습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var primaryStepTitle: String {
        hasReadyCredential ? "자격 준비 완료" : currentStep.title
    }

    private var primaryStepDetail: String {
        hasReadyCredential
            ? "sessionKey 또는 OAuth 자격이 이미 준비되어 있습니다. 이제 첫 성공 조회와 organization 확인만 남았습니다."
            : currentStep.detail
    }

    private var alternativeSteps: [Step] {
        Step.allCases.filter { $0 != currentStep }
    }

    private var primaryStepCard: some View {
        let state = state(for: currentStep)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.iconName)
                .foregroundStyle(state.color)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(primaryStepTitle)
                        .font(.caption.weight(.semibold))
                    if !hasReadyCredential {
                        Text("권장")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(4)
                    }
                }
                Text(primaryStepDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !hasReadyCredential {
                    Text(actionHint(for: currentStep))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private func alternativeStepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption)
                Text(step.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(step.buttonTitle) {
                perform(step)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func color(for step: Step) -> Color {
        let state = state(for: step)
        if step == currentStep && !hasReadyCredential {
            return .accentColor
        }
        return state.color.opacity(0.9)
    }

    private func state(for step: Step) -> (iconName: String, color: Color) {
        if hasReadyCredential {
            return ("checkmark.circle.fill", .green)
        }
        switch step {
        case .chromeImport:
            return step == currentStep ? ("arrow.right.circle.fill", .accentColor) : ("circle", .secondary)
        case .webLogin:
            return step == currentStep ? ("arrow.right.circle.fill", .accentColor) : ("circle", .secondary)
        case .manualSessionKey:
            if isAdvancedExpanded {
                return ("checkmark.circle.fill", .green)
            }
            return step == currentStep ? ("arrow.right.circle.fill", .accentColor) : ("circle", .secondary)
        }
    }

    private func perform(_ step: Step) {
        switch step {
        case .chromeImport:
            onOpenChrome()
        case .webLogin:
            onOpenWebLogin()
        case .manualSessionKey:
            onOpenAdvanced()
        }
    }

    private func actionHint(for step: Step) -> String {
        switch step {
        case .chromeImport:
            return "Chrome을 켜고 claude.ai 로그인 상태를 맞춘 뒤 다시 가져오면 됩니다."
        case .webLogin:
            return "내장 로그인 창이 열리면 인증 후 자동 추출이 끝날 때까지 기다리시면 됩니다."
        case .manualSessionKey:
            return "수동 입력은 마지막 수단입니다. 앞 경로가 다 실패했을 때만 여는 편이 맞습니다."
        }
    }
}

private extension SetupWizardView.Step {
    var buttonTitle: String {
        switch self {
        case .chromeImport:
            return "Chrome 열기"
        case .webLogin:
            return "웹 로그인"
        case .manualSessionKey:
            return "고급 설정"
        }
    }
}
