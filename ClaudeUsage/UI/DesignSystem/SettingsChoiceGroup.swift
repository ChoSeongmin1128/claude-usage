import SwiftUI

/// Short choices share one row when their intrinsic text sizes fit. Longer text
/// keeps its natural size and falls back to a vertical list.
struct SettingsChoiceGroup<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    let selection: Value
    let onChange: (Value) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppDesign.Space.section) {
                Text(title).font(AppDesign.Typography.subheadline).fixedSize()
                HStack(spacing: AppDesign.Space.row) { choices }.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
                Text(title).font(AppDesign.Typography.subheadline)
                VStack(alignment: .leading, spacing: 0) { choices }
            }
        }
    }

    private var choices: some View {
        ForEach(options.indices, id: \.self) { index in
            Button {
                onChange(options[index].value)
            } label: {
                HStack(spacing: AppDesign.Space.control) {
                    Image(systemName: selection == options[index].value ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selection == options[index].value ? Color.accentColor : .secondary)
                        .font(AppDesign.Typography.icon)
                    Text(options[index].label).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AppDesign.Space.compact)
                .frame(minHeight: AppDesign.Control.regularHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(options[index].label)
            .accessibilityValue(selection == options[index].value ? "선택됨" : "선택 안 됨")
            .accessibilityAddTraits(selection == options[index].value ? .isSelected : [])
        }
    }
}
