//
//  ProgressBarView.swift
//  ClaudeUsage
//
//  Phase 2: 동적 색상 진행바
//

// Shared usage progress primitive.
import SwiftUI

struct ProgressBarView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    let percentage: Double
    var height: CGFloat = 8
    var color: Color? = nil
    var basis: UsageValueBasis = .used
    var cornerRadius: CGFloat? = nil
    // On the used scale, so the marker goes through the same `basis` transform as the fill.
    var elapsedPercentage: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 배경
                RoundedRectangle(cornerRadius: cornerRadius ?? height / 2)
                    .fill(AppDesign.Surface.track)

                // 진행바
                RoundedRectangle(cornerRadius: cornerRadius ?? height / 2)
                    .fill(color ?? ColorProvider.statusColor(for: percentage))
                    .frame(width: geometry.size.width * CGFloat(basis.percentage(fromUsed: percentage) ?? 0) / 100)
                    .animation(
                        settings.motion.animation(for: .usageValue, reduceMotion: reduceMotion), value: percentage)
            }
            .overlay(alignment: .leading) {
                let markerWidth = Self.paceMarkerWidth(barHeight: height)
                if let offset = Self.paceMarkerOffset(
                    elapsedPercentage: elapsedPercentage, basis: basis, trackWidth: geometry.size.width,
                    markerWidth: markerWidth, scale: displayScale)
                {
                    RoundedRectangle(cornerRadius: markerWidth / 2, style: .continuous)
                        .fill(AppDesign.Surface.paceMarker)
                        .frame(width: markerWidth, height: height + Self.paceMarkerOverhang * 2)
                        .offset(x: offset)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("사용량")
        .accessibilityValue(basis.spokenValue(fromUsed: percentage))
    }

    static let paceMarkerOverhang: CGFloat = 2

    // 2.5pt is 5px at 2x; on the 4pt compact bar it reads heavier than the bar, so that bar gets 2pt.
    static func paceMarkerWidth(barHeight: CGFloat) -> CGFloat {
        barHeight >= 6 ? 2.5 : 2
    }

    static func paceMarkerOffset(
        elapsedPercentage: Double?, basis: UsageValueBasis, trackWidth: CGFloat, markerWidth: CGFloat, scale: CGFloat
    ) -> CGFloat? {
        guard let shown = basis.percentage(fromUsed: elapsedPercentage), trackWidth > markerWidth, scale > 0 else {
            return nil
        }
        let offset = (trackWidth - markerWidth) * CGFloat(shown) / 100
        return (offset * scale).rounded() / scale
    }
}
