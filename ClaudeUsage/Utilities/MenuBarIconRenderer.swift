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
    nonisolated static func batteryIcon(percentage: Double, color: NSColor, showPercent: Bool = true) -> NSImage {
        let height: CGFloat = 14
        let bodyWidth: CGFloat = 36
        let capWidth: CGFloat = 3
        let totalWidth = bodyWidth + capWidth + 1
        let cornerRadius: CGFloat = 3.0
        let capCornerRadius: CGFloat = 1.5
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

            // 퍼센트 텍스트 (배터리 내부 중앙)
            if showPercent {
                let textColor: NSColor = isDark ? .white : .black
                let text = String(format: "%.0f%%", remaining)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
                    .foregroundColor: textColor.withAlphaComponent(0.85)
                ]
                let textSize = (text as NSString).size(withAttributes: attrs)
                let textX = (bodyWidth - textSize.width) / 2
                let textY = (height - textSize.height) / 2
                (text as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
            }

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

    // MARK: - Concentric Rings Icon (동심원)

    /// 동심원 아이콘: 바깥=5시간, 안쪽=주간
    nonisolated static func concentricRingsIcon(
        outerPercent: Double,
        innerPercent: Double,
        outerColor: NSColor,
        innerColor: NSColor
    ) -> NSImage {
        let size: CGFloat = 18
        let center = NSPoint(x: size / 2, y: size / 2)
        let outerLineWidth: CGFloat = 2.5
        let outerRadius: CGFloat = (size - outerLineWidth) / 2
        let innerLineWidth: CGFloat = 2.0
        let innerRadius: CGFloat = 4.5

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let trackColor: NSColor = isDark ? .white.withAlphaComponent(0.15) : .black.withAlphaComponent(0.08)

            // 바깥 링 트랙
            let outerTrack = NSBezierPath()
            outerTrack.appendArc(withCenter: center, radius: outerRadius, startAngle: 0, endAngle: 360)
            outerTrack.lineWidth = outerLineWidth
            trackColor.setStroke()
            outerTrack.stroke()

            // 바깥 링 채움 (5시간)
            let outerFill = min(max(outerPercent, 0), 100) / 100.0
            if outerFill > 0 {
                let endAngle = 90 - (360 * outerFill)
                let outerArc = NSBezierPath()
                outerArc.appendArc(withCenter: center, radius: outerRadius, startAngle: 90, endAngle: endAngle, clockwise: true)
                outerArc.lineWidth = outerLineWidth
                outerArc.lineCapStyle = .round
                outerColor.setStroke()
                outerArc.stroke()
            }

            // 안쪽 링 트랙
            let innerTrack = NSBezierPath()
            innerTrack.appendArc(withCenter: center, radius: innerRadius, startAngle: 0, endAngle: 360)
            innerTrack.lineWidth = innerLineWidth
            trackColor.setStroke()
            innerTrack.stroke()

            // 안쪽 링 채움 (주간)
            let innerFill = min(max(innerPercent, 0), 100) / 100.0
            if innerFill > 0 {
                let endAngle = 90 - (360 * innerFill)
                let innerArc = NSBezierPath()
                innerArc.appendArc(withCenter: center, radius: innerRadius, startAngle: 90, endAngle: endAngle, clockwise: true)
                innerArc.lineWidth = innerLineWidth
                innerArc.lineCapStyle = .round
                innerColor.setStroke()
                innerArc.stroke()
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - Dual Battery Icon (이중 배터리)

    /// 이중 배터리 아이콘: 위=5시간, 아래=주간
    nonisolated static func dualBatteryIcon(
        topPercent: Double,
        bottomPercent: Double,
        topColor: NSColor,
        bottomColor: NSColor
    ) -> NSImage {
        let totalHeight: CGFloat = 14
        let bodyWidth: CGFloat = 36
        let capWidth: CGFloat = 3
        let totalWidth = bodyWidth + capWidth + 1
        let batteryHeight: CGFloat = 6.0
        let gap: CGFloat = 2.0
        let cornerRadius: CGFloat = 2.0
        let capCornerRadius: CGFloat = 1.0
        let inset: CGFloat = 1.0

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let strokeColor: NSColor = isDark ? .white.withAlphaComponent(0.7) : .black.withAlphaComponent(0.5)

            func drawBattery(yOffset: CGFloat, percentage: Double, color: NSColor) {
                let bodyRect = NSRect(x: 0.5, y: yOffset + 0.5, width: bodyWidth - 1, height: batteryHeight - 1)
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
                bodyPath.lineWidth = 0.8
                strokeColor.setStroke()
                bodyPath.stroke()

                let capRect = NSRect(x: bodyWidth, y: yOffset + batteryHeight * 0.2, width: capWidth * 0.7, height: batteryHeight * 0.6)
                let capPath = NSBezierPath(roundedRect: capRect, xRadius: capCornerRadius, yRadius: capCornerRadius)
                strokeColor.withAlphaComponent(0.4).setFill()
                capPath.fill()

                let remaining = (100.0 - min(max(percentage, 0), 100)) / 100.0
                let innerRect = NSRect(
                    x: inset,
                    y: yOffset + inset,
                    width: (bodyWidth - inset * 2) * remaining,
                    height: batteryHeight - inset * 2
                )
                let innerCorner = max(cornerRadius - inset, 0.5)
                let fillPath = NSBezierPath(roundedRect: innerRect, xRadius: innerCorner, yRadius: innerCorner)
                color.setFill()
                fillPath.fill()
            }

            drawBattery(yOffset: 0, percentage: bottomPercent, color: bottomColor)
            drawBattery(yOffset: batteryHeight + gap, percentage: topPercent, color: topColor)

            return true
        }

        image.isTemplate = false
        return image
    }
}
