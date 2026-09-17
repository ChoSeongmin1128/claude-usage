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

    let percentage: Double
    var height: CGFloat = 8
    var color: Color? = nil
    var basis: UsageValueBasis = .used

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 배경
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(AppDesign.Surface.track)

                // 진행바
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color ?? ColorProvider.statusColor(for: percentage))
                    .frame(width: geometry.size.width * CGFloat(basis.percentage(fromUsed: percentage) ?? 0) / 100)
                    .animation(
                        settings.motion.animation(for: .usageValue, reduceMotion: reduceMotion), value: percentage)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("사용량")
        .accessibilityValue(basis.spokenValue(fromUsed: percentage))
    }
}
