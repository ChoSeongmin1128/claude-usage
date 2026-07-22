//
//  UsageSectionView.swift
//  ClaudeUsage
//
//  Phase 2: 사용량 섹션 컴포넌트
//

import SwiftUI

struct UsageSectionView: View {
    let systemIcon: String?
    let title: String
    let percentage: Double
    let resetAt: String?
    var isWeekly: Bool = false
    var timeFormatStyle: TimeFormatStyle = .h24

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let systemIcon {
                        Image(systemName: systemIcon)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .center)
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                }

                if let text = resetTimeText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ProgressBarView(percentage: percentage, height: 8)
                    .frame(maxWidth: .infinity)

                Text(String(format: "%.0f%%", percentage))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(ColorProvider.statusColor(for: percentage))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 156, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var resetTimeText: String? {
        guard let resetAt = resetAt else { return nil }
        if isWeekly {
            return TimeFormatter.formatRelativeTimeWithClockWeekly(from: resetAt, style: timeFormatStyle)
        }
        return TimeFormatter.formatRelativeTimeWithClock(from: resetAt, style: timeFormatStyle)
    }
}
