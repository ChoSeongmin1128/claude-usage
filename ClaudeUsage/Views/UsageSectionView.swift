//
//  UsageSectionView.swift
//  ClaudeUsage
//
//  Phase 2: 사용량 섹션 컴포넌트
//

import SwiftUI

struct UsageSectionView: View {
    let title: String
    let percentage: Double
    let resetAt: String?
    var isWeekly: Bool = false
    var timeFormatStyle: TimeFormatStyle = .h24

    var body: some View {
        StandardUsageRow(
            title: title,
            percentage: percentage,
            detailText: resetTimeText
        )
    }

    private var resetTimeText: String? {
        guard let resetAt = resetAt else { return nil }
        if isWeekly {
            return TimeFormatter.formatRelativeTimeWithClockWeekly(
                from: resetAt,
                style: timeFormatStyle,
                label: nil
            )
        }
        return TimeFormatter.formatRelativeTimeWithClock(
            from: resetAt,
            style: timeFormatStyle,
            label: nil
        )
    }
}
