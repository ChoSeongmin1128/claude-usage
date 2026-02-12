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
    /// - Hue 120°(초록) → 60°(노랑) → 0°(빨강)
    nonisolated static func statusColor(for percentage: Double) -> Color {
        if percentage >= 100 {
            return .gray
        }

        let hue = (120.0 - (percentage * 1.2)) / 360.0
        let saturation = 0.85
        let brightness = percentage > 50 ? 0.85 : 0.75

        return Color(hue: max(0, hue), saturation: saturation, brightness: brightness)
    }

    /// NSColor 버전 (메뉴바용)
    nonisolated static func nsStatusColor(for percentage: Double) -> NSColor {
        if percentage >= 100 {
            return .gray
        }

        let hue = (120.0 - (percentage * 1.2)) / 360.0
        let saturation: CGFloat = 0.85
        let brightness: CGFloat = percentage > 50 ? 0.85 : 0.75

        return NSColor(hue: CGFloat(max(0, hue)), saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    /// 주간 세션용 색상 (시안 → 파랑)
    /// - Hue 190°(시안) → 260°(파랑)
    nonisolated static func weeklyStatusColor(for percentage: Double) -> Color {
        if percentage >= 100 { return .gray }
        let hue = (190.0 + (percentage * 0.7)) / 360.0
        let saturation = 0.75
        let brightness = 0.9
        return Color(hue: min(hue, 260.0 / 360.0), saturation: saturation, brightness: brightness)
    }

    /// 주간 세션용 NSColor (메뉴바용)
    nonisolated static func nsWeeklyStatusColor(for percentage: Double) -> NSColor {
        if percentage >= 100 { return .gray }
        let hue = (190.0 + (percentage * 0.7)) / 360.0
        let saturation: CGFloat = 0.75
        let brightness: CGFloat = 0.9
        return NSColor(hue: CGFloat(min(hue, 260.0 / 360.0)), saturation: saturation, brightness: brightness, alpha: 1.0)
    }
}
