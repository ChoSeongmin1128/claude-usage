import SwiftUI

/// macOS 기본 DisclosureGroup의 작은 chevron hit target 대신, label 행 전체를
/// 하나의 명시적인 disclosure button으로 제공한다.
struct SettingsDisclosureControl<Label: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var isExpanded: Bool
    private let accessibilityLabel: String
    private let label: () -> Label
    private let content: () -> Content

    init(
        isExpanded: Binding<Bool>,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : AppDesign.Motion.control) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppDesign.Space.row) {
                    Image(systemName: "chevron.right")
                        .font(AppDesign.Typography.smallIcon)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    label()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
            .accessibilityHint(isExpanded ? "눌러서 접습니다" : "눌러서 펼칩니다")

            if isExpanded {
                content()
                    .padding(.top, AppDesign.Space.row)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
