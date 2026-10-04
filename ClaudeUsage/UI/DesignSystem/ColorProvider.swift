//
//  ColorProvider.swift
//  ClaudeUsage
//
//  Phase 2: 동적 색상 시스템 (SwiftUI + AppKit 공용)
//

import SwiftUI
import AppKit

enum ColorProvider {
    /// 사용률 색 구간: 이 값 이상부터 노랑, 주황, 빨강. 100% 이상은 회색.
    nonisolated static let cautionPercent: Double = 50
    nonisolated static let warningPercent: Double = 75
    nonisolated static let criticalPercent: Double = 90

    nonisolated static func statusColor(for percentage: Double) -> Color {
        Color(nsStatusColor(for: percentage))
    }

    /// NSColor 버전 (메뉴바용)
    nonisolated static func nsStatusColor(for percentage: Double) -> NSColor {
        guard percentage.isFinite else { return .secondaryLabelColor }
        if percentage >= 100 { return .systemGray }
        if percentage >= criticalPercent { return .systemRed }
        if percentage >= warningPercent { return .systemOrange }
        if percentage >= cautionPercent { return .systemYellow }
        return .systemGreen
    }

    /// 주간 세션용 색상 (5시간과 동일)
    nonisolated static func weeklyStatusColor(for percentage: Double) -> Color {
        statusColor(for: percentage)
    }

    /// 주간 세션용 NSColor (5시간과 동일)
    nonisolated static func nsWeeklyStatusColor(for percentage: Double) -> NSColor {
        nsStatusColor(for: percentage)
    }
}
