// Shared provider identity and provenance rail.
import SwiftUI

struct ProviderIdentityRail: View {
    let projection: ProviderIdentityRailProjection
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(
                Array(projection.visibleSegments.enumerated()),
                id: \.offset
            ) { index, segment in
                if index > 0 {
                    Text("·")
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                Text(segment)
                    .font(font)
                    .foregroundStyle(
                        index >= baseSegmentCount
                            ? projection.tone.color
                            : .secondary
                    )
                    .lineLimit(1)
                    .truncationMode(index == 0 ? .middle : .tail)
                    .layoutPriority(
                        index >= baseSegmentCount
                            ? 2
                            : (index == 0 ? 0 : 1)
                    )
            }

            Spacer(minLength: 0)
        }
        .help(projection.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projection.accessibilityLabel)
        .accessibilityValue(projection.accessibilityValue)
    }

    private var font: Font {
        .system(
            size: compact ? 8 : 9,
            weight: .medium
        )
    }

    private var baseSegmentCount: Int {
        3
    }
}

private extension ProviderIdentityRailTone {
    var color: Color {
        switch self {
        case .standard:
            .secondary
        case .attention:
            Color(nsColor: .systemOrange)
        case .critical:
            Color(nsColor: .systemRed)
        }
    }
}
