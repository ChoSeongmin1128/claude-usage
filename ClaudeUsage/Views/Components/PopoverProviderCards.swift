import SwiftUI

struct PopoverProviderOverviewRowView: View {
    let provider: AppProviderKind
    let title: String
    let summary: String
    let meta: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppDesign.Space.label) {
                VStack(alignment: .leading, spacing: AppDesign.Space.micro) {
                    HStack(spacing: AppDesign.Space.control) {
                        ProviderBrandIconView(provider: provider, kind: .popover, size: 14)
                        Text(title)
                            .font(AppDesign.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isSelected {
                            Text("활성")
                                .font(AppDesign.Typography.caption2.weight(.medium))
                                .padding(.horizontal, AppDesign.Space.control)
                                .padding(.vertical, AppDesign.Space.tight)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }

                    Text(summary)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)
                Spacer()
                if let meta {
                    Text(meta)
                        .font(AppDesign.Typography.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(AppDesign.Typography.badge)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppDesign.Space.label)
            .padding(.vertical, AppDesign.Space.row)
            .background(
                RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.08)
                          : Color(NSColor.controlBackgroundColor).opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }
}

struct PopoverProviderShellCardView: View {
    let provider: AppProviderKind
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
        HStack(spacing: AppDesign.Space.label) {
            VStack(alignment: .leading, spacing: AppDesign.Space.micro) {
                HStack(spacing: AppDesign.Space.control) {
                    ProviderBrandIconView(provider: provider, kind: .popover, size: 13)
                    Text(title)
                        .font(AppDesign.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let badgeTitle {
                        Text(badgeTitle)
                            .font(AppDesign.Typography.caption2.weight(.medium))
                            .padding(.horizontal, AppDesign.Space.control)
                            .padding(.vertical, AppDesign.Space.tight)
                            .background((isSelectable ? Color.accentColor : Color.secondary).opacity(0.14))
                            .foregroundStyle(isSelectable ? Color.accentColor : .secondary)
                            .clipShape(Capsule())
                    }
                }

                Text(summary)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let detail {
                    Text(detail)
                        .font(AppDesign.Typography.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }
            .layoutPriority(1)

            Spacer()

            if let disclosureTitle, isSelectable {
                Text(disclosureTitle)
                    .font(AppDesign.Typography.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(AppDesign.Typography.badge)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, AppDesign.Space.label)
        .padding(.vertical, AppDesign.Space.row)
        .background(
            RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.08)
                        : AppDesign.Surface.subtleGroup)
        )
    }
}
