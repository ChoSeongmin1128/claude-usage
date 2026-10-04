import SwiftUI

struct SetupWizardView: View {
    @State private var isAlternativeMethodsExpanded = false

    enum Step: Int, CaseIterable, Identifiable {
        case browserImport
        case webLogin
        case manualSessionKey

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .browserImport:
                return "브라우저에서 가져오기"
            case .webLogin:
                return "앱에서 로그인"
            case .manualSessionKey:
                return "직접 입력"
            }
        }

        var ctaTitle: String { title }
    }

    /// 로그인 단계에서만 그린다.
    let currentStep: Step
    let isAdvancedExpanded: Bool
    let onImportFromBrowser: () -> Void
    let onOpenWebLogin: () -> Void
    let onOpenAdvanced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.label) {
            HStack(spacing: AppDesign.Space.row) {
                ForEach(Step.allCases) { step in
                    Capsule()
                        .fill(color(for: step))
                        .frame(height: 5)
                }
            }

            primaryStepCard

            if !alternativeSteps.isEmpty {
                DisclosureGroup(isExpanded: $isAlternativeMethodsExpanded) {
                    VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                        ForEach(alternativeSteps) { step in
                            alternativeStepRow(step)
                        }
                    }
                    .padding(.top, AppDesign.Space.control)
                } label: {
                    Text("다른 방법")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(AppDesign.Space.label)
        .appPanelStyle()
        .disclosureGroupStyle(AppDisclosureGroupStyle())
    }

    private var primaryStepTitle: String {
        currentStep.title
    }

    private var alternativeSteps: [Step] {
        Step.allCases.filter { $0 != currentStep }
    }

    private var primaryStepCard: some View {
        let state = state(for: currentStep)
        return HStack(alignment: .top, spacing: AppDesign.Space.row) {
            Image(systemName: state.iconName)
                .foregroundStyle(state.color)
                .font(AppDesign.Typography.caption)
                .padding(.top, 1)
            HStack(spacing: AppDesign.Space.control) {
                Text(primaryStepTitle)
                    .font(AppDesign.Typography.caption.weight(.semibold))
                if currentStep == .browserImport {
                    Text("권장")
                        .font(AppDesign.Typography.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AppDesign.Space.label)
        .appPanelStyle()
    }

    private func alternativeStepRow(_ step: Step) -> some View {
        Button(step.title) {
            perform(step)
        }
        .buttonStyle(.borderless)
        .font(AppDesign.Typography.caption)
    }

    private func color(for step: Step) -> Color {
        let state = state(for: step)
        if step == currentStep {
            return .accentColor
        }
        return state.color.opacity(0.9)
    }

    private func state(for step: Step) -> (iconName: String, color: Color) {
        switch step {
        case .browserImport:
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
        case .browserImport:
            onImportFromBrowser()
        case .webLogin:
            onOpenWebLogin()
        case .manualSessionKey:
            onOpenAdvanced()
        }
    }

}
