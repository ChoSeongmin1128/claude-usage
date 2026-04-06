import SwiftUI

extension SettingsView {
    func segmentedTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor).opacity(0.45))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    func settingsToggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    func chip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16))
        .foregroundStyle(color)
        .cornerRadius(6)
    }
}
