import SwiftUI

struct MenuBarHoverUsageView: View {
    @Environment(\.colorScheme) private var scheme
    let content: MenuBarHoverUsageContent

    var body: some View {
        if content.usesCommonColumns {
            VStack(alignment: .leading, spacing: AppDesign.Hover.rowGap) {
                HStack(spacing: AppDesign.Space.row) {
                    Text(content.caption)
                        .font(AppDesign.Typography.metadata).foregroundStyle(AppDesign.Text.secondary)
                    Spacer(minLength: 0)
                    ForEach(content.catalogProviders[0].items) { item in
                        Text(item.compactTitle).font(AppDesign.Typography.metadata).foregroundStyle(
                            AppDesign.Text.secondary
                        )
                        .frame(width: AppDesign.Hover.columnWidth, alignment: .trailing)
                    }
                }
                ForEach(content.catalogProviders) { provider in
                    VStack(alignment: .leading, spacing: AppDesign.Hover.rowGap) {
                        HStack(spacing: AppDesign.Space.row) {
                            serviceHeading(provider)
                            if content.hasMixedBasis {
                                Text(provider.basis.label).font(AppDesign.Typography.metadata).foregroundStyle(
                                    .secondary)
                            }
                            Spacer(minLength: 0)
                            ForEach(provider.items) { item in
                                Text(item.value).font(AppDesign.Typography.compactValue).monospacedDigit()
                                    .foregroundStyle(item.isUnknown ? AppDesign.Text.secondary : Color.primary)
                                    .frame(width: AppDesign.Hover.columnWidth, alignment: .trailing)
                            }
                        }
                        if let state = provider.stateText {
                            Text(state).font(AppDesign.Typography.metadata).foregroundStyle(AppDesign.Text.secondary)
                        }
                    }
                    .hoverPositionID("usage.\(provider.kind.rawValue)")
                }
            }
        }
        if !content.listProviders.isEmpty {
            if content.usesCommonColumns { Divider() }
            VStack(alignment: .leading, spacing: AppDesign.Hover.incidentGap) {
                ForEach(content.listProviders) { provider in
                    VStack(alignment: .leading, spacing: AppDesign.Hover.rowGap) {
                        HStack {
                            serviceHeading(provider)
                            Spacer()
                            Text(provider.stateText ?? provider.basis.title).font(AppDesign.Typography.metadata)
                                .foregroundStyle(AppDesign.Text.secondary)
                        }
                        .hoverPositionID("usage.\(provider.kind.rawValue)")
                        ForEach(provider.items) { item in
                            VStack(alignment: .leading, spacing: AppDesign.Hover.rowGap) {
                                HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.row) {
                                    Text(item.title).font(AppDesign.Typography.caption)
                                    Spacer(minLength: AppDesign.Space.row)
                                    Text(item.value).font(AppDesign.Typography.compactValue).monospacedDigit()
                                        .foregroundStyle(item.isUnknown ? AppDesign.Text.secondary : Color.primary)
                                        .multilineTextAlignment(.trailing)
                                }
                                if let detail = item.detail {
                                    Text(detail).font(AppDesign.Typography.metadata).foregroundStyle(
                                        AppDesign.Text.secondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .hoverPositionID("usage.\(provider.kind.rawValue).\(item.id)")
                        }
                    }
                }
            }
        }
    }
    private func serviceHeading(_ provider: MenuBarHoverUsageContent.Provider) -> some View {
        HStack(spacing: AppDesign.Space.tight) {
            ProviderBrandIconView(
                provider: provider.kind, kind: .popover, size: PopoverLayoutMetrics.compactProviderIconSize)
            Text(provider.kind.displayName).font(AppDesign.Typography.body)
            if provider.kind == .antigravity {
                Text("CLI").font(AppDesign.Typography.metadata).foregroundStyle(AppDesign.Text.secondary)
            } else {
                Circle().fill(AppDesign.Text.status(statusColor(provider.serviceTone), scheme: scheme))
                    .frame(width: AppDesign.Hover.statusDot, height: AppDesign.Hover.statusDot)
            }
        }
    }

    private func statusColor(_ tone: ServiceStatusPanelContent.Tone?) -> Color {
        switch tone {
        case .normal: .green
        case .minor: .orange
        case .major: .red
        case nil: .secondary
        }
    }

}
