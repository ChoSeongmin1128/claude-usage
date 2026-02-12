//
//  ProgressBarView.swift
//  ClaudeUsage
//
//  Phase 2: 동적 색상 진행바
//

import SwiftUI

struct ProgressBarView: View {
    let percentage: Double
    var height: CGFloat = 8
    var color: Color? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 배경
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.gray.opacity(0.2))

                // 진행바
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color ?? ColorProvider.statusColor(for: percentage))
                    .frame(width: geometry.size.width * CGFloat(min(percentage, 100)) / 100)
                    .animation(.easeInOut(duration: 0.3), value: percentage)
            }
        }
        .frame(height: height)
    }
}
