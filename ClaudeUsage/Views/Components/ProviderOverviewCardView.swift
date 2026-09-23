import SwiftUI

struct ProviderOverviewCardView: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let isEnabled: Bool
        let isActive: Bool
        let summary: String
    }

    let title: String
    let subtitle: String?
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack {
                Text(title)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(AppDesign.Typography.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(items) { item in
                HStack(spacing: AppDesign.Space.row) {
                    Circle()
                        .fill(item.isEnabled ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)

                    Text(item.title)
                        .font(AppDesign.Typography.caption)

                    if item.isActive {
                        Text("활성")
                            .font(AppDesign.Typography.caption2.weight(.medium))
                            .padding(.horizontal, AppDesign.Space.control)
                            .padding(.vertical, AppDesign.Space.tight)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(5)
                    }

                    Spacer()

                    Text(item.summary)
                        .font(AppDesign.Typography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(AppDesign.Space.label)
        .appPanelStyle()
    }
}
