import SwiftUI

/// The header owns expansion. Trailing actions and expanded content are siblings,
/// so using an account or selecting detail text never toggles the disclosure.
struct SettingsDisclosureControl<Label: View, Actions: View, Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var isExpanded: Bool
    @State private var isHovered = false
    private let accessibilityLabel: String?
    private let label: () -> Label
    private let actions: () -> Actions
    private let content: () -> Content

    init(
        isExpanded: Binding<Bool>, accessibilityLabel: String? = nil,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
        self.label = label
        self.actions = actions
        self.content = content
    }

    init(
        isExpanded: Binding<Bool>, accessibilityLabel: String? = nil,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) where Actions == EmptyView {
        self.init(
            isExpanded: isExpanded, accessibilityLabel: accessibilityLabel,
            label: label, actions: { EmptyView() }, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppDesign.Space.row) {
                if let accessibilityLabel {
                    disclosureButton.accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel)
                } else {
                    disclosureButton.accessibilityElement(children: .combine)
                }
                actions()
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
            .padding(.horizontal, AppDesign.Space.control)
            .padding(.vertical, AppDesign.Space.control)
            .frame(maxWidth: .infinity, minHeight: AppDesign.Control.disclosureRowHeight, alignment: .leading)
            .background(
                isHovered ? AppDesign.Surface.group : .clear,
                in: RoundedRectangle(cornerRadius: AppDesign.Radius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
