//
//  ColorProvider.swift
//  ClaudeUsage
//
//  Phase 2: 동적 색상 시스템 (SwiftUI + AppKit 공용)
//

import SwiftUI
import AppKit

enum ColorProvider {
    /// 사용률에 따른 Apple 시스템 색상
    /// 0-50%: 초록, 50-75%: 노랑, 75-90%: 주황, 90%+: 빨강, 100%+: 회색
    nonisolated static func statusColor(for percentage: Double) -> Color {
        if percentage >= 100 { return Color(.systemGray) }
        if percentage >= 90 { return Color(.systemRed) }
        if percentage >= 75 { return Color(.systemOrange) }
        if percentage >= 50 { return Color(.systemYellow) }
        return Color(.systemGreen)
    }

    /// NSColor 버전 (메뉴바용)
    nonisolated static func nsStatusColor(for percentage: Double) -> NSColor {
        if percentage >= 100 { return .systemGray }
        if percentage >= 90 { return .systemRed }
        if percentage >= 75 { return .systemOrange }
        if percentage >= 50 { return .systemYellow }
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
