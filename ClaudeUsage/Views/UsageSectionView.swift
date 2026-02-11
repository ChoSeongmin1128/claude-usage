//
//  UsageSectionView.swift
//  ClaudeUsage
//
//  Phase 2: 사용량 섹션 컴포넌트
//

import SwiftUI

struct UsageSectionView: View {
    let icon: String
    let title: String
    let percentage: Double
    let resetAt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 제목 + 퍼센트
            HStack {
                Text("\(icon) \(title)")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", percentage))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(ColorProvider.statusColor(for: percentage))
            }

            // 진행바
            ProgressBarView(percentage: percentage)

            // 리셋 시간
            Text(TimeFormatter.formatRelativeTime(from: resetAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
