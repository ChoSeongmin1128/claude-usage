import AppKit

/// 초기화권 기호(↺)를 옆 숫자의 높이에 맞춘다. ↺는 숫자보다 크고 기준선 아래로 내려가는 글리프라 같은 글꼴로
/// 그리면 숫자와 위아래 끝이 어긋난다. 그림 높이를 숫자 높이(cap height)에 맞추고 가운데를 숫자 가운데에 둔다.
nonisolated enum ResetCreditSymbol {
    struct Fit: Equatable {
        let pointSize: CGFloat
        let baselineOffset: CGFloat
    }

    static func fit(to font: NSFont) -> Fit {
        let natural = inkBounds(font)
        guard natural.height > 0 else { return Fit(pointSize: font.pointSize, baselineOffset: 0) }
        let fitted = font.withSize(font.pointSize * font.capHeight / natural.height)
        return Fit(pointSize: fitted.pointSize, baselineOffset: font.capHeight / 2 - inkBounds(fitted).midY)
    }

    private static func inkBounds(_ font: NSFont) -> CGRect {
        let text = NSAttributedString(string: MenuBarResetCreditBadge.symbol, attributes: [.font: font])
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
    }
}
