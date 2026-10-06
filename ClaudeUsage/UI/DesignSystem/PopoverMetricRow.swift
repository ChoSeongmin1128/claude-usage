import SwiftUI

struct PopoverMetricRow<Leading: View, Middle: View, Value: View, Detail: View>: View {
    let density: PopoverDensity
    let rowHeight: CGFloat
    let valueSpansMiddle: Bool
    private let leading: Leading
    private let middle: Middle
    private let value: Value
    private let detail: Detail

    init(
        density: PopoverDensity, rowHeight: CGFloat? = nil, valueSpansMiddle: Bool = false,
        @ViewBuilder leading: () -> Leading, @ViewBuilder middle: () -> Middle,
        @ViewBuilder value: () -> Value, @ViewBuilder detail: () -> Detail
    ) {
        self.density = density
        self.rowHeight =
            rowHeight
            ?? (density.isCompact
                ? PopoverLayoutMetrics.compactUsageRowHeight : PopoverLayoutMetrics.standardUsageRowHeight)
        self.valueSpansMiddle = valueSpansMiddle
        self.leading = leading()
        self.middle = middle()
        self.value = value()
        self.detail = detail()
    }

    var body: some View {
        PopoverMetricRowLayout(geometry: geometry, valueSpansMiddle: valueSpansMiddle) {
            VStack(alignment: .leading, spacing: 0) { leading }
            VStack(alignment: .leading, spacing: 0) { middle }
            VStack(alignment: .trailing, spacing: 0) { value }
            VStack(alignment: .leading, spacing: 0) { detail }
        }
    }

    private var geometry: PopoverMetricRowGeometry {
        let compact = density.isCompact
        let font = PopoverLayoutMetrics.metricValueFont(compact: compact)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineTop = compact ? max(0, (rowHeight - lineHeight) / 2) : 0
        let insets = compact ? PopoverLayoutMetrics.compactBodyInsets : PopoverLayoutMetrics.standardBodyInsets
        let idealWidth =
            compact
            ? PopoverLayoutMetrics.compactRowLabelWidth + PopoverLayoutMetrics.compactRowSpacing
                + PopoverLayoutMetrics.compactRowMeterWidth
            : PopoverLayoutMetrics.standardPopoverWidth - insets.leading - insets.trailing
        return PopoverMetricRowGeometry(
            compact: compact, rowHeight: rowHeight, idealWidth: idealWidth,
            labelGap: compact ? PopoverLayoutMetrics.compactRowSpacing : AppDesign.Space.label,
            valueGap: compact ? AppDesign.Space.compact : AppDesign.Space.row,
            labelWidth: PopoverLayoutMetrics.compactRowLabelWidth,
            meterWidth: PopoverLayoutMetrics.standardRowMeterWidth,
            valueWidth: PopoverLayoutMetrics.metricValueWidth,
            baselineOffset: lineTop + ceil(font.ascender), capHeight: font.capHeight,
            detailTop: lineHeight + AppDesign.Space.tight)
    }
}

private nonisolated struct PopoverMetricRowGeometry: Sendable {
    let compact: Bool
    let rowHeight: CGFloat
    let idealWidth: CGFloat
    let labelGap: CGFloat
    let valueGap: CGFloat
    let labelWidth: CGFloat
    let meterWidth: CGFloat
    let valueWidth: CGFloat
    let baselineOffset: CGFloat
    let capHeight: CGFloat
    let detailTop: CGFloat
}

private nonisolated struct PopoverMetricRowLayout: Layout {
    let geometry: PopoverMetricRowGeometry
    let valueSpansMiddle: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? geometry.idealWidth
        return CGSize(width: max(0, width), height: geometry.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let baseline = bounds.minY + geometry.baselineOffset
        let railCenter = baseline - geometry.capHeight / 2
        let leadingWidth: CGFloat
        let meterWidth: CGFloat
        if geometry.compact {
            leadingWidth = min(geometry.labelWidth, max(0, bounds.width - geometry.labelGap))
            meterWidth = max(0, bounds.width - leadingWidth - geometry.labelGap)
        } else {
            let naturalValueWidth = valueSpansMiddle ? subviews[2].sizeThatFits(.unspecified).width : 0
            meterWidth = min(max(geometry.meterWidth, naturalValueWidth), bounds.width)
            leadingWidth = max(0, bounds.width - meterWidth - geometry.labelGap)
        }
        let valueWidth = valueSpansMiddle ? meterWidth : min(geometry.valueWidth, meterWidth)
        let middleWidth = valueSpansMiddle ? 0 : max(0, meterWidth - valueWidth - geometry.valueGap)
        let valueX = bounds.maxX - valueWidth
        let middleX = bounds.minX + leadingWidth + geometry.labelGap

        func placeOnBaseline(_ index: Int, x: CGFloat, width: CGFloat) {
            let proposed = ProposedViewSize(width: width, height: nil)
            let dimensions = subviews[index].dimensions(in: proposed)
            subviews[index].place(
                at: CGPoint(x: x, y: baseline - dimensions[.firstTextBaseline]),
                anchor: .topLeading, proposal: proposed)
        }
        placeOnBaseline(0, x: bounds.minX, width: leadingWidth)
        placeOnBaseline(2, x: valueX, width: valueWidth)
        let middleProposal = ProposedViewSize(width: middleWidth, height: nil)
        let middleSize = subviews[1].sizeThatFits(middleProposal)
        subviews[1].place(
            at: CGPoint(x: middleX, y: railCenter - middleSize.height / 2),
            anchor: .topLeading, proposal: middleProposal)
        subviews[3].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + geometry.detailTop),
            anchor: .topLeading, proposal: ProposedViewSize(width: leadingWidth, height: nil))
    }
}

struct PopoverMetricValue: View {
    let text: String
    var caption: String? = nil
    let compact: Bool
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.micro) {
            Text(text)
                .font(compact ? AppDesign.Typography.compactValue : AppDesign.Typography.headline)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(caption ?? "")
                .font(AppDesign.Typography.caption2)
                .foregroundStyle(.secondary)
                .frame(width: PopoverLayoutMetrics.metricCaptionWidth, alignment: .trailing)
        }
    }
}
