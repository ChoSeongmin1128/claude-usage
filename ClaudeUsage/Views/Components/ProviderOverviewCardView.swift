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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(items) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(item.isEnabled ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)

                    Text(item.title)
                        .font(.caption)

                    if item.isActive {
                        Text("활성")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(5)
                    }

                    Spacer()

                    Text(item.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}
