import SwiftUI

struct PopoverProviderOverviewRowView: View {
    let title: String
    let summary: String
    let meta: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isSelected {
                            Text("활성")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }

                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)
                Spacer()
                if let meta {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.08)
                          : Color(NSColor.controlBackgroundColor).opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }
}

struct PopoverProviderShellCardView: View {
    let icon: String
    let title: String
    let summary: String
    let detail: String?
    let badgeTitle: String?
    let isSelected: Bool
    let isSelectable: Bool
    let disclosureTitle: String?
    let onSelect: (() -> Void)?

    var body: some View {
        Group {
            if let onSelect, isSelectable {
                Button(action: onSelect) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
                    .opacity(0.85)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let badgeTitle {
                        Text(badgeTitle)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((isSelectable ? Color.accentColor : Color.secondary).opacity(0.14))
                            .foregroundStyle(isSelectable ? Color.accentColor : .secondary)
                            .clipShape(Capsule())
                    }
                }

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }
            .layoutPriority(1)

            Spacer()

            if let disclosureTitle, isSelectable {
                Text(disclosureTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.08)
                      : Color(NSColor.controlBackgroundColor).opacity(0.35))
        )
    }
}
