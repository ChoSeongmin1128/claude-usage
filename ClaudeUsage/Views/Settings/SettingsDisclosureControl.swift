import SwiftUI

/// macOS 기본 DisclosureGroup의 작은 chevron hit target 대신, label 행 전체를
/// 하나의 명시적인 disclosure button으로 제공한다.
struct SettingsDisclosureControl<Label: View, Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var isExpanded: Bool
    private let accessibilityLabel: String?
    private let label: () -> Label
    private let content: () -> Content

    init(
        isExpanded: Binding<Bool>,
        accessibilityLabel: String? = nil,
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
            if let accessibilityLabel {
                disclosureButton.accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel)
            } else {
                disclosureButton.accessibilityElement(children: .combine)
            }

            if isExpanded {
                content()
                    .padding(.top, AppDesign.Space.row)
                    .transition(
                        settings.motion.allows(.disclosure, reduceMotion: reduceMotion)
                            ? .opacity.combined(with: .move(edge: .top)) : .identity)
            }
        }
    }
    private var disclosureButton: some View {
            Button {
            withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppDesign.Space.row) {
                    Image(systemName: "chevron.right")
                        .font(AppDesign.Typography.smallIcon)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    .accessibilityHidden(true)

                    label()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
            .accessibilityHint(isExpanded ? "눌러서 접습니다" : "눌러서 펼칩니다")

    }

}

struct AppDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsDisclosureControl(isExpanded: configuration.$isExpanded) {
            configuration.label
        } content: {
            configuration.content
        }
    }
}
