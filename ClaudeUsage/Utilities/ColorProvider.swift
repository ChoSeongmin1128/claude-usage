//
//  ColorProvider.swift
//  ClaudeUsage
//
//  Phase 2: 동적 색상 시스템 (SwiftUI + AppKit 공용)
//

import SwiftUI
import AppKit

enum ColorProvider {
    /// 사용률에 따른 동적 색상 (초록 → 노랑 → 빨강)
    /// 0-40%: 초록 → 연두, 40-70%: 노랑 구간, 70-100%: 주황 → 빨강
    nonisolated static func statusColor(for percentage: Double) -> Color {
        if percentage >= 100 { return .gray }
        let (h, s, b) = statusHSB(for: percentage)
        return Color(hue: h, saturation: s, brightness: b)
    }

    /// NSColor 버전 (메뉴바용)
    nonisolated static func nsStatusColor(for percentage: Double) -> NSColor {
        if percentage >= 100 { return .gray }
        let (h, s, b) = statusHSB(for: percentage)
        return NSColor(hue: h, saturation: s, brightness: b, alpha: 1.0)
    }

    /// 주간 세션용 색상 (5시간과 동일한 초록 → 노랑 → 빨강)
    nonisolated static func weeklyStatusColor(for percentage: Double) -> Color {
        statusColor(for: percentage)
    }

    /// 주간 세션용 NSColor (5시간과 동일)
    nonisolated static func nsWeeklyStatusColor(for percentage: Double) -> NSColor {
        nsStatusColor(for: percentage)
    }

    // MARK: - Private

    private nonisolated static func statusHSB(for percentage: Double) -> (CGFloat, CGFloat, CGFloat) {
        let hue: CGFloat
        if percentage <= 40 {
            // 초록(120°) → 연두-노랑(65°)
            hue = (120.0 - (percentage / 40.0) * 55.0) / 360.0
        } else if percentage <= 70 {
            // 노랑(65°) → 주황-노랑(35°) — 노랑 구간 넓게
            hue = (65.0 - ((percentage - 40.0) / 30.0) * 30.0) / 360.0
        } else {
            // 주황(35°) → 빨강(0°)
            hue = (35.0 - ((percentage - 70.0) / 30.0) * 35.0) / 360.0
        }
        return (max(0, hue), 0.85, 0.85)
    }
}
