//
//  MenuBarIconRenderer.swift
//  ClaudeUsage
//
//  메뉴바 아이콘 렌더링 (배터리바, 원형 링)
//

import AppKit

enum MenuBarIconRenderer {
    // MARK: - Battery Icon (Mac 스타일)

    /// Mac 배터리 UI 스타일 아이콘 생성
    /// - Parameters:
    ///   - percentage: 사용률 (0~100)
    ///   - color: 채움 색상
    /// - Returns: 메뉴바용 NSImage
    nonisolated static func batteryIcon(percentage: Double, color: NSColor) -> NSImage {
        let height: CGFloat = 12
        let bodyWidth: CGFloat = 24
        let capWidth: CGFloat = 2.5
        let totalWidth = bodyWidth + capWidth + 1
        let cornerRadius: CGFloat = 2.5
        let capCornerRadius: CGFloat = 1.0
        let inset: CGFloat = 1.5

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            // 배터리 본체 외곽선
            let bodyRect = NSRect(x: 0.5, y: 0.5, width: bodyWidth - 1, height: height - 1)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
            bodyPath.lineWidth = 1.0

            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let strokeColor: NSColor = isDark ? .white.withAlphaComponent(0.7) : .black.withAlphaComponent(0.5)
            strokeColor.setStroke()
            bodyPath.stroke()

            // 배터리 양극 돌출부
            let capRect = NSRect(x: bodyWidth, y: height * 0.25, width: capWidth, height: height * 0.5)
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: capCornerRadius, yRadius: capCornerRadius)
            strokeColor.withAlphaComponent(0.5).setFill()
            capPath.fill()

            // 내부 채움 (남은 양 = 100 - 사용량)
            let remaining = 100.0 - min(max(percentage, 0), 100)
            let fillPercent = remaining / 100.0
            let innerRect = NSRect(
                x: inset,
                y: inset,
                width: (bodyWidth - inset * 2) * fillPercent,
                height: height - inset * 2
            )
            let innerCorner = max(cornerRadius - inset, 1.0)
            let fillPath = NSBezierPath(roundedRect: innerRect, xRadius: innerCorner, yRadius: innerCorner)
            color.setFill()
            fillPath.fill()

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - Circular Ring Icon

    /// 원형 링 아이콘 생성 (사용량에 따라 채워짐)
    /// - Parameters:
    ///   - percentage: 사용률 (0~100)
    ///   - color: 채움 색상
    /// - Returns: 메뉴바용 NSImage
    nonisolated static func circularRingIcon(percentage: Double, color: NSColor) -> NSImage {
        let size: CGFloat = 16
        let lineWidth: CGFloat = 2.5
        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let trackColor: NSColor = isDark ? .white.withAlphaComponent(0.2) : .black.withAlphaComponent(0.12)

            // 배경 트랙 (빈 원)
            let trackPath = NSBezierPath()
            trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            trackPath.lineWidth = lineWidth
            trackColor.setStroke()
            trackPath.stroke()

            // 채움 호 (12시 방향에서 시계방향)
            let fillPercent = min(max(percentage, 0), 100) / 100.0
            if fillPercent > 0 {
                let startAngle: CGFloat = 90  // 12시 방향
                let endAngle = 90 - (360 * fillPercent)

                let fillPath = NSBezierPath()
                fillPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                fillPath.lineWidth = lineWidth
                fillPath.lineCapStyle = .round
                color.setStroke()
                fillPath.stroke()
            }

            return true
        }

        image.isTemplate = false
        return image
    }
}
