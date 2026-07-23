import SwiftUI

/// macOS 기본 DisclosureGroup의 작은 chevron hit target 대신, label 행 전체를
/// 하나의 명시적인 disclosure button으로 제공한다.
struct SettingsDisclosureControl<Label: View, Content: View>: View {
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
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
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
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
