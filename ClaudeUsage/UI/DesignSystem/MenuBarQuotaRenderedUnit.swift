import AppKit

struct MenuBarQuotaHitTarget {
    let id: String
    let region: Region

    enum Region {
        case rectangle(CGRect)
        case ring(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat)

        func contains(_ point: CGPoint) -> Bool {
            switch self {
            case .rectangle(let rect): rect.contains(point)
            case .ring(let center, let inner, let outer):
                (inner...outer).contains(hypot(point.x - center.x, point.y - center.y))
            }
        }
    }
}

struct MenuBarQuotaRenderedUnit {
    let ids: [String]
    let image: NSImage
    var condensedImage: NSImage? = nil
    let title: String
    var hitTargets: [MenuBarQuotaHitTarget] = []

    func selectedID(at point: CGPoint) -> String? {
        hitTargets.first { $0.region.contains(point) }?.id ?? ids.first
    }
}

@MainActor
struct MenuBarQuotaRenderItem {
    let id: String
    let title: String
    let gauge: MenuBarIconRenderer.Gauge
    let percentageText: String?
    var condensedPercentageText: String? = nil
    let resetText: String?
    var condensedResetText: String? = nil
}
