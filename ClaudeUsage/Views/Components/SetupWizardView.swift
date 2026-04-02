import SwiftUI

struct SetupWizardView: View {
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
                return "기본 경로입니다. Chrome 로그인 상태에서 sessionKey를 먼저 읽어옵니다."
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

            ForEach(Step.allCases) { step in
                stepRow(step)
            }

            HStack(spacing: 8) {
                Button(currentStep.ctaTitle) {
                    performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if hasReadyCredential {
                    Button("안내 숨기기") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if !isAdvancedExpanded {
                    Button("고급 열기") {
                        onOpenAdvanced()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func stepRow(_ step: Step) -> some View {
        let state = state(for: step)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.iconName)
                .foregroundStyle(state.color)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.caption)
                    if step == currentStep && !hasReadyCredential {
                        Text("현재")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(4)
                    }
                }
                Text(step.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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

    private func performPrimaryAction() {
        switch currentStep {
        case .chromeImport:
            onOpenChrome()
        case .webLogin:
            onOpenWebLogin()
        case .manualSessionKey:
            onOpenAdvanced()
        }
    }
}
